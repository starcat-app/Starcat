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

/// 侧边栏可选择的导航项。
///
/// Week 3 提供三类：
/// - All Stars：全部已 star 仓库
/// - Untagged：未打任何标签的仓库
/// - Language(String?)：按编程语言过滤；nil 代表无主语言（GitHub 的"Unknown"）
///
/// Week 4+ 会扩展：Tag(id), SavedSearch(id)。
enum SidebarItem: Hashable, Identifiable {
    case allStars
    case untagged
    case language(String?)
    /// W4 A6：按 tag id 过滤。tagId 是 Tag.id（UUID 字符串）。
    /// 显示名/颜色/图标 由 SidebarView 从 HomeViewModel.tags 字典里查。
    case tag(String)

    /// SwiftUI ForEach / List 用的稳定 id。
    var id: String {
        switch self {
        case .allStars:                return "section.all"
        case .untagged:                return "section.untagged"
        case .language(let lang):      return "language.\(lang ?? "<nil>")"
        case .tag(let tagId):          return "tag.\(tagId)"
        }
    }

    /// 用户可见的中文/英文显示名。
    /// 语言名保持原文（如 "Swift"、"TypeScript"），约定俗成。
    /// tag 不在此处给名字，由 SidebarView 用 vm.tags 查（避免在 enum 里背业务数据）。
    var displayName: String {
        switch self {
        case .allStars:                return "全部 Stars"
        case .untagged:                return "未分类"
        case .language(let lang):      return lang ?? "Unknown"
        case .tag(let tagId):          return tagId // fallback：tag 名缺失时显示 id
        }
    }

    /// SF Symbol 图标名（用于 Sidebar 行的前置图标）。
    var systemImage: String {
        switch self {
        case .allStars:                return "star.fill"
        case .untagged:                return "tag.slash"
        case .language:                return "chevron.left.forwardslash.chevron.right"
        case .tag:                     return "tag.fill"
        }
    }
}
