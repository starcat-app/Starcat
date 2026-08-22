//
//  ActivityViewModelTests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-2（2026-06-16）：ActivityViewModel SWR 状态机单测。
//
//  覆盖：
//  - load（.respectTTL）+ 缓存空 → 走 events 网络
//  - load + 缓存有 + TTL 内 → 不走 events 网络
//  - load + 缓存有 + TTL 过期 → 走 events 网络
//  - refresh（.forceNetwork）→ 永远走网络
//  - events 失败 + 缓存有 → 保留缓存 + loadError 不动
//  - events 304 → touch lastEventsFetchedAt 不变 etag
//  - events 过滤 ReleaseEvent / 不支持的 type 不入库（决策 Q1）
//  - cleanupIfNeeded: 24h 冷却短路 / 过期触发删除
//  - makeFollowingItems: 7 个 event type 标题格式化 + payload preserved
//
//  设计：
//  - DB 走 InMemoryDatabaseManager + GRDB repos（真实 SQL，与生产一致）
//  - GitHub API 走 MockGitHubAPIClient.receivedEventsHandler
//  - releasePollerRunner / currentLoginProvider 都是闭包，直接注入
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@MainActor
@Suite("ActivityViewModel SWR")
struct ActivityViewModelTests {

    @Test("Repo List 行动画严格只覆盖前 15 行")
    func rowRevealLimitIsExactlyFifteen() {
        #expect(ListRowRevealMetrics.animatedRowLimit == 15)
        #expect(ListRowRevealMetrics.shouldAnimate(index: 0))
        #expect(ListRowRevealMetrics.shouldAnimate(index: 14))
        #expect(!ListRowRevealMetrics.shouldAnimate(index: 15))
        #expect(!ListRowRevealMetrics.shouldAnimate(index: 29))
    }

    @Test("Activity 隐藏全部入口但保留聚合枚举，旧偏好恢复到时间线")
    func hiddenAllCategoryRestoresTimeline() {
        #expect(ActivityCategory.allCases.contains(.all))
        #expect(ActivityCategory(persistedRawValue: "") == .notification)
        #expect(ActivityCategory(persistedRawValue: "all") == .notification)
        #expect(ActivityCategory(persistedRawValue: "release") == .release)
    }

    // MARK: - Harness

    /// 引用类型计数器（让 releasePollerRunner 闭包能跨调用累加）。
    @MainActor
    private final class PollCounter {
        var count: Int = 0
    }

    /// 测试 harness：一次性把所有依赖组装好。
    /// `pollCounter.count`：闭包记录被调次数，断言 refresh 路径 / load 路径是否调用 release poll。
    @MainActor
    private final class Harness {
        let viewModel: ActivityViewModel
        let mockClient: MockGitHubAPIClient
        let mockBlogClient: MockGitHubBlogRSSClient
        let eventRepo: GRDBActivityEventRepository
        let announcementRepo: GRDBActivityAnnouncementRepository
        let syncStateRepo: GRDBActivitySyncStateRepository
        let countService: ActivityCategoryCountService
        let pollCounter: PollCounter

        init(login: String? = "octocat") throws {
            let db = try InMemoryDatabaseManager()
            let mock = MockGitHubAPIClient()
            let mockBlog = MockGitHubBlogRSSClient()
            let er = GRDBActivityEventRepository(database: db)
            let ar = GRDBActivityAnnouncementRepository(database: db)
            let sr = GRDBActivitySyncStateRepository(database: db)
            let cs = ActivityCategoryCountService()
            let counter = PollCounter()

            self.mockClient = mock
            self.mockBlogClient = mockBlog
            self.eventRepo = er
            self.announcementRepo = ar
            self.syncStateRepo = sr
            self.countService = cs
            self.pollCounter = counter

            // PR-3：默认 events 返回空数组，避免未设 handler 的测试 fatalError。
            mock.receivedEventsHandler = { _, _, _ in
                APIResponse(
                    value: [],
                    linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                    rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
                    statusCode: 200,
                    etag: "\"default-events\""
                )
            }

            self.viewModel = ActivityViewModel(
                repoRepository: GRDBRepoRepository(database: db),
                releaseRepository: GRDBReleaseRepository(database: db),
                releasePollerRunner: { @MainActor in counter.count += 1 },
                activityEventRepository: er,
                activityAnnouncementRepository: ar,
                activitySyncStateRepository: sr,
                apiClient: mock,
                blogRSSClient: mockBlog,
                currentLoginProvider: { @MainActor in login },
                categoryCountService: cs
            )
        }
    }

    /// 造一条 GitHubEventDTO（API 响应风格）。
    private func makeEventDTO(
        id: String,
        type: String,
        actor: String = "ruanyf",
        repoName: String = "torvalds/linux",
        repoId: Int64 = 99001,
        payloadJson: String = #"{"action":"started"}"#,
        createdAt: String = "2026-06-15T12:00:00Z"
    ) -> GitHubEventDTO {
        GitHubEventDTO(
            id: id,
            type: type,
            actor: GitHubEventActorDTO(
                id: 1024,
                login: actor,
                displayLogin: actor,
                avatarUrl: "https://avatars.githubusercontent.com/\(actor)"
            ),
            repo: GitHubEventRepoDTO(
                id: repoId,
                name: repoName,
                url: "https://api.github.com/repos/\(repoName)"
            ),
            payloadJson: payloadJson,
            createdAt: createdAt
        )
    }

