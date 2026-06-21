//
//  ActivityViewModel.swift
//  Starcat
//
//  Activity 页本地聚合 + 网络刷新 ViewModel。
//
//  ─── 版本演进 ───
//
//  v1（2026-06-10）：纯本地聚合，只组合 Starcat 已有缓存（star / repository /
//  suggestion / release / 占位 announcement），不接 GitHub Events API。
//
//  **v2 = Activity 公告与关注 PR-2（2026-06-16）**：接 GitHub Events API
//  + SWR 改造。设计参考 `TrendingViewModel.reload` 同款套路：
//  - `ActivityCachePolicy` enum 显式区分「尊重 TTL」/「强制走网络」入口
//  - 进入页面 / 切分类 = `.respectTTL`（2h TTL 内零打扰）
//  - 用户主动刷新 = `.forceNetwork`（绕过 TTL）
//  - 4 路并行本地读 → 上屏缓存 → 后台 events 网络 → 重组装上屏
//  - 4 路任一失败 fallback 到老数据，loadError 仅记录不阻断
//  - `cleanupIfNeeded()` 30 天数据清理 ≥ 24h 触发一次，detached Task 不阻塞 UI
//
//  网络层（PR-2 仅 1 路）：`GET /users/{login}/received_events/public`
//  → 写入 `activity_events` 表 → 写回 `activity_sync_state.events_etag` + `last_events_fetched_at`。
//  PR-3 会再接 blog RSS + Security Advisory，届时 4 路并行的网络层从 1 升到 3。
//
//  **v3 = Activity 公告与关注 PR-3（2026-06-17）**：announcement 双源网络
//  - Blog RSS：`GET https://github.blog/feed/` + ETag → `activity_announcements`
//  - Security：`GET /repos/{o}/{r}/security-advisories` 仅扫最近 30 天 push 的 starred
//  - 有真实 announcement 时隐藏内置占位 `announcement:activity-v1`
//
//  **v3.1（2026-06-17 dong4j 反馈卡顿）**：切分类 ≠ 全量 reload
//  - `allItems` 缓存未过滤聚合；`selectCategory` 只 refilter，零网络、零 makeItems 全量重建
//  - 网络按当前分类裁剪：following 只拉 events；announcement 只拉 blog + security
//  - security 扫描 detached 后台跑，不阻塞首屏；reload 用 defer 复位 loading 状态
//
//  Following payload 解析约束（详见 `makeFollowingItems` 注释）：
//  - 仅 7 个 event type（WatchEvent / ForkEvent / PushEvent / IssuesEvent /
//    PullRequestEvent / CreateEvent / DiscussionEvent）有 i18n 文案，其它丢弃
//  - ReleaseEvent 在网络层就过滤掉（决策 Q1，避免与 `releases` 表双显）
//  - payload JSON 反解码失败 / 字段缺失 → 该条 event 跳过（不阻塞 feed）
//

import Foundation
import Observation

/// Activity 数据加载的缓存策略（PR-2，2026-06-16）。
///
/// - `.respectTTL`：尊重 2h 客户端 TTL —— `activity_sync_state.last_events_fetched_at`
///   在 2h 内不再走 events 网络。用于首次入场、切分类等"非用户主动刷新"场景。
/// - `.forceNetwork`：绕过 TTL 永远走网络。用于 toolbar 刷新按钮 / 错误重试等
///   "用户主动要新数据"场景。
///
/// 与 `TrendingCachePolicy` 同款语义；放在 ViewModel 层（而非 Repository 入参）
/// 让 Repository 协议保持纯净，避免引入"返回值标记 from-cache vs from-network"的复杂度。
enum ActivityCachePolicy: Sendable {
    case respectTTL
    case forceNetwork
}

@MainActor
@Observable
final class ActivityViewModel {

    // MARK: - 常量（PR-2，2026-06-16）

    /// events 数据源 TTL：2 小时（方案 §5.3 决策 P5）。
    ///
    /// 选 2h 不选 4h / 8h：GitHub Events feed 在用户主动关注的人较活跃时（如
    /// `torvalds` / `gaearon`），4h 内会积累 10+ 条新事件，2h 是体感新鲜度
    /// 与配额节流的平衡点。2h 内重复进入 activity 页 → 短路网络（304 + ETag 进一步降本）。
    nonisolated static let eventsTTL: TimeInterval = 7_200

    /// announcement 双源（blog + security）网络 TTL：12 小时（方案 §3.2）。
    nonisolated static let announcementsTTL: TimeInterval = 43_200

    /// Security Advisory 扫描：仅最近 N 天内有 push 的 starred repo。
    nonisolated static let securityLookbackDays = 30

    /// Security 扫描 repo 上限，防止 starred 过多时 API 风暴。
    nonisolated static let securityScanMaxRepos = 200

    /// Security Advisory 扫描并发上限。
    ///
    /// 原实现最多 200 个 repo 串行请求，后台刷新会挂很久；这里采用小并发池，既缩短
    /// announcement 刷新时间，又避免对 GitHub API 造成突发洪峰。
    private let securityScanConcurrency = 6

    /// 30 天数据清理冷却：24 小时（方案 §5.4 决策 P6）。
    ///
    /// `cleanupIfNeeded()` 读 `activity_sync_state.last_cleanup_at`，距上次清理 < 24h 直接跳过。
    /// 不在主刷新路径里跑，由 reload 末尾 detached Task 异步派发；24h 一次足够
    /// 控制 events / announcements 表行数（30 天滚动窗口 × 平均 60 行/天 ≈ 1800 行上限）。
    nonisolated static let cleanupCooldown: TimeInterval = 86_400

    /// 数据保留天数：30 天（方案 §3.2）。30 天前的 events / announcements 被
    /// `cleanupIfNeeded()` 物理删除（不保留 tombstone —— device-local 数据 + 不挂 CloudKit）。
    nonisolated static let retentionDays: Int = 30

    /// Activity 首屏 prime：`fetchRecentStarred` 上限（足够覆盖各 kind 的 `.prefix(30)`）。
    nonisolated static let primeStarredLimit = 150

    /// 列表客户端分页：首屏 + 滚到底增量加载（对齐 Weekly `localPageSize`）。
    nonisolated static let pageSize = 30

    /// 超过该条数的 filter 走后台线程（`.all` 始终后台）。
    nonisolated static let asyncFilterItemThreshold = 400

    /// 受支持的 GitHub Event 类型集合。
    ///
    /// **排除清单**（决策 Q1 + §7.7）：
    /// - `ReleaseEvent`：与 `releases` 表语义重复（HOM-47 已专门追踪订阅 repo 的 release）
    /// - `GollumEvent`（wiki 编辑）/ `PublicEvent`（私转公）/ `MemberEvent`（协作者变更）：
    ///   信噪比低，第一版不展示
    ///
    /// 任何不在此集合内的 event type 在 `fetchAndPersistEvents` 里直接丢弃，不入库。
    /// 未来要支持新 event 加在这里 + `formatFollowingTitle` 加 case + i18n 加 key 即可。
    nonisolated static let supportedEventTypes: Set<String> = [
        "WatchEvent", "ForkEvent", "PushEvent",
        "IssuesEvent", "PullRequestEvent",
        "CreateEvent", "DiscussionEvent",
    ]

    // MARK: - 数据状态

    private(set) var items: [ActivityItem] = []
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var loadError: String?
    private(set) var lastRefreshedAt: Date?
    private(set) var itemsRevision: Int = 0
    /// P2：切分类时让 `listRowReveal` 走 instant（不 stagger）；排序切换仍为 animated。
    private(set) var skipListRowReveal = false
    /// 后台 filter / dedupe（尤其 `.all`）进行中；UI 应显示骨架屏而非空态。
    private(set) var isApplyingCategoryFilter = false
    /// 当前分类是否还有未上屏的 filtered 行（滚到底加载更多）。
    private(set) var hasMoreItems: Bool = false
    /// 当前已经有可见列表内容。View 层用它区分“后台过滤中但已有首屏”与“真的空白加载中”。
    ///
    /// 约束：不要让 `isApplyingCategoryFilter` 在已有 prime 首屏时重新切回骨架屏，否则
    /// 首次进入 Activity 全部类型会出现“列表出现 → 骨架 → 列表”的二次刷新感。
    var hasVisibleItems: Bool { !items.isEmpty }

    /// 是否已完成至少一次 `publishItems`（含 prime 快路径）。ActivityView 离 weekly 切回时判断要不要 `ensureLoaded`。
    var isAggregateReady: Bool { isAggregateLoaded }

    /// 未按侧边栏分类过滤的完整聚合列表（`makeItems` 输出）。
    /// 切分类只对它做 `filter`，避免重复读库 + 全量 `makeItems`。
    private var allItems: [ActivityItem] = []

    /// 当前分类 filter + sort 后的完整列表；`items` 是其分页切片。
    private var filteredItems: [ActivityItem] = []
    private var visiblePage: Int = 1

    /// 重建 `allItems` 用的原始四路输入；security 后台扫完只增量换 announcements 再重建。
    private var aggregateSnapshot: AggregateSnapshot?

    /// 是否已完成至少一次 `reload` 并成功 `publishItems`。
    private var isAggregateLoaded = false

    /// 当前侧边栏选中的分类（`selectCategory` / `reload` 入口都会更新）。
    private var currentCategory: ActivityCategory = .all

    /// 各分类独立记忆的时间排序（默认 `.newestFirst`）。
    private var timeSortByCategory: [ActivityCategory: ActivityTimeSort] = [:]

