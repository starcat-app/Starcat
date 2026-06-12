//
//  BatchStarServiceTests.swift
//  StarcatTests
//
//  覆盖 W12 toolbar 专项 PR-3 引入的 `BatchStarService`：
//    1. unstar 时 registry 已为未 star 的目标 → 静默 skip
//    2. star 时 registry 已 star 的目标 → 静默 skip
//    3. 串行执行 + 节流（concurrent API 调用永远不发生）
//    4. 连续失败 >= maxConsecutiveFailures 时整体停
//    5. cancel() 立刻退出循环，不再发新请求
//    6. 空 targets / 运行中 enqueue 静默 no-op
//
//  ⚠️ 不测「写入路径唯一」契约：BatchStarService 内部只调 StarActionService 公开
//  方法（star / unstar），编译器已保证它无法直接写 registry。本 suite 关注调度行为。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("BatchStarService (W12 PR-3)")
struct BatchStarServiceTests {

    // MARK: - Helpers

    /// 测试用复合依赖。直接复用 StarringSubsystem 的真实路径（DB + registry +
    /// StarActionService），只 mock GitHub API。
    private func makeDeps(currentUserID: Int64? = 100) throws -> (
        api: MockGitHubAPIClient,
        repo: GRDBRepoRepository,
        registry: StarredRegistry,
        starService: StarActionService,
        batchService: BatchStarService
    ) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let api = MockGitHubAPIClient()
        let registry = StarredRegistry()
        let starService = StarActionService(
            apiClient: api,
            repoRepository: repo,
            registry: registry,
            userIDProvider: { currentUserID },
            homeRefresher: nil
        )
        let batch = BatchStarService(starActionService: starService, registry: registry)
        // 测试态：节流压到 0，加速循环；连续失败容忍度保留默认 5。
        batch.throttleDelay = .zero
        return (api, repo, registry, starService, batch)
    }

    /// 简易 Repo 工厂：默认 is_starred 由 DB 写入路径决定，本辅助仅构造对象。
    private func makeRepo(id: Int64, owner: String = "u", name: String, isStarred: Bool = true) -> Repo {
        Repo(
            id: id,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    /// 把 repos 先 upsert 进 DB + registry，模拟「已 star」初态。
    private func seedStarred(repos: [Repo], deps: (api: MockGitHubAPIClient, repo: GRDBRepoRepository, registry: StarredRegistry, starService: StarActionService, batchService: BatchStarService)) async throws {
        let dtos: [StarredRepoDTO] = repos.map { r in
            let user = GitHubUserDTO(
                id: 1, login: r.owner, name: nil, avatarUrl: nil,
                publicRepos: nil, followers: nil, following: nil,
                bio: nil, company: nil, location: nil, email: nil,
                blog: nil, twitterUsername: nil, htmlUrl: nil
            )
            let dto = GitHubRepoDTO(
                id: r.id, name: r.name, fullName: r.fullName, owner: user,
                description: r.description, language: r.language,
                stargazersCount: r.starsCount, forksCount: r.forksCount,
                watchersCount: r.watchersCount, topics: nil,
                license: nil, homepage: r.homepage, htmlUrl: r.htmlUrl,
                cloneUrl: r.cloneUrl, sshUrl: r.sshUrl,
                isPrivate: r.isPrivate, fork: r.isFork, archived: r.isArchived,
                pushedAt: r.pushedAt, createdAt: r.createdAt, updatedAt: r.updatedAt
            )
            return StarredRepoDTO(starredAt: "2026-06-12T00:00:00Z", repo: dto)
        }
        try await deps.repo.upsertStarred(dtos, userID: 100, syncedAt: Date())
        let snapshot = try await deps.repo.fetchStarredRepoIDs()
        // 不能直接调 registry._add（fileprivate）；走 bootstrapper.reload 模拟。
        let boot = StarredRegistryBootstrapper(registry: deps.registry, repoRepository: deps.repo)
        await boot.reload()
        _ = snapshot
    }

    /// 等待 batchService.isRunning 翻回 false。
    /// 节流为 0 时通常 ~ms 级，给 2s 兜底。
    private func waitForFinish(_ service: BatchStarService) async throws {
        let deadline = Date().addingTimeInterval(2)
        while service.isRunning {
            if Date() > deadline {
                Issue.record("BatchStarService never finished within 2s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. skip 已为目标态

    @Test("unstar: registry 中未 star 的目标静默 skip，不发 API 请求")
    func unstarSkipsAlreadyUnstarred() async throws {
        let deps = try makeDeps()
        // 不 seed：registry 空，3 个 repo 在 service 视角是「未 star」→ unstar 应全部 skip
        let targets = (1...3).map { BatchStarTarget.from(repo: makeRepo(id: Int64($0), name: "r\($0)", isStarred: false)) }
        deps.api.unstarHandler = { _, _ in
            Issue.record("unstar API should not be called for skipped targets")
        }

        deps.batchService.enqueue(targets: targets, action: .unstar)
        try await waitForFinish(deps.batchService)

        let p = try #require(deps.batchService.completionSummary)
        #expect(p.action == .unstar)
        #expect(p.total == 3)
        #expect(p.skipped == 3)
        #expect(p.succeeded == 0)
        #expect(p.failed == 0)
        #expect(deps.api.unstarCalls.isEmpty)
    }

    @Test("star: registry 中已 star 的目标静默 skip")
    func starSkipsAlreadyStarred() async throws {
        let deps = try makeDeps()
        let repos = (1...2).map { makeRepo(id: Int64($0), name: "r\($0)") }
        try await seedStarred(repos: repos, deps: deps)
        #expect(deps.registry.count == 2)

        deps.api.starHandler = { _, _ in
            Issue.record("star API should not be called for already-starred targets")
        }
        deps.batchService.enqueue(targets: repos.map(BatchStarTarget.from(repo:)), action: .star)
        try await waitForFinish(deps.batchService)

        let p = try #require(deps.batchService.completionSummary)
        #expect(p.skipped == 2)
        #expect(p.succeeded == 0)
        #expect(deps.api.starCalls.isEmpty)
    }

    // MARK: - 2. 真正调 API：unstar 走完整链路

    @Test("unstar: 已 star 的目标按顺序调 API.unstar + 写入 DB + registry._remove")
    func unstarHappyPath() async throws {
        let deps = try makeDeps()
        let repos = (1...3).map { makeRepo(id: Int64($0), name: "r\($0)") }
        try await seedStarred(repos: repos, deps: deps)
        #expect(deps.registry.count == 3)

        deps.api.unstarHandler = { _, _ in /* 204 */ }
        deps.batchService.enqueue(targets: repos.map(BatchStarTarget.from(repo:)), action: .unstar)
        try await waitForFinish(deps.batchService)

        let p = try #require(deps.batchService.completionSummary)
        #expect(p.succeeded == 3)
        #expect(p.skipped == 0)
        #expect(p.failed == 0)
        #expect(deps.registry.count == 0)
        #expect(deps.api.unstarCalls.count == 3)
    }

    // MARK: - 3. 串行：永远不并发调 API

    @Test("串行执行：unstar 调用按入参顺序逐条发生，永远不并发")
    func serialNotConcurrent() async throws {
        let deps = try makeDeps()
        let repos = (1...5).map { makeRepo(id: Int64($0), name: "r\($0)") }
        try await seedStarred(repos: repos, deps: deps)

        let tracker = ConcurrencyTracker()
        deps.api.unstarHandler = { _, _ in
            tracker.enter()
            try? await Task.sleep(for: .milliseconds(20))
            tracker.exit()
        }

        deps.batchService.enqueue(targets: repos.map(BatchStarTarget.from(repo:)), action: .unstar)
        try await waitForFinish(deps.batchService)

        #expect(tracker.peak == 1, "并发度必须始终 == 1（串行）")
    }

    // MARK: - 4. 连续失败 >= maxConsecutiveFailures 时中止

    @Test("连续失败 >= maxConsecutiveFailures 整体停（剩余目标不再 API 调用）")
    func abortAfterConsecutiveFailures() async throws {
        let deps = try makeDeps()
        deps.batchService.maxConsecutiveFailures = 2
        let repos = (1...5).map { makeRepo(id: Int64($0), name: "r\($0)") }
        try await seedStarred(repos: repos, deps: deps)

        struct Boom: Error {}
        deps.api.unstarHandler = { _, _ in throw Boom() }

        deps.batchService.enqueue(targets: repos.map(BatchStarTarget.from(repo:)), action: .unstar)
        try await waitForFinish(deps.batchService)

        let p = try #require(deps.batchService.completionSummary)
        // 连续 2 次失败后立即停 → 只发了 2 次 API
        #expect(deps.api.unstarCalls.count == 2)
        #expect(p.failed == 2)
        #expect(p.succeeded == 0)
        // 注意：抛错的也会被记入 completed（catch 分支后 snapshot.completed += 1）
    }

    // MARK: - 5. cancel 立刻退出

    @Test("cancel(): 取消后不再发起新请求")
    func cancelStopsProcessing() async throws {
        let deps = try makeDeps()
        deps.batchService.throttleDelay = .milliseconds(40)
        let repos = (1...20).map { makeRepo(id: Int64($0), name: "r\($0)") }
        try await seedStarred(repos: repos, deps: deps)

        deps.api.unstarHandler = { _, _ in
            try? await Task.sleep(for: .milliseconds(20))
        }
        deps.batchService.enqueue(targets: repos.map(BatchStarTarget.from(repo:)), action: .unstar)
        try await Task.sleep(for: .milliseconds(80))
        deps.batchService.cancel()
        try await waitForFinish(deps.batchService)

        let p = try #require(deps.batchService.completionSummary)
        #expect(p.wasCancelled == true)
        #expect(deps.api.unstarCalls.count < 20)
    }

    // MARK: - 6. 边界

    @Test("空 targets：no-op，不修改 isRunning / completionSummary")
    func emptyTargetsNoOp() async throws {
        let deps = try makeDeps()
        deps.batchService.enqueue(targets: [], action: .unstar)
        #expect(deps.batchService.isRunning == false)
        #expect(deps.batchService.completionSummary == nil)
    }
}

// MARK: - 测试 helper：并发计数

/// 线程安全的"当前进行中并发数 + 历史峰值"追踪器。
/// 用于断言 `BatchStarService` 永远不并发调 API（peak 必须始终为 1）。
///
/// 不用 `@MainActor`：mock API handler 是 `async throws` 在非 MainActor 上下文跑，
/// 直接 lock 更省事；也避免 MainActor isolation hop 干扰被测的串行节奏。
private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var _peak = 0

    func enter() {
        lock.lock()
        current += 1
        if current > _peak { _peak = current }
        lock.unlock()
    }

    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return _peak
    }
}
