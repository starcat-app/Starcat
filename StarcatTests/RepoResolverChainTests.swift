//
//  RepoResolverChainTests.swift
//  StarcatTests
//
//  覆盖 R-01 RepoResolver 的关键路径测试：
//  1. LocalRepoSource 命中 → isLocalHit = true，链停止询问
//  2. BackendHintRepoSource 命中（local 未命中）→ isLocalHit = false，hint owner/name 大小写匹配
//  3. BackendHintRepoSource 跳过（owner / name 大小写不匹配）→ 继续问下一个
//  4. 单源 throws 不击穿链 → catch + 跳过 + 继续
//  5. 全部前置源失败 → MinimalRepoSource 永远命中 → isMinimal = true
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("RepoResolver Chain (R-01)")
struct RepoResolverChainTests {

    // MARK: - 1. Local hit

    @Test("LocalRepoSource 命中 → isLocalHit = true，后续 source 不被调用")
    func localSourceHitWins() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        // 写一条 starred 进 DB
        let dto = StarredRepoDTO(
            starredAt: "2026-06-09T00:00:00Z",
            repo: makeRepoDTO(id: 7, owner: "alice", name: "foo")
        )
        try await repoRepo.upsertStarred([dto], userID: 100, syncedAt: Date())

        let countingApi = CountingMockClient()
        // R-01 v1.2 后 BackendAggregateRepoSource 接 WeeklyAPI 真实网络调用了；
        // 本套件测的是 chain 行为而非 aggregate，故把它从测试链里去掉
        // （aggregate 单独测试见 BackendAggregateRepoSourceTests）。
        let resolver = RepoResolver(chain: [
            LocalRepoSource(repository: repoRepo),
            BackendHintRepoSource(),
            GitHubFallbackRepoSource(apiClient: countingApi),
            MinimalRepoSource()
        ])

        let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: nil)
        #expect(resolution.sourceName == "LocalRepoSource")
        #expect(resolution.isLocalHit == true)
        #expect(resolution.isMinimal == false)
        #expect(resolution.repo.id == 7)
        // 后续源不被调用：API client 计数应该是 0
        #expect(countingApi.repoCalls == 0)
    }

    // MARK: - 2. Hint hit (local miss)

    @Test("Hint 命中：本地无、hint 大小写匹配 → isLocalHit = false（来自 BackendHintRepoSource）")
    func hintSourceHit() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let countingApi = CountingMockClient()
        let resolver = RepoResolver(chain: [
            LocalRepoSource(repository: repoRepo),
            BackendHintRepoSource(),

            GitHubFallbackRepoSource(apiClient: countingApi),
            MinimalRepoSource()
        ])

        let hint = StarcatRepoCardDTO(
            ghRepoId: 4242, fullName: "alice/foo", owner: "alice", repo: "foo",
            stars: 999, forks: 12
        )
        let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: hint)
        #expect(resolution.sourceName == "BackendHintRepoSource")
        #expect(resolution.isLocalHit == false)
        #expect(resolution.isMinimal == false)
        #expect(resolution.repo.id == 4242)
        #expect(resolution.repo.starsCount == 999)
        #expect(countingApi.repoCalls == 0)         // 后续源不被调用
    }

    // MARK: - 3a. Hint case-insensitive 匹配防御：大小写不一致仍命中

    @Test("Hint owner/name 大小写不一致但 case-insensitive 匹配 → 仍命中（GitHub case-insensitive 同一仓库）")
    func hintCaseInsensitiveMatch() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let countingApi = CountingMockClient()
        let resolver = RepoResolver(chain: [
            LocalRepoSource(repository: repoRepo),
            BackendHintRepoSource(),

            GitHubFallbackRepoSource(apiClient: countingApi),
            MinimalRepoSource()
        ])

        // 入参是 alice/foo，hint 是 ALICE/FOO（同一仓库不同大小写）
        // 应该命中 BackendHintRepoSource，避免多走一次 GitHub API
        let hint = StarcatRepoCardDTO(
            ghRepoId: 1, fullName: "ALICE/FOO", owner: "ALICE", repo: "FOO"
        )
        let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: hint)
        #expect(resolution.sourceName == "BackendHintRepoSource")
        #expect(resolution.repo.id == 1)
        #expect(countingApi.repoCalls == 0)
    }

    // MARK: - 3b. Hint owner / name 真正不一致 → 跳过

    @Test("Hint owner / name 真正不一致 → BackendHintRepoSource 跳过 → GitHub fallback 兜底")
    func hintOwnerNameMismatchSkips() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let countingApi = CountingMockClient()
        countingApi.repoHandler = { owner, repo in
            self.makeRepoDTO(id: 8888, owner: owner, name: repo)
        }
        let resolver = RepoResolver(chain: [
            LocalRepoSource(repository: repoRepo),
            BackendHintRepoSource(),

            GitHubFallbackRepoSource(apiClient: countingApi),
            MinimalRepoSource()
        ])

        // 入参是 alice/foo，hint 是完全不同仓库 bob/baz（极端边界 / hint 串配错）
        let hint = StarcatRepoCardDTO(
            ghRepoId: 1, fullName: "bob/baz", owner: "bob", repo: "baz"
        )
        let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: hint)
        #expect(resolution.sourceName == "GitHubFallbackRepoSource")
        #expect(resolution.repo.id == 8888)
        #expect(countingApi.repoCalls == 1)
    }

    // MARK: - 4. 单源 throws 不击穿链

    @Test("GitHub source throws → 链 catch + 跳到 MinimalRepoSource 兜底")
    func sourceThrowsContinuesToNext() async throws {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let countingApi = CountingMockClient()
        struct Boom: Error {}
        countingApi.repoHandler = { _, _ in throw Boom() }

        let resolver = RepoResolver(chain: [
            LocalRepoSource(repository: repoRepo),
            BackendHintRepoSource(),

            GitHubFallbackRepoSource(apiClient: countingApi),
            MinimalRepoSource()
        ])

        let resolution = await resolver.resolve(owner: "ghost", name: "vanished", hint: nil)
        // 没有 hint、本地没有、GitHub 抛 Boom → MinimalRepoSource 兜底
        // （注：R-01 v1.2 后 aggregate 已从本套件测试链剔除，单独测试见 BackendAggregateRepoSourceTests）
        #expect(resolution.sourceName == "MinimalRepoSource")
        #expect(resolution.isMinimal == true)
        #expect(resolution.isLocalHit == false)
        #expect(resolution.repo.fullName == "ghost/vanished")
        #expect(resolution.repo.id == 0)             // minimal 没 hint 时 id = 0
        #expect(countingApi.repoCalls == 1)         // GitHub source 被调用过一次
    }

    // MARK: - 5. Hint + GitHub 都 nil → minimal 用 hint 兜底

    @Test("空 chain 的边界：仅 MinimalRepoSource → 永远命中 + isMinimal = true")
    func minimalAlwaysHits() async throws {
        let resolver = RepoResolver(chain: [MinimalRepoSource()])
        let hint = StarcatRepoCardDTO(
            ghRepoId: 555, fullName: "u/x", owner: "u", repo: "x", stars: 1
        )
        let resolution = await resolver.resolve(owner: "u", name: "x", hint: hint)
        #expect(resolution.isMinimal == true)
        #expect(resolution.repo.id == 555)         // 用 hint 兜底，id 来自 hint
        #expect(resolution.repo.starsCount == 1)
    }

    // MARK: - Helpers

    private func makeRepoDTO(id: Int64, owner: String, name: String) -> GitHubRepoDTO {
        GitHubRepoDTO(
            id: id, name: name, fullName: "\(owner)/\(name)",
            owner: GitHubUserDTO(id: 1, login: owner, name: nil, avatarUrl: nil,
                                 publicRepos: nil, followers: nil, following: nil,
                                 bio: nil, company: nil, location: nil, email: nil,
                                 blog: nil, twitterUsername: nil, htmlUrl: nil),
            description: nil, language: nil,
            stargazersCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, fork: false, archived: false,
            pushedAt: nil, createdAt: nil, updatedAt: nil
        )
    }
}

