//
//  SyncManagerTests.swift
//  StarcatTests
//
//  覆盖 SyncManager 的核心同步流转，主要为 W4-4 C1 引入：
//  - .syncing → 撞 NetworkError.rateLimited → 自动等待 → 重试同一页 → 完成
//  - rate limit 第二次撞墙时不再无限重试，会以 .rateLimited(retryAt:) 终态停下
//  - 正常无 rate limit 路径 → .completed
//
//  实现策略：
//  - 用 MockGitHubAPIClient 控制 starredRepos 的返回序列（throw / success 切换）
//  - 用 GRDBRepoRepository + InMemoryDatabaseManager 做真实持久化（避免再写 Mock Repo）
//  - SyncManager 用 rateLimitBufferSeconds: 0 + retryAfter: 0 让等待近乎瞬时完成
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("SyncManager")
struct SyncManagerTests {

    // MARK: - Fixtures

    private func makeDTO(id: Int64) -> StarredRepoDTO {
        let user = GitHubUserDTO(id: 1, login: "tester", name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil)
        let repo = GitHubRepoDTO(
            id: id,
            name: "r\(id)",
            fullName: "tester/r\(id)",
            owner: user,
            description: nil,
            language: "Swift",
            stargazersCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tester/r\(id)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: "2026-05-29T10:00:00Z", repo: repo)
    }

    private func makeOnePageResponse(dtos: [StarredRepoDTO], etag: String? = nil) -> APIResponse<[StarredRepoDTO]> {
        APIResponse(
            value: dtos,
            linkHeader: LinkHeader(nextPage: nil, lastPage: 1),
            rateLimit: .empty,
            statusCode: 200,
            etag: etag
        )
    }

    private func makeSUT() throws -> (SyncManager, MockGitHubAPIClient, GRDBRepoRepository) {
        let mock = MockGitHubAPIClient()
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let sync = SyncManager(apiClient: mock, repository: repo, rateLimitBufferSeconds: 0)
        return (sync, mock, repo)
    }

    /// 自旋等待 state 满足 predicate，避免 sleep 固定时长造成测试不稳。
    /// 超时阈值 5s — 单测里 sleep 加 buffer 都是 0，正常 1~2 次循环就该命中。
    private func waitForState(
        _ sync: SyncManager,
        timeout: TimeInterval = 5,
        condition: @escaping (SyncState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(sync.state) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitForState timed out, state=\(sync.state)")
    }

    /// 等"新的 .completed",与上一次 completion 的 Date 不同才算。
    /// 解决"上一次同步遗留的 .completed 让 waitForState 立刻返回 → 第二次同步实际未跑"的脆弱性。
    private func waitForNewCompletion(_ sync: SyncManager, after prev: Date?, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case let .completed(d) = sync.state, d != prev {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitForNewCompletion timed out, state=\(sync.state)")
    }

    /// 提取当前 .completed 的 Date(供 waitForNewCompletion 比较使用)。
    private func currentCompletionDate(_ sync: SyncManager) -> Date? {
        if case let .completed(d) = sync.state { return d }
        return nil
    }

    // MARK: - Tests

    @Test("迟到的同步页不能恢复本轮已取消的 Star", arguments: [false, true])
    func latePagePreservesLocalUnstar(incremental: Bool) async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 909
        let dtos = [makeDTO(id: 1), makeDTO(id: 2)]
        try await repo.upsertStarred(dtos, userID: userID, syncedAt: Date())
        if incremental {
            try await repo.updateSyncState(userID: userID, starredCount: 2, syncedCount: 2, status: "idle")
        }
        let registry = StarredRegistry()
        let bootstrapper = StarredRegistryBootstrapper(registry: registry, repoRepository: repo)
        await bootstrapper.reload()
        sync.onSyncCompleted = { await bootstrapper.reload() }

        // 请求已经开始后再提交取消操作，随后返回仍包含该仓库的旧页面。
        mock.starredReposHandler = { _, _, _ in
            try await repo.markUnstarred(repoId: 1, userID: userID)
            return self.makeOnePageResponse(dtos: dtos)
        }
        sync.performFullSync(userID: userID, force: !incremental)
        try await waitForState(sync) { if case .completed = $0 { true } else { false } }

        #expect(try await repo.findById(1)?.isStarred == false)
        #expect(try await repo.fetchStarredRepoIDs() == [2])
        #expect(!registry.contains(ghRepoId: 1))
        #expect(sync.progress?.current == 1)
        #expect(sync.progress?.total == 1)
    }

    @Test("全量同步收尾不能移除同步期间新加的 Star")
    func fullSyncPreservesLocalStar() async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 910
        let original = makeDTO(id: 1)
        let added = makeDTO(id: 2)
        try await repo.upsertStarred([original], userID: userID, syncedAt: Date())

        mock.starredReposHandler = { _, _, _ in
            _ = try await repo.upsertSingleStarred(
                repoDTO: added.repo, starredAt: nil, userID: userID, syncedAt: Date()
            )
            return self.makeOnePageResponse(dtos: [original])
        }
        sync.performFullSync(userID: userID, force: true)
        try await waitForState(sync) { if case .completed = $0 { true } else { false } }

        #expect(try await repo.fetchStarredRepoIDs() == [1, 2])
        #expect(sync.progress?.current == 2)
        #expect(sync.progress?.total == 2)
    }

