//
//  RepositoryInsightsRemoteProvider.swift
//  Starcat
//
//  仓库洞察远端指标的领域模型与 cache-first Provider。
//
//  本文件负责把类型化 GitHub Metrics 响应转换为可持久化洞察数据，并统一写入
//  RepositoryInsightsCache；ViewModel 负责先展示缓存、再决定是否刷新网络。
//

import Foundation

/// 协作活动范围与 Star 历史范围彼此独立。
enum RepositoryActivityRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case week
    case month
    case quarter
    case year

    var id: String { rawValue }

    var dayCount: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        }
    }

    var cacheRange: RepositoryInsightsRangeKey {
        switch self {
        case .week: return .week
        case .month: return .month
        case .quarter: return .quarter
        case .year: return .year
        }
    }

    var titleKey: String {
        "insights.repo.activity.range.\(rawValue)"
    }
}

/// 一个活动范围内四个协作 KPI 的真实计数。
struct RepositoryActivityCounts: Codable, Equatable, Sendable {
    let createdPullRequests: Int
    let mergedPullRequests: Int
    let createdIssues: Int
    let closedIssues: Int
    let generatedAt: Date

    /// 同一时间范围内“已合并 / 新建”的吞吐比。合并项可能创建于范围之前，因此允许超过 100%。
    var pullRequestThroughput: Double? {
        guard createdPullRequests > 0 else { return nil }
        return Double(mergedPullRequests) / Double(createdPullRequests)
    }

    /// 同一时间范围内“已关闭 / 新建”的吞吐比，不把它误称为同批 Issue 的解决率。
    var issueThroughput: Double? {
        guard createdIssues > 0 else { return nil }
        return Double(closedIssues) / Double(createdIssues)
    }

    /// 正数表示本周期新建多于关闭，负数表示存量 Issue 正在净消化。
    var netIssueChange: Int {
        createdIssues - closedIssues
    }
}

/// ViewModel 读取缓存时需要同时知道是否过期，过期值仍先显示。
struct RepositoryCachedActivityCounts: Equatable, Sendable {
    let value: RepositoryActivityCounts
    let fetchedAt: Date
    let isStale: Bool
}

/// GitHub 固定返回最近 52 周；保留绝对日期后，客户端按提交区独立 range 裁剪。
struct RepositoryCommitActivityPoint: Codable, Equatable, Identifiable, Sendable {
    let weekStart: Date
    let commits: Int

    var id: Date { weekStart }
}

struct RepositoryCommitActivity: Codable, Equatable, Sendable {
    let points: [RepositoryCommitActivityPoint]
    let generatedAt: Date

    func points(in range: RepositoryActivityRange) -> [RepositoryCommitActivityPoint] {
        let cutoff = generatedAt.addingTimeInterval(-Double(range.dayCount) * 86_400)
        return points.filter { $0.weekStart >= cutoff }
    }

    /// 最近 4 周与此前 4 周形成固定可比窗口，不受图表范围切换影响。
    var maintenancePulse: RepositoryMaintenancePulse? {
        let ordered = points.sorted { $0.weekStart < $1.weekStart }
        guard ordered.count >= 8 else { return nil }
        let recent = ordered.suffix(4)
        let previous = ordered.dropLast(4).suffix(4)
        let recentCommits = recent.reduce(0) { $0 + $1.commits }
        let previousCommits = previous.reduce(0) { $0 + $1.commits }
        let comparisonPercentage: Int? = previousCommits > 0
            ? Int(
                (
                    Double(recentCommits - previousCommits)
                        / Double(previousCommits)
                        * 100
                ).rounded()
            )
            : nil
        return RepositoryMaintenancePulse(
            recentCommits: recentCommits,
            comparisonPercentage: comparisonPercentage,
            activeWeeks: recent.count { $0.commits > 0 }
        )
    }
}

/// 提交活动的短周期维护信号；只做客户端派生，不增加 GitHub 请求。
struct RepositoryMaintenancePulse: Equatable, Sendable {
    let recentCommits: Int
    let comparisonPercentage: Int?
    let activeWeeks: Int
}

struct RepositoryCachedCommitActivity: Equatable, Sendable {
    let value: RepositoryCommitActivity
    let fetchedAt: Date
    let isStale: Bool
    let responseETag: String?