    /// 后台 security 扫描任务（可取消；完成后再合并进 `allItems`）。
    private var securityBackgroundTask: Task<Void, Never>?

    /// 切分类后补拉专属网络的 in-flight 任务（测试可 await）。
    private var supplementNetworkTask: Task<Void, Never>?

    /// 分类 filter 缓存；`allItems` 变化时清空。`.all` 去重+排序较重，可预热带入缓存。
    private var filteredItemsCache: [ActivityCategory: [ActivityItem]] = [:]

    /// 进行中的后台 filter；新切分类会 cancel 旧任务。
    private var categoryFilterTask: Task<Void, Never>?

    /// 本会话是否已按「含 events 的分类」跑过 events 网络决策（含 TTL 短路）。
    private var didPrimeEventsNetwork = false

    /// 本会话是否已按「含 announcement 的分类」跑过 blog/security 网络决策。
    private var didPrimeAnnouncementsNetwork = false

    /// `makeItems` 四路输入快照，供 security 后台完成后局部重建。
    private struct AggregateSnapshot {
        var repos: [Repo]
        var releases: [ReleaseTimelineEntry]
        var events: [ActivityEventRecord]
        var announcements: [ActivityAnnouncementRecord]
    }

    /// Security 扫描任务输入。只保留请求和日志需要的字符串，确保 TaskGroup 捕获值可 Sendable。
    private struct SecurityScanJob: Sendable {
        let owner: String
        let repo: String
        let fullName: String
    }

    /// Security Advisory 网络结果草稿。
    ///
    /// 不直接从 TaskGroup 返回 `ActivityAnnouncementRecord`，避免把 GRDB Record 为了并发实现
    /// 细节扩大标注为 Sendable；回到 ViewModel 后再组装持久化 Record。
    private struct SecurityAnnouncementDraft: Sendable {
        let ghsaId: String
        let summary: String
        let description: String?
        let htmlUrl: String?
        let severity: String?
        let publishedAt: String?
        let repoFullName: String
    }

    // MARK: - 依赖

    private let repoRepository: any RepoRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    /// PR-2 改造：原 `releasePoller: ReleasePoller` 替换为闭包注入。
    /// 用闭包而不是协议：① `ReleasePoller` 是 `final class` 没 protocol，
    /// 加 protocol 改动范围超出 PR-2；② 测试只关心「是否被调用」，
    /// 直接注入 `{}` no-op 比 mock 整个 poller 简单 10 倍；③ 与
    /// `currentLoginProvider` / `StarActionService.userIDProvider` 同款 pattern，
    /// AppDependencies 装配时只需 `{ _ = await self.releasePoller.runNow() }` 一行。
    private let releasePollerRunner: @MainActor () async -> Void
    /// PR-2 新增：following events 本地缓存 Repository。
    private let activityEventRepository: any ActivityEventRepositoryProtocol
    /// PR-2 新增：announcement 本地缓存 Repository（PR-2 阶段表为空，PR-3 RSS 接入后开始有数据）。
    private let activityAnnouncementRepository: any ActivityAnnouncementRepositoryProtocol
    /// PR-2 新增：activity_sync_state 单行 meta（ETag + lastFetchedAt + lastCleanupAt）。
    private let activitySyncStateRepository: any ActivitySyncStateRepositoryProtocol
    /// PR-2 新增：拉 events 用的 GitHub API client。
    private let apiClient: any GitHubAPIClientProtocol
    /// PR-3 新增：GitHub Blog RSS 客户端（独立 host，不走 api.github.com）。
    private let blogRSSClient: any GitHubBlogRSSAPIProtocol
    /// PR-2 新增：当前登录用户 login 提供者（注入闭包不直接持 AuthSession，
    /// 单测注入 stub `{ "octocat" }` 即可，与 `StarActionService.userIDProvider` 同款）。
    private let currentLoginProvider: @MainActor () -> String?

    /// 当前 in-flight 的 reload 任务（切分类 / 重复刷新时取消老任务）。
    private var currentReloadTask: Task<Void, Never>?

    // MARK: - 初始化

    init(
        repoRepository: any RepoRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        releasePollerRunner: @escaping @MainActor () async -> Void,
        activityEventRepository: any ActivityEventRepositoryProtocol,
        activityAnnouncementRepository: any ActivityAnnouncementRepositoryProtocol,
        activitySyncStateRepository: any ActivitySyncStateRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol,
        blogRSSClient: any GitHubBlogRSSAPIProtocol,
        currentLoginProvider: @escaping @MainActor () -> String?
    ) {
        self.repoRepository = repoRepository
        self.releaseRepository = releaseRepository
        self.releasePollerRunner = releasePollerRunner
        self.activityEventRepository = activityEventRepository
        self.activityAnnouncementRepository = activityAnnouncementRepository
        self.activitySyncStateRepository = activitySyncStateRepository
        self.apiClient = apiClient
        self.blogRSSClient = blogRSSClient
        self.currentLoginProvider = currentLoginProvider
    }

    // MARK: - Public Actions

    /// 进入 Activity 页：首次全量 reload；已加载过则只切分类 filter。
    func ensureLoaded(category: ActivityCategory) async {
        currentCategory = category
        if isAggregateLoaded {
            markCategorySwitchForListReveal()
            applyCategoryFilter(category, bumpRevision: false)
            return
        }
        isLoading = true
        await primeCategoryCacheIfAvailable(for: category)
        await reload(category: category, shouldPollReleases: false, cachePolicy: .respectTTL)
    }

    /// 滚到底加载下一页（纯本地切片，零网络）。
    func loadMoreIfNeeded() {
        guard hasMoreItems, !isLoading, !isApplyingCategoryFilter else { return }
        visiblePage += 1
        items = paginatedSlice(from: filteredItems, page: visiblePage)
        hasMoreItems = filteredItems.count > items.count
    }

    /// 倒数第 3 行触发加载更多（对齐 Weekly）。
    func shouldTriggerLoadMore(at index: Int) -> Bool {
        guard hasMoreItems, !isLoading else { return false }
        let threshold = max(items.count - 3, 0)
        return index >= threshold
    }

