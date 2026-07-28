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

    @Test("发布节奏按本地 Release 时间计算近一年数量与平均间隔")
    func releaseCadenceDerivesFromLocalReleaseHistory() {
        let now = ISO8601DateFormatter.shared.date(from: "2026-07-28T00:00:00Z")!
        let releases = [
            RepositoryReleaseInsight(
                tagName: "v3",
                name: nil,
                publishedAt: now.addingTimeInterval(-10 * 86_400),
                htmlURL: nil
            ),
            RepositoryReleaseInsight(
                tagName: "v2",
                name: nil,
                publishedAt: now.addingTimeInterval(-40 * 86_400),
                htmlURL: nil
            ),
            RepositoryReleaseInsight(
                tagName: "v1",
                name: nil,
                publishedAt: now.addingTimeInterval(-400 * 86_400),
                htmlURL: nil
            )
        ]
        let cadence = RepositoryReleaseCadenceInsight.make(releases: releases, now: now)

        #expect(cadence?.releasesLastYear == 2)
        #expect(cadence?.averageIntervalDays == 195)
        #expect(cadence?.latestPublishedAt == releases[0].publishedAt)
        #expect(RepositoryReleaseCadenceInsight.make(releases: [], now: now) == nil)
    }

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

    @Test("手动刷新期间所有远端区块保持现有内容")
    func manualRefreshKeepsVisibleContentUntilFreshValuesArrive() async {
        let generatedAt = Date(timeIntervalSince1970: 2_000)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 4,
            mergedPullRequests: 3,
            createdIssues: 2,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let refreshedActivity = RepositoryActivityCounts(
            createdPullRequests: 5,
            mergedPullRequests: 4,
            createdIssues: 3,
            closedIssues: 2,
            generatedAt: generatedAt.addingTimeInterval(60)
        )
        let commitActivity = RepositoryCommitActivity(
            points: [RepositoryCommitActivityPoint(weekStart: generatedAt, commits: 6)],
            generatedAt: generatedAt
        )
        let refreshedCommitActivity = RepositoryCommitActivity(
            points: [RepositoryCommitActivityPoint(weekStart: generatedAt, commits: 7)],
            generatedAt: generatedAt.addingTimeInterval(60)
        )
        let contributors = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(
                    id: "octo",
                    login: "octo",
                    commits: 8,
                    colorName: "blue"
                )
            ],
            generatedAt: generatedAt
        )
        let refreshedContributors = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(
                    id: "octo",
                    login: "octo",
                    commits: 9,
                    colorName: "blue"
                )
            ],
            generatedAt: generatedAt.addingTimeInterval(60)
        )
        let community = RepositoryCommunityInsight(
            healthPercentage: 80,
            hasReadme: true,
            hasCodeOfConduct: false,
            hasContributing: true,
            hasLicense: true
        )
        let refreshedCommunity = RepositoryCommunityInsight(
            healthPercentage: 90,
            hasReadme: true,
            hasCodeOfConduct: true,
            hasContributing: true,
            hasLicense: true
        )
        let recentActivity = RepositoryRecentActivity(
            events: [
                RepositoryRecentActivityEvent(
                    id: "issue-1",
                    kind: .issue,
                    number: 1,
                    title: "Old",
                    occurredAt: generatedAt,
                    htmlURL: nil
                )
            ],
            generatedAt: generatedAt
        )
        let refreshedRecentActivity = RepositoryRecentActivity(
            events: [
                RepositoryRecentActivityEvent(
                    id: "issue-2",
                    kind: .issue,
                    number: 2,
                    title: "New",
                    occurredAt: generatedAt.addingTimeInterval(60),
                    htmlURL: nil
                )
            ],
            generatedAt: generatedAt.addingTimeInterval(60)
        )
        let refreshGate = RepositoryInsightsRefreshGate(expectedCount: 5)
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await refreshGate.block()
                return refreshedActivity
            },
            cachedCommitHandler: { _ in
                RepositoryCachedCommitActivity(
                    value: commitActivity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshCommitHandler: { _ in
                await refreshGate.block()
                return refreshedCommitActivity
            },
            cachedContributorsHandler: { _ in
                RepositoryCachedContributorsInsight(
                    value: contributors,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshContributorsHandler: { _ in
                await refreshGate.block()
                return refreshedContributors
            },
            cachedCommunityHandler: { _ in
                RepositoryCachedCommunityInsight(
                    value: community,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshCommunityHandler: { _ in
                await refreshGate.block()
                return refreshedCommunity
            },
            cachedRecentActivityHandler: { _ in
                RepositoryCachedRecentActivity(
                    value: recentActivity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshRecentActivityHandler: { _ in
                await refreshGate.block()
                return refreshedRecentActivity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )
        let repo = fixtureRepo(id: 14)
        await viewModel.load(repo: repo, isAuthenticated: true)

        let refreshTasks = [
            Task { await viewModel.refreshActivity(repo: repo, isAuthenticated: true) },
            Task { await viewModel.refreshCommitActivity(repo: repo, isAuthenticated: true) },
            Task { await viewModel.refreshContributors(repo: repo, isAuthenticated: true) },
            Task { await viewModel.refreshCommunityProfile(repo: repo, isAuthenticated: true) },
            Task { await viewModel.refreshRecentActivity(repo: repo, isAuthenticated: true) }
        ]
        await refreshGate.waitUntilAllBlocked()

        #expect(viewModel.isRefreshingActivity)
        #expect(viewModel.isRefreshingCommitActivity)
        #expect(viewModel.isRefreshingContributors)
        #expect(viewModel.isRefreshingCommunity)
        #expect(viewModel.isRefreshingRecentActivity)
        #expect(viewModel.activityState == .content(activity))
        #expect(viewModel.commitActivityState == .content(commitActivity))
        #expect(viewModel.contributorsState == .content(contributors))
        #expect(viewModel.remoteCommunityState == .content(community))
        #expect(viewModel.recentActivityState == .content(recentActivity))

        await refreshGate.release()
        for task in refreshTasks {
            await task.value
        }

        #expect(viewModel.activityState == .content(refreshedActivity))
        #expect(viewModel.commitActivityState == .content(refreshedCommitActivity))
        #expect(viewModel.contributorsState == .content(refreshedContributors))
        #expect(viewModel.remoteCommunityState == .content(refreshedCommunity))
        #expect(viewModel.recentActivityState == .content(refreshedRecentActivity))
    }

    @Test("全局刷新并行更新各远端区块且刷新期间保留现有内容")
    func refreshAllUpdatesRemoteSectionsInParallel() async {
        let generatedAt = Date(timeIntervalSince1970: 2_100)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 1,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let refreshedActivity = RepositoryActivityCounts(
            createdPullRequests: 2,
            mergedPullRequests: 2,
            createdIssues: 2,
            closedIssues: 2,
            generatedAt: generatedAt.addingTimeInterval(30)
        )
        let commitActivity = RepositoryCommitActivity(
            points: [RepositoryCommitActivityPoint(weekStart: generatedAt, commits: 3)],
            generatedAt: generatedAt
        )
        let refreshedCommitActivity = RepositoryCommitActivity(
            points: [RepositoryCommitActivityPoint(weekStart: generatedAt, commits: 4)],
            generatedAt: generatedAt.addingTimeInterval(30)
        )
        let contributors = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(id: "a", login: "a", commits: 1, colorName: "blue")
            ],
            generatedAt: generatedAt
        )
        let refreshedContributors = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(id: "a", login: "a", commits: 2, colorName: "blue")
            ],
            generatedAt: generatedAt.addingTimeInterval(30)
        )
        let community = RepositoryCommunityInsight(
            healthPercentage: 50,
            hasReadme: true,
            hasCodeOfConduct: false,
            hasContributing: false,
            hasLicense: true
        )
        let refreshedCommunity = RepositoryCommunityInsight(
            healthPercentage: 70,
            hasReadme: true,
            hasCodeOfConduct: true,
            hasContributing: true,
            hasLicense: true
        )
        let recentActivity = RepositoryRecentActivity(
            events: [
                RepositoryRecentActivityEvent(
                    id: "issue-old",
                    kind: .issue,
                    number: 1,
                    title: "Old",
                    occurredAt: generatedAt,
                    htmlURL: nil
                )
            ],
            generatedAt: generatedAt
        )
        let refreshedRecentActivity = RepositoryRecentActivity(
            events: [
                RepositoryRecentActivityEvent(
                    id: "issue-new",
                    kind: .issue,
                    number: 2,
                    title: "New",
                    occurredAt: generatedAt.addingTimeInterval(30),
                    htmlURL: nil
                )
            ],
            generatedAt: generatedAt.addingTimeInterval(30)
        )
        let refreshGate = RepositoryInsightsRefreshGate(expectedCount: 5)
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await refreshGate.block()
                return refreshedActivity
            },
            cachedCommitHandler: { _ in
                RepositoryCachedCommitActivity(
                    value: commitActivity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshCommitHandler: { _ in
                await refreshGate.block()
                return refreshedCommitActivity
            },
            cachedContributorsHandler: { _ in
                RepositoryCachedContributorsInsight(
                    value: contributors,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshContributorsHandler: { _ in
                await refreshGate.block()
                return refreshedContributors
            },
            cachedCommunityHandler: { _ in
                RepositoryCachedCommunityInsight(
                    value: community,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshCommunityHandler: { _ in
                await refreshGate.block()
                return refreshedCommunity
            },
            cachedRecentActivityHandler: { _ in
                RepositoryCachedRecentActivity(
                    value: recentActivity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshRecentActivityHandler: { _ in
                await refreshGate.block()
                return refreshedRecentActivity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )
        let repo = fixtureRepo(id: 42)

        await viewModel.load(repo: repo, isAuthenticated: true)
        #expect(viewModel.activityState == .content(activity))

        let refreshTask = Task {
            await viewModel.refreshAll(repo: repo, isAuthenticated: true)
        }
        await refreshGate.waitUntilAllBlocked()

        #expect(viewModel.isRefreshingAll)
        #expect(viewModel.activityState == .content(activity))
        #expect(viewModel.commitActivityState == .content(commitActivity))
        #expect(viewModel.contributorsState == .content(contributors))
        #expect(viewModel.remoteCommunityState == .content(community))
        #expect(viewModel.recentActivityState == .content(recentActivity))

        await refreshGate.release()
        await refreshTask.value

        #expect(!viewModel.isRefreshingAll)
        #expect(viewModel.activityState == .content(refreshedActivity))
        #expect(viewModel.commitActivityState == .content(refreshedCommitActivity))
        #expect(viewModel.contributorsState == .content(refreshedContributors))
        #expect(viewModel.remoteCommunityState == .content(refreshedCommunity))
        #expect(viewModel.recentActivityState == .content(refreshedRecentActivity))
    }

    @Test("提交活动范围与活动概览范围彼此独立")
    func commitActivityRangeIsIndependentFromActivityRange() async {
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: nil
        )
        #expect(viewModel.activityRange == .month)
        #expect(viewModel.commitActivityRange == .month)

        viewModel.selectCommitActivityRange(.year)
        #expect(viewModel.commitActivityRange == .year)
        #expect(viewModel.activityRange == .month)

        await viewModel.selectActivityRange(
            .week,
            repo: fixtureRepo(id: 99),
            isAuthenticated: false
        )
        #expect(viewModel.activityRange == .week)
        #expect(viewModel.commitActivityRange == .year)
    }

    @Test("切换活动范围期间保留现有内容")
    func activityRangeChangeKeepsVisibleContentUntilTargetRangeArrives() async {
        let generatedAt = Date(timeIntervalSince1970: 3_000)
        let currentActivity = RepositoryActivityCounts(
            createdPullRequests: 4,
            mergedPullRequests: 3,
            createdIssues: 2,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let targetActivity = RepositoryActivityCounts(
            createdPullRequests: 12,
            mergedPullRequests: 10,
            createdIssues: 8,
            closedIssues: 6,
            generatedAt: generatedAt.addingTimeInterval(60)
        )
        let refreshGate = RepositoryInsightsRefreshGate(expectedCount: 1)
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, range in
                guard range == .month else { return nil }
                return RepositoryCachedActivityCounts(
                    value: currentActivity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await refreshGate.block()
                return targetActivity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )
        let repo = fixtureRepo(id: 15)
        await viewModel.load(repo: repo, isAuthenticated: true)

        let rangeTask = Task {
            await viewModel.selectActivityRange(.year, repo: repo, isAuthenticated: true)
        }
        await refreshGate.waitUntilAllBlocked()

        #expect(viewModel.activityRange == .year)
        #expect(viewModel.isRefreshingActivity)
        #expect(viewModel.activityState == .content(currentActivity))

        await refreshGate.release()
        await rangeTask.value

        #expect(viewModel.activityState == .content(targetActivity))
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
            release: { _ in RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil, htmlURL: nil) },
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
            RepositoryReleaseInsight(tagName: "v1.0", name: nil, publishedAt: nil, htmlURL: nil)
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
                    publishedAt: nil,
                    htmlURL: nil
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
            RepositoryReleaseInsight(tagName: "new", name: nil, publishedAt: nil, htmlURL: nil)
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

/// 同时冻结五个手动刷新请求，确保断言读取的是网络返回前的稳定 UI 状态。
private actor RepositoryInsightsRefreshGate {
    private let expectedCount: Int
    private var blockedCount = 0
    private var isReleased = false
    private var allBlockedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func block() async {
        blockedCount += 1
        if blockedCount == expectedCount {
            allBlockedWaiter?.resume()
            allBlockedWaiter = nil
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilAllBlocked() async {
        guard blockedCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            allBlockedWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct StubRepositoryLocalInsightsProvider: RepositoryLocalInsightsProviding {
    let release: @Sendable (Int64) async throws -> RepositoryReleaseInsight?
    var cadence: @Sendable (Int64) async throws -> RepositoryReleaseCadenceInsight? = { _ in nil }
    let health: @Sendable (Int64) async throws -> RepositoryHealthInsight?
    let openSSF: @Sendable (Int64) async throws -> RepositoryOpenSSFInsight?
    let community: @Sendable (Int64) async throws -> RepositoryCommunityInsight?

    func latestRelease(repoId: Int64) async throws -> RepositoryReleaseInsight? {
        try await release(repoId)
    }

    func releaseCadence(repoId: Int64) async throws -> RepositoryReleaseCadenceInsight? {
        try await cadence(repoId)
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
