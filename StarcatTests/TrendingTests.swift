//
//  TrendingTests.swift
//  StarcatTests
//
//  HOM-54 Trending 网络解码与 ViewModel 行为单测。
//

import Testing
import Foundation
@testable import Starcat

private func trendingHTTPResponse(
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

private actor StubTrendingRepository: TrendingRepositoryProtocol {
    var repos: [TrendingRepo]
    var cached: [TrendingRepo]
    var lastRefreshedAtValue: Date?
    var fetchCallCount: Int = 0
    var cachedCallCount: Int = 0
    var lastRefreshedCallCount: Int = 0

    /// 用于测试可注入的 fetch 行为（默认返回 self.repos，可重写为抛错或动态返回）。
    var fetchHandler: (@Sendable (_ since: TrendingPeriod, _ language: TrendingLanguage) async throws -> [TrendingRepo])?

    init(
        repos: [TrendingRepo] = [],
        cached: [TrendingRepo] = [],
        lastRefreshedAt: Date? = nil
    ) {
        self.repos = repos
        self.cached = cached
        self.lastRefreshedAtValue = lastRefreshedAt
    }

    func setRepos(_ value: [TrendingRepo]) {
        self.repos = value
    }

    func setFetchHandler(_ handler: @escaping @Sendable (_ since: TrendingPeriod, _ language: TrendingLanguage) async throws -> [TrendingRepo]) {
        self.fetchHandler = handler
    }

    func cachedTrending(since: TrendingPeriod, language: TrendingLanguage) async -> [TrendingRepo] {
        cachedCallCount += 1
        return cached
    }

    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo] {
        fetchCallCount += 1
        if let handler = fetchHandler {
            return try await handler(since, language)
        }
        return repos
    }

    func lastRefreshedAt(since: TrendingPeriod, language: TrendingLanguage) async -> Date? {
        lastRefreshedCallCount += 1
        return lastRefreshedAtValue
    }

    func storageReadCounts() -> (cached: Int, refreshedAt: Int) {
        (cachedCallCount, lastRefreshedCallCount)
    }
}

/// 测试用 helper：构造一个 TrendingRepo 业务对象。
/// R-01 v1.2 起走 `StarcatRepoCardDTO` + `TrendingRepo.init(card:since:)`，旧的
/// `TrendingResponseDTO` 路径已删。
private func makeTrendingRepo(
    fullName: String = "alice/demo",
    language: String? = "Swift",
    stars: Int = 1_000,
    forks: Int = 100,
    change: Int = 50
) -> TrendingRepo {
    let parts = fullName.split(separator: "/", maxSplits: 1)
    let owner = parts.count > 0 ? String(parts[0]) : ""
    let repo = parts.count > 1 ? String(parts[1]) : fullName

    // 不能在 ghRepoId 上 hash fullName 做唯一性（fullName 有 / 不能直接转 Int64），
    // 测试场景下 fullName 才是身份键，ghRepoId 就给个稳定 hash 简化。
    let ghRepoId = Int64(abs(fullName.hashValue % 1_000_000_000))
    let card = StarcatRepoCardDTO(
        ghRepoId: ghRepoId,
        fullName: fullName,
        owner: owner,
        repo: repo,
        description: "Demo",
        language: language,
        stars: stars,
        forks: forks,
        trending: StarcatRepoCardDTO.TrendingExtension(
            change: change,
            contributors: [
                StarcatRepoCardDTO.TrendingContributor(
                    avatar: URL(string: "https://avatars.githubusercontent.com/u/1?s=40&v=4")!,
                    login: "alice"
                )
            ]
        )
    )
    return TrendingRepo(card: card, since: .daily)
}

@Suite("Trending", .serialized)
struct TrendingTests {

    // R-01 v1.2：旧的非 envelope `/repo` 端点 + `build_by` 字段已废，所有测试改打
    // `/api/v1/repos` envelope 形态 + 验证 Bearer Auth header 注入。

