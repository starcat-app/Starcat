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
    case activity

    var id: String { rawValue }

    /// 本地化 key，用于 SwiftUI Text 自动查找翻译。
    /// 使用 LocalizedStringKey 类型，Text() 才会正确查找 catalog 中的翻译。
    var titleKey: LocalizedStringKey {
        switch self {
        case .manage:   return "nav.manage"
        case .trending: return "nav.trending"
        case .activity: return "nav.activity"
        }
    }

    var systemImage: String {
        switch self {
        case .manage:   return "star.circle"
        case .trending: return "safari"
        case .activity: return "bell.circle"
        }
    }
}

/// 侧边栏可选择的导航项。
///
/// Week 3 提供三类：
/// - All Stars：全部已 star 仓库
/// - Untagged：未打任何标签的仓库
/// - AllLanguages：Languages 分组内的全部语言入口，查询语义等同 All Stars，但在 UI 层归属语言分组
/// - Language(String?)：按编程语言过滤；nil 代表无主语言（GitHub 的"Unknown"）
///
/// Week 4+ 会扩展：Tag(id), SavedSearch(id)。
enum SidebarItem: Hashable, Identifiable {
    case trending
    case allStars
    case untagged
    /// Starcat 私有知识库基础分类。它和 Smart Collections 的系统集合共享查询语义，
    /// 但放在 Sidebar 主导航里，作为“全部仓库 / 未分类”同级的快速入口。
    case library
    case allLanguages
    case smartCollectionsHome
    case smartCollection(SmartCollectionKind)
    case userSmartCollection(String)
    case language(String?)
    /// W4 A6：按 tag id 过滤。tagId 是 Tag.id（UUID 字符串）。
    /// 显示名/颜色/图标 由 SidebarView 从 HomeViewModel.tags 字典里查。
    case tag(String)
    /// GitHub Stars List 虚拟「未分组」。
    case githubStarListUngrouped
    /// GitHub Stars List 真实 list。
    case githubStarList(String)

    /// SwiftUI ForEach / List 用的稳定 id。
    var id: String {
        switch self {
        case .trending:                return "section.trending"
        case .allStars:                return "section.all"
        case .untagged:                return "section.untagged"
        case .library:                 return "section.library"
        case .allLanguages:            return "language.all"
        case .smartCollectionsHome:    return "smartCollections.home"
        case .smartCollection(let kind): return "smartCollections.\(kind.rawValue)"
        case .userSmartCollection(let id): return "userSmartCollections.\(id)"
        case .language(let lang):      return "language.\(lang ?? "<nil>")"
        case .tag(let tagId):          return "tag.\(tagId)"
        case .githubStarListUngrouped: return "githubStarList.ungrouped"
        case .githubStarList(let id):  return "githubStarList.\(id)"
        }
    }

    /// 本地化显示名，用于 SwiftUI Text 自动查找翻译。
    var displayName: LocalizedStringKey {
        switch self {
        case .trending:                return "nav.trending"
        case .allStars:                return "sidebar.allRepos"
        case .untagged:                return "sidebar.untagged"
        case .library:                 return "sidebar.library"
        case .allLanguages:            return "trending.allLanguages"
        case .smartCollectionsHome:    return "smartCollections.title"
        case .smartCollection(let kind): return kind.titleKey
        case .userSmartCollection(let id): return LocalizedStringKey(id)
        // language 走短名（详见 LanguageDisplayName）。LocalizedStringKey 兜底：
        // 短名不会有 String Catalog 条目，SwiftUI 找不到翻译会原样吐 raw 字符串。
        // 无主语言（nil）统一显示 "Uncategorized"（dong4j 2026-06-16，不做 i18n）。
        case .language(let lang):      return LocalizedStringKey(lang.map(LanguageDisplayName.shortened(for:)) ?? "Uncategorized")
        case .tag(let tagId):          return LocalizedStringKey(tagId)
        case .githubStarListUngrouped: return "sidebar.githubStarLists.ungrouped"
        case .githubStarList(let id):  return LocalizedStringKey(id)
        }
    }

    /// 用于返回 String 类型的属性（如 navigationTitle）。
    /// 返回的是翻译 key，实际翻译由使用处处理。
    var displayNameKey: String {
        switch self {
        case .trending:                return "nav.trending"
        case .allStars:                return "sidebar.allRepos"
        case .untagged:                return "sidebar.untagged"
        case .library:                 return "sidebar.library"
        case .allLanguages:            return "trending.allLanguages"
        case .smartCollectionsHome:    return "smartCollections.title"
        case .smartCollection(let kind): return "smartCollections.\(kind.rawValue).title"
        case .userSmartCollection(let id): return id
        case .language(let lang):      return lang.map(LanguageDisplayName.shortened(for:)) ?? "Uncategorized"
        case .tag(let tagId):          return tagId
        case .githubStarListUngrouped: return "sidebar.githubStarLists.ungrouped"
        case .githubStarList(let id):  return id
        }
    }

