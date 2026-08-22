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
        // 固定 Unix 时间，让节奏边界测试不依赖字符串解析实现。
        let now = Date(timeIntervalSince1970: 1_785_196_800)
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

    @Test("页面加载与单面板刷新完成后更新共享洞察 XML")
    func loadAndManualRefreshNotifyContextCoordinator() async {
        let counter = RepositoryInsightsCallCounter()
        let provider = StubRepositoryLocalInsightsProvider(
            release: { _ in nil },
            cadence: { _ in nil },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: provider,
            contextRefreshHandler: { _ in
                await counter.increment()
            }
        )
        var repo = Repo.makeMinimal(owner: "octo", name: "artifact")
        repo.id = 9_001

        await viewModel.load(repo: repo, isAuthenticated: false)
        await viewModel.refreshActivity(repo: repo, isAuthenticated: false)

        #expect(await counter.value() == 2)
    }

    @Test("发布节奏优先使用本地历史且不请求远端")
    func releaseCadencePrefersLocalHistory() async {
        let cadence = RepositoryReleaseCadenceInsight(
            releasesLastYear: 3,
            averageIntervalDays: 14,
            latestPublishedAt: Date(timeIntervalSince1970: 3_000)
        )
        let counter = RepositoryInsightsCallCounter()
        let localProvider = StubRepositoryLocalInsightsProvider(
            release: { _ in nil },
            cadence: { _ in cadence },
            health: { _ in nil },
            openSSF: { _ in nil },
            community: { _ in nil }
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            cachedReleaseCadenceHandler: { _ in
                await counter.increment()
                return nil
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: localProvider,
            remoteProvider: remoteProvider
        )

        await viewModel.load(repo: fixtureRepo(id: 2), isAuthenticated: true)

        #expect(viewModel.releaseCadenceState == .content(cadence))
        #expect(await counter.value() == 0)
    }

    @Test("本地发布节奏缺失时优先展示新鲜远端缓存")
    func releaseCadenceUsesFreshRemoteCache() async {
        let cadence = RepositoryReleaseCadenceInsight(
            releasesLastYear: 5,
            averageIntervalDays: 21,
            latestPublishedAt: Date(timeIntervalSince1970: 4_000)
        )
        let refreshCounter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            cachedReleaseCadenceHandler: { _ in
                RepositoryCachedReleaseCadenceInsight(
                    value: cadence,
                    fetchedAt: Date(timeIntervalSince1970: 4_100),
                    isStale: false,
                    responseETag: "\"cadence\""
                )
            },
            refreshReleaseCadenceHandler: { _ in
                await refreshCounter.increment()
                return .cadenceOnly(nil)
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )

        await viewModel.load(repo: fixtureRepo(id: 3), isAuthenticated: true)

        #expect(viewModel.releaseCadenceState == .content(cadence))
        #expect(await refreshCounter.value() == 0)
    }

    @Test("发布节奏区分无 Release 未登录与加载失败")
    func releaseCadenceDistinguishesEmptyUnavailableAndFailed() async {
        let emptyRemoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            refreshReleaseCadenceHandler: { _ in .cadenceOnly(nil) }
        )
        let emptyViewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: emptyRemoteProvider
        )
        await emptyViewModel.load(repo: fixtureRepo(id: 4), isAuthenticated: true)
        #expect(emptyViewModel.releaseCadenceState == .empty)

        let unavailableViewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: emptyRemoteProvider
        )
        await unavailableViewModel.load(repo: fixtureRepo(id: 5), isAuthenticated: false)
        #expect(unavailableViewModel.releaseCadenceState == .unavailable)

        let failedRemoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            refreshReleaseCadenceHandler: { _ in throw StubError.failed }
        )
        let failedViewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: failedRemoteProvider
        )
        await failedViewModel.load(repo: fixtureRepo(id: 6), isAuthenticated: true)
        #expect(failedViewModel.releaseCadenceState == .failed)
    }

    @Test("安全公告派生高风险数量与最近发布日期")
    func securityAdvisoriesDeriveRiskSummary() {
        let older = Date(timeIntervalSince1970: 1_000)
        let latest = Date(timeIntervalSince1970: 2_000)
        let insight = RepositorySecurityAdvisoriesInsight(
            advisories: [
                RepositorySecurityAdvisory(
                    id: "GHSA-low",
                    cveID: nil,
                    summary: "Low",
                    severity: "low",
                    htmlURL: nil,
                    publishedAt: older
                ),
                RepositorySecurityAdvisory(
                    id: "GHSA-critical",
                    cveID: "CVE-2026-1",
                    summary: "Critical",
                    severity: "critical",
                    htmlURL: URL(string: "https://github.com/advisories/GHSA-critical"),
                    publishedAt: latest
                )
            ],
            generatedAt: latest
        )

        #expect(insight.highOrCriticalCount == 1)
        #expect(insight.latestPublishedAt == latest)
    }

    @Test("旧安全公告缓存缺少发布者字段时仍可解码")
    func securityAdvisoryCacheWithoutPublisherDecodes() throws {
        let payload = Data(
            #"{"id":"GHSA-old-cache","cveID":null,"summary":"Cached","severity":"medium","htmlURL":null,"publishedAt":1000}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RepositorySecurityAdvisory.self, from: payload)

        #expect(decoded.id == "GHSA-old-cache")
        #expect(decoded.publisherLogin == nil)
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

    @Test("安全公告刷新失败保留 stale 缓存而不是伪造成零条")
    func staleSecurityAdvisoriesSurviveRefreshFailure() async {
        let generatedAt = Date(timeIntervalSince1970: 2_000)
        let cached = RepositorySecurityAdvisoriesInsight(
            advisories: [
                RepositorySecurityAdvisory(
                    id: "GHSA-cached",
                    cveID: nil,
                    summary: "Cached advisory",
                    severity: "high",
                    htmlURL: nil,
                    publishedAt: generatedAt
                )
            ],
            generatedAt: generatedAt
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            cachedSecurityAdvisoriesHandler: { _ in
                RepositoryCachedSecurityAdvisoriesInsight(
                    value: cached,
                    fetchedAt: generatedAt,
                    isStale: true
                )
            },
            refreshSecurityAdvisoriesHandler: { _ in throw StubError.failed }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )

        await viewModel.load(repo: fixtureRepo(id: 26), isAuthenticated: true)

        #expect(viewModel.securityAdvisoriesState == .failed(cached: cached))
        #expect(viewModel.securityAdvisoriesState.visibleValue == cached)
    }

    @Test("非我的项目私仓首次加载和手动刷新都不会进入远端洞察")
    func privateRepositoryOutsideMyProjectsNeverLoadsRemoteInsights() async {
        let counter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                await counter.increment()
                return nil
            },
            refreshHandler: { _, _ in
                await counter.increment()
                throw StubError.failed
            },
            cachedCommitHandler: { _ in
                await counter.increment()
                return nil
            },
            refreshCommitHandler: { _ in
                await counter.increment()
                throw StubError.failed
            },
            cachedContributorsHandler: { _ in
                await counter.increment()
                return nil
            },
            refreshContributorsHandler: { _ in
                await counter.increment()
                throw StubError.failed
            },
            cachedCommunityHandler: { _ in
                await counter.increment()
                return nil
            },
            refreshCommunityHandler: { _ in
                await counter.increment()
                throw StubError.failed
            },
            cachedSecurityAdvisoriesHandler: { _ in
                await counter.increment()
                return nil
            },
            refreshSecurityAdvisoriesHandler: { _ in
                await counter.increment()
                throw StubError.failed
            },
            cachedRecentActivityHandler: { _ in
                await counter.increment()
                return nil
            },
            refreshRecentActivityHandler: { _ in
                await counter.increment()
                throw StubError.failed
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider
        )
        var privateRepo = fixtureRepo(id: 27)
        privateRepo.isPrivate = true

        await viewModel.load(repo: privateRepo, isAuthenticated: true)
        await viewModel.refreshAll(repo: privateRepo, isAuthenticated: true)

        #expect(await counter.value() == 0)
        #expect(viewModel.activityState == .unavailable(cached: nil))
        #expect(viewModel.commitActivityState == .unavailable(cached: nil))
        #expect(viewModel.contributorsState == .unavailable(cached: nil))
        #expect(viewModel.remoteCommunityState == .unavailable(cached: nil))
        #expect(viewModel.securityAdvisoriesState == .unavailable(cached: nil))
        #expect(viewModel.recentActivityState == .unavailable(cached: nil))
        #expect(viewModel.openSSFState == .unavailable)
    }

    @Test("我的项目私仓在门禁放行后会拉取远端洞察且 OpenSSF 固定不可用")
    func myProjectPrivateRepositoryLoadsRemoteInsights() async {
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 0,
            closedIssues: 0,
            generatedAt: Date(timeIntervalSince1970: 5_000)
        )
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in activity },
            cachedCommitHandler: { _ in nil },
            refreshCommitHandler: { _ in
                RepositoryCommitActivity(points: [], generatedAt: Date(timeIntervalSince1970: 5_000))
            },
            cachedContributorsHandler: { _ in nil },
            refreshContributorsHandler: { _ in
                RepositoryContributorsInsight(contributors: [], generatedAt: Date(timeIntervalSince1970: 5_000))
            },
            cachedCommunityHandler: { _ in nil },
            refreshCommunityHandler: { _ in
                RepositoryCommunityInsight(
                    healthPercentage: 80,
                    hasReadme: true,
                    hasCodeOfConduct: false,
                    hasContributing: false,
                    hasIssueTemplate: false,
                    hasLicense: true,
                    hasPullRequestTemplate: false,
                    readmeHTMLURL: nil,
                    codeOfConductHTMLURL: nil,
                    contributingHTMLURL: nil,
                    issueTemplateHTMLURL: nil,
                    licenseHTMLURL: nil,
                    pullRequestTemplateHTMLURL: nil
                )
            },
            refreshReleaseCadenceHandler: { _ in
                RepositoryReleaseRemoteSnapshot(
                    cadence: RepositoryReleaseCadenceInsight(
                        releasesLastYear: 1,
                        averageIntervalDays: nil,
                        latestPublishedAt: Date(timeIntervalSince1970: 4_900)
                    ),
                    latest: RepositoryReleaseInsight(
                        tagName: "v1.0.0",
                        name: "First",
                        publishedAt: Date(timeIntervalSince1970: 4_900),
                        htmlURL: nil
                    )
                )
            },
            cachedSecurityAdvisoriesHandler: { _ in nil },
            refreshSecurityAdvisoriesHandler: { _ in
                RepositorySecurityAdvisoriesInsight(advisories: [], generatedAt: Date(timeIntervalSince1970: 5_000))
            },
            cachedRecentActivityHandler: { _ in nil },
            refreshRecentActivityHandler: { _ in
                RepositoryRecentActivity(events: [], generatedAt: Date(timeIntervalSince1970: 5_000))
            }
        )
        let expectedRelease = RepositoryReleaseInsight(
            tagName: "v1.0.0",
            name: "First",
            publishedAt: Date(timeIntervalSince1970: 4_900),
            htmlURL: nil
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            remoteAccessProvider: StubRepositoryRemoteInsightsAccessProvider { repo, isAuthenticated in
                isAuthenticated && repo.isPrivate
            }
        )
        var privateRepo = fixtureRepo(id: 28)
        privateRepo.isPrivate = true

        await viewModel.load(repo: privateRepo, isAuthenticated: true)

        #expect(viewModel.activityState == RepositoryRemoteInsightsSectionState.content(activity))
        #expect(viewModel.releaseState == RepositoryInsightsSectionState.content(expectedRelease))
        #expect(viewModel.openSSFState == .unavailable)
    }

    @Test("五个独立刷新入口在刷新期间保持现有内容")
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

    @Test("同一入口十秒内连续手动刷新只调用一次远端 Provider")
    func repeatedManualRefreshUsesCooldown() async {
        let generatedAt = Date(timeIntervalSince1970: 2_050)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 1,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let counter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await counter.increment()
                return activity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            now: { generatedAt }
        )
        let repo = fixtureRepo(id: 15)
        await viewModel.load(repo: repo, isAuthenticated: true)

        await viewModel.refreshActivity(repo: repo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: repo, isAuthenticated: true)

        #expect(await counter.value() == 1)
        #expect(viewModel.activityState == .content(activity))
    }

    @Test("冷却未到时仍短暂拉高刷新旗标，驱动 Sync 确认转圈且不二次拉网")
    func cooldownRejectedRefreshStillPulsesRefreshingFlag() async {
        let generatedAt = Date(timeIntervalSince1970: 2_055)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 1,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let counter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await counter.increment()
                return activity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            now: { generatedAt }
        )
        let repo = fixtureRepo(id: 16)
        await viewModel.load(repo: repo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: repo, isAuthenticated: true)
        #expect(!viewModel.isRefreshingActivity)

        async let blockedRefresh: Void = viewModel.refreshActivity(
            repo: repo,
            isAuthenticated: true
        )
        try? await Task.sleep(for: .milliseconds(10))
        #expect(viewModel.isRefreshingActivity)
        await blockedRefresh

        #expect(!viewModel.isRefreshingActivity)
        #expect(await counter.value() == 1)
    }

    @Test("手动刷新冷却按仓库隔离")
    func manualRefreshCooldownIsScopedByRepository() async {
        let generatedAt = Date(timeIntervalSince1970: 2_060)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 1,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let counter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await counter.increment()
                return activity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            now: { generatedAt }
        )
        let firstRepo = fixtureRepo(id: 16)
        let secondRepo = fixtureRepo(id: 17)

        await viewModel.load(repo: firstRepo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: firstRepo, isAuthenticated: true)
        await viewModel.load(repo: secondRepo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: secondRepo, isAuthenticated: true)

        #expect(await counter.value() == 2)
    }

    @Test("数据库作用域变化会清空手动刷新冷却")
    func databaseScopeResetClearsManualRefreshCooldown() async {
        let generatedAt = Date(timeIntervalSince1970: 2_070)
        let activity = RepositoryActivityCounts(
            createdPullRequests: 1,
            mergedPullRequests: 1,
            createdIssues: 1,
            closedIssues: 1,
            generatedAt: generatedAt
        )
        let counter = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in
                RepositoryCachedActivityCounts(
                    value: activity,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshHandler: { _, _ in
                await counter.increment()
                return activity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            now: { generatedAt }
        )
        let repo = fixtureRepo(id: 18)

        await viewModel.load(repo: repo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: repo, isAuthenticated: true)
        viewModel.resetTransientStateForDatabaseScopeChange()
        await viewModel.load(repo: repo, isAuthenticated: true)
        await viewModel.refreshActivity(repo: repo, isAuthenticated: true)

        #expect(await counter.value() == 2)
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
        let securityAdvisories = RepositorySecurityAdvisoriesInsight(
            advisories: [
                RepositorySecurityAdvisory(
                    id: "GHSA-old",
                    cveID: nil,
                    summary: "Old advisory",
                    severity: "low",
                    htmlURL: nil,
                    publishedAt: generatedAt
                )
            ],
            generatedAt: generatedAt
        )
        let refreshedSecurityAdvisories = RepositorySecurityAdvisoriesInsight(
            advisories: [
                RepositorySecurityAdvisory(
                    id: "GHSA-new",
                    cveID: "CVE-2026-2",
                    summary: "New advisory",
                    severity: "high",
                    htmlURL: nil,
                    publishedAt: generatedAt.addingTimeInterval(30)
                )
            ],
            generatedAt: generatedAt.addingTimeInterval(30)
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
        let releaseCadence = RepositoryReleaseCadenceInsight(
            releasesLastYear: 2,
            averageIntervalDays: 30,
            latestPublishedAt: generatedAt
        )
        let refreshedReleaseCadence = RepositoryReleaseCadenceInsight(
            releasesLastYear: 3,
            averageIntervalDays: 20,
            latestPublishedAt: generatedAt.addingTimeInterval(30)
        )
        let refreshGate = RepositoryInsightsRefreshGate(expectedCount: 7)
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
            cachedReleaseCadenceHandler: { _ in
                RepositoryCachedReleaseCadenceInsight(
                    value: releaseCadence,
                    fetchedAt: generatedAt,
                    isStale: false,
                    responseETag: "\"release-cadence\""
                )
            },
            refreshReleaseCadenceHandler: { _ in
                await refreshGate.block()
                return RepositoryReleaseRemoteSnapshot(
                    cadence: refreshedReleaseCadence,
                    latest: nil
                )
            },
            cachedSecurityAdvisoriesHandler: { _ in
                RepositoryCachedSecurityAdvisoriesInsight(
                    value: securityAdvisories,
                    fetchedAt: generatedAt,
                    isStale: false
                )
            },
            refreshSecurityAdvisoriesHandler: { _ in
                await refreshGate.block()
                return refreshedSecurityAdvisories
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
        #expect(viewModel.releaseCadenceState == .content(releaseCadence))
        #expect(viewModel.securityAdvisoriesState == .content(securityAdvisories))
        #expect(viewModel.recentActivityState == .content(recentActivity))

        await refreshGate.release()
        _ = await refreshTask.value

        #expect(viewModel.isRefreshingAll)
        viewModel.finishGlobalRefresh()
        #expect(!viewModel.isRefreshingAll)
        #expect(viewModel.activityState == .content(refreshedActivity))
        #expect(viewModel.commitActivityState == .content(refreshedCommitActivity))
        #expect(viewModel.contributorsState == .content(refreshedContributors))
        #expect(viewModel.remoteCommunityState == .content(refreshedCommunity))
        #expect(viewModel.releaseCadenceState == .content(refreshedReleaseCadence))
        #expect(viewModel.securityAdvisoriesState == .content(refreshedSecurityAdvisories))
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

    @Test("Commit Activity 首次 202 后自动轮询直到成功")
    func commitActivityPollsGeneratingUntilSuccess() async {
        let generatedAt = Date(timeIntervalSince1970: 9_100)
        let commitActivity = RepositoryCommitActivity(
            points: [RepositoryCommitActivityPoint(weekStart: generatedAt, commits: 4)],
            generatedAt: generatedAt
        )
        let attempts = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            refreshCommitHandler: { _ in
                await attempts.increment()
                if await attempts.value() < 3 {
                    throw GitHubRepositoryMetricsError.generating(retryAfter: 30)
                }
                return commitActivity
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            sleep: { _ in }
        )

        await viewModel.load(repo: fixtureRepo(id: 910), isAuthenticated: true)

        #expect(await attempts.value() == 3)
        #expect(viewModel.commitActivityState == .content(commitActivity))
        #expect(!viewModel.isRefreshingCommitActivity)
    }

    @Test("Commit Activity generating 最多自动轮询三次")
    func commitActivityGeneratingPollingIsBounded() async {
        let attempts = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            refreshCommitHandler: { _ in
                await attempts.increment()
                throw GitHubRepositoryMetricsError.generating(retryAfter: 30)
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            sleep: { _ in }
        )

        await viewModel.load(repo: fixtureRepo(id: 911), isAuthenticated: true)

        #expect(await attempts.value() == 4)
        #expect(viewModel.commitActivityState == .generating(cached: nil))
        #expect(!viewModel.isRefreshingCommitActivity)
    }

    @Test("Contributors 首次 202 后自动轮询且不得误报 failed")
    func contributorsPollsGeneratingUntilSuccess() async {
        let generatedAt = Date(timeIntervalSince1970: 9_200)
        let contributors = RepositoryContributorsInsight(
            contributors: [
                RepositoryContributor(
                    id: "octo",
                    login: "octo",
                    commits: 3,
                    colorName: "blue"
                )
            ],
            generatedAt: generatedAt
        )
        let attempts = RepositoryInsightsCallCounter()
        let remoteProvider = StubRepositoryRemoteInsightsProvider(
            cachedHandler: { _, _ in nil },
            refreshHandler: { _, _ in throw StubError.failed },
            refreshContributorsHandler: { _ in
                await attempts.increment()
                if await attempts.value() == 1 {
                    throw GitHubRepositoryMetricsError.generating(retryAfter: nil)
                }
                return contributors
            }
        )
        let viewModel = RepositoryInsightsViewModel(
            provider: emptyLocalProvider(),
            remoteProvider: remoteProvider,
            sleep: { _ in }
        )

        await viewModel.load(repo: fixtureRepo(id: 912), isAuthenticated: true)

        #expect(await attempts.value() == 2)
        #expect(viewModel.contributorsState == .content(contributors))
        #expect(!viewModel.isRefreshingContributors)
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
                ),
                ReleaseRecord(
                    id: 69,
                    repoId: 7,
                    tagName: "v2.0.0",
                    name: "Previous",
                    bodyMarkdown: nil,
                    htmlUrl: "https://github.com/octo/demo-7/releases/tag/v2.0.0",
                    isPrerelease: false,
                    isDraft: false,
                    publishedAt: "2026-06-20T00:00:00Z",
                    createdAtRemote: "2026-06-20T00:00:00Z",
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
            insightsCache: cache,
            database: database,
            now: {
                // 固定 Unix 时间，让数据源映射测试只验证业务结果。
                Date(timeIntervalSince1970: 1_785_196_800)
            }
        )

        let snapshot = await provider.snapshot(repoId: 7)
        let release: RepositoryReleaseInsight
        let cadence: RepositoryReleaseCadenceInsight
        let health: RepositoryHealthInsight
        let openSSF: RepositoryOpenSSFInsight
        let cachedCommunity: RepositoryCommunityInsight
        if case .value(let value?) = snapshot.release {
            release = value
        } else {
            Issue.record("缺少 Release 快照")
            return
        }
        if case .value(let value?) = snapshot.releaseCadence {
            cadence = value
        } else {
            Issue.record("缺少发布节奏快照")
            return
        }
        if case .value(let value?) = snapshot.health {
            health = value
        } else {
            Issue.record("缺少健康度快照")
            return
        }
        if case .value(let value?) = snapshot.openSSF {
            openSSF = value
        } else {
            Issue.record("缺少 OpenSSF 快照")
            return
        }
        if case .value(let value?) = snapshot.community {
            cachedCommunity = value
        } else {
            Issue.record("缺少 Community 快照")
            return
        }

        #expect(release.tagName == "v2.1.0")
        #expect(release.name == "Stable")
        #expect(cadence.releasesLastYear == 2)
        #expect(cadence.averageIntervalDays == 30)
        #expect(cadence.latestPublishedAt == Date(timeIntervalSince1970: 1_784_505_600))
        #expect(health.overallScore == 88)
        #expect(health.maintenanceScore == 90)
        #expect(openSSF == RepositoryOpenSSFInsight(score: 8.7, scoreDate: "2026-07-27"))
        #expect(cachedCommunity == community)
    }

    @Test("单事务本地快照中 Community 损坏不影响其它区块")
    func localSnapshotIsolatesCorruptCommunityPayload() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 8, owner: "octo", name: "isolated")
        let releaseRepository = GRDBReleaseRepository(database: database)
        try await releaseRepository.upsertMany(
            [
                ReleaseRecord(
                    id: 801,
                    repoId: 8,
                    tagName: "v1.0.0",
                    name: "Stable",
                    bodyMarkdown: nil,
                    htmlUrl: "https://github.com/octo/isolated/releases/tag/v1.0.0",
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
        try await database.writer.write { db in
            try RepositoryInsightsSnapshotRecord(
                repoId: 8,
                dataset: RepositoryInsightsDataset.communityProfile.rawValue,
                rangeKey: RepositoryInsightsRangeKey.all.rawValue,
                payloadJSON: Data("not-json".utf8),
                defaultBranchSHA: nil,
                fetchedAt: "2026-07-27T00:00:00Z",
                staleAfter: "2026-07-28T00:00:00Z",
                responseETag: nil
            ).insert(db)
        }
        let provider = DefaultRepositoryLocalInsightsProvider(
            releaseRepository: releaseRepository,
            healthRepository: GRDBRepoHealthRepository(database: database),
            openSSFRepository: GRDBOpenSSFScoreRepository(database: database),
            insightsCache: GRDBRepositoryInsightsCache(database: database),
            database: database
        )

        let snapshot = await provider.snapshot(repoId: 8)

        if case .value(let release?) = snapshot.release {
            #expect(release.tagName == "v1.0.0")
        } else {
            Issue.record("Community 损坏不应影响 Release")
        }
        if case .failed = snapshot.community {
            // 预期：只隔离损坏的 Community 区块。
        } else {
            Issue.record("损坏 Community 应标记为失败")
        }
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

private struct StubRepositoryRemoteInsightsAccessProvider: RepositoryRemoteInsightsAccessProviding {
    let handler: @Sendable (Repo, Bool) async -> Bool

    func allowsRemoteInsights(repo: Repo, isAuthenticated: Bool) async -> Bool {
        await handler(repo, isAuthenticated)
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

/// 冻结本次测试声明的全部刷新请求，确保断言读取的是网络返回前的稳定 UI 状态。
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
    var cachedReleaseCadenceHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedReleaseCadenceInsight? = { _ in nil }
    var refreshReleaseCadenceHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositoryReleaseRemoteSnapshot = { _ in
        throw StubError.failed
    }
    var cachedSecurityAdvisoriesHandler: @Sendable (
        Int64
    ) async throws -> RepositoryCachedSecurityAdvisoriesInsight? = { _ in nil }
    var refreshSecurityAdvisoriesHandler: @Sendable (
        RepoIdentity
    ) async throws -> RepositorySecurityAdvisoriesInsight = { _ in
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

    func cachedReleaseCadence(repoID: Int64) async throws
        -> RepositoryCachedReleaseCadenceInsight? {
        try await cachedReleaseCadenceHandler(repoID)
    }

    func refreshReleaseCadence(repository: RepoIdentity) async throws
        -> RepositoryReleaseRemoteSnapshot {
        try await refreshReleaseCadenceHandler(repository)
    }

    func cachedSecurityAdvisories(repoID: Int64) async throws
        -> RepositoryCachedSecurityAdvisoriesInsight? {
        try await cachedSecurityAdvisoriesHandler(repoID)
    }

    func refreshSecurityAdvisories(repository: RepoIdentity) async throws
        -> RepositorySecurityAdvisoriesInsight {
        try await refreshSecurityAdvisoriesHandler(repository)
    }

    func cachedRecentActivity(repoID: Int64) async throws -> RepositoryCachedRecentActivity? {
        try await cachedRecentActivityHandler(repoID)
    }

    func refreshRecentActivity(repository: RepoIdentity) async throws -> RepositoryRecentActivity {
        try await refreshRecentActivityHandler(repository)
    }
}

private actor RepositoryInsightsCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
