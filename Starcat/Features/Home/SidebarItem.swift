//
//  SidebarItem.swift
//  Starcat
//
//  侧边栏导航项模型。
//
//  设计约束：
//  - 用 enum 把所有合法导航态封死（避免传字符串、scatter 分支）
//  - 必须可 Hashable + Equatable（SwiftUI NavigationSplitView selection 要求）
//  - 不在此处做查询；查询在 HomeViewModel 里按 SidebarItem 派发
//

import Foundation
import SwiftUI

/// Sidebar 顶部的一级入口。
///
/// 这个层级不等同于 `SidebarItem`：前者决定左栏下面展示哪一组导航结构，
/// 后者才是 repo 列表真正用来查询数据的筛选项。把两者拆开，可以避免后续
/// Search / Trending 各自扩展子结构时继续挤进同一个列表分组。
enum SidebarRootPage: String, CaseIterable, Identifiable {
    case manage
    case trending
    case search

    var id: String { rawValue }

    /// 本地化 key，用于 SwiftUI Text 自动查找翻译。
    /// 使用 LocalizedStringKey 类型，Text() 才会正确查找 catalog 中的翻译。
    var titleKey: LocalizedStringKey {
        switch self {
        case .manage:   return "nav.manage"
        case .trending: return "nav.trending"
        case .search:   return "nav.search"
        }
    }

    var systemImage: String {
        switch self {
        case .manage:   return "folder"
        case .trending: return "chart.line.uptrend.xyaxis"
        case .search:   return "magnifyingglass"
        }
    }
}

/// 侧边栏可选择的导航项。
///
/// Week 3 提供三类：
/// - All Stars：全部已 star 仓库
/// - Untagged：未打任何标签的仓库
/// - Language(String?)：按编程语言过滤；nil 代表无主语言（GitHub 的"Unknown"）
///
/// Week 4+ 会扩展：Tag(id), SavedSearch(id)。
enum SidebarItem: Hashable, Identifiable {
    case trending
    case allStars
    case untagged
    case language(String?)
    /// W4 A6：按 tag id 过滤。tagId 是 Tag.id（UUID 字符串）。
    /// 显示名/颜色/图标 由 SidebarView 从 HomeViewModel.tags 字典里查。
    case tag(String)

    /// SwiftUI ForEach / List 用的稳定 id。
    var id: String {
        switch self {
        case .trending:                return "section.trending"
        case .allStars:                return "section.all"
        case .untagged:                return "section.untagged"
        case .language(let lang):      return "language.\(lang ?? "<nil>")"
        case .tag(let tagId):          return "tag.\(tagId)"
        }
    }

    /// 本地化显示名，用于 SwiftUI Text 自动查找翻译。
    var displayName: LocalizedStringKey {
        switch self {
        case .trending:                return "trending.title"
        case .allStars:                return "sidebar.allRepos"
        case .untagged:                return "sidebar.untagged"
        case .language(let lang):      return LocalizedStringKey(lang ?? "Unknown")
        case .tag(let tagId):          return LocalizedStringKey(tagId)
        }
    }

    /// 用于返回 String 类型的属性（如 navigationTitle）。
    /// 返回的是翻译 key，实际翻译由使用处处理。
    var displayNameKey: String {
        switch self {
        case .trending:                return "trending.title"
        case .allStars:                return "sidebar.allRepos"
        case .untagged:                return "sidebar.untagged"
        case .language(let lang):      return lang ?? "Unknown"
        case .tag(let tagId):          return tagId
        }
    }

    /// SF Symbol 图标名（用于 Sidebar 行的前置图标）。
    var systemImage: String {
        switch self {
        case .trending:                return "chart.line.uptrend.xyaxis"
        case .allStars:                return "star.fill"
        case .untagged:                return "tag.slash"
        case .language:                return "chevron.left.forwardslash.chevron.right"
        case .tag:                     return "tag.fill"
        }
    }
}

// MARK: - 持久化编解码

extension SidebarItem {

    /// 用于落盘到 UserDefaults 的字符串编码。
    ///
    /// 关键约束：
    /// - `SidebarItem` 含关联值，无法直接用 Swift RawValue，这里用 `"type:payload"` 手编。
    /// - `.language(nil)`（GitHub 无主语言）编码成空 payload `"language:"`，解码时还原回 nil。
    /// - `.trending` 不是 Manage 分类，不应被持久化为"上次分类"，这里防御性折叠成 allStars。
    var persistedRawValue: String {
        switch self {
        case .trending, .allStars: return "allStars"
        case .untagged:            return "untagged"
        case .language(let lang):  return "language:\(lang ?? "")"
        case .tag(let tagId):      return "tag:\(tagId)"
        }
    }

    /// 从 `persistedRawValue` 解码。
    ///
    /// 任何无法识别的旧值 / 空串 都回落到 `.allStars`，对应需求里
    /// "获取不到之前的分类 → 默认选中 allStars"。
    init(persistedRawValue raw: String) {
        if raw == "untagged" {
            self = .untagged
        } else if raw.hasPrefix("language:") {
            let lang = String(raw.dropFirst("language:".count))
            // 空 payload 代表 GitHub 无主语言（.language(nil)）
            self = .language(lang.isEmpty ? nil : lang)
        } else if raw.hasPrefix("tag:") {
            self = .tag(String(raw.dropFirst("tag:".count)))
        } else {
            self = .allStars
        }
    }
}