    @Test("正常无 rate limit → .completed")
    func normalSync() async throws {
        let (sync, mock, repo) = try makeSUT()
        let dtos = [makeDTO(id: 1), makeDTO(id: 2)]
        mock.starredReposHandler = { page, _, _ in
            #expect(page == 1)
            return self.makeOnePageResponse(dtos: dtos)
        }

        sync.performFullSync(userID: 42)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        let count = try await repo.starredCount()
        #expect(count == 2)
    }

    @Test("撞 rate limit → 自动等待 → 重试同一页 → .completed")
    func rateLimitedThenRetry() async throws {
        let (sync, mock, repo) = try makeSUT()
        let dtos = [makeDTO(id: 11)]

        // 计数控制：第 1 次抛 rateLimited，第 2 次返回正常数据
        // 注意：actor-isolated mutation 在 @Sendable closure 里需要用 lock 或 atomic；
        // 这里测试单线程跑，直接用引用类型 box 即可。
        let attempts = Counter()
        mock.starredReposHandler = { page, _, _ in
            #expect(page == 1) // 重试时必须还是 page=1
            let n = attempts.increment()
            if n == 1 {
                throw NetworkError.rateLimited(retryAfter: 0)
            }
            return self.makeOnePageResponse(dtos: dtos)
        }

        sync.performFullSync(userID: 99)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        #expect(attempts.value == 2)
        let count = try await repo.starredCount()
        #expect(count == 1)
    }

    @Test("第二次再撞 rate limit → 不再自动等待，停在 .rateLimited")
    func rateLimitedTwiceTerminates() async throws {
        let (sync, mock, _) = try makeSUT()

        let attempts = Counter()
        mock.starredReposHandler = { _, _, _ in
            _ = attempts.increment()
            throw NetworkError.rateLimited(retryAfter: 0)
        }

        sync.performFullSync(userID: 7)
        // 第一次自动重试后第二次依然抛 → 转为终态 .rateLimited
        try await waitForState(sync) { if case .rateLimited = $0 { return true } else { return false } }

        #expect(attempts.value == 2, "应该恰好重试 1 次")
    }

    // MARK: - W4-4 C2 ETag

    @Test("C2: 首次同步不带 ETag,响应 ETag 写入本地")
    func firstSyncSavesETag() async throws {
        let (sync, mock, repo) = try makeSUT()
        let dtos = [makeDTO(id: 100)]
        mock.starredReposHandler = { _, _, ifNoneMatch in
            #expect(ifNoneMatch == nil, "首次同步不应带 If-None-Match")
            return self.makeOnePageResponse(dtos: dtos, etag: "\"abc123\"")
        }

        sync.performFullSync(userID: 555)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        let savedETag = try await repo.fetchStarsETag(userID: 555)
        #expect(savedETag == "\"abc123\"")
    }

