//
//  OwnerCardView.swift
//  Starcat
//
//  仓库 owner 卡片的主题化展示层。
//
//  组件不读取 AppDependencies、AuthSession 或网络服务，只接收展示数据与动作闭包；
//  明亮主题使用图片 + 信息面板，黑暗主题使用双向虚化过渡。贡献数据保持可选，
//  组织账号无法获取贡献时不渲染对应区域，也不预留高度。
//

import Foundation
import Kingfisher
import SwiftUI

/// Owner 卡片展示层：明亮主题使用图片 + 信息面板，黑暗主题使用双向虚化图片叠层。
struct OwnerCardView: View {

    let avatarURL: String?
    let displayName: String
    let login: String
    let bio: String?
    let followers: Int?
    let following: Int?
    let websiteURL: URL?
    let emailAddress: String?
    let contributionPayload: ContributionCalendarPayload?
    let isFollowing: Bool?

    /// 关注请求进行中时显示进度并锁定按钮，避免重复提交。
    var isFollowInFlight = false
    /// 未登录时保持可点击以触发登录；仅登录后的关注状态查询期禁用。
    var isFollowActionEnabled = true

    var onOpenGitHub: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpenWebsite: () -> Void = {}
    var onComposeEmail: () -> Void = {}
    var onOpenFollowers: () -> Void = {}
    var onOpenFollowing: () -> Void = {}
    var onToggleFollow: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 已关注时默认表达关系状态，只有 hover 才暴露破坏性较强的“取消关注”意图。
    @State private var isFollowButtonHovered = false

