//
//  ReadmeMetricsTests.swift
//  StarcatTests
//
//  README 缓存指标埋点测试(HOM-201 P2-3,2026-06-14)。
//
//  ────────────────────────────────────────────────────────────────────────────
//  覆盖范围
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. `ReadmeMetrics` 本身的 actor 计数器语义(并发安全 / 快照 / reset)。
//  2. `ReadmeAPI` 各 SWR 终态的 record 调用是否落到正确计数器:
//      - cachedReadme manage 命中 → cachedHit +1
//      - cachedReadme trending → manage promote → cachedHit +1
//      - refreshReadme 200 → refresh200 +1
//      - refreshReadme 304 → refresh304 +1
//      - refreshReadme 404 → refresh404 +1
//      - refreshReadme transport error → refreshFailed +1
//      - trending 路径同 4 个终态
//
//  ────────────────────────────────────────────────────────────────────────────
//  Fixture 选择
//  ────────────────────────────────────────────────────────────────────────────
//
//  本套不复用 `ReadmeAPINetworkTests.makeAPI` —— 因为那套 fixture 不返回
//  `ReadmeMetrics` 实例;本套需要 record 后断言 snapshot,所以自带 fixture。
//  与 `ReadmeAPINetworkTests` 的 GRDB + MockGitHubAPIClient 接法保持一致。
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeMetrics — actor 计数器")
struct ReadmeMetricsActorTests {

    @Test("初始快照全 0")
    func initialSnapshotZero() async {
        let m = ReadmeMetrics()
        let snap = await m.snapshot()
        #expect(snap.cachedHit == 0)
        #expect(snap.refresh200 == 0)
        #expect(snap.refresh304 == 0)
        #expect(snap.refresh404 == 0)
        #expect(snap.refreshFailed == 0)
        #expect(snap.totalRefresh == 0)
    }

    @Test("各 record 独立累加")
    func independentCounters() async {
        let m = ReadmeMetrics()
        await m.recordCachedHit()
        await m.recordCachedHit()
        await m.recordRefresh200()
        await m.recordRefresh304()
        await m.recordRefresh304()
        await m.recordRefresh304()
        await m.recordRefresh404()
        await m.recordRefreshFailed()

        let snap = await m.snapshot()
        #expect(snap.cachedHit == 2)
        #expect(snap.refresh200 == 1)
        #expect(snap.refresh304 == 3)
        #expect(snap.refresh404 == 1)
        #expect(snap.refreshFailed == 1)
        #expect(snap.totalRefresh == 6) // 200+304+404+failed = 1+3+1+1
    }

    @Test("reset 清零所有计数器")
    func resetClearsAll() async {
        let m = ReadmeMetrics()
        await m.recordCachedHit()
        await m.recordRefresh200()
        await m.recordRefresh404()
        await m.reset()
        let snap = await m.snapshot()
        #expect(snap.cachedHit == 0)
        #expect(snap.refresh200 == 0)
        #expect(snap.refresh404 == 0)
    }

    @Test("并发 record 累加结果正确(actor 串行保证)")
    func concurrentRecord() async {
        let m = ReadmeMetrics()
        // 并发 100 次 recordRefresh200,actor 保证最终是 100
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { await m.recordRefresh200() }
            }
        }
        let snap = await m.snapshot()
        #expect(snap.refresh200 == 100)
    }
}

@Suite("ReadmeAPI — metrics 埋点联动")
struct ReadmeAPIMetricsIntegrationTests {

    // MARK: - Fixture

