//
//  TrendingViewModel.swift
//  Starcat
//
//  Trending 页面状态模型。
//
//  职责：
//  - 维护 Trending 列表数据
//  - 处理日/周/月榜切换
//  - 处理语言筛选
//  - 处理 AI 摘要请求（轻量本地占位 + 评分计算）
//
//  设计约束：
//  - @MainActor + @Observable，所有状态变更在主线程
//  - 依赖 TrendingRepositoryProtocol，便于测试注入 Mock
//
//  R-01 v1.2（2026-06-10）：删除会话级 star 集合（`subscribedRepoIDs` /
//  `subscribe(repo:)` / `incrementStarsCount` / `subscriptionError`）。
//  Star/unstar 跨场景状态由 `StarredRegistry`（@Observable 单例）统一驱动；
//  trending row 的 ✓ 标记通过 `RepoCardViewData.isStarred = registry.contains(...)`
//  自动响应。详情页 star 操作改走 `StarActionService.star(owner:repo:)` 单点。
//
//  R-06.1（2026-06-15）：客户端 Trending TTL 改造，把无脑 `forceNetwork: Bool` 升级到
//  语义化 `TrendingCachePolicy` enum（`.respectTTL` / `.forceNetwork`）+ 分周期 TTL。
//  - `.respectTTL`：缓存命中且 TTL 内不走网络；空缓存或过期才拉
//  - `.forceNetwork`：用户主动刷新按钮 / pull-to-refresh / 错误重试，永远走网络
//  - 周期 / 语言切换走 `.respectTTL`（TTL 内可命中其它桶缓存避免无意义请求）
//  详见 §6.6 R-06 设计文档。
//

import Foundation
import Observation
import SwiftUI

/// Trending 数据加载的缓存策略。
///
/// - `.respectTTL`：尊重当前周期的客户端 TTL —— 缓存命中且未过期则不走网络；
///   过期或空缓存才发请求。用于首次入场、周期切换、语言切换等"非用户主动刷新"场景。
/// - `.forceNetwork`：绕过 TTL 永远走网络。用于 toolbar 刷新按钮、`refreshable` 下拉、
///   错误重试等"用户主动要新数据"场景。
///
/// 与 dong4j 讨论权衡：把 cachePolicy 放在 ViewModel 层（而非 Repository.fetchTrending
/// 入参），让 Repository 协议保持纯净，避免引入"返回值标记 from-cache vs from-network"
/// 的复杂度（否则 ViewModel 无法判断要不要更新 `lastRefreshedAt = Date()`，会出现
/// "TTL 命中 → 更新刷新时间 → always-fresh 死循环"的 bug）。
enum TrendingCachePolicy: Equatable, Sendable {
    case respectTTL
    case forceNetwork
}

/// Trending 中栏的本地排序方式。
///
/// `recommended` 保留 trending-api 返回顺序,也就是官方趋势榜原始排名；其它选项只对
/// 当前已加载列表做本地排序,不改变缓存桶和远端请求参数。
enum TrendingSortOption: String, CaseIterable, Identifiable, Sendable {
    case recommended
    case starsDesc
    case starsAsc
    case updatedDesc
    case updatedAsc
    case createdDesc
    case createdAsc
    case nameAsc
    case nameDesc
    case risingTrend

    var id: String { rawValue }

    var isTrendingSpecificSort: Bool {
        self == .risingTrend
    }

    var localizedTitle: String {
        switch self {
        case .recommended: return String.l10n("trending.sort.recommended")
        case .starsDesc: return String.l10n("trending.sort.starsDesc")
        case .starsAsc: return String.l10n("trending.sort.starsAsc")
        case .updatedDesc: return String.l10n("trending.sort.updatedDesc")
        case .updatedAsc: return String.l10n("trending.sort.updatedAsc")
        case .createdDesc: return String.l10n("trending.sort.createdDesc")
        case .createdAsc: return String.l10n("trending.sort.createdAsc")
        case .nameAsc: return String.l10n("trending.sort.nameAsc")
        case .nameDesc: return String.l10n("trending.sort.nameDesc")
        case .risingTrend: return String.l10n("trending.sort.risingTrend")
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .recommended: return "trending.sort.recommended"
        case .starsDesc: return "trending.sort.starsDesc"
        case .starsAsc: return "trending.sort.starsAsc"
        case .updatedDesc: return "trending.sort.updatedDesc"
        case .updatedAsc: return "trending.sort.updatedAsc"
        case .createdDesc: return "trending.sort.createdDesc"
        case .createdAsc: return "trending.sort.createdAsc"
        case .nameAsc: return "trending.sort.nameAsc"
        case .nameDesc: return "trending.sort.nameDesc"
        case .risingTrend: return "trending.sort.risingTrend"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended:
            return "sparkles"
        case .starsDesc:
            return "star.fill"
        case .starsAsc:
            return "star"
        case .updatedDesc, .updatedAsc:
            return "clock.arrow.circlepath"
        case .createdDesc:
            return "calendar.badge.plus"
        case .createdAsc:
            return "calendar"
        case .nameAsc:
            return "a.square"
        case .nameDesc:
            return "z.square"
        case .risingTrend:
            return "chart.line.uptrend.xyaxis"
        }
    }
}