// MARK: - CountingMockClient

/// `MockGitHubAPIClient` 子类，仅记录 `repo(owner:repo:)` 调用次数。
/// 不能直接 subclass（final class），所以新建一个同协议实现，专门为 chain 测试用。
@MainActor
private final class CountingMockClient: GitHubAPIClientProtocol, @unchecked Sendable {
    nonisolated(unsafe) var repoCalls = 0
    nonisolated(unsafe) var repoHandler: ((String, String) async throws -> GitHubRepoDTO)?

    func starredRepos(page: Int, perPage: Int, ifNoneMatch: String?) async throws -> APIResponse<[StarredRepoDTO]> {
        fatalError("not used in chain tests")
    }
    func unstar(owner: String, repo: String) async throws { /* noop */ }
    func star(owner: String, repo: String) async throws { /* noop */ }
    func getCurrentUser() async throws -> GitHubUserDTO { fatalError("not used") }
    func readmeHTML(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?) async throws -> BytesResponse {
        fatalError("not used")
    }
    func readmeMarkdown(owner: String, repo: String, ifNoneMatch: String?, ifModifiedSince: String?) async throws -> BytesResponse {
        fatalError("not used")
    }
    func getSubscription(owner: String, repo: String) async throws -> GitHubSubscriptionDTO {
        GitHubSubscriptionDTO(subscribed: false, ignored: false, reason: nil, createdAt: nil, url: nil, repositoryUrl: nil)
    }
    func putSubscription(owner: String, repo: String, subscribed: Bool, ignored: Bool) async throws -> GitHubSubscriptionDTO {
        GitHubSubscriptionDTO(subscribed: subscribed, ignored: ignored, reason: nil, createdAt: nil, url: nil, repositoryUrl: nil)
    }
    func deleteSubscription(owner: String, repo: String) async throws { /* noop */ }
    func releases(owner: String, repo: String, perPage: Int) async throws -> APIResponse<[GitHubReleaseDTO]> {
        fatalError("not used")
    }
    func repo(owner: String, repo: String) async throws -> GitHubRepoDTO {
        repoCalls += 1
        guard let handler = repoHandler else {
            // 默认抛错，模拟「网络不通」
            struct DefaultBoom: Error {}
            throw DefaultBoom()
        }
        return try await handler(owner, repo)
    }
}
