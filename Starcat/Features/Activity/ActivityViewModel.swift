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
    static let eventsTTL: TimeInterval = 7_200

    /// announcement 双源（blog + security）网络 TTL：12 小时（方案 §3.2）。
    static let announcementsTTL: TimeInterval = 43_200

    /// Security Advisory 扫描：仅最近 N 天内有 push 的 starred repo。
    static let securityLookbackDays = 30

    /// Security 扫描 repo 上限，防止 starred 过多时 API 风暴。
    static let securityScanMaxRepos = 200

    /// 30 天数据清理冷却：24 小时（方案 §5.4 决策 P6）。
    ///
    /// `cleanupIfNeeded()` 读 `activity_sync_state.last_cleanup_at`，距上次清理 < 24h 直接跳过。
    /// 不在主刷新路径里跑，由 reload 末尾 detached Task 异步派发；24h 一次足够
    /// 控制 events / announcements 表行数（30 天滚动窗口 × 平均 60 行/天 ≈ 1800 行上限）。
    static let cleanupCooldown: TimeInterval = 86_400

    /// 数据保留天数：30 天（方案 §3.2）。30 天前的 events / announcements 被
    /// `cleanupIfNeeded()` 物理删除（不保留 tombstone —— device-local 数据 + 不挂 CloudKit）。
    static let retentionDays: Int = 30

    /// 受支持的 GitHub Event 类型集合。
    ///
    /// **排除清单**（决策 Q1 + §7.7）：
    /// - `ReleaseEvent`：与 `releases` 表语义重复（HOM-47 已专门追踪订阅 repo 的 release）
    /// - `GollumEvent`（wiki 编辑）/ `PublicEvent`（私转公）/ `MemberEvent`（协作者变更）：
    ///   信噪比低，第一版不展示
    ///
    /// 任何不在此集合内的 event type 在 `fetchAndPersistEvents` 里直接丢弃，不入库。
    /// 未来要支持新 event 加在这里 + `formatFollowingTitle` 加 case + i18n 加 key 即可。
    static let supportedEventTypes: Set<String> = [
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

    /// 进入页面 / 切分类入口：尊重 TTL，2h 内不走 events 网络。
    func load(category: ActivityCategory) async {
        await reload(category: category, shouldPollReleases: false, cachePolicy: .respectTTL)
    }

    /// 用户主动刷新（toolbar 按钮）：强制走 events 网络 + 跑一次 Release 巡检。
    func refresh(category: ActivityCategory) async {
        await reload(category: category, shouldPollReleases: true, cachePolicy: .forceNetwork)
    }

    /// SWR 核心入口（PR-2 重构，复刻 `TrendingViewModel.reload` 同款套路）。
    ///
    /// 行为矩阵：
    /// | 入口 | cachePolicy | 缓存空 | 缓存有 + TTL 内 | 缓存有 + TTL 过期 |
    /// |------|-------------|--------|------------------|---------------------|
    /// | 进入页面 (.task) | .respectTTL | 走网络 + isLoading | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
    /// | 切分类 | .respectTTL | 走网络 + isLoading | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
    /// | 主动刷新按钮 | .forceNetwork | 走网络 + isLoading | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
    ///
    /// SWR 关键约束：
    /// - 缓存命中 + `.respectTTL` + TTL 内 → **完全不走 events 网络**（2h 内零打扰）
    /// - 4 路本地（repos / releases / events / announcements）任一失败不影响其它路
    /// - events 网络失败 + 有缓存 → 保留已显示，仅 log（loadError 不动以免与 Release poller 错误串）
    /// - events 网络失败 + 无缓存 → loadError 显示，UI 空状态
    func reload(category: ActivityCategory, shouldPollReleases: Bool, cachePolicy: ActivityCachePolicy) async {
        currentReloadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }

            // ① 读 sync_state，先把 lastRefreshedAt 顶到 UI（toolbar 新鲜度提示首屏可见）
            let initialSyncState = try? await self.activitySyncStateRepository.current()
            if let timestamp = initialSyncState?.lastEventsFetchedAt,
               let date = Self.parseDate(timestamp)
            {
                self.lastRefreshedAt = date
            }
            guard !Task.isCancelled else { return }

            // ② 第一阶段：本地 4 路并行读
            //   4 路任一失败不影响其它路（try? + ?? 空集合兜底）；这是 SWR 「永远先上屏可用数据」的实现。
            async let cachedReposTask = self.repoRepository.fetchAllStarred()
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

            let cachedItems = self.makeItems(
                repos: cachedRepos,
                releases: cachedReleases,
                events: cachedEvents,
                announcements: cachedAnnouncements
            )
            self.items = self.filter(cachedItems, by: category)
            self.itemsRevision += 1
            self.loadError = nil
            self.isLoading = !hasUsableCache

            // ③ 决定是否走 3 路网络（events + blog RSS + security）
            let shouldFetchEvents = Self.shouldFetchEvents(
                cachePolicy: cachePolicy,
                syncState: initialSyncState
            )
            let shouldFetchBlog = Self.shouldFetchBlogRSS(
                cachePolicy: cachePolicy,
                syncState: initialSyncState
            )
            let shouldFetchSecurity = Self.shouldFetchSecurityAdvisories(
                cachePolicy: cachePolicy,
                syncState: initialSyncState
            )

            // 后台刷新指示器：仅在"有缓存 + 走网络"时点亮（与 Trending 同款）
            if hasUsableCache && (shouldFetchEvents || shouldFetchBlog || shouldFetchSecurity || shouldPollReleases) {
                self.isRefreshing = true
            }

            // ④ Release 巡检（v1 已有逻辑保留）
            if shouldPollReleases {
                await self.releasePollerRunner()
            }
            guard !Task.isCancelled else { return }

            // ⑤ 三路网络刷新（events / blog / security）
            var refreshedEvents = cachedEvents
            var refreshedAnnouncements = cachedAnnouncements

            if shouldFetchEvents, let login = self.currentLoginProvider() {
                let result = await self.fetchAndPersistEvents(
                    login: login,
                    etag: initialSyncState?.eventsEtag
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .updated:
                    self.lastRefreshedAt = Date()
                    refreshedEvents = (try? await self.activityEventRepository.fetchAll(limit: 200)) ?? cachedEvents
                case .notModified:
                    self.lastRefreshedAt = Date()
                case .failed(let error):
                    if !hasUsableCache {
                        self.loadError = error.localizedDescription
                    } else {
                        AppLog.network.warning(
                            "Activity events refresh failed but cache shown: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }

            if shouldFetchBlog {
                let result = await self.fetchAndPersistBlogRSS(etag: initialSyncState?.blogRssEtag)
                guard !Task.isCancelled else { return }
                switch result {
                case .updated, .notModified:
                    refreshedAnnouncements = (try? await self.activityAnnouncementRepository.fetchAll(limit: 100))
                        ?? refreshedAnnouncements
                case .failed(let error):
                    AppLog.network.warning(
                        "Activity blog RSS refresh failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            if shouldFetchSecurity {
                let result = await self.fetchAndPersistSecurityAdvisories(repos: cachedRepos)
                guard !Task.isCancelled else { return }
                switch result {
                case .updated, .notModified:
                    refreshedAnnouncements = (try? await self.activityAnnouncementRepository.fetchAll(limit: 100))
                        ?? refreshedAnnouncements
                case .failed(let error):
                    AppLog.network.warning(
                        "Activity security refresh failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            // ⑥ 重读 releases（Release 巡检可能写入新行）+ 重组装 items
            if shouldFetchEvents || shouldFetchBlog || shouldFetchSecurity || shouldPollReleases {
                let refreshedReleases = (try? await self.releaseRepository.fetchTimeline(limit: 120)) ?? cachedReleases
                guard !Task.isCancelled else { return }

                let refreshedItems = self.makeItems(
                    repos: cachedRepos,
                    releases: refreshedReleases,
                    events: refreshedEvents,
                    announcements: refreshedAnnouncements
                )
                let filtered = self.filter(refreshedItems, by: category)
                let oldIDs = self.items.map(\.id)
                let newIDs = filtered.map(\.id)
                self.items = filtered
                // 智能 revision：身份序列变化才 bump，避免无意义动画重播
                if oldIDs != newIDs {
                    self.itemsRevision += 1
                }
            }

            self.isLoading = false
            self.isRefreshing = false

            // ⑦ 后台清理（≥ 24h 触发，detached Task 不阻塞主路径）
            Task.detached(priority: .background) { [weak self] in
                await self?.cleanupIfNeeded()
            }
        }

        currentReloadTask = task
        await task.value
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
        var allRecords: [ActivityAnnouncementRecord] = []

        for repo in candidates {
            let parts = repo.fullName.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let owner = parts[0]
            let name = parts[1]

            do {
                let response = try await apiClient.securityAdvisories(owner: owner, repo: name)
                let records = response.value.map { dto -> ActivityAnnouncementRecord in
                    let url = dto.htmlUrl ?? "https://github.com/advisories/\(dto.ghsaId)"
                    let createdAtISO = dto.publishedAt ?? nowISO
                    return ActivityAnnouncementRecord(
                        id: AnnouncementSource.security.makeId(nativeId: dto.ghsaId),
                        source: AnnouncementSource.security.rawValue,
                        title: dto.summary,
                        bodyMarkdown: dto.description,
                        author: nil,
                        url: url,
                        repoName: repo.fullName,
                        categories: dto.severity.map { AnnouncementCategoriesCodec.encode([$0]) } ?? nil,
                        isRead: false,
                        createdAt: createdAtISO,
                        fetchedAt: nowISO
                    )
                }
                allRecords.append(contentsOf: records)
            } catch NetworkError.notFound {
                continue
            } catch NetworkError.clientError(let code, _) where code == 403 || code == 404 {
                continue
            } catch {
                AppLog.network.warning(
                    "Activity security skip \(repo.fullName): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }

        do {
            if !allRecords.isEmpty {
                try await activityAnnouncementRepository.upsertMany(allRecords)
            }
            try await activitySyncStateRepository.updateSecurity(lastFetchedAt: now)
            AppLog.network.info(
                "Activity security refreshed: repos=\(candidates.count, privacy: .public), advisories=\(allRecords.count, privacy: .public)"
            )
            return .updated
        } catch {
            return .failed(error)
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

    private func filter(_ source: [ActivityItem], by category: ActivityCategory) -> [ActivityItem] {
        let filtered: [ActivityItem]
        if category == .all {
            // `.all` 视图专属去重：makeStarItems / makeRepositoryItems / makeSuggestionItems
            // 三个 builder 都派生自同一份 starred repos，同一个 repo 在 .all 视图会同时
            // 出现 .star / .repository / .suggestion 三条卡片（id 前缀不同，Identifiable
            // 不会去重）。dong4j 2026-06-11 反馈视觉冗余 → 这里做一次「按 repo.id」去重。
            //
            // 单独的具体分类（.star / .repository / .suggestion）不在这里走，因为：
            //  - 它们各自就是单一 kind 视角（按 starredAt / pushedAt / stars 数排序），
            //    用户主动选择「看 push 活动」或「看推荐」时不应被去重剥夺信号；
            //  - 单一 kind 内同 repo 本就不会重复（每个 repo 在每个 builder 里最多 1 条）。
            filtered = deduplicateForAllView(source)
        } else {
            filtered = source.filter { $0.category == category }
        }
        return filtered.sorted { lhs, rhs in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
    }

    /// `.all` 视图按 `repo.id` 在 `.star` / `.repository` / `.suggestion` 三类间去重。
    ///
    /// **去重范围**：仅这三类参与（都派生自 starred repos）。
    ///  - `.announcement`：无 repo，独立事件源；
    ///  - `.release`：独立事件源（用户订阅过的版本发布），与同 repo 的 star 语义并存；
    ///  - `.following`：每条对应一个 GitHub event id（unique），即便同 repo 同 actor
    ///    也是不同时间不同动作的独立事件，不去重。
    private func deduplicateForAllView(_ source: [ActivityItem]) -> [ActivityItem] {
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

    private static func isDedupableKind(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .star, .repository, .suggestion:
            return true
        case .announcement, .release, .following:
            return false
        }
    }

    private static func shouldReplace(existing: ActivityItem?, with candidate: ActivityItem) -> Bool {
        guard let existing else { return true }
        let lhs = existing.createdAt ?? .distantPast
        let rhs = candidate.createdAt ?? .distantPast
        if rhs > lhs { return true }
        if rhs < lhs { return false }
        return kindPriority(candidate.kind) > kindPriority(existing.kind)
    }

    /// kind 优先级（仅 tiebreaker 用，越高越优先保留）。
    /// star 是用户行为信号最强；repository 是 push 活动；suggestion 是启发式推荐。
    private static func kindPriority(_ kind: ActivityKind) -> Int {
        switch kind {
        case .star:         return 3
        case .repository:   return 2
        case .suggestion:   return 1
        case .announcement, .release, .following:
            return 0
        }
    }

    /// 4 路本地数据聚合为 ActivityItem 列表（PR-2 升级签名加 events / announcements）。
    private func makeItems(
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

    private func makeBuiltinAnnouncement() -> ActivityItem {
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
    private func makeAnnouncementItems(_ records: [ActivityAnnouncementRecord]) -> [ActivityItem] {
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
    private func makeReleaseItems(_ entries: [ReleaseTimelineEntry]) -> [ActivityItem] {
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

    private static func releaseSortDate(_ release: ReleaseRecord) -> Date {
        parseDate(release.publishedAt) ?? parseDate(release.createdAtRemote) ?? parseDate(release.fetchedAt) ?? .distantPast
    }

    private func makeStarItems(_ repos: [Repo]) -> [ActivityItem] {
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

    private func makeRepositoryItems(_ repos: [Repo]) -> [ActivityItem] {
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

    private func makeSuggestionItems(_ repos: [Repo]) -> [ActivityItem] {
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
    private func makeFollowingItems(_ records: [ActivityEventRecord]) -> [ActivityItem] {
        records.prefix(60).compactMap { record -> ActivityItem? in
            guard let title = formatFollowingTitle(record) else { return nil }
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
                title: title,
                subtitle: record.repoName,
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
    private func formatFollowingTitle(_ record: ActivityEventRecord) -> String? {
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
    private func extractFollowingBody(_ record: ActivityEventRecord) -> String? {
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
    private func extractFollowingURL(_ record: ActivityEventRecord) -> URL? {
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
