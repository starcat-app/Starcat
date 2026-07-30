//
//  InsightsDrillDown.swift
//  Starcat
//
//  “我的洞察”数字到 Manage 列表的类型化路由。所有路由都从 neutral 构造，
//  避免用户此前的 Toolbar 条件静默叠加，导致统计数字与下钻列表不一致。
//

import Foundation

/// 洞察页面可下钻的统计语义。
enum InsightsDrillDownTarget: Equatable {
    case action(InsightsSelection)
    case status(RepoStatus)
    case language(String?)
}

/// 下钻后的 Manage 锚点与完整临时筛选快照。
struct InsightsDrillDownRoute: Equatable {
    let selection: SidebarItem
    let filters: GlobalRepoFilterState
}

enum InsightsDrillDownRouter {

    /// 把可见统计项转换为结构化筛选。聚合后的“其他”没有精确列表表达，因此调用方不应传入。
    static func route(
        scope: InsightsScope,
        target: InsightsDrillDownTarget,
        embeddingModel: String
    ) -> InsightsDrillDownRoute? {
        var filters = GlobalRepoFilterState.neutral

        switch target {
        case .action(let selection):
            switch selection {
            case .untagged:
                filters.tagAvailabilityFilter = .missing
            case .unread:
                filters.statusFilter = .unread
            case .missingReadme:
                filters.readmeAvailabilityFilter = .missing
            case .missingIndexableContent:
                filters.indexableSourceAvailabilityFilter = .missing
            case .indexIssues:
                filters.ragIndexStateFilter = .issues(embeddingModel: embeddingModel)
            case .healthPending:
                filters.healthAvailabilityFilter = .missing
            case .openSSFPending:
                filters.openSSFAvailabilityFilter = .missing
            case .maintenanceRisk:
                filters.insightsRiskFilter = .maintenance
            case .securityRisk:
                filters.insightsRiskFilter = .security
            default:
                return nil
            }

        case .status(let status):
            filters.statusFilter = status

        case .language(let language):
            if let language {
                filters.globalFilterLanguages = [language]
            } else {
                filters.repoLanguageFilter = .uncategorized
            }
        }

        return InsightsDrillDownRoute(
            selection: scope == .knowledge ? .library : .allStars,
            filters: filters
        )
    }
}
