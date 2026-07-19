//
//  WeeklyBulkRepositoryTests.swift
//  StarcatTests
//
//  R-06.4 客户端 bulk 缓存仓库行为级单测。
//
//  覆盖：
//  - cachedBulk 空表 → 返回 nil
//  - cachedTotal 只读 meta → 返回 total，不展开 repos/languages
//  - fetchBulk 网络成功 → 写入 DB，cachedBulk 后续命中（含 languages / meta）
//  - fetchBulk 整批替换：第二次拉到不同数据，旧行被全部清掉
//  - 网络失败 + 缓存非空 → fallback 返回缓存（不抛错）
//  - 网络失败 + 缓存空 → 抛原网络错误
//  - lastRefreshedAt 写入后返回接近当前时间的时间戳
//  - clearCache：清空三张表
//
//  设计：与 `TrendingRepositoryPersistenceTests` 同款 mock URLSession + 内存 DB。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

// MARK: - Fixture helpers

private func bulkHTTPResponse(
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

/// 构造 weekly bulk envelope wire fixture body。
///
/// 入参 repos: `(fullName, language, stars, latestEventAt)`。
/// languages 直接拍平传 `[(key, label, count)]`。
private func bulkFixtureBody(
    repos: [(String, String?, Int, String)],
    languages: [(String, String, Int)] = [],
    generatedAt: String? = "2026-06-15T12:00:00Z",
    total: Int? = nil,
    sourcesByFullName: [String: [String]] = [:],
    archivedFullNames: Set<String> = [],
    forkFullNames: Set<String> = [],
    pushedAtByFullName: [String: String] = [:],
    pinPositionsByFullName: [String: Int] = [:]
) -> Data {
    // Wire payload 是**扁平**对象：card 字段（gh_repo_id / full_name / owner / ...）
    // 与 feed 字段（is_available / source_types / weekly / ...）同级，由
    // `WeeklyFeedRepoDTO.decodeCard(from:)` 显式从扁平容器解 card 字段。
    let repoDicts: [[String: Any]] = repos.enumerated().map { idx, tuple in
        let parts = tuple.0.split(separator: "/", maxSplits: 1)
        let owner = parts.count > 0 ? String(parts[0]) : ""
        let name = parts.count > 1 ? String(parts[1]) : tuple.0
        var dict: [String: Any] = [
            "gh_repo_id": Int64(2000 + idx),
            "full_name": tuple.0,
            "owner": owner,
            "repo": name,
            "stars": tuple.2,
            "forks": tuple.2 / 10,
            "watchers": tuple.2,
            "subscribers": 0,
            "topics": [],
            "is_archived": archivedFullNames.contains(tuple.0),
            "is_fork": forkFullNames.contains(tuple.0),
            "is_private": false,
            "open_issues": 0,
            "name": name,
            "is_available": true,
            "source_types": sourcesByFullName[tuple.0] ?? ["weekly"],
            "first_event_at": tuple.3,
            "latest_event_at": tuple.3,
            "source_entries": [[
                "source_code": (sourcesByFullName[tuple.0] ?? ["weekly"])[0],
                "occurred_at": tuple.3,
                "source_url": "https://example.com/source/\(idx)",
                "title": "Source \(idx)"
            ]],
            "weekly": [
                "issue_number": 100 + idx,
                "issue_url": "https://example.com/issue/\(100 + idx)"
            ]
        ]
        if let lang = tuple.1 {
            dict["language"] = lang
        }
        if let pushedAt = pushedAtByFullName[tuple.0] {
            dict["pushed_at"] = pushedAt
        }
        if let position = pinPositionsByFullName[tuple.0] {
            dict["is_pinned"] = true
            dict["pin_position"] = position
        }
        return dict
    }
    let langDicts: [[String: Any]] = languages.map { tuple in
        [
            "key": tuple.0,
            "label": tuple.1,
            "count": tuple.2
        ]
    }
    var meta: [String: Any] = [
        "total": total ?? repos.count
    ]
    if let generatedAt {
        meta["generated_at"] = generatedAt
    }
    let envelope: [String: Any] = [
        "schema_version": 2,
        "data": [
            "sources": [
                ["code": "weekly", "display_name_zh": "阮一峰周刊", "display_name_en": "Weekly", "icon_key": "ruanyf", "sort_order": 10, "count": repos.count],
                ["code": "hellogithub", "display_name_zh": "HelloGitHub", "display_name_en": "HelloGitHub", "icon_key": "hellogithub", "sort_order": 40, "count": 0],
                ["code": "ai_intelligence", "display_name_zh": "AI 情报", "display_name_en": "AI Intelligence", "icon_key": "ai-intelligence", "sort_order": 50, "count": 0]
            ],
            "repos": repoDicts,
            "languages": langDicts
        ],
        "meta": meta
    ]
    return try! JSONSerialization.data(withJSONObject: envelope, options: [])
}

private func isoDaysAgo(_ days: Int) -> String {
    let date = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
    return ISO8601DateFormatter().string(from: date)
}

private func allowWeeklyFilterTaskToFinish() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}

