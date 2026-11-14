//
//  ProfileOrganizationsView.swift
//  Starcat
//
//  个人卡片右侧的公开组织头像组；最多三个位置，窄宽度逐级收起为原生菜单。
//

import AppKit
import Kingfisher
import SwiftUI

/// 只消费已缓存的组织资料，不在视图中请求成员关系；图片复用项目的 Kingfisher 缓存。
struct ProfileOrganizationsView: View {
    let organizations: [GitHubOrganizationDTO]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            organizationButtons(maximumSlots: 3)
            organizationButtons(maximumSlots: 2)
            organizationButtons(maximumSlots: 1)
        }
    }

    /// 为溢出菜单预留一个位置；每个候选保留自然宽度，交给 ViewThatFits 判断是否放得下。
    private func organizationButtons(maximumSlots: Int) -> some View {
        let visibleCount = organizations.count <= maximumSlots ? organizations.count : maximumSlots - 1
        let remaining = Array(organizations.dropFirst(visibleCount))
        return HStack(spacing: 5) {
            ForEach(organizations.prefix(visibleCount)) { organization in
                Button {
                    NSWorkspace.shared.open(GitHubURLs.userProfile(login: organization.login))
                } label: {
                    organizationAvatar(organization)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover(scale: 1.06)
                .help(tooltip(for: organization))
                .accessibilityLabel(Text(verbatim: organization.login))
            }
            if !remaining.isEmpty {
                Menu {
                    ForEach(remaining) { organization in
                        Button {
                            NSWorkspace.shared.open(GitHubURLs.userProfile(login: organization.login))
                        } label: {
                            Text(verbatim: organization.login)
                        }
                        .help(tooltip(for: organization))
                    }
                } label: {
                    Text(verbatim: "+\(remaining.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, minHeight: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("sidebar.organizations.more"))
                .accessibilityLabel(Text("sidebar.organizations.more"))
                .accessibilityValue(Text(verbatim: remaining.map(\.login).joined(separator: ", ")))
            }
        }
        .fixedSize()
    }

    /// GitHub 组织标识保留圆角方形，避免圆形裁切损失 logo 四角。
    private func organizationAvatar(_ organization: GitHubOrganizationDTO) -> some View {
        KFImage(GitHubAvatarURL.imageURL(from: organization.avatarUrl, displayDiameter: 20))
            .resizable()
            .cancelOnDisappear(true)
            .placeholder {
                Image(systemName: "building.2")
                    .foregroundStyle(.secondary)
            }
            .fade(duration: 0.15)
            .scaledToFill()
            .frame(width: 20, height: 20)
            .background(.secondary.opacity(0.12))
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.secondary.opacity(0.18), lineWidth: 0.5)
            }
    }

    /// 使用组织原文作为提示，保留账号和 GitHub 简介，不生成额外显示名称。
    private func tooltip(for organization: GitHubOrganizationDTO) -> String {
        guard let description = organization.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return organization.login }
        return "\(organization.login)\n\(description)"
    }
}
