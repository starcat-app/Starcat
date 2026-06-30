//
//  ExploreModels.swift
//  Starcat
//
//  探索页的 UI 领域模型。
//
//  设计约束：
//  - `SidebarRootPage.trending` 暂时保留为内部路由，避免一次性改动历史入口和持久化；
//  - ExploreMode 表达用户可见的二级模块：发现 / 趋势 / 热门 / 新发布；
//  - sort 选项按模块收敛在这里，保证中栏筛选栏和 API query 不分叉。
//

import SwiftUI

/// 探索页二级模块。
enum ExploreMode: String, CaseIterable, Identifiable, Hashable {
    case discover
    case trending
    case popular
    case newReleases

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .discover: return "explore.mode.discover"
        case .trending: return "explore.mode.trending"
        case .popular: return "explore.mode.popular"
        case .newReleases: return "explore.mode.newReleases"
        }
    }

    var localizedTitle: String {
        switch self {
        case .discover: return String.l10n("explore.mode.discover")
        case .trending: return String.l10n("explore.mode.trending")
        case .popular: return String.l10n("explore.mode.popular")
        case .newReleases: return String.l10n("explore.mode.newReleases")
        }
    }

    var systemImage: String {
        switch self {
        case .discover: return "safari"
        case .trending: return "chart.line.uptrend.xyaxis"
        case .popular: return "flame"
        case .newReleases: return "shippingbox"
        }
    }

    var usesDiscoveryAPI: Bool {
        self != .trending
    }

    var discoveryListMode: DiscoveryListMode {
        switch self {
        case .discover: return .discover
        case .trending: return .trending
        case .popular: return .popular
        case .newReleases: return .newReleases
        }
    }
}

/// 发现 / 热门 / 新发布中栏筛选栏的排序选项。
enum ExploreSortOption: String, CaseIterable, Identifiable, Hashable {
    case recommended
    case popular
    case stars
    case activity
    case release
    case updated

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .recommended: return "explore.sort.recommended"
        case .popular: return "explore.sort.popular"
        case .stars: return "explore.sort.stars"
        case .activity: return "explore.sort.activity"
        case .release: return "explore.sort.release"
        case .updated: return "explore.sort.updated"
        }
    }

    /// 传给 starcat-discovery-api 的 query 值。nil 表示使用后端默认排序。
    var apiValue: String? {
        switch self {
        case .recommended, .popular, .release:
            return nil
        case .stars:
            return "stars"
        case .activity:
            return "activity"
        case .updated:
            return "updated"
        }
    }

    static func options(for mode: ExploreMode) -> [ExploreSortOption] {
        switch mode {
        case .discover:
            // 发现流由后端 discovery_score 控制，首期不暴露伪排序，避免 UI 承诺后端不支持的行为。
            return [.recommended]
        case .popular:
            return [.popular, .stars, .activity]
        case .newReleases:
            return [.release, .stars, .updated]
        case .trending:
            return []
        }
    }

    static func defaultOption(for mode: ExploreMode) -> ExploreSortOption {
        options(for: mode).first ?? .recommended
    }

    func normalized(for mode: ExploreMode) -> ExploreSortOption {
        let options = Self.options(for: mode)
        return options.contains(self) ? self : Self.defaultOption(for: mode)
    }
}