@MainActor
@Observable
final class TrendingViewModel {

    // MARK: - TTL 常量

    /// 返回当前 Trending 周期的客户端 TTL。
    ///
    /// 客户端与后端分桶新鲜度保持一致，避免 daily 数据被统一 24h 策略长期遮蔽，
    /// 同时让 weekly / monthly 继续复用更稳定的本地快照。
    static func ttl(for period: TrendingPeriod) -> TimeInterval {
        switch period {
        case .daily:
            return 60 * 60
        case .weekly:
            return 6 * 60 * 60
        case .monthly:
            return 24 * 60 * 60
        }
    }

    // MARK: - 数据状态

    /// 当前 Trending 列表（**分页切片**，不是全量）。
    ///
    /// 对齐 Weekly：全量数据放 `allRepos`（private、非 @Observable），对外只暴露分页切片
    /// `repos`，避免滚动分页时因全量数组在 View 层反复 `prefix` 导致重算/卡顿。
    /// 数据在 `TrendingListPipeline` 完成排序与评分后一次性发布，切片只在分页时推进。
    private(set) var repos: [TrendingRepo] = []

    /// 全量 repo（已排序已筛选）。仅 ViewModel 内部用于切片与 `hasMore` 判断，不对外暴露。
    private var allRepos: [TrendingRepo] = []

    /// 已排序但尚未应用全局筛选的候选列表。
    ///
    /// 仅供 View 补载 Wiki / Health / OpenSSF 信号；真正展示仍只读取 `repos`，避免为了
    /// 获得筛选元数据而在主线程重跑整榜过滤。
    private(set) var filterCandidateRepos: [TrendingRepo] = []

    /// 当前允许 SwiftUI 构造的 row 数量。首屏固定 20，滚动接近底部再按页增长。
    private(set) var visibleLimit: Int = TrendingViewModel.pageSize

    /// 是否还有更多分页可加载（对齐 Weekly 的 hasMore）。
    var hasMore: Bool { visibleLimit < allRepos.count }

    /// 全量 repo 数（供 Sidebar / subtitle 计数，与分页切片 `repos.count` 区分）。
    var totalCount: Int { allRepos.count }

    /// 分类切换时跳过 row reveal，避免几十个 row 动画与列表 diff 同时争抢主线程。
    private(set) var skipListRowReveal: Bool = false

    /// 当前请求桶是否已经有可展示快照。
    ///
    /// 切到未加载桶时，旧 List 视图树仍保留但隐藏在局部骨架下；新快照发布后原地更新，
    /// 不再用 if/else 销毁并重建整个列表宿主。
    var hasPublishedCurrentQuery: Bool {
        publishedQueryIdentity == currentQueryIdentity
    }

    /// 当前 Trending 列表"身份快照"版本。
    ///
    /// **只在榜单"身份序列"变化时递增**（即 fullName 列表或顺序发生变化）。
    /// 数值字段变化（stars / forks / starsInPeriod / contributors）即使被网络刷新覆盖，
    /// 也不递增 revision —— SwiftUI `List + ForEach + Identifiable` 会自然 in-place diff，
    /// row 不重播入场动画，stars 数等会"悄悄"更新。
    ///
    /// 不递增的场景：
    /// - 缓存命中后再次走网络拿到完全相同的榜单（最常见）
    /// - 网络回来发现 stars / forks 变化但 fullName 顺序不变
    /// - 本地 star 成功导致的 starsCount +1
    ///
    /// 递增的场景：
    /// - 周期切换（如 daily → weekly）后第一次有数据
    /// - 语言切换后第一次有数据
    /// - 真实换榜：榜单成员或顺序发生变化
    /// - 进入页面 + 缓存命中（首屏入场需要 row reveal 动画）
    private(set) var reposRevision: Int = 0

