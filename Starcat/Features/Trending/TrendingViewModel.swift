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

    /// 加载中状态
    private(set) var isLoading: Bool = false

    /// 错误信息
    private(set) var loadError: String?

    /// 订阅（GitHub Star）失败信息。
    private(set) var subscriptionError: String?

    // MARK: - 筛选状态

    /// 当前时间周期
    var selectedPeriod: TrendingPeriod = .daily {
        didSet {
            guard oldValue != selectedPeriod else { return }
            Task { await reload() }
        }
    }

    /// 当前语言筛选
    var selectedLanguage: TrendingLanguage = .all {
        didSet {
            guard oldValue != selectedLanguage else { return }
            Task { await reload() }
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

    /// 刷新 Trending 列表
    func reload() async {
        // 取消旧任务
        currentReloadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }

            self.isLoading = true
            self.loadError = nil

            do {
                let fetched = try await self.repository.fetchTrending(
                    since: self.selectedPeriod,
                    language: self.selectedLanguage
                )

                // race 防护
                guard !Task.isCancelled else { return }

                self.repos = fetched

                // 预计算 AI 评分
                self.precomputeScores()

            } catch {
                guard !Task.isCancelled else { return }
                self.loadError = error.localizedDescription
                self.repos = []
            }

            self.isLoading = false
        }

        currentReloadTask = task
        await task.value
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