    /// SF Symbol 图标名（用于 Sidebar 行的前置图标）。
    var systemImage: String {
        switch self {
        case .trending:                return "safari"
        case .allStars:                return "star.fill"
        case .untagged:                return "tag.slash"
        case .library:                 return "heart.fill"
        case .allLanguages:            return "globe"
        case .smartCollectionsHome:    return "line.3.horizontal.decrease.circle"
        case .smartCollection(let kind): return kind.systemImage
        case .userSmartCollection:     return "line.3.horizontal.decrease.circle"
        case .language:                return "chevron.left.forwardslash.chevron.right"
        case .tag:                     return "tag.fill"
        case .githubStarListUngrouped: return "tray"
        case .githubStarList:          return "folder.fill"
        }
    }

    /// 固定导航项的轻量语义色。动态项（语言 / 标签 / GitHub Lists）在 SidebarView
    /// 内已有真实数据来源颜色，这里只覆盖没有业务颜色字段的 Starred 固定分组。
    var semanticIconColor: Color? {
        switch self {
        case .allStars:             return .yellow
        case .untagged:             return .orange
        case .library:              return .pink
        case .smartCollectionsHome,
             .smartCollection,
             .userSmartCollection:  return .blue
        default:                    return nil
        }
    }
}

// MARK: - Smart Collections 导航语义

extension SidebarItem {
    /// Smart Collections 在中栏始终展示集合卡片总览（具体集合 selection 不切到 repo list）。
    var isSmartCollectionsSurface: Bool {
        switch self {
        case .smartCollectionsHome, .smartCollection, .userSmartCollection:
            return true
        default:
            return false
        }
    }

    /// 右栏在未选中 repo 时展示 Smart Collections 浏览面板。
    var isSmartCollectionDetailContext: Bool {
        switch self {
        case .smartCollection, .userSmartCollection:
            return true
        default:
            return false
        }
    }

    /// GitHub Stars List 分组上下文。刷新远端 list 后，当前列表内容也需要跟着重载。
    var isGitHubStarListContext: Bool {
        switch self {
        case .githubStarList, .githubStarListUngrouped:
            return true
        default:
            return false
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
    /// - `.allLanguages` 查询语义等同 `.allStars`，但 UI 选中态属于 Languages 分组，需要独立落盘。
    var persistedRawValue: String {
        switch self {
        case .trending, .allStars: return "allStars"
        case .untagged:            return "untagged"
        case .library:             return "library"
        case .allLanguages:        return "allLanguages"
        case .smartCollectionsHome: return "smartCollectionsHome"
        case .smartCollection(let kind): return "smartCollection:\(kind.rawValue)"
        case .userSmartCollection(let id): return "userSmartCollection:\(id)"
        case .language(let lang):  return "language:\(lang ?? "")"
        case .tag(let tagId):      return "tag:\(tagId)"
        case .githubStarListUngrouped: return "githubStarListUngrouped"
        case .githubStarList(let id): return "githubStarList:\(id)"
        }
    }

    /// 从 `persistedRawValue` 解码。
    ///
    /// 任何无法识别的旧值 / 空串 都回落到 `.allStars`，对应需求里
    /// "获取不到之前的分类 → 默认选中 allStars"。
    init(persistedRawValue raw: String) {
        if raw == "untagged" {
            self = .untagged
        } else if raw == "library" {
            self = .library
        } else if raw == "allLanguages" {
            self = .allLanguages
        } else if raw == "smartCollectionsHome" {
            self = .smartCollectionsHome
        } else if raw.hasPrefix("smartCollection:") {
            let value = String(raw.dropFirst("smartCollection:".count))
            self = SmartCollectionKind(rawValue: value).map(SidebarItem.smartCollection) ?? .allStars
        } else if raw.hasPrefix("userSmartCollection:") {
            self = .userSmartCollection(String(raw.dropFirst("userSmartCollection:".count)))
        } else if raw.hasPrefix("language:") {
            let lang = String(raw.dropFirst("language:".count))
            // 空 payload 代表 GitHub 无主语言（.language(nil)）
            self = .language(lang.isEmpty ? nil : lang)
        } else if raw.hasPrefix("tag:") {
            self = .tag(String(raw.dropFirst("tag:".count)))
        } else if raw == "githubStarListUngrouped" {
            self = .githubStarListUngrouped
        } else if raw.hasPrefix("githubStarList:") {
            self = .githubStarList(String(raw.dropFirst("githubStarList:".count)))
        } else {
            self = .allStars
        }
    }
}
