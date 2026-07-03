//
//  ExploreModels.swift
//  Starcat
//
//  探索页的 UI 领域模型。
//
//  设计约束：
//  - `SidebarRootPage.trending` 暂时保留为内部路由，避免一次性改动历史入口和持久化；
//  - ExploreMode 表达用户可见的二级模块：发现 / 趋势 / 热门 / 新发布 / 周刊；
//  - sort 选项按模块收敛在这里，保证中栏筛选栏和 API query 不分叉。
//

import SwiftUI

/// 探索页二级模块。
enum ExploreMode: String, CaseIterable, Identifiable, Hashable {
    case discover
    case trending
    case popular
    case newReleases
    case weekly

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .discover: return "explore.mode.discover"
        case .trending: return "explore.mode.trending"
        case .popular: return "explore.mode.popular"
        case .newReleases: return "explore.mode.newReleases"
        case .weekly: return "explore.mode.weekly"
        }
    }

    var localizedTitle: String {
        switch self {
        case .discover: return String.l10n("explore.mode.discover")
        case .trending: return String.l10n("explore.mode.trending")
        case .popular: return String.l10n("explore.mode.popular")
        case .newReleases: return String.l10n("explore.mode.newReleases")
        case .weekly: return String.l10n("explore.mode.weekly")
        }
    }

    var systemImage: String {
        switch self {
        case .discover: return "safari"
        case .trending: return "chart.line.uptrend.xyaxis"
        case .popular: return "flame"
        case .newReleases: return "shippingbox"
        case .weekly: return "newspaper"
        }
    }

    var usesDiscoveryAPI: Bool {
        switch self {
        case .discover, .popular, .newReleases:
            return true
        case .trending, .weekly:
            return false
        }
    }

    /// Starcat 正式 discovery 服务只承载发现 / 热门 / 新发布。
    /// 趋势继续走 starcat-trending-api，不能映射到 discovery-api 的候选 trending。
    var discoveryListMode: DiscoveryListMode? {
        switch self {
        case .discover: return .discover
        case .trending: return nil
        case .popular: return .popular
        case .newReleases: return .newReleases
        case .weekly: return nil
        }
    }
}

/// 发现 / 热门 / 新发布中栏筛选栏的排序选项。
enum ExploreSortOption: String, CaseIterable, Identifiable, Hashable {
    case recommended
    case popular
    case stars
    case starsAscending
    case activity
    case release
    case releaseDate
    case releaseDateAscending
    case updated
    case updatedAscending
    case created
    case createdAscending
    case nameAsc
    case nameDesc

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .recommended: return "explore.sort.recommended"
        case .popular: return "explore.sort.popular"
        case .stars: return "explore.sort.stars"
        case .starsAscending: return "explore.sort.starsAscending"
        case .activity: return "explore.sort.activity"
        case .release: return "explore.sort.release"
        case .releaseDate: return "explore.sort.releaseDate"
        case .releaseDateAscending: return "explore.sort.releaseDateAscending"
        case .updated: return "explore.sort.updated"
        case .updatedAscending: return "explore.sort.updatedAscending"
        case .created: return "explore.sort.created"
        case .createdAscending: return "explore.sort.createdAscending"
        case .nameAsc: return "explore.sort.nameAsc"
        case .nameDesc: return "explore.sort.nameDesc"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended, .popular, .release:
            return "sparkles"
        case .stars:
            return "star.fill"
        case .starsAscending:
            return "star"
        case .activity:
            return "flame"
        case .releaseDate, .releaseDateAscending:
            return "tag"
        case .updated, .updatedAscending:
            return "clock.arrow.circlepath"
        case .created, .createdAscending:
            return self == .created ? "calendar.badge.plus" : "calendar"
        case .nameAsc:
            return "a.square"
        case .nameDesc:
            return "z.square"
        }
    }

    var isModeSpecificSort: Bool {
        switch self {
        case .releaseDate:
            return true
        case .activity, .releaseDateAscending:
            return true
        case .recommended, .popular, .release, .stars, .starsAscending,
             .updated, .updatedAscending, .created, .createdAscending, .nameAsc, .nameDesc:
            return false
        }
    }

    /// 传给 starcat-discovery-api 的 query 值。nil 表示使用后端默认排序。
    var apiValue: String? {
        switch self {
        case .recommended, .popular, .release:
            return nil
        case .stars:
            return "stars"
        case .starsAscending:
            return "stars_asc"
        case .activity:
            return "activity"
        case .updated:
            return "updated_desc"
        case .updatedAscending:
            return "updated_asc"
        case .created:
            return "created_desc"
        case .createdAscending:
            return "created_asc"
        case .nameAsc:
            return "name_asc"
        case .nameDesc:
            return "name_desc"
        case .releaseDate:
            return "release_desc"
        case .releaseDateAscending:
            return "release_asc"
        }
    }

    static func options(for mode: ExploreMode) -> [ExploreSortOption] {
        switch mode {
        case .discover:
            return commonOptions(defaultOption: .recommended)
        case .popular:
            return commonOptions(defaultOption: .popular)
        case .newReleases:
            return commonOptions(defaultOption: .release)
        case .trending, .weekly:
            return []
        }
    }

    private static func commonOptions(defaultOption: ExploreSortOption?) -> [ExploreSortOption] {
        let common: [ExploreSortOption] = [
            .stars,
            .starsAscending,
            .updated,
            .updatedAscending,
            .created,
            .createdAscending,
            .nameAsc,
            .nameDesc
        ]
        if let defaultOption {
            return [defaultOption] + common
        }
        return common
    }

    static func defaultOption(for mode: ExploreMode) -> ExploreSortOption {
        options(for: mode).first ?? .recommended
    }

    func normalized(for mode: ExploreMode) -> ExploreSortOption {
        let options = Self.options(for: mode)
        return options.contains(self) ? self : Self.defaultOption(for: mode)
    }
}
