//
//  RepositoryInsightsViewModelTests.swift
//  StarcatTests
//
//  验证仓库洞察本地各区块独立收敛，并阻止快速切换时旧 repo 结果覆盖新 repo。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Repository insights view model")
struct RepositoryInsightsViewModelTests {

    @Test("活动刷新失败保留 stale 缓存")
    func staleActivitySurvivesRefreshFailure() async {
        let cached = RepositoryActivityCounts(
            createdPullRequests: 4,
            mergedPullRequests: 3,
            createdIssues: 2,
            closedIssues: 1,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: cached,
                    fetchedAt: cached.generatedAt,
                    isStale: true
                )
            },
            refreshHandler: { _, _ in throw StubError.failed }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )

        await viewModel.load(repo: fixtureRepo(id: 11), isAuthenticated: true)

        #expect(viewModel.activityState == .failed(cached: cached))
        #expect(!viewModel.isRefreshingActivity)
    }

    @Test("较慢的旧活动范围不能覆盖新范围")
    func staleActivityRangeIsDiscarded() async {
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, range in
                if range == .week {
                    try await Task.sleep(for: .milliseconds(120))
                }
                return RepositoryActivityCounts(
                    createdPullRequests: range.dayCount,
                    mergedPullRequests: 0,
                    createdIssues: 0,
                    closedIssues: 0,
                    generatedAt: Date()
                )
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )
        let repo = fixtureRepo(id: 12)
        await viewModel.load(repo: repo, isAuthenticated: false)

        let oldLoad = Task {
            await viewModel.selectActivityRange(.week, repo: repo, isAuthenticated: true)
        }
        try? await Task.sleep(for: .milliseconds(20))
        await viewModel.selectActivityRange(.year, repo: repo, isAuthenticated: true)
        await oldLoad.value

        #expect(viewModel.activityRange == .year)
        guard case .content(let counts) = viewModel.activityState else {
            Issue.record("Expected current range content")
            return
        }
        #expect(counts.createdPullRequests == RepositoryActivityRange.year.dayCount)
    }

    @Test("未登录时社区缓存仍可显示且贡献者保持独立提示")
    func signedOutCommunityCacheRemainsVisible() async {
        let community = RepositoryCommunityInsight(
            healthPercentage: 80,
            hasReadme: true,
            hasCodeOfConduct: false,
            hasContributing: true,
            hasLicense: true
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            cachedCommunityHandler: { _ in
                RepositoryCachedCommunityInsight(
                    value: community,
                    fetchedAt: Date(timeIntervalSince1970: 1_000),
                    isStale: true
                )
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )

        await viewModel.load(repo: fixtureRepo(id: 13), isAuthenticated: false)

        #expect(viewModel.remoteCommunityState == .stale(community))
        #expect(viewModel.contributorsState == .unavailable(cached: nil))
        #expect(viewModel.activityState == .unavailable(cached: nil))
    }

    @Test("默认数据源映射已有 Release、Health、OpenSSF 与 Community 缓存")
    func defaultProviderMapsExistingLocalData() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7)

        let releaseRepository = GRDBReleaseRepository(database: database)
        try await releaseRepository.upsertMany(
            [
                ReleaseRecord(
                    id: 70,
                    repoId: 7,
                    tagName: "v2.1.0",
                    name: "Stable",
                    bodyMarkdown: nil,
                    htmlUrl: "https://github.com/octo/demo-7/releases/tag/v2.1.0",
                    isPrerelease: false,
                    isDraft: false,
                    publishedAt: "2026-07-20T00:00:00Z",
                    createdAtRemote: "2026-07-20T00:00:00Z",
                    assetsJson: nil,
                    isRead: false,
                    fetchedAt: "2026-07-27T00:00:00Z"
                )
            ],
            isReadDefault: false
        )

        let healthRepository = GRDBRepoHealthRepository(database: database)
        try await healthRepository.upsert(
            RepoHealthSnapshot(
                repoId: 7,
                overallScore: 88.4,
                grade: "A",
                maintenanceScore: 90.1,
                popularityScore: 87.2,
                qualityScore: 86.6,
                securityScore: 89.4,
                payloadJSON: "{}",
                computedAt: "2026-07-27T00:00:00Z",
                staleAfter: "2026-07-28T00:00:00Z",
                fetchStatus: .success,
                lastError: nil
            )
        )

        let openSSFRepository = GRDBOpenSSFScoreRepository(database: database)
        try await openSSFRepository.upsert(
            OpenSSFScoreRecord(
                repoId: 7,
                fetchStatus: .success,
                aggregateScore: 8.7,
                checksJSON: nil,
                scoreDate: "2026-07-27",
                fetchedAt: "2026-07-27T00:00:00Z",
                lastError: nil
            )
        )

        let cache = GRDBRepositoryInsightsCache(database: database)
        let community = RepositoryCommunityInsight(
            healthPercentage: 92,
            hasReadme: true,
            hasCodeOfConduct: false,
            hasContributing: true,
            hasLicense: true
        )
        try await cache.store(
            community,
            repoId: 7,
            dataset: .communityProfile,
            range: .all,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            responseETag: nil,
            defaultBranchSHA: nil
        )

        let provider = DefaultRepositoryLocalInsightsProvider(
            releaseRepository: releaseRepository,
            healthRepository: healthRepository,
            openSSFRepository: openSSFRepository,
            insightsCache: cache
        )

        let release = try #require(try await provider.latestRelease(repoId: 7))
        let health = try #require(try await provider.health(repoId: 7))
        let openSSF = try #require(try await provider.openSSF(repoId: 7))
        let cachedCommunity = try #require(try await provider.cachedCommunity(repoId: 7))

        #expect(release.tagName == "v2.1.0")
        #expect(release.name == "Stable")
        #expect(health.overallScore == 88)
        #expect(health.maintenanceScore == 90)
        #expect(openSSF == RepositoryOpenSSFInsight(score: 8.7, scoreDate: "2026-07-27"))
        #expect(cachedCommunity == community)
    }

    @Test("本地区块独立加载且单一区块失败不影响其他结果")
    func sectionsLoadIndependently() async {
        let provider = StubRepositoryLocalInsightsProvider(
            release: { _ in RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil) },
            health: { _ in RepositoryHealthInsight(
                overallScore: 80,
                grade: "B",
                maintenanceScore: 81,
                popularityScore: 82,
                qualityScore: 83,
                securityScore: 84,
                isPartial: false
            ) },
            openSSF: { _ in throw StubError.failed },
            community: { _ in nil }
        )
        let viewModel = RepositoryInsightsViewModel(provider: provider)

        await viewModel.load(repoId: 1)

        #expect(viewModel.releaseState == .content(
            RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil)
        ))
        #expect(viewModel.healthState != .failed)
        #expect(viewModel.openSSFState == .failed)
        #expect(viewModel.communityState == .empty)
    }

    @Test("较慢的旧 repo 结果不能覆盖新 repo")
    func staleGenerationIsDiscarded() async {
        let provider = StubRepositoryLocalInsightsProvider(
            release: { repoId in
                if repoId == 1 {
                    try await Task.sleep(for: .milliseconds(120))
                }
                return RepositoryReleaseInsight(
                    tagName: repoId == 1 ? "old" : "new",
                    name: nil,
                    publishedAt: nil
                )
            },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
        let viewModel = RepositoryInsightsViewModel(provider: provider)

        let oldLoad = Task { await viewModel.load(repoId: 1) }
        try? await Task.sleep(for: .milliseconds(20))
        await viewModel.load(repoId: 2)
        await oldLoad.value

        #expect(viewModel.activeRepoID == 2)
        #expect(viewModel.releaseState == .content(
            RepositoryReleaseInsight(tagName: "new", name: nil, publishedAt: nil)
        ))
    }

    @Test("已取消的旧仓库本地阶段不得再启动远端加载")
    func cancelledLocalStageCannotInterruptCurrentRemoteState() async {
        let gate = RepositoryInsightsLocalLoadGate()
        let recorder = RepositoryInsightsRemoteCallRecorder()
        let localProvider = StubRepositoryLocalInsightsProvider(
            release: { repoID in
                if repoID == 1 {
                    // continuation 故意不响应 Task cancellation，复现真实 Provider 迟到返回。
                    await gate.block()
                }
                return nil
            },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { repoID, _ in
                await recorder.record(repoID)
                return nil
            },
            refreshHandler: { repository, _ in
                RepositoryActivityCounts(
                    createdPullRequests: Int(repository.ghRepoID ?? -1),
                    mergedPullRequests: 0,
                    createdIssues: 0,
                    closedIssues: 0,
                    generatedAt: Date()
                )
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: localProvider,
            remoteProvider: remoteProvider
        )

        let oldLoad = Task {
            await viewModel.load(repo: fixtureRepo(id: 1), isAuthenticated: true)
        }
        await gate.waitUntilBlocked()
        oldLoad.cancel()
        await viewModel.load(repo: fixtureRepo(id: 2), isAuthenticated: true)
        await gate.release()
        await oldLoad.value

        #expect(await recorder.repoIDs() == [2])
        guard case .content(let counts) = viewModel.activityState else {
            Issue.record("Expected current repository activity content")
            return
        }
        #expect(counts.createdPullRequests == 2)
        #expect(viewModel.activeRepoID == 2)
    }

    private func emptyLocalProvider() -> StubRepositoryLocalInsightsProvider {
        StubRepositoryLocalInsightsProvider(
            release: { _ in nil },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
    }

    private func fixtureRepo(id: Int64) -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "demo-\(id)")
        repo.id = id
        repo.isStarred = true
        repo.cachedAt = "2026-07-27T00:00:00Z"
        return repo
    }
}

