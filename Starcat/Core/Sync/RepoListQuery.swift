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

/// Manage 列表的基础数据范围。
///
/// 只放 Core 层可理解的语义，避免 Repository 反向依赖 `SidebarItem` 这种 UI 导航枚举。
enum RepoListScope: Equatable, Sendable {
    case allStars
    case untagged
    case language(String?)
    case tag(String)
}

/// Manage 列表的可下推过滤条件。
///
/// `selectedTagIDs` 语义与 HomeViewModel 保持一致：命中任意一个标签即可保留（OR）。
/// 它会继续与 `scope` 做 AND 组合，例如 “Swift + tagA/tagB”。
struct RepoListFilters: Equatable, Sendable {
    var hideArchived: Bool
    var hideForks: Bool
    var status: RepoStatus?
    var selectedTagIDs: Set<String>

    static let empty = RepoListFilters(
        hideArchived: false,
        hideForks: false,
        status: nil,
        selectedTagIDs: []
    )
}

