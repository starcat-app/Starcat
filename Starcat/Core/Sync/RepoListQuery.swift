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

/// Manage 列表的可下推过滤条件。
///
/// `selectedTagIDs` 语义与 HomeViewModel 保持一致：命中任意一个标签即可保留（OR）。
/// 它会继续与 `scope` 做 AND 组合，例如 “Swift + tagA/tagB”。
struct RepoListFilters: Equatable, Sendable {
    var hideArchived: Bool
    var hideForks: Bool
    var status: RepoStatus?
    var library: RepoLibraryFilter
    var selectedTagIDs: Set<String>

    init(
        hideArchived: Bool,
        hideForks: Bool,
        status: RepoStatus?,
        library: RepoLibraryFilter = .all,
        selectedTagIDs: Set<String>
    ) {
        self.hideArchived = hideArchived
        self.hideForks = hideForks
        self.status = status
        self.library = library
        self.selectedTagIDs = selectedTagIDs
    }

    static let empty = RepoListFilters(
        hideArchived: false,
        hideForks: false,
        status: nil,
        library: .all,
        selectedTagIDs: []
    )
}
