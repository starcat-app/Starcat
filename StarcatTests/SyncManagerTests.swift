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
                                 publicRepos: nil, followers: nil, following: nil)
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
            updatedAt: nil
        )
        return StarredRepoDTO(starredAt: "2026-05-29T10:00:00Z", repo: repo)
    }

    private func makeOnePageResponse(dtos: [StarredRepoDTO]) -> APIResponse<[StarredRepoDTO]> {
        APIResponse(
            value: dtos,
            linkHeader: LinkHeader(nextPage: nil, lastPage: 1),
            rateLimit: .empty,
            statusCode: 200
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

    // MARK: - Tests

    @Test("正常无 rate limit → .completed")
    func normalSync() async throws {
        let (sync, mock, repo) = try makeSUT()
        let dtos = [makeDTO(id: 1), makeDTO(id: 2)]
        mock.starredReposHandler = { page, _ in
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
        mock.starredReposHandler = { page, _ in
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
        mock.starredReposHandler = { _, _ in
            _ = attempts.increment()
            throw NetworkError.rateLimited(retryAfter: 0)
        }

        sync.performFullSync(userID: 7)
        // 第一次自动重试后第二次依然抛 → 转为终态 .rateLimited
        try await waitForState(sync) { if case .rateLimited = $0 { return true } else { return false } }

        #expect(attempts.value == 2, "应该恰好重试 1 次")
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
