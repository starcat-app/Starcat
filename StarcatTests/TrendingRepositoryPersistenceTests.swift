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

/// 构造 trending v1.2 envelope wire fixture body。
///
/// R-01 v1.2 后 TrendingAPI 走 `StarcatEnvelope<[StarcatRepoCardDTO]>`，旧的非 envelope
/// `[TrendingResponseDTO]` 数组格式已废。fullName 字段从输入 tuple 第 1 项的 "/owner/repo" 解析。
private func trendingFixtureBody(_ items: [(String, String?, Int, Int, Int)]) -> Data {
    // [(repo path, lang, stars, forks, change)]
    let cards = items.enumerated().map { (idx, tuple) -> [String: Any] in
        let cleanPath = tuple.0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = cleanPath.split(separator: "/", maxSplits: 1)
        let owner = parts.count > 0 ? String(parts[0]) : ""
        let repo = parts.count > 1 ? String(parts[1]) : cleanPath

        var card: [String: Any] = [
            "gh_repo_id": Int64(1000 + idx),
            "full_name": cleanPath,
            "owner": owner,
            "repo": repo,
            "stars": tuple.2,
            "forks": tuple.3,
            "watchers": tuple.2,
            "subscribers": 0,
            "topics": [],
            "is_archived": false,
            "is_fork": false,
            "is_private": false,
            "open_issues": 0,
            "trending": [
                "change": tuple.4,
                "contributors": []
            ]
        ]
        if let lang = tuple.1 {
            card["language"] = lang
        }
        return card
    }
    let envelope: [String: Any] = [
        "schema_version": 1,
        "data": cards
    ]
    return try! JSONSerialization.data(withJSONObject: envelope, options: [])
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
        // TrendingAPI 已移除默认 baseURL，纯读测试也得显式传一个假地址（永不被使用）。
        let api = TrendingAPI(baseURL: URL(string: "https://trend.test.invalid")!)
        let repo = TrendingRepository(api: api, database: db)

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

    // MARK: - lastRefreshedAt（2026-06-02 新增，配合"消除二次入场动画"改造）

    @Test("lastRefreshedAt: 空表返回 nil")
    func lastRefreshedAtEmpty() async throws {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let api = TrendingAPI(baseURL: URL(string: "https://trend.test.invalid")!)
        let repo = TrendingRepository(api: api, database: db)

        let date = await repo.lastRefreshedAt(since: .daily, language: .all)
        #expect(date == nil)
    }

    @Test("lastRefreshedAt: 写入后返回接近当前时间的时间戳")
    func lastRefreshedAtAfterFetch() async throws {
        let (repo, _) = try makeRepository { request in
            let body = trendingFixtureBody([
                ("/owner/a", "Swift", 100, 10, 5),
            ])
            return (trendingPersistResponse(200, request.url!), body)
        }

        let before = Date()
        _ = try await repo.fetchTrending(since: .daily, language: .swift)
        let after = Date()

        let date = await repo.lastRefreshedAt(since: .daily, language: .swift)
        let unwrapped = try #require(date)
        #expect(unwrapped >= before.addingTimeInterval(-1), "lastRefreshedAt should be >= fetch start time")
        #expect(unwrapped <= after.addingTimeInterval(1), "lastRefreshedAt should be <= fetch end time")
    }

    // MARK: - R-01 v1.2 GRDB v8 4 字段持久化（2026-06-10）

    @Test("v8 4 字段：DTO → trending_repos 表 → cachedTrending 域模型 全链路透传")
    func v8FieldsPersistedAndReadBack() async throws {
        let (repo, db) = try makeRepository { request in
            // 构造一个所有 v8 字段都填实值的 fixture（不走默认 fixture，因为它没填新字段）
            let card: [String: Any] = [
                "gh_repo_id": Int64(2024),
                "full_name": "owner/v8repo",
                "owner": "owner",
                "repo": "v8repo",
                "owner_avatar": "https://avatars.githubusercontent.com/owner.png",
                "stars": 100,
                "forks": 10,
                "watchers": 100,
                "subscribers": 55,
                "topics": [],
                "default_branch": "develop",
                "open_issues": 9,
                "is_archived": false,
                "is_fork": false,
                "is_private": false,
                "trending": [
                    "change": 5,
                    "contributors": []
                ]
            ]
            let envelope: [String: Any] = ["schema_version": 1, "data": [card]]
            let body = try! JSONSerialization.data(withJSONObject: envelope, options: [])
            return (trendingPersistResponse(200, request.url!), body)
        }

        // 1. fetch → 写库
        let fetched = try await repo.fetchTrending(since: .daily, language: .all)
        #expect(fetched.count == 1)
        let mem = try #require(fetched.first)
        #expect(mem.ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/owner.png")
        #expect(mem.subscribersCount == 55)
        #expect(mem.defaultBranch == "develop")
        #expect(mem.openIssuesCount == 9)

        // 2. SQL 直读，验证 4 列真的写进表
        try await db.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM trending_repos WHERE full_name = ?",
                arguments: ["owner/v8repo"]
            )
            #expect(row?["owner_avatar"] as String? == "https://avatars.githubusercontent.com/owner.png")
            #expect(row?["subscribers_count"] as Int? == 55)
            #expect(row?["default_branch"] as String? == "develop")
            #expect(row?["open_issues_count"] as Int? == 9)
        }

        // 3. cachedTrending → toDomain 时 4 字段被还原回 TrendingRepo
        let cached = await repo.cachedTrending(since: .daily, language: .all)
        #expect(cached.count == 1)
        let cachedFirst = try #require(cached.first)
        #expect(cachedFirst.ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/owner.png")
        #expect(cachedFirst.subscribersCount == 55)
        #expect(cachedFirst.defaultBranch == "develop")
        #expect(cachedFirst.openIssuesCount == 9)
    }

    // MARK: - R-05 trending 详情页字段补齐 10 字段持久化（2026-06-11，直接进 v4 建表）

    @Test("R-05 10 字段：DTO → trending_repos 表 → cachedTrending 域模型 全链路透传")
    func r05DetailFieldsPersistedAndReadBack() async throws {
        let (repo, db) = try makeRepository { request in
            // 构造一个所有 R-05 字段都填实值的 fixture（不走默认 fixture，因为它没填这些新字段）
            let card: [String: Any] = [
                "gh_repo_id": Int64(20251),
                "full_name": "owner/r05repo",
                "owner": "owner",
                "repo": "r05repo",
                "stars": 5000,
                "forks": 300,
                "watchers": 5000,
                "subscribers": 78,
                // R-05 详情页字段
                "topics": ["ai", "swift", "macos"],
                "homepage": "https://example.com",
                "license_spdx": "Apache-2.0",
                "is_archived": true,
                "is_fork": false,
                "is_private": false,
                "default_branch": "main",
                "open_issues": 12,
                "pushed_at": "2026-06-11T08:00:00Z",
                "updated_at": "2026-06-10T16:30:00Z",
                "created_at": "2024-01-15T12:00:00Z",
                "trending": [
                    "change": 821,
                    "contributors": []
                ]
            ]
            let envelope: [String: Any] = ["schema_version": 1, "data": [card]]
            let body = try! JSONSerialization.data(withJSONObject: envelope, options: [])
            return (trendingPersistResponse(200, request.url!), body)
        }

        // 1. fetch → 内存域模型 10 字段透传
        let fetched = try await repo.fetchTrending(since: .daily, language: .all)
        #expect(fetched.count == 1)
        let mem = try #require(fetched.first)
        #expect(mem.watchersCount == 5000)
        #expect(mem.topics == #"["ai","swift","macos"]"#)
        #expect(mem.license == "Apache-2.0")
        #expect(mem.homepage?.absoluteString == "https://example.com")
        #expect(mem.isArchived == true)
        #expect(mem.isFork == false)
        #expect(mem.isPrivate == false)
        #expect(mem.pushedAt == "2026-06-11T08:00:00Z")
        #expect(mem.createdAt == "2024-01-15T12:00:00Z")
        #expect(mem.updatedAt == "2026-06-10T16:30:00Z")

        // 2. SQL 直读，验证 10 列真的写进表（GRDB Bool 桥到 SQLite INTEGER 0/1）
        try await db.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM trending_repos WHERE full_name = ?",
                arguments: ["owner/r05repo"]
            )
            #expect(row?["watchers_count"] as Int? == 5000)
            #expect(row?["topics"] as String? == #"["ai","swift","macos"]"#)
            #expect(row?["license"] as String? == "Apache-2.0")
            #expect(row?["homepage"] as String? == "https://example.com")
            #expect(row?["is_archived"] as Bool? == true)
            #expect(row?["is_fork"] as Bool? == false)
            #expect(row?["is_private"] as Bool? == false)
            #expect(row?["pushed_at"] as String? == "2026-06-11T08:00:00Z")
            #expect(row?["created_at"] as String? == "2024-01-15T12:00:00Z")
            #expect(row?["updated_at"] as String? == "2026-06-10T16:30:00Z")
        }

        // 3. cachedTrending → toDomain 时 10 字段被还原回 TrendingRepo
        let cached = await repo.cachedTrending(since: .daily, language: .all)
        #expect(cached.count == 1)
        let cachedFirst = try #require(cached.first)
        #expect(cachedFirst.watchersCount == 5000)
        #expect(cachedFirst.topics == #"["ai","swift","macos"]"#)
        #expect(cachedFirst.license == "Apache-2.0")
        #expect(cachedFirst.homepage?.absoluteString == "https://example.com")
        #expect(cachedFirst.isArchived == true)
        #expect(cachedFirst.isFork == false)
        #expect(cachedFirst.isPrivate == false)
        #expect(cachedFirst.pushedAt == "2026-06-11T08:00:00Z")
        #expect(cachedFirst.createdAt == "2024-01-15T12:00:00Z")
        #expect(cachedFirst.updatedAt == "2026-06-10T16:30:00Z")

        // 4. makeEphemeralRepo 也要正确透传（R-05 修复的核心目标 —— 详情页 hero）
        let ephemeral = cachedFirst.makeEphemeralRepo()
        #expect(ephemeral.watchersCount == 5000)
        #expect(ephemeral.topicsArray == ["ai", "swift", "macos"])
        #expect(ephemeral.license == "Apache-2.0")
        #expect(ephemeral.homepage == "https://example.com")
        #expect(ephemeral.isArchived == true)
        #expect(ephemeral.createdAt == "2024-01-15T12:00:00Z")
        #expect(ephemeral.updatedAt == "2026-06-10T16:30:00Z")
        #expect(ephemeral.pushedAt == "2026-06-11T08:00:00Z")
    }

    @Test("lastRefreshedAt: 多桶隔离，每个桶独立时间戳")
    func lastRefreshedAtPerBucket() async throws {
        let (repo, _) = try makeRepository { request in
            let body = trendingFixtureBody([
                ("/owner/a", "Swift", 100, 10, 5),
            ])
            return (trendingPersistResponse(200, request.url!), body)
        }

        // 只写入 daily/Swift 桶
        _ = try await repo.fetchTrending(since: .daily, language: .swift)

        let dailySwift = await repo.lastRefreshedAt(since: .daily, language: .swift)
        let weeklyAll = await repo.lastRefreshedAt(since: .weekly, language: .all)
        #expect(dailySwift != nil)
        #expect(weeklyAll == nil, "未写入的桶应该返回 nil")
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