    @Test("TrendingAPI v1: envelope decodes with trending extension")
    func apiDecodesEnvelopeWithTrendingExtension() async throws {
        URLProtocolStub.reset()
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            apiKey: "test-key-abc123",
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            {
              "schema_version": 1,
              "data": [
                {
                  "gh_repo_id": 12345,
                  "full_name": "signerlabs/ShipSwift",
                  "owner": "signerlabs",
                  "repo": "ShipSwift",
                  "owner_avatar": "https://avatars.githubusercontent.com/u/1?s=40&v=4",
                  "description": "AI-native SwiftUI component library",
                  "language": "Swift",
                  "stars": 2069,
                  "forks": 124,
                  "watchers": 2069,
                  "subscribers": 50,
                  "topics": ["swift", "ai"],
                  "homepage": null,
                  "license_spdx": "MIT",
                  "is_archived": false,
                  "is_fork": false,
                  "is_private": false,
                  "default_branch": "main",
                  "open_issues": 5,
                  "pushed_at": "2026-06-09T12:00:00Z",
                  "updated_at": "2026-06-09T12:00:00Z",
                  "created_at": "2025-01-01T00:00:00Z",
                  "html_url": "https://github.com/signerlabs/ShipSwift",
                  "trending": {
                    "change": 108,
                    "contributors": [
                      {
                        "avatar": "https://avatars.githubusercontent.com/u/99269419?s=40&v=4",
                        "login": "w-zhong"
                      }
                    ]
                  }
                }
              ]
            }
            """#.data(using: .utf8)!
            return (trendingHTTPResponse(200, request.url!), body)
        }

        let repos = try await api.fetchTrending(since: .weekly, language: .swift)

        let request = try #require(URLProtocolStub.receivedRequests.first)
        // R-01 v1.2：endpoint 切到 /api/v1/repos
        #expect(request.url?.path == "/api/v1/repos")
        #expect(request.url?.query?.contains("since=weekly") == true)
        #expect(request.url?.query?.contains("lang=Swift") == true)
        // Bearer Auth 必须注入
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-abc123")

        let repo = try #require(repos.first)
        #expect(repo.fullName == "signerlabs/ShipSwift")
        #expect(repo.contributors.first?.username == "w-zhong")
        #expect(repo.starsInPeriod == 108)
    }

    @Test("TrendingAPI v1: missing optional fields decode to defaults")
    func apiDecodesMissingOptionalFields() async throws {
        URLProtocolStub.reset()
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            // 仅必填 + 部分可选，验证 envelope 解码 + StarcatRepoCardDTO 容错。
            // gh_repo_id / full_name / owner / repo 必填；其它可选缺失走默认值（stars=0 等）。
            let body = #"""
            {
              "schema_version": 1,
              "data": [
                {
                  "gh_repo_id": 999,
                  "full_name": "owner/minimal",
                  "owner": "owner",
                  "repo": "minimal",
                  "description": null,
                  "language": "",
                  "stars": 42,
                  "forks": 0,
                  "watchers": 0,
                  "subscribers": 0,
                  "topics": [],
                  "is_archived": false,
                  "is_fork": false,
                  "is_private": false,
                  "open_issues": 0
                }
              ]
            }
            """#.data(using: .utf8)!
            return (trendingHTTPResponse(200, request.url!), body)
        }

        let repos = try await api.fetchTrending(since: .daily, language: .all)

        let repo = try #require(repos.first)
        #expect(repo.fullName == "owner/minimal")
        #expect(repo.forksCount == 0)
        #expect(repo.contributors.isEmpty)
        #expect(repo.starsInPeriod == 0)
    }

    @Test("TrendingAPI v1: 401 envelope error surfaces as serverError")
    func api401EnvelopeErrorSurfaces() async throws {
        URLProtocolStub.reset()
        // apiKey nil = 不发 Authorization 头，模拟未配置 key 的场景。
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            {
              "schema_version": 1,
              "error": {
                "code": "UNAUTHORIZED",
                "message": "missing Authorization header"
              }
            }
            """#.data(using: .utf8)!
            return (trendingHTTPResponse(401, request.url!), body)
        }