@Suite("WeeklyBulkRepository", .serialized)
struct WeeklyBulkRepositoryTests {

    // MARK: - 工厂

    private func makeRepository(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) throws -> (WeeklyBulkRepository, any DatabaseManaging) {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = handler
        let db = try InMemoryDatabaseManager()
        let api = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let repo = WeeklyBulkRepository(api: api, database: db)
        return (repo, db)
    }

    // MARK: - 基础读路径

    @Test("cachedBulk: 空表返回 nil")
    func cachedEmpty() async throws {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let repo = WeeklyBulkRepository(api: api, database: db)

        let cached = await repo.cachedBulk()
        #expect(cached == nil)
    }

    @Test("cachedTotal: 空表返回 nil")
    func cachedTotalEmpty() async throws {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let repo = WeeklyBulkRepository(api: api, database: db)

        let total = await repo.cachedTotal()
        #expect(total == nil)
    }

    @Test("lastRefreshedAt: 空表返回 nil")
    func lastRefreshedAtEmpty() async throws {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let repo = WeeklyBulkRepository(api: api, database: db)

        let date = await repo.lastRefreshedAt()
        #expect(date == nil)
    }

    // MARK: - fetch + cache 联动

    @Test("fetchBulk 网络成功 → 写 DB → cachedBulk 后续命中（repos / languages / meta 都落盘）")
    func fetchThenCacheHit() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/a", "Swift", 100, "2026-06-15T10:00:00Z"),
                    ("owner/b", "Go", 200, "2026-06-15T11:00:00Z")
                ],
                languages: [
                    ("Swift", "Swift", 1),
                    ("Go", "Go", 1)
                ],
                generatedAt: "2026-06-15T12:00:00Z"
            )
            return (
                bulkHTTPResponse(200, request.url!, ["ETag": "W/\"abc12345\""]),
                body
            )
        }

        let fetched = try await repo.fetchBulk()
        #expect(fetched.items.count == 2)
        #expect(fetched.sources.map(\.code) == ["weekly", "hellogithub", "ai_intelligence"])
        #expect(fetched.languages.count == 2)
        #expect(fetched.etag == "W/\"abc12345\"")
        #expect(fetched.generatedAt == "2026-06-15T12:00:00Z")

        let cached = try #require(await repo.cachedBulk())
        #expect(cached.items.count == 2)
        #expect(cached.sources.map(\.code) == ["weekly", "hellogithub", "ai_intelligence"])
        #expect(cached.languages.count == 2)
        #expect(cached.etag == "W/\"abc12345\"")
        #expect(cached.generatedAt == "2026-06-15T12:00:00Z")
        // owner/b 的 latest_event_at 更晚 → 排在前面（cachedBulk 按 latest_event_at DESC 出）
        #expect(cached.items.first?.fullName == "owner/b")
        #expect(cached.items.last?.fullName == "owner/a")
        // Sidebar 预取周刊数量只需要 meta.total，不应该依赖 cachedBulk 读全量明细。
        #expect(await repo.cachedTotal() == 2)
    }

    @Test("置顶与通用来源事件写入缓存后按 pin_position 优先排序")
    func pinnedAndSourceEntriesPersist() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/newer", "Swift", 100, "2026-06-15T12:00:00Z"),
                    ("owner/pinned", "Go", 50, "2026-06-15T10:00:00Z")
                ],
                pinPositionsByFullName: ["owner/pinned": 1]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()
        let page = try #require(await repo.cachedPage(query: WeeklyBulkCacheQuery(
            source: .all,
            coverage: .all,
            hideArchived: false,
            hideForks: false,
            starsFilter: .all,
            pushedRecency: .all,
            language: "",
            sort: .defaultOrder,
            page: 1,
            pageSize: 20,
            now: Date()
        )))
        #expect(page.items.first?.fullName == "owner/pinned")
        #expect(page.items.first?.isPinned == true)
        #expect(page.items.first?.pinPosition == 1)
        #expect(page.items.first?.sourceEntries.first?.title == "Source 1")
    }

    @Test("cachedPage: SQLite 分页筛选排序只返回当前页")
    func cachedPageFiltersAndSortsInSQLite() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/a", "Swift", 100, "2026-06-15T10:00:00Z"),
                    ("owner/b", "Swift", 1_500, "2026-06-15T11:00:00Z"),
                    ("owner/c", "Go", 8_000, "2026-06-15T12:00:00Z"),
                    ("owner/d", "Swift", 12_000, "2026-06-15T13:00:00Z")
                ],
                total: 4,
                sourcesByFullName: [
                    "owner/a": ["weekly"],
                    "owner/b": ["weekly", "zread"],
                    "owner/c": ["zread"],
                    "owner/d": ["weekly", "discovery"]
                ],
                archivedFullNames: ["owner/d"],
                pushedAtByFullName: [
                    "owner/a": isoDaysAgo(10),
                    "owner/b": isoDaysAgo(20),
                    "owner/c": isoDaysAgo(10),
                    "owner/d": isoDaysAgo(5)
                ]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()

        let query = WeeklyBulkCacheQuery(
            source: .weekly,
            coverage: .multipleSources,
            hideArchived: true,
            hideForks: false,
            starsFilter: .min1000,
            pushedRecency: .days30,
            language: "Swift",
            sort: .starsDesc,
            page: 1,
            pageSize: 1,
            now: Date()
        )

        let firstPage = try #require(await repo.cachedPage(query: query))
        #expect(firstPage.catalogTotal == 4)
        #expect(firstPage.filteredTotal == 1)
        #expect(firstPage.items.map(\.fullName) == ["owner/b"])

        let secondPage = try #require(await repo.cachedPage(query: WeeklyBulkCacheQuery(
            source: query.source,
            coverage: query.coverage,
            hideArchived: query.hideArchived,
            hideForks: query.hideForks,
            starsFilter: query.starsFilter,
            pushedRecency: query.pushedRecency,
            language: query.language,
            sort: query.sort,
            page: 2,
            pageSize: 1,
            now: query.now
        )))
        #expect(secondPage.items.isEmpty)
    }

    @Test("fetchBulk 整批替换：第二次拉新数据，旧行被全部清掉")
    func fetchReplacesAll() async throws {
        let firstPayload = bulkFixtureBody(repos: [
            ("owner/a", "Swift", 100, "2026-06-15T10:00:00Z"),
            ("owner/b", "Swift", 200, "2026-06-15T11:00:00Z"),
            ("owner/c", "Swift", 300, "2026-06-15T12:00:00Z")
        ])
        let secondPayload = bulkFixtureBody(repos: [
            ("owner/x", "Swift", 999, "2026-06-15T15:00:00Z")
        ])

        let (repo, _) = try makeRepository { request in
            let isFirst = URLProtocolStub.receivedRequests.count <= 1
            let body = isFirst ? firstPayload : secondPayload
            return (bulkHTTPResponse(200, request.url!), body)
        }

        _ = try await repo.fetchBulk()
        let cachedAfterFirst = try #require(await repo.cachedBulk())
        #expect(cachedAfterFirst.items.count == 3)

        _ = try await repo.fetchBulk()
        let cachedAfterSecond = try #require(await repo.cachedBulk())
        #expect(cachedAfterSecond.items.count == 1)
        #expect(cachedAfterSecond.items.first?.fullName == "owner/x")
    }

    // MARK: - 网络失败 fallback

    @Test("fetchBulk 网络失败 + 缓存非空 → fallback 返回缓存,不抛错")
    func networkFailureFallbackToCache() async throws {
        let (repo, _) = try makeRepository { request in
            let isFirst = URLProtocolStub.receivedRequests.count <= 1
            if isFirst {
                let body = bulkFixtureBody(repos: [
                    ("owner/cached", "Swift", 100, "2026-06-15T10:00:00Z")
                ])
                return (bulkHTTPResponse(200, request.url!), body)
            } else {
                return (bulkHTTPResponse(500, request.url!), Data())
            }
        }

        _ = try await repo.fetchBulk()

        let result = try await repo.fetchBulk()
        #expect(result.items.count == 1)
        #expect(result.items.first?.fullName == "owner/cached")
    }

    @Test("fetchBulk 网络失败 + 缓存空 → 抛原网络错误")
    func networkFailureNoCacheThrows() async throws {
        let (repo, _) = try makeRepository { request in
            (bulkHTTPResponse(500, request.url!), Data())
        }

        await #expect(throws: WeeklyAPIError.self) {
            _ = try await repo.fetchBulk()
        }
    }

    // MARK: - lastRefreshedAt

    @Test("lastRefreshedAt: 写入后返回接近当前时间的时间戳")
    func lastRefreshedAtAfterFetch() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(repos: [
                ("owner/a", "Swift", 100, "2026-06-15T10:00:00Z")
            ])
            return (bulkHTTPResponse(200, request.url!), body)
        }

        let before = Date()
        _ = try await repo.fetchBulk()
        let after = Date()

        let date = try #require(await repo.lastRefreshedAt())
        #expect(date >= before.addingTimeInterval(-1))
        #expect(date <= after.addingTimeInterval(1))
    }

    // MARK: - clearCache

    @Test("clearCache: 清空四张表后 cachedBulk 返回 nil")
    func clearCacheWipesFourTables() async throws {
        let (repo, db) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [("owner/a", "Swift", 100, "2026-06-15T10:00:00Z")],
                languages: [("Swift", "Swift", 1)]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }

        _ = try await repo.fetchBulk()
        // 写入后三张表都有内容
        try await db.writer.read { db in
            let repoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_repos") ?? 0
            let langCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_languages") ?? 0
            let metaCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_meta") ?? 0
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_sources") ?? 0
            #expect(repoCount == 1)
            #expect(langCount == 1)
            #expect(metaCount == 1)
            #expect(sourceCount == 3)
        }

        await repo.clearCache()

        try await db.writer.read { db in
            let repoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_repos") ?? -1
            let langCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_languages") ?? -1
            let metaCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_meta") ?? -1
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_bulk_sources") ?? -1
            #expect(repoCount == 0)
            #expect(langCount == 0)
            #expect(metaCount == 0)
            #expect(sourceCount == 0)
        }

        let cached = await repo.cachedBulk()
        #expect(cached == nil)
    }

    // MARK: - WeeklyContentViewModel TTL 边界

    @MainActor
    @Test("WeeklyContentViewModel.bulkTTL: 6 小时")
    func bulkTTLValue() {
        #expect(WeeklyContentViewModel.bulkTTL == 6 * 60 * 60)
    }

    @MainActor
    @Test("WeeklyContentViewModel: 本地 bulk 模式按来源过滤")
    func localBulkFiltersBySource() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/weekly", "Swift", 300, "2026-06-15T10:00:00Z"),
                    ("owner/zread", "Go", 200, "2026-06-15T11:00:00Z"),
                    ("owner/hn", "Rust", 100, "2026-06-15T12:00:00Z")
                ],
                sourcesByFullName: [
                    "owner/weekly": ["weekly"],
                    "owner/zread": ["zread"],
                    "owner/hn": ["discovery"]
                ]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()

        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let viewModel = WeeklyContentViewModel(
            api: api,
            languageStore: WeeklyLanguageStore(api: api),
            bulkRepository: repo
        )

        await viewModel.loadInitialIfNeeded()
        #expect(viewModel.dataSource == .local)
        #expect(viewModel.total == 3)
        // 主动刷新会把完整 bulk 放进会话内存，后续 source 切换走后台 prepared pipeline。
        await viewModel.reload()
        #expect(viewModel.localDerivationCountForTesting == 1)

        viewModel.changeSource(to: .zread)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.selectedSource == .zread)
        #expect(viewModel.total == 1)
        #expect(viewModel.items.map(\.fullName) == ["owner/zread"])

        viewModel.changeSource(to: .discovery)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 1)
        #expect(viewModel.items.map(\.fullName) == ["owner/hn"])

        let derivationsAfterAB = viewModel.localDerivationCountForTesting
        viewModel.changeSource(to: .zread)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.items.map(\.fullName) == ["owner/zread"])
        #expect(viewModel.localDerivationCountForTesting == derivationsAfterAB,
                "source A-B-A 回切必须直接发布 prepared snapshot")
    }

    @MainActor
    @Test("WeeklyContentViewModel: 外部语言选择驱动本地列表筛选")
    func localBulkFiltersByLanguageSelection() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/swift", "Swift", 300, "2026-06-15T10:00:00Z"),
                    ("owner/go", "Go", 200, "2026-06-15T11:00:00Z"),
                    ("owner/none", nil, 100, "2026-06-15T12:00:00Z")
                ]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()

        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let viewModel = WeeklyContentViewModel(
            api: api,
            languageStore: WeeklyLanguageStore(api: api),
            bulkRepository: repo
        )

        await viewModel.loadInitialIfNeeded()
        #expect(viewModel.total == 3)

        viewModel.changeLanguage(to: "Swift")
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 1)
        #expect(viewModel.items.map(\.fullName) == ["owner/swift"])

        viewModel.changeLanguage(to: TrendingLanguage.uncategorizedKey)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 1)
        #expect(viewModel.items.map(\.fullName) == ["owner/none"])
    }

    @MainActor
    @Test("WeeklyContentViewModel: 来源目录动态提供 HelloGitHub 与 AI 情报筛选")
    func dynamicSourceCatalogFiltersNewChannels() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/hello", "Go", 300, "2026-06-15T10:00:00Z"),
                    ("owner/ai", "Swift", 200, "2026-06-15T11:00:00Z")
                ],
                sourcesByFullName: [
                    "owner/hello": ["hellogithub"],
                    "owner/ai": ["ai_intelligence"]
                ]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()
        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let viewModel = WeeklyContentViewModel(
            api: api,
            languageStore: WeeklyLanguageStore(api: api),
            bulkRepository: repo
        )

        await viewModel.loadInitialIfNeeded()
        #expect(viewModel.availableSourceFilters.map(\.id) == ["all", "weekly", "hellogithub", "ai_intelligence"])
        #expect(viewModel.availableSourceFilters.map(\.count) == [nil, 2, 0, 0])
        viewModel.changeSource(to: .helloGitHub)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.items.map(\.fullName) == ["owner/hello"])
        viewModel.changeSource(to: .aiIntelligence)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.items.map(\.fullName) == ["owner/ai"])
    }

    @MainActor
    @Test("WeeklySelectionService: total 与 selected item 独立维护")
    func selectionServiceKeepsTotalWhenSelectionClears() async throws {
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [("owner/weekly", "Swift", 300, "2026-06-15T10:00:00Z")],
                total: 1
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()

        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let viewModel = WeeklyContentViewModel(
            api: api,
            languageStore: WeeklyLanguageStore(api: api),
            bulkRepository: repo
        )
        await viewModel.loadInitialIfNeeded()

        let service = WeeklySelectionService()
        service.applyTotal(viewModel.total)
        let item = try #require(viewModel.items.first)
        service.select(item)

        #expect(service.total == 1)
        #expect(service.selectedItem?.fullName == "owner/weekly")

        service.clearSelection()
        #expect(service.total == 1)
        #expect(service.selectedItem == nil)
    }

    @MainActor
    @Test("WeeklyContentViewModel: 本地 bulk 模式组合筛选收录强度 / 状态 / 热度 / 推送时间")
    func localBulkFiltersByAdvancedCriteria() async throws {
        let recentPush = isoDaysAgo(10)
        let stalePush = isoDaysAgo(400)
        let (repo, _) = try makeRepository { request in
            let body = bulkFixtureBody(
                repos: [
                    ("owner/good", "Swift", 5_000, "2026-06-15T15:00:00Z"),
                    ("owner/archived", "Swift", 5_000, "2026-06-15T14:00:00Z"),
                    ("owner/fork", "Swift", 5_000, "2026-06-15T13:00:00Z"),
                    ("owner/low", "Swift", 50, "2026-06-15T12:00:00Z"),
                    ("owner/stale", "Swift", 5_000, "2026-06-15T11:00:00Z"),
                    ("owner/single", "Swift", 5_000, "2026-06-15T10:00:00Z")
                ],
                sourcesByFullName: [
                    "owner/good": ["weekly", "zread"],
                    "owner/archived": ["weekly", "zread"],
                    "owner/fork": ["weekly", "zread"],
                    "owner/low": ["weekly", "zread"],
                    "owner/stale": ["weekly", "zread"],
                    "owner/single": ["weekly"]
                ],
                archivedFullNames: ["owner/archived"],
                forkFullNames: ["owner/fork"],
                pushedAtByFullName: [
                    "owner/good": recentPush,
                    "owner/archived": recentPush,
                    "owner/fork": recentPush,
                    "owner/low": recentPush,
                    "owner/stale": stalePush,
                    "owner/single": recentPush
                ]
            )
            return (bulkHTTPResponse(200, request.url!), body)
        }
        _ = try await repo.fetchBulk()

        let api = WeeklyAPI(baseURL: URL(string: "https://weekly.test.invalid")!)
        let viewModel = WeeklyContentViewModel(
            api: api,
            languageStore: WeeklyLanguageStore(api: api),
            bulkRepository: repo
        )

        await viewModel.loadInitialIfNeeded()
        #expect(viewModel.total == 6)

        viewModel.changeCoverage(to: .multipleSources)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 5)
        #expect(Set(viewModel.items.map(\.fullName)) == [
            "owner/good",
            "owner/archived",
            "owner/fork",
            "owner/low",
            "owner/stale"
        ])

        viewModel.changeHideArchivedRepos(to: true)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 4)
        #expect(!viewModel.items.map(\.fullName).contains("owner/archived"))

        viewModel.changeHideForkRepos(to: true)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 3)
        #expect(!viewModel.items.map(\.fullName).contains("owner/fork"))

        viewModel.changeStarsFilter(to: .min1000)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 2)
        #expect(Set(viewModel.items.map(\.fullName)) == ["owner/good", "owner/stale"])

        viewModel.changePushedRecency(to: .days90)
        await allowWeeklyFilterTaskToFinish()
        #expect(viewModel.total == 1)
        #expect(viewModel.items.map(\.fullName) == ["owner/good"])
        #expect(viewModel.selectedSort == .defaultOrder)
        #expect(viewModel.filterSummaryTitle.contains("5"))
        #expect(viewModel.filterSummaryTitle.contains("1"))
        #expect(!viewModel.filterSummaryTitle.contains(WeeklyFeedSort.defaultOrder.localizedTitle))
    }
}
