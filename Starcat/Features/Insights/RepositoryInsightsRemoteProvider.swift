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

    /// 提交活动图是否按日拆柱（依赖每周 `days`）；更长窗口仍用周柱以免过密。
    var usesDailyCommitBars: Bool {
        switch self {
        case .week, .month: return true
        case .quarter, .year: return false
        }
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
///
/// `weekStart` 在周粒度是周日起点；1 周 / 1 月展开日柱时，同一字段表示该日 0 点
///（沿用字段名以兼容已缓存 JSON，避免双写新旧 key）。
struct RepositoryCommitActivityPoint: Codable, Equatable, Identifiable, Sendable {
    let weekStart: Date
    let commits: Int
    /// GitHub `days`：周日→周六共 7 项；旧缓存或日粒度派生点为空。
    let days: [Int]

    var id: Date { weekStart }

    init(weekStart: Date, commits: Int, days: [Int] = []) {
        self.weekStart = weekStart
        self.commits = commits
        self.days = days
    }

    enum CodingKeys: String, CodingKey {
        case weekStart, commits, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekStart = try container.decode(Date.self, forKey: .weekStart)
        commits = try container.decode(Int.self, forKey: .commits)
        // 旧缓存没有 days；缺省为空，1 周视图会退回单周柱而不是崩。
        days = try container.decodeIfPresent([Int].self, forKey: .days) ?? []
    }

    /// 把本周 `days` 展开为 7 个日点；长度不是 7 时返回 nil，由调用方退回周柱。
    func expandedDailyPoints() -> [RepositoryCommitActivityPoint]? {
        guard days.count == 7 else { return nil }
        return days.enumerated().map { dayIndex, count in
            RepositoryCommitActivityPoint(
                weekStart: weekStart.addingTimeInterval(TimeInterval(dayIndex) * 86_400),
                commits: count,
                days: []
            )
        }
    }
}

struct RepositoryCommitActivity: Codable, Equatable, Sendable {
    let points: [RepositoryCommitActivityPoint]
    let generatedAt: Date

    func points(in range: RepositoryActivityRange) -> [RepositoryCommitActivityPoint] {
        let cutoff = generatedAt.addingTimeInterval(-Double(range.dayCount) * 86_400)
        let weekly = points
            .filter { $0.weekStart >= cutoff }
            .sorted { $0.weekStart < $1.weekStart }

        // 1 周 / 1 月：用每周自带的 days 拆日柱；3 月 / 1 年日柱过密，保持周柱。
        // 任一周围缺 days（旧缓存）则整段退回周柱，避免日/周混画。
        switch range {
        case .week:
            guard let latest = weekly.last else { return [] }
            return latest.expandedDailyPoints() ?? [latest]
        case .month:
            return Self.expandedDailyPoints(from: weekly, cutoff: cutoff) ?? weekly
        case .quarter, .year:
            return weekly
        }
    }

    /// 把范围内各周的 `days` 串成日点，并按 cutoff 裁掉窗口外的日子。
    private static func expandedDailyPoints(
        from weekly: [RepositoryCommitActivityPoint],
        cutoff: Date
    ) -> [RepositoryCommitActivityPoint]? {
        guard !weekly.isEmpty else { return [] }
        var daily: [RepositoryCommitActivityPoint] = []
        daily.reserveCapacity(weekly.count * 7)
        for week in weekly {
            guard let expanded = week.expandedDailyPoints() else { return nil }
            daily.append(contentsOf: expanded)
        }
        return daily.filter { $0.weekStart >= cutoff }
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

/// Release 节奏允许缓存“确认无 Release”的 nil，避免每次进入仓库都重复请求 GitHub。
struct RepositoryCachedReleaseCadenceInsight: Equatable, Sendable {
    let value: RepositoryReleaseCadenceInsight?
    let fetchedAt: Date
    let isStale: Bool
    let responseETag: String?
}

/// 远端 Release 回退结果：节奏缓存与「Latest Release」卡片共用同一次 `/releases` 响应。
struct RepositoryReleaseRemoteSnapshot: Equatable, Sendable {
    let cadence: RepositoryReleaseCadenceInsight?
    let latest: RepositoryReleaseInsight?

    static func cadenceOnly(_ cadence: RepositoryReleaseCadenceInsight?) -> Self {
        Self(cadence: cadence, latest: nil)
    }
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

    func cachedReleaseCadence(repoID: Int64) async throws
        -> RepositoryCachedReleaseCadenceInsight?

    /// 远端 Release 回退同时带回最新一条，供 Local Insights「Latest Release」在无私有订阅时上屏。
    func refreshReleaseCadence(repository: RepoIdentity) async throws
        -> RepositoryReleaseRemoteSnapshot

    func refreshReleaseCadence(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryReleaseRemoteSnapshot

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

    func cachedReleaseCadence(repoID: Int64) async throws
        -> RepositoryCachedReleaseCadenceInsight? {
        nil
    }

    func refreshReleaseCadence(repository: RepoIdentity) async throws
        -> RepositoryReleaseRemoteSnapshot {
        throw GitHubRepositoryMetricsError.unavailable(
            statusCode: 503,
            message: "Release cadence provider unavailable"
        )
    }

    func refreshReleaseCadence(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryReleaseRemoteSnapshot {
        try await refreshReleaseCadence(repository: repository)
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

/// 仓库洞察远端 Provider 的进程级共享包装。
///
/// 洞察页面、AI 摘要与 AI 对话都可能在同一时刻请求相同仓库的数据。底层缓存已经按
/// `repo + dataset + range` 持久化，但“先读缓存、发现缺失、同时刷新”仍可能让多个
/// 消费者重复发起网络请求。这里为每类数据维护独立 single-flight，同一请求只执行一次，
/// 所有等待者共享结果；结果仍由底层 Provider 写入统一 SQLite 缓存。
///
/// single-flight Task 不绑定任一页面生命周期：某个消费者取消等待时，不应取消其它消费者
/// 仍在使用的共享请求，也应允许请求完成后继续温热缓存。
struct SharedRepositoryRemoteInsightsProvider: RepositoryRemoteInsightsProviding, Sendable {
    private struct RepositoryKey: Hashable, Sendable {
        let repoID: Int64?
        let owner: String
        let name: String

        init(_ repository: RepoIdentity) {
            repoID = repository.ghRepoID
            owner = repository.owner
            name = repository.name
        }
    }

    private struct ActivityKey: Hashable, Sendable {
        let repository: RepositoryKey
        let range: RepositoryActivityRange
    }

    private let base: any RepositoryRemoteInsightsProviding
    private let activityFlights = RepositoryInsightsSingleFlight<ActivityKey, RepositoryActivityCounts>()
    private let commitFlights = RepositoryInsightsSingleFlight<RepositoryKey, RepositoryCommitActivity>()
    private let contributorFlights =
        RepositoryInsightsSingleFlight<RepositoryKey, RepositoryContributorsInsight>()
    private let communityFlights =
        RepositoryInsightsSingleFlight<RepositoryKey, RepositoryCommunityInsight>()
    private let releaseFlights =
        RepositoryInsightsSingleFlight<RepositoryKey, RepositoryReleaseRemoteSnapshot>()
    private let securityFlights =
        RepositoryInsightsSingleFlight<RepositoryKey, RepositorySecurityAdvisoriesInsight>()
    private let recentActivityFlights =
        RepositoryInsightsSingleFlight<ActivityKey, RepositoryRecentActivity>()

    init(base: any RepositoryRemoteInsightsProviding) {
        self.base = base
    }

    func cachedActivity(
        repoID: Int64,
        range: RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts? {
        try await base.cachedActivity(repoID: repoID, range: range)
    }

    func refreshActivity(
        repository: RepoIdentity,
        range: RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts {
        let key = ActivityKey(repository: RepositoryKey(repository), range: range)
        return try await activityFlights.value(for: key) {
            try await base.refreshActivity(repository: repository, range: range)
        }
    }

    func cachedCommitActivity(repoID: Int64) async throws -> RepositoryCachedCommitActivity? {
        try await base.cachedCommitActivity(repoID: repoID)
    }

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity {
        try await refreshCommitActivity(repository: repository, ifNoneMatch: nil)
    }

    func refreshCommitActivity(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommitActivity {
        try await commitFlights.value(for: RepositoryKey(repository)) {
            try await base.refreshCommitActivity(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
        }
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        try await base.cachedContributors(repoID: repoID)
    }

    func refreshContributors(
        repository: RepoIdentity
    ) async throws -> RepositoryContributorsInsight {
        try await refreshContributors(repository: repository, ifNoneMatch: nil)
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        try await contributorFlights.value(for: RepositoryKey(repository)) {
            try await base.refreshContributors(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
        }
    }

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight? {
        try await base.cachedCommunityProfile(repoID: repoID)
    }

    func refreshCommunityProfile(
        repository: RepoIdentity
    ) async throws -> RepositoryCommunityInsight {
        try await refreshCommunityProfile(repository: repository, ifNoneMatch: nil)
    }

    func refreshCommunityProfile(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryCommunityInsight {
        try await communityFlights.value(for: RepositoryKey(repository)) {
            try await base.refreshCommunityProfile(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
        }
    }

    func cachedReleaseCadence(
        repoID: Int64
    ) async throws -> RepositoryCachedReleaseCadenceInsight? {
        try await base.cachedReleaseCadence(repoID: repoID)
    }

    func refreshReleaseCadence(
        repository: RepoIdentity
    ) async throws -> RepositoryReleaseRemoteSnapshot {
        try await refreshReleaseCadence(repository: repository, ifNoneMatch: nil)
    }

    func refreshReleaseCadence(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryReleaseRemoteSnapshot {
        try await releaseFlights.value(for: RepositoryKey(repository)) {
            try await base.refreshReleaseCadence(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
        }
    }

    func cachedSecurityAdvisories(
        repoID: Int64
    ) async throws -> RepositoryCachedSecurityAdvisoriesInsight? {
        try await base.cachedSecurityAdvisories(repoID: repoID)
    }

    func refreshSecurityAdvisories(
        repository: RepoIdentity
    ) async throws -> RepositorySecurityAdvisoriesInsight {
        try await refreshSecurityAdvisories(repository: repository, ifNoneMatch: nil)
    }

    func refreshSecurityAdvisories(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositorySecurityAdvisoriesInsight {
        try await securityFlights.value(for: RepositoryKey(repository)) {
            try await base.refreshSecurityAdvisories(
                repository: repository,
                ifNoneMatch: ifNoneMatch
            )
        }
    }

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity? {
        try await base.cachedRecentActivity(repoID: repoID)
    }

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity {
        try await refreshRecentActivity(repository: repository, activityRange: .month)
    }

    func refreshRecentActivity(
        repository: RepoIdentity,
        activityRange: RepositoryActivityRange
    ) async throws -> RepositoryRecentActivity {
        let key = ActivityKey(repository: RepositoryKey(repository), range: activityRange)
        return try await recentActivityFlights.value(for: key) {
            try await base.refreshRecentActivity(
                repository: repository,
                activityRange: activityRange
            )
        }
    }
}

/// 单个数据集的有界并发合并器。
///
/// `Task` 在 actor 内登记后再等待，因此 actor 重入期间的后续调用会命中同一个任务。
/// 任务完成即移除，不承担结果缓存职责；长期缓存仍由 `RepositoryInsightsCaching` 负责。
private actor RepositoryInsightsSingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(
        for key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let task = tasks[key] {
            return try await task.value
        }

        let task = Task {
            try await operation()
        }
        tasks[key] = task
        defer {
            tasks[key] = nil
        }
        return try await task.value
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
                            commits: $0.total,
                            // 保留周日→周六明细，供「1 周」范围展开日柱；其它范围仍用 total。
                            days: $0.days
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
            let mappedValue = RepositoryCommunityInsight(
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
            let value = try await resolvingIssueTemplateAvailability(
                in: mappedValue,
                repository: repository
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
                let cachedValue = try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .communityProfile,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositoryCommunityInsight.self
                )
                let value = try await resolvingIssueTemplateAvailability(
                    in: cachedValue,
                    repository: repository
                )
                if value != cachedValue {
                    // 旧缓存可能保存过 API 的误判；确认目录存在后立即覆盖，避免下一次 304 再回退。
                    try await cache.store(
                        value,
                        repoId: repoID,
                        dataset: .communityProfile,
                        range: .all,
                        fetchedAt: fetchedAt,
                        responseETag: responseETag ?? ifNoneMatch,
                        defaultBranchSHA: nil
                    )
                }
                return value
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                return try await refreshCommunityProfile(
                    repository: repository,
                    ifNoneMatch: nil
                )
            }
        }
    }

    private func resolvingIssueTemplateAvailability(
        in value: RepositoryCommunityInsight,
        repository: RepoIdentity
    ) async throws -> RepositoryCommunityInsight {
        guard !value.hasIssueTemplate else { return value }
        do {
            let isAvailable = try await metricsClient.loadIssueTemplateAvailability(
                repository: repository,
                observer: nil
            )
            return value.markingIssueTemplateAvailable(isAvailable)
        } catch is CancellationError {
            // 目录探测只是兼容兜底，但不能吞掉切库或关闭页面触发的任务取消。
            throw CancellationError()
        } catch {
            // 主 Community Profile 已成功时，兜底端点失败不应拖垮整个社区信号区块。
            return value
        }
    }

    func cachedReleaseCadence(repoID: Int64) async throws
        -> RepositoryCachedReleaseCadenceInsight? {
        let cached: RepositoryInsightsCachedValue<RepositoryReleaseCadenceInsight?>?
        cached = try await cache.load(
            repoId: repoID,
            dataset: .releaseCadence,
            range: .all,
            as: RepositoryReleaseCadenceInsight?.self
        )
        guard let cached else { return nil }
        return RepositoryCachedReleaseCadenceInsight(
            value: cached.value,
            fetchedAt: cached.fetchedAt,
            isStale: cached.isStale(at: now()),
            responseETag: cached.responseETag
        )
    }

    func refreshReleaseCadence(repository: RepoIdentity) async throws
        -> RepositoryReleaseRemoteSnapshot {
        try await refreshReleaseCadence(repository: repository, ifNoneMatch: nil)
    }

    func refreshReleaseCadence(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryReleaseRemoteSnapshot {
        let fetchedAt = now()
        guard let repoID = repository.ghRepoID else {
            throw GitHubRepositoryMetricsError.invalidResponse
        }
        do {
            // 节奏只消费最近 12 次发布日期；不写 release 订阅表，避免未订阅仓库进入活动时间线。
            // latest 仅回传给洞察页 Local Insights，不入库 releases 表。
            let response = try await metricsClient.loadReleases(
                repository: repository,
                limit: 12,
                ifNoneMatch: ifNoneMatch
            )
            let releases = response.value.map { metric in
                RepositoryReleaseInsight(
                    tagName: metric.tagName,
                    name: metric.name,
                    publishedAt: metric.publishedAt.flatMap(ISO8601DateFormatter.githubDate(from:)),
                    htmlURL: URL(string: metric.htmlURL)
                )
            }
            let value = RepositoryReleaseCadenceInsight.make(releases: releases, now: fetchedAt)
            try await cache.store(
                value,
                repoId: repoID,
                dataset: .releaseCadence,
                range: .all,
                fetchedAt: fetchedAt,
                responseETag: response.etag,
                defaultBranchSHA: nil
            )
            return RepositoryReleaseRemoteSnapshot(cadence: value, latest: releases.first)
        } catch GitHubRepositoryMetricsError.notModified(let responseETag) {
            do {
                let cadence = try await revalidatedCachedValue(
                    repoID: repoID,
                    dataset: .releaseCadence,
                    fetchedAt: fetchedAt,
                    responseETag: responseETag ?? ifNoneMatch,
                    as: RepositoryReleaseCadenceInsight?.self
                )
                return .cadenceOnly(cadence)
            } catch GitHubRepositoryMetricsError.invalidResponse where ifNoneMatch != nil {
                // 304 到达前缓存可能被清理；无 payload 时只允许无条件补拉一次。
                return try await refreshReleaseCadence(
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