private enum StubError: Error {
    case failed
}

/// 精确冻结旧仓库本地 Provider，且故意不合作响应 Task cancellation。
private actor RepositoryInsightsLocalLoadGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// actor 记录远端调用顺序，避免测试闭包跨任务写数组产生数据竞争。
private actor RepositoryInsightsRemoteCallRecorder {
    private var values: [Int64] = []

    func record(_ repoID: Int64) {
        values.append(repoID)
    }

    func repoIDs() -> [Int64] {
        values
    }
}

private struct StubRepositoryLocalInsightsProvider: RepositoryLocalInsightsProviding {
    let release: @Sendable (Int64) async throws -> RepositoryReleaseInsight?
    let health: @Sendable (Int64) async throws -> RepositoryHealthInsight?
    let openSSF: @Sendable (Int64) async throws -> RepositoryOpenSSFInsight?
    let community: @Sendable (Int64) async throws -> RepositoryCommunityInsight?

    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight? {
        try await release(repoId)
    }

    func health(repoId: Int64) async throws -> RepositoryHealthInsight? {
        try await health(repoId)
    }

    func openSSF(repoId: Int64) async throws -> RepositoryOpenSSFInsight? {
        try await openSSF(repoId)
    }

    func cachedCommunity(repoId: Int64) async throws -> RepositoryCommunityInsight? {
        try await community(repoId)
    }
}

