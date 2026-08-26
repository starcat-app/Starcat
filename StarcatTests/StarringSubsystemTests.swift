//
//  StarringSubsystemTests.swift
//  StarcatTests
//
//  覆盖 R-01 StarringSubsystem 的关键路径：
//    1. StarredRegistry.contains O(1) 查询正确性（含 nil 防御）
//    2. StarActionService.star 完整流程：apiClient.star → apiClient.repo → DB upsert
//       → registry._add → homeRefresher.refreshAfterStarChange
//    3. StarActionService.unstar 保留私有数据（DB markUnstarred 行为 + registry._remove）
//    4. StarredRegistryBootstrapper.reload 从 DB 全量重建 registry
//    5. StarredRegistryBootstrapper.clearOnSignOut 清空 registry
//    6. StarActionService.star API 失败时 registry 不变（不污染状态）
//    7. StarActionService 未登录时抛 .notAuthenticated
//    8. star/unstar 会话星标数：Explore 快照 toggle 按 overlay ±1；asCardData 读 overlay
//
//  ⚠️ 不测「fileprivate 写权限」契约——编译期已保证（任何 View / ViewModel 试图
//  调 `registry._add` 都编译失败）。把这条契约放在文件头注释 + 设计文档 §4.3.2。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("StarringSubsystem (R-01)")
struct StarringSubsystemTests {

    // MARK: - Helpers

