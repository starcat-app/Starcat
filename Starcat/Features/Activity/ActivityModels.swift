//
//  ActivityModels.swift
//  Starcat
//
//  Activity 页的轻量领域模型。
//
//  设计约束：
//  - Activity 第一版是“本地聚合页”，不新建数据库表，也不复刻 GitHub Mobile Explore。
//  - Release 类活动直接复用 HOM-47 已落地的 `ReleaseRecord` / `ReleaseTimelineEntry`。
//  - 其它类型先从本地 repo 缓存派生，后续接 Events API 时再补 payload。
//

import Foundation
import SwiftUI

/// Activity 左栏固定分类。
///
/// 分类数量第一版固定，每个分类直接挑选一个 GitHub Linguist 调色板里的颜色作为色点，
/// 不再走"分类 → 语言名 → Devicon SVG"链路。这样可以避免侧边栏出现 Swift / JS / Go
/// 这类语言图标干扰用户对分类语义的判断（dong4j 在 2026-06-05 反馈：分类不应使用语言图标）。
///
/// 选色策略：从 Linguist 颜色表里挑七个高对比度、足够区分的颜色，
/// 与 Tags / Trending / Manage 现有色块共存时不冲突。
enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case announcement
    case release
    case star
    case repository
    case following
    case suggestion
    /// MUL-176：阮一峰周刊（ruanyf/weekly）推荐 GitHub 项目聚合。
    ///
    /// 与其他分类不同，weekly 的数据源不是本地 Repo 缓存，而是独立的远端 REST API
    /// （starcat-weekly-api）。因此 ActivityView 在选中此分类时会切换到
    /// `WeeklyContentView`，不复用 ActivityViewModel 的本地聚合逻辑。
    case weekly

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .all:          return "activity.category.all"
        case .announcement: return "activity.category.announcement"
        case .release:      return "activity.category.release"
        case .star:         return "activity.category.star"
        case .repository:   return "activity.category.repository"
        case .following:    return "activity.category.following"
        case .suggestion:   return "activity.category.suggestion"
        case .weekly:       return "activity.category.weekly"
        }
    }

    var localizedTitle: String {
        switch self {
        case .all:          return String.l10n("activity.category.all")
        case .announcement: return String.l10n("activity.category.announcement")
        case .release:      return String.l10n("activity.category.release")
        case .star:         return String.l10n("activity.category.star")
        case .repository:   return String.l10n("activity.category.repository")
        case .following:    return String.l10n("activity.category.following")
        case .suggestion:   return String.l10n("activity.category.suggestion")
        case .weekly:       return String.l10n("activity.category.weekly")
        }
    }

    /// 分类色点的 hex（取自 GitHub Linguist 调色板）。
    /// 取值思路：同时也是 selection / hover 时整行 accent 的源色。
    var iconColorHex: String {
        switch self {
        case .all:          return "#F05138" // Swift orange-red
        case .announcement: return "#f1e05a" // JavaScript yellow
        case .release:      return "#00ADD8" // Go cyan
        case .star:         return "#41b883" // Vue green
        case .repository:   return "#A97BFF" // Kotlin purple
        case .following:    return "#701516" // Ruby deep red
        case .suggestion:   return "#3178c6" // TypeScript blue
        case .weekly:       return "#dea584" // Rust beige —— 与上面 7 色都不撞，且与"周刊"温和气质相符
        }
    }

    /// `iconColorHex` 解析后的 SwiftUI Color；hex 非法时回退到系统强调色。
    var iconColor: Color {
        Color(hex: iconColorHex) ?? .accentColor
    }

    var systemImage: String {
        switch self {
        case .all:          return "tray.full"
        case .announcement: return "megaphone"
        case .release:      return "shippingbox"
        case .star:         return "star"
        case .repository:   return "folder"
        case .following:    return "person.2"
        case .suggestion:   return "sparkles"
        case .weekly:       return "newspaper"
        }
    }
}

extension ActivityCategory {
    init(persistedRawValue raw: String) {
        self = ActivityCategory(rawValue: raw) ?? .all
    }

    var persistedRawValue: String {
        rawValue
    }
}

/// Activity 卡片类型。
enum ActivityKind: String, Sendable {
    case announcement
    case release
    case star
    case repository
    case following
    case suggestion
}

/// Activity 中栏与右栏共享的展示模型。
///
/// 这里保留 `repo` / `release` 引用，而不是把字段全部摊平成字符串，是因为右侧详情页
/// 需要根据类型展示不同信息；保持原模型能减少重复字段和后续漂移。
struct ActivityItem: Identifiable, Equatable {
    let id: String
    let kind: ActivityKind
    let category: ActivityCategory
    let title: String
    let subtitle: String?
    let body: String?
    let createdAt: Date?
    let htmlURL: URL?
    let repo: Repo?
    let release: ReleaseRecord?
    /// 发行版聚合详情专用：同一个 repo 下已缓存的 Release 列表，按发布时间倒序。
    ///
    /// 其它 Activity kind 保持空数组。把它放在 ActivityItem 上，是为了列表选中后
    /// 详情页首帧无需再做一次 DB 查询；详情 shell 仍会按 repoId 后台刷新最新缓存。
    let releases: [ReleaseRecord]
    let isRead: Bool

    /// 行 / 详情头部 accent 配色：
    /// - 若卡片关联到具体 repo 且 repo 有主语言，复用语言色，维持与 RepoRowView 一致的视觉
    /// - 否则回退到分类自身的色点
    /// 返回 `Color` 而不是语言名，避免每个调用点再绕一次 `LanguageColor.color(for:)`，
    /// 也让"分类色"与"语言色"在调用点完全等价。
    var accentColor: Color {
        if let language = repo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return category.iconColor
    }
}