    /// 当前 (period, language) 桶最近一次成功刷新时间。
    ///
    /// 来源：① reload 开始时从 repository 读 trending_repos.cached_at 的 max；
    /// ② 网络成功后更新为 `Date()`（避免再 query 一次 DB）。
    ///
    /// UI 用法：toolbar 显示"X 分钟前"新鲜度提示；超过当前周期 TTL 的 80% 变橙色。
    /// 没缓存 / 还没刷新过返回 nil，UI 隐藏新鲜度提示。
    private(set) var lastRefreshedAt: Date?

    /// 加载中状态。
    ///
    /// 初始为 `true`：View 首帧在 `.task` 跑到 `reload` 之前就要能进骨架，
    /// 否则 `isLoading=false && repos=[]` 会短暂渲染空 List（发现 / 周刊不会有这个问题）。
    private(set) var isLoading: Bool = true

    /// 后台刷新中状态。
    ///
    /// 与 `isLoading` 区分：`isLoading` 是"无可用列表 + 在等数据"的全屏骨架；
    /// `isRefreshing` 是"有列表 + 网络在跑"的轻量后台刷新（toolbar 刷新 icon 旋转）。
    /// 同一时间至多一个为 true。
    private(set) var isRefreshing: Bool = false

    /// 错误信息
    private(set) var loadError: String?

    /// 有可用缓存时网络刷新失败的横条提示（与探索发现/热门同语义）。
    private(set) var cacheWarning: String?

    // MARK: - 筛选状态

    /// 当前时间周期。只能通过 `selectPeriod` 修改，确保一次交互只触发一次查询。
    private(set) var selectedPeriod: TrendingPeriod = .daily

    /// 当前语言筛选。只能通过 `selectLanguage` 修改，避免 didSet 与 View.task 双触发。
    private(set) var selectedLanguage: TrendingLanguage = .all

    /// 设置页「感兴趣语言」镜像。Trending 全量化后「其他」分类的本地过滤依赖它；
    /// 由 TrendingView 从 AppSettings 单向同步（onChange）。
    var interestedLanguages: [String] = [] {
        didSet {
            guard oldValue != interestedLanguages else { return }
            guard selectedLanguage.isOther else { return }
            // 「其他」的排除集合变了，本地重新派生。
            Task { await republishLocalSnapshot() }
        }
    }

    /// 当前中栏排序方式。默认保留 trending-api 返回顺序,即官方趋势榜原始排名。
    private(set) var selectedSort: TrendingSortOption = .recommended

    // MARK: - AI 摘要状态

    /// 正在生成摘要的 repo id 集合
    private(set) var summarizingRepoIDs: Set<String> = []

    /// 摘要结果缓存：repo fullName -> 摘要文本
    private(set) var summaryCache: [String: String] = [:]

    // MARK: - AI 评分状态

    /// AI 评分缓存：repo fullName -> 评分
    private(set) var scoreCache: [String: TrendingScore] = [:]

    // MARK: - 个性化推荐

    /// 用户收藏偏好：语言分布
    private(set) var userLanguagePreferences: [String: Double] = [:]

    /// 用户收藏偏好：主题分布（基于 topics）
    var userTopicPreferences: [String: Double] = [:]

    /// 推荐结果与主列表一起由后台 actor 派生；SwiftUI 只读前三项。
    private(set) var recommendedRepos: [TrendingRepo] = []

    // MARK: - 依赖

    private let repository: any TrendingRepositoryProtocol
    private let githubAPIClient: any GitHubAPIClientProtocol
    private let listPipeline = TrendingListPipeline()

    /// 当前全局筛选的轻量值快照。Observable store 本身不能跨 actor，View 先投影成 Set，
    /// 再由管线在 MainActor 之外逐项匹配。
    private var globalFilter: TrendingListFilter = .all

    /// 每个查询桶的内存新鲜度。返回已经看过的分类时先命中这里，不再重复读取 SQLite。
    private var memoryRefreshDates: [TrendingQueryIdentity: Date] = [:]