    var body: some View {
        Group {
            if colorScheme == .dark {
                darkCard
            } else {
                lightCard
            }
        }
        .frame(width: 340)
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(cardBorderColor, lineWidth: colorScheme == .dark ? 5 : 3)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.34 : 0.14),
            radius: colorScheme == .dark ? 18 : 12,
            y: 7
        )
    }

    // MARK: - A：明亮主题

    private var lightCard: some View {
        VStack(spacing: 0) {
            avatarImage
                // A 方案的头像区域必须保持正方形，避免横向裁切后留下大块无效底部空间。
                .frame(width: 324, height: 324)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.top, 8)
                .overlay(alignment: .topTrailing) {
                    // GitHub 入口移入信息区，图片上只保留关闭动作，避免遮挡头像主体。
                    SheetCloseButton(action: onClose)
                        .padding(10)
                }

            profileContent
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - B：黑暗主题

    private var darkCard: some View {
        VStack(spacing: -48) {
            darkAvatarStage
                .overlay(alignment: .topTrailing) {
                    topActions
                        .padding(12)
                }

            // 信息区按内容自然增长；组织账号没有贡献数据时不会保留草坪占位。
            profileContent
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 共享信息区

    private var profileContent: some View {
        VStack(alignment: .leading, spacing: colorScheme == .light ? 10 : 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: displayName)
                        .font(.title3.bold())
                        .foregroundStyle(primaryContentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(verbatim: "@\(login)")
                        .font(.caption)
                        .foregroundStyle(secondaryContentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if colorScheme == .light {
                    Spacer(minLength: 4)
                    githubButton
                }
            }

            if let normalizedBio {
                Text(verbatim: normalizedBio)
                    .font(.callout)
                    .foregroundStyle(secondaryContentColor)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .help(normalizedBio)
            }

            profileLinks

            Divider()
                .overlay(dividerColor)

            HStack(spacing: 14) {
                statButton(
                    value: followers,
                    label: "repo.owner.followers",
                    systemImage: "person.2",
                    action: onOpenFollowers
                )

                statButton(
                    value: following,
                    label: "repo.owner.following",
                    systemImage: "checkmark.square",
                    action: onOpenFollowing
                )

                Spacer(minLength: 4)

                followButton
            }

            if contributionPayload != nil {
                ContributionGraphView(
                    payload: contributionPayload,
                    lastFetchedAt: nil,
                    login: login,
                    style: colorScheme == .dark ? .ownerCardDark : .standard
                )
                // 原型和现有 owner 卡片一样只展示静态草坪，避免临时预览占用 display-link。
                .environment(\.starcatContinuousAnimationsPaused, true)
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.035)
                                : Color.primary.opacity(0.025)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.primary.opacity(0.12),
                            lineWidth: 1
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var profileLinks: some View {
        if websiteURL != nil || normalizedEmail != nil {
            HStack(spacing: 8) {
                if let websiteURL {
                    compactLinkButton(
                        systemImage: "link",
                        accessibilityText: websiteURL.absoluteString,
                        action: onOpenWebsite
                    )
                }

                if let normalizedEmail {
                    compactLinkButton(
                        systemImage: "envelope",
                        accessibilityText: normalizedEmail,
                        action: onComposeEmail
                    )
                }
            }
        }
    }

    private func compactLinkButton(
        systemImage: String,
        accessibilityText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(primaryContentColor)
                .frame(width: 28, height: 28)
                .background(linkButtonFill, in: Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(scale: 1.0)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .help(accessibilityText)
    }

    private func statButton(
        value: Int?,
        label: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: value.map { compactCount($0) } ?? "-")
                    .monospacedDigit()
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.caption)
            .foregroundStyle(primaryContentColor)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(scale: 1.0)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value.map { String($0) } ?? "-"))
    }

    // MARK: - 操作

    private var topActions: some View {
        HStack(spacing: 8) {
            githubButton
            SheetCloseButton(action: onClose)
        }
    }

    private var githubButton: some View {
        Button(action: onOpenGitHub) {
            HStack(spacing: 4) {
                Text(verbatim: "GitHub")
                Image(systemName: "arrow.up.right")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(scale: 1.0)
        .help("repo.openOnGithub")
    }

    private var followButton: some View {
        Button(action: onToggleFollow) {
            Group {
                if isFollowInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else if isFollowing == true {
                    if isFollowButtonHovered {
                        Label("repo.owner.unfollow", systemImage: "person.badge.minus")
                    } else {
                        Label("repo.owner.followingBadge", systemImage: "checkmark")
                    }
                } else {
                    Label("repo.owner.follow", systemImage: "plus")
                }
            }
            .font(.caption.weight(.semibold))
            .frame(minWidth: 74)
            .foregroundStyle(followButtonForeground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(followButtonFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(followButtonStroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isFollowInFlight || !isFollowActionEnabled)
        .pressableHover(scale: 1.0)
        .onHover { hovering in
            isFollowButtonHovered = isFollowing == true && hovering
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isFollowButtonHovered)
    }

    // MARK: - 图片

    @ViewBuilder
    private var avatarImage: some View {
        if let imageURL {
            KFImage(
                source: .network(
                    KF.ImageResource(
                        downloadURL: imageURL,
                        cacheKey: imageURL.absoluteString
                    )
                )
            )
            .resizable()
            .cancelOnDisappear(true)
            .placeholder { avatarPlaceholder }
            .fade(duration: reduceMotion ? 0 : 0.2)
            .scaledToFill()
            .clipped()
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "person.crop.square.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(72)
        }
    }

    /// B 方案保持与 A 相同的方形头像尺寸，并用同源模糊底图贯穿顶部操作区与底部过渡区。
    private var darkAvatarStage: some View {
        ZStack(alignment: .top) {
            // 模糊底图覆盖整个舞台，GitHub / 关闭按钮不再悬浮在突兀的纯黑条上。
            avatarImage
                .frame(width: 340, height: 396)
                .blur(radius: 28)
                .scaleEffect(1.14)
                .opacity(0.68)

            avatarImage
                .frame(width: 324, height: 324)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.58), location: 0.10),
                            .init(color: .black, location: 0.22),
                            .init(color: .black, location: 0.66),
                            .init(color: .black.opacity(0.78), location: 0.80),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .shadow(color: .black.opacity(0.30), radius: 18, y: 12)

            // 单一连续渐变同时压暗按钮区和信息衔接区，避免独立倒影造成横向断层。
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.36), location: 0.0),
                    .init(color: .clear, location: 0.17),
                    .init(color: .clear, location: 0.56),
                    .init(color: .black.opacity(0.30), location: 0.74),
                    .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.96), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: 340, height: 396)
        .clipped()
    }

    // MARK: - 派生样式

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 28)
    }

    private var imageURL: URL? {
        GitHubAvatarURL.imageURL(from: avatarURL, displayDiameter: 700)
    }

    private var normalizedBio: String? {
        let value = bio?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var normalizedEmail: String? {
        let value = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var primaryContentColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var secondaryContentColor: Color {
        colorScheme == .dark ? .white.opacity(0.74) : .secondary
    }

    private var dividerColor: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .secondary.opacity(0.18)
    }

    private var linkButtonFill: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .primary.opacity(0.06)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark ? .black.opacity(0.80) : .white.opacity(0.96)
    }

    private var followButtonForeground: Color {
        if isFollowing == true {
            return isFollowButtonHovered ? .red : primaryContentColor
        }
        return colorScheme == .dark ? .black : .white
    }

    private var followButtonFill: Color {
        if isFollowing == true {
            if isFollowButtonHovered {
                return .red.opacity(colorScheme == .dark ? 0.18 : 0.09)
            }
            return colorScheme == .dark ? .white.opacity(0.12) : .primary.opacity(0.06)
        }
        return .primary
    }

    private var followButtonStroke: Color {
        guard isFollowing == true else { return .clear }
        return isFollowButtonHovered
            ? .red.opacity(0.48)
            : secondaryContentColor.opacity(0.42)
    }

    private func compactCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
