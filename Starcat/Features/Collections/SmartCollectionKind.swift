//
//  SmartCollectionKind.swift
//  Starcat
//
//  Smart Collections 第一版的系统集合定义。
//
//  第一版不做用户自定义 rule builder，也不新增数据库表。系统集合是固定 enum，
//  筛选结果由本地 repo 元数据和 Repo Health 快照即时派生。
//

import Foundation
import SwiftUI

enum SmartCollectionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case needsReview
    case unmaintained
    case highValue
    case noTags
    case using
    case recentlyActive

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .needsReview: return "smartCollections.needsReview.title"
        case .unmaintained: return "smartCollections.unmaintained.title"
        case .highValue: return "smartCollections.highValue.title"
        case .noTags: return "smartCollections.noTags.title"
        case .using: return "smartCollections.using.title"
        case .recentlyActive: return "smartCollections.recentlyActive.title"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .needsReview: return "smartCollections.needsReview.subtitle"
        case .unmaintained: return "smartCollections.unmaintained.subtitle"
        case .highValue: return "smartCollections.highValue.subtitle"
        case .noTags: return "smartCollections.noTags.subtitle"
        case .using: return "smartCollections.using.subtitle"
        case .recentlyActive: return "smartCollections.recentlyActive.subtitle"
        }
    }

    var systemImage: String {
        switch self {
        case .needsReview: return "exclamationmark.magnifyingglass"
        case .unmaintained: return "clock.badge.exclamationmark"
        case .highValue: return "star.circle.fill"
        case .noTags: return "tag.slash"
        case .using: return "checkmark.seal.fill"
        case .recentlyActive: return "bolt.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsReview: return .orange
        case .unmaintained: return .red
        case .highValue: return .green
        case .noTags: return .blue
        case .using: return .accentColor
        case .recentlyActive: return .mint
        }
    }

    /// 总览卡片铺底色：用集合主题色轻微染色，便于两列网格里快速扫视区分。
    var cardBackground: Color {
        tint.opacity(0.11)
    }

    /// 总览卡片描边：比背景略深，明暗主题下都保持可读对比。
    var cardBorder: Color {
        tint.opacity(0.24)
    }

    /// 图标徽章底：比整卡背景再深一档，让 SF Symbol 更聚焦。
    var iconBadgeBackground: Color {
        tint.opacity(0.18)
    }
}
