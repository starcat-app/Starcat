//
//  GitHubStarListVisibilityBadge.swift
//  Starcat
//
//  真实 GitHub List 的公开 / 私有标识。
//  只给有 isPrivate 字段的 List 出徽标；未分组和其它星标入口没有可见性，附件槽保持空。
//

import SwiftUI

/// 中栏数量行右侧的分组可见性。图标规格对齐探索页 `info.circle`。
enum GitHubStarListVisibilityBadge: Equatable, Hashable, Sendable {
    case `public`
    case `private`

    /// 公开用 globe，私有用 lock.fill；两者都是 GitHub List 的原意象。
    var systemImage: String {
        switch self {
        case .public: return "globe"
        case .private: return "lock.fill"
        }
    }

    var helpKey: String {
        switch self {
        case .public: return "githubStarLists.visibility.public"
        case .private: return "githubStarLists.visibility.private"
        }
    }

    /// 只有侧栏选中真实 List、且本地已经同步到该 List 时才出徽标。
    static func make(
        selection: SidebarItem,
        lists: [GitHubStarList]
    ) -> GitHubStarListVisibilityBadge? {
        guard case .githubStarList(let id) = selection else { return nil }
        guard let list = lists.first(where: { $0.id == id }) else { return nil }
        return list.isPrivate ? .private : .public
    }
}

/// 钉在系统 `navigationSubtitle`「N 个仓库」右侧，只读，不抢点击。
struct GitHubStarListVisibilityBadgeView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let badge: GitHubStarListVisibilityBadge

    var body: some View {
        Image(systemName: badge.systemImage)
            .font(interfaceScale.font(.caption, weight: .medium))
            .foregroundStyle(.secondary)
            .help(LocalizedStringKey(badge.helpKey))
            .accessibilityLabel(Text(LocalizedStringKey(badge.helpKey)))
            .accessibilityAddTraits(.isStaticText)
    }
}
