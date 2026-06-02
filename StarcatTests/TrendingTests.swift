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

    init(repos: [TrendingRepo] = [], cached: [TrendingRepo] = []) {
        self.repos = repos
        self.cached = cached
    }

    func cachedTrending(since: TrendingPeriod, language: TrendingLanguage) async -> [TrendingRepo] {
        cached
    }

    func fetchTrending(since: TrendingPeriod, language: TrendingLanguage) async throws -> [TrendingRepo] {
        repos
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
