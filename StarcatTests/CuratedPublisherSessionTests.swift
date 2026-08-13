//
//  CuratedPublisherSessionTests.swift
//  StarcatTests
//
//  覆盖精选发布状态机的权限守卫、编辑失效、连接持久化、提交与恢复。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台会话", .serialized)
@MainActor
struct CuratedPublisherSessionTests {
    @Test("连接验证成功后才保存管理员密钥并选择首个来源")
    func connectPersistsOnlyValidatedKey() async {
        let credentials = CuratedCredentialStoreSpy()
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api, credentials: credentials)

        await session.connect(adminKey: " admin-key ", currentUserID: 20_341_123)

        #expect(session.isAdminConnected)
        #expect(session.selectedSourceCode == "ai_intelligence")
        #expect(credentials.storedKey == "admin-key")
    }

    @Test("非维护者即使直接调用也不能连接或发布")
    func executionLayerRejectsUnauthorizedUser() async {
        let credentials = CuratedCredentialStoreSpy()
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api, credentials: credentials)

        await session.connect(adminKey: "admin-key", currentUserID: 1)
        await session.publish(currentUserID: 1)

        #expect(!session.isAdminConnected)
        #expect(credentials.storedKey == nil)
        #expect(api.submittedRequests.isEmpty)
    }

    @Test("编辑最终 URL 会撤销官方核验与人工确认")
    func editingFinalURLInvalidatesVerification() async {
        let candidate = Self.candidate()
        let resolver = CuratedResolverStub(candidate: candidate)
        let session = makeSession(resolver: resolver)
        session.clue = "openai/codex"
        await session.resolveClue(externalSearchProvider: .anySearch)
        session.hasConfirmedOfficialRepository = true
        #expect(session.verifiedCandidate != nil)

        session.finalGitHubURL = "https://github.com/openai/openai-python"

        #expect(session.verifiedCandidate == nil)
        #expect(!session.hasConfirmedOfficialRepository)
        #expect(!session.canPublish)
    }

    @Test("发布提交稳定契约并读取终态")
    func publishSubmitsAndLoadsTerminalBatch() async {
        let api = CuratedAPIStub(
            sourcesResult: .success([Self.source]),
            acceptance: Self.acceptance,
            batches: [Self.successBatch]
        )
        let tracker = CuratedBatchTrackerSpy()
        let session = makeSession(api: api, tracker: tracker)
        await session.connect(adminKey: "admin-key", currentUserID: 20_341_123)
        session.clue = "great coding agent"
        await session.resolveClue(externalSearchProvider: .anySearch)
        session.displayTitle = "Codex"
        session.sourceURL = "https://example.com/article"
        session.hasConfirmedOfficialRepository = true

        await session.publish(currentUserID: 20_341_123)

        #expect(api.submittedRequests.count == 1)
        #expect(api.submittedRequests.first?.sourceCode == "ai_intelligence")
        #expect(api.submittedRequests.first?.repositories.first?.owner == "openai")
        #expect(api.submittedRequests.first?.repositories.first?.sourceURL == "https://example.com/article")
        #expect(tracker.batchID == "batch-1")
        #expect(session.batch?.status == .success)
        #expect(session.operation == .idle)
    }

    @Test("启动时用安全存储密钥恢复最近批次")
    func bootstrapRestoresLastBatch() async {
        let credentials = CuratedCredentialStoreSpy(storedKey: "stored-admin")
        let tracker = CuratedBatchTrackerSpy(batchID: "batch-1")
        let api = CuratedAPIStub(
            sourcesResult: .success([Self.source]),
            batches: [Self.successBatch]
        )
        let session = makeSession(api: api, credentials: credentials, tracker: tracker)

        await session.bootstrap(currentUserID: 20_341_123)

        #expect(session.isAdminConnected)
        #expect(session.batch?.batchID == "batch-1")
        #expect(api.fetchedBatchIDs == ["batch-1"])
    }

    private func makeSession(
        resolver: CuratedResolverStub = CuratedResolverStub(candidate: Self.candidate()),
        api: CuratedAPIStub = CuratedAPIStub(sourcesResult: .success([Self.source])),
        credentials: CuratedCredentialStoreSpy = CuratedCredentialStoreSpy(),
        tracker: CuratedBatchTrackerSpy = CuratedBatchTrackerSpy()
    ) -> CuratedPublisherSession {
        CuratedPublisherSession(
            resolver: resolver,
            api: api,
            credentialStore: credentials,
            batchTracker: tracker,
            sleeper: CuratedNeverSleeper()
        )
    }

    private static let source = CuratedPublisherSource(
        code: "ai_intelligence",
        displayNameZH: "AI 情报",
        displayNameEN: "AI Intelligence",
        iconKey: "sparkles",
        sortOrder: 1,
        count: 1,
        ingestMode: "manual",
        enabled: true,
        manualImportEnabled: true,
        pending: 0,
        processing: 0,
        retrying: 0,
        discarded: 0
    )

    private static let acceptance = CuratedPublisherBatchAcceptance(
        batchID: "batch-1",
        sourceCode: "ai_intelligence",
        status: .pending,
        total: 1,
        duplicateCount: 0,
        createdAt: "2026-08-13T00:00:00Z"
    )

    private static var successBatch: CuratedPublisherBatch {
        try! JSONDecoder().decode(CuratedPublisherBatch.self, from: Data("""
        {"batch_id":"batch-1","source_code":"ai_intelligence","kind":"manual_import","status":"success","total":1,"success":1,"discarded":0,"created_at":"2026-08-13T00:00:00Z","finished_at":"2026-08-13T00:00:01Z","updated_at":"2026-08-13T00:00:01Z"}
        """.utf8))
    }

    private static func candidate() -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 1, owner: "openai", name: "codex"),
            card: RepoCardViewData(
                ghRepoId: 1,
                fullName: "openai/codex",
                owner: "openai",
                repo: "codex",
                avatarURL: nil,
                description: "Coding agent",
                language: "Rust",
                starsCount: 10_000,
                forksCount: 500,
                isArchived: false,
                isFork: false,
                isPrivate: false,
                isStarred: false,
                isInLibrary: false,
                badge: nil,
                weeklySources: [],
                weeklySourceLabel: nil,
                inlineMetadata: nil,
                footerMetadata: nil,
                readStatus: nil,
                openSSFScore: nil,
                healthBadge: nil
            ),
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )
    }
}