    /// 已经发布到 UI 的查询桶；与当前请求桶不同时，列表宿主进入局部占位状态。
    private var publishedQueryIdentity: TrendingQueryIdentity?

    /// 后台管线预先生成的 row identity 序列，避免发布时在 MainActor 再遍历全榜单。
    private var publishedRepoIdentityIDs: [String] = []

    /// reload 代际。即使底层 Repository 不响应取消，过期结果也不能覆盖新分类。
    private var reloadGeneration: UInt64 = 0

    /// 当前 in-flight 的 reload 任务
    private var currentReloadTask: Task<Void, Never>?
    private var currentReloadIdentity: TrendingQueryIdentity?
    private var currentReloadPolicy: TrendingCachePolicy?

    private static let pageSize = 20

    private var currentQueryIdentity: TrendingQueryIdentity {
        TrendingQueryIdentity(period: selectedPeriod)
    }

    // MARK: - Initialization

    init(
        repository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol
    ) {
        self.repository = repository
        self.githubAPIClient = githubAPIClient
    }

    // MARK: - Public Actions

    /// 首次进入或从其它 Explore 分类返回时，原子设置语言与排序后只发起一次 reload。
    func activate(
        language: TrendingLanguage,
        sort: TrendingSortOption
    ) async {
        selectedLanguage = language
        selectedSort = sort
        await reload(cachePolicy: .respectTTL, revealsRows: true)
    }

    /// 切换周期。所有查询条件变更都经由这里收敛，避免属性观察器隐式创建第二个任务。
    func selectPeriod(_ period: TrendingPeriod) async {
        guard selectedPeriod != period else { return }
        selectedPeriod = period
        await reload(cachePolicy: .respectTTL, revealsRows: true)
    }

    /// 切换语言。全量化后语言是本地过滤维度，切语言只重新派生展示快照，零网络。
    func selectLanguage(_ language: TrendingLanguage) async {
        guard selectedLanguage != language else { return }
        selectedLanguage = language
        await republishLocalSnapshot()
    }

    /// 本地切换排序；排序和评分在 `TrendingListPipeline` actor 内完成。
    func selectSort(_ sort: TrendingSortOption) async {
        guard selectedSort != sort else { return }
        selectedSort = sort
        await republishLocalSnapshot()
    }

    /// 排序 / 语言 / 感兴趣语言变化时，用最新派生输入重新派生并发布当前查询桶快照，
    /// 不触发网络。所有本地派生入口统一走这里，避免重复写同一套 snapshot 读取逻辑。
    private func republishLocalSnapshot() async {
        skipListRowReveal = true
        let identity = currentQueryIdentity
        let snapshot = await preparedMemorySnapshot(for: identity)
        guard identity == currentQueryIdentity, let snapshot else { return }
        publish(snapshot, for: identity, resetVisiblePage: true)
    }

    /// 应用 View 提供的全局筛选输入，并从已有原始快照在后台重新派生列表。
    /// Store 状态未变化时直接短路，避免 row badge 的无关刷新触发整榜计算。
    func updateGlobalFilter(_ filter: TrendingListFilter) async {
        guard globalFilter != filter else { return }
        globalFilter = filter
        skipListRowReveal = true

        let identity = currentQueryIdentity
        let snapshot = await preparedMemorySnapshot(for: identity)
        guard identity == currentQueryIdentity, let snapshot else { return }
        publish(snapshot, for: identity, resetVisiblePage: true)
    }

    /// 滚动接近当前页尾时追加一页 row，避免首屏一次构造整个榜单。
    /// 滚动分页入口：由 `automaticListPagination` 触发（对齐 Weekly），
    /// 预取判定由 modifier 内部完成，这里推进可见窗口并切片。
    func loadMoreIfNeeded() async {
        let totalAvailable = allRepos.count
        guard totalAvailable > visibleLimit else { return }
        let previousLimit = visibleLimit
        visibleLimit = min(visibleLimit + Self.pageSize, totalAvailable)
        // 只复制新开放的一页，避免每次触底都重新分配并复制完整历史前缀。
        // `repos` 的既有元素与顺序保持不变，SwiftUI 可以稳定复用已经显示的 row。
        repos.append(contentsOf: allRepos[previousLimit..<visibleLimit])
    }

