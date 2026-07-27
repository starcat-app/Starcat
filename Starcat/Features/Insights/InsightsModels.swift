//
//  InsightsModels.swift
//  Starcat
//
//  洞察中心前端展示模型。首阶段由 Mock provider 供数，后续真实 SQLite / GitHub
//  provider 继续产出同一组快照，避免数据接入时重写 SwiftUI 页面。
//

import Foundation
import SwiftUI

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

    var titleKey: LocalizedStringKey {
        switch self {
        case .overview:     return "insights.topic.overview"
        case .organization: return "insights.topic.organization"
        case .technology:   return "insights.topic.technology"
        case .health:       return "insights.topic.health"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:     return "rectangle.3.group.fill"
        case .organization: return "tray.full.fill"
        case .technology:   return "chevron.left.forwardslash.chevron.right"
        case .health:       return "heart.text.square.fill"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .overview:     return "insights.topic.overview.subtitle"
        case .organization: return "insights.topic.organization.subtitle"
        case .technology:   return "insights.topic.technology.subtitle"
        case .health:       return "insights.topic.health.subtitle"
        }
    }

    /// 当前主题在中栏展示的分析视图。每个主题都有自己的摘要入口，
    /// 避免左栏和中栏同时出现两个语义不清的“概览”。
    var contentSelections: [InsightsSelection] {
        switch self {
        case .overview:
            return [.overviewSummary]
        case .organization:
            return [.organizationSummary]
        case .technology:
            return [.technologySummary, .languages, .topics, .licenses]
        case .health:
            return [.healthSummary]
        }
    }

    /// 当前主题下真正需要用户处理的集合。索引完整性属于知识整理，
    /// 不归入“技术分布”；概览只提供一个聚合入口，避免重复列出全部动作。
    func attentionSelections(for scope: InsightsScope) -> [InsightsSelection] {
        switch self {
        case .overview:
            return [.allActions]
        case .organization:
            return [
                .untagged,
                .unread,
                .missingReadme,
                .missingIndexableContent,
                .indexIssues
            ].filter { $0.isAvailable(in: scope) }
        case .technology:
            return []
        case .health:
            return [
                .healthPending,
                .openSSFPending,
                .maintenanceRisk,
                .securityRisk
            ]
        }
    }

    func selections(for scope: InsightsScope) -> [InsightsSelection] {
        contentSelections + attentionSelections(for: scope)
    }

    var primarySelection: InsightsSelection {
        contentSelections[0]
    }
}

/// 中栏当前选择的分析视图或待处理集合。
///
/// Selection 必须保持业务语义唯一，不能用同一个 `.summary` 代表四个主题的不同页面；
/// 唯一 case 让三栏选择恢复、标题和 Detail 内容始终一一对应。
enum InsightsSelection: String, CaseIterable, Identifiable, Sendable {
    case overviewSummary
    case allActions
    case organizationSummary
    case untagged
    case unread
    case missingReadme
    case missingIndexableContent
    case indexIssues
    case technologySummary
    case languages
    case topics
    case licenses
    case healthSummary
    case healthPending
    case openSSFPending
    case maintenanceRisk
    case securityRisk

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .overviewSummary:        return "insights.selection.overviewSummary"
        case .allActions:             return "insights.selection.allActions"
        case .organizationSummary:    return "insights.selection.organizationSummary"
        case .untagged:               return "insights.action.untagged"
        case .unread:                 return "insights.action.unread"
        case .missingReadme:          return "insights.action.missingReadme"
        case .missingIndexableContent: return "insights.action.missingIndexableContent"
        case .indexIssues:            return "insights.action.indexIssues"
        case .technologySummary:      return "insights.selection.technologySummary"
        case .languages:              return "insights.selection.languages"
        case .topics:                 return "insights.selection.topics"
        case .licenses:               return "insights.selection.licenses"
        case .healthSummary:          return "insights.selection.healthSummary"
        case .healthPending:          return "insights.action.healthPending"
        case .openSSFPending:         return "insights.action.openSSFPending"
        case .maintenanceRisk:        return "insights.action.maintenanceRisk"
        case .securityRisk:           return "insights.action.securityRisk"
        }
    }

    var systemImage: String {
        switch self {
        case .overviewSummary:         return "rectangle.3.group.fill"
        case .allActions:              return "checklist"
        case .organizationSummary:     return "chart.bar.xaxis"
        case .untagged:                return "tag.slash.fill"
        case .unread:                  return "book.closed.fill"
        case .missingReadme:           return "doc.questionmark.fill"
        case .missingIndexableContent: return "doc.text.magnifyingglass"
        case .indexIssues:             return "exclamationmark.magnifyingglass"
        case .technologySummary:       return "chart.bar.fill"
        case .languages:               return "chevron.left.forwardslash.chevron.right"
        case .topics:                  return "square.grid.2x2.fill"
        case .licenses:                return "checkmark.seal.fill"
        case .healthSummary:           return "heart.text.square.fill"
        case .healthPending:           return "heart.text.square.fill"
        case .openSSFPending:          return "shield.lefthalf.filled"
        case .maintenanceRisk:         return "wrench.and.screwdriver.fill"
        case .securityRisk:            return "lock.trianglebadge.exclamationmark.fill"
        }
    }

    var tintName: String {
        switch self {
        case .overviewSummary, .organizationSummary, .technologySummary, .healthSummary:
            return "blue"
        case .allActions:
            return "purple"
        case .untagged, .maintenanceRisk:
            return "orange"
        case .unread, .languages:
            return "blue"
        case .missingReadme, .missingIndexableContent, .licenses:
            return "yellow"
        case .indexIssues, .securityRisk:
            return "red"
        case .topics:
            return "purple"
        case .healthPending:
            return "pink"
        case .openSSFPending:
            return "cyan"
        }
    }

    var topic: InsightsTopic {
        switch self {
        case .overviewSummary, .allActions:
            return .overview
        case .organizationSummary,
             .untagged,
             .unread,
             .missingReadme,
             .missingIndexableContent,
             .indexIssues:
            return .organization
        case .technologySummary, .languages, .topics, .licenses:
            return .technology
        case .healthSummary,
             .healthPending,
             .openSSFPending,
             .maintenanceRisk,
             .securityRisk:
            return .health
        }
    }

    func isAvailable(in scope: InsightsScope) -> Bool {
        switch self {
        case .missingReadme, .missingIndexableContent, .indexIssues:
            return scope == .knowledge
        default:
            return true
        }
    }
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
    let topicItems: [InsightsDistributionItem]
    let licenseItems: [InsightsDistributionItem]
    let actionItems: [InsightsActionItem]
    let healthCoverage: InsightsCoverage
    let openSSFCoverage: InsightsCoverage
}

/// 仓库洞察活动统计。
struct RepositoryActivityMetric: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let value: Int
    /// 只有存在同口径上一周期数据时才显示环比；首版 GitHub Search 实时计数不伪造变化率。
    let delta: Int?
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

/// 贡献者摘要。头像 URL 允许为空，网络失败时 UI 回退到稳定的首字母占位。
struct RepositoryContributor: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let login: String
    let commits: Int
    let colorName: String
    let avatarURL: URL?

    init(
        id: String,
        login: String,
        commits: Int,
        colorName: String,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.login = login
        self.commits = commits
        self.colorName = colorName
        self.avatarURL = avatarURL
    }
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
