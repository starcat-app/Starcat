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

/// Manage 列表的可下推过滤条件。
///
/// `selectedTagIDs` 语义与 HomeViewModel 保持一致：命中任意一个标签即可保留（OR）。
/// 它会继续与 `scope` 做 AND 组合，例如 “Swift + tagA/tagB”。
struct RepoListFilters: Equatable, Sendable {
    var hideArchived: Bool
    var hideForks: Bool
    var status: RepoStatus?
    var library: RepoLibraryFilter
    var language: RepoLanguageFilter
    var selectedLanguages: Set<String>
    var wikiAvailability: RepoSignalAvailabilityFilter
    var healthAvailability: RepoSignalAvailabilityFilter
    var openSSFAvailability: RepoSignalAvailabilityFilter
    var selectedTagIDs: Set<String>

    init(
        hideArchived: Bool,
        hideForks: Bool,
        status: RepoStatus?,
        library: RepoLibraryFilter = .all,
        language: RepoLanguageFilter = .all,
        selectedLanguages: Set<String> = [],
        wikiAvailability: RepoSignalAvailabilityFilter = .unknown,
        healthAvailability: RepoSignalAvailabilityFilter = .unknown,
        openSSFAvailability: RepoSignalAvailabilityFilter = .unknown,
        selectedTagIDs: Set<String>
    ) {
        self.hideArchived = hideArchived
        self.hideForks = hideForks
        self.status = status
        self.library = library
        self.language = language
        self.selectedLanguages = selectedLanguages
        self.wikiAvailability = wikiAvailability
        self.healthAvailability = healthAvailability
        self.openSSFAvailability = openSSFAvailability
        self.selectedTagIDs = selectedTagIDs
    }

    static let empty = RepoListFilters(
        hideArchived: false,
        hideForks: false,
        status: nil,
        library: .all,
        language: .all,
        selectedLanguages: [],
        wikiAvailability: .unknown,
        healthAvailability: .unknown,
        openSSFAvailability: .unknown,
        selectedTagIDs: []
    )
}