    @Test("C2: 第二次同步带上次 ETag,304 早退,不调 upsert")
    func secondSyncHits304AndEarlyReturns() async throws {
        let (sync, mock, repo) = try makeSUT()
        // 预置 ETag
        try await repo.updateStarsETag(userID: 777, etag: "\"prev-etag\"")
        // 预置一行老 repo,验证 304 后本地不被改动
        try await repo.upsertStarred([makeDTO(id: 1)], userID: 777, syncedAt: Date())

        let attempts = Counter()
        mock.starredReposHandler = { _, _, ifNoneMatch in
            _ = attempts.increment()
            #expect(ifNoneMatch == "\"prev-etag\"", "第二次同步应带上次的 ETag")
            throw NetworkError.notModified(etag: "\"prev-etag\"")
        }

        sync.performFullSync(userID: 777)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        #expect(sync.lastRunWroteRepos == false, "304 早退不应标记 wroteRepos")
        #expect(attempts.value == 1, "304 应早退,不应触发分页循环额外请求")
        // 本地数据不应被清空
        let count = try await repo.starredCount()
        #expect(count == 1)
        // ETag 仍是旧值（304 路径未刷新）
        #expect(try await repo.fetchStarsETag(userID: 777) == "\"prev-etag\"")
    }

    @Test("C2: force=true 跳过 ETag,即使本地有 ETag 也走全量")
    func forceTrueSkipsETag() async throws {
        let (sync, mock, repo) = try makeSUT()
        try await repo.updateStarsETag(userID: 888, etag: "\"cached\"")

        let observedHeader = Box<String??>(nil)
        mock.starredReposHandler = { _, _, ifNoneMatch in
            observedHeader.value = ifNoneMatch
            return self.makeOnePageResponse(dtos: [self.makeDTO(id: 1)], etag: "\"fresh\"")
        }

        sync.performFullSync(userID: 888, force: true)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        #expect(observedHeader.value == .some(nil), "force=true 时 If-None-Match 应该是 nil")
        #expect(try await repo.fetchStarsETag(userID: 888) == "\"fresh\"", "新 ETag 应被持久化")
    }

    @Test("启动期 performFullSyncIfStale: lastSyncAt 在 TTL 内则跳过网络")
    func performFullSyncIfStaleSkipsWhenFresh() async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 901
        try await repo.updateSyncState(userID: userID, starredCount: 1, syncedCount: 1, status: "idle")

        mock.starredReposHandler = { _, _, _ in
            Issue.record("不应发起 starredRepos 网络请求")
            return self.makeOnePageResponse(dtos: [self.makeDTO(id: 1)])
        }

        sync.performFullSyncIfStale(userID: userID, maxAge: 300)
        try await Task.sleep(for: .milliseconds(80))

