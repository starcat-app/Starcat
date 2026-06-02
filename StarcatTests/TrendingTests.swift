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
        cached
    }

    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo] {
        fetchCallCount += 1
        if let handler = fetchHandler {
            return try await handler(since, language)
        }
        return repos
    }

    func lastRefreshedAt(since: TrendingPeriod, language: TrendingLanguage) async -> Date? {
        lastRefreshedAtValue
    }
}

private func makeTrendingRepo(
    fullName: String = "alice/demo",
    language: String? = "Swift",
    stars: Int = 1_000,
    forks: Int = 100,
    change: Int = 50
) -> TrendingRepo {
    let dto = TrendingResponseDTO(
        repo: "/\(fullName)",
        desc: "Demo",
        lang: language,
        stars: stars,
        forks: forks,
        buildBy: [
            TrendingContributorDTO(avatar: "https://avatars.githubusercontent.com/u/1?s=40&v=4", by: "/alice")
        ],
        change: change
    )
    return TrendingRepo(dto: dto, since: .daily)
}

@Suite("Trending", .serialized)
struct TrendingTests {

    @Test("TrendingAPI: live /repo schema with build_by decodes")
    func apiDecodesBuildByResponse() async throws {
        URLProtocolStub.reset()
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            [
              {
                "repo": "/signerlabs/ShipSwift",
                "desc": "AI-native SwiftUI component library",
                "lang": "Swift",
                "stars": 2069,
                "forks": 124,
                "build_by": [
                  {
                    "avatar": "https://avatars.githubusercontent.com/u/99269419?s=40&v=4",
                    "by": "/w-zhong"
                  }
                ],
                "change": 108
              }
            ]
            """#.data(using: .utf8)!
            return (trendingHTTPResponse(200, request.url!), body)
        }

        let repos = try await api.fetchTrending(since: .weekly, language: .swift)

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/repo")
        #expect(request.url?.query?.contains("since=weekly") == true)
        #expect(request.url?.query?.contains("lang=Swift") == true)

        let repo = try #require(repos.first)
        #expect(repo.fullName == "signerlabs/ShipSwift")
        #expect(repo.contributors.first?.username == "w-zhong")
        #expect(repo.starsInPeriod == 108)
    }

    @Test("TrendingAPI: missing optional upstream fields do not drop the whole list")
    func apiDecodesMissingOptionalFields() async throws {
        URLProtocolStub.reset()
        let api = TrendingAPI(
            baseURL: URL(string: "https://trend.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            [
              {
                "repo": "/owner/minimal",
                "desc": null,
                "lang": "",
                "stars": 42
              }
            ]
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

    // 注：原 `TrendingRepository.ttl(for:)` 静态 TTL 表已随 W7+ "trending 持久化（ttl_c：不设 TTL）"
    // 重构删除（dong4j 决策：每次进 Trending 都强制走网络重拉，本地缓存只承担"离线兜底 + 快速首屏 SWR"角色）。
    // 对应单测改为验证持久化分桶（cachedTrending / fetchTrending）行为，见
    // `TrendingRepositoryPersistenceTests` 套件。

    @MainActor
    @Test("TrendingViewModel: subscribe calls GitHub star endpoint")
    func subscribeCallsGitHubStar() async throws {
        let mock = MockGitHubAPIClient()
        mock.starHandler = { _, _ in }
        let vm = TrendingViewModel(
            repository: StubTrendingRepository(),
            githubAPIClient: mock
        )
        let repo = makeTrendingRepo(fullName: "owner/project")

        try await vm.subscribe(repo: repo)

        #expect(mock.starCalls.count == 1)
        #expect(mock.starCalls.first?.owner == "owner")
        #expect(mock.starCalls.first?.repo == "project")
        #expect(vm.subscribedRepoIDs.contains("owner/project"))
    }

    // MARK: - 智能 revision 行为（2026-06-02 新增，配合"消除二次入场动画"改造）

    @MainActor
    @Test("TrendingViewModel.reload(forceNetwork: false): cache hit skips network call")
    func reloadCacheHitSkipsNetworkWhenForceFalse() async throws {
        let cachedRepos = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]
        let stub = StubTrendingRepository(repos: cachedRepos, cached: cachedRepos)
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: false)

        #expect(vm.repos.count == 2)
        let count = await stub.fetchCallCount
        #expect(count == 0, "cache hit + forceNetwork=false should skip network entirely")
        #expect(vm.reposRevision == 1, "cache surface should still bump revision once for first-paint reveal")
    }

    @MainActor
    @Test("TrendingViewModel.reload(forceNetwork: true): cache hit still calls network")
    func reloadCacheHitFetchesWhenForceTrue() async throws {
        let cachedRepos = [
            makeTrendingRepo(fullName: "owner/a"),
            makeTrendingRepo(fullName: "owner/b")
        ]
        let stub = StubTrendingRepository(repos: cachedRepos, cached: cachedRepos)
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: true)

        let count = await stub.fetchCallCount
        #expect(count == 1, "forceNetwork=true should always fetch")
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

        await vm.reload(forceNetwork: true)

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

        await vm.reload(forceNetwork: true)

        // 第一阶段缓存上屏 +1，第二阶段身份变化 +1，共 2
        #expect(vm.reposRevision == 2, "identity changed should bump revision again")
        #expect(vm.repos.map(\.fullName) == ["owner/c", "owner/d"])
    }

    @MainActor
    @Test("TrendingViewModel.reload: empty cache forces network even when forceNetwork=false")
    func reloadEmptyCacheForcesNetwork() async throws {
        let fresh = [makeTrendingRepo(fullName: "owner/a")]
        let stub = StubTrendingRepository(repos: fresh, cached: [])
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: false)

        let count = await stub.fetchCallCount
        #expect(count == 1, "empty cache must always fetch, regardless of forceNetwork")
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

        await vm.reload(forceNetwork: false)

        // 缓存命中 + forceNetwork=false：lastRefreshedAt 应该来自 repository（120s 前）
        #expect(vm.lastRefreshedAt != nil)
        let secs = vm.secondsSinceLastRefresh ?? 0
        #expect(secs >= 100 && secs <= 200, "should be roughly 120s ago")
        #expect(vm.formattedFreshness != nil)
    }

    @MainActor
    @Test("TrendingViewModel: isStale true when last refresh > 1 hour ago")
    func isStaleAfterOneHour() async throws {
        let timestamp = Date(timeIntervalSinceNow: -7200)  // 2 小时前
        let stub = StubTrendingRepository(
            repos: [],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: timestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: false)

        #expect(vm.isStale == true)
    }

    @MainActor
    @Test("TrendingViewModel: isStale false when last refresh < 1 hour ago")
    func isStaleFalseWhenRecent() async throws {
        let timestamp = Date(timeIntervalSinceNow: -300)   // 5 分钟前
        let stub = StubTrendingRepository(
            repos: [],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: timestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: false)

        #expect(vm.isStale == false)
    }

    @MainActor
    @Test("TrendingViewModel: lastRefreshedAt updated to now after successful network fetch")
    func lastRefreshedAtUpdatedAfterFetch() async throws {
        let oldTimestamp = Date(timeIntervalSinceNow: -3600)
        let stub = StubTrendingRepository(
            repos: [makeTrendingRepo(fullName: "owner/a")],
            cached: [makeTrendingRepo(fullName: "owner/a")],
            lastRefreshedAt: oldTimestamp
        )
        let vm = TrendingViewModel(repository: stub, githubAPIClient: MockGitHubAPIClient())

        await vm.reload(forceNetwork: true)

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

        vm.updateLanguagePreferences(from: [
            LanguageStat(language: "Swift", count: 9),
            LanguageStat(language: "Python", count: 1)
        ])
        await vm.reload()

        #expect(vm.recommendedRepos.first?.fullName == "owner/swift-tool")
    }
}
