//
//  RepositoryInsightsAIContextProvider.swift
//  Starcat
//
//  AI 摘要、AI 对话与仓库洞察页面共用的数据准备入口。
//
//  关键约束：
//  - 只通过 RepositoryRemoteInsightsProviding / RepoStarHistoryRepositoryProtocol 取数，
//    让 AI 与页面复用同一 SQLite 缓存及 single-flight，禁止另建一套洞察缓存。
//  - 缓存新鲜时零网络；缓存过期时刷新失败仍回退旧值，洞察不是 AI 主流程的硬失败点。
//  - Prompt 只注入聚合事实，不注入 Issue / PR 标题和安全公告正文，降低 prompt injection
//    风险并控制 token 体积。
//

import Foundation

struct RepositoryInsightsAIContext: Equatable, Sendable {
    let content: String

    static let empty = RepositoryInsightsAIContext(content: "")

    var isEmpty: Bool {
        content.isEmpty
    }
}

protocol RepositoryInsightsAIContextProviding: Sendable {
    func context(for repo: Repo) async -> RepositoryInsightsAIContext
}

protocol RepositoryInsightsDocumentProviding: Sendable {
    func document(for repo: Repo) async -> RepositoryInsightsDocument
    func cachedDocument(for repo: Repo) async -> RepositoryInsightsDocument
}

extension RepositoryInsightsDocumentProviding {
    func cachedDocument(for repo: Repo) async -> RepositoryInsightsDocument {
        await document(for: repo)
    }
}

