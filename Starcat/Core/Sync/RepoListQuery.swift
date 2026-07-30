//
//  RepoListQuery.swift
//  Starcat
//
//  Manage 列表的大数据量查询模型。
//
//  本文件把原本散落在 HomeViewModel 里的“先取全量 Repo，再在内存过滤/排序/分页”
//  收口成 repository 可执行的查询描述。目标不是改变 UI，而是让数据库索引承担筛选、
//  排序和分页，ViewModel 只接收当前需要展示的少量行。
//

import Foundation
import SwiftUI

/// Manage 列表的基础数据范围。
///
/// 只放 Core 层可理解的语义，避免 Repository 反向依赖 `SidebarItem` 这种 UI 导航枚举。
enum RepoListScope: Equatable, Sendable {
    /// 当前 GitHub 用户可访问的个人 / 组织项目。
    ///
    /// `userID` 必须参与查询：虽然 Starcat 会按账号切换数据库，异步同步仍可能跨越切库边界，
    /// 关系表保留用户约束可以避免旧账号的项目短暂出现在新账号列表中。
    case myProjects(userID: Int64)
    case allStars
    case library
    case untagged
    case language(String?)
    case tag(String)
    case githubStarList(String)
    case githubStarListUngrouped
}

/// Manage 列表的知识库筛选条件。
///
/// 这里独立于 `LibraryState`：`LibraryState` 是单 repo 的真实入库状态，
/// 本枚举是列表过滤器，多了 `.all` 代表不按知识库状态收窄。
enum RepoLibraryFilter: String, CaseIterable, Codable, Sendable {
    case all
    case inLibrary = "in_library"
    case outsideLibrary = "outside_library"

    static func parse(_ raw: String?) -> RepoLibraryFilter {
        guard let raw, let value = RepoLibraryFilter(rawValue: raw) else {
            return .all
        }
        return value
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .all: return "general.all"
        case .inLibrary: return "library.state.inLibrary"
        case .outsideLibrary: return "library.state.outsideLibrary"
        }
    }

    var localizedDisplayName: String {
        switch self {
        case .all: return String.l10n("general.all")
        case .inLibrary: return String.l10n("library.state.inLibrary")
        case .outsideLibrary: return String.l10n("library.state.outsideLibrary")
        }
    }
}

/// toolbar 全局 Star 状态筛选。
///
/// `StarredRegistry` 与 `repos.is_starred` 分别是远端列表和本地 Manage 列表的状态来源，
/// 两条路径统一调用 `matches(isStarred:)`，避免不同页面对“未 Star”产生不同解释。
enum RepoStarFilter: String, CaseIterable, Codable, Sendable {
    case all
    case starred
    case unstarred

    static func parse(_ raw: String?) -> RepoStarFilter {
        guard let raw, let value = RepoStarFilter(rawValue: raw) else {
            return .all
        }
        return value
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .all: return "general.all"
        case .starred: return "list.filter.starStatus.starred"
        case .unstarred: return "list.filter.starStatus.unstarred"
        }
    }

    func matches(isStarred: Bool) -> Bool {
        switch self {
        case .all: return true
        case .starred: return isStarred
        case .unstarred: return !isStarred
        }
    }
}

/// Manage 列表的语言筛选条件。
///
/// 不能直接复用 `RepoListScope.language`：scope 代表左侧导航的基础集合，
/// filter 代表 toolbar 上可叠加的收窄条件。知识库集合需要在 `.library`
/// scope 内继续按语言过滤，所以单独建一个轻量值类型。
enum RepoLanguageFilter: Equatable, Hashable, Codable, Sendable {
    case all
    case uncategorized
    case language(String)

    private static let uncategorizedRawValue = "__starcat_uncategorized__"

    static func parse(_ raw: String?) -> RepoLanguageFilter {
        guard let raw, !raw.isEmpty else { return .all }
        if raw == uncategorizedRawValue { return .uncategorized }
        return .language(raw)
    }

    var persistedRawValue: String {
        switch self {
        case .all: return ""
        case .uncategorized: return Self.uncategorizedRawValue
        case .language(let language): return language
        }
    }

    var queryLanguage: String?? {
        switch self {
        case .all: return nil
        case .uncategorized: return .some(nil)
        case .language(let language): return .some(language)
        }
    }
}

/// 全局“是否存在某类信号”的三态筛选。
///
/// `.unknown` 表示不筛选；`.available` 只保留已确认存在信号的 repo；`.missing`
/// 只保留已确认不存在信号的 repo。调用方不能把“尚未探测”当成 missing。
enum RepoSignalAvailabilityFilter: String, CaseIterable, Codable, Sendable {
    case unknown
    case available
    case missing
}

