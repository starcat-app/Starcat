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

    @Test("共享 Provider 合并相同仓库与范围的并发刷新")
    func sharedProviderCoalescesConcurrentRefreshes() async throws {
        let base = ActivityOnlyRemoteInsightsProvider()
        let provider = SharedRepositoryRemoteInsightsProvider(base: base)
        let repository = RepoIdentity(ghRepoID: 20, owner: "octo", name: "shared")

        async let first = provider.refreshActivity(repository: repository, range: .month)
        async let second = provider.refreshActivity(repository: repository, range: .month)
        let values = try await [first, second]

        #expect(values[0] == values[1])
        #expect(await base.refreshCount() == 1)
    }

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

    @Test("活动概览与最近动态并发加载只发出一次 GraphQL 请求")
    func activityAndRecentActivityShareGraphQLBundle() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 27, owner: "octo", name: "bundle")
        let httpClient = ActivityBundleHTTPClient()
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )
        let repository = RepoIdentity(ghRepoID: 27, owner: "octo", name: "bundle")

        async let activity = provider.refreshActivity(
            repository: repository,
            range: .month
        )
        async let recent = provider.refreshRecentActivity(
            repository: repository,
            activityRange: .month
        )
        let (activityValue, recentValue) = try await (activity, recent)
        let requests = await httpClient.requests()
        let cachedActivity = try #require(
            try await provider.cachedActivity(repoID: 27, range: .month)
        )
        let cachedRecent = try #require(
            try await provider.cachedRecentActivity(repoID: 27)
        )

        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/graphql")
        #expect(activityValue.createdPullRequests == 8)
        #expect(activityValue.mergedPullRequests == 5)
        #expect(activityValue.createdIssues == 13)
        #expect(activityValue.closedIssues == 7)
        #expect(recentValue.events.map(\.id) == ["issue-7", "pullRequest-42"])
        #expect(cachedActivity.value == activityValue)
        #expect(cachedRecent.value == recentValue)
    }

    @Test("完整冷加载正常路径最多五次请求并写入六类缓存")
    func fullColdLoadUsesFiveRequestBudget() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 28, owner: "octo", name: "budget")
        let httpClient = FullLoadMetricsHTTPClient()
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )
        let repository = RepoIdentity(ghRepoID: 28, owner: "octo", name: "budget")

        async let activity = provider.refreshActivity(repository: repository, range: .month)
        async let commit = provider.refreshCommitActivity(repository: repository)
        async let contributors = provider.refreshContributors(repository: repository)
        async let community = provider.refreshCommunityProfile(repository: repository)
        async let security = provider.refreshSecurityAdvisories(repository: repository)
        async let recent = provider.refreshRecentActivity(
            repository: repository,
            activityRange: .month
        )
        _ = try await (activity, commit, contributors, community, security, recent)

        let requests = await httpClient.requests()
        let paths = requests.compactMap(\.url?.path)
        #expect(requests.count == 5)
        #expect(paths.filter { $0 == "/graphql" }.count == 1)
        #expect(Set(paths) == [
            "/graphql",
            "/repos/octo/budget/stats/commit_activity",
            "/repos/octo/budget/contributors",
            "/repos/octo/budget/community/profile",
            "/repos/octo/budget/security-advisories"
        ])
        #expect(try await provider.cachedActivity(repoID: 28, range: .month) != nil)
        #expect(try await provider.cachedCommitActivity(repoID: 28) != nil)
        #expect(try await provider.cachedContributors(repoID: 28) != nil)
        #expect(try await provider.cachedCommunityProfile(repoID: 28) != nil)
        #expect(try await provider.cachedSecurityAdvisories(repoID: 28) != nil)
        #expect(try await provider.cachedRecentActivity(repoID: 28) != nil)
        #expect(await httpClient.requests().count == 5)
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
        // 「1 周 / 1 月」展开 days；更长范围仍周柱。
        #expect(refreshed.points(in: .week).map(\.commits) == [1, 1, 1, 1, 1, 1, 1])
        #expect(refreshed.points(in: .week).count == 7)
        #expect(refreshed.points(in: .month).map(\.commits) == [1, 1, 1, 1, 1, 1, 1])
        #expect(refreshed.points(in: .quarter).map(\.commits) == [12, 7])
        #expect(cached.value == refreshed)
        #expect(refreshed.points.last?.days == [1, 1, 1, 1, 1, 1, 1])
        #expect(!cached.isStale)
        #expect(request.url?.path == "/repos/octo/commits/stats/commit_activity")
    }

    @Test("1 周 / 1 月展开 days；缺 days 或更长范围保持周柱")
    func shortRangesExpandDaysOrFallBackToWeeklyBars() {
        let weekStart = Date(timeIntervalSince1970: 1_700_000_000)
        let previousWeek = weekStart.addingTimeInterval(-7 * 86_400)
        let generatedAt = weekStart.addingTimeInterval(6 * 86_400)
        let withDays = RepositoryCommitActivity(
            points: [
                RepositoryCommitActivityPoint(
                    weekStart: previousWeek,
                    commits: 10,
                    days: [2, 2, 2, 1, 1, 1, 1]
                ),
                RepositoryCommitActivityPoint(
                    weekStart: weekStart,
                    commits: 28,
                    days: [1, 2, 3, 4, 5, 6, 7]
                )
            ],
            generatedAt: generatedAt
        )
        let legacy = RepositoryCommitActivity(
            points: [
                RepositoryCommitActivityPoint(weekStart: weekStart, commits: 9)
            ],
            generatedAt: generatedAt
        )

        #expect(withDays.points(in: .week).map(\.commits) == [1, 2, 3, 4, 5, 6, 7])
        #expect(
            withDays.points(in: .week).map(\.weekStart)
                == (0..<7).map { weekStart.addingTimeInterval(TimeInterval($0) * 86_400) }
        )
        #expect(
            withDays.points(in: .month).map(\.commits)
                == [2, 2, 2, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7]
        )
        #expect(withDays.points(in: .quarter).map(\.commits) == [10, 28])
        #expect(withDays.points(in: .year).map(\.commits) == [10, 28])
        #expect(legacy.points(in: .week).map(\.commits) == [9])
        #expect(legacy.points(in: .month).map(\.commits) == [9])
        #expect(RepositoryActivityRange.week.usesDailyCommitBars)
        #expect(RepositoryActivityRange.month.usesDailyCommitBars)
        #expect(!RepositoryActivityRange.quarter.usesDailyCommitBars)
    }

    @Test("过期提交活动使用 ETag 条件请求并在 304 后复用缓存")
    func commitActivityRevalidatesCachedPayload() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 26, owner: "octo", name: "conditional")
        let now = Date(timeIntervalSince1970: 4_000)
        let httpClient = ConditionalCommitActivityHTTPClient()
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )
        let repository = RepoIdentity(
            ghRepoID: 26,
            owner: "octo",
            name: "conditional"
        )

        let initial = try await provider.refreshCommitActivity(repository: repository)
        let cached = try #require(try await provider.cachedCommitActivity(repoID: 26))
        let revalidated = try await provider.refreshCommitActivity(
            repository: repository,
            ifNoneMatch: cached.responseETag
        )
        let requests = await httpClient.requests()

        #expect(initial == revalidated)
        #expect(cached.responseETag == "\"commit-v1\"")
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(
            requests[1].value(forHTTPHeaderField: "If-None-Match")
                == "\"commit-v1\""
        )
    }

    @Test("304 返回前缓存丢失会无条件重拉一次")
    func missingPayloadAfterNotModifiedTriggersUnconditionalRetry() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 28, owner: "octo", name: "retry")
        let cache = GRDBRepositoryInsightsCache(database: database)
        let now = Date(timeIntervalSince1970: 5_000)
        try await cache.store(
            RepositoryCommitActivity(
                points: [RepositoryCommitActivityPoint(weekStart: now, commits: 1)],
                generatedAt: now
            ),
            repoId: 28,
            dataset: .commitActivity,
            range: .all,
            fetchedAt: now,
            responseETag: "\"commit-v1\"",
            defaultBranchSHA: nil
        )
        let httpClient = MissingPayloadConditionalHTTPClient {
            try await cache.remove(
                repoId: 28,
                dataset: .commitActivity,
                range: .all
            )
        }
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: cache,
            now: { now }
        )

        let refreshed = try await provider.refreshCommitActivity(
            repository: RepoIdentity(ghRepoID: 28, owner: "octo", name: "retry"),
            ifNoneMatch: "\"commit-v1\""
        )
        let requests = await httpClient.requests()
        let cached = try #require(try await provider.cachedCommitActivity(repoID: 28))

        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == "\"commit-v1\"")
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(refreshed.points.map(\.commits) == [11])
        #expect(cached.value == refreshed)
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
        #expect(community.hasIssueTemplate)
        #expect(community.hasLicense)
        #expect(community.hasPullRequestTemplate)
        #expect(community.readmeHTMLURL?.absoluteString == "https://github.com/octo/community#readme")
        #expect(
            community.codeOfConductHTMLURL?.absoluteString
                == "https://github.com/octo/community/blob/main/CODE_OF_CONDUCT.md"
        )
        #expect(community.contributingHTMLURL == nil)
        #expect(
            community.issueTemplateHTMLURL?.absoluteString
                == "https://github.com/octo/community/tree/main/.github/ISSUE_TEMPLATE"
        )
        #expect(
            community.licenseHTMLURL?.absoluteString
                == "https://github.com/octo/community/blob/main/LICENSE"
        )
        #expect(
            community.pullRequestTemplateHTMLURL?.absoluteString
                == "https://github.com/octo/community/blob/main/.github/PULL_REQUEST_TEMPLATE.md"
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

    @Test("发布节奏读取 GitHub 最近 12 次 Release 并写入独立缓存")
    func releaseCadenceMapsAndPersistsIndependently() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 26, owner: "octo", name: "cadence")
        let httpClient = ReleaseCadenceHTTPClient(
            body: """
            [
              {
                "tag_name":"v3",
                "name":"Version 3",
                "body":null,
                "html_url":"https://github.com/octo/cadence/releases/tag/v3",
                "published_at":"2026-07-20T00:00:00Z"
              },
              {
                "tag_name":"v2",
                "name":null,
                "body":null,
                "html_url":"https://github.com/octo/cadence/releases/tag/v2",
                "published_at":"2026-06-20T00:00:00Z"
              },
              {
                "tag_name":"v1",
                "name":null,
                "body":null,
                "html_url":"https://github.com/octo/cadence/releases/tag/v1",
                "published_at":"2026-05-21T00:00:00Z"
              }
            ]
            """
        )
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )

        let refreshed = try #require(
            try await provider.refreshReleaseCadence(
                repository: RepoIdentity(ghRepoID: 26, owner: "octo", name: "cadence")
            )
        )
        let cached = try #require(try await provider.cachedReleaseCadence(repoID: 26))
        let request = try #require(await httpClient.request())
        let perPage = URLComponents(
            url: try #require(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "per_page" })?.value

        #expect(request.url?.path == "/repos/octo/cadence/releases")
        #expect(perPage == "12")
        #expect(refreshed.releasesLastYear == 3)
        #expect(refreshed.averageIntervalDays == 30)
        #expect(
            refreshed.latestPublishedAt
                == ISO8601DateFormatter.githubDate(from: "2026-07-20T00:00:00Z")
        )
        #expect(cached.value == refreshed)
        #expect(cached.responseETag == "\"release-v1\"")
        #expect(!cached.isStale)
    }

    @Test("仓库确认没有 Release 时缓存空结果避免重复请求")
    func releaseCadencePersistsConfirmedEmptyResult() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 27, owner: "octo", name: "no-release")
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: ReleaseCadenceHTTPClient(body: "[]"),
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let refreshed = try await provider.refreshReleaseCadence(
            repository: RepoIdentity(ghRepoID: 27, owner: "octo", name: "no-release")
        )
        let cached = try #require(try await provider.cachedReleaseCadence(repoID: 27))

        #expect(refreshed == nil)
        #expect(cached.value == nil)
        #expect(!cached.isStale)
    }

    @Test("安全公告映射真实响应并写入独立缓存")
    func securityAdvisoriesMapAndPersistIndependently() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 25, owner: "octo", name: "secure")
        let httpClient = SecurityAdvisoriesHTTPClient()
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-07-28T12:00:00Z")
        )
        let provider = DefaultRepositoryRemoteInsightsProvider(
            metricsClient: DefaultGitHubRepositoryMetricsClient(
                httpClient: httpClient,
                token: "token",
                baseURL: URL(string: "https://api.example.test")!
            ),
            cache: GRDBRepositoryInsightsCache(database: database),
            now: { now }
        )

        let refreshed = try await provider.refreshSecurityAdvisories(
            repository: RepoIdentity(ghRepoID: 25, owner: "octo", name: "secure")
        )
        let cached = try #require(try await provider.cachedSecurityAdvisories(repoID: 25))
        let request = try #require(await httpClient.request())
        let perPage = URLComponents(
            url: try #require(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "per_page" })?.value

        #expect(request.url?.path == "/repos/octo/secure/security-advisories")
        #expect(perPage == "100")
        #expect(refreshed.advisories.map(\.id) == ["GHSA-latest", "GHSA-older"])
        #expect(refreshed.advisories.map(\.severity) == ["low", "critical"])
        #expect(refreshed.advisories.last?.cveID == "CVE-2026-1")
        #expect(
            refreshed.advisories.first?.htmlURL?.absoluteString
                == "https://github.com/octo/secure/security/advisories/GHSA-latest"
        )
        #expect(refreshed.highOrCriticalCount == 1)
        #expect(refreshed.latestPublishedAt == refreshed.advisories.first?.publishedAt)
        #expect(cached.value == refreshed)
        #expect(!cached.isStale)
        #expect(RepositoryInsightsDataset.securityAdvisories.timeToLive == 6 * 60 * 60)
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

