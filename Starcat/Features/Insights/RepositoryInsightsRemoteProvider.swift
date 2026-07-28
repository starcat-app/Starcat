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
}

struct RepositoryContributorsInsight: Codable, Equatable, Sendable {
    let contributors: [RepositoryContributor]
    let generatedAt: Date
}

struct RepositoryCachedContributorsInsight: Equatable, Sendable {
    let value: RepositoryContributorsInsight
    let fetchedAt: Date
    let isStale: Bool
}

struct RepositoryCachedCommunityInsight: Equatable, Sendable {
    let value: RepositoryCommunityInsight
    let fetchedAt: Date
    let isStale: Bool
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

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight?

    func refreshContributors(repository: RepoIdentity) async throws -> RepositoryContributorsInsight

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight?

    func refreshCommunityProfile(repository: RepoIdentity) async throws -> RepositoryCommunityInsight

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity?

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity
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
        let value = try await metricsClient.loadActivityCounts(
            repository: repository,
            range: range,
            now: fetchedAt
        )
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
            isStale: cached.isStale(at: now())
        )
    }

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity {
        let fetchedAt = now()
        let response = try await metricsClient.loadCommitActivity(repository: repository)
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
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
            isStale: cached.isStale(at: now())
        )
    }

    func refreshContributors(repository: RepoIdentity) async throws -> RepositoryContributorsInsight {
        let fetchedAt = now()
        let response = try await metricsClient.loadContributors(repository: repository, limit: 12)
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
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
            isStale: cached.isStale(at: now())
        )
    }

    func refreshCommunityProfile(repository: RepoIdentity) async throws -> RepositoryCommunityInsight {
        let fetchedAt = now()
        let response = try await metricsClient.loadCommunityProfile(repository: repository)
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        let profile = response.value
        let value = RepositoryCommunityInsight(
            healthPercentage: profile.healthPercentage,
            hasReadme: profile.hasReadme,
            hasCodeOfConduct: profile.hasCodeOfConduct,
            hasContributing: profile.hasContributing,
            hasLicense: profile.hasLicense,
            readmeHTMLURL: profile.readmeHTMLURL,
            codeOfConductHTMLURL: profile.codeOfConductHTMLURL,
            contributingHTMLURL: profile.contributingHTMLURL,
            licenseHTMLURL: profile.licenseHTMLURL
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
        let fetchedAt = now()
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
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }

        let events = (
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
