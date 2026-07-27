//
//  MainWindowNavigationDispatcher.swift
//  Starcat
//
//  跨窗口跳转到主窗口的类型化路由，以及只在当前 Sidebar 分类内生效的临时全局筛选快照。
//

import Foundation

/// Toolbar 全局筛选的完整值快照。
///
/// 临时跳转必须提供完整快照，而不是在用户现有筛选上追加一个字段。否则从 RAG 元数据
/// 点击“未 Star”时，用户此前留下的语言或 Health 条件会继续叠加，导致落地列表数量和
/// 点击前看到的统计不一致。`.neutral` 因此是所有跨窗口钻取的明确起点。
struct GlobalRepoFilterState: Equatable {
    var hideArchived: Bool
    var hideForks: Bool
    var statusFilter: RepoStatus?
    var starFilter: RepoStarFilter
    var libraryFilter: RepoLibraryFilter
    var repoLanguageFilter: RepoLanguageFilter
    var globalFilterLanguages: [String]
    var wikiAvailabilityFilter: RepoSignalAvailabilityFilter
    var healthAvailabilityFilter: RepoSignalAvailabilityFilter
    var openSSFAvailabilityFilter: RepoSignalAvailabilityFilter
    var tagAvailabilityFilter: RepoSignalAvailabilityFilter
    var readmeAvailabilityFilter: RepoSignalAvailabilityFilter
    var indexableSourceAvailabilityFilter: RepoSignalAvailabilityFilter
    var ragIndexStateFilter: RepoRAGIndexStateFilter
    var insightsRiskFilter: RepoInsightsRiskFilter

    static let neutral = GlobalRepoFilterState(
        hideArchived: false,
        hideForks: false,
        statusFilter: nil,
        starFilter: .all,
        libraryFilter: .all,
        repoLanguageFilter: .all,
        globalFilterLanguages: [],
        wikiAvailabilityFilter: .unknown,
        healthAvailabilityFilter: .unknown,
        openSSFAvailabilityFilter: .unknown,
        tagAvailabilityFilter: .unknown,
        readmeAvailabilityFilter: .unknown,
        indexableSourceAvailabilityFilter: .unknown,
        ragIndexStateFilter: .unknown,
        insightsRiskFilter: .unknown
    )

    /// 这些字段只用于洞察的临时结构化下钻，不进入用户持久 Toolbar 偏好。
    var hasInsightsDrillDownFilters: Bool {
        tagAvailabilityFilter != .unknown
            || readmeAvailabilityFilter != .unknown
            || indexableSourceAvailabilityFilter != .unknown
            || ragIndexStateFilter != .unknown
            || insightsRiskFilter != .unknown
    }
}

/// 主窗口级一次性路由总线。
///
/// RAG 窗口只发布“去哪里、临时使用哪套筛选”，不直接持有 `HomeView` 的 Sidebar 状态。
/// 请求先保存再激活主窗口，因此主窗口已关闭时也能在重新挂载后补消费。
@MainActor
@Observable
final class MainWindowNavigationDispatcher {
    enum Destination: Equatable {
        case manage(SidebarItem)
        case revealTags
        /// Universal Link 只携带稳定的 owner / repo，不把网页端数据写入本地库。
        case repository(RepositoryDeepLink)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
        let temporaryFilters: GlobalRepoFilterState?
        let returnPage: SidebarRootPage?
    }

    var pendingRequest: Request?

    /// 发布一次主窗口跳转。`temporaryFilters == nil` 表示只导航，不覆盖用户筛选。
    func navigate(
        to destination: Destination,
        temporaryFilters: GlobalRepoFilterState? = nil,
        returnPage: SidebarRootPage? = nil
    ) {
        pendingRequest = Request(
            destination: destination,
            temporaryFilters: temporaryFilters,
            returnPage: returnPage
        )
        AppDelegate.activateMainWindowIfPossible()
    }
}