        #expect(sync.state == .idle, "TTL 内应完全跳过 sync")
    }

    @Test("启动期 performFullSyncIfStale: 无 lastSyncAt 时仍走同步")
    func performFullSyncIfStaleRunsWhenNoLastSync() async throws {
        let (sync, mock, _) = try makeSUT()
        mock.starredReposHandler = { _, _, _ in
            self.makeOnePageResponse(dtos: [self.makeDTO(id: 2)], etag: "\"etag-2\"")
        }

        sync.performFullSyncIfStale(userID: 902, maxAge: 300)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        #expect(sync.lastRunWroteRepos == true)
    }

    @Test("正常同步写入后 lastRunWroteRepos 为 true")
    func lastRunWroteReposTrueAfterUpsert() async throws {
        let (sync, mock, _) = try makeSUT()
        mock.starredReposHandler = { _, _, _ in
            self.makeOnePageResponse(dtos: [self.makeDTO(id: 3)])
        }

        sync.performFullSync(userID: 903)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        #expect(sync.lastRunWroteRepos == true)
    }

    @Test("首次完整同步成功应触发数据贡献边沿")
    func fullSyncFiresContributionHook() async throws {
        let (sync, mock, _) = try makeSUT()
        let calls = Counter()
        sync.onFullSyncCompleted = { userID, _ in
            #expect(userID == 904)
            calls.increment()
        }
        mock.starredReposHandler = { _, _, _ in
            self.makeOnePageResponse(dtos: [self.makeDTO(id: 4)])
        }

        sync.performFullSync(userID: 904)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }
        #expect(calls.value == 1)
    }

    @Test("ETag 304 不应触发数据贡献边沿")
    func notModifiedDoesNotFireContributionHook() async throws {
        let (sync, mock, repo) = try makeSUT()
        try await repo.updateStarsETag(userID: 905, etag: "\"same\"")
        let calls = Counter()
        sync.onFullSyncCompleted = { _, _ in calls.increment() }
        mock.starredReposHandler = { _, _, _ in throw NetworkError.notModified(etag: "\"same\"") }

        sync.performFullSync(userID: 905)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }
        #expect(calls.value == 0)
    }

    @Test("200 与 304 都在完成态之后通知旁路，保留手动/自动来源", arguments: [false, true], [false, true])
    func settledHookPreservesManualIntent(notModified: Bool, manual: Bool) async throws {
        let (sync, mock, _) = try makeSUT()
        var coreCompleted = false
        var settledCount = 0
        sync.onSyncCompleted = { coreCompleted = true }
        sync.onSyncSettled = { userID, trigger in
            #expect(userID == 906)
            #expect(coreCompleted)
            #expect((trigger == .manual) == manual)
            if case .completed = sync.state {} else { Issue.record("Follow-up scheduled before Stars completed") }
            settledCount += 1
        }
        mock.starredReposHandler = { _, _, _ in
            if notModified { throw NetworkError.notModified(etag: "same") }
            return self.makeOnePageResponse(dtos: [self.makeDTO(id: 5)])
        }
        sync.performFullSync(userID: 906, trigger: manual ? .manual : .automatic)
        try await waitForState(sync) { if case .completed = $0 { true } else { false } }
        #expect(settledCount == 1)
        #expect(sync.lastRunWroteRepos == !notModified)
    }

    @Test("同帧连续触发只拉取一次")
    func synchronousRequestsAreCoalesced() async throws {
        let (sync, mock, _) = try makeSUT()
        let calls = Counter()
        mock.starredReposHandler = { _, _, _ in
            calls.increment()
            return self.makeOnePageResponse(dtos: [self.makeDTO(id: 6)])
        }
        sync.performFullSync(userID: 907, trigger: .manual)
        sync.performFullSync(userID: 907, trigger: .manual)
        sync.performFullSync(userID: 907, trigger: .manual)
        try await waitForState(sync) { if case .completed = $0 { true } else { false } }
        #expect(calls.value == 1)
    }

    @Test("取消后切库屏障仍等待旧核心收尾，取消与失败不派发后台重试")
    func cancelledSyncDoesNotScheduleFollowUp() async throws {
        let (sync, mock, _) = try makeSUT()
        let gate = SyncCompletionTestGate()
        defer { gate.open() }
        var enteredCore = false
        var settledCount = 0
        var stopped = false
        sync.onSyncCompleted = { enteredCore = true; await gate.wait() }
        sync.onSyncSettled = { _, _ in settledCount += 1 }
        mock.starredReposHandler = { _, _, _ in self.makeOnePageResponse(dtos: [self.makeDTO(id: 7)]) }
        sync.performFullSync(userID: 908, trigger: .manual)
        let deadline = Date().addingTimeInterval(3)
        while !enteredCore, Date() < deadline { await Task.yield() }
        #expect(enteredCore)
        sync.cancel()
        let stopping = Task { await sync.cancelAndWait(); stopped = true }
        await Task.yield()
        #expect(!stopped)
        gate.open()
        await stopping.value
        #expect(sync.state == .idle)
        #expect(settledCount == 0)

        mock.starredReposHandler = { _, _, _ in throw NetworkError.unauthorized }
        sync.performFullSync(userID: 908, trigger: .manual)
        try await waitForState(sync) { if case .failed = $0 { true } else { false } }
        #expect(settledCount == 0)
    }
}

