//
//  KnowledgeRAGIndexBuilderTests.swift
//  StarcatTests
//
//  使用真实内存索引库和可控向量客户端，验证失败后能退出构建态，且取消后的迟到响应不会写回。
//  不连接真实 Provider，不读写用户的数据库、凭据或模型配置。
//

import Foundation
import Testing
@testable import Starcat

/// 覆盖 source 通知和 Stars 同步后的元数据入口，而非只测试展示状态枚举。
@MainActor
@Suite("Knowledge RAG Index Builder", .timeLimit(.minutes(1)))
struct KnowledgeRAGIndexBuilderTests {
    enum RefreshRoute: CaseIterable, Sendable {
        case source, metadata
    }

    @Test("自动刷新失败或超时后必须结束构建并保留可检索文本",
          arguments: RefreshRoute.allCases, [AIEmbeddingError.modelRequestRejected, .timedOut])
    func automaticFailureFinishesStatus(route: RefreshRoute, error: AIEmbeddingError) async throws {
        let fixture = try await Fixture(error: error)
        defer { fixture.cleanup() }

        switch route {
        case .source:
            await fixture.builder.refresh(repo: fixture.repo, sources: [.readme])
        case .metadata:
            await fixture.builder.refreshMetadataForKnowledgeRepos()
        }

        #expect(await fixture.client.requestCount == 1)
        #expect(fixture.builder.status == .failed(error.localizedDescription))
        #expect(!fixture.builder.status.isActivelyIndexing)
        let coverage = try await fixture.builder.coverage()
        #expect(coverage.failedChunks > 0)
        #expect(coverage.readyChunks > 0, "向量失败不影响本地文本可检索")
        #expect(SearchIndexStatus.knowledge(status: fixture.builder.status, coverage: coverage, hasModel: true) == .failed)
        #expect(!(try await fixture.chunks.fetchChunksNeedingEmbedding(limit: 32)).isEmpty,
                "失败分片应已释放 claim，允许用户手动重试")
    }

    @Test("同配置失败后自动刷新只更新文本，手动重试可恢复向量构建")
    func automaticRetriesPauseUntilManualRebuild() async throws {
        let fixture = try await Fixture(error: .modelRequestRejected)
        defer { fixture.cleanup() }
        await fixture.builder.refreshMetadataForKnowledgeRepos()
        await fixture.client.setResponse(.success)

        try await fixture.notes.updateContent(repoId: fixture.repo.id, content: "Keep this new local note searchable", isAIGenerated: false)
        await fixture.builder.refresh(repo: fixture.repo, sources: [.notes])
        await fixture.builder.refreshMetadataForKnowledgeRepos()
        try await fixture.builder.rebuildKnowledgeBase(recordsRefreshSummary: false, userInitiated: false)

        #expect(await fixture.client.requestCount == 1, "后台刷新不能绕过失败暂停")
        #expect(fixture.builder.status == .failed(AIEmbeddingError.modelRequestRejected.localizedDescription))
        let pending = try await fixture.chunks.fetchChunksNeedingEmbedding(limit: 32)
        #expect(pending.contains { $0.content.contains("new local note") }, "暂停向量请求时仍写入新文本")

        try await fixture.builder.rebuildKnowledgeBase()

        #expect(await fixture.client.requestCount > 1)
        #expect(!fixture.builder.status.isActivelyIndexing)
        if case .completed = fixture.builder.status {} else { Issue.record("手动重试成功后应完成") }
        #expect(try await fixture.builder.coverage().failedChunks == 0)
    }

    enum ConfigurationChange: CaseIterable, Sendable {
        case model, provider, endpoint, timeout, credential
    }

    @Test("修改向量配置后自动解除失败暂停", arguments: ConfigurationChange.allCases)
    func changedConfigurationCanRetry(_ change: ConfigurationChange) async throws {
        let fixture = try await Fixture(error: .timedOut)
        defer { fixture.cleanup() }
        await fixture.builder.refreshMetadataForKnowledgeRepos()
        await fixture.client.setResponse(.success)
        switch change {
        case .model:
            fixture.settings.aiEmbeddingTask.modelID = "embed-v2"
        case .provider:
            var profile = fixture.settings.aiProviderProfiles[0]
            profile.id = "other-test-provider"
            fixture.settings.aiProviderProfiles.append(profile)
            fixture.settings.aiEmbeddingTask.providerID = profile.id
            try fixture.keychain.storeAIKey("test-key", forProvider: profile.id)
        case .endpoint:
            fixture.settings.aiProviderProfiles[0].baseURL = "https://other-embedding.invalid/v1"
        case .timeout:
            var parameters = AIModelParameters.embeddingDefault
            parameters.timeoutSeconds = 60
            fixture.settings.aiProviderProfiles[0].models[0].parameters = parameters
        case .credential:
            try fixture.keychain.storeAIKey("replacement-test-key", forProvider: fixture.settings.aiEmbeddingTask.providerID)
        }

        await fixture.builder.refreshMetadataForKnowledgeRepos()

        #expect(await fixture.client.requestCount == 2)
        if case .completed = fixture.builder.status {} else { Issue.record("修改配置后应允许重新向量化") }
        #expect(try await fixture.builder.coverage().failedChunks == 0)
    }

    @Test("取消后的迟到成功或失败都不写回状态或分片", arguments: [false, true])
    func lateResponseAfterCancellationIsIgnored(fails: Bool) async throws {
        let fixture = try await Fixture(error: .modelRequestRejected)
        defer { fixture.cleanup() }
        await fixture.client.setResponse(.suspended)
        let operation = Task { await fixture.builder.refreshMetadataForKnowledgeRepos() }
        await fixture.client.waitUntilRequested()
        #expect(fixture.builder.status.isActivelyIndexing)
        fixture.builder.cancel()
        await fixture.client.completeSuspended(failing: fails)
        await operation.value

        #expect(fixture.builder.status == .idle)
        let pending = try await fixture.chunks.fetchChunksNeedingEmbedding(limit: 32)
        #expect(!pending.isEmpty, "取消后释放 claim，不能把迟到结果写成 ready 或 failed")
        #expect(pending.allSatisfy { $0.embeddingStatus == .pending })

        await fixture.client.setResponse(.success)
        await fixture.builder.refreshMetadataForKnowledgeRepos()
        #expect(await fixture.client.requestCount == 2, "旧请求的失败不能暂停新一轮")
        if case .completed = fixture.builder.status {} else { Issue.record("新一轮应可以正常完成") }
    }

    @Test("排队的内容刷新失败后也必须退出构建态并暂停重复请求")
    func queuedRefreshFailureFinishesStatus() async throws {
        let fixture = try await Fixture(error: .modelRequestRejected)
        defer { fixture.cleanup() }
        await fixture.client.setResponse(.suspended)
        let operation = Task { await fixture.builder.refreshMetadataForKnowledgeRepos() }
        await fixture.client.waitUntilRequested()
        try await fixture.notes.updateContent(repoId: fixture.repo.id, content: "Queued note requires its own vector", isAIGenerated: false)
        await fixture.builder.refresh(repo: fixture.repo, sources: [.notes])
        await fixture.client.setResponse(.failure(.timedOut))
        await fixture.client.completeSuspended(failing: false)
        await operation.value

        #expect(await fixture.client.requestCount == 2)
        #expect(fixture.builder.status == .failed(AIEmbeddingError.timedOut.localizedDescription))
        await fixture.builder.refreshMetadataForKnowledgeRepos()
        #expect(await fixture.client.requestCount == 2)
    }

    /// 每个用例都持有独立 defaults、内存库与测试客户端；不安装全局 URLProtocol stub。
    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let suiteName: String
        let settings: AppSettings
        let keychain: InMemoryKeychain
        let chunks: GRDBRAGChunkRepository
        let notes: GRDBRepoNoteRepository
        let repo: Repo
        let builder: KnowledgeRAGIndexBuilder
        let client: EmbeddingClient

        init(error: AIEmbeddingError) async throws {
            suiteName = "KnowledgeRAGIndexBuilderTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            keychain = InMemoryKeychain()
            settings = AppSettings(defaults: defaults, keychain: keychain)
            let profileID = "test-rag-embedding"
            settings.aiProviderProfiles = [AIProviderProfile(
                id: profileID,
                provider: .openAICompatible,
                baseURL: "https://embedding.invalid/v1",
                models: [
                    AIModelDescriptor(providerID: profileID, name: "embed-v1", capability: .embedding),
                    AIModelDescriptor(providerID: profileID, name: "embed-v2", capability: .embedding)
                ],
                lastTestStatus: .success(modelCount: 2)
            )]
            settings.aiEmbeddingTask.providerID = profileID
            settings.aiEmbeddingTask.modelID = "embed-v1"
            try keychain.storeAIKey("test-key", forProvider: profileID)
            let database = try InMemoryDatabaseManager()
            try await database.insertRepoFixture(id: 1)
            let repos = GRDBRepoRepository(database: database)
            repo = try #require(try await repos.findById(1))
            notes = GRDBRepoNoteRepository(database: database)
            try await notes.updateLibraryState(repoId: 1, state: .inLibrary)
            let readmes = ReadmeRepository(database: database, notificationCenter: NotificationCenter())
            let markdown = "# Installation\nBuild the package with swift build and run the executable locally."
            try await readmes.upsertContent(repoId: 1, content: markdown, at: Date())
            chunks = GRDBRAGChunkRepository(database: database)
            _ = try await chunks.replaceSource(
                repoId: 1, source: .readme,
                drafts: RAGChunkBuilder().buildReadme(repoId: 1, markdown: markdown)
            )
            client = EmbeddingClient(error: error)
            let injectedClient = client
            let configuredSettings = settings
            builder = KnowledgeRAGIndexBuilder(
                chunkRepository: chunks,
                repoRepository: repos,
                readmeRepository: readmes,
                readmeAPI: ReadmeAPI(
                    client: MockGitHubAPIClient(),
                    repository: readmes,
                    trendingRepository: TrendingReadmeRepository(database: database),
                    inflightTracker: ReadmeInflightTracker(),
                    metrics: ReadmeMetrics()
                ),
                noteRepository: notes,
                summaryRepository: GRDBAISummaryRepository(database: database),
                repoTagRepository: GRDBRepoTagRepository(database: database),
                settings: settings,
                entitlementGate: EntitlementGate(entitlementProvider: TestEntitlement(), userIDProvider: { 1 }),
                keychain: keychain,
                embeddingClientFactory: { configuration in
                    let expectedTimeout = try configuredSettings.resolveEmbeddingSelection().parameters.timeoutSeconds
                    #expect(configuration.timeoutInterval == expectedTimeout,
                            "沿用模型请求的超时参数")
                    return injectedClient
                }
            )
        }

        func cleanup() {
            builder.cancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// 仅提供测试权益，避免门控提前返回而掩盖真正的 embedding 状态错误。
    private final class TestEntitlement: ProEntitlementProviding {
        let entitlement = ProEntitlement.testEnvironment
    }

    /// Actor 统计实际请求次数；本文件只测试向量调用，其他协议方法明确拒绝执行。
    private actor EmbeddingClient: AIClientProtocol {
        enum Response: Sendable {
            case failure(AIEmbeddingError), success, suspended
        }
        private var response: Response
        private var pendingResponse: (count: Int, continuation: CheckedContinuation<[[Float]], Error>)?
        private var requestWaiter: CheckedContinuation<Void, Never>?
        private(set) var requestCount = 0

        init(error: AIEmbeddingError) { response = .failure(error) }

        func setResponse(_ response: Response) { self.response = response }

        /// 用 continuation 协调时序，避免依赖任意 sleep 才碰巧覆盖取消和排队路径。
        func waitUntilRequested() async {
            if requestCount > 0 { return }
            await withCheckedContinuation { requestWaiter = $0 }
        }

        func completeSuspended(failing: Bool) {
            guard let pending = pendingResponse else { return }
            pendingResponse = nil
            if failing { pending.continuation.resume(throwing: AIEmbeddingError.timedOut) }
            else { pending.continuation.resume(returning: Array(repeating: [1, 0, 0], count: pending.count)) }
        }

        func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
            requestCount += 1
            switch response {
            case .failure(let error): throw error
            case .success: return Array(repeating: [1, 0, 0], count: inputs.count)
            case .suspended:
                return try await withCheckedThrowingContinuation { continuation in
                    pendingResponse = (inputs.count, continuation)
                    requestWaiter?.resume()
                    requestWaiter = nil
                }
            }
        }

        func embedding(input: String, model: String?) async throws -> [Float] {
            try await embeddings(inputs: [input], model: model)[0]
        }

        func chat(request: AIChatRequest) async throws -> AIChatResponse { throw AIClientError.emptyResponse }
        func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
            throw AIClientError.emptyResponse
        }
        nonisolated func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: AIClientError.emptyResponse) }
        }
        func listModels() async throws -> [AIModelDescriptor] { [] }
        func testConnection() async throws {}
    }
}
