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
        #expect(refreshed.pullRequestThroughput == 5.0 / 8.0)
        #expect(refreshed.issueThroughput == 7.0 / 13.0)
        #expect(refreshed.netIssueChange == 6)
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

    @Test("活动吞吐比在没有新建项时保持未知而不是伪造零值")
    func activityThroughputKeepsZeroDenominatorUnknown() {
        let counts = RepositoryActivityCounts(
            createdPullRequests: 0,
            mergedPullRequests: 3,
            createdIssues: 0,
            closedIssues: 4,
            generatedAt: .distantPast
        )

        #expect(counts.pullRequestThroughput == nil)
        #expect(counts.issueThroughput == nil)
        #expect(counts.netIssueChange == -4)
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

    @Test("维护脉搏比较最近四周与此前四周")
    func maintenancePulseUsesAdjacentFourWeekWindows() {
        let start = Date(timeIntervalSince1970: 1_000)
        let commits = [1, 0, 2, 1, 3, 0, 5, 2]
        let activity = RepositoryCommitActivity(
            points: commits.enumerated().map { index, count in
                RepositoryCommitActivityPoint(
                    weekStart: start.addingTimeInterval(Double(index) * 7 * 86_400),
                    commits: count
                )
            },
            generatedAt: start.addingTimeInterval(8 * 7 * 86_400)
        )
        let pulse = activity.maintenancePulse

        #expect(pulse?.recentCommits == 10)
        #expect(pulse?.comparisonPercentage == 150)
        #expect(pulse?.activeWeeks == 3)
    }

    @Test("维护脉搏在历史不足或上一窗口为零时不伪造比较值")
    func maintenancePulseKeepsUnavailableComparisonUnknown() {
        let start = Date(timeIntervalSince1970: 1_000)
        let short = RepositoryCommitActivity(
            points: [
                RepositoryCommitActivityPoint(weekStart: start, commits: 1)
            ],
            generatedAt: start
        )
        let zeroBaseline = RepositoryCommitActivity(
            points: (0..<8).map { index in
                RepositoryCommitActivityPoint(
                    weekStart: start.addingTimeInterval(Double(index) * 7 * 86_400),
                    commits: index >= 4 ? 1 : 0
                )
            },
            generatedAt: start.addingTimeInterval(8 * 7 * 86_400)
        )

        #expect(short.maintenancePulse == nil)
        #expect(zeroBaseline.maintenancePulse?.comparisonPercentage == nil)
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
        #expect(abs((contributors.concentration?.topContributorShare ?? 0) - 42.0 / 59.0) < 0.000_001)
        #expect(contributors.concentration?.topThreeShare == 1)
        #expect(contributors.concentration?.sampledContributors == 2)
        #expect(contributors.contributors.first?.avatarURL?.absoluteString == "https://avatars.test/alice")
        #expect(
            contributors.contributors.map { $0.profileHTMLURL?.absoluteString } == [
                "https://github.com/alice",
                "https://github.com/bob"
            ]
        )
        #expect(community.healthPercentage == 75)
        #expect(community.hasReadme)
        #expect(community.hasCodeOfConduct)
        #expect(!community.hasContributing)
        #expect(community.hasLicense)
        #expect(community.readmeHTMLURL?.absoluteString == "https://github.com/octo/community#readme")
        #expect(
            community.codeOfConductHTMLURL?.absoluteString
                == "https://github.com/octo/community/blob/main/CODE_OF_CONDUCT.md"
        )
        #expect(community.contributingHTMLURL == nil)
        #expect(
            community.licenseHTMLURL?.absoluteString
                == "https://github.com/octo/community/blob/main/LICENSE"
        )
        #expect(cachedContributors.value == contributors)
        #expect(cachedCommunity.value == community)
        #expect(paths == [
            "/repos/octo/community/contributors",
            "/repos/octo/community/community/profile"
        ])
    }

    @Test("贡献者集中度忽略负数并在没有有效提交时保持未知")
    func contributorConcentrationRequiresPositiveContributionTotal() {
        let insight = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(
                    id: "alice",
                    login: "alice",
                    commits: 0,
                    colorName: "purple"
                ),
                RepositoryContributor(
                    id: "bob",
                    login: "bob",
                    commits: -1,
                    colorName: "blue"
                )
            ],
            generatedAt: .distantPast
        )

        #expect(insight.concentration == nil)
    }

    @Test("最近活动合并 PR 与 Issue 并按真实时间倒序缓存")
    func recentActivityMergesAndSortsEvents() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 24, owner: "octo", name: "timeline")
        let httpClient = RecentActivityHTTPClient()
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        let refreshed = try await provider.refreshRecentActivity(
            repository: RepoIdentity(ghRepoID: 24, owner: "octo", name: "timeline")
        )
        let cached = try #require(try await provider.cachedRecentActivity(repoID: 24))
        let queries = await httpClient.queries()

        #expect(refreshed.events.map(\.id) == ["issue-7", "pullRequest-42"])
        #expect(refreshed.events.map(\.title) == ["Fix crash", "Improve cache"])
        #expect(cached.value == refreshed)
        #expect(queries.count == 2)
        #expect(queries.contains { $0.contains("is:pr") })
        #expect(queries.contains { $0.contains("is:issue") })
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
              {"login":"alice","contributions":42,"avatar_url":"https://avatars.test/alice","html_url":"https://github.com/alice"},
              {"login":"bob","contributions":17,"avatar_url":null,"html_url":"https://github.com/bob"}
            ]
            """
        case "/repos/octo/community/community/profile":
            body = """
            {
              "health_percentage":75,
              "files":{
                "readme":{"html_url":"https://github.com/octo/community#readme"},
                "code_of_conduct":{"html_url":"https://www.contributor-covenant.org/version/2/1/code_of_conduct/"},
                "code_of_conduct_file":{"html_url":"https://github.com/octo/community/blob/main/CODE_OF_CONDUCT.md"},
                "contributing":null,
                "license":{"html_url":"https://github.com/octo/community/blob/main/LICENSE"}
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

private actor RecentActivityHTTPClient: RAGHTTPClientProtocol {
    private var recordedQueries: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let query = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        recordedQueries.append(query)
        let item: String
        if query.contains("is:pr") {
            item = """
            {
              "number":42,
              "title":"Improve cache",
              "state":"closed",
              "html_url":"https://github.com/octo/timeline/pull/42",
              "labels":[],
              "comments":2,
              "created_at":"2026-07-20T00:00:00Z",
              "closed_at":"2026-07-25T00:00:00Z",
              "updated_at":"2026-07-25T00:00:00Z",
              "repository_url":"https://api.github.com/repos/octo/timeline",
              "pull_request":{}
            }
            """
        } else {
            item = """
            {
              "number":7,
              "title":"Fix crash",
              "state":"closed",
              "html_url":"https://github.com/octo/timeline/issues/7",
              "labels":[],
              "comments":1,
              "created_at":"2026-07-24T00:00:00Z",
              "closed_at":"2026-07-26T00:00:00Z",
              "updated_at":"2026-07-26T00:00:00Z",
              "repository_url":"https://api.github.com/repos/octo/timeline"
            }
            """
        }
        let body = "{\"total_count\":1,\"items\":[\(item)]}"
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

    func queries() -> [String] {
        recordedQueries
    }
}
