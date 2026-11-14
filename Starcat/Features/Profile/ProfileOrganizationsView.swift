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

    @Environment(\.displayScale) private var displayScale

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
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
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

    /// 12pt 圆形头像与同排社交图标保持一致，按钮外层保留 20pt 点击区域。
    /// 至少请求 64px 图源后高质量缩小，避免小尺寸头像细节因低分辨率取图而模糊。
    private func organizationAvatar(_ organization: GitHubOrganizationDTO) -> some View {
        KFImage(GitHubAvatarURL.imageURL(
            from: organization.avatarUrl,
            displayDiameter: 12,
            displayScale: displayScale,
            minimumPixelSize: 64
        ))
            .resizable()
            .interpolation(.high)
            .cancelOnDisappear(true)
            .placeholder {
                Image(systemName: "building.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .fade(duration: 0.15)
            .scaledToFill()
            .frame(width: 12, height: 12)
            .clipShape(Circle())
    }

    /// 使用组织原文作为提示，保留账号和 GitHub 简介，不生成额外显示名称。
    private func tooltip(for organization: GitHubOrganizationDTO) -> String {
        guard let description = organization.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return organization.login }
        return "\(organization.login)\n\(description)"
    }
}
