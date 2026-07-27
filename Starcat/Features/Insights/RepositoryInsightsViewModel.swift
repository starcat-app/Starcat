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
}

struct RepositoryReleaseInsight: Equatable, Sendable {
    let tagName: String
    let name: String?
    let publishedAt: Date?
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
struct RepositoryCommunityInsight: Codable, Equatable, Sendable {
    let healthPercentage: Int
    let hasReadme: Bool
    let hasCodeOfConduct: Bool
    let hasContributing: Bool
    let hasLicense: Bool
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
            publishedAt: record.publishedAt.flatMap(ISO8601DateFormatter.shared.date(from:))
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
    private var remoteGeneration: UInt64 = 0

    private(set) var activeRepoID: Int64?
    private(set) var releaseState: RepositoryInsightsSectionState<RepositoryReleaseInsight> = .idle
    private(set) var healthState: RepositoryInsightsSectionState<RepositoryHealthInsight> = .idle
    private(set) var openSSFState: RepositoryInsightsSectionState<RepositoryOpenSSFInsight> = .idle
    private(set) var communityState: RepositoryInsightsSectionState<RepositoryCommunityInsight> = .idle
    private(set) var activityRange: RepositoryActivityRange = .month
    private(set) var activityState: RepositoryRemoteInsightsSectionState<RepositoryActivityCounts> = .idle
    private(set) var isRefreshingActivity = false

    init(
        provider: any RepositoryLocalInsightsProviding,
        remoteProvider: (any RepositoryRemoteInsightsProviding)? = nil
    ) {
        self.provider = provider
        self.remoteProvider = remoteProvider
    }

    /// 本地 Provider 单测继续使用此入口；生产页面使用 `load(repo:isAuthenticated:)`。
    func load(repoId: Int64) async {
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
    }

    func load(repo: Repo, isAuthenticated: Bool) async {
        await load(repoId: repo.id)
        await loadActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: false)
    }

    func selectActivityRange(
        _ range: RepositoryActivityRange,
        repo: Repo,
        isAuthenticated: Bool
    ) async {
        guard activityRange != range else { return }
        activityRange = range
        await loadActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: false)
    }

    func refreshActivity(repo: Repo, isAuthenticated: Bool) async {
        guard !isRefreshingActivity else { return }
        await loadActivity(repo: repo, isAuthenticated: isAuthenticated, forceRefresh: true)
    }

    /// README 模式不保活远端刷新。generation 让已经返回的旧结果无法再写 UI。
    func cancelRemoteLoading() {
        remoteGeneration &+= 1
        isRefreshingActivity = false
    }

    private func loadActivity(
        repo: Repo,
        isAuthenticated: Bool,
        forceRefresh: Bool
    ) async {
        remoteGeneration &+= 1
        let requestedGeneration = remoteGeneration
        let selectedRange = activityRange
        activityState = .loading(cached: nil)

        guard isAuthenticated, let remoteProvider else {
            activityState = .unavailable(cached: nil)
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
            activityState = .failed(cached: nil)
            return
        }
        guard ownsRemoteResult(
            generation: requestedGeneration,
            repoID: repo.id,
            range: selectedRange
        ) else { return }

        if let cached {
            activityState = cached.isStale ? .stale(cached.value) : .content(cached.value)
            if !cached.isStale, !forceRefresh {
                return
            }
        }

        isRefreshingActivity = true
        defer {
            if requestedGeneration == remoteGeneration {
                isRefreshingActivity = false
            }
        }
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
                activityState = .generating(cached: cached?.value)
            case .unauthorized, .forbidden, .unavailable:
                activityState = .unavailable(cached: cached?.value)
            default:
                activityState = .failed(cached: cached?.value)
            }
        } catch {
            guard ownsRemoteResult(
                generation: requestedGeneration,
                repoID: repo.id,
                range: selectedRange
            ) else { return }
            activityState = .failed(cached: cached?.value)
        }
    }

    private func ownsRemoteResult(
        generation: UInt64,
        repoID: Int64,
        range: RepositoryActivityRange
    ) -> Bool {
        remoteGeneration == generation
            && activeRepoID == repoID
            && activityRange == range
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