        await #expect(throws: TrendingAPIError.self) {
            _ = try await api.fetchTrending(since: .daily, language: .all)
        }
    }

    // 注：原 `TrendingRepository.ttl(for:)` 静态 TTL 表已随 W7+ "trending 持久化（ttl_c：不设 TTL）"
    // 重构删除（dong4j 决策：每次进 Trending 都强制走网络重拉，本地缓存只承担"离线兜底 + 快速首屏 SWR"角色）。
    // 对应单测改为验证持久化分桶（cachedTrending / fetchTrending）行为，见
    // `TrendingRepositoryPersistenceTests` 套件。

    // 注：原 `subscribeCallsGitHubStar` 单测已随 R-01 v1.2（2026-06-10）一并删除。
    // 删除背景：TrendingViewModel 不再持有会话级 `subscribedRepoIDs` 与 `subscribe(repo:)`；
    // star 操作走 `StarActionService.star(owner:repo:)` 单点（跨场景一致），由
    // `StarActionServiceTests` 套件统一覆盖（包含 stub apiClient.star 调用 + Registry add）。

    // MARK: - 骨架屏入场（与发现 / 周刊对齐）

    @MainActor
    @Test("TrendingViewModel 初始 isLoading=true，首帧就能进 RepoSkeletonListView")
    func initialStateReadyForSkeleton() {
        let stub = StubTrendingRepository(repos: [], cached: [])
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        #expect(vm.isLoading)
        #expect(vm.repos.isEmpty)
    }

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL) 缓存命中后结束 loading")
    func reloadCacheHitClearsLoading() async {
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -60)
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())
        #expect(vm.isLoading)

        await vm.reload(cachePolicy: .respectTTL)

        #expect(!vm.isLoading)
        #expect(vm.repos.count == 1)
    }

    @MainActor
    @Test("Trending 分类进入播放 row reveal，主动刷新不重复播放")
    func categoryActivationRevealsRowsButRefreshSkipsReveal() async {
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -60)
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.activate(language: .all, sort: .recommended)
        #expect(!vm.skipListRowReveal)

        await vm.reload(cachePolicy: .forceNetwork)
        #expect(vm.skipListRowReveal)
    }

    // MARK: - 智能 revision 行为（2026-06-02 新增，配合"消除二次入场动画"改造）

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL): cache hit + TTL 内 skips network call")
    func reloadCacheHitWithinTTLSkipsNetwork() async throws {
        let cachedRepos = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]
        // daily 缓存 30 分钟前刷过（低于 1h TTL），.respectTTL 应跳过网络
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -1_800)
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        #expect(vm.repos.count == 2)
        let count = await stub.fetchCallCount
        #expect(count == 0, "cache hit + TTL 内 + .respectTTL should skip network entirely")
        #expect(vm.reposRevision == 1, "cache surface should still bump revision once for first-paint reveal")
    }

    @MainActor
    @Test("Trending 返回同一查询桶直接命中内存快照，不重复读取 SQLite")
    func sameQueryReentryUsesMemorySnapshot() async {
        let cachedRepos = (0..<45).map {
            makeTrendingRepo(fullName: "owner/reentry-\($0)")
        }
        let stub = StubTrendingRepository(
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -60)
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)
        vm.loadMoreIfNeeded(currentIndex: 16, totalAvailable: cachedRepos.count)
        let firstReads = await stub.storageReadCounts()
        let firstRevision = vm.reposRevision

        await vm.reload(cachePolicy: .respectTTL)

        let secondReads = await stub.storageReadCounts()
        #expect(secondReads.cached == firstReads.cached)
        #expect(secondReads.refreshedAt == firstReads.refreshedAt)
        #expect(vm.reposRevision == firstRevision)
        #expect(vm.visibleLimit == 40)
        #expect(vm.hasPublishedCurrentQuery)
    }

    @MainActor
    @Test("Trending 首屏仅开放 20 条，并按滚动阈值逐页增长")
    func visiblePageGrowsInTwentyItemChunks() async {
        let cachedRepos = (0..<45).map {
            makeTrendingRepo(fullName: "owner/repo-\($0)")
        }
        let stub = StubTrendingRepository(
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -60)
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        #expect(vm.repos.count == 45)
        #expect(vm.visibleLimit == 20)
        vm.loadMoreIfNeeded(currentIndex: 16, totalAvailable: 45)
        #expect(vm.visibleLimit == 40)
        vm.loadMoreIfNeeded(currentIndex: 36, totalAvailable: 45)
        #expect(vm.visibleLimit == 45)
    }

    @MainActor
    @Test("Trending 相同查询并发 reload 只保留一个 Repository 请求")
    func concurrentSameQueryReloadsShareOneRequest() async {
        let stub = StubTrendingRepository()
        await stub.setFetchHandler { _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return [makeTrendingRepo(fullName: "owner/once")]
        }
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        let first = Task { @MainActor in
            await vm.reload(cachePolicy: .respectTTL)
        }
        await Task.yield()
        let second = Task { @MainActor in
            await vm.reload(cachePolicy: .respectTTL)
        }
        await first.value
        await second.value

        #expect(await stub.fetchCallCount == 1)
        #expect(vm.repos.map(\.fullName) == ["owner/once"])
    }

    @MainActor
    @Test("Trending 快速切换周期时旧请求结果不能覆盖新查询")
    func stalePeriodRequestCannotOverwriteLatestQuery() async {
        let stub = StubTrendingRepository()
        await stub.setFetchHandler { period, _ in
            if period == .daily {
                // 故意吞掉取消并晚返回，验证 ViewModel 的 generation guard。
                try? await Task.sleep(for: .milliseconds(80))
                return [makeTrendingRepo(fullName: "owner/daily")]
            }
            return [makeTrendingRepo(fullName: "owner/weekly")]
        }
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        let oldReload = Task { @MainActor in
            await vm.reload(cachePolicy: .respectTTL)
        }
        while await stub.fetchCallCount == 0 {
            await Task.yield()
        }
        await vm.selectPeriod(.weekly)
        await oldReload.value

        #expect(vm.selectedPeriod == .weekly)
        #expect(vm.repos.map(\.fullName) == ["owner/weekly"])
        #expect(vm.hasPublishedCurrentQuery)
    }

    @MainActor
    @Test("TrendingViewModel.reload(.forceNetwork): cache hit still calls network")
    func reloadCacheHitFetchesWhenForceNetwork() async throws {
        let cachedRepos = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -60)  // 即便 1 分钟前刚刷过
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .forceNetwork)

        let count = await stub.fetchCallCount
        #expect(count == 1, ".forceNetwork should always fetch even within TTL")
    }

    // MARK: - R-06.1 TTL 边界单测

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL): cache hit + TTL 过期 → 走网络")
    func reloadCacheHitBeyondTTLFetchesNetwork() async throws {
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        // daily 缓存超过 1h TTL，.respectTTL 应回退到网络
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -(TrendingViewModel.ttl(for: .daily) + 60))
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        let count = await stub.fetchCallCount
        #expect(count == 1, "TTL 过期 → .respectTTL 也要走网络（自动后台刷新）")
    }

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL): cache hit + 边界刚过 TTL → 走网络")
    func reloadCacheHitJustBeyondTTLFetches() async throws {
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        // daily TTL 刚过 1 秒，应判定过期
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -(TrendingViewModel.ttl(for: .daily) + 1))
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        let count = await stub.fetchCallCount
        #expect(count == 1, "刚过 TTL 1 秒就应走网络")
    }

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL): cache hit + 边界刚到 TTL 内 → 跳过网络")
    func reloadCacheHitWithinTTLBoundaryNoFetch() async throws {
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        // daily TTL 刚好差 1 秒，仍在 TTL 内
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: Date(timeIntervalSinceNow: -(TrendingViewModel.ttl(for: .daily) - 1))
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        let count = await stub.fetchCallCount
        #expect(count == 0, "差 1 秒到 TTL 应继续走缓存")
    }

    @MainActor
    @Test("TrendingViewModel.ttl: daily 1h / weekly 6h / monthly 24h")
    func periodTTLValues() {
        #expect(TrendingViewModel.ttl(for: .daily) == 1 * 60 * 60)
        #expect(TrendingViewModel.ttl(for: .weekly) == 6 * 60 * 60)
        #expect(TrendingViewModel.ttl(for: .monthly) == 24 * 60 * 60)
    }

    @MainActor
    @Test("TrendingViewModel.reload(.respectTTL): lastRefreshedAt = nil 永远拉网络")
    func reloadCacheHitWithoutLastRefreshedAtFetchesNetwork() async throws {
        // 异常路径：repository 返回 cached 数据但没记录 lastRefreshedAt（理论上不可能，但加单测兜底防御）
        let cachedRepos = [makeTrendingRepo(fullName: "owner/a")]
        let stub = StubTrendingRepository(
            repos: cachedRepos,
            cached: cachedRepos,
            lastRefreshedAt: nil
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        let count = await stub.fetchCallCount
        #expect(count == 1, "lastRefreshedAt 缺失 → 保守判定为 TTL 外，走网络")
    }

    @MainActor
    @Test("TrendingViewModel.reload: fresh data with same identity does NOT bump revision")
    func reloadDoesNotBumpRevisionWhenIdentityUnchanged() async throws {
        let cached = [
            makeTrendingRepo(fullName: "owner/a", stars: 100),
            makeTrendingRepo(fullName: "owner/b", stars: 200)
        ]
        // 网络返回的数据：相同 fullName 列表，但 stars 数变了
        let fresh = [
            makeTrendingRepo(fullName: "owner/a", stars: 150),
            makeTrendingRepo(fullName: "owner/b", stars: 250)
        ]
        let stub = StubTrendingRepository(repos: fresh, cached: cached)
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .forceNetwork)

        // 第一阶段缓存上屏 bump revision (revision=1)
        // 第二阶段网络回来发现 fullName 序列相同 → NOT bump (revision stays 1)
        #expect(vm.reposRevision == 1, "identity unchanged means in-place update only, no extra revision bump")
        // 但 stars 数应该已经被网络数据覆盖（in-place diff）
        #expect(vm.repos.first?.starsCount == 150, "stars count should be updated in-place")
    }

    @MainActor
    @Test("TrendingViewModel.reload: fresh data with different identity bumps revision")
    func reloadBumpsRevisionWhenIdentityChanged() async throws {
        let cached = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]
        // 网络返回完全不同的列表
        let fresh = [
            makeTrendingRepo(fullName: "owner/c"),
            makeTrendingRepo(fullName: "owner/d")
        ]
        let stub = StubTrendingRepository(repos: fresh, cached: cached)
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .forceNetwork)

        // 第一阶段缓存上屏 +1，第二阶段身份变化 +1，共 2
        #expect(vm.reposRevision == 2, "identity changed should bump revision again")
        #expect(vm.repos.map(\.fullName) == ["owner/c", "owner/d"])
    }

    @MainActor
    @Test("TrendingViewModel.reload: empty cache forces network even with .respectTTL")
    func reloadEmptyCacheForcesNetwork() async throws {
        let fresh = [makeTrendingRepo(fullName: "owner/a")]
        let stub = StubTrendingRepository(repos: fresh, cached: [])
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        let count = await stub.fetchCallCount
        #expect(count == 1, "empty cache must always fetch, regardless of cachePolicy")
        #expect(vm.repos.count == 1)
    }

    @MainActor
    @Test("TrendingViewModel: lastRefreshedAt populated from repository on reload")
    func lastRefreshedAtPopulated() async throws {
        let timestamp = Date(timeIntervalSinceNow: -120)   // 2 分钟前
        let stub = StubTrendingRepository(
            repos: [makeTrendingRepo(fullName: "owner/a")],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: timestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        // 缓存命中 + .respectTTL + TTL 内：lastRefreshedAt 应该来自 repository（120s 前）
        #expect(vm.lastRefreshedAt != nil)
        let secs = vm.secondsSinceLastRefresh ?? 0
        #expect(secs >= 100 && secs <= 200, "should be roughly 120s ago")
        #expect(vm.formattedFreshness != nil)
    }

    @MainActor
    @Test("TrendingViewModel: daily 超过 TTL 80% 时 isStale=true")
    func isStaleAfterDailyWarningThreshold() async throws {
        // daily TTL=1h，50 分钟已超过 80% 预警线但尚未过期，因此不会被自动刷新覆盖。
        let timestamp = Date(timeIntervalSinceNow: -50 * 60)
        let stub = StubTrendingRepository(
            repos: [],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: timestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        #expect(vm.isStale == true)
    }

    @MainActor
    @Test("TrendingViewModel: daily 未到 TTL 80% 时 isStale=false")
    func isStaleFalseBeforeDailyWarningThreshold() async throws {
        let timestamp = Date(timeIntervalSinceNow: -30 * 60)
        let stub = StubTrendingRepository(
            repos: [],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: timestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .respectTTL)

        #expect(vm.isStale == false, "daily 30 分钟未到 80% 预警线")
    }

    @MainActor
    @Test("TrendingViewModel: lastRefreshedAt updated to now after successful network fetch")
    func lastRefreshedAtUpdatedAfterFetch() async throws {
        let oldTimestamp = Date(timeIntervalSinceNow: -90_000)  // 25h 前（TTL 外，会触发拉网络）
        let stub = StubTrendingRepository(
            repos: [makeTrendingRepo(fullName: "owner/a")],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: oldTimestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(cachePolicy: .forceNetwork)

        // 网络成功 → lastRefreshedAt 应该被更新为 Date()（接近 now）
        let secs = vm.secondsSinceLastRefresh ?? Double.greatestFiniteMagnitude
        #expect(secs < 5, "lastRefreshedAt should be very recent after successful fetch")
    }

    @MainActor
    @Test("TrendingViewModel: recommendations prefer local language distribution")
    func recommendationsPreferLanguagePreferences() async throws {
        let swift = makeTrendingRepo(fullName: "owner/swift-tool", language: "Swift", stars: 100, forks: 1, change: 1)
        let python = makeTrendingRepo(fullName: "owner/python-tool", language: "Python", stars: 10_000, forks: 1_000, change: 2_000)
        let repo = StubTrendingRepository(repos: [python, swift])
        let vm = TrendingViewModel(repository: repo, githubAPIClient: MockGitHubAPIClient())

        await vm.updateLanguagePreferences(from: [
            LanguageStat(language: "Swift", count: 9),
            LanguageStat(language: "Python", count: 1)
        ])
        await vm.reload()

        #expect(vm.recommendedRepos.first?.fullName == "owner/swift-tool")
    }

    @MainActor
    @Test("Trending 全局筛选由后台快照派生，并保留 Wiki unknown 语义")
    func globalFilterIsDerivedByPipeline() async throws {
        let keep = makeTrendingRepo(fullName: "owner/swift-tool", language: "Swift")
        let drop = makeTrendingRepo(fullName: "owner/python-tool", language: "Python")
        let repository = StubTrendingRepository(repos: [keep, drop])
        let vm = TrendingViewModel(repository: repository, githubAPIClient: MockGitHubAPIClient())

        await vm.reload()
        await vm.updateGlobalFilter(TrendingListFilter(
            star: .starred,
            library: .inLibrary,
            hideArchived: false,
            hideForks: false,
            languages: ["swift"],
            wikiAvailability: .available,
            healthAvailability: .available,
            openSSFAvailability: .available,
            starredRepoIDs: [keep.ghRepoId],
            inLibraryRepoIDs: [keep.ghRepoId],
            wikiKnownRepoIDs: [keep.ghRepoId],
            wikiAvailableRepoIDs: [keep.ghRepoId],
            healthAvailableRepoIDs: [keep.ghRepoId],
            openSSFAvailableRepoIDs: [keep.ghRepoId]
        ))

        #expect(vm.displayedRepos.map(\.fullName) == [keep.fullName])
        #expect(vm.filterCandidateRepos.count == 2, "信号补载必须保留未筛选候选")

        await vm.updateGlobalFilter(TrendingListFilter(
            star: .all,
            library: .all,
            hideArchived: false,
            hideForks: false,
            languages: [],
            wikiAvailability: .missing,
            healthAvailability: .unknown,
            openSSFAvailability: .unknown,
            starredRepoIDs: [],
            inLibraryRepoIDs: [],
            wikiKnownRepoIDs: [drop.ghRepoId],
            wikiAvailableRepoIDs: [],
            healthAvailableRepoIDs: [],
            openSSFAvailableRepoIDs: []
        ))

        #expect(vm.displayedRepos.map(\.fullName) == [drop.fullName])
    }

    @Test("Trending prepared snapshot 命中不重复派生，新事实源只失效对应桶")
    func preparedSnapshotSkipsRepeatedDerivation() async {
        let pipeline = TrendingListPipeline()
        let identity = TrendingQueryIdentity(period: .daily, language: .all)
        let context = TrendingDerivationContext(
            sort: .recommended,
            filter: .all,
            languagePreferences: ["Swift": 1]
        )
        let repos = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]

        _ = await pipeline.prepare(repos: repos, for: identity, context: context)
        #expect(await pipeline.derivationCountForTesting() == 1)

        let cached = await pipeline.preparedSnapshot(for: identity, context: context)
        #expect(cached?.repos.map(\.fullName) == ["owner/a", "owner/b"])
        #expect(await pipeline.derivationCountForTesting() == 1,
                "同 identity + context 命中必须直接返回 prepared snapshot")

        let sortedContext = TrendingDerivationContext(
            sort: .nameDesc,
            filter: .all,
            languagePreferences: ["Swift": 1]
        )
        _ = await pipeline.preparedSnapshot(for: identity, context: sortedContext)
        #expect(await pipeline.derivationCountForTesting() == 2)

        _ = await pipeline.prepare(
            repos: [makeTrendingRepo(fullName: "owner/c")],
            for: identity,
            context: context
        )
        #expect(await pipeline.derivationCountForTesting() == 3,
                "同桶新事实源必须淘汰旧 prepared snapshot 并重新派生")
    }

    @Test("Trending prepared snapshot LRU 超过 12 项后淘汰最旧 context")
    func preparedSnapshotLRUEvictsOldestContext() async {
        let pipeline = TrendingListPipeline()
        let identity = TrendingQueryIdentity(period: .daily, language: .all)
        let repos = [makeTrendingRepo(fullName: "owner/a")]
        let contexts = (0...12).map { index in
            TrendingDerivationContext(
                sort: .recommended,
                filter: .all,
                languagePreferences: ["Lang\(index)": Double(index)]
            )
        }

        _ = await pipeline.prepare(repos: repos, for: identity, context: contexts[0])
        for context in contexts.dropFirst() {
            _ = await pipeline.preparedSnapshot(for: identity, context: context)
        }
        let derivationsAfterThirteenContexts = await pipeline.derivationCountForTesting()

        _ = await pipeline.preparedSnapshot(for: identity, context: contexts[0])
        #expect(await pipeline.derivationCountForTesting() == derivationsAfterThirteenContexts + 1,
                "容量为 12 时，第 13 个 context 必须淘汰最久未访问项")
    }
}