private struct CuratedResolverStub: CuratedProjectResolving {
    let candidate: RepositoryCandidate

    func resolve(
        clue: String,
        externalSearchProvider: ExternalSearchProviderID
    ) async throws -> CuratedProjectResolution {
        CuratedProjectResolution(
            candidates: [candidate],
            usedWebSearch: false,
            didFallbackFromWebSearch: false
        )
    }

    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate {
        candidate
    }
}

private final class CuratedAPIStub: CuratedPublisherAPIProtocol, @unchecked Sendable {
    let sourcesResult: Result<[CuratedPublisherSource], Error>
    let acceptance: CuratedPublisherBatchAcceptance
    private var batches: [CuratedPublisherBatch]
    private let lock = NSLock()
    private(set) var submittedRequests: [CuratedPublisherImportRequest] = []
    private(set) var fetchedBatchIDs: [String] = []

    init(
        sourcesResult: Result<[CuratedPublisherSource], Error>,
        acceptance: CuratedPublisherBatchAcceptance = CuratedPublisherBatchAcceptance(
            batchID: "batch-1",
            sourceCode: "ai_intelligence",
            status: .pending,
            total: 1,
            duplicateCount: 0,
            createdAt: "2026-08-13T00:00:00Z"
        ),
        batches: [CuratedPublisherBatch] = []
    ) {
        self.sourcesResult = sourcesResult
        self.acceptance = acceptance
        self.batches = batches
    }

    func fetchManualSources(adminKey: String) async throws -> [CuratedPublisherSource] {
        try sourcesResult.get()
    }

    func submit(
        _ request: CuratedPublisherImportRequest,
        adminKey: String
    ) async throws -> CuratedPublisherBatchAcceptance {
        lock.withLock { submittedRequests.append(request) }
        return acceptance
    }

    func fetchBatch(id: String, adminKey: String) async throws -> CuratedPublisherBatch {
        try lock.withLock {
            fetchedBatchIDs.append(id)
            guard !batches.isEmpty else { throw URLError(.resourceUnavailable) }
            return batches.removeFirst()
        }
    }
}

private final class CuratedCredentialStoreSpy: CuratedPublisherCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var storedKey: String?

    init(storedKey: String? = nil) {
        self.storedKey = storedKey
    }

    func loadAdminKey() throws -> String? { lock.withLock { storedKey } }
    func storeAdminKey(_ key: String) throws { lock.withLock { storedKey = key } }
    func deleteAdminKey() throws { lock.withLock { storedKey = nil } }
}

private final class CuratedBatchTrackerSpy: CuratedPublisherBatchTracking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var batchID: String?

    init(batchID: String? = nil) {
        self.batchID = batchID
    }

    func loadLastBatchID() -> String? { lock.withLock { batchID } }
    func storeLastBatchID(_ batchID: String) { lock.withLock { self.batchID = batchID } }
}

private struct CuratedNeverSleeper: CuratedPublisherSleeping {
    func sleepBeforeNextPoll() async throws {
        try await Task.sleep(for: .seconds(60))
    }
}
