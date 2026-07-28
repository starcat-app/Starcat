//
//  RepositoryInsightsViewModel.swift
//  Starcat
//
//  仓库洞察的本地数据状态机。Release、Health、OpenSSF 与 Community 各自独立，
//  单一区块失败不会把整个页面切成错误态；repo generation 防止快速切换时旧结果回写。
//

import Foundation

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

protocol RepositoryLocalInsightsProviding: Sendable {
    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight?
    func health(repoId: Int64) async throws -> RepositoryHealthInsight?
    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight?
    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight?
}

struct DefaultRepositoryLocalInsightsProvider: RepositoryLocalInsightsProviding, Sendable {
    let releaseRepository: any ReleaseRepositoryProtocol
    let healthRepository: any RepoHealthRepositoryProtocol
    let openSSFRepository: any OpenSSFScoreRepositoryProtocol
    let insightsCache: any RepositoryInsightsCaching

    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight? {
        guard let record = try await releaseRepository.latest(forRepo: repoId) else { return nil }
        return RepositoryReleaseInsight(
            tagName: record.tagName,
            name: record.name,
            publishedAt: record.publishedAt.flatMap(ISO8601DateFormatter.shared.date(from:)),
            htmlURL: URL(string: record.htmlUrl)
        )
    }

    func health(repoId: Int64) async throws -> RepositoryHealthInsight? {
        guard let snapshot = try await healthRepository.snapshot(for: repoId),
              snapshot.fetchStatus != .failed else { return nil }
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

    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight? {
        guard let record = try await openSSFRepository.record(for: repoId),
              record.fetchStatus == .success,
              let score = record.aggregateScore else { return nil }
        return RepositoryOpenSSFInsight(score: score, scoreDate: record.scoreDate)
    }

    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight? {
        try await insightsCache.load(
            repoId: repoId,
            dataset: .communityProfile,
            range: .all,
            as: RepositoryCommunityInsight.self
        )?.value
    }
}

@MainActor
@Observable
final class RepositoryInsightsViewModel {
    private enum LoadEvent: Sendable {
        case release(RepositoryReleaseInsight?)
        case releaseFailed
        case health(RepositoryHealthInsight?)
        case healthFailed
        case openSSF(RepositoryOpenSSFInsight?)
        case openSSFFailed
        case community(RepositoryCommunityInsight?)
        case communityFailed
    }

    private let provider: any RepositoryLocalInsightsProviding
    private let remoteProvider: (any RepositoryRemoteInsightsProviding)?
    private var generation: UInt64 = 0
    private var activityGeneration: UInt64 = 0
    private var commitGeneration: UInt64 = 0
    private var contributorGeneration: UInt64 = 0
    private var communityGeneration: UInt64 = 0
    private var timelineGeneration: UInt64 = 0

    private(set) var activeRepoID: Int64?
    private(set) var releaseState: RepositoryInsightsSectionState<RepositoryReleaseInsight> = .idle
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
    private(set) var recentActivityState:
        RepositoryRemoteInsightsSectionState<RepositoryRecentActivity> = .idle
    private(set) var isRefreshingRecentActivity = false
    /// 底栏全局刷新；与分区 Sync 独立，分区入口继续保留。
    private(set) var isRefreshingAll = false

    init(
        provider: any RepositoryLocalInsightsProviding,
        remoteProvider: (any RepositoryRemoteInsightsProviding)? = nil
    ) {
        self.provider = provider
        self.remoteProvider = remoteProvider
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
        healthState = .loading
        openSSFState = .loading
        communityState = .loading

        await withTaskGroup(of: LoadEvent.self) { group in
            group.addTask { [provider] in
                do { return .release(try await provider.latestRelease(repoId: repoId)) }
                catch { return .releaseFailed }
            }
            group.addTask { [provider] in
                do { return .health(try await provider.health(repoId: repoId)) }
                catch { return .healthFailed }
            }
            group.addTask { [provider] in
                do { return .openSSF(try await provider.openSSF(repoId: repoId)) }
                catch { return .openSSFFailed }
            }
            group.addTask { [provider] in
                do { return .community(try await provider.cachedCommunity(repoId: repoId)) }
                catch { return .communityFailed }
            }

            for await event in group {
                guard generation == requestedGeneration, activeRepoID == repoId else { continue }
                apply(event)
            }
        }
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
        async let timelineLoad: Void = loadRecentActivity(
            repo: repo,
            isAuthenticated: isAuthenticated,
            forceRefresh: false
        )
        _ = await (activityLoad, commitLoad, contributorLoad, communityLoad, timelineLoad)
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
        guard !isRefreshingActivity else { return }
        await loadActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshCommitActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingCommitActivity else { return }
        await loadCommitActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshContributors(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingContributors else { return }
        await loadContributors(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshCommunityProfile(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingCommunity else { return }
        await loadCommunityProfile(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    func refreshRecentActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingRecentActivity else { return }
        await loadRecentActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    /// 底栏全局入口：并行强制刷新各远端区块；不碰分区 Sync，也不清空已上屏内容。
    /// 本地 Release / Health / OpenSSF 仍读库缓存，本页无对应出站刷新通道。
    func refreshAll(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingAll else { return }
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
            timelineLoad
        )
    }

    /// README 模式不保活远端刷新。generation 让已经返回的旧结果无法再写 UI。
    func cancelRemoteLoading() {
        activityGeneration &+= 1
        commitGeneration &+= 1
        contributorGeneration &+= 1
        communityGeneration &+= 1
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
                )
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
                repository: repoIdentity(for: repo)
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
                repository: repoIdentity(for: repo)
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
                repository: repoIdentity(for: repo)
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

    private func apply(_ event: LoadEvent) {
        switch event {
        case .release(let value):
            releaseState = value.map(RepositoryInsightsSectionState.content) ?? .empty
        case .releaseFailed:
            releaseState = .failed
        case .health(let value):
            healthState = value.map(RepositoryInsightsSectionState.content) ?? .empty
        case .healthFailed:
            healthState = .failed
        case .openSSF(let value):
            openSSFState = value.map(RepositoryInsightsSectionState.content) ?? .empty
        case .openSSFFailed:
            openSSFState = .failed
        case .community(let value):
            communityState = value.map(RepositoryInsightsSectionState.content) ?? .empty
        case .communityFailed:
            communityState = .failed
        }
    }
}