    init(
        value: RepositoryCommitActivity,
        fetchedAt: Date,
        isStale: Bool,
        responseETag: String? = nil
    ) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.responseETag = responseETag
    }
}

struct RepositoryContributorsInsight: Codable, Equatable, Sendable {
    let contributors: [RepositoryContributor]
    let generatedAt: Date

    /// GitHub Contributors 接口当前只取前 12 位，因此占比明确限定在该样本内。
    var concentration: RepositoryContributorConcentration? {
        let ordered = contributors.sorted { $0.commits > $1.commits }
        let totalCommits = ordered.reduce(0) { $0 + max($1.commits, 0) }
        guard totalCommits > 0, let first = ordered.first else { return nil }
        let topThreeCommits = ordered.prefix(3).reduce(0) { $0 + max($1.commits, 0) }
        return RepositoryContributorConcentration(
            topContributorShare: Double(max(first.commits, 0)) / Double(totalCommits),
            topThreeShare: Double(topThreeCommits) / Double(totalCommits),
            sampledContributors: ordered.count
        )
    }
}

/// 前 12 位贡献者样本内的提交集中度，不将其误称为仓库全量贡献者占比。
struct RepositoryContributorConcentration: Equatable, Sendable {
    let topContributorShare: Double
    let topThreeShare: Double
    let sampledContributors: Int
}

struct RepositoryCachedContributorsInsight: Equatable, Sendable {
    let value: RepositoryContributorsInsight
    let fetchedAt: Date
    let isStale: Bool
    let responseETag: String?

    init(
        value: RepositoryContributorsInsight,
        fetchedAt: Date,
        isStale: Bool,
        responseETag: String? = nil
    ) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.responseETag = responseETag
    }
}

struct RepositoryCachedCommunityInsight: Equatable, Sendable {
    let value: RepositoryCommunityInsight
    let fetchedAt: Date
    let isStale: Bool
    let responseETag: String?

    init(
        value: RepositoryCommunityInsight,
        fetchedAt: Date,
        isStale: Bool,
        responseETag: String? = nil
    ) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.responseETag = responseETag
    }
}

/// GitHub 已发布的仓库安全公告。这里只展示公开公告，不把“接口无权限”误判为零风险。
struct RepositorySecurityAdvisory: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let cveID: String?
    let summary: String
    let severity: String
    let htmlURL: URL?
    let publishedAt: Date
}

/// 安全公告的缓存快照；派生统计只基于本次成功获取的公告列表。
struct RepositorySecurityAdvisoriesInsight: Codable, Equatable, Sendable {
    let advisories: [RepositorySecurityAdvisory]
    let generatedAt: Date

    var highOrCriticalCount: Int {
        advisories.count {
            let severity = $0.severity.lowercased()
            return severity == "high" || severity == "critical"
        }
    }

    var latestPublishedAt: Date? {
        advisories.map(\.publishedAt).max()
    }
}

struct RepositoryCachedSecurityAdvisoriesInsight: Equatable, Sendable {
    let value: RepositorySecurityAdvisoriesInsight
    let fetchedAt: Date
    let isStale: Bool
    let responseETag: String?

    init(
        value: RepositorySecurityAdvisoriesInsight,
        fetchedAt: Date,
        isStale: Bool,
        responseETag: String? = nil
    ) {
        self.value = value
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.responseETag = responseETag
    }
}

enum RepositoryRecentActivityKind: String, Codable, Equatable, Sendable {
    case pullRequest
    case issue
}

struct RepositoryRecentActivityEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: RepositoryRecentActivityKind
    let number: Int
    let title: String
    let occurredAt: Date
    let htmlURL: URL?
}

struct RepositoryRecentActivity: Codable, Equatable, Sendable {
    let events: [RepositoryRecentActivityEvent]
    let generatedAt: Date
}

struct RepositoryCachedRecentActivity: Equatable, Sendable {
    let value: RepositoryRecentActivity
    let fetchedAt: Date
    let isStale: Bool
}

