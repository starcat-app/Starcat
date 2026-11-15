//
//  ProfileOrganizationsView.swift
//  Starcat
//
//  账户浮层中的组织列表；头像放大为 32pt，名称与完整简介提供可读的成员关系入口。
//

import SwiftUI

/// 只消费账户浮层已经合并的组织，不在视图中读 Token 或查询成员关系。
struct ProfileOrganizationsView: View {
    let organizations: [GitHubOrganizationDTO]

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(organizations.enumerated()), id: \.element.id) { index, organization in
                ProfileAccountRow(
                    login: organization.login,
                    avatarUrl: organization.avatarUrl,
                    detail: organization.description,
                    rowIndex: index
                )
            }
        }
    }
}