    /// 刷新 Trending 列表（R-06.1 TTL 升级版，2026-06-15 改造）。
    ///
    /// **R-06.1 设计变更**（相比 2026-06-02 智能 revision 版）：
    /// - `forceNetwork: Bool` 升级为 `cachePolicy: TrendingCachePolicy` enum，语义更清晰
    /// - 在"缓存命中"分支加入 TTL 判断：`.respectTTL` + 缓存在当前周期 TTL 内 → 跳过网络；
    ///   否则走网络。`.forceNetwork` 永远走网络绕过 TTL
    /// - "智能 revision"逻辑不变（拿到 fresh 数据后对比 fullName 序列）
    ///
    /// 行为矩阵：
    /// | 入口 | cachePolicy | 缓存空 | 缓存有 + TTL 内 | 缓存有 + TTL 过期 |
    /// |------|-------------|--------|------------------|---------------------|
    /// | 进入页面 (.task) | .respectTTL | 走网络 + isLoading | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
    /// | 周期/语言切换 | .respectTTL | 走网络 + isLoading | 上屏缓存 + 不走网络 | 上屏缓存 + 后台刷新 |
    /// | 主动刷新按钮 | .forceNetwork | 走网络 + isLoading | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
    /// | 错误重试 | .forceNetwork | 走网络 + isLoading | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
    /// | refreshable 下拉 | .forceNetwork | 走网络 + isLoading | 上屏缓存 + 后台刷新 | 上屏缓存 + 后台刷新 |
    ///
    /// SWR 关键约束：
    /// - 缓存命中 + `.respectTTL` + TTL 内 → **完全不走网络**
    /// - 缓存命中 + `.respectTTL` + TTL 过期 → 上屏缓存 → 后台拉网络 → 智能 revision
    /// - 缓存命中 + `.forceNetwork` → 上屏缓存 → 后台拉网络 → 智能 revision
    /// - 缓存空 → 必拉网络（不管 cachePolicy），isLoading=true
    /// - 网络失败 + 有缓存 → 保留已显示，提示 cacheWarning（不遮住列表）
    /// - 网络失败 + 无缓存 → errorView
    ///
    /// 智能 revision 规则（关键，与 2026-06-02 版本一致）：
    /// - 缓存上屏总是 bump revision（首屏入场动画）
    /// - 网络回来对比 oldIDs vs newIDs：身份序列变化才 bump
    /// - "身份序列" = `repos.map(\.fullName)` ordered list，stars/forks 等数值不算
    ///
    /// 注意：网络成功时 fetchTrending 已经 race-free（actor 内的 DB 写入是顺序的），
    /// 这里 ViewModel 层用 currentReloadTask 取消老任务即可。
    func reload(
        cachePolicy: TrendingCachePolicy = .respectTTL,
        revealsRows: Bool = false
    ) async {
        let identity = currentQueryIdentity

        // 相同桶的重复入口复用现有任务；主动刷新可以升级并替换自动 TTL 任务。
        if currentReloadIdentity == identity,
           let currentReloadTask,
           currentReloadPolicy == cachePolicy || currentReloadPolicy == .forceNetwork {
            // 用户在同一查询仍刷新时切走再返回，继续复用数据任务，但不能吞掉本次
            // 分类入场的 row reveal 请求；动画只影响 View，不会创建第二个网络任务。
            if revealsRows {
                skipListRowReveal = false
            }
            await currentReloadTask.value
            return
        }

        currentReloadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        currentReloadIdentity = identity
        currentReloadPolicy = cachePolicy
        // Explore 进入趋势、切周期或切语言时，首屏应与星标分类一样播放 row reveal；
        // 主动刷新仍跳过动画，避免同一份已显示内容因后台更新再次整批闪动。
        skipListRowReveal = !revealsRows && publishedQueryIdentity != nil
        loadError = nil
        cacheWarning = nil

        if hasPublishedCurrentQuery {
            isLoading = false
            isRefreshing = cachePolicy == .forceNetwork
        } else {
            // 不清空 repos：稳定保留 List 宿主，局部骨架通过 query identity 将旧内容遮住。
            isLoading = true
            isRefreshing = false
        }

        let task = Task { [weak self] in
            guard let self else { return }

            var hasUsableSnapshot = false

            // ① 会话级内存快照优先。返回看过的分类时不再重复读 SQLite。
            if let memory = await self.preparedMemorySnapshot(for: identity) {
                guard self.isCurrentReload(generation, identity: identity) else { return }
                // 同一查询从其它 Explore 模块返回时保留已加载页；切到不同桶时
                // `publish` 会因 queryChanged 自动重置为首屏 20 条。
                self.publish(memory, for: identity, resetVisiblePage: false)
                self.lastRefreshedAt = self.memoryRefreshDates[identity]
                self.isLoading = false
                hasUsableSnapshot = true
            } else {
                // ② 首次访问该桶才读取持久化缓存；数据库 actor 不占用 MainActor。
                let refreshedAt = await self.repository.lastRefreshedAt(
                    since: identity.period,
                    language: .all
                )
                guard self.isCurrentReload(generation, identity: identity) else { return }

                let cached = await self.repository.cachedTrending(
                    since: identity.period,
                    language: .all
                )
                guard self.isCurrentReload(generation, identity: identity) else { return }

                self.lastRefreshedAt = refreshedAt
                if let refreshedAt {
                    self.memoryRefreshDates[identity] = refreshedAt
                }

                if !cached.isEmpty {
                    let prepared = await self.prepare(cached, for: identity)
                    guard self.isCurrentReload(generation, identity: identity) else { return }
                    self.publish(prepared, for: identity, resetVisiblePage: true)
                    self.isLoading = false
                    hasUsableSnapshot = true
                }
            }

            let shouldFetchNetwork: Bool = {
                guard hasUsableSnapshot else { return true }
                if cachePolicy == .forceNetwork { return true }
                guard let last = self.memoryRefreshDates[identity] else { return true }
                return Date().timeIntervalSince(last) > Self.ttl(for: identity.period)
            }()

            guard shouldFetchNetwork else {
                AppLog.network.debug("Trending memory snapshot + TTL 内, skip storage/network (\(identity.logValue, privacy: .public))")
                self.finishReloadIfCurrent(generation, identity: identity)
                return
            }

            self.isLoading = !hasUsableSnapshot
            self.isRefreshing = hasUsableSnapshot

            do {
                let fetchResult = try await self.repository.fetchTrending(
                    since: identity.period,
                    language: .all
                )
                guard self.isCurrentReload(generation, identity: identity) else { return }

                let prepared = await self.prepare(fetchResult.repos, for: identity)
                guard self.isCurrentReload(generation, identity: identity) else { return }

                self.publish(prepared, for: identity, resetVisiblePage: !hasUsableSnapshot)
                if case .cachedFallback = fetchResult.source {
                    // 网络失败但仓库层回退了缓存：保留旧刷新时间，只提示横条。
                    self.loadError = nil
                    self.cacheWarning = Self.cacheFallbackWarning(fetchResult.fallbackErrorDescription)
                    AppLog.network.warning(
                        "Trending fetch returned cachedFallback: \(fetchResult.fallbackErrorDescription ?? "", privacy: .public)"
                    )
                } else {
                    let refreshedAt = Date()
                    self.lastRefreshedAt = refreshedAt
                    self.memoryRefreshDates[identity] = refreshedAt
                    self.loadError = nil
                    self.cacheWarning = nil
                }
            } catch {
                guard self.isCurrentReload(generation, identity: identity) else { return }
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("diagnostics.operation.loadTrending"),
                    service: "Trending"
                )
                if hasUsableSnapshot {
                    // 与探索发现一致：列表继续用缓存，横条说明刷新失败原因。
                    self.loadError = nil
                    self.cacheWarning = Self.cacheFallbackWarning(friendly.message)
                    AppLog.network.warning("Trending 后台刷新失败但内存有快照，保持已显示: \(error.localizedDescription, privacy: .public)")
                    friendly.record(
                        level: .warning,
                        category: "network",
                        operation: "trending.reload",
                        service: "trending"
                    )
                } else {
                    self.loadError = friendly.message
                    self.cacheWarning = nil
                    friendly.record(category: "network", operation: "trending.reload", service: "trending")
                }
            }

            self.finishReloadIfCurrent(generation, identity: identity)
        }