/// 核心回调的可控挂起点；不响应取消，以验证必须等待迟到的回调退出后才能切库。
@MainActor
private final class SyncCompletionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// 引用类型 box,用于 @Sendable handler 闭包里捕获并修改值类型(配合 Counter 一起做测试观察用)。
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ initial: T) { value = initial }
}

// MARK: - W4-4 C3 增量同步测试

extension SyncManagerTests {

    /// 构造 starred_at 可控的 DTO,便于做 cutoff 时间比较。
    private func makeDTO(id: Int64, starredAt: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(id: 1, login: "tester", name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil)
        let repo = GitHubRepoDTO(
            id: id, name: "r\(id)", fullName: "tester/r\(id)", owner: user,
            description: nil, language: "Swift",
            stargazersCount: 0, forksCount: 0, watchersCount: 0,
            topics: [], license: nil, homepage: nil,
            htmlUrl: "https://github.com/tester/r\(id)", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, fork: false, archived: false,
            pushedAt: nil, createdAt: nil, updatedAt: nil,
            openIssuesCount: nil, defaultBranch: nil,
            disabled: nil, isTemplate: nil, score: nil
        )
        return StarredRepoDTO(starredAt: starredAt, repo: repo)
    }

    /// 多页响应(允许指定 nextPage)。
    private func makePageResponse(dtos: [StarredRepoDTO], nextPage: Int?, etag: String? = nil) -> APIResponse<[StarredRepoDTO]> {
        APIResponse(
            value: dtos,
            linkHeader: LinkHeader(nextPage: nextPage, lastPage: nextPage),
            rateLimit: .empty,
            statusCode: 200,
            etag: etag
        )
    }

    @Test("C3: 有 lastSyncAt 时,遇到 starred_at <= cutoff 即停止后续页拉取")
    func incrementalStopsAtCutoff() async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 4242