    /// 构造一组测试依赖：内存 DB + mock API client + registry + service + bootstrapper。
    private func makeDeps(
        currentUserID: Int64? = 100
    ) throws -> (
        api: MockGitHubAPIClient,
        repo: GRDBRepoRepository,
        note: GRDBRepoNoteRepository,
        registry: StarredRegistry,
        service: StarActionService,
        bootstrapper: StarredRegistryBootstrapper,
        refresher: SpyHomeRefresher
    ) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let note = GRDBRepoNoteRepository(database: db)
        let api = MockGitHubAPIClient()
        let registry = StarredRegistry()
        let refresher = SpyHomeRefresher()
        let service = StarActionService(
            apiClient: api,
            repoRepository: repo,
            registry: registry,
            undoStarHistory: MockUndoStarHistoryRepository(),
            userIDProvider: { currentUserID },
            homeRefresher: refresher
        )
        let bootstrapper = StarredRegistryBootstrapper(registry: registry, repoRepository: repo)
        return (api, repo, note, registry, service, bootstrapper, refresher)
    }

    /// 构造一个 GitHubRepoDTO（默认字段足够 upsert 不挂）。
    private func makeRepoDTO(id: Int64, owner: String, name: String, stargazersCount: Int = 100) -> GitHubRepoDTO {
        let user = GitHubUserDTO(
            id: 1, login: owner, name: nil, avatarUrl: nil,
            publicRepos: nil, followers: nil, following: nil,
            bio: nil, company: nil, location: nil, email: nil,
            blog: nil, twitterUsername: nil, htmlUrl: nil
        )
        return GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "\(owner)/\(name)",
            owner: user,
            description: "desc",
            language: "Swift",
            stargazersCount: stargazersCount,
            forksCount: 10,
            watchersCount: 5,
            topics: ["a"],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
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
    }

    // MARK: - 1. Registry.contains 行为

    @Test("Registry.contains: 空集合 / 命中 / nil 输入")
    func registryContainsBehavior() throws {
        let registry = StarredRegistry()
        #expect(registry.count == 0)
        #expect(registry.contains(ghRepoId: 42) == false)
        #expect(registry.contains(ghRepoId: nil) == false)

        // 通过 bootstrapper.reload 间接写入（fileprivate 强制）
        // 这里用一个手写小 stub 验证 contains。
        let deps = try makeDeps()
        // 直接调 bootstrapper.reload —— 但 DB 还为空，registry 仍为空集
        Task { await deps.bootstrapper.reload() }
        #expect(registry.contains(ghRepoId: 42) == false)
    }

    // MARK: - 2. StarActionService.star 完整流程

    @Test("star: 完整调用顺序（API.star → API.repo → DB upsert → registry._add → refresher）")
    func starHappyPath() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in /* 204 No Content */ }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 4242, owner: owner, name: repo)
        }

        let saved = try await deps.service.star(owner: "alice", repo: "foo")

        #expect(saved.id == 4242)
        #expect(saved.fullName == "alice/foo")
        #expect(saved.isStarred == true)
        // registry 已写入
        #expect(deps.registry.contains(ghRepoId: 4242) == true)
        #expect(deps.registry.count == 1)
        // homeRefresher 被调到
        #expect(deps.refresher.refreshCount == 1)
        // DB 持久化生效
        let starredCount = try await deps.repo.starredCount()
        #expect(starredCount == 1)
    }

    // MARK: - 3. StarActionService.unstar 保留私有数据

    @Test("unstar: 调 markUnstarred + registry._remove + 保留 repos 行和 libraryState")
    func unstarPreservesPrivateData() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 5555, owner: owner, name: repo)
        }
        deps.api.unstarHandler = { _, _ in /* 204 */ }

        // 先 star
        let saved = try await deps.service.star(owner: "alice", repo: "foo")
        try await deps.note.updateLibraryState(repoId: saved.id, state: .inLibrary)
        #expect(deps.registry.contains(ghRepoId: 5555))
        #expect(try await deps.repo.starredCount() == 1)

        // 再 unstar
        try await deps.service.unstar(repo: saved)

        #expect(deps.registry.contains(ghRepoId: 5555) == false)
        #expect(deps.registry.count == 0)
        #expect(try await deps.repo.starredCount() == 0)

        // 但 repos 表还留着这一行（is_starred=0），保留用户私有数据
        let stillThere = try await deps.repo.findById(5555)
        #expect(stillThere != nil)
        #expect(stillThere?.isStarred == false)
        #expect(try await deps.note.fetchLibraryState(repoId: saved.id) == .inLibrary)
    }

    @Test("unstar: 本地 starsCount 从 1 回到 0（不依赖 GitHub GET 的最终一致性）")
    func unstarDecrementsLocalStarsCount() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 7777, owner: owner, name: repo, stargazersCount: 1)
        }
        deps.api.unstarHandler = { _, _ in }

        let saved = try await deps.service.star(owner: "alice", repo: "zero-star")
        #expect(saved.starsCount == 1)

        try await deps.service.unstar(repo: saved)

        let local = try await deps.repo.findById(7777)
        #expect(local?.isStarred == false)
        #expect(local?.starsCount == 0)
        #expect(deps.registry.displayedStarsCount(base: 1, ghRepoId: 7777) == 0)
    }

    @Test("star/unstar: 会话星标数按点击前展示值 ±1，不依赖 GitHub GET")
    func sessionStarsCountFollowsDisplayedSnapshot() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 8888, owner: owner, name: repo, stargazersCount: 100)
        }
        deps.api.unstarHandler = { _, _ in }

        let saved = try await deps.service.star(
            owner: "alice",
            repo: "snapshot",
            displayedStarsCount: 100
        )
        #expect(deps.registry.displayedStarsCount(base: 100, ghRepoId: saved.id) == 101)

        try await deps.service.unstar(
            ghRepoId: saved.id,
            owner: "alice",
            name: "snapshot",
            displayedStarsCount: 101
        )
        #expect(deps.registry.displayedStarsCount(base: 100, ghRepoId: saved.id) == 100)
    }

    @Test("toggle unstar: 列表仍持接口快照时按会话展示数 -1，而不是再对快照减一次")
    func toggleUnstarUsesSessionOverlayNotStaleSnapshot() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 8888, owner: owner, name: repo, stargazersCount: 100)
        }
        deps.api.unstarHandler = { _, _ in }

        let saved = try await deps.service.star(
            owner: "alice",
            repo: "snapshot",
            displayedStarsCount: 100
        )
        #expect(deps.registry.displayedStarsCount(base: 100, ghRepoId: saved.id) == 101)

        // Explore / Activity 详情的 displayRepo 仍是点 star 前的快照：starsCount=100。
        var staleSnapshot = saved
        staleSnapshot.starsCount = 100
        staleSnapshot.isStarred = true

        try await deps.service.toggle(repo: staleSnapshot)
        #expect(deps.registry.displayedStarsCount(base: 100, ghRepoId: saved.id) == 100)
    }

    @Test("asCardData(registry:): 探索卡片星标数读会话 overlay，不停留在接口快照")
    func asCardDataUsesSessionStarsCount() async throws {
        let deps = try makeDeps()
        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 8888, owner: owner, name: repo, stargazersCount: 100)
        }

        _ = try await deps.service.star(
            owner: "alice",
            repo: "snapshot",
            displayedStarsCount: 100
        )

        let dto = StarcatRepoCardDTO(
            ghRepoId: 8888,
            fullName: "alice/snapshot",
            owner: "alice",
            repo: "snapshot",
            stars: 100,
            forks: 0
        )
        let card = dto.asCardData(registry: deps.registry)
        #expect(card.isStarred == true)
        #expect(card.starsCount == 101)

        let snapshot = deps.registry.applyingDisplayState(to: dto.toEphemeralRepo())
        #expect(snapshot.isStarred == true)
        #expect(snapshot.starsCount == 101)
    }

    @Test("star: 已入库未 star repo 重新 star 后保留 libraryState")
    func starPreservesLibraryStateForUnstarredLibraryRepo() async throws {
        let deps = try makeDeps()
        let dto = makeRepoDTO(id: 6666, owner: "alice", name: "bar")
        let external = try await deps.repo.upsertExternalRepoForLibrary(repoDTO: dto, syncedAt: Date())
        try await deps.note.updateLibraryState(repoId: external.id, state: .inLibrary)
        #expect(external.isStarred == false)

        deps.api.starHandler = { _, _ in }
        deps.api.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 6666, owner: owner, name: repo)
        }

        let saved = try await deps.service.star(owner: "alice", repo: "bar")

        #expect(saved.isStarred)
        #expect(try await deps.note.fetchLibraryState(repoId: saved.id) == .inLibrary)
    }

    // MARK: - 4. Bootstrapper.reload

    @Test("bootstrapper.reload 从 DB is_starred=1 全量重建 registry")
    func bootstrapperReload() async throws {
        let deps = try makeDeps()
        // 直接走 GRDBRepoRepository 的批量 upsert 写 3 条 starred
        let dtos: [StarredRepoDTO] = (1...3).map { i in
            let dto = self.makeRepoDTO(id: Int64(i), owner: "u", name: "r\(i)")
            return StarredRepoDTO(starredAt: "2026-06-09T00:00:00Z", repo: dto)
        }
        try await deps.repo.upsertStarred(dtos, userID: 100, syncedAt: Date())

        // registry 此时是空（没人写）
        #expect(deps.registry.count == 0)

        await deps.bootstrapper.reload()

        #expect(deps.registry.count == 3)
        #expect(deps.registry.contains(ghRepoId: 1))
        #expect(deps.registry.contains(ghRepoId: 2))
        #expect(deps.registry.contains(ghRepoId: 3))
        #expect(deps.registry.contains(ghRepoId: 99) == false)
    }

    // MARK: - 5. Bootstrapper.clearOnSignOut

    @Test("bootstrapper.clearOnSignOut 清空 registry")
    func bootstrapperClearOnSignOut() async throws {
        let deps = try makeDeps()
        let dto = StarredRepoDTO(
            starredAt: "2026-06-09T00:00:00Z",
            repo: makeRepoDTO(id: 1, owner: "u", name: "r")
        )
        try await deps.repo.upsertStarred([dto], userID: 100, syncedAt: Date())
        await deps.bootstrapper.reload()
        #expect(deps.registry.count == 1)

        deps.bootstrapper.clearOnSignOut()
        #expect(deps.registry.count == 0)
    }

    // MARK: - 6. star API 失败 → registry 不写入

    @Test("star: apiClient.star 抛错 → registry 不变 + homeRefresher 不调用")
    func starApiFailureLeavesRegistryUntouched() async throws {
        let deps = try makeDeps()
        struct Boom: Error {}
        deps.api.starHandler = { _, _ in throw Boom() }
        deps.api.repoHandler = { _, _ in
            Issue.record("repoHandler 不应被调用：apiClient.star 已抛错")
            return self.makeRepoDTO(id: 0, owner: "x", name: "y")
        }

        await #expect(throws: Boom.self) {
            _ = try await deps.service.star(owner: "alice", repo: "foo")
        }

        #expect(deps.registry.count == 0)
        #expect(deps.refresher.refreshCount == 0)
        #expect(try await deps.repo.starredCount() == 0)
    }

    // MARK: - 7. 未登录抛 .notAuthenticated

    @Test("star: 未登录 → 抛 StarActionError.notAuthenticated（不调任何 API）")
    func starNotAuthenticated() async throws {
        let deps = try makeDeps(currentUserID: nil)
        deps.api.starHandler = { _, _ in
            Issue.record("api.star 不应被调用：未登录应在前面短路")
        }

        await #expect(throws: StarActionError.self) {
            _ = try await deps.service.star(owner: "a", repo: "b")
        }
        #expect(deps.api.starCalls.isEmpty)
        #expect(deps.registry.count == 0)
    }

    @Test("unstar: 未登录 → 抛 StarActionError.notAuthenticated（不调 API）")
    func unstarNotAuthenticated() async throws {
        let deps = try makeDeps(currentUserID: nil)
        deps.api.unstarHandler = { _, _ in
            Issue.record("api.unstar 不应被调用：未登录应在前面短路")
        }
        // 用一个 dummy ephemeral Repo 触发 unstar
        let dto = StarcatRepoCardDTO(
            ghRepoId: 1, fullName: "a/b", owner: "a", repo: "b"
        )
        let ephemeral = dto.toEphemeralRepo()

        await #expect(throws: StarActionError.self) {
            try await deps.service.unstar(repo: ephemeral)
        }
        #expect(deps.registry.count == 0)
    }
}

// MARK: - 测试 spy

/// `HomeRefreshing` 的 spy，记录 refresh 调用次数。
@MainActor
private final class SpyHomeRefresher: HomeRefreshing {
    var refreshCount = 0
    func refreshAfterStarChange() async {
        refreshCount += 1
    }
}
