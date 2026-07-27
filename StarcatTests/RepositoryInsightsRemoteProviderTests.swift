//
//  RepositoryInsightsRemoteProviderTests.swift
//  StarcatTests
//
//  验证活动范围查询口径、四项 KPI 解码以及 SQLite cache-first 写读闭环。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repository insights remote provider")
struct RepositoryInsightsRemoteProviderTests {

    @Test("活动 KPI 使用选中范围查询并写入对应缓存")
    func activityCountsUseRangeAndPersistCache() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 21, owner: "octo", name: "metrics")
        let httpClient = ActivityMetricsHTTPClient(totals: [8, 5, 13, 7])
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")
        )
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "token",
            baseURL: URL(string: "https://api.example.test")!
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: client,
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )
        let identity = RepoIdentity(ghRepoID: 21, owner: "octo", name: "metrics")

        let refreshed = try await provider.refreshActivity(
            repository: identity,
            range: .month
        )
        let cached = try #require(
            try await provider.cachedActivity(repoID: 21, range: .month)
        )
        let queries = await httpClient.requests().compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value
        }

        #expect(refreshed.createdPullRequests == 8)
        #expect(refreshed.mergedPullRequests == 5)
        #expect(refreshed.createdIssues == 13)
        #expect(refreshed.closedIssues == 7)
        #expect(cached.value == refreshed)
        #expect(!cached.isStale)
        #expect(queries.count == 4)
        #expect(queries.allSatisfy { $0.contains("repo:octo/metrics") })
        #expect(queries.allSatisfy { $0.contains("2026-06-27..2026-07-27") })
        #expect(queries.contains { $0.contains("is:pr created:") })
        #expect(queries.contains { $0.contains("is:pr merged:") })
        #expect(queries.contains { $0.contains("is:issue created:") })
        #expect(queries.contains { $0.contains("is:issue closed:") })
    }

    @Test("Commit activity 保存 52 周原始结果并由客户端按活动范围裁剪")
    func commitActivityPersistsAndFiltersOnClient() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 22, owner: "octo", name: "commits")
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")
        )
        let oldWeek = Int(now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970)
        let recentWeek = Int(now.addingTimeInterval(-5 * 86_400).timeIntervalSince1970)
        let httpClient = CommitActivityHTTPClient(
            body: """
            [
              {"week":\(oldWeek),"total":12,"days":[1,2,3,2,2,1,1]},
              {"week":\(recentWeek),"total":7,"days":[1,1,1,1,1,1,1]}
            ]
            """
        )
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "token",
            baseURL: URL(string: "https://api.example.test")!
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: client,
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )

        let refreshed = try await provider.refreshCommitActivity(
            repository: RepoIdentity(ghRepoID: 22, owner: "octo", name: "commits")
        )
        let cached = try #require(try await provider.cachedCommitActivity(repoID: 22))
        let request = try #require(await httpClient.request())

        #expect(refreshed.points.count == 2)
        #expect(refreshed.points(in: .week).map(\.commits) == [7])
        #expect(refreshed.points(in: .month).map(\.commits) == [7])
        #expect(refreshed.points(in: .quarter).map(\.commits) == [12, 7])
        #expect(cached.value == refreshed)
        #expect(!cached.isStale)
        #expect(request.url?.path == "/repos/octo/commits/stats/commit_activity")
    }

    @Test("贡献者与社区规范映射为展示模型并独立缓存")
    func contributorsAndCommunityPersistIndependently() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 23, owner: "octo", name: "community")
        let httpClient = ContributorsCommunityHTTPClient()
        let now = Date(timeIntervalSince1970: 2_000)
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )
        let repository = RepoIdentity(ghRepoID: 23, owner: "octo", name: "community")

        let contributors = try await provider.refreshContributors(repository: repository)
        let community = try await provider.refreshCommunityProfile(repository: repository)
        let cachedContributors = try #require(
            try await provider.cachedContributors(repoID: 23)
        )
        let cachedCommunity = try #require(
            try await provider.cachedCommunityProfile(repoID: 23)
        )
        let paths = await httpClient.paths()

        #expect(contributors.contributors.map(\.login) == ["alice", "bob"])
        #expect(contributors.contributors.map(\.commits) == [42, 17])
        #expect(contributors.contributors.first?.avatarURL?.absoluteString == "https://avatars.test/alice")
        #expect(community.healthPercentage == 75)
        #expect(community.hasReadme)
        #expect(community.hasCodeOfConduct)
        #expect(!community.hasContributing)
        #expect(community.hasLicense)
        #expect(cachedContributors.value == contributors)
        #expect(cachedCommunity.value == community)
        #expect(paths == [
            "/repos/octo/community/contributors",
            "/repos/octo/community/community/profile"
        ])
    }
}

private actor ActivityMetricsHTTPClient: RAGHTTPClientProtocol {
    private var totals: [Int]
    private var recordedRequests: [URLRequest] = []

    init(totals: [Int]) {
        self.totals = totals
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let total = totals.removeFirst()
        let data = Data("{\"total_count\":\(total),\"items\":[]}".utf8)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor CommitActivityHTTPClient: RAGHTTPClientProtocol {
    private let body: String
    private var recordedRequest: URLRequest?

    init(body: String) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequest = request
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"commit-v1\""]
            )!
        )
    }

    func request() -> URLRequest? {
        recordedRequest
    }
}

private actor ContributorsCommunityHTTPClient: RAGHTTPClientProtocol {
    private var recordedPaths: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        recordedPaths.append(path)
        let body: String
        switch path {
        case "/repos/octo/community/contributors":
            body = """
            [
              {"login":"alice","contributions":42,"avatar_url":"https://avatars.test/alice"},
              {"login":"bob","contributions":17,"avatar_url":null}
            ]
            """
        case "/repos/octo/community/community/profile":
            body = """
            {
              "health_percentage":75,
              "files":{
                "readme":{},
                "code_of_conduct":{},
                "contributing":null,
                "license":{}
              }
            }
            """
        default:
            body = "{}"
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func paths() -> [String] {
        recordedPaths
    }
}
