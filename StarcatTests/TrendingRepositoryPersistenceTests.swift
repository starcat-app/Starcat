//
//  TrendingRepositoryPersistenceTests.swift
//  StarcatTests
//
//  W7+ trending 列表持久化（GRDB）行为级单测。
//
//  覆盖：
//  - cachedTrending 空表 → 返回空数组
//  - fetchTrending 网络成功 → 写入 DB，cachedTrending 后续命中
//  - fetchTrending 整批替换：第二次拉到不同的 (rank → repo) 映射，旧行被全部清掉
//  - 多桶隔离：同一 repo 出现在 (daily, Swift) 与 (weekly, "") 桶不互相覆盖
//  - 网络失败 + 缓存非空 → fallback 返回缓存（不抛错）
//  - 网络失败 + 缓存空 → 抛原网络错误
//
//  设计：
//  - 用 `InMemoryDatabaseManager` 起内存 DB，跑完真实 v4 迁移
//  - 用 `URLProtocolStub` mock TrendingAPI 的 HTTP 响应（与 `TrendingTests.swift` 同款）
//  - `TrendingRepository(api:database:)` 装配真实 TrendingAPI（注入 stubbed session）
//

import Testing
import Foundation
import GRDB
@testable import Starcat

private func trendingPersistResponse(
    _ statusCode: Int,
    _ url: URL,
    _ headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private func trendingFixtureBody(_ items: [(String, String?, Int, Int, Int)]) -> Data {
    // [(repo, lang, stars, forks, change)]
    let arr = items.map { tuple -> [String: Any] in
        var dict: [String: Any] = [
            "repo": tuple.0,
            "stars": tuple.2,
            "forks": tuple.3,
            "change": tuple.4,
            "build_by": []
        ]
        if let lang = tuple.1 {
            dict["lang"] = lang
        }
        return dict
    }
    return try! JSONSerialization.data(withJSONObject: arr, options: [])
}

@Suite("TrendingRepository 持久化", .serialized)
struct TrendingRepositoryPersistenceTests {

    // MARK: - 工厂

    private func makeRepository(handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) throws -> (TrendingRepository, any DatabaseManaging) {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = handler
        let db = try InMemoryDatabaseManager()
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let repo = TrendingRepository(api: api, database: db)
        return (repo, db)
    }

    // MARK: - 基础读路径

    @Test("cachedTrending: 空表返回空数组")
    func cachedEmpty() async throws {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let repo = TrendingRepository(database: db)

        let cached = await repo.cachedTrending(since: .daily, language: .all)
        #expect(cached.isEmpty)
    }

    // MARK: - fetch + cache 联动

    @Test("fetchTrending 网络成功 → 写 DB → cachedTrending 后续命中")
    func fetchThenCacheHit() async throws {
        let (repo, _) = try makeRepository { request in
            let body = trendingFixtureBody([
                ("/owner/a", "Swift", 100, 10, 5),
                ("/owner/b", "Swift", 200, 20, 8),
            ])
            return (trendingPersistResponse(200, request.url!), body)
        }

        let fetched = try await repo.fetchTrending(since: .daily, language: .swift)
        #expect(fetched.count == 2)
        #expect(fetched.first?.fullName == "owner/a")

        let cached = await repo.cachedTrending(since: .daily, language: .swift)
        #expect(cached.count == 2)
        #expect(cached.first?.fullName == "owner/a")
        #expect(cached.last?.fullName == "owner/b")
    }

    @Test("fetchTrending 整批替换：第二次拉新数据,旧行被清掉")
    func fetchReplacesAll() async throws {
        let firstPayload = trendingFixtureBody([
            ("/owner/a", "Swift", 100, 10, 5),
            ("/owner/b", "Swift", 200, 20, 8),
            ("/owner/c", "Swift", 300, 30, 12),
        ])
        let secondPayload = trendingFixtureBody([
            ("/owner/x", "Swift", 999, 99, 50),
        ])

        // 用 receivedRequests.count 做"第几次请求"判定，避免 @Sendable 闭包内捕获 var
        let (repo, _) = try makeRepository { request in
            let isFirst = URLProtocolStub.receivedRequests.count <= 1
            let body = isFirst ? firstPayload : secondPayload
            return (trendingPersistResponse(200, request.url!), body)
        }

        _ = try await repo.fetchTrending(since: .daily, language: .swift)
        let cachedAfterFirst = await repo.cachedTrending(since: .daily, language: .swift)
        #expect(cachedAfterFirst.count == 3)

        _ = try await repo.fetchTrending(since: .daily, language: .swift)
        let cachedAfterSecond = await repo.cachedTrending(since: .daily, language: .swift)
        #expect(cachedAfterSecond.count == 1)
        #expect(cachedAfterSecond.first?.fullName == "owner/x")
    }

    @Test("多桶隔离：同一 repo 出现在不同 (period, language) 不互相覆盖")
    func multiBucketIsolation() async throws {
        // 两次请求都返回同一 repo，验证两个桶独立持久化
        let (repo, _) = try makeRepository { request in
            let body = trendingFixtureBody([
                ("/owner/shared", "Swift", 100, 10, 5),
            ])
            return (trendingPersistResponse(200, request.url!), body)
        }

        _ = try await repo.fetchTrending(since: .daily, language: .swift)
        _ = try await repo.fetchTrending(since: .weekly, language: .all)

        let dailySwift = await repo.cachedTrending(since: .daily, language: .swift)
        let weeklyAll = await repo.cachedTrending(since: .weekly, language: .all)
        #expect(dailySwift.count == 1)
        #expect(weeklyAll.count == 1)

        // 验证另一个桶不会被污染
        let dailyAll = await repo.cachedTrending(since: .daily, language: .all)
        #expect(dailyAll.isEmpty)
    }

    // MARK: - 网络失败 fallback

    @Test("fetchTrending 网络失败 + 缓存非空 → fallback 返回缓存,不抛错")
    func networkFailureFallbackToCache() async throws {
        // 用 receivedRequests.count 做"第几次请求"判定，避免 @Sendable 闭包内捕获 var
        let (repo, _) = try makeRepository { request in
            let isFirst = URLProtocolStub.receivedRequests.count <= 1
            if isFirst {
                let body = trendingFixtureBody([
                    ("/owner/cached", "Swift", 100, 10, 5),
                ])
                return (trendingPersistResponse(200, request.url!), body)
            } else {
                // 后续请求返回 500，触发 fallback
                return (trendingPersistResponse(500, request.url!), Data())
            }
        }

        _ = try await repo.fetchTrending(since: .daily, language: .swift)

        // 第二次拉失败 → 应该返回上次缓存的数据
        let result = try await repo.fetchTrending(since: .daily, language: .swift)
        #expect(result.count == 1)
        #expect(result.first?.fullName == "owner/cached")
    }

    @Test("fetchTrending 网络失败 + 缓存空 → 抛原网络错误")
    func networkFailureNoCacheThrows() async throws {
        let (repo, _) = try makeRepository { request in
            (trendingPersistResponse(500, request.url!), Data())
        }

        await #expect(throws: TrendingAPIError.self) {
            _ = try await repo.fetchTrending(since: .daily, language: .swift)
        }
    }
}