    /// 与 `ReadmeAPINetworkTests.makeAPI` 同款,但额外返回 metrics 实例供断言。
    private func makeAPI() async throws -> (
        ReadmeAPI,
        MockGitHubAPIClient,
        Repo,
        ReadmeRepository,
        TrendingReadmeRepository,
        ReadmeMetrics,
        any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        let readmeRepo = ReadmeRepository(database: db)
        let trendingReadmeRepo = TrendingReadmeRepository(database: db)
        let repoId: Int64 = 99

        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, 'alice', 'foo', 'alice/foo', 'd', 'Swift',
                    0, 0, 0, '[]', NULL,
                    NULL, 'https://github.com/alice/foo', NULL, NULL,
                    0, 0, 0, 1,
                    NULL, NULL, NULL, NULL, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [repoId]
            )
        }

        let repo = Repo(
            id: repoId,
            owner: "alice",
            name: "foo",
            fullName: "alice/foo",
            description: "d",
            language: "Swift",
            starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/alice/foo",
            cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil,
            cachedAt: "2026-05-30T00:00:00Z"
        )

        let mock = MockGitHubAPIClient()
        let inflightTracker = ReadmeInflightTracker()
        let metrics = ReadmeMetrics()
        let api = ReadmeAPI(
            client: mock,
            repository: readmeRepo,
            trendingRepository: trendingReadmeRepo,
            inflightTracker: inflightTracker,
            metrics: metrics
        )
        return (api, mock, repo, readmeRepo, trendingReadmeRepo, metrics, db)
    }

    private func makeReadme(repoId: Int64, html: String) -> Readme {
        Readme(
            repoId: repoId,
            content: nil,
            renderedHtml: html,
            etag: "\"e\"",
            lastModified: nil,
            cachedAt: "2026-05-29T00:00:00Z",
            size: html.utf8.count
        )
    }

    // MARK: - cachedReadme: cachedHit

    @Test("cachedReadme manage 命中 → cachedHit +1")
    func cachedReadmeManageHitRecordsCachedHit() async throws {
        let (api, _, repo, readmeRepo, _, metrics, _) = try await makeAPI()
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "<h1>x</h1>"))

        let hit = try await api.cachedReadme(for: repo)
        #expect(hit != nil)
        let snap = await metrics.snapshot()
        #expect(snap.cachedHit == 1)
        #expect(snap.totalRefresh == 0)
    }

    @Test("cachedReadme manage / trending 都没命中 → cachedHit 不动")
    func cachedReadmeMissDoesNotRecord() async throws {
        let (api, _, repo, _, _, metrics, _) = try await makeAPI()
        let hit = try await api.cachedReadme(for: repo)
        #expect(hit == nil)
        let snap = await metrics.snapshot()
        #expect(snap.cachedHit == 0)
    }

    @Test("cachedReadme trending → manage promote → cachedHit +1")
    func cachedReadmePromoteRecordsCachedHit() async throws {
        let (api, _, repo, _, trendingRepo, metrics, _) = try await makeAPI()
        // 只在 trending 表埋点缓存,manage 表是空
        try await trendingRepo.upsert(TrendingReadme(
            fullName: repo.fullName,
            renderedHtml: "<h1>trending</h1>",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-05-29T00:00:00Z",
            size: 100
        ))

        let hit = try await api.cachedReadme(for: repo)
        #expect(hit != nil)
        let snap = await metrics.snapshot()
        #expect(snap.cachedHit == 1)
    }

    // MARK: - refreshReadme manage 路径

    @Test("refreshReadme 200 → refresh200 +1")
    func refresh200RecordsRefresh200() async throws {
        let (api, mock, repo, _, _, metrics, _) = try await makeAPI()
        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: "<h1>new</h1>".data(using: .utf8)!, etag: "\"e\"")
        }
        _ = await api.refreshReadme(for: repo)
        let snap = await metrics.snapshot()
        #expect(snap.refresh200 == 1)
        #expect(snap.refresh304 == 0)
        #expect(snap.refresh404 == 0)
        #expect(snap.refreshFailed == 0)
    }

    @Test("refreshReadme 304 → refresh304 +1")
    func refresh304RecordsRefresh304() async throws {
        let (api, mock, repo, readmeRepo, _, metrics, _) = try await makeAPI()
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "<h1>cached</h1>"))
        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"old-etag\"")
        }
        _ = await api.refreshReadme(for: repo)
        let snap = await metrics.snapshot()
        #expect(snap.refresh304 == 1)
        #expect(snap.refresh200 == 0)
    }

    @Test("refreshReadme 404 → refresh404 +1")
    func refresh404RecordsRefresh404() async throws {
        let (api, mock, repo, _, _, metrics, _) = try await makeAPI()
        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.notFound
        }
        _ = await api.refreshReadme(for: repo)
        let snap = await metrics.snapshot()
        #expect(snap.refresh404 == 1)
        #expect(snap.refresh200 == 0)
    }

    @Test("refreshReadme transport error → refreshFailed +1")
    func refreshErrorRecordsFailed() async throws {
        let (api, mock, repo, _, _, metrics, _) = try await makeAPI()
        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.transport(underlying: URLError(.notConnectedToInternet))
        }
        _ = await api.refreshReadme(for: repo)
        let snap = await metrics.snapshot()
        #expect(snap.refreshFailed == 1)
        #expect(snap.refresh200 == 0)
        #expect(snap.refresh304 == 0)
        #expect(snap.refresh404 == 0)
    }

    // MARK: - refreshTrendingReadme

    @Test("refreshTrendingReadme 200 → refresh200 +1")
    func trendingRefresh200RecordsRefresh200() async throws {
        let (api, mock, _, _, _, metrics, _) = try await makeAPI()
        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: "<h1>new</h1>".data(using: .utf8)!, etag: "\"e\"")
        }
        _ = await api.refreshTrendingReadme(owner: "bob", repo: "bar")
        let snap = await metrics.snapshot()
        #expect(snap.refresh200 == 1)
    }

    @Test("refreshTrendingReadme 404 → refresh404 +1")
    func trendingRefresh404RecordsRefresh404() async throws {
        let (api, mock, _, _, _, metrics, _) = try await makeAPI()
        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.notFound
        }
        _ = await api.refreshTrendingReadme(owner: "bob", repo: "bar")
        let snap = await metrics.snapshot()
        #expect(snap.refresh404 == 1)
    }

    // MARK: - 累计计数(多次调用)

    @Test("混合调用 → totalRefresh 与各计数器对齐")
    func mixedCallsAggregateCorrectly() async throws {
        let (api, mock, repo, readmeRepo, _, metrics, _) = try await makeAPI()

        // 1) 200 一次
        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: "<h1>x</h1>".data(using: .utf8)!, etag: "\"e1\"")
        }
        _ = await api.refreshReadme(for: repo)

        // 2) 304 两次(本地已有缓存)
        try await readmeRepo.upsert(makeReadme(repoId: repo.id, html: "<h1>c</h1>"))
        mock.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.notModified304(etag: "\"e1\"")
        }
        _ = await api.refreshReadme(for: repo)
        _ = await api.refreshReadme(for: repo)

        // 3) 404 一次
        mock.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.notFound
        }
        _ = await api.refreshReadme(for: repo)

        let snap = await metrics.snapshot()
        #expect(snap.refresh200 == 1)
        #expect(snap.refresh304 == 2)
        #expect(snap.refresh404 == 1)
        #expect(snap.refreshFailed == 0)
        #expect(snap.totalRefresh == 4)
    }
}