protocol RepositoryRemoteInsightsProviding: Sendable {
    func cachedActivity(
        repoID: Int64,
        range: RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts?

    func refreshActivity(
        repository: RepoIdentity,
        range: RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts

    func cachedCommitActivity(repoID: Int64) async throws -> RepositoryCachedCommitActivity?

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity

    func refreshCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommitActivity

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight?

    func refreshContributors(repository: RepoIdentity) async throws -> RepositoryContributorsInsight

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight?

    func refreshCommunityProfile(repository: RepoIdentity) async throws -> RepositoryCommunityInsight

    func refreshCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommunityInsight

    func cachedSecurityAdvisories(repoID: Int64) async throws
        -> RepositoryCachedSecurityAdvisoriesInsight?

    func refreshSecurityAdvisories(repository: RepoIdentity) async throws
        -> RepositorySecurityAdvisoriesInsight

    func refreshSecurityAdvisories(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositorySecurityAdvisoriesInsight

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity?

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity

    func refreshRecentActivity(
        repository: RepoIdentity,
        activityRange: RepositoryActivityRange
    ) async throws -> RepositoryRecentActivity
}

extension RepositoryRemoteInsightsProviding {
    func refreshCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommitActivity {
        try await refreshCommitActivity(repository: repository)
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        try await refreshContributors(repository: repository)
    }

    func refreshCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommunityInsight {
        try await refreshCommunityProfile(repository: repository)
    }

    func refreshSecurityAdvisories(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositorySecurityAdvisoriesInsight {
        try await refreshSecurityAdvisories(repository: repository)
    }

    func refreshRecentActivity(
        repository: RepoIdentity,
        activityRange: RepositoryActivityRange
    ) async throws -> RepositoryRecentActivity {
        try await refreshRecentActivity(repository: repository)
    }
}

struct DefaultRepositoryRemoteInsightsProvider: RepositoryRemoteInsightsProviding, Sendable {
    let metricsClient: any GitHubRepositoryMetricsClient
    let cache: any RepositoryInsightsCaching
    let now: @Sendable () -> Date

    init(
        metricsClient: any GitHubRepositoryMetricsClient,
        cache: any RepositoryInsightsCaching,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.metricsClient = metricsClient
        self.cache = cache
        self.now = now
    }

    func cachedActivity(
        repoID: Int64,
        range: RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .activityCounts,
            range: range.cacheRange,
            as: RepositoryActivityCounts.self
        ) else {
            return nil
        }
        return RepositoryCachedActivityCounts(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now())
        )
    }

    func refreshActivity(
        repository: RepoIdentity,
        range: RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts {
        let fetchedAt = now()
        let value: RepositoryActivityCounts
        do {
            let bundle = try await metricsClient.loadActivityBundle(
                repository: repository,
                dateRange: RepositoryActivityDateRange(
                    range: range,
                    now: fetchedAt
                ).queryValue
            )
            value = RepositoryActivityCounts(
                createdPullRequests: bundle.createdPullRequests,
                mergedPullRequests: bundle.mergedPullRequests,
                createdIssues: bundle.createdIssues,
                closedIssues: bundle.closedIssues,
                generatedAt: fetchedAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // GraphQL schema、权限或代理兼容性异常时保留原 REST 口径，避免优化影响可用性。
            value = try await metricsClient.loadActivityCounts(
                repository: repository,
                range: range,
                now: fetchedAt
            )
        }
        guard let repoID = repository.ghRepoID else {
            // Manage 详情只会传持久化 Repo；无 ID 代表调用方越过了产品边界，不能写错缓存键。
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        try await cache.store(
            value,
            repoId: repoID,
            dataset: .activityCounts,
            range: range.cacheRange,
            fetchedAt: fetchedAt,
            responseETag: nil,
            defaultBranchSHA: nil
        )
        return value
    }

    func cachedCommitActivity(repoID: Int64) async throws -> RepositoryCachedCommitActivity? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .commitActivity,
            range: .all,
            as: RepositoryCommitActivity.self
        ) else {
            return nil
        }
        return RepositoryCachedCommitActivity(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now()),
            responseETag: cached.responseETag
        )
    }

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity {
        try await refreshCommitActivity(repository: repository, ifNoneMatch: nil)
    }

    func refreshCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommitActivity {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        do {
            let response = try await metricsClient.loadCommitActivity(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
            let value = RepositoryCommitActivity(
                points: response.value
                    .map {
                        RepositoryCommitActivityPoint(
                            weekStart: Date(timeIntervalSince1970: TimeInterval($0.week)),
                            commits: $0.total
                        )
                    }
                    .sorted { $0.weekStart < $1.weekStart },
                generatedAt: fetchedAt
            )
            try await cache.store(
                value,
                repoId: repoID,
                dataset: .commitActivity,
                range: .all,
                fetchedAt: fetchedAt,
                responseETag: response.etag,
                defaultBranchSHA: nil
            )
            return value
        } catch GitHubRepositoryMetricsError.notModified(let responseETag) {
            do {
                return try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .commitActivity,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositoryCommitActivity.self
                )
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                // 请求在飞行期间缓存可能被清理；最多无条件重拉一次，避免 304 对应空 payload。
                return try await refreshCommitActivity(
                    repository: repository,
                    ifNoneMatch: nil
                )
            }
        }
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .contributors,
            range: .all,
            as: RepositoryContributorsInsight.self
        ) else {
            return nil
        }
        return RepositoryCachedContributorsInsight(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now()),
            responseETag: cached.responseETag
        )
    }