// MARK: - TrendingReadmeRepository CRUD

@Suite("TrendingReadmeRepository CRUD", .serialized)
struct TrendingReadmeRepositoryTests {

    private func makeRepository() throws -> (TrendingReadmeRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)
        return (repo, db)
    }

    private func makeReadme(fullName: String, html: String = "<h1>R</h1>") -> TrendingReadme {
        TrendingReadme(
            fullName: fullName,
            renderedHtml: html,
            etag: "\"abc\"",
            lastModified: nil,
            cachedAt: ISO8601DateFormatter.shared.string(from: Date()),
            size: html.utf8.count
        )
    }

    @Test("find: 未命中返回 nil")
    func findMiss() async throws {
        let (repo, _) = try makeRepository()
        let result = try await repo.find(fullName: "owner/none")
        #expect(result == nil)
    }

    @Test("upsert + find: 写入后能读回")
    func upsertThenFind() async throws {
        let (repo, _) = try makeRepository()
        let readme = makeReadme(fullName: "owner/a")
        try await repo.upsert(readme)

        let result = try await repo.find(fullName: "owner/a")
        #expect(result?.fullName == "owner/a")
        #expect(result?.renderedHtml == "<h1>R</h1>")
    }

    @Test("upsert: 同一 fullName 二次写入会覆盖")
    func upsertOverwrites() async throws {
        let (repo, _) = try makeRepository()
        try await repo.upsert(makeReadme(fullName: "owner/a", html: "<h1>v1</h1>"))
        try await repo.upsert(makeReadme(fullName: "owner/a", html: "<h1>v2</h1>"))

        let result = try await repo.find(fullName: "owner/a")
        #expect(result?.renderedHtml == "<h1>v2</h1>")
    }

    @Test("touchCachedAt: 仅更新 cached_at,不动 HTML")
    func touchCachedAt() async throws {
        let (repo, _) = try makeRepository()
        try await repo.upsert(makeReadme(fullName: "owner/a"))
        let before = try await repo.find(fullName: "owner/a")

        let later = Date().addingTimeInterval(3600)
        try await repo.touchCachedAt(fullName: "owner/a", at: later)
        let after = try await repo.find(fullName: "owner/a")

        #expect(before?.renderedHtml == after?.renderedHtml)
        #expect(before?.cachedAt != after?.cachedAt)
    }

    @Test("delete: 删除后再查为 nil")
    func deleteOne() async throws {
        let (repo, _) = try makeRepository()
        try await repo.upsert(makeReadme(fullName: "owner/a"))
        try await repo.delete(fullName: "owner/a")
        let result = try await repo.find(fullName: "owner/a")
        #expect(result == nil)
    }

    @Test("countAll + totalBytes: 统计正确")
    func stats() async throws {
        let (repo, _) = try makeRepository()
        try await repo.upsert(makeReadme(fullName: "owner/a", html: "<h1>aa</h1>"))
        try await repo.upsert(makeReadme(fullName: "owner/b", html: "<h1>bbbb</h1>"))

        let count = try await repo.countAll()
        let bytes = try await repo.totalBytes()
        #expect(count == 2)
        #expect(bytes == Int64("<h1>aa</h1>".utf8.count + "<h1>bbbb</h1>".utf8.count))
    }

    @Test("deleteAll: 清空整表")
    func deleteAll() async throws {
        let (repo, _) = try makeRepository()
        try await repo.upsert(makeReadme(fullName: "owner/a"))
        try await repo.upsert(makeReadme(fullName: "owner/b"))
        try await repo.deleteAll()

        let count = try await repo.countAll()
        #expect(count == 0)
    }
}