        currentReloadTask = task
        await task.value
        if isCurrentReload(generation, identity: identity) {
            currentReloadTask = nil
            currentReloadIdentity = nil
            currentReloadPolicy = nil
        }
    }

    /// 从后台 actor 读取已有快照，并用 signpost 记录纯派生耗时。
    private func preparedMemorySnapshot(
        for identity: TrendingQueryIdentity
    ) async -> TrendingPreparedSnapshot? {
        while !Task.isCancelled {
            let context = currentDerivationContext
            let token = PerformanceTracer.shared.begin(.trendingDerive)
            let snapshot = await listPipeline.preparedSnapshot(for: identity, context: context)
            PerformanceTracer.shared.end(token)

            // actor 执行期间用户可能继续切换排序或筛选。只允许与当前输入完全一致的
            // 快照离开这里；否则用最新 context 重算，避免旧结果短暂上屏。
            if context == currentDerivationContext {
                return snapshot
            }
        }
        return nil
    }

    /// 将缓存或网络结果写入后台 actor，再用当前最新派生输入生成可发布快照。
    private func prepare(
        _ repos: [TrendingRepo],
        for identity: TrendingQueryIdentity
    ) async -> TrendingPreparedSnapshot {
        while !Task.isCancelled {
            let context = currentDerivationContext
            let token = PerformanceTracer.shared.begin(.trendingDerive)
            let snapshot = await listPipeline.prepare(
                repos: repos,
                for: identity,
                context: context
            )
            PerformanceTracer.shared.end(token)
            if context == currentDerivationContext {
                return snapshot
            }
        }

        // 取消后的结果会被外层 generation guard 丢弃；这里仍返回一个完整值以保持 API
        // 非可选，并避免在并发边界使用强制解包。
        return await listPipeline.prepare(
            repos: repos,
            for: identity,
            context: currentDerivationContext
        )
    }

    private var currentDerivationContext: TrendingDerivationContext {
        TrendingDerivationContext(
            sort: selectedSort,
            filter: globalFilter,
            languagePreferences: userLanguagePreferences,
            selectedLanguage: selectedLanguage,
            interestedLanguages: Set(interestedLanguages.map { $0.lowercased() })
        )
    }

    /// MainActor 只发布已经准备好的值；不在发布区间做排序、评分或数据库访问。
    private func publish(
        _ snapshot: TrendingPreparedSnapshot,
        for identity: TrendingQueryIdentity,
        resetVisiblePage: Bool
    ) {
        PerformanceTracer.shared.trace(.trendingPublish) {
            let oldIDs = publishedRepoIdentityIDs
            let newIDs = snapshot.identityIDs
            let queryChanged = publishedQueryIdentity != identity
            let identityChanged = queryChanged || oldIDs != newIDs

            filterCandidateRepos = snapshot.allRepos
            allRepos = snapshot.repos
            publishedRepoIdentityIDs = snapshot.identityIDs
            scoreCache = snapshot.scores
            recommendedRepos = snapshot.recommendedRepos
            publishedQueryIdentity = identity
            loadError = nil
            cacheWarning = nil

            if resetVisiblePage || identityChanged {
                visibleLimit = Self.pageSize
            }
            repos = Array(allRepos.prefix(visibleLimit))
            if identityChanged {
                reposRevision += 1
                AppLog.network.debug(
                    "Trending publish \(identity.logValue, privacy: .public), identity \(oldIDs.count) → \(newIDs.count)"
                )
            }
        }
    }

    private func isCurrentReload(
        _ generation: UInt64,
        identity: TrendingQueryIdentity
    ) -> Bool {
        !Task.isCancelled
            && reloadGeneration == generation
            && currentQueryIdentity == identity
    }

    private func finishReloadIfCurrent(
        _ generation: UInt64,
        identity: TrendingQueryIdentity
    ) {
        guard isCurrentReload(generation, identity: identity) else { return }
        isLoading = false
        isRefreshing = false
    }

    // MARK: - Freshness（新鲜度展示）

    /// 当前桶距上次刷新经过的秒数；从未刷新过返回 nil。
    var secondsSinceLastRefresh: TimeInterval? {
        guard let date = lastRefreshedAt else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// 当前桶数据是否接近过期（超过当前周期 TTL 的 80%）。
    /// 超过此阈值 UI 会用橙色提示陈旧（不强制刷新，仅视觉信号）。
    var isStale: Bool {
        guard let secs = secondsSinceLastRefresh else { return false }
        return secs > Self.ttl(for: selectedPeriod) * 0.8
    }

    /// 当前桶可用的"刷新提示"文本（如"刚刚" / "12 分钟前" / "1 小时前" / "1 天前"）。
    /// 没有 lastRefreshedAt 返回 nil，UI 隐藏新鲜度提示。
    var formattedFreshness: String? {
        guard let secs = secondsSinceLastRefresh else { return nil }
        if secs < 30 {
            return String.l10n("relative.justNow")
        }
        if secs < 60 {
            return String.l10n("relative.justNow")
        }
        let minutes = Int(secs / 60)
        if minutes < 60 {
            return String(format: String.l10n("trending.freshness.minutesAgoFormat"), minutes)
        }
        let hours = Int(secs / 3600)
        if hours < 24 {
            return String(format: String.l10n("trending.freshness.hoursAgoFormat"), hours)
        }
        let days = Int(secs / 86400)
        return String(format: String.l10n("trending.freshness.daysAgoFormat"), days)
    }

    /// 请求 AI 摘要
    func requestSummary(for repo: TrendingRepo) async {
        guard !summarizingRepoIDs.contains(repo.fullName) else { return }

        summarizingRepoIDs.insert(repo.fullName)

        // TODO: 调用 AI 服务生成摘要
        // 临时模拟：2 秒后返回占位文本
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let language = repo.language ?? String.l10n("trending.summary.openSource")
        summaryCache[repo.fullName] = String(
            format: String.l10n("trending.summary.placeholderFormat"),
            language
        )

        summarizingRepoIDs.remove(repo.fullName)
    }

    /// 获取 repo 的 AI 评分
    func score(for repo: TrendingRepo) -> TrendingScore {
        // 评分在后台快照派生阶段统一计算；这里绝不在 MainActor 补算或写缓存。
        scoreCache[repo.fullName] ?? TrendingScore(total: 0, growthRate: 0, activity: 0, quality: 0)
    }

    /// 从本地 Stars 语言分布生成偏好权重。
    func updateLanguagePreferences(from stats: [LanguageStat]) async {
        let total = stats.reduce(0) { $0 + $1.count }
        let preferences: [String: Double]
        if total > 0 {
            preferences = Dictionary(uniqueKeysWithValues: stats.compactMap { stat in
                guard !stat.language.isEmpty else { return nil }
                return (stat.language, Double(stat.count) / Double(total))
            })
        } else {
            preferences = [:]
        }

        guard userLanguagePreferences != preferences else { return }
        userLanguagePreferences = preferences

        let identity = currentQueryIdentity
        let snapshot = await preparedMemorySnapshot(for: identity)
        guard identity == currentQueryIdentity, let snapshot else { return }
        publish(snapshot, for: identity, resetVisiblePage: false)
    }

    /// 当前中栏实际展示的列表。
    ///
    /// 排序已经在 `TrendingListPipeline` actor 中完成；保留这个属性作为既有调用方的
    /// 兼容读取面，但不再在 SwiftUI body 求值期间创建新的全量数组。
    var displayedRepos: [TrendingRepo] {
        repos
    }

    /// 与探索发现共用文案键：刷新失败但仍展示本地缓存。
    private static func cacheFallbackWarning(_ errorDescription: String?) -> String {
        // 底层 TLS / 网络细节只进日志；横条用固定用户文案。
        if let errorDescription, !errorDescription.isEmpty {
            AppLog.network.warning("Trending cache fallback detail: \(errorDescription, privacy: .public)")
        }
        return String.l10n("explore.cacheFallback.warning")
    }

}

// MARK: - TrendingScore

/// AI 评分模型
struct TrendingScore: Equatable, Sendable {
    /// 综合评分 (0-100)
    let total: Int

    /// Star 增长率 (0-1)
    let growthRate: Double

    /// 活跃度 (0-10)
    let activity: Double

    /// 质量指标 (0-1)
    let quality: Double

    /// 评分等级
    var level: ScoreLevel {
        switch total {
        case 80...: return .excellent
        case 60..<80: return .good
        case 40..<60: return .average
        default: return .low
        }
    }
}

/// 评分等级
enum ScoreLevel {
    case excellent
    case good
    case average
    case low

    var color: String {
        switch self {
        case .excellent: return "green"
        case .good: return "blue"
        case .average: return "orange"
        case .low: return "gray"
        }
    }

    /// UI 里展示的评分等级名称；rawValue 仅保留为内部稳定标识。
    var displayName: LocalizedStringKey {
        switch self {
        case .excellent: return "trending.score.excellent"
        case .good: return "trending.score.good"
        case .average: return "trending.score.average"
        case .low: return "trending.score.low"
        }
    }
}
