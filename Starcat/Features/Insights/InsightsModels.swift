//
//  InsightsModels.swift
//  Starcat
//
//  洞察中心前端展示模型。首阶段由 Mock provider 供数，后续真实 SQLite / GitHub
//  provider 继续产出同一组快照，避免数据接入时重写 SwiftUI 页面。
//

import Foundation

/// “我的洞察”统计范围。每个快照只能属于一个明确范围，避免卡片静默混用口径。
enum InsightsScope: String, CaseIterable, Identifiable, Sendable {
    case starred
    case knowledge

    var id: String { rawValue }
}

/// 洞察中心左栏二级主题。
enum InsightsTopic: String, CaseIterable, Identifiable, Sendable {
    case overview
    case organization
    case technology
    case health

    var id: String { rawValue }
}

/// 中栏当前选择的摘要或待处理集合。
enum InsightsSelection: String, CaseIterable, Identifiable, Sendable {
    case summary
    case untagged
    case unread
    case indexIssues
    case healthPending

    var id: String { rawValue }
}

/// 单个 KPI。数值保持原始 Int，格式化交给 View 结合当前 Locale 完成。
struct InsightsMetric: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let value: Int
    let detailKey: String
    let systemImage: String
    let tintName: String
}

/// 占比型统计项，用于状态、标签和语言分布。
struct InsightsDistributionItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let count: Int
    let fraction: Double
    let colorName: String
}

/// 需要处理的动作项。`selection` 是中栏下钻目标，不直接携带业务筛选闭包。
struct InsightsActionItem: Identifiable, Equatable, Sendable {
    let id: InsightsSelection
    let titleKey: String
    let detailKey: String
    let count: Int
    let systemImage: String
    let tintName: String
}

/// 覆盖率统计，Health 与 OpenSSF 分开表达，避免把两个来源混成一个分数。
struct InsightsCoverage: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

/// “我的洞察”一次一致快照。
struct MyInsightsSnapshot: Equatable, Sendable {
    let scope: InsightsScope
    let generatedAt: Date
    let metrics: [InsightsMetric]
    let statusItems: [InsightsDistributionItem]
    let languageItems: [InsightsDistributionItem]
    let actionItems: [InsightsActionItem]
    let healthCoverage: InsightsCoverage
    let openSSFCoverage: InsightsCoverage
}

/// 仓库洞察活动统计。
struct RepositoryActivityMetric: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let value: Int
    let delta: Int
    let systemImage: String
    let tintName: String
}

/// 按周聚合的提交柱状图数据。
struct RepositoryCommitPoint: Identifiable, Equatable, Sendable {
    let id: Int
    let weekLabel: String
    let commits: Int
}

/// Star 历史折线中的单点。
struct StarHistoryPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let count: Int

    var id: Date { date }
}

/// 贡献者摘要。Mock 阶段使用首字母头像，避免引入远端图片依赖。
struct RepositoryContributor: Identifiable, Equatable, Sendable {
    let id: String
    let login: String
    let commits: Int
    let colorName: String
}

/// Starcat 当前四维健康度。
struct RepositoryHealthDimensionItem: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let score: Int
    let systemImage: String
    let tintName: String
}

/// 社区或安全信号。
struct RepositorySignal: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case positive
        case warning
        case missing
    }

    let id: String
    let titleKey: String
    let detailKey: String
    let state: State
    let systemImage: String
}

/// 最近活动时间线。
struct RepositoryTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let relativeTimeKey: String
    let systemImage: String
    let tintName: String
}

/// 单仓库洞察完整快照。只保存展示所需标量，不持有 `Repo`，便于后续跨 actor 传递。
struct RepositoryInsightsSnapshot: Equatable, Sendable {
    let repoID: Int64
    let fullName: String
    let generatedAt: Date
    let currentStars: Int
    let starGrowth30Days: Int
    let starGrowthOneYear: Int
    let starHistory: [StarHistoryPoint]
    let activityMetrics: [RepositoryActivityMetric]
    let commitPoints: [RepositoryCommitPoint]
    let contributors: [RepositoryContributor]
    let healthDimensions: [RepositoryHealthDimensionItem]
    let communitySignals: [RepositorySignal]
    let securitySignals: [RepositorySignal]
    let timelineItems: [RepositoryTimelineItem]
}