    private func makeAPIResponse(_ events: [GitHubEventDTO], etag: String? = "\"e1\"") -> APIResponse<[GitHubEventDTO]> {
        APIResponse(
            value: events,
            linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
            rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
            statusCode: 200,
            etag: etag
        )
    }

    // MARK: - SWR：空缓存走网络

    @Test("load + 缓存空 → 走 events 网络 + 上屏后 items 含 following")
    func loadEmptyCacheFetchesEvents() async throws {
        let h = try Harness()
        h.mockClient.receivedEventsHandler = { username, _, _ in
            #expect(username == "octocat")
            return self.makeAPIResponse([
                self.makeEventDTO(id: "ev1", type: "WatchEvent"),
            ])
        }

        await h.viewModel.load(category: .following)

        let following = h.viewModel.items.filter { $0.kind == .following }
        #expect(following.count == 1)
        #expect(following[0].title == "torvalds/linux")
        #expect(following[0].following?.actorLogin == "ruanyf")
        #expect(h.viewModel.lastRefreshedAt != nil)
        #expect(h.viewModel.isLoading == false)
        #expect(h.viewModel.isRefreshing == false)
        #expect(h.mockClient.receivedEventsCalls.count == 1)
    }

    @Test("load 发布 allItems 后回写 Activity sidebar 分类计数")
    func loadPublishesSidebarCategoryCounts() async throws {
        let h = try Harness()
        h.mockClient.receivedEventsHandler = { _, _, _ in
            self.makeAPIResponse([
                self.makeEventDTO(id: "ev-count", type: "WatchEvent"),
            ])
        }

        await h.viewModel.load(category: .following)

        #expect(h.countService.count(for: .following) == 1)
        #expect(h.countService.count(for: .announcement) == 1)
        #expect(h.countService.count(for: .all) == 2)
        #expect(h.countService.count(for: .star) == 0)
        #expect(!ActivityCategory.allCases.contains { $0.rawValue == "weekly" })
    }

