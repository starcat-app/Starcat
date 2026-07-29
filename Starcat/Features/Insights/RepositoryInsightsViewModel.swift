//
//  RepositoryInsightsViewModel.swift
//  Starcat
//
//  仓库洞察的本地数据状态机。Release、Health、OpenSSF 与 Community 各自独立，
//  单一区块失败不会把整个页面切成错误态；repo generation 防止快速切换时旧结果回写。
//

import Foundation
import GRDB

enum RepositoryInsightsSectionState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case content(Value)
    case empty
    case unavailable
    case failed
}

/// 远端区块需要在失败时保留旧缓存，因此与纯本地区块使用不同状态模型。
enum RepositoryRemoteInsightsSectionState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading(cached: Value?)
    case content(Value)
    case stale(Value)
    case generating(cached: Value?)
    case unavailable(cached: Value?)
    case failed(cached: Value?)

    /// 手动刷新只改变刷新按钮，不先清空正在展示的内容；失败时也用该值兜底。
    var visibleValue: Value? {
        switch self {
        case .idle:
            return nil
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        }
    }
}

struct RepositoryReleaseInsight: Equatable, Sendable {
    let tagName: String
    let name: String?
    let publishedAt: Date?
    /// GitHub release 页；本地 `releases.html_url` 已有，时间线可直接跳转。
    let htmlURL: URL?
}

/// 从 Release 历史派生的发布节奏。
///
/// 本地订阅历史优先；本地没有记录时，远端 Provider 会把相同模型写入仓库洞察缓存。
struct RepositoryReleaseCadenceInsight: Codable, Equatable, Sendable {
    let releasesLastYear: Int
    /// 最近最多 12 条有效发布日期之间的平均间隔，不代表仓库全历史。
    let averageIntervalDays: Int?
    let latestPublishedAt: Date

    static func make(
        releases: [RepositoryReleaseInsight],
        now: Date
    ) -> RepositoryReleaseCadenceInsight? {
        let dates = releases.compactMap(\.publishedAt).sorted(by: >)
        guard let latest = dates.first else { return nil }
        let oneYearAgo = now.addingTimeInterval(-365 * 86_400)
        let releasesLastYear = dates.count { $0 >= oneYearAgo && $0 <= now }
        let intervals = zip(dates, dates.dropFirst()).map { newer, older in
            max(0, newer.timeIntervalSince(older) / 86_400)
        }
        let averageIntervalDays = intervals.isEmpty
            ? nil
            : Int((intervals.reduce(0, +) / Double(intervals.count)).rounded())
        return RepositoryReleaseCadenceInsight(
            releasesLastYear: releasesLastYear,
            averageIntervalDays: averageIntervalDays,
            latestPublishedAt: latest
        )
    }
}

struct RepositoryHealthInsight: Equatable, Sendable {
    let overallScore: Int
    let grade: String
    let maintenanceScore: Int
    let popularityScore: Int
    let qualityScore: Int
    let securityScore: Int
    let isPartial: Bool
}

struct RepositoryOpenSSFInsight: Equatable, Sendable {
    let score: Double
    let scoreDate: String?
}

/// GitHub Community Profile 的可缓存展示值。后续类型化 GitHub Client 直接产出本模型。
/// `*HTMLURL` 为可选：旧缓存无字段时为 nil，UI 用仓库页约定路径兜底。
struct RepositoryCommunityInsight: Codable, Equatable, Sendable {
    let healthPercentage: Int
    let hasReadme: Bool
    let hasCodeOfConduct: Bool
    let hasContributing: Bool
    let hasIssueTemplate: Bool
    let hasLicense: Bool
    let hasPullRequestTemplate: Bool
    let readmeHTMLURL: URL?
    let codeOfConductHTMLURL: URL?
    let contributingHTMLURL: URL?
    let issueTemplateHTMLURL: URL?
    let licenseHTMLURL: URL?
    let pullRequestTemplateHTMLURL: URL?

