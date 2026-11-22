//
//  InsightsModels.swift
//  Starcat
//
//  洞察中心领域与展示模型。SQLite / GitHub Provider 产出同一组类型化快照，
//  让范围、统计与下钻语义在数据层和 SwiftUI 页面之间保持一致。
//

import Foundation
import SwiftUI

/// “我的洞察”统计范围。每个快照只能属于一个明确范围，避免卡片静默混用口径。
enum InsightsScope: String, CaseIterable, Identifiable, Sendable {
    case starred
    case knowledge

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .starred: return "insights.scope.starred"
        case .knowledge: return "insights.scope.knowledge"
        }
    }
}

/// 洞察左栏的页面入口，每项对应一张完整页面。
enum InsightsTopic: String, CaseIterable, Identifiable, Sendable {
    case overview
    case organization
    case technology
    case health
    case knowledgeProfile

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .overview:     return "insights.topic.overview"
        case .organization: return "insights.topic.organization"
        case .technology:   return "insights.topic.technology"
        case .health:       return "insights.topic.health"
        case .knowledgeProfile: return "insights.profile.title"
        }
    }

    /// 洞察分类统一使用业务图标，个人画像用单人轮廓表达。
    var iconSource: BusinessIcon.Source {
        switch self {
        case .overview:     return .business(.dashboard)
        case .organization: return .business(.organization)
        case .technology:   return .business(.codeContext)
        case .health:       return .business(.repositoryHealth)
        case .knowledgeProfile: return .business(.knowledgeProfile)
        }
    }

    /// 洞察左栏主题图标的轻量语义色，对齐星标 / 探索 / 活动侧栏的彩色分类风格。
    var semanticIconColor: Color {
        switch self {
        case .overview:     return .blue
        case .organization: return .orange
        case .technology:   return .purple
        case .health:       return .pink
        case .knowledgeProfile: return .indigo
        }
    }

    /// 取旧中栏各页内容的并集。共用的统计区块只在同一页出现一次。
    func dashboardSections(for scope: InsightsScope) -> [InsightsDashboardSection] {
        let actionSections = InsightsActionID.allCases
            .filter { $0.topic == self && $0.isAvailable(in: scope) }
            .map(InsightsDashboardSection.action)

        switch self {
        case .overview:
            return [
                .metrics, .rhythm, .organizationProgress, .knowledgeCoverage,
                .priorityRepositories, .assetCleanup, .languages, .allActions, .healthCoverage
            ]
        case .organization:
            return [.organizationProgress, .rhythm, .knowledgeCoverage, .priorityRepositories, .assetCleanup]
                + actionSections
        case .technology:
            return [.languages, .topics, .licenses]
        case .health:
            return [.healthCoverage] + actionSections
        case .knowledgeProfile:
            return []
        }
    }
}

/// 右侧统计页与首屏骨架共用区块顺序，待办的身份独立于实时数量。
enum InsightsDashboardSection: Hashable, Sendable {
    case metrics
    case rhythm
    case organizationProgress
    case knowledgeCoverage
    case priorityRepositories
    case assetCleanup
    case languages
    case topics
    case licenses
    case allActions
    case healthCoverage
    case action(InsightsActionID)
}

/// 待办项的稳定标识，用于分组展示及生成对应的 Manage 筛选。
enum InsightsActionID: String, CaseIterable, Sendable {
    case untagged
    case unread
    case missingReadme
    case missingIndexableContent
    case indexIssues
    case healthPending
    case openSSFPending
    case maintenanceRisk
    case securityRisk

    var iconSource: BusinessIcon.Source {
        switch self {
        case .untagged:                return .business(.untagged)
        case .unread:                  return .system("book.closed.fill")
        case .missingReadme:           return .system("doc.questionmark.fill")
        case .missingIndexableContent: return .system("doc.text.magnifyingglass")
        case .indexIssues:             return .system("exclamationmark.magnifyingglass")
        case .healthPending:           return .business(.repositoryHealth)
        case .openSSFPending:          return .system("shield.lefthalf.filled")
        case .maintenanceRisk:         return .system("wrench.and.screwdriver.fill")
        case .securityRisk:            return .system("lock.trianglebadge.exclamationmark.fill")
        }
    }

    var topic: InsightsTopic {
        switch self {
        case .untagged,
             .unread,
             .missingReadme,
             .missingIndexableContent,
             .indexIssues:
            return .organization
        case .healthPending,
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

/// 待办项包含统计值和展示说明，筛选条件由下钻路由统一生成。
struct InsightsActionItem: Identifiable, Equatable, Sendable {
    let id: InsightsActionID
    let titleKey: String
    let detailKey: String
    let count: Int
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

/// 当前范围内需要清理的资产信号。三类信号允许重叠，不能相加当作唯一仓库数。
struct InsightsAssetSummary: Equatable, Sendable {
    let dormantCount: Int
    let archivedCount: Int
    let unavailableCount: Int
}

/// 按 GitHub Star 数筛出的高价值待整理仓库，点击后直接进入对应仓库详情。
struct InsightsRepositoryHighlight: Identifiable, Equatable, Sendable {
    let id: Int64
    let fullName: String
    let starsCount: Int
    let isUnread: Bool
    let isUntagged: Bool
}

/// 按自然周聚合的收藏或入库数量，固定补齐 12 周零值以保持图表时间轴稳定。
struct InsightsRhythmPoint: Identifiable, Equatable, Sendable {
    var id: Date { weekStart }

    let weekStart: Date
    let count: Int
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
    let assetSummary: InsightsAssetSummary
    let priorityRepositories: [InsightsRepositoryHighlight]
    let rhythmPoints: [InsightsRhythmPoint]
    let knowledgeCoverageItems: [InsightsDistributionItem]
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

/// 贡献者摘要。头像 URL 允许为空，网络失败时 UI 回退到稳定的首字母占位。
/// `profileHTMLURL` 可选：旧缓存无字段时 UI 用 `https://github.com/{login}` 兜底。
struct RepositoryContributor: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let login: String
    let commits: Int
    let colorName: String
    let avatarURL: URL?
    let profileHTMLURL: URL?

    init(
        id: String,
        login: String,
        commits: Int,
        colorName: String,
        avatarURL: URL? = nil,
        profileHTMLURL: URL? = nil
    ) {
        self.id = id
        self.login = login
        self.commits = commits
        self.colorName = colorName
        self.avatarURL = avatarURL
        self.profileHTMLURL = profileHTMLURL
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
