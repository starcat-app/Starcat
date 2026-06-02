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
//  - 处理 AI 摘要请求
//  - 处理一键订阅到 Stars
//
//  设计约束：
//  - @MainActor + @Observable，所有状态变更在主线程
//  - 依赖 TrendingRepositoryProtocol，便于测试注入 Mock
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TrendingViewModel {

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
    /// UI 用法：toolbar 显示"X 分钟前"新鲜度提示；超过 1 小时（`isStale`）变橙色。
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

    /// 订阅（GitHub Star）失败信息。
    private(set) var subscriptionError: String?

    // MARK: - 筛选状态

    /// 当前时间周期
    var selectedPeriod: TrendingPeriod = .daily {
        didSet {
            guard oldValue != selectedPeriod else { return }
            // 周期切换 = 用户主动选择"换榜单"，强制走网络拿最新数据
            Task { await reload(forceNetwork: true) }
        }
    }

    /// 当前语言筛选
    var selectedLanguage: TrendingLanguage = .all {
        didSet {
            guard oldValue != selectedLanguage else { return }
            // 语言切换同样视为"换榜单"，强制刷新
            Task { await reload(forceNetwork: true) }
        }
    }

    // MARK: - AI 摘要状态

    /// 正在生成摘要的 repo id 集合
    private(set) var summarizingRepoIDs: Set<String> = []

    /// 摘要结果缓存：repo fullName -> 摘要文本
    private(set) var summaryCache: [String: String] = [:]

    // MARK: - 订阅状态

    /// 正在订阅的 repo fullName 集合。
    private(set) var subscribingRepoIDs: Set<String> = []

    /// 本次会话里已经订阅成功的 repo fullName 集合。
    private(set) var subscribedRepoIDs: Set<String> = []

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

    /// 刷新 Trending 列表（智能 revision 升级版，2026-06-02 改造）。
    ///
    /// **核心设计变更**（相比 W7+ 初版无脑 SWR）：
    /// - 引入 `forceNetwork` 参数区分"主动刷新"vs"进入页面"
    /// - 第二阶段拿到 fresh 数据后，对比 fullName 序列，**只在身份变化时** bump reposRevision；
    ///   stars/forks 等数值变化让 SwiftUI 自然 in-place diff，**避免每次进页面都重播入场动画**
    ///
    /// 行为矩阵：
    /// | 入口 | forceNetwork | 缓存空 | 缓存有 |
    /// |------|--------------|--------|--------|
    /// | 进入页面 (.task) | false | 走网络 + isLoading | 上屏缓存 + 不走网络 |
    /// | 周期/语言切换 | true | 走网络 + isLoading | 上屏缓存 + 后台刷新 + isRefreshing |
    /// | 主动刷新按钮 | true | 走网络 + isLoading | 上屏缓存 + 后台刷新 + isRefreshing |
    /// | 错误重试 | true | 走网络 + isLoading | 上屏缓存 + 后台刷新 + isRefreshing |
    ///
    /// SWR 关键约束：
    /// - 缓存命中 + forceNetwork=false → **完全不走网络**（首次进页面零打扰，关键）
    /// - 缓存命中 + forceNetwork=true → 上屏缓存 → 后台拉网络 → 智能 revision 决定动画
    /// - 缓存空 → 必拉网络（不管 forceNetwork），isLoading=true
    /// - 网络失败 + 有缓存 → 保留已显示，仅 loadError 记录
    /// - 网络失败 + 无缓存 → errorView
    ///
    /// 智能 revision 规则（关键）：
    /// - 缓存上屏总是 bump revision（首屏入场动画）
    /// - 网络回来对比 oldIDs vs newIDs：身份序列变化才 bump
    /// - "身份序列" = `repos.map(\.fullName)` ordered list，stars/forks 等数值不算
    ///
    /// 注意：网络成功时 fetchTrending 已经 race-free（actor 内的 DB 写入是顺序的），
    /// 这里 ViewModel 层用 currentReloadTask 取消老任务即可。
    func reload(forceNetwork: Bool = false) async {
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
            //   缓存空 → 必走（无脑拉）
            //   缓存有 + forceNetwork=true → 走（用户主动 / 周期切换 / 重试）
            //   缓存有 + forceNetwork=false → 跳过（首次进页面零打扰）
            let shouldFetchNetwork = !hasUsableCache || forceNetwork
            guard shouldFetchNetwork else {
                AppLog.network.debug("Trending cache hit, skip network (forceNetwork=false)")
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
                    self.loadError = error.localizedDescription
                    AppLog.network.warning("Trending 后台刷新失败但本地有缓存，保持已显示: \(error.localizedDescription, privacy: .public)")
                } else {
                    // 没缓存又拉失败 → 走原 errorView 流程
                    self.loadError = error.localizedDescription
                    self.repos = []
                    self.reposRevision += 1
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

    /// 当前桶数据是否陈旧（>1 小时）。
    /// 超过此阈值 UI 会用橙色提示陈旧（不强制刷新，仅视觉信号）。
    var isStale: Bool {
        guard let secs = secondsSinceLastRefresh else { return false }
        return secs > 3600
    }

    /// 当前桶可用的"刷新提示"文本（如"刚刚" / "12 分钟前" / "1 小时前" / "1 天前"）。
    /// 没有 lastRefreshedAt 返回 nil，UI 隐藏新鲜度提示。
    var formattedFreshness: String? {
        guard let secs = secondsSinceLastRefresh else { return nil }
        if secs < 30 {
            return String(localized: "trending.freshness.justNow")
        }
        if secs < 60 {
            return String(localized: "trending.freshness.lessThanMinute")
        }
        let minutes = Int(secs / 60)
        if minutes < 60 {
            return String(format: String(localized: "trending.freshness.minutesAgoFormat"), minutes)
        }
        let hours = Int(secs / 3600)
        if hours < 24 {
            return String(format: String(localized: "trending.freshness.hoursAgoFormat"), hours)
        }
        let days = Int(secs / 86400)
        return String(format: String(localized: "trending.freshness.daysAgoFormat"), days)
    }

    /// 请求 AI 摘要
    func requestSummary(for repo: TrendingRepo) async {
        guard !summarizingRepoIDs.contains(repo.fullName) else { return }

        summarizingRepoIDs.insert(repo.fullName)

        // TODO: 调用 AI 服务生成摘要
        // 临时模拟：2 秒后返回占位文本
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let language = repo.language ?? String(localized: "trending.summary.openSource")
        summaryCache[repo.fullName] = String(
            format: String(localized: "trending.summary.placeholderFormat"),
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

    /// 一键订阅（star 到 GitHub）
    func subscribe(repo: TrendingRepo) async throws {
        guard !subscribingRepoIDs.contains(repo.fullName),
              !subscribedRepoIDs.contains(repo.fullName)
        else { return }

        subscribingRepoIDs.insert(repo.fullName)
        subscriptionError = nil
        defer { subscribingRepoIDs.remove(repo.fullName) }

        do {
            try await githubAPIClient.star(owner: repo.owner, repo: repo.name)
            subscribedRepoIDs.insert(repo.fullName)

            // 本地 stars 计数 +1（UI 即时反馈）
            if let index = repos.firstIndex(where: { $0.fullName == repo.fullName }) {
                repos[index].starsCount += 1
            }

            AppLog.sync.info("Subscribed to \(repo.fullName, privacy: .public)")
        } catch {
            subscriptionError = String(
                format: String(localized: "trending.subscription.failedFormat"),
                repo.fullName,
                error.localizedDescription
            )
            throw error
        }
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

    /// 更新指定 repo 的本地 stars 计数（star 操作成功后调用）。
    func incrementStarsCount(fullName: String) {
        if let index = repos.firstIndex(where: { $0.fullName == fullName }) {
            repos[index].starsCount += 1
        }
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

    // MARK: - Private

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