    init(
        healthPercentage: Int,
        hasReadme: Bool,
        hasCodeOfConduct: Bool,
        hasContributing: Bool,
        hasIssueTemplate: Bool = false,
        hasLicense: Bool,
        hasPullRequestTemplate: Bool = false,
        readmeHTMLURL: URL? = nil,
        codeOfConductHTMLURL: URL? = nil,
        contributingHTMLURL: URL? = nil,
        issueTemplateHTMLURL: URL? = nil,
        licenseHTMLURL: URL? = nil,
        pullRequestTemplateHTMLURL: URL? = nil
    ) {
        self.healthPercentage = healthPercentage
        self.hasReadme = hasReadme
        self.hasCodeOfConduct = hasCodeOfConduct
        self.hasContributing = hasContributing
        self.hasIssueTemplate = hasIssueTemplate
        self.hasLicense = hasLicense
        self.hasPullRequestTemplate = hasPullRequestTemplate
        self.readmeHTMLURL = readmeHTMLURL
        self.codeOfConductHTMLURL = codeOfConductHTMLURL
        self.contributingHTMLURL = contributingHTMLURL
        self.issueTemplateHTMLURL = issueTemplateHTMLURL
        self.licenseHTMLURL = licenseHTMLURL
        self.pullRequestTemplateHTMLURL = pullRequestTemplateHTMLURL
    }
}

enum RepositoryLocalInsightResult<Value: Sendable>: Sendable {
    case value(Value?)
    case failed
}

struct RepositoryLocalInsightsSnapshot: Sendable {
    let release: RepositoryLocalInsightResult<RepositoryReleaseInsight>
    let releaseCadence: RepositoryLocalInsightResult<RepositoryReleaseCadenceInsight>
    let health: RepositoryLocalInsightResult<RepositoryHealthInsight>
    let openSSF: RepositoryLocalInsightResult<RepositoryOpenSSFInsight>
    let community: RepositoryLocalInsightResult<RepositoryCommunityInsight>
}

protocol RepositoryLocalInsightsProviding: Sendable {
    func snapshot(repoId: Int64) async -> RepositoryLocalInsightsSnapshot
    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight?
    func releaseCadence(repoId: Int64) async throws -> RepositoryReleaseCadenceInsight?
    func health(repoId: Int64) async throws -> RepositoryHealthInsight?
    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight?
    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight?
}

extension RepositoryLocalInsightsProviding {
    /// 测试桩与第三方实现保持原有五方法契约；生产 GRDB Provider 会覆盖为单事务读取。
    func snapshot(repoId: Int64) async -> RepositoryLocalInsightsSnapshot {
        async let release = captureRepositoryLocalInsight {
            try await latestRelease(repoId: repoId)
        }
        async let cadence = captureRepositoryLocalInsight {
            try await releaseCadence(repoId: repoId)
        }
        async let healthResult = captureRepositoryLocalInsight {
            try await health(repoId: repoId)
        }
        async let openSSFResult = captureRepositoryLocalInsight {
            try await openSSF(repoId: repoId)
        }
        async let community = captureRepositoryLocalInsight {
            try await cachedCommunity(repoId: repoId)
        }
        return await RepositoryLocalInsightsSnapshot(
            release: release,
            releaseCadence: cadence,
            health: healthResult,
            openSSF: openSSFResult,
            community: community
        )
    }
}

private func captureRepositoryLocalInsight<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value?
) async -> RepositoryLocalInsightResult<Value> {
    do {
        return .value(try await operation())
    } catch {
        return .failed
    }
}

struct DefaultRepositoryLocalInsightsProvider: RepositoryLocalInsightsProviding, Sendable {
    let releaseRepository: any ReleaseRepositoryProtocol
    let healthRepository: any RepoHealthRepositoryProtocol
    let openSSFRepository: any OpenSSFScoreRepositoryProtocol
    let insightsCache: any RepositoryInsightsCaching
    let database: (any DatabaseManaging)?
    let now: @Sendable () -> Date

    init(
        releaseRepository: any ReleaseRepositoryProtocol,
        healthRepository: any RepoHealthRepositoryProtocol,
        openSSFRepository: any OpenSSFScoreRepositoryProtocol,
        insightsCache: any RepositoryInsightsCaching,
        database: (any DatabaseManaging)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.releaseRepository = releaseRepository
        self.healthRepository = healthRepository
        self.openSSFRepository = openSSFRepository
        self.insightsCache = insightsCache
        self.database = database
        self.now = now
    }

