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
//  语义化 `TrendingCachePolicy` enum（`.respectTTL` / `.forceNetwork`）+ 24h TTL。
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
/// - `.respectTTL`：尊重 24h 客户端 TTL —— 缓存命中且未过期则不走网络；
///   过期或空缓存才发请求。用于首次入场、周期切换、语言切换等"非用户主动刷新"场景。
/// - `.forceNetwork`：绕过 TTL 永远走网络。用于 toolbar 刷新按钮、`refreshable` 下拉、
///   错误重试等"用户主动要新数据"场景。
///
/// 与 dong4j 讨论权衡：把 cachePolicy 放在 ViewModel 层（而非 Repository.fetchTrending
/// 入参），让 Repository 协议保持纯净，避免引入"返回值标记 from-cache vs from-network"
/// 的复杂度（否则 ViewModel 无法判断要不要更新 `lastRefreshedAt = Date()`，会出现
/// "TTL 命中 → 更新刷新时间 → always-fresh 死循环"的 bug）。
enum TrendingCachePolicy: Sendable {
    case respectTTL
    case forceNetwork
}

/// Trending 中栏的本地排序方式。
///
/// `recommended` 保留 trending-api 返回顺序,也就是官方趋势榜原始排名；其它选项只对
/// 当前已加载列表做本地排序,不改变缓存桶和远端请求参数。
enum TrendingSortOption: String, CaseIterable, Identifiable {
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
            return "textformat.abc"
        case .nameDesc:
            return "textformat.abc.dottedunderline"
        case .risingTrend:
            return "chart.line.uptrend.xyaxis"
        }
    }
}

@MainActor
@Observable
final class TrendingViewModel {

    // MARK: - TTL 常量

    /// 客户端 Trending 缓存的 TTL：24 小时。
    ///
    /// 设计动机：与后端 trending-api 的 cron 节奏对齐 —— daily 桶每 1h 更新一次但客户端
    /// 不必每 1h 都拉（用户感知不到，浪费请求）；weekly 桶 6h 更新一次，monthly 桶 24h+。
    /// 取 24h 作为单一常量是这三档的平衡值：
    /// - 对 daily 桶用户感知到的"最旧数据"约 24h（在 trending 主要消费场景下可接受）
    /// - 对 weekly / monthly 桶 TTL 内永远命中本地，零请求
    ///
    /// 与 PR-1.5 后端 `TrendingCache` 的分桶 TTL（daily 1h / weekly 6h / monthly 24h）
    /// 互补：客户端 24h 是"用户体感节奏"，后端是"数据新鲜度节奏"，两端独立判定。
    static let trendingTTL: TimeInterval = 86_400

    // MARK: - 数据状态

    /// 当前 Trending 列表（可变，用于 star 操作后更新本地计数）
    var repos: [TrendingRepo] = []

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
    /// UI 用法：toolbar 显示"X 分钟前"新鲜度提示；超过 20 小时（`isStale`，80% TTL）变橙色。
    /// 没缓存 / 还没刷新过返回 nil，UI 隐藏新鲜度提示。
    private(set) var lastRefreshedAt: Date?

    /// 加载中状态
    private(set) var isLoading: Bool = false

    /// 后台刷新中状态。
    ///
    /// 与 `isLoading` 区分：`isLoading` 是"无缓存 + 网络在跑"的全屏 loading；
    /// `isRefreshing` 是"有缓存 + 网络在跑"的轻量后台刷新（toolbar 刷新 icon 旋转）。
    /// 同一时间至多一个为 true。
    private(set) var isRefreshing: Bool = false

    /// 错误信息
    private(set) var loadError: String?

    // MARK: - 筛选状态

    /// 当前时间周期
    var selectedPeriod: TrendingPeriod = .daily {
        didSet {
            guard oldValue != selectedPeriod else { return }
            // 周期切换 = 切到另一个 (period, language) 桶，按 TTL 决定是否走网络
            // 如果目标桶 24h 内拉过 → 直接走缓存零等待；否则才发请求
            // R-06.1 之前是 `forceNetwork: true` 一律走网络，浪费"刚 6 分钟前看过 weekly"这种用户路径
            Task { await reload(cachePolicy: .respectTTL) }
        }
    }

