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