    func refreshContributors(repository: RepoIdentity) async throws -> RepositoryContributorsInsight {
        try await refreshContributors(repository: repository, ifNoneMatch: nil)
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        do {
            let response = try await metricsClient.loadContributors(
                repository: repository,
                limit: 12,
                ifNoneMatch: ifNoneMatch
            )
            let colors = ["purple", "blue", "pink", "green", "orange"]
            let value = RepositoryContributorsInsight(
                contributors: response.value.map { metric in
                    let colorIndex = metric.login.unicodeScalars.reduce(0) {
                        ($0 + Int($1.value)) % colors.count
                    }
                    return RepositoryContributor(
                        id: metric.login,
                        login: metric.login,
                        commits: metric.contributions,
                        colorName: colors[colorIndex],
                        avatarURL: metric.avatarURL.flatMap(URL.init(string:)),
                        profileHTMLURL: metric.htmlURL.flatMap(URL.init(string:))
                    )
                },
                generatedAt: fetchedAt
            )
            try await cache.store(
                value,
                repoId: repoID,
                dataset: .contributors,
                range: .all,
                fetchedAt: fetchedAt,
                responseETag: response.etag,
                defaultBranchSHA: nil
            )
            return value
        } catch GitHubRepositoryMetricsError.notModified(let responseETag) {
            do {
                return try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .contributors,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositoryContributorsInsight.self
                )
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                return try await refreshContributors(
                    repository: repository,
                    ifNoneMatch: nil
                )
            }
        }
    }

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .communityProfile,
            range: .all,
            as: RepositoryCommunityInsight.self
        ) else {
            return nil
        }
        return RepositoryCachedCommunityInsight(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now()),
            responseETag: cached.responseETag
        )
    }

    func refreshCommunityProfile(repository: RepoIdentity) async throws -> RepositoryCommunityInsight {
        try await refreshCommunityProfile(repository: repository, ifNoneMatch: nil)
    }

    func refreshCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommunityInsight {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        do {
            let response = try await metricsClient.loadCommunityProfile(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
            let profile = response.value
            let value = RepositoryCommunityInsight(
                healthPercentage: profile.healthPercentage,
                hasReadme: profile.hasReadme,
                hasCodeOfConduct: profile.hasCodeOfConduct,
                hasContributing: profile.hasContributing,
                hasIssueTemplate: profile.hasIssueTemplate,
                hasLicense: profile.hasLicense,
                hasPullRequestTemplate: profile.hasPullRequestTemplate,
                readmeHTMLURL: profile.readmeHTMLURL,
                codeOfConductHTMLURL: profile.codeOfConductHTMLURL,
                contributingHTMLURL: profile.contributingHTMLURL,
                issueTemplateHTMLURL: profile.issueTemplateHTMLURL,
                licenseHTMLURL: profile.licenseHTMLURL,
                pullRequestTemplateHTMLURL: profile.pullRequestTemplateHTMLURL
            )
            try await cache.store(
                value,
                repoId: repoID,
                dataset: .communityProfile,
                range: .all,
                fetchedAt: fetchedAt,
                responseETag: response.etag,
                defaultBranchSHA: nil
            )
            return value
        } catch GitHubRepositoryMetricsError.notModified(let responseETag) {
            do {
                return try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .communityProfile,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositoryCommunityInsight.self
                )
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                return try await refreshCommunityProfile(
                    repository: repository,
                    ifNoneMatch: nil
                )
            }
        }
    }

    func cachedSecurityAdvisories(repoID: Int64) async throws
        -> RepositoryCachedSecurityAdvisoriesInsight? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .securityAdvisories,
            range: .all,
            as: RepositorySecurityAdvisoriesInsight.self
        ) else {
            return nil
        }
        return RepositoryCachedSecurityAdvisoriesInsight(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now()),
            responseETag: cached.responseETag
        )
    }

    func refreshSecurityAdvisories(repository: RepoIdentity) async throws
        -> RepositorySecurityAdvisoriesInsight {
        try await refreshSecurityAdvisories(repository: repository, ifNoneMatch: nil)
    }

    func refreshSecurityAdvisories(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositorySecurityAdvisoriesInsight {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        do {
            // 单页上限取 100，既覆盖绝大多数仓库，又避免为一个概览指标引入分页风暴。
            let response = try await metricsClient.loadSecurityAdvisories(
                repository: repository,
                limit: 100,
                ifNoneMatch: ifNoneMatch
            )
            let advisories = response.value.compactMap { metric -> RepositorySecurityAdvisory? in
                guard let publishedAt = ISO8601DateFormatter.githubDate(from: metric.publishedAt) else {
                    return nil
                }
                return RepositorySecurityAdvisory(
                    id: metric.ghsaID,
                    cveID: metric.cveID,
                    summary: metric.summary,
                    severity: metric.severity.lowercased(),
                    htmlURL: metric.htmlURL.flatMap(URL.init(string:)),
                    publishedAt: publishedAt
                )
            }
            .sorted { $0.publishedAt > $1.publishedAt }
            let value = RepositorySecurityAdvisoriesInsight(
                advisories: advisories,
                generatedAt: fetchedAt
            )
            try await cache.store(
                value,
                repoId: repoID,
                dataset: .securityAdvisories,
                range: .all,
                fetchedAt: fetchedAt,
                responseETag: response.etag,
                defaultBranchSHA: nil
            )
            return value
        } catch GitHubRepositoryMetricsError.notModified(let responseETag) {
            do {
                return try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .securityAdvisories,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositorySecurityAdvisoriesInsight.self
                )
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                return try await refreshSecurityAdvisories(
                    repository: repository,
                    ifNoneMatch: nil
                )
            }
        }
    }

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity? {
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: .recentActivity,
            range: .all,
            as: RepositoryRecentActivity.self
        ) else {
            return nil
        }
        return RepositoryCachedRecentActivity(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now())
        )
    }

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity {
        try await refreshRecentActivity(repository: repository, activityRange: .month)
    }

    func refreshRecentActivity(
        repository: RepoIdentity,
        activityRange: RepositoryActivityRange
    ) async throws -> RepositoryRecentActivity {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }

        let events: [RepositoryRecentActivityEvent]
        do {
            let bundle = try await metricsClient.loadActivityBundle(
                repository: repository,
                dateRange: RepositoryActivityDateRange(
                    range: activityRange,
                    now: fetchedAt
                ).queryValue
            )
            events = Array(
                (
                    makeRecentEvents(bundle.recentPullRequests, kind: .pullRequest)
                    + makeRecentEvents(bundle.recentIssues, kind: .issue)
                )
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(8)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            events = try await loadRecentEventsViaREST(repository: repository)
        }
        let value = RepositoryRecentActivity(events: Array(events), generatedAt: fetchedAt)
        try await cache.store(
            value,
            repoId: repoID,
            dataset: .recentActivity,
            range: .all,
            fetchedAt: fetchedAt,
            responseETag: nil,
            defaultBranchSHA: nil
        )
        return value
    }

    private func loadRecentEventsViaREST(
        repository: RepoIdentity
    ) async throws -> [RepositoryRecentActivityEvent] {
        let base = "repo:\(repository.owner)/\(repository.name)"
        let pullRequests = try await metricsClient.searchIssues(
            repository: repository,
            query: "\(base) is:pr",
            sort: "updated",
            order: "desc",
            perPage: 5
        )
        let issues = try await metricsClient.searchIssues(
            repository: repository,
            query: "\(base) is:issue",
            sort: "updated",
            order: "desc",
            perPage: 5
        )
        return Array(
            (
                makeRecentEvents(
                    pullRequests.value.items,
                    kind: .pullRequest,
                    repository: repository
                )
                + makeRecentEvents(
                    issues.value.items,
                    kind: .issue,
                    repository: repository
                )
            )
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(8)
        )
    }

    private func makeRecentEvents(
        _ metrics: [GitHubRepositoryActivityEventMetric],
        kind: RepositoryRecentActivityKind
    ) -> [RepositoryRecentActivityEvent] {
        metrics.compactMap { metric in
            guard let occurredAt = ISO8601DateFormatter.githubDate(from: metric.occurredAt) else {
                return nil
            }
            return RepositoryRecentActivityEvent(
                id: "\(kind.rawValue)-\(metric.number)",
                kind: kind,
                number: metric.number,
                title: metric.title,
                occurredAt: occurredAt,
                htmlURL: URL(string: metric.htmlURL)
            )
        }
    }

    private func makeRecentEvents(
        _ items: [GitHubRepositoryIssueItem],
        kind: RepositoryRecentActivityKind,
        repository: RepoIdentity
    ) -> [RepositoryRecentActivityEvent] {
        items.compactMap { item in
            guard item.belongs(to: repository),
                  let occurredAt = ISO8601DateFormatter.githubDate(
                      from: item.closedAt ?? item.updatedAt
                  ) else {
                return nil
            }
            return RepositoryRecentActivityEvent(
                id: "\(kind.rawValue)-\(item.number)",
                kind: kind,
                number: item.number,
                title: item.title,
                occurredAt: occurredAt,
                htmlURL: URL(string: item.htmlURL)
            )
        }
    }

    /// 304 只证明远端内容未变化。先续期同一缓存行，再重新读取 payload；
    /// 若缓存被并发清理或已损坏，则不能把“无本地内容”伪装成成功。
    private func revalidatedCachedValue<Value: Decodable & Sendable>(
        repoID: Int64,
        dataset: RepositoryInsightsDataset,
        fetchedAt: Date,
        responseETag: String?,
        as type: Value.Type
    ) async throws -> Value {
        try await cache.touch(
            repoId: repoID,
            dataset: dataset,
            range: .all,
            fetchedAt: fetchedAt,
            responseETag: responseETag
        )
        guard let cached = try await cache.load(
            repoId: repoID,
            dataset: dataset,
            range: .all,
            as: type
        ) else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        return cached.value
    }
}

