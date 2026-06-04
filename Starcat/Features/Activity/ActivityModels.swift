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
/// 分类数量第一版固定，因此颜色图标用固定语言名映射到 `LanguageIconView`，
/// 与 Manage 的 Languages 行保持同一套视觉语义。
enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case announcement
    case release
    case star
    case repository
    case following
    case suggestion

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
        }
    }

    var localizedTitle: String {
        switch self {
        case .all:          return String(localized: "activity.category.all")
        case .announcement: return String(localized: "activity.category.announcement")
        case .release:      return String(localized: "activity.category.release")
        case .star:         return String(localized: "activity.category.star")
        case .repository:   return String(localized: "activity.category.repository")
        case .following:    return String(localized: "activity.category.following")
        case .suggestion:   return String(localized: "activity.category.suggestion")
        }
    }

    /// 固定复用语言色，不新增分类色板。
    var iconLanguage: String {
        switch self {
        case .all:          return "Swift"
        case .announcement: return "JavaScript"
        case .release:      return "Go"
        case .star:         return "Python"
        case .repository:   return "Rust"
        case .following:    return "Java"
        case .suggestion:   return "TypeScript"
        }
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
    let isRead: Bool

    var accentLanguage: String {
        repo?.language ?? category.iconLanguage
    }
}