/// 只实现 single-flight 测试所需的活动刷新，其余入口若被误用应立即失败。
private actor ActivityOnlyRemoteInsightsProvider: RepositoryRemoteInsightsProviding {
    private var activityRefreshCount = 0

    func refreshCount() -> Int {
        activityRefreshCount
    }

    func cachedActivity(
        repoID: Int64,
        range: RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts? {
        nil
    }

    func refreshActivity(
        repository: RepoIdentity,
        range: RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts {
        activityRefreshCount += 1
        // 保证第二个调用在第一个完成前进入共享 Provider。
        try await Task.sleep(for: .milliseconds(30))
        return RepositoryActivityCounts(
            createdPullRequests: 2,
            mergedPullRequests: 1,
            createdIssues: 3,
            closedIssues: 2,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func cachedCommitActivity(repoID: Int64) async throws -> RepositoryCachedCommitActivity? {
        throw TestRemoteProviderError.unused
    }

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity {
        throw TestRemoteProviderError.unused
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        throw TestRemoteProviderError.unused
    }

    func refreshContributors(
        repository: RepoIdentity
    ) async throws -> RepositoryContributorsInsight {
        throw TestRemoteProviderError.unused
    }

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight? {
        throw TestRemoteProviderError.unused
    }

    func refreshCommunityProfile(
        repository: RepoIdentity
    ) async throws -> RepositoryCommunityInsight {
        throw TestRemoteProviderError.unused
    }

    func cachedSecurityAdvisories(
        repoID: Int64
    ) async throws -> RepositoryCachedSecurityAdvisoriesInsight? {
        throw TestRemoteProviderError.unused
    }

    func refreshSecurityAdvisories(
        repository: RepoIdentity
    ) async throws -> RepositorySecurityAdvisoriesInsight {
        throw TestRemoteProviderError.unused
    }

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity? {
        throw TestRemoteProviderError.unused
    }

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity {
        throw TestRemoteProviderError.unused
    }
}

private enum TestRemoteProviderError: Error {
    case unused
}

private actor ActivityMetricsHTTPClient: RAGHTTPClientProtocol {
    private var totals: [Int]
    private var recordedRequests: [URLRequest] = []

    init(totals: [Int]) {
        self.totals = totals
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/graphql" {
            return (
                Data(#"{"message":"GraphQL unavailable"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
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

private actor ActivityBundleHTTPClient: RAGHTTPClientProtocol {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        // 留出足够时间让第二个 Provider 调用进入 Metrics Client，共享同一 in-flight Task。
        try await Task.sleep(for: .milliseconds(30))
        let body = """
        {
          "data":{
            "createdPullRequests":{"issueCount":8},
            "mergedPullRequests":{"issueCount":5},
            "createdIssues":{"issueCount":13},
            "closedIssues":{"issueCount":7},
            "recentPullRequests":{
              "issueCount":1,
              "nodes":[{
                "number":42,
                "title":"Improve cache",
                "url":"https://github.com/octo/bundle/pull/42",
                "closedAt":"2026-07-25T00:00:00Z",
                "updatedAt":"2026-07-25T00:00:00Z"
              }]
            },
            "recentIssues":{
              "issueCount":1,
              "nodes":[{
                "number":7,
                "title":"Fix crash",
                "url":"https://github.com/octo/bundle/issues/7",
                "closedAt":"2026-07-26T00:00:00Z",
                "updatedAt":"2026-07-26T00:00:00Z"
              }]
            }
          }
        }
        """
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

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

/// 仓库洞察完整冷加载的请求预算桩；按真实路径返回最小合法响应。
private actor FullLoadMetricsHTTPClient: RAGHTTPClientProtocol {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let body: String
        switch request.url?.path {
        case "/graphql":
            // 留出窗口让 Activity 与 Recent 同时进入 Metrics in-flight tracker。
            try await Task.sleep(for: .milliseconds(30))
            body = """
            {
              "data":{
                "createdPullRequests":{"issueCount":8},
                "mergedPullRequests":{"issueCount":5},
                "createdIssues":{"issueCount":13},
                "closedIssues":{"issueCount":7},
                "recentPullRequests":{"issueCount":0,"nodes":[]},
                "recentIssues":{"issueCount":0,"nodes":[]}
              }
            }
            """
        case "/repos/octo/budget/stats/commit_activity",
             "/repos/octo/budget/contributors",
             "/repos/octo/budget/security-advisories":
            body = "[]"
        case "/repos/octo/budget/community/profile":
            body = """
            {
              "health_percentage":75,
              "files":{
                "code_of_conduct":null,
                "code_of_conduct_file":null,
                "contributing":null,
                "license":null,
                "readme":null
              }
            }
            """
        default:
            throw URLError(.badURL)
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"budget-v1\""]
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

/// 首次请求返回完整 payload，后续带 validator 的请求返回 304，
/// 用于覆盖 provider 的条件请求与缓存续期闭环。
private actor ConditionalCommitActivityHTTPClient: RAGHTTPClientProtocol {
    private var recordedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let isConditional = request.value(forHTTPHeaderField: "If-None-Match") != nil
        let body = isConditional
            ? Data()
            : Data(#"[{"week":1785100000,"total":9,"days":[1,1,1,1,1,2,2]}]"#.utf8)
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: isConditional ? 304 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"commit-v1\""]
            )!
        )
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor MissingPayloadConditionalHTTPClient: RAGHTTPClientProtocol {
    private let onConditional: @Sendable () async throws -> Void
    private var recordedRequests: [URLRequest] = []

    init(onConditional: @escaping @Sendable () async throws -> Void) {
        self.onConditional = onConditional
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let isConditional = request.value(forHTTPHeaderField: "If-None-Match") != nil
        if isConditional {
            try await onConditional()
        }
        return (
            isConditional
                ? Data()
                : Data(#"[{"week":1785100000,"total":11,"days":[1,1,1,2,2,2,2]}]"#.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: isConditional ? 304 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"commit-v2\""]
            )!
        )
    }

    func requests() -> [URLRequest] {
        recordedRequests
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
                "issue_template":{"html_url":"https://github.com/octo/community/tree/main/.github/ISSUE_TEMPLATE"},
                "pull_request_template":{"html_url":"https://github.com/octo/community/blob/main/.github/PULL_REQUEST_TEMPLATE.md"},
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

private actor SecurityAdvisoriesHTTPClient: RAGHTTPClientProtocol {
    private var recordedRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequest = request
        let body = """
        [
          {
            "ghsa_id":"GHSA-older",
            "cve_id":"CVE-2026-1",
            "summary":"Critical issue",
            "severity":"CRITICAL",
            "html_url":"https://github.com/octo/secure/security/advisories/GHSA-older",
            "published_at":"2026-07-20T00:00:00Z"
          },
          {
            "ghsa_id":"GHSA-latest",
            "cve_id":null,
            "summary":"Low issue",
            "severity":"low",
            "html_url":"https://github.com/octo/secure/security/advisories/GHSA-latest",
            "published_at":"2026-07-25T00:00:00Z"
          }
        ]
        """
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"security-v1\""]
            )!
        )
    }

    func request() -> URLRequest? {
        recordedRequest
    }
}

private actor ReleaseCadenceHTTPClient: RAGHTTPClientProtocol {
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
                headerFields: ["ETag": "\"release-v1\""]
            )!
        )
    }

    func request() -> URLRequest? {
        recordedRequest
    }
}

private actor RecentActivityHTTPClient: RAGHTTPClientProtocol {
    private var recordedQueries: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/graphql" {
            return (
                Data(#"{"message":"GraphQL unavailable"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
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