    @Test("进入时间线也从本地缓存发布侧栏分类数字，不打 events 网络")
    func notificationEntryPublishesSidebarCountsFromCache() async throws {
        let h = try Harness()
        let oneHourAgo = Date().addingTimeInterval(-3_600)
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "sidebar-ev",
                eventType: "WatchEvent",
                actorLogin: "ruanyf",
                actorAvatarUrl: nil,
                repoName: "torvalds/linux",
                repoId: 99001,
                payloadJson: #"{"action":"started"}"#,
                isRead: false,
                createdAt: "2026-06-15T00:00:00Z",
                fetchedAt: ActivityViewModel.isoString(oneHourAgo)
            )
        ])
        h.mockClient.receivedEventsHandler = { _, _, _ in
            Issue.record("时间线进页不应为侧栏数字打 events 网络")
            throw NetworkError.invalidResponse
        }

        await h.viewModel.primeSidebarCategoryCountsIfNeeded()

        #expect(h.countService.count(for: .following) == 1)
        #expect(h.countService.count(for: .announcement) == 1)
        #expect(h.countService.count(for: .star) == 0)
        #expect(h.mockClient.receivedEventsCalls.count == 0)
        #expect(h.viewModel.isAggregateReady)
    }

    @Test("ActivityCategoryCountService: 本地分类发布后立即对 Sidebar 可见")
    func categoryCountServicePublishesLocalCountsImmediately() async throws {
        let service = ActivityCategoryCountService()

        service.applyLocalCounts([.all: 2, .following: 1, .announcement: 1])
        #expect(service.count(for: .all) == 2)
        #expect(service.count(for: .following) == 1)
        #expect(service.count(for: .announcement) == 1)
    }

    // MARK: - SWR：TTL 内不走网络

    @Test("load + TTL 内 (1h ago) → 不走 events 网络")
    func loadCacheHitTTLInsideSkipsNetwork() async throws {
        let h = try Harness()

        // 预置：events 表已有数据 + sync_state.lastEventsFetchedAt = 1h ago
        let oneHourAgo = Date().addingTimeInterval(-3_600)
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "cached-ev",
                eventType: "WatchEvent",
                actorLogin: "ruanyf",
                actorAvatarUrl: nil,
                repoName: "torvalds/linux",
                repoId: 99001,
                payloadJson: #"{"action":"started"}"#,
                isRead: false,
                createdAt: "2026-06-15T00:00:00Z",
                fetchedAt: ActivityViewModel.isoString(oneHourAgo)
            ),
        ])
        try await h.syncStateRepo.updateEvents(etag: "\"cached-etag\"", lastFetchedAt: oneHourAgo)

        // Mock 不该被调到；故意把 handler 设为抛错——若被调到测试就挂
        h.mockClient.receivedEventsHandler = { _, _, _ in
            Issue.record("TTL 内不应走 events 网络")
            throw NetworkError.invalidResponse
        }

        await h.viewModel.load(category: .following)

        #expect(h.mockClient.receivedEventsCalls.count == 0)
        #expect(h.viewModel.items.contains { $0.kind == .following })
    }

    // MARK: - SWR：TTL 过期 → 走网络

    @Test("load + TTL 过期 (3h ago) → 走 events 网络（后台刷新，已有缓存上屏）")
    func loadCacheHitTTLExpiredFetchesEvents() async throws {
        let h = try Harness()

        let threeHoursAgo = Date().addingTimeInterval(-3 * 3600)
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "old-ev",
                eventType: "WatchEvent",
                actorLogin: "ruanyf",
                actorAvatarUrl: nil,
                repoName: "torvalds/linux",
                repoId: 99001,
                payloadJson: #"{"action":"started"}"#,
                isRead: false,
                createdAt: "2026-06-14T00:00:00Z",
                fetchedAt: ActivityViewModel.isoString(threeHoursAgo)
            ),
        ])
        try await h.syncStateRepo.updateEvents(etag: "\"old-etag\"", lastFetchedAt: threeHoursAgo)

        h.mockClient.receivedEventsHandler = { _, _, etag in
            #expect(etag == "\"old-etag\"")
            return self.makeAPIResponse([
                self.makeEventDTO(id: "new-ev", type: "ForkEvent", repoName: "facebook/react", repoId: 88001),
            ])
        }

        await h.viewModel.load(category: .following)

        #expect(h.mockClient.receivedEventsCalls.count == 1)
        let following = h.viewModel.items.filter { $0.kind == .following }
        // 两条都该上屏（old + new 在 events 表里都有）
        #expect(following.count == 2)
    }

    // MARK: - refresh 永远走网络

    @Test("refresh + TTL 内 → 仍走 events 网络（绕过 TTL）")
    func refreshAlwaysFetches() async throws {
        let h = try Harness()
        // 设置 TTL 仍在窗口内
        try await h.syncStateRepo.updateEvents(etag: "\"e\"", lastFetchedAt: Date())

        h.mockClient.receivedEventsHandler = { _, _, _ in
            self.makeAPIResponse([
                self.makeEventDTO(id: "fresh", type: "WatchEvent"),
            ])
        }

        await h.viewModel.refresh(category: .following)

        #expect(h.mockClient.receivedEventsCalls.count == 1)
        #expect(h.pollCounter.count == 1) // refresh 也跑 release poller
    }

    // MARK: - 304 短路

    @Test("304 NotModified → touch lastEventsFetchedAt + 缓存保持显示")
    func notModified304TouchesTimestamp() async throws {
        let h = try Harness()

        let twoHoursAgo = Date().addingTimeInterval(-2 * 3600 - 60)
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "cached-ev",
                eventType: "WatchEvent",
                actorLogin: "ruanyf",
                actorAvatarUrl: nil,
                repoName: "torvalds/linux",
                repoId: 99001,
                payloadJson: #"{"action":"started"}"#,
                isRead: false,
                createdAt: "2026-06-15T00:00:00Z",
                fetchedAt: ActivityViewModel.isoString(twoHoursAgo)
            ),
        ])
        try await h.syncStateRepo.updateEvents(etag: "\"e1\"", lastFetchedAt: twoHoursAgo)

        h.mockClient.receivedEventsHandler = { _, _, etag in
            #expect(etag == "\"e1\"")
            throw NetworkError.notModified(etag: "\"e1\"")
        }

        await h.viewModel.load(category: .following)

        // 缓存仍在
        #expect(h.viewModel.items.contains { $0.kind == .following })
        // lastEventsFetchedAt 已被 touch 到现在（>= 5 秒前不算 touch 过的旧值）
        let state = try await h.syncStateRepo.current()
        let timestamp = try #require(state?.lastEventsFetchedAt)
        let parsed = try #require(ActivityViewModel.parseDate(timestamp))
        #expect(Date().timeIntervalSince(parsed) < 5)
        // etag 保持
        #expect(state?.eventsEtag == "\"e1\"")
    }

    // MARK: - 失败降级：有缓存

    @Test("events 失败 + 有缓存 → 保留 items + loadError 不阻塞")
    func eventsFailureWithCacheKeepsItems() async throws {
        let h = try Harness()
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "cached",
                eventType: "WatchEvent",
                actorLogin: "ruanyf",
                actorAvatarUrl: nil,
                repoName: "torvalds/linux",
                repoId: 99001,
                payloadJson: #"{"action":"started"}"#,
                isRead: false,
                createdAt: "2026-06-15T00:00:00Z",
                fetchedAt: "2026-06-15T00:00:00Z"
            ),
        ])
        // 不设 sync_state → shouldFetchEvents 为 true（无 lastFetchedAt）

        h.mockClient.receivedEventsHandler = { _, _, _ in
            throw NetworkError.serverError(statusCode: 503)
        }

        await h.viewModel.load(category: .following)

        // 缓存仍上屏
        #expect(h.viewModel.items.contains { $0.kind == .following })
        // 有缓存 → loadError 应保持 nil（仅 log 不展示给用户）
        #expect(h.viewModel.loadError == nil)
    }

    @Test("events 失败 + 无缓存 → loadError 显示")
    func eventsFailureNoCacheShowsError() async throws {
        let h = try Harness()
        h.mockClient.receivedEventsHandler = { _, _, _ in
            throw NetworkError.serverError(statusCode: 503)
        }

        await h.viewModel.load(category: .following)

        #expect(h.viewModel.loadError != nil)
    }

    // MARK: - 过滤 ReleaseEvent / 不支持类型（决策 Q1）

    @Test("fetch: ReleaseEvent + GollumEvent 在网络层被过滤不入库")
    func filtersReleaseAndUnsupportedEvents() async throws {
        let h = try Harness()
        h.mockClient.receivedEventsHandler = { _, _, _ in
            self.makeAPIResponse([
                self.makeEventDTO(id: "watch1", type: "WatchEvent"),
                self.makeEventDTO(id: "rel1",   type: "ReleaseEvent"),   // 决策 Q1：丢弃
                self.makeEventDTO(id: "goll1",  type: "GollumEvent"),    // 信噪比低：丢弃
                self.makeEventDTO(id: "fork1",  type: "ForkEvent"),
            ])
        }

        await h.viewModel.load(category: .following)

        let stored = try await h.eventRepo.fetchAll(limit: 100)
        let ids = Set(stored.map(\.id))
        #expect(ids == ["watch1", "fork1"])
    }

    // MARK: - cleanupIfNeeded

    @Test("cleanupIfNeeded: 24h 冷却内短路不动数据")
    func cleanupCooldownSkipsWithin24h() async throws {
        let h = try Harness()

        // 预置一条 35 天前的 event（满足"应被删"条件）+ 12h 前清理过
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "old", eventType: "WatchEvent", actorLogin: "x",
                actorAvatarUrl: nil, repoName: "x/y", repoId: 1,
                payloadJson: "{}", isRead: false,
                createdAt: ISO8601DateFormatter.shared.string(
                    from: Date().addingTimeInterval(-35 * 86_400)
                ),
                fetchedAt: "2026-05-01T00:00:00Z"
            ),
        ])
        try await h.syncStateRepo.updateLastCleanupAt(Date().addingTimeInterval(-12 * 3600))

        await h.viewModel.cleanupIfNeeded()

        let remaining = try await h.eventRepo.fetchAll(limit: 100)
        #expect(remaining.count == 1) // 冷却短路，未清理
    }

    @Test("cleanupIfNeeded: ≥ 24h 冷却过 → 删除 30 天前的 events")
    func cleanupRunsAfter24h() async throws {
        let h = try Harness()

        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "old", eventType: "WatchEvent", actorLogin: "x",
                actorAvatarUrl: nil, repoName: "x/y", repoId: 1,
                payloadJson: "{}", isRead: false,
                createdAt: ISO8601DateFormatter.shared.string(
                    from: Date().addingTimeInterval(-35 * 86_400)
                ),
                fetchedAt: "2026-05-01T00:00:00Z"
            ),
            ActivityEventRecord(
                id: "fresh", eventType: "WatchEvent", actorLogin: "x",
                actorAvatarUrl: nil, repoName: "x/y", repoId: 1,
                payloadJson: "{}", isRead: false,
                createdAt: ISO8601DateFormatter.shared.string(from: Date()),
                fetchedAt: "2026-06-15T00:00:00Z"
            ),
        ])
        try await h.syncStateRepo.updateLastCleanupAt(Date().addingTimeInterval(-25 * 3600))

        await h.viewModel.cleanupIfNeeded()

        let remaining = try await h.eventRepo.fetchAll(limit: 100)
        #expect(remaining.map(\.id) == ["fresh"])

        // lastCleanupAt 已被刷新（< 5s 前）
        let state = try await h.syncStateRepo.current()
        let parsed = try #require(state?.lastCleanupAt.flatMap(ActivityViewModel.parseDate))
        #expect(Date().timeIntervalSince(parsed) < 5)
    }

    // MARK: - payload format

    @Test("makeFollowingItems: 7 个 event type 标题分别格式化（含 PR merged / CreateEvent 分支）")
    func formatTitleAllEventTypes() async throws {
        let h = try Harness()
        h.mockClient.receivedEventsHandler = { _, _, _ in
            self.makeAPIResponse([
                self.makeEventDTO(id: "watch", type: "WatchEvent"),
                self.makeEventDTO(id: "fork",  type: "ForkEvent"),
                self.makeEventDTO(id: "push",  type: "PushEvent",
                    payloadJson: #"{"ref":"refs/heads/main","size":3}"#),
                self.makeEventDTO(id: "iss-o", type: "IssuesEvent",
                    payloadJson: #"{"action":"opened","issue":{"title":"Bug"}}"#),
                self.makeEventDTO(id: "iss-c", type: "IssuesEvent",
                    payloadJson: #"{"action":"closed","issue":{"title":"Bug"}}"#),
                self.makeEventDTO(id: "pr-o",  type: "PullRequestEvent",
                    payloadJson: #"{"action":"opened","pull_request":{"title":"Feat"}}"#),
                self.makeEventDTO(id: "pr-m",  type: "PullRequestEvent",
                    payloadJson: #"{"action":"closed","pull_request":{"merged":true,"title":"Feat"}}"#),
                self.makeEventDTO(id: "pr-c",  type: "PullRequestEvent",
                    payloadJson: #"{"action":"closed","pull_request":{"merged":false,"title":"Feat"}}"#),
                self.makeEventDTO(id: "cre-b", type: "CreateEvent",
                    payloadJson: #"{"ref":"feature-x","ref_type":"branch"}"#),
                self.makeEventDTO(id: "cre-t", type: "CreateEvent",
                    payloadJson: #"{"ref":"v1.0","ref_type":"tag"}"#),
                self.makeEventDTO(id: "cre-r", type: "CreateEvent",
                    payloadJson: #"{"ref":null,"ref_type":"repository"}"#),
                self.makeEventDTO(id: "disc",  type: "DiscussionEvent",
                    payloadJson: #"{"action":"created","discussion":{"title":"Q?"}}"#),
            ])
        }

        await h.viewModel.load(category: .following)

        let following = h.viewModel.items.filter { $0.kind == .following }
        // 应有 12 条（全部 supported event）
        #expect(following.count == 12)

        // 检 payload preserved
        let watchItem = try #require(following.first { $0.id.hasSuffix(":watch") })
        #expect(watchItem.following?.eventType == "WatchEvent")
        #expect(watchItem.following?.actorAvatarURL != nil)

        // 检 PR merged 与 PR closed 副标题不同（分别走 .merged.format / .closed.format）
        let prM = try #require(following.first { $0.id.hasSuffix(":pr-m") })
        let prC = try #require(following.first { $0.id.hasSuffix(":pr-c") })
        #expect(prM.subtitle != prC.subtitle)
    }

    @Test("makeFollowingItems: 不支持的 type 不应出现（本地数据混入也跳过）")
    func skipsUnsupportedTypesInLocal() async throws {
        let h = try Harness()

        // 预置本地一条 ReleaseEvent —— 模拟 PR-1 历史数据 / schema 不强约束
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "stale-release", eventType: "ReleaseEvent",
                actorLogin: "x", actorAvatarUrl: nil,
                repoName: "x/y", repoId: 1, payloadJson: "{}",
                isRead: false,
                createdAt: ISO8601DateFormatter.shared.string(from: Date()),
                fetchedAt: ISO8601DateFormatter.shared.string(from: Date())
            ),
        ])
        try await h.syncStateRepo.updateEvents(etag: "\"e\"", lastFetchedAt: Date())

        await h.viewModel.load(category: .following)

        // following 列表不应包含 ReleaseEvent 渲染产物
        #expect(h.viewModel.items.filter { $0.kind == .following }.isEmpty)
    }

    // MARK: - 4 路本地降级

    @Test("4 路本地: 即使 events 表读失败也不影响其它（伪场景: 本地空 + 网络空）")
    func empty4PathsRendersNoItems() async throws {
        let h = try Harness(login: nil) // login 为 nil → 不走网络

        await h.viewModel.load(category: .all)

        // 没 login → 不走网络。空 repo / release / event / announcement →
        // items 只剩内置占位 announcement
        #expect(h.viewModel.items.count == 1)
        #expect(h.viewModel.items.first?.id == "announcement:activity-v1")
        // network handler 完全没被调（因为 login 为 nil 直接 skip events fetch）
        #expect(h.mockClient.receivedEventsCalls.count == 0)
    }

    // MARK: - PR-3 announcement

    @Test("关注排序 oldestFirst 反转列表顺序")
    func followingSortOldestFirst() async throws {
        let h = try Harness()
        let older = "2026-06-10T12:00:00Z"
        let newer = "2026-06-16T12:00:00Z"
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "ev-old", eventType: "WatchEvent", actorLogin: "a",
                actorAvatarUrl: nil, repoName: "org/old", repoId: 1,
                payloadJson: #"{"action":"started"}"#, isRead: false,
                createdAt: older, fetchedAt: older
            ),
            ActivityEventRecord(
                id: "ev-new", eventType: "ForkEvent", actorLogin: "b",
                actorAvatarUrl: nil, repoName: "org/new", repoId: 2,
                payloadJson: #"{"action":"created"}"#, isRead: false,
                createdAt: newer, fetchedAt: newer
            ),
        ])

        await h.viewModel.ensureLoaded(category: .following)
        #expect(h.viewModel.items.first?.title == "org/new")

        h.viewModel.changeTimeSort(to: .oldestFirst)
        #expect(h.viewModel.items.first?.title == "org/old")
    }

    @Test("clearFollowingFeed 清空 activity_events 并移除列表项")
    func clearFollowingFeedRemovesItems() async throws {
        let h = try Harness()
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "ev1", eventType: "WatchEvent", actorLogin: "a",
                actorAvatarUrl: nil, repoName: "org/r", repoId: 1,
                payloadJson: #"{"action":"started"}"#, isRead: false,
                createdAt: "2026-06-16T12:00:00Z", fetchedAt: "2026-06-16T12:00:00Z"
            ),
        ])

        await h.viewModel.ensureLoaded(category: .following)
        #expect(h.viewModel.items.contains { $0.kind == .following })

        await h.viewModel.clearFollowingFeed()

        #expect(h.viewModel.items.filter { $0.kind == .following }.isEmpty)
        let stored = try await h.eventRepo.fetchAll(limit: 10)
        #expect(stored.isEmpty)
    }

    @Test("clearAnnouncementFeed 清空 activity_announcements 并回退内置占位")
    func clearAnnouncementFeedRemovesItems() async throws {
        let h = try Harness()
        try await h.announcementRepo.upsertMany([
            ActivityAnnouncementRecord(
                id: "blog:test", source: AnnouncementSource.blog.rawValue,
                title: "Test", bodyMarkdown: "body", author: nil, url: "https://github.blog/test",
                repoName: nil, categories: nil, isRead: false,
                createdAt: "2026-06-16T12:00:00Z", fetchedAt: "2026-06-16T12:00:00Z"
            ),
        ])

        await h.viewModel.ensureLoaded(category: .announcement)
        #expect(h.viewModel.items.contains { $0.id == "blog:test" })

        await h.viewModel.clearAnnouncementFeed()

        #expect(h.viewModel.items.contains { $0.id == "blog:test" } == false)
        #expect(h.viewModel.items.contains { $0.id == "announcement:activity-v1" })
        let stored = try await h.announcementRepo.fetchAll(limit: 10)
        #expect(stored.isEmpty)
    }

    @Test("公告排序 oldestFirst 反转列表顺序")
    func announcementSortOldestFirst() async throws {
        let h = try Harness()
        let older = "2026-06-10T12:00:00Z"
        let newer = "2026-06-16T12:00:00Z"
        try await h.announcementRepo.upsertMany([
            ActivityAnnouncementRecord(
                id: "blog:old", source: AnnouncementSource.blog.rawValue,
                title: "Old", bodyMarkdown: "a", author: nil, url: "https://github.blog/old",
                repoName: nil, categories: nil, isRead: false,
                createdAt: older, fetchedAt: older
            ),
            ActivityAnnouncementRecord(
                id: "blog:new", source: AnnouncementSource.blog.rawValue,
                title: "New", bodyMarkdown: "b", author: nil, url: "https://github.blog/new",
                repoName: nil, categories: nil, isRead: false,
                createdAt: newer, fetchedAt: newer
            ),
        ])

        await h.viewModel.ensureLoaded(category: .announcement)
        #expect(h.viewModel.items.first?.title == "New")

        h.viewModel.changeTimeSort(to: .oldestFirst)
        #expect(h.viewModel.items.first?.title == "Old")
    }

    @Test("切分类 selectCategory 不 bump itemsRevision（避免 listRowReveal 风暴）")
    func selectCategoryDoesNotBumpItemsRevision() async throws {
        let h = try Harness()
        try await h.eventRepo.upsertMany([
            ActivityEventRecord(
                id: "ev1", eventType: "WatchEvent", actorLogin: "a",
                actorAvatarUrl: nil, repoName: "org/r", repoId: 1,
                payloadJson: #"{"action":"started"}"#, isRead: false,
                createdAt: "2026-06-16T12:00:00Z", fetchedAt: "2026-06-16T12:00:00Z"
            ),
        ])

        await h.viewModel.ensureLoaded(category: .following)
        let revisionAfterLoad = h.viewModel.itemsRevision

        h.viewModel.selectCategory(.announcement)
        await h.viewModel.awaitPendingBackgroundWorkForTesting()
        #expect(h.viewModel.itemsRevision == revisionAfterLoad)

        h.viewModel.selectCategory(.following)
        await h.viewModel.awaitPendingBackgroundWorkForTesting()
        #expect(h.viewModel.itemsRevision == revisionAfterLoad)
    }

    @Test("切分类在首屏提交后推进独立 row reveal，排序不冒充分类动画")
    func selectCategoryAdvancesRowRevealAfterSnapshotCommit() async throws {
        let h = try Harness()
        await h.viewModel.ensureLoaded(category: .star)
        let initialRevealRevision = h.viewModel.rowRevealRevision

        h.viewModel.selectCategory(.repository)
        await h.viewModel.awaitPendingBackgroundWorkForTesting()
        #expect(h.viewModel.rowRevealRevision > initialRevealRevision)
        let categoryRevealRevision = h.viewModel.rowRevealRevision

        h.viewModel.changeTimeSort(to: .oldestFirst)
        #expect(h.viewModel.itemsRevision > 0)
        #expect(h.viewModel.rowRevealRevision == categoryRevealRevision)
    }

    @Test("切分类 selectCategory 不重复拉 events")
    func selectCategorySkipsDuplicateEventsNetwork() async throws {
        let h = try Harness()

        await h.viewModel.ensureLoaded(category: .following)
        let callsAfterLoad = h.mockClient.receivedEventsCalls.count

        h.mockClient.receivedEventsHandler = { _, _, _ in
            Issue.record("切分类不应重复走 events 网络")
            throw NetworkError.invalidResponse
        }

        h.viewModel.selectCategory(.repository)

        #expect(h.mockClient.receivedEventsCalls.count == callsAfterLoad)
    }

    @Test("先 following 后 announcement → selectCategory 懒补 blog")
    func selectCategorySupplementsAnnouncementNetwork() async throws {
        let h = try Harness()

        await h.viewModel.ensureLoaded(category: .following)
        #expect(h.mockBlogClient.fetchFeedCalls.isEmpty)

        h.viewModel.selectCategory(.announcement)
        await h.viewModel.awaitPendingBackgroundWorkForTesting()

        #expect(h.mockBlogClient.fetchFeedCalls.count == 1)
        #expect(h.viewModel.items.contains { $0.kind == .announcement })
    }

    @Test("announcement 分类不触发 events 网络")
    func announcementCategorySkipsEventsNetwork() async throws {
        let h = try Harness()
        var eventsCalled = false
        h.mockClient.receivedEventsHandler = { _, _, _ in
            eventsCalled = true
            return APIResponse(
                value: [],
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
                statusCode: 200,
                etag: "\"e\""
            )
        }

        await h.viewModel.ensureLoaded(category: .announcement)

        #expect(eventsCalled == false)
        #expect(h.mockBlogClient.fetchFeedCalls.count == 1)
    }

    @Test("blog RSS 12h TTL 内不走网络")
    func blogTTLInsideSkipsNetwork() async throws {
        let h = try Harness()
        try await h.syncStateRepo.updateBlogRss(etag: "\"b\"", lastFetchedAt: Date())
        try await h.syncStateRepo.updateSecurity(lastFetchedAt: Date())
        try await h.syncStateRepo.updateEvents(etag: "\"e\"", lastFetchedAt: Date())

        h.mockBlogClient.fetchFeedHandler = { _ in
            Issue.record("blog TTL 内不应走网络")
            throw NetworkError.invalidResponse
        }

        await h.viewModel.load(category: .announcement)

        #expect(h.mockBlogClient.fetchFeedCalls.count == 0)
    }

    @Test("blog RSS 拉取后写入 announcements + 隐藏内置占位")
    func blogRSSPersistsAndHidesBuiltin() async throws {
        let h = try Harness()
        h.mockBlogClient.fetchFeedHandler = { _ in
            APIResponse(
                value: [
                    GitHubBlogRSSItemDTO(
                        guid: "?p=1",
                        title: "Hello Blog",
                        link: "https://github.blog/hello/",
                        author: "Staff",
                        pubDate: "Mon, 16 Jun 2026 12:00:00 +0000",
                        categories: ["AI & ML"],
                        descriptionHTML: "<p>Short</p>",
                        contentHTML: "<p>Full <b>HTML</b></p>"
                    ),
                ],
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
                statusCode: 200,
                etag: "\"rss-new\""
            )
        }

        await h.viewModel.load(category: .announcement)

        let announcements = h.viewModel.items.filter { $0.kind == .announcement }
        #expect(announcements.count == 1)
        #expect(announcements[0].id == "blog:?p=1")
        #expect(announcements[0].announcement?.source == .blog)
        #expect(announcements[0].announcement?.htmlBody?.contains("<b>HTML</b>") == true)
        #expect(!h.viewModel.items.contains { $0.id == "announcement:activity-v1" })

        let stored = try await h.announcementRepo.fetchAll(limit: 10)
        #expect(stored.count == 1)
        #expect(stored[0].title == "Hello Blog")
    }

    @Test("blog 304 touch lastBlogFetchedAt")
    func blog304TouchesTimestamp() async throws {
        let h = try Harness()
        let thirteenHoursAgo = Date().addingTimeInterval(-13 * 3600)
        try await h.syncStateRepo.updateBlogRss(etag: "\"old\"", lastFetchedAt: thirteenHoursAgo)
        try await h.syncStateRepo.updateSecurity(lastFetchedAt: Date())
        try await h.syncStateRepo.updateEvents(etag: "\"e\"", lastFetchedAt: Date())

        h.mockBlogClient.fetchFeedHandler = { etag in
            #expect(etag == "\"old\"")
            throw NetworkError.notModified(etag: "\"old\"")
        }

        await h.viewModel.load(category: .announcement)

        let state = try await h.syncStateRepo.current()
        let parsed = try #require(state?.lastBlogFetchedAt.flatMap(ActivityViewModel.parseDate))
        #expect(Date().timeIntervalSince(parsed) < 5)
    }

    @Test("security 仅扫描最近 30 天 push 的 starred repo")
    func securityScansRecentStarredOnly() async throws {
        let recent = makeRepo(id: 1, fullName: "a/r1", pushedAt: ActivityViewModel.isoString(Date()))
        let old = makeRepo(id: 2, fullName: "a/r2", pushedAt: ActivityViewModel.isoString(Date().addingTimeInterval(-40 * 86_400)))
        let unstarred = makeRepo(id: 3, fullName: "a/r3", pushedAt: ActivityViewModel.isoString(Date()), isStarred: false)

        let result = ActivityViewModel.starredReposRecentlyPushed(repos: [recent, old, unstarred])
        #expect(result.map(\.id) == [1])
    }

    @Test("security per-repo 404 静默跳过")
    func security404Skipped() async throws {
        let db = try InMemoryDatabaseManager()
        let recentPushed = ActivityViewModel.isoString(Date())
        try await insertStarredRepo(db: db, id: 101, fullName: "org/missing", pushedAt: recentPushed)
        try await insertStarredRepo(db: db, id: 102, fullName: "org/hit", pushedAt: recentPushed)

        let repoRepo = GRDBRepoRepository(database: db)
        let syncStateRepo = GRDBActivitySyncStateRepository(database: db)
        try await syncStateRepo.updateEvents(etag: "\"e\"", lastFetchedAt: Date())
        try await syncStateRepo.updateBlogRss(etag: "\"b\"", lastFetchedAt: Date())

        let mockBlog = MockGitHubBlogRSSClient()
        let mockAPI = MockGitHubAPIClient()
        mockAPI.securityAdvisoriesHandler = { owner, repo in
            if owner == "org", repo == "missing" {
                throw NetworkError.notFound
            }
            return APIResponse(
                value: [
                    GitHubSecurityAdvisoryDTO(
                        ghsaId: "GHSA-xxxx",
                        summary: "CVE fix",
                        description: "Details",
                        htmlUrl: "https://github.com/advisories/GHSA-xxxx",
                        // 使用当前时间，避免后台 30 天保留期清理掉本用例刚写入的公告。
                        publishedAt: ActivityViewModel.isoString(Date()),
                        severity: "high"
                    ),
                ],
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
                statusCode: 200,
                etag: nil
            )
        }

        let vm = ActivityViewModel(
            repoRepository: repoRepo,
            releaseRepository: GRDBReleaseRepository(database: db),
            releasePollerRunner: {},
            activityEventRepository: GRDBActivityEventRepository(database: db),
            activityAnnouncementRepository: GRDBActivityAnnouncementRepository(database: db),
            activitySyncStateRepository: syncStateRepo,
            apiClient: mockAPI,
            blogRSSClient: mockBlog,
            currentLoginProvider: { "octocat" }
        )

        await vm.load(category: .announcement)
        await vm.awaitPendingBackgroundWorkForTesting()

        let stored = try await GRDBActivityAnnouncementRepository(database: db).fetchAll(limit: 10)
        #expect(stored.count == 1)
        let announcement = try #require(stored.first)
        #expect(announcement.id == "security:GHSA-xxxx")
        #expect(mockAPI.securityAdvisoriesCalls.count == 2)
    }

    @Test("following 分类首屏 pageSize 条，loadMore 追加剩余")
    func followingPaginationLoadMore() async throws {
        let h = try Harness()
        var records: [ActivityEventRecord] = []
        for index in 0..<35 {
            let day = String(format: "%02d", index + 1)
            records.append(
                ActivityEventRecord(
                    id: "ev-\(index)",
                    eventType: "WatchEvent",
                    actorLogin: "actor\(index)",
                    actorAvatarUrl: nil,
                    repoName: "org/repo\(index)",
                    repoId: Int64(index + 1),
                    payloadJson: #"{"action":"started"}"#,
                    isRead: false,
                    createdAt: "2026-06-\(day)T12:00:00Z",
                    fetchedAt: "2026-06-\(day)T12:00:00Z"
                )
            )
        }
        try await h.eventRepo.upsertMany(records)

        await h.viewModel.ensureLoaded(category: .following)
        #expect(h.viewModel.items.count == ActivityViewModel.pageSize)
        #expect(h.viewModel.hasMoreItems)

        h.viewModel.loadMoreIfNeeded()
        #expect(h.viewModel.items.count == 35)
        #expect(h.viewModel.hasMoreItems == false)
    }

    @Test("following 分页追加只尾部 append,不 bump itemsRevision")
    func followingPaginationAppendsWithoutReplacingPrefix() async throws {
        let h = try Harness()
        var records: [ActivityEventRecord] = []
        for index in 0..<60 {
            let day = String(format: "%02d", (index % 28) + 1)
            records.append(
                ActivityEventRecord(
                    id: "append-ev-\(index)",
                    eventType: "WatchEvent",
                    actorLogin: "actor\(index)",
                    actorAvatarUrl: nil,
                    repoName: "org/repo\(index)",
                    repoId: Int64(index + 1),
                    payloadJson: #"{"action":"started"}"#,
                    isRead: false,
                    createdAt: "2026-06-\(day)T12:00:00Z",
                    fetchedAt: "2026-06-\(day)T12:00:00Z"
                )
            )
        }
        try await h.eventRepo.upsertMany(records)

        await h.viewModel.ensureLoaded(category: .following)
        let firstPageIDs = h.viewModel.items.map(\.id)
        let revisionBeforeAppend = h.viewModel.itemsRevision

        h.viewModel.loadMoreIfNeeded()

        #expect(h.viewModel.items.count == 60)
        #expect(Array(h.viewModel.items.map(\.id).prefix(ActivityViewModel.pageSize)) == firstPageIDs,
                "append 后前一页 identity 必须保持原顺序,避免 List 误判为整段替换")
        #expect(h.viewModel.itemsRevision == revisionBeforeAppend,
                "本地分页 append 不应 bump revision,否则会触发整栏 reveal / 重建")
        #expect(h.viewModel.hasMoreItems == false)
    }

    @Test("首次进入全部分类复用后台 filter 管线，完成后正常上屏且不 bump revision")
    func allCategoryInitialLoadUsesFilterPipeline() async throws {
        let h = try Harness()
        var records: [ActivityEventRecord] = []
        for index in 0..<35 {
            let day = String(format: "%02d", (index % 28) + 1)
            records.append(
                ActivityEventRecord(
                    id: "all-ev-\(index)",
                    eventType: "WatchEvent",
                    actorLogin: "actor\(index)",
                    actorAvatarUrl: nil,
                    repoName: "org/repo\(index)",
                    repoId: Int64(index + 1),
                    payloadJson: #"{"action":"started"}"#,
                    isRead: false,
                    createdAt: "2026-06-\(day)T12:00:00Z",
                    fetchedAt: "2026-06-\(day)T12:00:00Z"
                )
            )
        }
        try await h.eventRepo.upsertMany(records)

        await h.viewModel.ensureLoaded(category: .all)
        await h.viewModel.awaitPendingBackgroundWorkForTesting()

        #expect(h.viewModel.isApplyingCategoryFilter == false)
        #expect(h.viewModel.items.count == ActivityViewModel.pageSize)
        #expect(h.viewModel.hasMoreItems)
        #expect(h.viewModel.itemsRevision == 0)
    }

    // MARK: - PR-3 helpers

    private func insertStarredRepo(
        db: InMemoryDatabaseManager,
        id: Int64,
        fullName: String,
        pushedAt: String
    ) async throws {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        try await db.writer.write { database in
            try database.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, ?, ?, ?, NULL, NULL,
                    0, 0, 0, NULL, NULL,
                    NULL, ?, NULL, NULL,
                    0, 0, 0, 1,
                    ?, NULL, NULL, '2026-01-01T00:00:00Z', NULL
                )
                """,
                arguments: [id, parts[0], parts[1], fullName, "https://github.com/\(fullName)", pushedAt]
            )
        }
    }

    private func makeRepo(id: Int64, fullName: String, pushedAt: String, isStarred: Bool = true) -> Repo {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return Repo(
            id: id,
            owner: parts[0],
            name: parts[1],
            fullName: fullName,
            description: nil,
            language: nil,
            starsCount: 10,
            forksCount: 1,
            watchersCount: 1,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(fullName)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: pushedAt,
            createdAt: nil,
            updatedAt: pushedAt,
            starredAt: "2026-01-01T00:00:00Z",
            cachedAt: nil
        )
    }
}