/// RAG 索引状态筛选。模型名属于状态判断的一部分：ready chunk 若来自旧模型，
/// 仍需进入“索引失败 / 过期”下钻，而不能被当成当前模型可用。
enum RepoRAGIndexStateFilter: Equatable, Sendable {
    case unknown
    case issues(embeddingModel: String)

    var cacheKey: String {
        switch self {
        case .unknown:
            return "unknown"
        case .issues(let embeddingModel):
            return "issues:\(embeddingModel)"
        }
    }
}

/// 洞察中的风险集合使用与统计快照相同的固定阈值，确保数字下钻后列表数量一致。
enum RepoInsightsRiskFilter: String, Equatable, Sendable {
    case unknown
    case maintenance
    case security
}

/// Manage 列表的可下推过滤条件。
///
/// `selectedTagIDs` 语义与 HomeViewModel 保持一致：命中任意一个标签即可保留（OR）。
/// 它会继续与 `scope` 做 AND 组合，例如 “Swift + tagA/tagB”。
struct RepoListFilters: Equatable, Sendable {
    var hideArchived: Bool
    var hideForks: Bool
    var status: RepoStatus?
    var star: RepoStarFilter
    var library: RepoLibraryFilter
    var language: RepoLanguageFilter
    var selectedLanguages: Set<String>
    var wikiAvailability: RepoSignalAvailabilityFilter
    var healthAvailability: RepoSignalAvailabilityFilter
    var openSSFAvailability: RepoSignalAvailabilityFilter
    var tagAvailability: RepoSignalAvailabilityFilter
    var readmeAvailability: RepoSignalAvailabilityFilter
    var indexableSourceAvailability: RepoSignalAvailabilityFilter
    var ragIndexState: RepoRAGIndexStateFilter
    var insightsRisk: RepoInsightsRiskFilter
    var selectedTagIDs: Set<String>
    /// 仅 `.myProjects` scope 消费；其它 scope 必须忽略，防止项目筛选污染 Stars。
    var project: UserProjectFilter
    /// 项目列表的数据库关键字搜索；普通 Manage 搜索仍走既有 FTS / 语义链路。
    var projectSearchText: String

    init(
        hideArchived: Bool,
        hideForks: Bool,
        status: RepoStatus?,
        star: RepoStarFilter = .all,
        library: RepoLibraryFilter = .all,
        language: RepoLanguageFilter = .all,
        selectedLanguages: Set<String> = [],
        wikiAvailability: RepoSignalAvailabilityFilter = .unknown,
        healthAvailability: RepoSignalAvailabilityFilter = .unknown,
        openSSFAvailability: RepoSignalAvailabilityFilter = .unknown,
        tagAvailability: RepoSignalAvailabilityFilter = .unknown,
        readmeAvailability: RepoSignalAvailabilityFilter = .unknown,
        indexableSourceAvailability: RepoSignalAvailabilityFilter = .unknown,
        ragIndexState: RepoRAGIndexStateFilter = .unknown,
        insightsRisk: RepoInsightsRiskFilter = .unknown,
        selectedTagIDs: Set<String>,
        project: UserProjectFilter = .init(),
        projectSearchText: String = ""
    ) {
        self.hideArchived = hideArchived
        self.hideForks = hideForks
        self.status = status
        self.star = star
        self.library = library
        self.language = language
        self.selectedLanguages = selectedLanguages
        self.wikiAvailability = wikiAvailability
        self.healthAvailability = healthAvailability
        self.openSSFAvailability = openSSFAvailability
        self.tagAvailability = tagAvailability
        self.readmeAvailability = readmeAvailability
        self.indexableSourceAvailability = indexableSourceAvailability
        self.ragIndexState = ragIndexState
        self.insightsRisk = insightsRisk
        self.selectedTagIDs = selectedTagIDs
        self.project = project
        self.projectSearchText = projectSearchText
    }

    static let empty = RepoListFilters(
        hideArchived: false,
        hideForks: false,
        status: nil,
        star: .all,
        library: .all,
        language: .all,
        selectedLanguages: [],
        wikiAvailability: .unknown,
        healthAvailability: .unknown,
        openSSFAvailability: .unknown,
        tagAvailability: .unknown,
        readmeAvailability: .unknown,
        indexableSourceAvailability: .unknown,
        ragIndexState: .unknown,
        insightsRisk: .unknown,
        selectedTagIDs: [],
        project: .init(),
        projectSearchText: ""
    )
}

/// 项目筛选菜单所需的数据库枚举值；不包含 Repo 内容或私有仓库名称。
struct ProjectFilterOptions: Equatable, Sendable {
    var organizationLogins: [String]
    var visibilities: [ProjectVisibility]
    var permissions: [ProjectPermission]

    static let empty = ProjectFilterOptions(
        organizationLogins: [],
        visibilities: [],
        permissions: []
    )
}