    /// 当前语言筛选
    var selectedLanguage: TrendingLanguage = .all {
        didSet {
            guard oldValue != selectedLanguage else { return }
            // 语言切换同样切桶，按 TTL 决定（与 selectedPeriod 同款理由）
            Task { await reload(cachePolicy: .respectTTL) }
        }
    }

    /// 当前中栏排序方式。默认保留 trending-api 返回顺序,即官方趋势榜原始排名。
    var selectedSort: TrendingSortOption = .recommended {
        didSet {
            guard oldValue != selectedSort else { return }
            reposRevision += 1
        }
    }

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
    var userLanguagePreferences: [String: Double] = [:]

    /// 用户收藏偏好：主题分布（基于 topics）
    var userTopicPreferences: [String: Double] = [:]

    // MARK: - 依赖

    private let repository: any TrendingRepositoryProtocol
    private let githubAPIClient: any GitHubAPIClientProtocol

    /// 当前 in-flight 的 reload 任务
    private var currentReloadTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        repository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol
    ) {
        self.repository = repository
        self.githubAPIClient = githubAPIClient
    }

    // MARK: - Public Actions

    /// 刷新 Trending 列表（R-06.1 TTL 升级版，2026-06-15 改造）。
    ///
    /// **R-06.1 设计变更**（相比 2026-06-02 智能 revision 版）：
    /// - `forceNetwork: Bool` 升级为 `cachePolicy: TrendingCachePolicy` enum，语义更清晰
    /// - 在"缓存命中"分支加入 TTL 判断：`.respectTTL` + 缓存在 24h 内 → 跳过网络；
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
    /// - 缓存命中 + `.respectTTL` + TTL 内 → **完全不走网络**（24h 内零打扰，关键）
    /// - 缓存命中 + `.respectTTL` + TTL 过期 → 上屏缓存 → 后台拉网络 → 智能 revision
    /// - 缓存命中 + `.forceNetwork` → 上屏缓存 → 后台拉网络 → 智能 revision
    /// - 缓存空 → 必拉网络（不管 cachePolicy），isLoading=true
    /// - 网络失败 + 有缓存 → 保留已显示，仅 loadError 记录
    /// - 网络失败 + 无缓存 → errorView
    ///
    /// 智能 revision 规则（关键，与 2026-06-02 版本一致）：
    /// - 缓存上屏总是 bump revision（首屏入场动画）
    /// - 网络回来对比 oldIDs vs newIDs：身份序列变化才 bump
    /// - "身份序列" = `repos.map(\.fullName)` ordered list，stars/forks 等数值不算
    ///
    /// 注意：网络成功时 fetchTrending 已经 race-free（actor 内的 DB 写入是顺序的），
    /// 这里 ViewModel 层用 currentReloadTask 取消老任务即可。
    func reload(cachePolicy: TrendingCachePolicy = .respectTTL) async {
        // 取消旧任务
        currentReloadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }

            // ① 拿"上次刷新时间"放出来（toolbar 新鲜度提示首屏可见）
            self.lastRefreshedAt = await self.repository.lastRefreshedAt(
                since: self.selectedPeriod,
                language: self.selectedLanguage
            )
            guard !Task.isCancelled else { return }

            // ② 第一阶段：读本地缓存
            let cached = await self.repository.cachedTrending(
                since: self.selectedPeriod,
                language: self.selectedLanguage
            )
            guard !Task.isCancelled else { return }

            let hasUsableCache = !cached.isEmpty
            if hasUsableCache {
                self.repos = cached
                self.reposRevision += 1   // 缓存上屏 = 首屏入场，需要 row reveal 动画
                self.precomputeScores()
                self.loadError = nil
                self.isLoading = false
            } else {
                // 没缓存 → 进 isLoading 让 UI 显示 ProgressView
                self.repos = []
                self.isLoading = true
                self.loadError = nil
            }

            // ③ 第二阶段：是否走网络？
            //   - 缓存空 → 必走（无脑拉）
            //   - .forceNetwork → 走（用户主动 / 重试 / 下拉刷新，绕过 TTL）
            //   - .respectTTL + 缓存有 + TTL 内 → 跳过（24h 内零打扰）
            //   - .respectTTL + 缓存有 + TTL 过期 → 走（自动后台刷新）
            let shouldFetchNetwork: Bool = {
                if !hasUsableCache { return true }
                switch cachePolicy {
                case .forceNetwork:
                    return true
                case .respectTTL:
                    guard let last = self.lastRefreshedAt else { return true }
                    let age = Date().timeIntervalSince(last)
                    return age > Self.trendingTTL
                }
            }()
            guard shouldFetchNetwork else {
                AppLog.network.debug("Trending cache hit + TTL 内, skip network (policy=.respectTTL)")
                self.isLoading = false
                self.isRefreshing = false
                return
            }

            // 后台刷新指示器：仅在"有缓存 + 走网络"时点亮（避免与全屏 isLoading 重复）
            if hasUsableCache {
                self.isRefreshing = true
            }

            do {
                let fetched = try await self.repository.fetchTrending(
                    since: self.selectedPeriod,
                    language: self.selectedLanguage
                )
                guard !Task.isCancelled else { return }

                // ④ 智能 revision：对比身份序列，变化才 bump
                let oldIDs = self.repos.map(\.fullName)
                let newIDs = fetched.map(\.fullName)
                let identityChanged = oldIDs != newIDs

                self.repos = fetched   // 不管是否 bump revision，都要赋值（让 SwiftUI 自然 diff 数值字段）
                if identityChanged {
                    self.reposRevision += 1
                    AppLog.network.debug("Trending identity changed (\(oldIDs.count) → \(newIDs.count)), bumped revision")
                } else {
                    AppLog.network.debug("Trending identity unchanged, in-place update only")
                }

                self.precomputeScores()
                self.loadError = nil
                self.lastRefreshedAt = Date()   // 网络成功后立即更新（避免再 query DB）
            } catch {
                guard !Task.isCancelled else {
                    self.isRefreshing = false
                    return
                }
                if hasUsableCache {
                    // 缓存还能用 → 保持已上屏，仅记录错误（UI 在 toolbar 显示刷新失败提示）
                    let friendly = UserFacingError.map(
                        error,
                        operation: String.l10n("diagnostics.operation.loadTrending"),
                        service: "Trending"
                    )
                    self.loadError = friendly.message
                    AppLog.network.warning("Trending 后台刷新失败但本地有缓存，保持已显示: \(error.localizedDescription, privacy: .public)")
                    friendly.record(level: .warning, category: "network", operation: "trending.reload", service: "trending")
                } else {
                    // 没缓存又拉失败 → 走原 errorView 流程
                    let friendly = UserFacingError.map(
                        error,
                        operation: String.l10n("diagnostics.operation.loadTrending"),
                        service: "Trending"
                    )
                    self.loadError = friendly.message
                    self.repos = []
                    self.reposRevision += 1
                    friendly.record(category: "network", operation: "trending.reload", service: "trending")
                }
            }

            self.isLoading = false
            self.isRefreshing = false
        }

        currentReloadTask = task
        await task.value
    }

    // MARK: - Freshness（新鲜度展示）

    /// 当前桶距上次刷新经过的秒数；从未刷新过返回 nil。
    var secondsSinceLastRefresh: TimeInterval? {
        guard let date = lastRefreshedAt else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// 当前桶数据是否陈旧（>20 小时，约为 24h TTL 的 80%）。
    /// 超过此阈值 UI 会用橙色提示陈旧（不强制刷新，仅视觉信号）。
    ///
    /// R-06.1（2026-06-15）：阈值从 1h 调整到 20h，与新的 24h TTL 对齐。
    /// 20h 是"接近过期"的预警位置：用户视觉看到橙色 → 知道再过 4h 数据会被自动刷新；
    /// 直接绑 TTL（24h）的话只在过期那刻变色，预警价值为零。
    var isStale: Bool {
        guard let secs = secondsSinceLastRefresh else { return false }
        return secs > 72_000 // 20h = 20 * 3600
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
        if let cached = scoreCache[repo.fullName] {
            return cached
        }

        // 计算评分
        let score = calculateScore(for: repo)
        scoreCache[repo.fullName] = score
        return score
    }

    /// 从本地 Stars 语言分布生成偏好权重。
    func updateLanguagePreferences(from stats: [LanguageStat]) {
        let total = stats.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            userLanguagePreferences = [:]
            return
        }

        userLanguagePreferences = Dictionary(uniqueKeysWithValues: stats.compactMap { stat in
            guard !stat.language.isEmpty else { return nil }
            return (stat.language, Double(stat.count) / Double(total))
        })
    }

    /// 推荐区使用的仓库列表。
    ///
    /// 有本地语言偏好时优先匹配用户常 star 的语言；没有偏好时退化为当前榜单评分最高的项目，
    /// 这样未登录 / 未同步状态也能展示“发现”价值，而不是让区块永远消失。
    var recommendedRepos: [TrendingRepo] {
        let ranked: [TrendingRepo]
        if userLanguagePreferences.isEmpty {
            ranked = repos.sorted { score(for: $0).total > score(for: $1).total }
        } else {
            ranked = repos.sorted { lhs, rhs in
                let lhsPreference = userLanguagePreferences[lhs.language ?? ""] ?? 0
                let rhsPreference = userLanguagePreferences[rhs.language ?? ""] ?? 0
                if lhsPreference != rhsPreference {
                    return lhsPreference > rhsPreference
                }
                return score(for: lhs).total > score(for: rhs).total
            }
        }

        return Array(ranked.prefix(3))
    }

    /// 当前中栏实际展示的列表。
    ///
    /// `repos` 保存 API/缓存原始顺序,供推荐计算、身份对比和恢复官方 ranking 使用；
    /// UI 统一读取 `displayedRepos`,避免排序状态污染底层缓存语义。
    var displayedRepos: [TrendingRepo] {
        switch selectedSort {
        case .recommended:
            return repos
        case .starsDesc:
            return repos.sorted { $0.starsCount > $1.starsCount }
        case .starsAsc:
            return repos.sorted { $0.starsCount < $1.starsCount }
        case .nameAsc:
            return repos.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        case .nameDesc:
            return repos.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedDescending }
        case .updatedDesc:
            return repos.sorted { trendingDate($0.updatedAt) > trendingDate($1.updatedAt) }
        case .updatedAsc:
            return repos.sorted { trendingDate($0.updatedAt) < trendingDate($1.updatedAt) }
        case .createdDesc:
            return repos.sorted { trendingDate($0.createdAt) > trendingDate($1.createdAt) }
        case .createdAsc:
            return repos.sorted { trendingDate($0.createdAt) < trendingDate($1.createdAt) }
        case .risingTrend:
            return repos.sorted {
                if $0.starsInPeriod != $1.starsInPeriod {
                    return $0.starsInPeriod > $1.starsInPeriod
                }
                if $0.starsCount != $1.starsCount {
                    return $0.starsCount > $1.starsCount
                }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        }
    }

    // MARK: - Private

    private func trendingDate(_ text: String?) -> Date {
        guard let text, let date = ISO8601DateFormatter.shared.date(from: text) else {
            return .distantPast
        }
        return date
    }

    /// 预计算所有 repo 的 AI 评分
    private func precomputeScores() {
        for repo in repos {
            let score = calculateScore(for: repo)
            scoreCache[repo.fullName] = score
        }
    }

    /// 计算单个 repo 的 AI 评分
    private func calculateScore(for repo: TrendingRepo) -> TrendingScore {
        // 多维度评分：
        // 1. Star 增长率 (starsInPeriod / starsCount)
        // 2. 活跃度 (forksCount / starsCount)
        // 3. 质量指标 (contributors 数量)

        let growthRate: Double
        if repo.starsCount > 0 {
            growthRate = Double(repo.starsInPeriod) / Double(repo.starsCount)
        } else {
            growthRate = 0
        }

        let forkRatio: Double
        if repo.starsCount > 0 {
            forkRatio = Double(repo.forksCount) / Double(repo.starsCount)
        } else {
            forkRatio = 0
        }

        let contributorBonus = min(Double(repo.contributors.count) * 2, 10) // 最多 5 个贡献者，每个加 2 分

        // 综合评分 (0-100)
        let growthScore = min(growthRate * 100 * 10, 40)  // 增长率权重 40%
        let qualityScore = min(forkRatio * 30, 30)         // 质量权重 30%
        let activityScore = contributorBonus               // 活跃度权重 30%

        let total = growthScore + qualityScore + activityScore

        return TrendingScore(
            total: Int(total),
            growthRate: growthRate,
            activity: contributorBonus,
            quality: forkRatio
        )
    }
}

// MARK: - TrendingScore

/// AI 评分模型
struct TrendingScore: Equatable {
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