private struct StubRepositoryRemoteInsightsProvider: RepositoryRemoteInsightsProviding {
    let cachedHandler: @Sendable (
        Int64,
        RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts?
    let refreshHandler: @Sendable (
        RepoIdentity,
        RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts
    var cachedCommitHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedCommitActivity? = { _ in nil }
    var refreshCommitHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositoryCommitActivity = { _ in
        throw StubError.failed
    }
    var cachedContributorsHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedContributorsInsight? = { _ in nil }
    var refreshContributorsHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositoryContributorsInsight = { _ in
        throw StubError.failed
    }
    var cachedCommunityHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedCommunityInsight? = { _ in nil }
    var refreshCommunityHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositoryCommunityInsight = { _ in
        throw StubError.failed
    }
    var cachedRecentActivityHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedRecentActivity? = { _ in nil }
    var refreshRecentActivityHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositoryRecentActivity = { _ in
        throw StubError.failed
    }

    func cachedActivity(
        repoID: Int64,
        range: RepositoryActivityRange
    ) async throws -> RepositoryCachedActivityCounts? {
        try await cachedHandler(repoID, range)
    }

    func refreshActivity(
        repository: RepoIdentity,
        range: RepositoryActivityRange
    ) async throws -> RepositoryActivityCounts {
        try await refreshHandler(repository, range)
    }

    func cachedCommitActivity(repoID: Int64) async throws -> RepositoryCachedCommitActivity? {
        try await cachedCommitHandler(repoID)
    }

    func refreshCommitActivity(repository: RepoIdentity) async throws -> RepositoryCommitActivity {
        try await refreshCommitHandler(repository)
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        try await cachedContributorsHandler(repoID)
    }

    func refreshContributors(repository: RepoIdentity) async throws -> RepositoryContributorsInsight {
        try await refreshContributorsHandler(repository)
    }

    func cachedCommunityProfile(repoID: Int64) async throws -> RepositoryCachedCommunityInsight? {
        try await cachedCommunityHandler(repoID)
    }

    func refreshCommunityProfile(repository: RepoIdentity) async throws -> RepositoryCommunityInsight {
        try await refreshCommunityHandler(repository)
    }

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity? {
        try await cachedRecentActivityHandler(repoID)
    }

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity {
        try await refreshRecentActivityHandler(repository)
    }
}
