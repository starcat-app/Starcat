//
//  CuratedPublisherSessionTests.swift
//  StarcatTests
//
//  覆盖 Weekly 发布会话的网络边界、批量提交、动态分类、权限与轮询恢复。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台 Weekly 会话", .serialized)
@MainActor
struct CuratedPublisherSessionTests {
    @Test("窗口启动只读取本机凭据且不调用 Weekly")
    func bootstrapDoesNotCallWeekly() async {
        let credentials = CuratedCredentialStoreSpy(storedKey: "stored-admin")
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api, credentials: credentials)

        await session.bootstrap(currentUserID: 20_341_123)

        #expect(session.hasStoredAdminCredential)
        #expect(!session.isAdminConnected)
        #expect(api.fetchSourcesCount == 0)
        #expect(api.fetchedBatchIDs.isEmpty)
    }

    @Test("AI 甄别成功激活发布阶段后才读取 Weekly 分类")
    func activateAfterIdentificationLoadsSources() async {
        let credentials = CuratedCredentialStoreSpy(storedKey: "stored-admin")
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api, credentials: credentials)
        await session.bootstrap(currentUserID: 20_341_123)

        await session.activatePublishing(findings: [Self.finding()], currentUserID: 20_341_123)

        #expect(session.isAdminConnected)
        #expect(session.selectedSourceCode == "ai_intelligence")
        #expect(session.preparedFindings.count == 1)
        #expect(api.fetchSourcesCount == 1)
    }

    @Test("连接验证成功后才保存管理员密钥")
    func connectPersistsOnlyValidatedKey() async {
        let credentials = CuratedCredentialStoreSpy()
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api, credentials: credentials)

        await session.connect(adminKey: " admin-key ", currentUserID: 20_341_123)

        #expect(session.isAdminConnected)
        #expect(credentials.storedKey == "admin-key")
    }

    @Test("非维护者即使直接调用也不能连接或发布")
    func executionLayerRejectsUnauthorizedUser() async {
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]))
        let session = makeSession(api: api)
        session.setPreparedFindings([Self.finding()])

        await session.connect(adminKey: "admin-key", currentUserID: 1)
        await session.publish(currentUserID: 1)

        #expect(!session.isAdminConnected)
        #expect(api.submittedRequests.isEmpty)
    }

    @Test("发布一次提交全部已确认项目并读取终态")
    func publishSubmitsWholeBatch() async {
        let api = CuratedAPIStub(
            sourcesResult: .success([Self.source]),
            acceptance: Self.acceptance(total: 2),
            batches: [Self.successBatch(total: 2)]
        )
        let tracker = CuratedBatchTrackerSpy()
        let session = makeSession(api: api, tracker: tracker)
        await session.connect(adminKey: "admin-key", currentUserID: 20_341_123)
        session.setPreparedFindings([
            Self.finding(),
            Self.finding(id: 2, owner: "openai", name: "openai-python", title: "OpenAI Python")
        ])

        await session.publish(currentUserID: 20_341_123)

        let request = api.submittedRequests.first
        #expect(api.submittedRequests.count == 1)
        #expect(request?.repositories.count == 2)
        #expect(request?.repositories.map(\.owner) == ["openai", "openai"])
        #expect(request?.repositories.first?.sourceURL == "https://example.com/article")
        #expect(tracker.batchID == "batch-1")
        #expect(session.batch?.status == .success)
    }

    @Test("新增分类成功后直接加入列表并选中")
    func createSourceSelectsCreatedCategory() async {
        let created = CuratedPublisherSource(
            code: "developer_tools",
            displayNameZH: "开发工具",
            displayNameEN: "Developer Tools",
            iconKey: "bookmark.fill",
            sortOrder: 20,
            count: 0,
            ingestMode: "manual",
            enabled: true,
            manualImportEnabled: true,
            pending: 0,
            processing: 0,
            retrying: 0,
            discarded: 0
        )
        let api = CuratedAPIStub(sourcesResult: .success([Self.source]), createdSource: created)
        let session = makeSession(api: api)
        await session.connect(adminKey: "admin-key", currentUserID: 20_341_123)

        let succeeded = await session.createSource(
            code: "developer_tools",
            displayNameZH: "开发工具",
            displayNameEN: "Developer Tools",
            currentUserID: 20_341_123
        )

        #expect(succeeded)
        #expect(session.selectedSourceCode == "developer_tools")
        #expect(api.createdSourceRequests == [
            CuratedPublisherSourceCreationRequest(
                code: "developer_tools",
                displayNameZH: "开发工具",
                displayNameEN: "Developer Tools"
            )
        ])
    }

    @Test("轮询遇到瞬时网络错误后继续追踪到终态")
    func pollingRetriesTransientFailure() async {
        let api = CuratedAPIStub(
            sourcesResult: .success([Self.source]),
            batchResults: [
                .success(Self.pendingBatch),
                .failure(URLError(.timedOut)),
                .success(Self.successBatch(total: 1))
            ]
        )
        let session = makeSession(api: api, sleeper: CuratedImmediateSleeper())
        await session.connect(adminKey: "admin-key", currentUserID: 20_341_123)
        session.setPreparedFindings([Self.finding()])

        await session.publish(currentUserID: 20_341_123)
        await waitForIdle(session)

        #expect(session.batch?.status == .success)
        #expect(api.fetchedBatchIDs.count == 3)
        #expect(session.errorMessage == nil)
    }

    private func makeSession(
        api: CuratedAPIStub = CuratedAPIStub(sourcesResult: .success([Self.source])),
        credentials: CuratedCredentialStoreSpy = CuratedCredentialStoreSpy(),
        tracker: CuratedBatchTrackerSpy = CuratedBatchTrackerSpy(),
        sleeper: any CuratedPublisherSleeping = CuratedNeverSleeper()
    ) -> CuratedPublisherSession {
        CuratedPublisherSession(
            api: api,
            credentialStore: credentials,
            batchTracker: tracker,
            sleeper: sleeper
        )
    }

    private func waitForIdle(_ session: CuratedPublisherSession) async {
        for _ in 0..<100 where session.operation != .idle { await Task.yield() }
    }

    private static let source = CuratedPublisherSource(
        code: "ai_intelligence",
        displayNameZH: "AI 情报",
        displayNameEN: "AI Intelligence",
        iconKey: "sparkles",
        sortOrder: 10,
        count: 1,
        ingestMode: "manual",
        enabled: true,
        manualImportEnabled: true,
        pending: 0,
        processing: 0,
        retrying: 0,
        discarded: 0
    )

    private static func acceptance(total: Int) -> CuratedPublisherBatchAcceptance {
        CuratedPublisherBatchAcceptance(
            batchID: "batch-1",
            sourceCode: "ai_intelligence",
            status: .pending,
            total: total,
            duplicateCount: 0,
            createdAt: "2026-08-13T00:00:00Z"
        )
    }

    private static var pendingBatch: CuratedPublisherBatch {
        decodeBatch(status: "pending", total: 1, success: 0)
    }

    private static func successBatch(total: Int) -> CuratedPublisherBatch {
        decodeBatch(status: "success", total: total, success: total)
    }

    private static func decodeBatch(status: String, total: Int, success: Int) -> CuratedPublisherBatch {
        try! JSONDecoder().decode(CuratedPublisherBatch.self, from: Data("""
        {"batch_id":"batch-1","source_code":"ai_intelligence","kind":"manual_import","status":"\(status)","total":\(total),"success":\(success),"discarded":0,"created_at":"2026-08-13T00:00:00Z","updated_at":"2026-08-13T00:00:01Z"}
        """.utf8))
    }

    private static func finding(
        id: Int = 1,
        owner: String = "openai",
        name: String = "codex",
        title: String = "Codex"
    ) -> CuratedProjectFinding {
        let candidate = candidate(id: Int64(id), owner: owner, name: name)
        return CuratedProjectFinding(
            id: id,
            originalText: title,
            title: title,
            sourceURL: URL(string: "https://example.com/article"),
            status: .confirmed,
            reason: "官方仓库",
            repository: candidate,
            candidates: [candidate],
            evidence: []
        )
    }

    private static func candidate(id: Int64, owner: String, name: String) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: id, owner: owner, name: name),
            card: RepoCardViewData(
                ghRepoId: id,
                fullName: "\(owner)/\(name)",
                owner: owner,
                repo: name,
                avatarURL: nil,
                description: "Project",
                language: "Swift",
                starsCount: 100,
                forksCount: 10,
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

private final class CuratedAPIStub: CuratedPublisherAPIProtocol, @unchecked Sendable {
    let sourcesResult: Result<[CuratedPublisherSource], Error>
    let acceptance: CuratedPublisherBatchAcceptance
    let createdSource: CuratedPublisherSource?
    private var batchResults: [Result<CuratedPublisherBatch, Error>]
    private let lock = NSLock()
    private(set) var fetchSourcesCount = 0
    private(set) var submittedRequests: [CuratedPublisherImportRequest] = []
    private(set) var createdSourceRequests: [CuratedPublisherSourceCreationRequest] = []
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
        createdSource: CuratedPublisherSource? = nil,
        batches: [CuratedPublisherBatch] = [],
        batchResults: [Result<CuratedPublisherBatch, Error>]? = nil
    ) {
        self.sourcesResult = sourcesResult
        self.acceptance = acceptance
        self.createdSource = createdSource
        self.batchResults = batchResults ?? batches.map(Result.success)
    }

    func fetchManualSources(adminKey: String) async throws -> [CuratedPublisherSource] {
        lock.withLock { fetchSourcesCount += 1 }
        return try sourcesResult.get()
    }

    func createManualSource(
        _ request: CuratedPublisherSourceCreationRequest,
        adminKey: String
    ) async throws -> CuratedPublisherSource {
        try lock.withLock {
            createdSourceRequests.append(request)
            guard let createdSource else { throw URLError(.badServerResponse) }
            return createdSource
        }
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
            guard !batchResults.isEmpty else { throw URLError(.resourceUnavailable) }
            return try batchResults.removeFirst().get()
        }
    }
}

private final class CuratedCredentialStoreSpy: CuratedPublisherCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var storedKey: String?

    init(storedKey: String? = nil) { self.storedKey = storedKey }

    func loadAdminKey() throws -> String? { lock.withLock { storedKey } }
    func storeAdminKey(_ key: String) throws { lock.withLock { storedKey = key } }
    func deleteAdminKey() throws { lock.withLock { storedKey = nil } }
}

private final class CuratedBatchTrackerSpy: CuratedPublisherBatchTracking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var batchID: String?

    init(batchID: String? = nil) { self.batchID = batchID }

    func loadLastBatchID() -> String? { lock.withLock { batchID } }
    func storeLastBatchID(_ batchID: String) { lock.withLock { self.batchID = batchID } }
}

private struct CuratedNeverSleeper: CuratedPublisherSleeping {
    func sleepBeforeNextPoll() async throws { try await Task.sleep(for: .seconds(60)) }
}

private struct CuratedImmediateSleeper: CuratedPublisherSleeping {
    func sleepBeforeNextPoll() async throws { await Task.yield() }
}