    /// `ForEach(items)` 路径下的 loadMore 触发（按 item 查下标）。
    func shouldTriggerLoadMore(for item: ActivityItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return false }
        return shouldTriggerLoadMore(at: index)
    }

    /// 指定分类的时间排序（各分类独立记忆，默认最新优先）。
    func timeSort(for category: ActivityCategory) -> ActivityTimeSort {
        guard category.showsActivityFilterBar else { return .newestFirst }
        return timeSortByCategory[category] ?? .newestFirst
    }

    /// 切换当前分类排序：纯本地 refilter，零网络。
    func changeTimeSort(to sort: ActivityTimeSort) {
        guard currentCategory.showsActivityFilterBar else { return }
        guard sort != timeSort(for: currentCategory) else { return }
        skipListRowReveal = false
        timeSortByCategory[currentCategory] = sort
        filteredItemsCache.removeValue(forKey: currentCategory)
        applyCategoryFilter(currentCategory, bumpRevision: true)
    }

    /// 清空关注分类本地缓存（`activity_events` 全表删除 + 重建聚合列表）。
    func clearFollowingFeed() async {
        do {
            try await activityEventRepository.clearAll()
        } catch {
            AppLog.database.warning(
                "Activity following clear failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        if var snapshot = aggregateSnapshot {
            snapshot.events = []
            let items = await buildItems(from: snapshot, reason: "clearFollowing")
            publishItems(from: items, snapshot: snapshot)
        } else {
            allItems.removeAll { $0.kind == .following }
            filteredItemsCache.removeAll()
            applyCategoryFilter(currentCategory, bumpRevision: true)
        }
        loadError = nil
    }

    /// 清空公告分类本地缓存（`activity_announcements` 全表删除 + 重建聚合列表）。
    ///
    /// 清空后若表内无真实公告，`makeItems` 会回退显示内置占位 `announcement:activity-v1`。
    func clearAnnouncementFeed() async {
        do {
            try await activityAnnouncementRepository.clearAll()
        } catch {
            AppLog.database.warning(
                "Activity announcement clear failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        if var snapshot = aggregateSnapshot {
            snapshot.announcements = []
            let items = await buildItems(from: snapshot, reason: "clearAnnouncement")
            publishItems(from: items, snapshot: snapshot)
        } else {
            allItems.removeAll { $0.kind == .announcement }
            filteredItemsCache.removeAll()
            applyCategoryFilter(currentCategory, bumpRevision: true)
        }
        loadError = nil
    }

    /// 侧边栏切分类：只 refilter `allItems`；若该分类专属网络尚未拉过则后台补拉。
    ///
    /// **性能约束（HOM-46 同款）**：切分类走 `applyCategoryFilter(bumpRevision: false)`，
    /// 不因可见 ID 变化 bump `itemsRevision`，避免 30 行 `listRowReveal` stagger 占满主线程。
    func selectCategory(_ category: ActivityCategory) {
        currentCategory = category
        markCategorySwitchForListReveal()
        categoryFilterTask?.cancel()
        if isAggregateLoaded || !allItems.isEmpty {
            applyCategoryFilter(category, bumpRevision: false)
        }
        if items.isEmpty, !isAggregateLoaded {
            isLoading = true
            Task { @MainActor in await self.primeCategoryCacheIfAvailable(for: category) }
        }
        guard isAggregateLoaded else { return }

        let missingEvents = Self.needsEventsNetwork(for: category) && !didPrimeEventsNetwork
        let missingAnnouncements = Self.needsAnnouncementsNetwork(for: category) && !didPrimeAnnouncementsNetwork
        guard missingEvents || missingAnnouncements else { return }

        supplementNetworkTask = Task { @MainActor [weak self] in
            await self?.supplementNetworks(for: category, cachePolicy: .respectTTL)
        }
    }

    /// 进入页面入口（保留给测试 / 外部直调）：等同 `ensureLoaded`。
    func load(category: ActivityCategory) async {
        await ensureLoaded(category: category)
    }

    /// 用户主动刷新（toolbar 按钮）：强制走当前分类相关网络 + Release 巡检。
    func refresh(category: ActivityCategory) async {
        currentCategory = category
        await reload(category: category, shouldPollReleases: true, cachePolicy: .forceNetwork)
    }

    /// 测试专用：等待后台 supplement / security 扫描结束（避免 flaky）。
    func awaitPendingBackgroundWorkForTesting() async {
        await supplementNetworkTask?.value
        await securityBackgroundTask?.value
        await categoryFilterTask?.value
    }

    /// SWR 核心入口（PR-2 重构，复刻 `TrendingViewModel.reload` 同款套路）。
    ///
    /// 行为矩阵：
    /// | 入口 | cachePolicy | 缓存空 | 缓存有 + TTL 内 | 缓存有 + TTL 过期 |
    /// |------|-------------|--------|------------------|---------------------|
    /// | 进入页面 (.task) | .respectTTL | 走网络 + isLoading | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
    /// | 切分类 | `selectCategory` | — | 只 refilter allItems | 只 refilter | 零网络 |
    /// | 主动刷新按钮 | .forceNetwork | 走网络 + isLoading | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
    ///
    /// SWR 关键约束：
    /// - 缓存命中 + `.respectTTL` + TTL 内 → **完全不走 events 网络**（2h 内零打扰）
    /// - 4 路本地（repos / releases / events / announcements）任一失败不影响其它路
    /// - events 网络失败 + 有缓存 → 保留已显示，仅 log（loadError 不动以免与 Release poller 错误串）
    /// - events 网络失败 + 无缓存 → loadError 显示，UI 空状态
    func reload(category: ActivityCategory, shouldPollReleases: Bool, cachePolicy: ActivityCachePolicy) async {
        currentCategory = category
        currentReloadTask?.cancel()
        isLoading = true

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.isRefreshing = false
            }

            // ① 读 sync_state，先把 lastRefreshedAt 顶到 UI（toolbar 新鲜度提示首屏可见）
            let initialSyncState = try? await self.activitySyncStateRepository.current()
            if let timestamp = initialSyncState?.lastEventsFetchedAt,
               let date = Self.parseDate(timestamp)
            {
                self.lastRefreshedAt = date
            }
            guard !Task.isCancelled else { return }

            // ② 第一阶段：本地 4 路并行读。
            //
            // `.all` 的 repo 类卡片最终只消费 `primeStarredLimit` 条近期 starred repo
            // （见 `reposForItemAssembly`）。首次切入 Activity All 时继续全表读取只会拖慢
            // 本地阶段，并且通常组装出与 prime 快路径相同的首屏，造成无意义二次发布。
            async let cachedReposTask = category == .all
                ? self.repoRepository.fetchRecentStarred(limit: Self.primeStarredLimit)
                : self.repoRepository.fetchAllStarred()
            async let cachedReleasesTask = self.releaseRepository.fetchTimeline(limit: 120)
            async let cachedEventsTask = self.activityEventRepository.fetchAll(limit: 200)
            async let cachedAnnouncementsTask = self.activityAnnouncementRepository.fetchAll(limit: 100)
            let cachedRepos = (try? await cachedReposTask) ?? []
            let cachedReleases = (try? await cachedReleasesTask) ?? []
            let cachedEvents = (try? await cachedEventsTask) ?? []
            let cachedAnnouncements = (try? await cachedAnnouncementsTask) ?? []
            guard !Task.isCancelled else { return }

            let hasUsableCache = !(cachedRepos.isEmpty && cachedReleases.isEmpty
                && cachedEvents.isEmpty && cachedAnnouncements.isEmpty)

            var snapshot = AggregateSnapshot(
                repos: cachedRepos,
                releases: cachedReleases,
                events: cachedEvents,
                announcements: cachedAnnouncements
            )
            let cachedItems = await self.buildItems(from: snapshot, reason: "reload.cached")
            self.publishItemsIfChanged(from: cachedItems, snapshot: snapshot)
            self.loadError = nil
            self.isLoading = !hasUsableCache

            // ③ 按当前分类裁剪网络（避免看「关注」时扫 200 个 security）
            let shouldFetchEvents = Self.needsEventsNetwork(for: category)
                && Self.shouldFetchEvents(cachePolicy: cachePolicy, syncState: initialSyncState)
            let shouldFetchBlog = Self.needsAnnouncementsNetwork(for: category)
                && Self.shouldFetchBlogRSS(cachePolicy: cachePolicy, syncState: initialSyncState)
            let shouldFetchSecurity = Self.needsAnnouncementsNetwork(for: category)
                && Self.shouldFetchSecurityAdvisories(cachePolicy: cachePolicy, syncState: initialSyncState)
            let willScheduleSecurityInBackground = shouldFetchSecurity

            if Self.needsEventsNetwork(for: category) {
                didPrimeEventsNetwork = true
            }
            if Self.needsAnnouncementsNetwork(for: category) {
                didPrimeAnnouncementsNetwork = true
            }

            if hasUsableCache && (shouldFetchEvents || shouldFetchBlog || willScheduleSecurityInBackground || shouldPollReleases) {
                self.isRefreshing = true
            }

            // ④ Release 巡检（v1 已有逻辑保留）
            if shouldPollReleases {
                await self.releasePollerRunner()
            }
            guard !Task.isCancelled else { return }

            // ⑤ 前台网络：events + blog（security 走后台，不阻塞本路径）
            var didMutateAggregate = false

            if shouldFetchEvents, let login = self.currentLoginProvider() {
                let result = await self.fetchAndPersistEvents(
                    login: login,
                    etag: initialSyncState?.eventsEtag
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .updated:
                    self.lastRefreshedAt = Date()
                    snapshot.events = (try? await self.activityEventRepository.fetchAll(limit: 200)) ?? snapshot.events
                    didMutateAggregate = true
                case .notModified:
                    self.lastRefreshedAt = Date()
                case .failed(let error):
                    self.recordEventsLoadError(error, category: category, snapshot: snapshot)
                }
            }

            if shouldFetchBlog {
                let result = await self.fetchAndPersistBlogRSS(etag: initialSyncState?.blogRssEtag)
                guard !Task.isCancelled else { return }
                switch result {
                case .updated, .notModified:
                    snapshot.announcements = (try? await self.activityAnnouncementRepository.fetchAll(limit: 100))
                        ?? snapshot.announcements
                    didMutateAggregate = true
                case .failed(let error):
                    AppLog.network.warning(
                        "Activity blog RSS refresh failed: \(error.localizedDescription, privacy: .public)"
                    )
                    let friendly = UserFacingError.map(
                        error,
                        operation: String.l10n("diagnostics.operation.loadActivityAnnouncements"),
                        service: "GitHub Blog"
                    )
                    friendly.record(level: .warning, category: "activity", operation: "blogRSS.refresh", service: "github-blog")
                }
            }

            if shouldFetchSecurity {
                self.scheduleSecurityScan(repos: cachedRepos)
            }

            // ⑥ 前台路径有数据变化 → 重组装；Release 巡检也可能写入新 release
            if didMutateAggregate || shouldPollReleases {
                if shouldPollReleases {
                    snapshot.releases = (try? await self.releaseRepository.fetchTimeline(limit: 120)) ?? snapshot.releases
                }
                guard !Task.isCancelled else { return }
                let refreshedItems = await self.buildItems(from: snapshot, reason: "reload.refreshed")
                self.publishItemsIfChanged(from: refreshedItems, snapshot: snapshot)
            }

            // ⑦ 后台清理（≥ 24h 触发，detached Task 不阻塞主路径）
            Task.detached(priority: .background) { [weak self] in
                await self?.cleanupIfNeeded()
            }
        }

        currentReloadTask = task
        await task.value
    }

    // MARK: - 分类切换 / 聚合发布

    /// 分类首屏快路径：LIMIT 读库 + 局部 snapshot，不等 `fetchAllStarred` 全表。
    private func primeCategoryCacheIfAvailable(for category: ActivityCategory) async {
        switch category {
        case .weekly:
            return
        case .announcement:
            await primeAnnouncementCacheIfAvailable()
        case .following:
            await primeFollowingCacheIfAvailable()
        case .release:
            let releases = (try? await releaseRepository.fetchTimeline(limit: 120)) ?? []
            guard !releases.isEmpty else { return }
            await publishPrimeSnapshot(AggregateSnapshot(
                repos: aggregateSnapshot?.repos ?? [],
                releases: releases,
                events: aggregateSnapshot?.events ?? [],
                announcements: aggregateSnapshot?.announcements ?? []
            ))
        case .star, .repository, .suggestion:
            let repos = (try? await repoRepository.fetchRecentStarred(limit: Self.primeStarredLimit)) ?? []
            guard !repos.isEmpty else { return }
            await publishPrimeSnapshot(AggregateSnapshot(
                repos: repos,
                releases: aggregateSnapshot?.releases ?? [],
                events: aggregateSnapshot?.events ?? [],
                announcements: aggregateSnapshot?.announcements ?? []
            ))
        case .all:
            async let reposTask = repoRepository.fetchRecentStarred(limit: Self.primeStarredLimit)
            async let releasesTask = releaseRepository.fetchTimeline(limit: 120)
            async let eventsTask = activityEventRepository.fetchAll(limit: 200)
            async let announcementsTask = activityAnnouncementRepository.fetchAll(limit: 100)
            let repos = (try? await reposTask) ?? []
            let releases = (try? await releasesTask) ?? []
            let events = (try? await eventsTask) ?? []
            let announcements = (try? await announcementsTask) ?? []
            guard !(repos.isEmpty && releases.isEmpty && events.isEmpty && announcements.isEmpty) else {
                return
            }
            await publishPrimeSnapshot(AggregateSnapshot(
                repos: repos,
                releases: releases,
                events: events,
                announcements: announcements
            ))
        }
    }

    /// prime 快路径上屏：与 `publishItems` 相同，但额外清 `isLoading` 让骨架屏立刻消失。
    private func publishPrimeSnapshot(_ snapshot: AggregateSnapshot) async {
        let items = await buildItems(from: snapshot, reason: "prime")
        publishItems(from: items, snapshot: snapshot)
        isLoading = false
    }

    /// 公告分类首屏快路径：只读 `activity_announcements`，不等 starred repos 全表扫描。
    private func primeAnnouncementCacheIfAvailable() async {
        let cachedAnnouncements = (try? await activityAnnouncementRepository.fetchAll(limit: 100)) ?? []
        guard !cachedAnnouncements.isEmpty else { return }

        let snapshot = AggregateSnapshot(
            repos: aggregateSnapshot?.repos ?? [],
            releases: aggregateSnapshot?.releases ?? [],
            events: aggregateSnapshot?.events ?? [],
            announcements: cachedAnnouncements
        )
        let items = await buildItems(from: snapshot, reason: "prime.announcement")
        publishItems(from: items, snapshot: snapshot)
        isLoading = false
    }

    /// 关注分类首屏快路径：只读 `activity_events`，不等 starred repos 全表扫描。
    private func primeFollowingCacheIfAvailable() async {
        let cachedEvents = (try? await activityEventRepository.fetchAll(limit: 200)) ?? []
        guard !cachedEvents.isEmpty else { return }

        let snapshot = AggregateSnapshot(
            repos: aggregateSnapshot?.repos ?? [],
            releases: aggregateSnapshot?.releases ?? [],
            events: cachedEvents,
            announcements: aggregateSnapshot?.announcements ?? []
        )
        let items = await buildItems(from: snapshot, reason: "prime.following")
        publishItems(from: items, snapshot: snapshot)
        isLoading = false
    }

    /// 切分类后补拉尚未 prime 的网络（不取消 in-flight reload、不重建本地四路读）。
    private func supplementNetworks(for category: ActivityCategory, cachePolicy: ActivityCachePolicy) async {
        guard var snapshot = aggregateSnapshot else { return }

        let syncState = try? await activitySyncStateRepository.current()
        let shouldFetchEvents = Self.needsEventsNetwork(for: category)
            && Self.shouldFetchEvents(cachePolicy: cachePolicy, syncState: syncState)
        let shouldFetchBlog = Self.needsAnnouncementsNetwork(for: category)
            && Self.shouldFetchBlogRSS(cachePolicy: cachePolicy, syncState: syncState)
        let shouldFetchSecurity = Self.needsAnnouncementsNetwork(for: category)
            && Self.shouldFetchSecurityAdvisories(cachePolicy: cachePolicy, syncState: syncState)

        if Self.needsEventsNetwork(for: category) {
            didPrimeEventsNetwork = true
        }
        if Self.needsAnnouncementsNetwork(for: category) {
            didPrimeAnnouncementsNetwork = true
        }

        guard shouldFetchEvents || shouldFetchBlog || shouldFetchSecurity else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var didMutateAggregate = false

        if shouldFetchEvents, let login = currentLoginProvider() {
            let result = await fetchAndPersistEvents(login: login, etag: syncState?.eventsEtag)
            switch result {
            case .updated:
                lastRefreshedAt = Date()
                snapshot.events = (try? await activityEventRepository.fetchAll(limit: 200)) ?? snapshot.events
                didMutateAggregate = true
            case .notModified:
                lastRefreshedAt = Date()
            case .failed(let error):
                recordEventsLoadError(error, category: category, snapshot: snapshot)
            }
        }

        if shouldFetchBlog {
            let result = await fetchAndPersistBlogRSS(etag: syncState?.blogRssEtag)
            switch result {
            case .updated, .notModified:
                snapshot.announcements = (try? await activityAnnouncementRepository.fetchAll(limit: 100))
                    ?? snapshot.announcements
                didMutateAggregate = true
            case .failed(let error):
                AppLog.network.warning(
                    "Activity blog RSS supplement failed: \(error.localizedDescription, privacy: .public)"
                )
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("diagnostics.operation.loadActivityAnnouncements"),
                    service: "GitHub Blog"
                )
                friendly.record(level: .warning, category: "activity", operation: "blogRSS.supplement", service: "github-blog")
            }
        }

        if shouldFetchSecurity {
            scheduleSecurityScan(repos: snapshot.repos)
        }

        if didMutateAggregate {
            let items = await buildItems(from: snapshot, reason: "supplement")
            publishItemsIfChanged(from: items, snapshot: snapshot)
        }
    }

    /// **性能约束（HOM-46 同款 + 2026-06-17 修订）**：
    /// - `selectCategory` 走 `bumpRevision: false` + 默认 `resetPage: true` 时，
    ///   **禁止**因可见 ID 变化而 bump `itemsRevision`——否则 30 行 `listRowReveal`
    ///   同时 stagger，主线程卡顿会连带 sidebar 蛇动画掉帧。
    /// - 排序切换等仍用 `bumpRevision: true` 保留 reveal。
    ///
    /// **`.all` 专项（2026-06-17）**：去重+全量排序走 `Task.detached`，避免主线程彩虹圈；
    /// 命中 `filteredItemsCache` 时同步上屏。
    private func applyCategoryFilter(
        _ category: ActivityCategory,
        bumpRevision: Bool,
        resetPage: Bool = true
    ) {
        if let cached = filteredItemsCache[category] {
            commitFilteredSlice(from: cached, bumpRevision: bumpRevision, resetPage: resetPage)
            return
        }

        let source = allItems
        guard !source.isEmpty else {
            commitFilteredSlice(from: [], bumpRevision: bumpRevision, resetPage: resetPage)
            return
        }

        let sort = timeSort(for: category)
        let needsAsyncFilter = category == .all || source.count > Self.asyncFilterItemThreshold

        if !needsAsyncFilter {
            let filtered = Self.computeFilteredItems(source: source, category: category, timeSort: sort)
            filteredItemsCache[category] = filtered
            commitFilteredSlice(from: filtered, bumpRevision: bumpRevision, resetPage: resetPage)
            return
        }

        isApplyingCategoryFilter = true
        categoryFilterTask?.cancel()
        categoryFilterTask = Task { @MainActor [weak self] in
            let filtered = await Task.detached(priority: .userInitiated) {
                Self.computeFilteredItems(source: source, category: category, timeSort: sort)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard self.currentCategory == category else {
                self.isApplyingCategoryFilter = false
                return
            }
            self.filteredItemsCache[category] = filtered
            self.commitFilteredSlice(from: filtered, bumpRevision: bumpRevision, resetPage: resetPage)
            self.isApplyingCategoryFilter = false
        }
    }

    private func commitFilteredSlice(
        from filtered: [ActivityItem],
        bumpRevision: Bool,
        resetPage: Bool = true
    ) {
        filteredItems = filtered
        if resetPage {
            visiblePage = 1
        }
        let slice = paginatedSlice(from: filteredItems, page: visiblePage)
        let oldIDs = items.map(\.id)
        items = slice
        hasMoreItems = filteredItems.count > slice.count
        if bumpRevision {
            itemsRevision += 1
        } else if !resetPage && oldIDs != slice.map(\.id) {
            itemsRevision += 1
        }
    }

    /// 后台预热分类 filter 缓存（不阻塞 UI）。
    private func prewarmFilterCache(for category: ActivityCategory) {
        guard filteredItemsCache[category] == nil else { return }
        let source = allItems
        guard !source.isEmpty else { return }
        let sort = timeSort(for: category)
        Task.detached(priority: .utility) { [source, category, sort] in
            let filtered = Self.computeFilteredItems(source: source, category: category, timeSort: sort)
            await MainActor.run { [weak self] in
                guard let self, self.filteredItemsCache[category] == nil else { return }
                self.filteredItemsCache[category] = filtered
            }
        }
    }

    private func applyFilterForCurrentCategory(bumpRevision: Bool, resetPage: Bool = true) {
        applyCategoryFilter(currentCategory, bumpRevision: bumpRevision, resetPage: resetPage)
    }

    private func paginatedSlice(from source: [ActivityItem], page: Int) -> [ActivityItem] {
        let upper = min(page * Self.pageSize, source.count)
        return Array(source.prefix(upper))
    }

    /// 切分类后本帧 List 行 instant 显示；下一 run loop 恢复，loadMore 新行仍可 reveal。
    private func markCategorySwitchForListReveal() {
        skipListRowReveal = true
        DispatchQueue.main.async { [weak self] in
            self?.skipListRowReveal = false
        }
    }

    private func publishItems(from source: [ActivityItem], snapshot: AggregateSnapshot? = nil) {
        allItems = source
        if let snapshot {
            aggregateSnapshot = snapshot
        }
        isAggregateLoaded = true
        filteredItemsCache.removeAll()
        categoryFilterTask?.cancel()
        isApplyingCategoryFilter = false

        // `.all` 的去重 + 排序在数据多时会明显占用 CPU。这里必须复用
        // `applyCategoryFilter` 的后台分支，不能在 publish 阶段直接同步调用
        // `computeFilteredItems`，否则首次从 Manage / Trending 切进 Activity All
        // 会绕过 v3.1 的主线程保护并造成卡顿。
        applyCategoryFilter(currentCategory, bumpRevision: false, resetPage: true)

        if currentCategory != .all {
            prewarmFilterCache(for: .all)
        }
    }

    /// 发布前做轻量 fingerprint 判断，避免后台刷新把同一批 Activity 行重复推给 SwiftUI。
    ///
    /// 为什么不用 `ActivityItem ==`：
    /// - 卡顿问题来自“同一批行”反复触发 filter / List 重建，而不是内容字段差异；
    /// - `.all` 内置公告会用 `Date()` 生成时间，做全字段比较会把同一条占位公告误判为变化；
    /// - 真有新增 / 删除 / 换序时 ID 序列会变化，仍走完整发布。
    /// - 同一远端公告 ID 的标题 / 正文变化必须刷新，所以不能只比 ID。
    ///
    /// 即便跳过 UI 发布，也要更新 `aggregateSnapshot`，让后续 security / blog 合并基于最新
    /// 原始输入，不因为 no-op 优化丢失后台状态。
    private func publishItemsIfChanged(from source: [ActivityItem], snapshot: AggregateSnapshot? = nil) {
        if let snapshot {
            aggregateSnapshot = snapshot
        }
        let oldFingerprint = allItems.map(Self.publishFingerprint)
        let newFingerprint = source.map(Self.publishFingerprint)
        guard oldFingerprint != newFingerprint else {
            isAggregateLoaded = true
            return
        }
        publishItems(from: source, snapshot: snapshot)
    }

    private nonisolated static func publishFingerprint(for item: ActivityItem) -> String {
        let createdAt: String
        if item.id == "announcement:activity-v1" {
            // 内置占位公告的 Date 只用于排序，不代表业务内容变化；忽略它才能让 no-op
            // 判断稳定，避免 Activity All 首次进入后被同一占位公告反复重发。
            createdAt = ""
        } else {
            createdAt = item.createdAt.map { String($0.timeIntervalSince1970) } ?? ""
        }
        let subtitle = item.subtitle ?? ""
        let body = item.body ?? ""
        let readState = item.isRead ? "read" : "unread"
        let repoID = item.repo.map { String($0.id) } ?? ""
        let releaseID = item.release.map { String($0.id) } ?? ""
        let releaseCount = String(item.releases.count)
        let parts: [String] = [
            item.id, item.title, subtitle, body, createdAt,
            readState, repoID, releaseID, releaseCount
        ]
        return parts.joined(separator: "|")
    }

    /// Activity row 组装包含排序、payload JSON 解析、HTML 摘要提取和本地化格式化。
    /// 这些操作单次数量不大，但在页面切换首帧跑在 MainActor 上会直接造成彩虹圈；
    /// 所以所有发布前的组装统一从这里进入后台任务，主线程只做最终数组赋值和 SwiftUI diff。
    private func buildItems(from snapshot: AggregateSnapshot, reason: String) async -> [ActivityItem] {
        #if DEBUG
        let start = ContinuousClock.now
        #endif

        let items = await Task.detached(priority: .userInitiated) {
            Self.makeItems(snapshot: snapshot)
        }.value

        #if DEBUG
        let duration = start.duration(to: ContinuousClock.now)
        AppLog.ui.debug(
            "Activity makeItems[\(reason, privacy: .public)] repos=\(snapshot.repos.count, privacy: .public) releases=\(snapshot.releases.count, privacy: .public) events=\(snapshot.events.count, privacy: .public) announcements=\(snapshot.announcements.count, privacy: .public) items=\(items.count, privacy: .public) elapsed=\(String(describing: duration), privacy: .public)"
        )
        #endif

        return items
    }

    private nonisolated static func makeItems(snapshot: AggregateSnapshot) -> [ActivityItem] {
        let repos = Self.reposForItemAssembly(snapshot.repos)
        return makeItems(
            repos: repos,
            releases: snapshot.releases,
            events: snapshot.events,
            announcements: snapshot.announcements
        )
    }

    /// events 失败时：无 following 可展示则给当前分类可见的错误（不再静默吞掉）。
    private func recordEventsLoadError(_ error: Error, category: ActivityCategory, snapshot: AggregateSnapshot) {
        let followingCount = Self.makeFollowingItems(snapshot.events).count
        let shouldSurface = (category == .following || category == .all) && followingCount == 0
        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.loadActivity"),
            service: "GitHub"
        )
        if shouldSurface {
            loadError = friendly.message
        } else {
            AppLog.network.warning(
                "Activity events refresh failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        friendly.record(level: shouldSurface ? .error : .warning, category: "activity", operation: "events.refresh", service: "github")
    }

    /// Security 扫描放后台：最多 200 个串行 API，不能挡切分类 / 首屏。
    private func scheduleSecurityScan(repos: [Repo]) {
        securityBackgroundTask?.cancel()
        isRefreshing = true
        securityBackgroundTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRefreshing = false }
            let result = await self.fetchAndPersistSecurityAdvisories(repos: repos)
            guard !Task.isCancelled else { return }
            await self.integrateSecurityScanResult(result)
        }
    }

    private func integrateSecurityScanResult(_ result: AnnouncementFetchResult) async {
        switch result {
        case .updated, .notModified:
            guard var snapshot = aggregateSnapshot else { return }
            snapshot.announcements = (try? await activityAnnouncementRepository.fetchAll(limit: 100))
                ?? snapshot.announcements
            let items = await buildItems(from: snapshot, reason: "security.integrate")
            publishItemsIfChanged(from: items, snapshot: snapshot)
        case .failed(let error):
            AppLog.network.warning(
                "Activity security refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadActivitySecurity"),
                service: "GitHub"
            )
            friendly.record(level: .warning, category: "activity", operation: "security.refresh", service: "github")
        }
    }

    /// 当前分类是否需要 events 网络。
    nonisolated static func needsEventsNetwork(for category: ActivityCategory) -> Bool {
        category == .all || category == .following
    }

    /// 当前分类是否需要 announcement 网络（blog + security）。
    nonisolated static func needsAnnouncementsNetwork(for category: ActivityCategory) -> Bool {
        category == .all || category == .announcement
    }

    // MARK: - Events 网络获取（PR-2，2026-06-16）

    /// events 网络拉取的三种结果。
    enum EventsFetchResult {
        /// 200 OK：拿到新数据已写库 + 更新 sync_state。
        case updated
        /// 304 Not Modified：服务端未变化，已 touch `last_events_fetched_at`。
        case notModified
        /// 其它失败（401 / 403 / 5xx / transport）。
        case failed(Error)
    }

    /// 真正发起 `GET /users/{login}/received_events/public` + 落库的实现。
    ///
    /// **过滤约束**（与 `supportedEventTypes` 配套）：
    /// 1. `ReleaseEvent` 在此处显式丢弃（决策 Q1）
    /// 2. 不在 `supportedEventTypes` 内的 type 也丢弃（信噪比低，避免空文案行）
    /// 3. 余下的事件 batch upsert 进 `activity_events`，保留 `is_read` 不被覆盖
    ///
    /// **304 处理**：通过 `NetworkError.notModified(etag:)` 短路。即便 etag 一字不差，
    /// 也要 touch `last_events_fetched_at`，否则 TTL 会一直显示"很久没刷新"。
    ///
    /// **网络失败**：sync_state 一律不动（保留旧 etag），下次 reload 可以重试 304 短路。
    private func fetchAndPersistEvents(login: String, etag: String?) async -> EventsFetchResult {
        do {
            let response = try await apiClient.receivedEvents(
                username: login,
                perPage: 100,
                ifNoneMatch: etag
            )

            let now = Date()
            let nowISO = Self.isoString(now)

            // 过滤 + 转 record
            let records = response.value
                .filter { Self.supportedEventTypes.contains($0.type) }
                .map { dto in
                    ActivityEventRecord(
                        id: dto.id,
                        eventType: dto.type,
                        actorLogin: dto.actor.login,
                        actorAvatarUrl: dto.actor.avatarUrl,
                        repoName: dto.repo.name,
                        repoId: dto.repo.id,
                        payloadJson: dto.payloadJson,
                        isRead: false,
                        createdAt: dto.createdAt,
                        fetchedAt: nowISO
                    )
                }

            if !records.isEmpty {
                try await activityEventRepository.upsertMany(records)
            }
            try await activitySyncStateRepository.updateEvents(etag: response.etag, lastFetchedAt: now)
            AppLog.network.info(
                "Activity events refreshed: kept=\(records.count, privacy: .public)/total=\(response.value.count, privacy: .public)"
            )
            return .updated

        } catch NetworkError.notModified(let receivedEtag) {
            // 304 短路：touch lastFetchedAt（保留 etag —— GitHub 偶尔返回更新版本号，原样存）
            do {
                try await activitySyncStateRepository.updateEvents(
                    etag: receivedEtag ?? etag,
                    lastFetchedAt: Date()
                )
            } catch {
                AppLog.network.warning(
                    "Activity sync_state touch after 304 failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .notModified

        } catch {
            return .failed(error)
        }
    }

    /// 决定是否走 events 网络（policy + TTL 双重判定）。
    nonisolated static func shouldFetchEvents(
        cachePolicy: ActivityCachePolicy,
        syncState: ActivitySyncStateRecord?
    ) -> Bool {
        switch cachePolicy {
        case .forceNetwork:
            return true
        case .respectTTL:
            guard let timestamp = syncState?.lastEventsFetchedAt,
                  let last = parseDate(timestamp)
            else {
                return true // 没刷新过 → 必拉
            }
            return Date().timeIntervalSince(last) > eventsTTL
        }
    }

    // MARK: - Announcement 网络获取（PR-3，2026-06-17）

    /// announcement 网络拉取结果（blog / security 共用三态）。
    enum AnnouncementFetchResult {
        case updated
        case notModified
        case failed(Error)
    }

    /// Blog RSS 拉取 + 落库。ETag 存 `activity_sync_state.blog_rss_etag`。
    private func fetchAndPersistBlogRSS(etag: String?) async -> AnnouncementFetchResult {
        do {
            let response = try await blogRSSClient.fetchFeed(ifNoneMatch: etag)
            let now = Date()
            let nowISO = Self.isoString(now)

            let records = response.value.map { dto -> ActivityAnnouncementRecord in
                let bodyHTML = dto.contentHTML ?? dto.descriptionHTML
                let createdAtISO = Self.parseRFC2822Date(dto.pubDate).map(Self.isoString)
                    ?? nowISO
                return ActivityAnnouncementRecord(
                    id: AnnouncementSource.blog.makeId(nativeId: dto.guid),
                    source: AnnouncementSource.blog.rawValue,
                    title: dto.title,
                    bodyMarkdown: bodyHTML,
                    author: dto.author,
                    url: dto.link,
                    repoName: nil,
                    categories: AnnouncementCategoriesCodec.encode(dto.categories),
                    isRead: false,
                    createdAt: createdAtISO,
                    fetchedAt: nowISO
                )
            }

            if !records.isEmpty {
                try await activityAnnouncementRepository.upsertMany(records)
            }
            try await activitySyncStateRepository.updateBlogRss(etag: response.etag, lastFetchedAt: now)
            AppLog.network.info("Activity blog RSS refreshed: count=\(records.count, privacy: .public)")
            return .updated

        } catch NetworkError.notModified(let receivedEtag) {
            do {
                try await activitySyncStateRepository.updateBlogRss(
                    etag: receivedEtag ?? etag,
                    lastFetchedAt: Date()
                )
            } catch {
                AppLog.network.warning(
                    "Activity blog sync_state touch after 304 failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .notModified

        } catch {
            return .failed(error)
        }
    }

    /// Security Advisory 批量扫描 + 落库。无 per-repo ETag，只 touch `last_security_fetched_at`。
    ///
    /// **范围收窄**：`is_starred = 1` 且 `pushed_at >= now - 30 days`，上限 200 repo。
    /// 单 repo 404 / 403 静默跳过，不阻断整批。
    private func fetchAndPersistSecurityAdvisories(repos: [Repo]) async -> AnnouncementFetchResult {
        let candidates = Self.starredReposRecentlyPushed(repos: repos)
        guard !candidates.isEmpty else {
            do {
                try await activitySyncStateRepository.updateSecurity(lastFetchedAt: Date())
            } catch {
                AppLog.network.warning(
                    "Activity security touch (empty scan) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return .updated
        }

        let now = Date()
        let nowISO = Self.isoString(now)
        let jobs = candidates.compactMap(Self.makeSecurityScanJob(repo:))
        let drafts = await fetchSecurityAnnouncementDrafts(
            jobs: jobs,
            concurrencyLimit: securityScanConcurrency
        )
        let allRecords = drafts.map { draft -> ActivityAnnouncementRecord in
            ActivityAnnouncementRecord(
                id: AnnouncementSource.security.makeId(nativeId: draft.ghsaId),
                source: AnnouncementSource.security.rawValue,
                title: draft.summary,
                bodyMarkdown: draft.description,
                author: nil,
                url: draft.htmlUrl ?? "https://github.com/advisories/\(draft.ghsaId)",
                repoName: draft.repoFullName,
                categories: draft.severity.map { AnnouncementCategoriesCodec.encode([$0]) } ?? nil,
                isRead: false,
                createdAt: draft.publishedAt ?? nowISO,
                fetchedAt: nowISO
            )
        }

        do {
            if !allRecords.isEmpty {
                try await activityAnnouncementRepository.upsertMany(allRecords)
            }
            try await activitySyncStateRepository.updateSecurity(lastFetchedAt: now)
            AppLog.network.info(
                "Activity security refreshed: repos=\(jobs.count, privacy: .public), advisories=\(allRecords.count, privacy: .public)"
            )
            return .updated
        } catch {
            return .failed(error)
        }
    }

    private static func makeSecurityScanJob(repo: Repo) -> SecurityScanJob? {
        let parts = repo.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return SecurityScanJob(owner: parts[0], repo: parts[1], fullName: repo.fullName)
    }

    /// 受限并发拉取 Security Advisory 草稿。
    ///
    /// 每个子任务只返回 Sendable 草稿；404/403 与串行旧实现一致静默跳过，其它错误只 log
    /// 后跳过，不影响整批扫描。
    private func fetchSecurityAnnouncementDrafts(
        jobs: [SecurityScanJob],
        concurrencyLimit: Int
    ) async -> [SecurityAnnouncementDraft] {
        guard !jobs.isEmpty else { return [] }
        let apiClient = self.apiClient
        let limit = max(1, concurrencyLimit)

        return await withTaskGroup(of: [SecurityAnnouncementDraft].self) { group in
            var nextIndex = 0

            func scheduleNext() {
                guard nextIndex < jobs.count else { return }
                let job = jobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    await Self.fetchSecurityAnnouncementDrafts(for: job, apiClient: apiClient)
                }
            }

            for _ in 0..<min(limit, jobs.count) {
                scheduleNext()
            }

            var result: [SecurityAnnouncementDraft] = []
            while let batch = await group.next() {
                result.append(contentsOf: batch)
                scheduleNext()
            }
            return result
        }
    }

    nonisolated private static func fetchSecurityAnnouncementDrafts(
        for job: SecurityScanJob,
        apiClient: any GitHubAPIClientProtocol
    ) async -> [SecurityAnnouncementDraft] {
        do {
            let response = try await apiClient.securityAdvisories(owner: job.owner, repo: job.repo)
            return response.value.map { dto in
                SecurityAnnouncementDraft(
                    ghsaId: dto.ghsaId,
                    summary: dto.summary,
                    description: dto.description,
                    htmlUrl: dto.htmlUrl,
                    severity: dto.severity,
                    publishedAt: dto.publishedAt,
                    repoFullName: job.fullName
                )
            }
        } catch NetworkError.notFound {
            return []
        } catch NetworkError.clientError(let code, _) where code == 403 || code == 404 {
            return []
        } catch {
            AppLog.network.warning(
                "Activity security skip \(job.fullName): \(error.localizedDescription, privacy: .public)"
            )
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadActivitySecurity"),
                service: "GitHub"
            )
            friendly.record(
                level: .warning,
                category: "activity",
                operation: "securityAdvisories.fetch",
                service: "github"
            )
            return []
        }
    }

    /// 最近 30 天有 push 的 starred repo，按 pushed_at 倒序，上限 200。
    nonisolated static func starredReposRecentlyPushed(repos: [Repo]) -> [Repo] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(securityLookbackDays * 86_400))
        return repos
            .filter { repo in
                guard repo.isStarred, let pushedAt = parseDate(repo.pushedAt) else { return false }
                return pushedAt >= cutoff
            }
            .sorted { lhs, rhs in
                (parseDate(lhs.pushedAt) ?? .distantPast) > (parseDate(rhs.pushedAt) ?? .distantPast)
            }
            .prefix(securityScanMaxRepos)
            .map { $0 }
    }

    nonisolated static func shouldFetchBlogRSS(
        cachePolicy: ActivityCachePolicy,
        syncState: ActivitySyncStateRecord?
    ) -> Bool {
        switch cachePolicy {
        case .forceNetwork:
            return true
        case .respectTTL:
            guard let timestamp = syncState?.lastBlogFetchedAt,
                  let last = parseDate(timestamp)
            else { return true }
            return Date().timeIntervalSince(last) > announcementsTTL
        }
    }

    nonisolated static func shouldFetchSecurityAdvisories(
        cachePolicy: ActivityCachePolicy,
        syncState: ActivitySyncStateRecord?
    ) -> Bool {
        switch cachePolicy {
        case .forceNetwork:
            return true
        case .respectTTL:
            guard let timestamp = syncState?.lastSecurityFetchedAt,
                  let last = parseDate(timestamp)
            else { return true }
            return Date().timeIntervalSince(last) > announcementsTTL
        }
    }

    // MARK: - 数据清理（PR-2，2026-06-16）

    /// 后台清理：30 天以前的 events / announcements，≥ 24h 触发一次。
    ///
    /// 由 `reload` 末尾 detached Task 派发，**不阻塞主路径**。SQL `DELETE` 走索引
    /// 通常 < 10ms，但本方法仍设计为可重入 + 容错（任何步骤失败仅 warning 记录）。
    ///
    /// **公开方法**（不是 private）：① 测试 target 需要直接调它验证 ≥24h 短路逻辑；
    /// ② 未来 Settings 「清除全部缓存」按钮如果想触发即时清理也能直接调。
    func cleanupIfNeeded() async {
        let now = Date()
        do {
            let syncState = try await activitySyncStateRepository.current()
            if let lastStr = syncState?.lastCleanupAt,
               let last = Self.parseDate(lastStr),
               now.timeIntervalSince(last) < Self.cleanupCooldown
            {
                return // 距上次清理 < 24h，跳过
            }
        } catch {
            AppLog.database.warning(
                "Activity cleanup syncState read failed: \(error.localizedDescription, privacy: .public)"
            )
            // 读 syncState 失败仍继续清理：清理本身幂等，最坏情况就是多删了一次
        }

        let eventsDeleted = (try? await activityEventRepository.deleteOlderThan(days: Self.retentionDays)) ?? 0
        let announcementsDeleted = (try? await activityAnnouncementRepository.deleteOlderThan(days: Self.retentionDays)) ?? 0

        do {
            try await activitySyncStateRepository.updateLastCleanupAt(now)
        } catch {
            AppLog.database.warning(
                "Activity cleanup touch lastCleanupAt failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        if eventsDeleted > 0 || announcementsDeleted > 0 {
            AppLog.database.info(
                "Activity cleanup: events=\(eventsDeleted, privacy: .public), announcements=\(announcementsDeleted, privacy: .public)"
            )
        }
    }

    // MARK: - 视图模型组装

    /// 全表 starred repos 只取近期 `primeStarredLimit` 条参与 star/repo/suggestion 三类 builder，
    /// 避免 `fetchAllStarred` 数千行时在主线程做三次全量 sort。
    nonisolated static func reposForItemAssembly(_ repos: [Repo]) -> [Repo] {
        guard repos.count > primeStarredLimit else { return repos }
        return repos
            .filter { $0.isStarred }
            .sorted { ($0.starredAt ?? "") > ($1.starredAt ?? "") }
            .prefix(primeStarredLimit)
            .map { $0 }
    }

    /// 分类 filter + sort（可在 `Task.detached` 调用，避免 `.all` 去重堵主线程）。
    nonisolated static func computeFilteredItems(
        source: [ActivityItem],
        category: ActivityCategory,
        timeSort: ActivityTimeSort
    ) -> [ActivityItem] {
        let filtered: [ActivityItem]
        if category == .all {
            filtered = deduplicateForAllView(source)
        } else {
            filtered = source.filter { $0.category == category }
        }
        return sortFilteredItems(filtered, timeSort: timeSort)
    }

    private func filter(_ source: [ActivityItem], by category: ActivityCategory) -> [ActivityItem] {
        Self.computeFilteredItems(
            source: source,
            category: category,
            timeSort: timeSort(for: category)
        )
    }

    /// 分类列表最终排序：尊重各分类 `timeSort`（默认最新优先）。
    nonisolated static func sortFilteredItems(
        _ items: [ActivityItem],
        timeSort: ActivityTimeSort
    ) -> [ActivityItem] {
        let ascending = timeSort == .oldestFirst
        return items.sorted { lhs, rhs in
            let l = lhs.createdAt ?? .distantPast
            let r = rhs.createdAt ?? .distantPast
            return ascending ? (l < r) : (l > r)
        }
    }

    private func sortFilteredItems(_ items: [ActivityItem], category: ActivityCategory) -> [ActivityItem] {
        Self.sortFilteredItems(items, timeSort: timeSort(for: category))
    }

    /// `.all` 视图按 `repo.id` 在 `.star` / `.repository` / `.suggestion` 三类间去重。
    ///
    /// **去重范围**：仅这三类参与（都派生自 starred repos）。
    ///  - `.announcement`：无 repo，独立事件源；
    ///  - `.release`：独立事件源（用户订阅过的版本发布），与同 repo 的 star 语义并存；
    ///  - `.following`：每条对应一个 GitHub event id（unique），即便同 repo 同 actor
    ///    也是不同时间不同动作的独立事件，不去重。
    nonisolated static func deduplicateForAllView(_ source: [ActivityItem]) -> [ActivityItem] {
        var bestByRepoId: [Int64: ActivityItem] = [:]
        var nonDedupItems: [ActivityItem] = []

        for item in source {
            guard Self.isDedupableKind(item.kind), let repoId = item.repo?.id else {
                nonDedupItems.append(item)
                continue
            }
            if Self.shouldReplace(existing: bestByRepoId[repoId], with: item) {
                bestByRepoId[repoId] = item
            }
        }

        return nonDedupItems + Array(bestByRepoId.values)
    }

    nonisolated private static func isDedupableKind(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .star, .repository, .suggestion:
            return true
        case .announcement, .release, .following:
            return false
        }
    }

    nonisolated private static func shouldReplace(existing: ActivityItem?, with candidate: ActivityItem) -> Bool {
        guard let existing else { return true }
        let lhs = existing.createdAt ?? .distantPast
        let rhs = candidate.createdAt ?? .distantPast
        if rhs > lhs { return true }
        if rhs < lhs { return false }
        return kindPriority(candidate.kind) > kindPriority(existing.kind)
    }

    /// kind 优先级（仅 tiebreaker 用，越高越优先保留）。
    /// star 是用户行为信号最强；repository 是 push 活动；suggestion 是启发式推荐。
    nonisolated private static func kindPriority(_ kind: ActivityKind) -> Int {
        switch kind {
        case .star:         return 3
        case .repository:   return 2
        case .suggestion:   return 1
        case .announcement, .release, .following:
            return 0
        }
    }

    /// 4 路本地数据聚合为 ActivityItem 列表（PR-2 升级签名加 events / announcements）。
    private nonisolated static func makeItems(
        repos: [Repo],
        releases: [ReleaseTimelineEntry],
        events: [ActivityEventRecord],
        announcements: [ActivityAnnouncementRecord]
    ) -> [ActivityItem] {
        var result: [ActivityItem] = []
        let realAnnouncements = makeAnnouncementItems(announcements)
        // 有真实 announcement 时隐藏内置占位（PR-3）。
        if realAnnouncements.isEmpty {
            result.append(makeBuiltinAnnouncement())
        }
        result.append(contentsOf: realAnnouncements)
        result.append(contentsOf: makeReleaseItems(releases))
        result.append(contentsOf: makeStarItems(repos))
        result.append(contentsOf: makeRepositoryItems(repos))
        result.append(contentsOf: makeFollowingItems(events))
        result.append(contentsOf: makeSuggestionItems(repos))
        return result
    }

    private nonisolated static func makeBuiltinAnnouncement() -> ActivityItem {
        ActivityItem(
            id: "announcement:activity-v1",
            kind: .announcement,
            category: .announcement,
            title: String.l10n("activity.announcement.activityV1.title"),
            subtitle: String.l10n("activity.announcement.activityV1.subtitle"),
            body: String.l10n("activity.announcement.activityV1.body"),
            createdAt: Date(),
            htmlURL: nil,
            repo: nil,
            release: nil,
            releases: [],
            isRead: true
        )
    }

    /// announcement 表行 → ActivityItem。blog 正文走 HTML 摘要截断；security 保留纯文本。
    private nonisolated static func makeAnnouncementItems(_ records: [ActivityAnnouncementRecord]) -> [ActivityItem] {
        records.prefix(40).compactMap { record -> ActivityItem? in
            guard let source = AnnouncementSource(rawValue: record.source) else { return nil }

            let sourceTitle: String = {
                switch source {
                case .blog:     return String.l10n("activity.announcement.source.blog")
                case .security: return String.l10n("activity.announcement.source.security")
                }
            }()

            let categories = AnnouncementCategoriesCodec.decode(record.categories)
            let subtitle: String = {
                if categories.isEmpty { return sourceTitle }
                return "\(sourceTitle) · \(categories.prefix(2).joined(separator: ", "))"
            }()

            let bodySummary: String? = {
                guard let raw = record.bodyMarkdown, !raw.isEmpty else { return nil }
                switch source {
                case .blog:
                    return HTMLTextExtractor.plainText(from: raw, maxLength: 120)
                case .security:
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.count > 120 {
                        return String(text.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
                    }
                    return text
                }
            }()

            let payload = ActivityAnnouncementPayload(
                source: source,
                categories: categories,
                author: record.author,
                htmlBody: source == .blog ? record.bodyMarkdown : nil,
                repoName: record.repoName
            )

            return ActivityItem(
                id: record.id,
                kind: .announcement,
                category: .announcement,
                title: record.title,
                subtitle: subtitle,
                body: bodySummary,
                createdAt: Self.parseDate(record.createdAt),
                htmlURL: URL(string: record.url),
                repo: nil,
                release: nil,
                releases: [],
                isRead: record.isRead,
                announcement: payload
            )
        }
    }

    /// 发行版活动按 repo 聚合，而不是按 release event 展开。
    ///
    /// 原实现是一条 ReleaseTimelineEntry 生成一张卡片，导致同一个 repo 有多个版本时
    /// 中栏出现多张几乎相同的卡片。现在列表主体回到 repo：同一 repo 只显示一张，
    /// 用最新 release 的发布时间排序，详情页再展开该 repo 下所有 cached releases。
    private nonisolated static func makeReleaseItems(_ entries: [ReleaseTimelineEntry]) -> [ActivityItem] {
        let grouped = Dictionary(grouping: entries, by: { $0.repo.id })
        return grouped.values.compactMap { group -> ActivityItem? in
            guard let first = group.first else { return nil }
            let sorted = group.sorted { lhs, rhs in
                Self.releaseSortDate(lhs.release) > Self.releaseSortDate(rhs.release)
            }
            guard let latest = sorted.first?.release else { return nil }
            let latestTitle = latest.name?.isEmpty == false ? latest.name! : latest.tagName
            return ActivityItem(
                id: "release-repo:\(first.repo.id)",
                kind: .release,
                category: .release,
                title: first.repo.fullName,
                subtitle: latestTitle,
                body: first.repo.description,
                createdAt: Self.parseDate(latest.publishedAt) ?? Self.parseDate(latest.createdAtRemote),
                htmlURL: URL(string: first.repo.htmlUrl),
                repo: first.repo,
                release: latest,
                releases: sorted.map(\.release),
                isRead: sorted.allSatisfy { $0.release.isRead }
            )
        }
    }

    nonisolated private static func releaseSortDate(_ release: ReleaseRecord) -> Date {
        parseDate(release.publishedAt) ?? parseDate(release.createdAtRemote) ?? parseDate(release.fetchedAt) ?? .distantPast
    }

    private nonisolated static func makeStarItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred }
            .sorted { ($0.starredAt ?? "") > ($1.starredAt ?? "") }
            .prefix(30)
            .map { repo in
                ActivityItem(
                    id: "star:\(repo.id):\(repo.starredAt ?? "")",
                    kind: .star,
                    category: .star,
                    title: repo.fullName,
                    subtitle: String.l10n("activity.star.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.starredAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    releases: [],
                    isRead: true
                )
            }
    }

    private nonisolated static func makeRepositoryItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred }
            .sorted { ($0.pushedAt ?? $0.updatedAt ?? "") > ($1.pushedAt ?? $1.updatedAt ?? "") }
            .prefix(30)
            .map { repo in
                ActivityItem(
                    id: "repository:\(repo.id):\(repo.pushedAt ?? repo.updatedAt ?? "")",
                    kind: .repository,
                    category: .repository,
                    title: repo.fullName,
                    subtitle: String.l10n("activity.repository.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.pushedAt) ?? Self.parseDate(repo.updatedAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    releases: [],
                    isRead: true
                )
            }
    }

    private nonisolated static func makeSuggestionItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred && !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.starsCount == rhs.starsCount {
                    return (lhs.pushedAt ?? "") > (rhs.pushedAt ?? "")
                }
                return lhs.starsCount > rhs.starsCount
            }
            .prefix(20)
            .map { repo in
                ActivityItem(
                    id: "suggestion:\(repo.id)",
                    kind: .suggestion,
                    category: .suggestion,
                    title: repo.fullName,
                    subtitle: String.l10n("activity.suggestion.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.pushedAt) ?? Self.parseDate(repo.updatedAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    releases: [],
                    isRead: true
                )
            }
    }

    // MARK: - Following payload 解析（PR-2，2026-06-16）

    /// `activity_events` 表行 → ActivityItem，做 payload 解析 + i18n format 化。
    ///
    /// 设计要点：
    /// - **不支持的 event type 跳过**（`formatFollowingTitle` 返回 nil）：不在
    ///   `supportedEventTypes` 集合内的 type 在写入层就被过滤掉，理论上 DB
    ///   里不会有，但 schema 不强约束，万一历史数据混进来 → 静默跳过，不阻塞 feed。
    /// - **payload 解析失败 → 跳过**（不抛错）：单条 malformed payload 不影响
    ///   其它 event 上屏。
    /// - **prefix(60)** 截断：DB 端 `fetchAll(limit: 200)` 已截，这里再截一刀
    ///   保证 makeItems 最终聚合行数可控。
    private nonisolated static func makeFollowingItems(_ records: [ActivityEventRecord]) -> [ActivityItem] {
        records.prefix(60).compactMap { record -> ActivityItem? in
            guard let eventSummary = formatFollowingTitle(record) else { return nil }
            let payload = ActivityFollowingPayload(
                eventType: record.eventType,
                actorLogin: record.actorLogin,
                actorAvatarURL: record.actorAvatarUrl.flatMap { URL(string: $0) },
                repoFullName: record.repoName,
                repoId: record.repoId
            )
            return ActivityItem(
                id: "following:\(record.id)",
                kind: .following,
                category: .following,
                title: record.repoName,
                subtitle: eventSummary,
                body: extractFollowingBody(record),
                createdAt: Self.parseDate(record.createdAt),
                htmlURL: extractFollowingURL(record),
                repo: nil,
                release: nil,
                releases: [],
                isRead: record.isRead,
                following: payload
            )
        }
    }

    /// 按 event type + payload 拼装 row title 文本（已 i18n format 化）。
    ///
    /// 返回 nil 表示该事件没有对应的本地化文案 → 跳过（不展示空行）。
    /// 文案 key 详见 `Localizable.xcstrings` 里的 `activity.following.event.*.format`。
    private nonisolated static func formatFollowingTitle(_ record: ActivityEventRecord) -> String? {
        let actor = record.actorLogin
        let repo = record.repoName
        let payload = Self.decodePayload(record.payloadJson)

        switch record.eventType {
        case "WatchEvent":
            return String(format: String.l10n("activity.following.event.watch.format"), actor, repo)

        case "ForkEvent":
            return String(format: String.l10n("activity.following.event.fork.format"), actor, repo)

        case "PushEvent":
            // PushEvent payload: { ref: "refs/heads/main", ... }
            // GitHub 2025.10 起 commits 字段已移除，这里只展示分支名（参考方案 §7.1）
            let ref = (payload["ref"] as? String) ?? ""
            let branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            let fallbackBranch = branch.isEmpty ? "main" : branch
            return String(
                format: String.l10n("activity.following.event.push.format"),
                actor, fallbackBranch, repo
            )

        case "IssuesEvent":
            let action = payload["action"] as? String
            switch action {
            case "opened":
                return String(format: String.l10n("activity.following.event.issues.opened.format"), actor, repo)
            case "closed":
                return String(format: String.l10n("activity.following.event.issues.closed.format"), actor, repo)
            default:
                return nil // 其它 action（edited / reopened / labeled 等）信噪比低，跳过
            }

        case "PullRequestEvent":
            let action = payload["action"] as? String
            switch action {
            case "opened":
                return String(format: String.l10n("activity.following.event.pullRequest.opened.format"), actor, repo)
            case "closed":
                // closed 又分 merged / not merged，对开发者来说 merged 是更强信号 → 单独文案
                let pr = payload["pull_request"] as? [String: Any]
                let merged = pr?["merged"] as? Bool ?? false
                let key = merged
                    ? "activity.following.event.pullRequest.merged.format"
                    : "activity.following.event.pullRequest.closed.format"
                return String(format: String.l10n(key), actor, repo)
            default:
                return nil
            }

        case "CreateEvent":
            let refType = payload["ref_type"] as? String
            switch refType {
            case "branch":
                let ref = (payload["ref"] as? String) ?? ""
                return String(format: String.l10n("activity.following.event.create.branch.format"), actor, ref, repo)
            case "tag":
                let ref = (payload["ref"] as? String) ?? ""
                return String(format: String.l10n("activity.following.event.create.tag.format"), actor, ref, repo)
            case "repository":
                return String(format: String.l10n("activity.following.event.create.repository.format"), actor, repo)
            default:
                return nil
            }

        case "DiscussionEvent":
            return String(format: String.l10n("activity.following.event.discussion.format"), actor, repo)

        default:
            return nil
        }
    }

    /// 抽取 row body 文本（issue / PR / discussion 标题）。其它 event type 返回 nil。
    private nonisolated static func extractFollowingBody(_ record: ActivityEventRecord) -> String? {
        let payload = Self.decodePayload(record.payloadJson)
        switch record.eventType {
        case "IssuesEvent":
            return (payload["issue"] as? [String: Any])?["title"] as? String
        case "PullRequestEvent":
            return (payload["pull_request"] as? [String: Any])?["title"] as? String
        case "DiscussionEvent":
            return (payload["discussion"] as? [String: Any])?["title"] as? String
        default:
            return nil
        }
    }

    /// 抽取 row click 跳转的 HTML URL。
    /// 优先 issue / PR / discussion 的 `html_url`；其它类型回退到 repo 主页。
    private nonisolated static func extractFollowingURL(_ record: ActivityEventRecord) -> URL? {
        let payload = Self.decodePayload(record.payloadJson)
        let candidates: [Any?] = [
            (payload["pull_request"] as? [String: Any])?["html_url"],
            (payload["issue"] as? [String: Any])?["html_url"],
            (payload["discussion"] as? [String: Any])?["html_url"],
        ]
        for case let urlStr as String in candidates.compactMap({ $0 }) {
            if let url = URL(string: urlStr) {
                return url
            }
        }
        return URL(string: "https://github.com/\(record.repoName)")
    }

    /// payload JSON 字符串 → [String: Any] 字典。失败返回空字典（不抛错）。
    nonisolated private static func decodePayload(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    // MARK: - Date helpers

    /// GitHub API 大多返回带 fractional seconds 的 ISO8601；少数旧缓存可能没有。
    /// 这里保留 fallback，避免一条坏时间导致排序全部掉到底。
    nonisolated static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.shared.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    /// Date → ISO8601 字符串（带 fractional seconds，与 GitHub API 同款格式）。
    nonisolated static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter.shared.string(from: date)
    }

    /// RSS `pubDate`（RFC 2822）→ `Date`。解析失败返回 nil，由调用方 fallback 到 now。
    nonisolated static func parseRFC2822Date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: trimmed)
    }
}