extension GitHubRepositoryMetricsClient {
    /// Search Issues 的 `total_count` 已是目标 KPI；每个口径只取一条明细，减少响应体。
    func loadActivityCounts(
        repository: RepoIdentity,
        range: RepositoryActivityRange,
        now: Date
    ) async throws -> RepositoryActivityCounts {
        let dateRange = RepositoryActivityDateRange(range: range, now: now)
        let base = "repo:\(repository.owner)/\(repository.name)"

        let createdPullRequests = try await searchIssues(
            repository: repository,
            query: "\(base) is:pr created:\(dateRange.queryValue)",
            sort: "created",
            order: "desc",
            perPage: 1
        ).value.totalCount
        let mergedPullRequests = try await searchIssues(
            repository: repository,
            query: "\(base) is:pr merged:\(dateRange.queryValue)",
            sort: "updated",
            order: "desc",
            perPage: 1
        ).value.totalCount
        let createdIssues = try await searchIssues(
            repository: repository,
            query: "\(base) is:issue created:\(dateRange.queryValue)",
            sort: "created",
            order: "desc",
            perPage: 1
        ).value.totalCount
        let closedIssues = try await searchIssues(
            repository: repository,
            query: "\(base) is:issue closed:\(dateRange.queryValue)",
            sort: "updated",
            order: "desc",
            perPage: 1
        ).value.totalCount

        return RepositoryActivityCounts(
            createdPullRequests: createdPullRequests,
            mergedPullRequests: mergedPullRequests,
            createdIssues: createdIssues,
            closedIssues: closedIssues,
            generatedAt: now
        )
    }
}

/// GitHub Search 使用日期而非秒级时间；固定 UTC 避免本地时区跨日导致同一刷新口径漂移。
private struct RepositoryActivityDateRange {
    let queryValue: String

    init(range: RepositoryActivityRange, now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(byAdding: .day, value: -range.dayCount, to: now) ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        queryValue = "\(formatter.string(from: start))..\(formatter.string(from: now))"
    }
}