    func snapshot(repoId: Int64) async -> RepositoryLocalInsightsSnapshot {
        guard let database else {
            return await fallbackSnapshot(repoId: repoId)
        }
        let snapshotDate = now()
        do {
            return try await database.writer.read { db in
            var releaseResult: RepositoryLocalInsightResult<RepositoryReleaseInsight> = .failed
            var cadenceResult:
                RepositoryLocalInsightResult<RepositoryReleaseCadenceInsight> = .failed
            do {
                let records = try ReleaseRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM releases
                        WHERE repo_id = ?
                        ORDER BY COALESCE(published_at, created_at_remote, fetched_at) DESC
                        LIMIT 12
                        """,
                    arguments: [repoId]
                )
                let releases = records.map(Self.releaseInsight)
                releaseResult = .value(releases.first)
                cadenceResult = .value(
                    RepositoryReleaseCadenceInsight.make(
                        releases: releases,
                        now: snapshotDate
                    )
                )
            } catch {
                // 单表损坏只让对应区块失败，不能拖垮同事务内的其它本地洞察。
            }

            let healthResult: RepositoryLocalInsightResult<RepositoryHealthInsight>
            do {
                healthResult = .value(
                    try RepoHealthSnapshot.fetchOne(db, key: repoId)
                        .flatMap(Self.healthInsight)
                )
            } catch {
                healthResult = .failed
            }

            let openSSFResult: RepositoryLocalInsightResult<RepositoryOpenSSFInsight>
            do {
                openSSFResult = .value(
                    try OpenSSFScoreRecord.fetchOne(db, key: repoId)
                        .flatMap(Self.openSSFInsight)
                )
            } catch {
                openSSFResult = .failed
            }

            let communityResult: RepositoryLocalInsightResult<RepositoryCommunityInsight>
            do {
                let record = try RepositoryInsightsSnapshotRecord
                    .filter(Column("repo_id") == repoId)
                    .filter(Column("dataset") == RepositoryInsightsDataset.communityProfile.rawValue)
                    .filter(Column("range_key") == RepositoryInsightsRangeKey.all.rawValue)
                    .fetchOne(db)
                communityResult = .value(
                    try record.map {
                        try JSONDecoder().decode(
                            RepositoryCommunityInsight.self,
                            from: $0.payloadJSON
                        )
                    }
                )
            } catch {
                communityResult = .failed
            }

                return RepositoryLocalInsightsSnapshot(
                    release: releaseResult,
                    releaseCadence: cadenceResult,
                    health: healthResult,
                    openSSF: openSSFResult,
                    community: communityResult
                )
            }
        } catch {
            return RepositoryLocalInsightsSnapshot(
                release: .failed,
                releaseCadence: .failed,
                health: .failed,
                openSSF: .failed,
                community: .failed
            )
        }
    }

    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight? {
        guard let record = try await releaseRepository.latest(forRepo: repoId) else { return nil }
        return Self.releaseInsight(record)
    }

    func releaseCadence(repoId: Int64) async throws -> RepositoryReleaseCadenceInsight? {
        let releases = try await releaseRepository.fetch(forRepo: repoId, limit: 12)
            .map(Self.releaseInsight)
        return RepositoryReleaseCadenceInsight.make(releases: releases, now: now())
    }

    func health(repoId: Int64) async throws -> RepositoryHealthInsight? {
        try await healthRepository.snapshot(for: repoId).flatMap(Self.healthInsight)
    }

    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight? {
        try await openSSFRepository.record(for: repoId).flatMap(Self.openSSFInsight)
    }

    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight? {
        try await insightsCache.load(
            repoId: repoId,
            dataset: .communityProfile,
            range: .all,
            as: RepositoryCommunityInsight.self
        )?.value
    }

    private func fallbackSnapshot(repoId: Int64) async -> RepositoryLocalInsightsSnapshot {
        async let release = captureRepositoryLocalInsight {
            try await latestRelease(repoId: repoId)
        }
        async let cadence = captureRepositoryLocalInsight {
            try await releaseCadence(repoId: repoId)
        }
        async let healthResult = captureRepositoryLocalInsight {
            try await health(repoId: repoId)
        }
        async let openSSFResult = captureRepositoryLocalInsight {
            try await openSSF(repoId: repoId)
        }
        async let community = captureRepositoryLocalInsight {
            try await cachedCommunity(repoId: repoId)
        }
        return await RepositoryLocalInsightsSnapshot(
            release: release,
            releaseCadence: cadence,
            health: healthResult,
            openSSF: openSSFResult,
            community: community
        )
    }

    private static func releaseInsight(_ record: ReleaseRecord) -> RepositoryReleaseInsight {
        RepositoryReleaseInsight(
            tagName: record.tagName,
            name: record.name,
            publishedAt: record.publishedAt.flatMap(ISO8601DateFormatter.shared.date(from:)),
            htmlURL: URL(string: record.htmlUrl)
        )
    }

    private static func healthInsight(_ snapshot: RepoHealthSnapshot) -> RepositoryHealthInsight? {
        guard snapshot.fetchStatus != .failed else { return nil }
        return RepositoryHealthInsight(
            overallScore: Int(snapshot.overallScore.rounded()),
            grade: snapshot.grade,
            maintenanceScore: Int(snapshot.maintenanceScore.rounded()),
            popularityScore: Int(snapshot.popularityScore.rounded()),
            qualityScore: Int(snapshot.qualityScore.rounded()),
            securityScore: Int(snapshot.securityScore.rounded()),
            isPartial: snapshot.fetchStatus == .partial
        )
    }

    private static func openSSFInsight(_ record: OpenSSFScoreRecord) -> RepositoryOpenSSFInsight? {
        guard record.fetchStatus == .success, let score = record.aggregateScore else { return nil }
        return RepositoryOpenSSFInsight(score: score, scoreDate: record.scoreDate)
    }
}

@MainActor
@Observable
final class RepositoryInsightsViewModel {
    private enum ManualRefreshTarget: Hashable {
        case activity
        case commitActivity
        case contributors
        case community
        case recentActivity
        case all
    }

    private struct ManualRefreshKey: Hashable {
        let repoID: Int64
        let target: ManualRefreshTarget
    }

    /// 与洞察 UI 规范一致：同一个刷新入口完成后 10 秒内不重复触发网络。
    private static let manualRefreshCooldown: TimeInterval = 10

    private let provider: any RepositoryLocalInsightsProviding
    private let remoteProvider: (any RepositoryRemoteInsightsProviding)?
    private let now: @Sendable () -> Date
    private var lastManualRefreshAt: [ManualRefreshKey: Date] = [:]
    private var generation: UInt64 = 0
    private var activityGeneration: UInt64 = 0
    private var commitGeneration: UInt64 = 0
    private var contributorGeneration: UInt64 = 0
    private var communityGeneration: UInt64 = 0
    private var securityGeneration: UInt64 = 0
    private var timelineGeneration: UInt64 = 0

    private(set) var activeRepoID: Int64?
    private(set) var releaseState: RepositoryInsightsSectionState<RepositoryReleaseInsight> = .idle
    private(set) var releaseCadenceState:
        RepositoryInsightsSectionState<RepositoryReleaseCadenceInsight> = .idle
    private(set) var healthState: RepositoryInsightsSectionState<RepositoryHealthInsight> = .idle
    private(set) var openSSFState: RepositoryInsightsSectionState<RepositoryOpenSSFInsight> = .idle
    private(set) var communityState: RepositoryInsightsSectionState<RepositoryCommunityInsight> = .idle
    private(set) var activityRange: RepositoryActivityRange = .month
    /// 提交柱图范围，与活动概览 KPI 的 `activityRange` 彼此独立。
    private(set) var commitActivityRange: RepositoryActivityRange = .month
    private(set) var activityState: RepositoryRemoteInsightsSectionState<RepositoryActivityCounts> = .idle
    private(set) var isRefreshingActivity = false
    private(set) var commitActivityState:
        RepositoryRemoteInsightsSectionState<RepositoryCommitActivity> = .idle
    private(set) var isRefreshingCommitActivity = false
    private(set) var contributorsState:
        RepositoryRemoteInsightsSectionState<RepositoryContributorsInsight> = .idle
    private(set) var isRefreshingContributors = false
    private(set) var remoteCommunityState:
        RepositoryRemoteInsightsSectionState<RepositoryCommunityInsight> = .idle
    private(set) var isRefreshingCommunity = false
    private(set) var securityAdvisoriesState:
        RepositoryRemoteInsightsSectionState<RepositorySecurityAdvisoriesInsight> = .idle
    private(set) var recentActivityState:
        RepositoryRemoteInsightsSectionState<RepositoryRecentActivity> = .idle
    private(set) var isRefreshingRecentActivity = false
    /// 底栏全局刷新；与分区 Sync 独立，分区入口继续保留。
    private(set) var isRefreshingAll = false

    init(
        provider: any RepositoryLocalInsightsProviding,
        remoteProvider: (any RepositoryRemoteInsightsProviding)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.remoteProvider = remoteProvider
        self.now = now
    }

    /// 本地 Provider 单测继续使用此入口；生产页面使用 `load(repo:isAuthenticated:)`。
    func load(repoId: Int64) async {
        _ = await loadLocalSections(repoId: repoId)
    }

    /// 返回本次本地加载的 generation，让生产入口在跨入远端阶段前再次确认所有权。
    ///
    /// SwiftUI task cancellation 只是协作式信号：数据库或测试 Provider 可能忽略取消并迟到
    /// 返回。因此不能只靠 Task cancellation，否则旧仓库会继续启动远端区块并使新 generation
    /// 失效。
    private func loadLocalSections(repoId: Int64) async -> UInt64 {
        generation &+= 1
        let requestedGeneration = generation
        activeRepoID = repoId
        releaseState = .loading
        releaseCadenceState = .loading
        healthState = .loading
        openSSFState = .loading
        communityState = .loading

        let snapshot = await provider.snapshot(repoId: repoId)
        guard generation == requestedGeneration, activeRepoID == repoId else {
            return requestedGeneration
        }
        releaseState = sectionState(from: snapshot.release)
        releaseCadenceState = sectionState(from: snapshot.releaseCadence)
        healthState = sectionState(from: snapshot.health)
        openSSFState = sectionState(from: snapshot.openSSF)
        communityState = sectionState(from: snapshot.community)
        return requestedGeneration
    }

    func load(repo: Repo, isAuthenticated: Bool) async {
        let localGeneration = await loadLocalSections(repoId: repo.id)
        guard !Task.isCancelled,
              generation == localGeneration,
              activeRepoID == repo.id
        else {
            return
        }
        async let activityLoad: Void = loadActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        async let commitLoad: Void = loadCommitActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        async let contributorLoad: Void = loadContributors(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        async let communityLoad: Void = loadCommunityProfile(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        async let securityLoad: Void = loadSecurityAdvisories(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        async let timelineLoad: Void = loadRecentActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        _ = await (
            activityLoad,
            commitLoad,
            contributorLoad,
            communityLoad,
            securityLoad,
            timelineLoad
        )
    }

    func selectActivityRange(
        _ range: RepositoryActivityRange,
        repo: Repo,
        isAuthenticated: Bool
    ) async {
        guard activityRange != range else { return }
        activityRange = range
        await loadActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false,
            preserveVisibleContent: true
        )
    }

    /// 提交图只做客户端裁剪（GitHub 一次给 52 周），不跟活动概览联动刷新。
    func selectCommitActivityRange(_ range: RepositoryActivityRange) {
        guard commitActivityRange != range else { return }
        commitActivityRange = range
    }

    func refreshActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingActivity,
              reserveManualRefresh(.activity, repoID: repo.id)
        else { return }
        await loadActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshCommitActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingCommitActivity,
              reserveManualRefresh(.commitActivity, repoID: repo.id)
        else { return }
        await loadCommitActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshContributors(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingContributors,
              reserveManualRefresh(.contributors, repoID: repo.id)
        else { return }
        await loadContributors(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshCommunityProfile(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingCommunity,
              reserveManualRefresh(.community, repoID: repo.id)
        else { return }
        await loadCommunityProfile(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshRecentActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingRecentActivity,
              reserveManualRefresh(.recentActivity, repoID: repo.id)
        else { return }
        await loadRecentActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    /// 底栏全局入口：并行强制刷新各远端区块；不碰分区 Sync，也不清空已上屏内容。
    /// 本地 Release / Health / OpenSSF 仍读库缓存，本页无对应出站刷新通道。
    func refreshAll(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingAll,
              reserveManualRefresh(.all, repoID: repo.id)
        else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        async let activityLoad: Void = loadActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        async let commitLoad: Void = loadCommitActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        async let contributorLoad: Void = loadContributors(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        async let communityLoad: Void = loadCommunityProfile(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        async let securityLoad: Void = loadSecurityAdvisories(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        async let timelineLoad: Void = loadRecentActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: true
        )
        _ = await (
            activityLoad,
            commitLoad,
            contributorLoad,
            communityLoad,
            securityLoad,
            timelineLoad
        )
    }

    /// 点击时即占用 cooldown，而不是等成功后才记录。这样快速失败或极快缓存响应也不会
    /// 被连续点击放大；当前刷新中的重复点击仍由各区块 isRefreshing 标记优先拦截。
    private func reserveManualRefresh(
        _ target: ManualRefreshTarget,
        repoID: Int64
    ) -> Bool {
        let currentDate = now()
        let key = ManualRefreshKey(repoID: repoID, target: target)
        if let lastRefresh = lastManualRefreshAt[key],
           currentDate.timeIntervalSince(lastRefresh) < Self.manualRefreshCooldown {
            return false
        }
        lastManualRefreshAt[key] = currentDate
        return true
    }

    /// DatabaseManager 已切换到另一个用户目录时，页面实例可能仍被 SwiftUI 保留。
    /// 清掉 repo 级冷却并让所有旧 generation 失效，随后由新的 task 重新加载当前仓库。
    func resetTransientStateForDatabaseScopeChange() {
        generation &+= 1
        cancelRemoteLoading()
        lastManualRefreshAt.removeAll(keepingCapacity: true)
        activeRepoID = nil
    }

    /// README 模式不保活远端刷新。generation 让已经返回的旧结果无法再写 UI。
    func cancelRemoteLoading() {
        activityGeneration &+= 1
        commitGeneration &+= 1
        contributorGeneration &+= 1
        communityGeneration &+= 1
        securityGeneration &+= 1
        timelineGeneration &+= 1
        isRefreshingActivity = false
        isRefreshingCommitActivity = false
        isRefreshingContributors = false
        isRefreshingCommunity = false
        isRefreshingRecentActivity = false
        isRefreshingAll = false
    }

    private func loadActivity(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool,
        preserveVisibleContent: Bool = false
    ) async {
        activityGeneration &+= 1
        let requestedGeneration = activityGeneration
        let selectedRange = activityRange
        // 时间范围切换与手动刷新都必须保留现有指标，直到目标范围的数据真正到达。
        // 仓库切换仍走默认 false，避免短暂显示上一个仓库的数据。
        let retainedValue = (forceRefresh || preserveVisibleContent)
            ? activityState.visibleValue
            : nil
        if !forceRefresh, !preserveVisibleContent {
            activityState = .loading(cached: nil)
        }
        if forceRefresh {
            isRefreshingActivity = true
        }
        defer {
            if requestedGeneration == activityGeneration {
                isRefreshingActivity = false
            }
        }

        guard isAuthenticated, let remoteProvider else {
            activityState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedActivityCounts?
        do {
            cached = try await remoteProvider.cachedActivity(
                repoID: repo.id,
                range: selectedRange
            )
        } catch {
            guard ownsRemoteResult(
                generation: requestedGeneration,
                repoID: repo.id,
                range: selectedRange
            ) else { return }
            activityState = .failed(cached: retainedValue)
            return
        }
        guard ownsRemoteResult(
            generation: requestedGeneration,
            repoID: repo.id,
            range: selectedRange
        ) else { return }

        if let cached {
            if !forceRefresh {
                activityState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        isRefreshingActivity = true
        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshActivity(
                repository: RepoIdentity(
                    ghRepoID: repo.id,
                    owner: repo.owner,
                    name: repo.name
                ),
                range: selectedRange
            )
            guard ownsRemoteResult(
                generation: requestedGeneration,
                repoID: repo.id,
                range: selectedRange
            ) else { return }
            activityState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsRemoteResult(
                generation: requestedGeneration,
                repoID: repo.id,
                range: selectedRange
            ) else { return }
            switch error {
            case .generating:
                activityState = .generating(cached: fallbackValue)
            case .unauthorized, .forbidden, .unavailable:
                activityState = .unavailable(cached: fallbackValue)
            default:
                activityState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsRemoteResult(
                generation: requestedGeneration,
                repoID: repo.id,
                range: selectedRange
            ) else { return }
            activityState = .failed(cached: fallbackValue)
        }
    }

    private func ownsRemoteResult(
        generation: UInt64,
        repoID: Int64,
        range: RepositoryActivityRange
    ) -> Bool {
        activityGeneration == generation
            && activeRepoID == repoID
            && activityRange == range
    }

    private func loadCommitActivity(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        commitGeneration &+= 1
        let requestedGeneration = commitGeneration
        let retainedValue = forceRefresh ? commitActivityState.visibleValue : nil
        if !forceRefresh {
            commitActivityState = .loading(cached: nil)
        }
        if forceRefresh {
            isRefreshingCommitActivity = true
        }
        defer {
            if requestedGeneration == commitGeneration {
                isRefreshingCommitActivity = false
            }
        }

        guard isAuthenticated, let remoteProvider else {
            commitActivityState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedCommitActivity?
        do {
            cached = try await remoteProvider.cachedCommitActivity(repoID: repo.id)
        } catch {
            guard ownsCommitResult(generation: requestedGeneration, repoID: repo.id) else { return }
            commitActivityState = .failed(cached: retainedValue)
            return
        }
        guard ownsCommitResult(generation: requestedGeneration, repoID: repo.id) else { return }

        if let cached {
            if !forceRefresh {
                commitActivityState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        isRefreshingCommitActivity = true
        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshCommitActivity(
                repository: RepoIdentity(
                    ghRepoID: repo.id,
                    owner: repo.owner,
                    name: repo.name
                ),
                ifNoneMatch: cached?.responseETag
            )
            guard ownsCommitResult(generation: requestedGeneration, repoID: repo.id) else { return }
            commitActivityState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsCommitResult(generation: requestedGeneration, repoID: repo.id) else { return }
            switch error {
            case .generating:
                commitActivityState = .generating(cached: fallbackValue)
            case .unauthorized, .forbidden, .unavailable:
                commitActivityState = .unavailable(cached: fallbackValue)
            default:
                commitActivityState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsCommitResult(generation: requestedGeneration, repoID: repo.id) else { return }
            commitActivityState = .failed(cached: fallbackValue)
        }
    }

    private func ownsCommitResult(generation: UInt64, repoID: Int64) -> Bool {
        commitGeneration == generation && activeRepoID == repoID
    }

    private func loadContributors(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        contributorGeneration &+= 1
        let requestedGeneration = contributorGeneration
        let retainedValue = forceRefresh ? contributorsState.visibleValue : nil
        if !forceRefresh {
            contributorsState = .loading(cached: nil)
        }
        if forceRefresh {
            isRefreshingContributors = true
        }
        defer {
            if requestedGeneration == contributorGeneration {
                isRefreshingContributors = false
            }
        }

        guard isAuthenticated, let remoteProvider else {
            contributorsState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedContributorsInsight?
        do {
            cached = try await remoteProvider.cachedContributors(repoID: repo.id)
        } catch {
            guard ownsContributorResult(generation: requestedGeneration, repoID: repo.id) else { return }
            contributorsState = .failed(cached: retainedValue)
            return
        }
        guard ownsContributorResult(generation: requestedGeneration, repoID: repo.id) else { return }

        if let cached {
            if !forceRefresh {
                contributorsState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        isRefreshingContributors = true
        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshContributors(
                repository: repoIdentity(for: repo),
                ifNoneMatch: cached?.responseETag
            )
            guard ownsContributorResult(generation: requestedGeneration, repoID: repo.id) else { return }
            contributorsState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsContributorResult(generation: requestedGeneration, repoID: repo.id) else { return }
            switch error {
            case .unauthorized, .forbidden, .unavailable:
                contributorsState = .unavailable(cached: fallbackValue)
            default:
                contributorsState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsContributorResult(generation: requestedGeneration, repoID: repo.id) else { return }
            contributorsState = .failed(cached: fallbackValue)
        }
    }

    private func loadCommunityProfile(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        communityGeneration &+= 1
        let requestedGeneration = communityGeneration
        let retainedValue = forceRefresh ? remoteCommunityState.visibleValue : nil
        if !forceRefresh {
            remoteCommunityState = .loading(cached: nil)
        }
        if forceRefresh {
            isRefreshingCommunity = true
        }
        defer {
            if requestedGeneration == communityGeneration {
                isRefreshingCommunity = false
            }
        }

        guard let remoteProvider else {
            remoteCommunityState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedCommunityInsight?
        do {
            cached = try await remoteProvider.cachedCommunityProfile(repoID: repo.id)
        } catch {
            guard ownsCommunityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            remoteCommunityState = .failed(cached: retainedValue)
            return
        }
        guard ownsCommunityResult(generation: requestedGeneration, repoID: repo.id) else { return }

        if let cached {
            if !forceRefresh {
                remoteCommunityState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !isAuthenticated || (!cached.isStale && !forceRefresh) {
                return
            }
        } else if !isAuthenticated {
            remoteCommunityState = .unavailable(cached: retainedValue)
            return
        }

        isRefreshingCommunity = true
        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshCommunityProfile(
                repository: repoIdentity(for: repo),
                ifNoneMatch: cached?.responseETag
            )
            guard ownsCommunityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            remoteCommunityState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsCommunityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            switch error {
            case .unauthorized, .forbidden, .unavailable:
                remoteCommunityState = .unavailable(cached: fallbackValue)
            default:
                remoteCommunityState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsCommunityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            remoteCommunityState = .failed(cached: fallbackValue)
        }
    }

    private func ownsContributorResult(generation: UInt64, repoID: Int64) -> Bool {
        contributorGeneration == generation && activeRepoID == repoID
    }

    private func ownsCommunityResult(generation: UInt64, repoID: Int64) -> Bool {
        communityGeneration == generation && activeRepoID == repoID
    }

    /// 安全公告只跟随页面首次加载和底栏全局刷新，不再增加一个分区刷新按钮。
    /// force refresh 期间保留旧值，GitHub 权限不足时也不会把旧值清空成“零公告”。
    private func loadSecurityAdvisories(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        securityGeneration &+= 1
        let requestedGeneration = securityGeneration
        let retainedValue = forceRefresh ? securityAdvisoriesState.visibleValue : nil
        if !forceRefresh {
            securityAdvisoriesState = .loading(cached: nil)
        }

        guard isAuthenticated, let remoteProvider else {
            securityAdvisoriesState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedSecurityAdvisoriesInsight?
        do {
            cached = try await remoteProvider.cachedSecurityAdvisories(repoID: repo.id)
        } catch {
            guard ownsSecurityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            securityAdvisoriesState = .failed(cached: retainedValue)
            return
        }
        guard ownsSecurityResult(generation: requestedGeneration, repoID: repo.id) else { return }

        if let cached {
            if !forceRefresh {
                securityAdvisoriesState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshSecurityAdvisories(
                repository: repoIdentity(for: repo),
                ifNoneMatch: cached?.responseETag
            )
            guard ownsSecurityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            securityAdvisoriesState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsSecurityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            switch error {
            case .unauthorized, .forbidden, .unavailable:
                securityAdvisoriesState = .unavailable(cached: fallbackValue)
            default:
                securityAdvisoriesState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsSecurityResult(generation: requestedGeneration, repoID: repo.id) else { return }
            securityAdvisoriesState = .failed(cached: fallbackValue)
        }
    }

    private func ownsSecurityResult(generation: UInt64, repoID: Int64) -> Bool {
        securityGeneration == generation && activeRepoID == repoID
    }

    private func repoIdentity(for repo: Repo) -> RepoIdentity {
        RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name)
    }

    private func loadRecentActivity(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        timelineGeneration &+= 1
        let requestedGeneration = timelineGeneration
        let retainedValue = forceRefresh ? recentActivityState.visibleValue : nil
        if !forceRefresh {
            recentActivityState = .loading(cached: nil)
        }
        if forceRefresh {
            isRefreshingRecentActivity = true
        }
        defer {
            if requestedGeneration == timelineGeneration {
                isRefreshingRecentActivity = false
            }
        }

        guard isAuthenticated, let remoteProvider else {
            recentActivityState = .unavailable(cached: retainedValue)
            return
        }

        let cached: RepositoryCachedRecentActivity?
        do {
            cached = try await remoteProvider.cachedRecentActivity(repoID: repo.id)
        } catch {
            guard ownsTimelineResult(generation: requestedGeneration, repoID: repo.id) else { return }
            recentActivityState = .failed(cached: retainedValue)
            return
        }
        guard ownsTimelineResult(generation: requestedGeneration, repoID: repo.id) else { return }

        if let cached {
            if !forceRefresh {
                recentActivityState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            }
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        isRefreshingRecentActivity = true
        let fallbackValue = retainedValue ?? cached?.value
        do {
            let fresh = try await remoteProvider.refreshRecentActivity(
                repository: repoIdentity(for: repo),
                activityRange: activityRange
            )
            guard ownsTimelineResult(generation: requestedGeneration, repoID: repo.id) else { return }
            recentActivityState = .content(fresh)
        } catch let error as GitHubRepositoryMetricsError {
            guard ownsTimelineResult(generation: requestedGeneration, repoID: repo.id) else { return }
            switch error {
            case .unauthorized, .forbidden, .unavailable:
                recentActivityState = .unavailable(cached: fallbackValue)
            default:
                recentActivityState = .failed(cached: fallbackValue)
            }
        } catch {
            guard ownsTimelineResult(generation: requestedGeneration, repoID: repo.id) else { return }
            recentActivityState = .failed(cached: fallbackValue)
        }
    }

    private func ownsTimelineResult(generation: UInt64, repoID: Int64) -> Bool {
        timelineGeneration == generation && activeRepoID == repoID
    }

    private func sectionState<Value: Equatable & Sendable>(
        from result: RepositoryLocalInsightResult<Value>
    ) -> RepositoryInsightsSectionState<Value> {
        switch result {
        case .value(let value):
            return value.map(RepositoryInsightsSectionState.content) ?? .empty
        case .failed:
            return .failed
        }
    }
}
