//
//  ProfileOrganizationsView.swift
//  Starcat
//
//  账户浮层中的组织头像墙，空间不足时自动换行。
//

import SwiftUI

/// 只消费账户浮层已经合并的组织，不在视图中读 Token 或查询成员关系。
struct ProfileOrganizationsView: View {
    let organizations: [GitHubOrganizationDTO]
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        LazyVGrid(columns: Self.columns(at: interfaceScale), alignment: .leading, spacing: interfaceScale.scaled(8)) {
            ForEach(organizations) { organization in
                ProfileAccountAvatar(
                    login: organization.login,
                    avatarUrl: organization.avatarUrl,
                    detail: organization.description,
                    size: interfaceScale.scaled(36),
                    cornerRadius: interfaceScale.scaled(8)
                )
            }
        }
    }

    /// 真实头像与加载占位共用列宽，系统滚动条占用空间时也能自然换行。
    static func columns(at scale: InterfaceScale) -> [GridItem] {
        let size = scale.scaled(36)
        return [GridItem(.adaptive(minimum: size, maximum: size), spacing: scale.scaled(8))]
    }
}