        // baseline:全量同步建立 lastSyncAt
        mock.starredReposHandler = { page, _, _ in
            #expect(page == 1)
            return self.makePageResponse(dtos: [self.makeDTO(id: 1, starredAt: "2026-05-29T00:00:00Z")], nextPage: nil, etag: "\"v1\"")
        }
        sync.performFullSync(userID: userID)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }
        #expect(try await repo.starredCount() == 1)

        // 第二次同步,模拟"新增 1 条" + 边界页含 1 条 <= cutoff
        let attemptCount = Counter()
        mock.starredReposHandler = { page, _, _ in
            _ = attemptCount.increment()
            if page == 1 {
                return self.makePageResponse(dtos: [
                    self.makeDTO(id: 2, starredAt: "2099-01-01T00:00:00Z"), // 新
                    self.makeDTO(id: 1, starredAt: "2026-05-29T00:00:00Z")  // 旧(<= cutoff)
                ], nextPage: 2, etag: "\"v2\"")
            }
            Issue.record("增量模式不应触发 page 2 请求, page=\(page)")
            return self.makePageResponse(dtos: [], nextPage: nil)
        }
        let prev = currentCompletionDate(sync)
        sync.performFullSync(userID: userID)
        try await waitForNewCompletion(sync, after: prev)

        #expect(attemptCount.value == 1, "增量模式 page 1 边界后应停止,不再请求 page 2")
        #expect(try await repo.starredCount() == 2)
    }

    @Test("C3: 增量模式不调 markUnstarredExcept(本地 unstar 不被覆盖)")
    func incrementalDoesNotMarkUnstarred() async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 9999

        // baseline:写入 repo 1, 2
        mock.starredReposHandler = { page, _, _ in
            #expect(page == 1)
            return self.makePageResponse(dtos: [
                self.makeDTO(id: 1, starredAt: "2026-05-29T10:00:00Z"),
                self.makeDTO(id: 2, starredAt: "2026-05-29T09:00:00Z")
            ], nextPage: nil, etag: "\"e1\"")
        }
        sync.performFullSync(userID: userID)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }
        #expect(try await repo.starredCount() == 2)

        // 第二次同步:远端无 repo 2,新增 repo 3。增量模式不调 markUnstarredExcept → repo 2 保留
        mock.starredReposHandler = { _, _, _ in
            return self.makePageResponse(dtos: [
                self.makeDTO(id: 3, starredAt: "2099-12-31T23:59:59Z"),
                self.makeDTO(id: 1, starredAt: "2026-05-29T10:00:00Z")
            ], nextPage: nil, etag: "\"e2\"")
        }
        let prev = currentCompletionDate(sync)
        sync.performFullSync(userID: userID)
        try await waitForNewCompletion(sync, after: prev)

        #expect(try await repo.starredCount() == 3)
    }

    @Test("增量同步成功不应触发数据贡献边沿")
    func incrementalDoesNotFireContributionHook() async throws {
        let (sync, mock, _) = try makeSUT()
        let userID: Int64 = 10_001
        mock.starredReposHandler = { _, _, _ in
            self.makePageResponse(
                dtos: [self.makeDTO(id: 1, starredAt: "2026-05-29T00:00:00Z")],
                nextPage: nil
            )
        }
        sync.performFullSync(userID: userID)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }

        let calls = Counter()
        sync.onFullSyncCompleted = { _, _ in calls.increment() }
        let previous = currentCompletionDate(sync)
        mock.starredReposHandler = { _, _, _ in
            self.makePageResponse(
                dtos: [self.makeDTO(id: 2, starredAt: "2099-01-01T00:00:00Z")],
                nextPage: nil
            )
        }
        sync.performFullSync(userID: userID)
        try await waitForNewCompletion(sync, after: previous)

        #expect(calls.value == 0)
    }

    @Test("C3: force=true 走全量,markUnstarredExcept 会清除消失的 repo")
    func forceFullSyncMarksUnstarred() async throws {
        let (sync, mock, repo) = try makeSUT()
        let userID: Int64 = 1212

        mock.starredReposHandler = { _, _, _ in
            self.makePageResponse(dtos: [
                self.makeDTO(id: 1, starredAt: "2026-05-29T10:00:00Z"),
                self.makeDTO(id: 2, starredAt: "2026-05-29T09:00:00Z")
            ], nextPage: nil, etag: "\"e1\"")
        }
        sync.performFullSync(userID: userID)
        try await waitForState(sync) { if case .completed = $0 { return true } else { return false } }
        #expect(try await repo.starredCount() == 2)

        // force=true,远端只返回 repo 1
        mock.starredReposHandler = { _, _, ifNoneMatch in
            #expect(ifNoneMatch == nil, "force 时应跳过 If-None-Match")
            return self.makePageResponse(dtos: [
                self.makeDTO(id: 1, starredAt: "2026-05-29T10:00:00Z")
            ], nextPage: nil, etag: "\"e2\"")
        }
        let prev = currentCompletionDate(sync)
        sync.performFullSync(userID: userID, force: true)
        try await waitForNewCompletion(sync, after: prev)

        #expect(try await repo.starredCount() == 1, "force 全量应清除消失的 repo 2")
    }
}

/// 引用类型计数器，让 @Sendable handler 闭包能在不引入 actor 隔离的前提下做自增。
/// 仅用于测试：单测内串行调用，竞态不是问题；显式 @unchecked Sendable 关掉编译器警告。
final class Counter: @unchecked Sendable {
    private(set) var value: Int = 0
    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