struct DefaultRepositoryInsightsAIContextProvider:
    RepositoryInsightsAIContextProviding,
    RepositoryInsightsDocumentProviding,
    Sendable
{

    private let localProvider: any RepositoryLocalInsightsProviding
    private let remoteProvider: any RepositoryRemoteInsightsProviding
    private let starHistoryRepository: any RepoStarHistoryRepositoryProtocol
    private let now: @Sendable () -> Date

    init(
        localProvider: any RepositoryLocalInsightsProviding,
        remoteProvider: any RepositoryRemoteInsightsProviding,
        starHistoryRepository: any RepoStarHistoryRepositoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.localProvider = localProvider
        self.remoteProvider = remoteProvider
        self.starHistoryRepository = starHistoryRepository
        self.now = now
    }

    func context(for repo: Repo) async -> RepositoryInsightsAIContext {
        let document = await document(for: repo)
        return RepositoryInsightsAIContext(content: document.xml)
    }

    func document(for repo: Repo) async -> RepositoryInsightsDocument {
        let snapshot = await snapshot(for: repo)
        return RepositoryInsightsXMLRenderer.render(snapshot: snapshot, generatedAt: now())
    }

    /// RAG 后台只允许读取现有缓存；缺数据也返回部分文档，绝不从知识库查询链路扇出网络。
    func cachedDocument(for repo: Repo) async -> RepositoryInsightsDocument {
        let snapshot = await cachedSnapshot(for: repo)
        return RepositoryInsightsXMLRenderer.render(snapshot: snapshot, generatedAt: now())
    }

    /// 只负责准备结构化事实；XML、文件存储与 Prompt 注入由后续边界分别处理。
    private func snapshot(for repo: Repo) async -> RepositoryInsightsSnapshot {
        let local = await localProvider.snapshot(repoId: repo.id)

        // StarHistoryRepository 自己负责“我的项目”权限路由与公共 Discovery 回退；
        // 私有仓库也必须走它，不能套用普通 GitHub Metrics 的 public-only 门禁。
        async let starHistory = prepareStarHistory(for: repo)

        guard !repo.isPrivate else {
            return await Self.snapshot(
                repo: repo,
                local: local,
                releaseCadence: nil,
                activity: nil,
                commitActivity: nil,
                contributors: nil,
                community: nil,
                security: nil,
                recentActivity: nil,
                starHistory: starHistory
            )
        }

        async let activity = prepareActivity(for: repo)
        async let commitActivity = prepareCommitActivity(for: repo)
        async let contributors = prepareContributors(for: repo)
        async let community = prepareCommunity(for: repo)
        async let security = prepareSecurity(for: repo)
        async let recentActivity = prepareRecentActivity(for: repo)

        let localCadence = Self.localValue(local.releaseCadence)
        let releaseCadence: RepositoryInsightsPreparedValue<RepositoryReleaseCadenceInsight>?
        if localCadence == nil {
            releaseCadence = await prepareReleaseCadence(for: repo)
        } else {
            releaseCadence = nil
        }

        return await Self.snapshot(
            repo: repo,
            local: local,
            releaseCadence: releaseCadence,
            activity: activity,
            commitActivity: commitActivity,
            contributors: contributors,
            community: community,
            security: security,
            recentActivity: recentActivity,
            starHistory: starHistory
        )
    }

    private func cachedSnapshot(for repo: Repo) async -> RepositoryInsightsSnapshot {
        let local = await localProvider.snapshot(repoId: repo.id)
        async let starHistory = try? starHistoryRepository.cached(repo: repo, range: .oneYear)

        guard !repo.isPrivate else {
            return await Self.snapshot(
                repo: repo,
                local: local,
                releaseCadence: nil,
                activity: nil,
                commitActivity: nil,
                contributors: nil,
                community: nil,
                security: nil,
                recentActivity: nil,
                starHistory: starHistory
            )
        }

        async let activity = cachedPrepared(
            load: { try await remoteProvider.cachedActivity(repoID: repo.id, range: .month) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let commitActivity = cachedPrepared(
            load: { try await remoteProvider.cachedCommitActivity(repoID: repo.id) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let contributors = cachedPrepared(
            load: { try await remoteProvider.cachedContributors(repoID: repo.id) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let community = cachedPrepared(
            load: { try await remoteProvider.cachedCommunityProfile(repoID: repo.id) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let security = cachedPrepared(
            load: { try await remoteProvider.cachedSecurityAdvisories(repoID: repo.id) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let recentActivity = cachedPrepared(
            load: { try await remoteProvider.cachedRecentActivity(repoID: repo.id) },
            value: \.value,
            fetchedAt: \.fetchedAt,
            isStale: \.isStale
        )
        async let remoteReleaseCadence: RepositoryInsightsPreparedValue<
            RepositoryReleaseCadenceInsight
        >? = {
            guard let cached = try? await remoteProvider.cachedReleaseCadence(repoID: repo.id),
                  let value = cached.value else {
                return nil
            }
            return RepositoryInsightsPreparedValue(
                value: value,
                fetchedAt: cached.fetchedAt,
                isStale: cached.isStale
            )
        }()

        return await Self.snapshot(
            repo: repo,
            local: local,
            releaseCadence: remoteReleaseCadence,
            activity: activity,
            commitActivity: commitActivity,
            contributors: contributors,
            community: community,
            security: security,
            recentActivity: recentActivity,
            starHistory: starHistory
        )
    }

    private func cachedPrepared<Cached: Sendable, Value: Sendable>(
        load: @escaping @Sendable () async throws -> Cached?,
        value: KeyPath<Cached, Value>,
        fetchedAt: KeyPath<Cached, Date>,
        isStale: KeyPath<Cached, Bool>
    ) async -> RepositoryInsightsPreparedValue<Value>? {
        guard let cached = try? await load() else { return nil }
        return RepositoryInsightsPreparedValue(
            value: cached[keyPath: value],
            fetchedAt: cached[keyPath: fetchedAt],
            isStale: cached[keyPath: isStale]
        )
    }

    private func prepareActivity(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryActivityCounts>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedActivity(repoID: repo.id, range: .month)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { _ in
                try await remoteProvider.refreshActivity(
                    repository: identity,
                    range: .month
                )
            }
        )
    }

    private func prepareCommitActivity(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryCommitActivity>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedCommitActivity(repoID: repo.id)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { cached in
                try await remoteProvider.refreshCommitActivity(
                    repository: identity,
                    ifNoneMatch: cached?.responseETag
                )
            }
        )
    }

    private func prepareContributors(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryContributorsInsight>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedContributors(repoID: repo.id)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { cached in
                try await remoteProvider.refreshContributors(
                    repository: identity,
                    ifNoneMatch: cached?.responseETag
                )
            }
        )
    }

    private func prepareCommunity(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryCommunityInsight>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedCommunityProfile(repoID: repo.id)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { cached in
                try await remoteProvider.refreshCommunityProfile(
                    repository: identity,
                    ifNoneMatch: cached?.responseETag
                )
            }
        )
    }

    private func prepareSecurity(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositorySecurityAdvisoriesInsight>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedSecurityAdvisories(repoID: repo.id)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { cached in
                try await remoteProvider.refreshSecurityAdvisories(
                    repository: identity,
                    ifNoneMatch: cached?.responseETag
                )
            }
        )
    }

    private func prepareRecentActivity(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryRecentActivity>? {
        let identity = Self.identity(for: repo)
        return await prepare(
            cached: {
                try await remoteProvider.cachedRecentActivity(repoID: repo.id)
            },
            cachedValue: \.value,
            cachedFetchedAt: \.fetchedAt,
            cachedIsStale: \.isStale,
            refresh: { _ in
                try await remoteProvider.refreshRecentActivity(
                    repository: identity,
                    activityRange: .month
                )
            }
        )
    }

    private func prepareReleaseCadence(
        for repo: Repo
    ) async -> RepositoryInsightsPreparedValue<RepositoryReleaseCadenceInsight>? {
        let identity = Self.identity(for: repo)
        let cached: RepositoryCachedReleaseCadenceInsight?
        do {
            cached = try await remoteProvider.cachedReleaseCadence(repoID: repo.id)
        } catch {
            return try? await remoteProvider.refreshReleaseCadence(repository: identity).map {
                RepositoryInsightsPreparedValue(value: $0, fetchedAt: now(), isStale: false)
            }
        }

        if let cached, !cached.isStale {
            return cached.value.map {
                RepositoryInsightsPreparedValue(
                    value: $0,
                    fetchedAt: cached.fetchedAt,
                    isStale: false
                )
            }
        }

        do {
            return try await remoteProvider.refreshReleaseCadence(
                repository: identity,
                ifNoneMatch: cached?.responseETag
            ).map {
                RepositoryInsightsPreparedValue(value: $0, fetchedAt: now(), isStale: false)
            }
        } catch {
            return cached?.value.map {
                RepositoryInsightsPreparedValue(
                    value: $0,
                    fetchedAt: cached?.fetchedAt,
                    isStale: true
                )
            }
        }
    }

    private func prepareStarHistory(for repo: Repo) async -> StarHistorySnapshot? {
        let cached = try? await starHistoryRepository.cached(repo: repo, range: .oneYear)
        do {
            return try await starHistoryRepository.refresh(
                repo: repo,
                range: .oneYear,
                forceRefresh: false
            )
        } catch {
            return cached
        }
    }

    private func prepare<Cached: Sendable, Value: Sendable>(
        cached: @escaping @Sendable () async throws -> Cached?,
        cachedValue: KeyPath<Cached, Value>,
        cachedFetchedAt: KeyPath<Cached, Date>,
        cachedIsStale: KeyPath<Cached, Bool>,
        refresh: @escaping @Sendable (Cached?) async throws -> Value
    ) async -> RepositoryInsightsPreparedValue<Value>? {
        let cachedResult: Cached?
        do {
            cachedResult = try await cached()
        } catch {
            cachedResult = nil
        }

        if let cachedResult, !cachedResult[keyPath: cachedIsStale] {
            return RepositoryInsightsPreparedValue(
                value: cachedResult[keyPath: cachedValue],
                fetchedAt: cachedResult[keyPath: cachedFetchedAt],
                isStale: false
            )
        }

        do {
            return RepositoryInsightsPreparedValue(
                value: try await refresh(cachedResult),
                fetchedAt: now(),
                isStale: false
            )
        } catch {
            guard let cachedResult else { return nil }
            return RepositoryInsightsPreparedValue(
                value: cachedResult[keyPath: cachedValue],
                fetchedAt: cachedResult[keyPath: cachedFetchedAt],
                isStale: true
            )
        }
    }

    private static func snapshot(
        repo: Repo,
        local: RepositoryLocalInsightsSnapshot,
        releaseCadence remoteReleaseCadence:
            RepositoryInsightsPreparedValue<RepositoryReleaseCadenceInsight>?,
        activity: RepositoryInsightsPreparedValue<RepositoryActivityCounts>?,
        commitActivity: RepositoryInsightsPreparedValue<RepositoryCommitActivity>?,
        contributors: RepositoryInsightsPreparedValue<RepositoryContributorsInsight>?,
        community remoteCommunity: RepositoryInsightsPreparedValue<RepositoryCommunityInsight>?,
        security: RepositoryInsightsPreparedValue<RepositorySecurityAdvisoriesInsight>?,
        recentActivity: RepositoryInsightsPreparedValue<RepositoryRecentActivity>?,
        starHistory: StarHistorySnapshot?
    ) -> RepositoryInsightsSnapshot {
        let localCadence = localValue(local.releaseCadence)
        let releaseCadence = localCadence.map {
            RepositoryInsightsPreparedValue(value: $0, fetchedAt: nil, isStale: false)
        } ?? remoteReleaseCadence
        let localCommunity = localValue(local.community)
        let community = remoteCommunity ?? localCommunity.map {
            RepositoryInsightsPreparedValue(value: $0, fetchedAt: nil, isStale: false)
        }
        return RepositoryInsightsSnapshot(
            repo: repo,
            release: localValue(local.release),
            releaseCadence: releaseCadence,
            health: localValue(local.health),
            openSSF: localValue(local.openSSF),
            community: community,
            activity: activity,
            commitActivity: commitActivity,
            contributors: contributors,
            security: security,
            recentActivity: recentActivity,
            starHistory: starHistory,
            localFailureCount: [
                isFailure(local.release),
                isFailure(local.releaseCadence),
                isFailure(local.health),
                isFailure(local.openSSF),
                isFailure(local.community)
            ].count(where: { $0 })
        )
    }

    private static func isFailure<Value>(
        _ result: RepositoryLocalInsightResult<Value>
    ) -> Bool {
        if case .failed = result { return true }
        return false
    }

    private static func localValue<Value>(
        _ result: RepositoryLocalInsightResult<Value>
    ) -> Value? {
        switch result {
        case .value(let value):
            return value
        case .failed:
            return nil
        }
    }

    private static func identity(for repo: Repo) -> RepoIdentity {
        RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name)
    }

}
