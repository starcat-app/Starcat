//
//  ProfileAccountPopover.swift
//  Starcat
//
//  复用头像右上角的账户入口展示勋章、组织和 GitHub Sponsors，同时保留刷新与退出登录。
//

import AppKit
import Kingfisher
import SwiftUI

/// 浮层只消费专属服务；首次加载显示分区骨架，刷新保留已有内容，空 Sponsors 不占空间。
struct ProfileAccountPopover: View {
    let user: GitHubUserDTO
    let service: ProfileExtrasService
    let lastRefreshed: String?
    let onRefresh: () -> Void
    let onSignOut: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @FocusState private var focusedAchievement: String?
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("profile.extras.title")
                    .font(interfaceScale.font(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "@\(user.login)")
                    .font(interfaceScale.font(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, interfaceScale.scaled(16))
            .padding(.vertical, interfaceScale.scaled(12))
            Divider()
            profileContent
            Divider()
            accountActions
        }
        .frame(width: interfaceScale.scaled(340))
        .task(id: user.id) { service.load(user: user) }
    }

    private var profileContent: some View {
        let maximumHeight = interfaceScale.scaled(420)
        return ScrollView {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
                achievementsSection
                Divider()
                organizationsSection
                sponsorsSection
                    .animation(contentAnimation, value: service.snapshot.sponsors)
                    .animation(contentAnimation, value: service.failures.contains(.sponsors))
            }
            .padding(.leading, interfaceScale.scaled(16))
            .padding(.trailing, interfaceScale.scaled(8))
            .padding(.vertical, interfaceScale.scaled(12))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .contentMargins(.trailing, interfaceScale.scaled(8), for: .scrollContent)
        // 测量实际内容，短面板随内容收紧，长面板只滚动中间区域。
        .frame(height: min(contentHeight ?? maximumHeight, maximumHeight))
    }

    private var achievementColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: interfaceScale.scaled(4)), count: 4)
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            HStack(spacing: 8) {
                sectionHeader(Text("profile.extras.achievements"), symbol: "medal")
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Button {
                    openAchievements()
                } label: {
                    HStack(spacing: 4) {
                        Text("profile.extras.achievements.open")
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                    .font(interfaceScale.font(size: 11))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .inlineActionHover()
            }
            if let achievements = service.snapshot.achievements {
                if achievements.isEmpty {
                    Text("profile.extras.achievements.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: achievementColumns, spacing: interfaceScale.scaled(7)) {
                        ForEach(achievements) { achievement in
                            achievementButton(achievement)
                        }
                    }
                    .transition(.opacity)
                }
            } else if !service.failures.contains(.achievements) {
                ProfileExtrasSkeleton(
                    columns: achievementColumns,
                    count: 4,
                    size: interfaceScale.scaled(52),
                    height: interfaceScale.scaled(57),
                    cornerRadius: interfaceScale.scaled(26)
                )
            }
            if service.failures.contains(.achievements) { failureNotice }
        }
        .animation(contentAnimation, value: service.snapshot.achievements)
        .animation(contentAnimation, value: service.failures.contains(.achievements))
    }

    private var organizationsSection: some View {
        let result = service.snapshot.organizations
        let organizations = result?.organizations ?? user.organizations ?? []
        return VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            sectionHeader(Text("profile.extras.organizations"), symbol: "building.2")
            if result == nil && !service.failures.contains(.organizations) {
                ProfileExtrasSkeleton(
                    columns: ProfileOrganizationsView.columns(at: interfaceScale),
                    count: 5,
                    size: interfaceScale.scaled(36),
                    cornerRadius: interfaceScale.scaled(8)
                )
            } else if organizations.isEmpty {
                Text("profile.extras.organizations.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProfileOrganizationsView(organizations: organizations)
                    .transition(.opacity)
            }
            if result?.accessLimited == true || service.failures.contains(.organizations) {
                Text("profile.extras.organizations.limited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(contentAnimation, value: result)
        .animation(contentAnimation, value: service.failures.contains(.organizations))
    }

    @ViewBuilder
    private var sponsorsSection: some View {
        let sponsors = service.snapshot.sponsors
        let failed = service.failures.contains(.sponsors)
        let hasAccounts = sponsors.map { !$0.sponsors.isEmpty || !$0.sponsoring.isEmpty } ?? false
        if hasAccounts || sponsors == nil {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
                Divider().padding(.bottom, interfaceScale.scaled(4))
                sectionHeader(Text(verbatim: "GitHub Sponsors"), symbol: "heart")
                if let sponsors {
                    ProfileSponsorsGroup(accounts: sponsors.sponsors, title: "profile.extras.sponsors.received")
                    ProfileSponsorsGroup(accounts: sponsors.sponsoring, title: "profile.extras.sponsors.given")
                } else if !failed {
                    ProfileExtrasSkeleton(
                        columns: ProfileSponsorsGroup.columns(at: interfaceScale),
                        count: ProfileSponsorsGroup.columnCount,
                        size: interfaceScale.scaled(36),
                        cornerRadius: interfaceScale.scaled(18)
                    )
                }
                if failed { failureNotice }
            }
            .transition(.opacity)
        } else if failed {
            failureNotice
        }
    }

    /// 保留 GitHub 原图与等级原文；等级叠在图角，同一列的各枚勋章始终等高。
    private func achievementButton(_ achievement: GitHubAchievement) -> some View {
        let description = [achievement.name, achievement.tier].compactMap { $0 }.joined(separator: " · ")
        return Button {
            openAchievements(slug: achievement.id)
        } label: {
            KFImage(achievement.imageURL)
                .resizable()
                .cancelOnDisappear(true)
                .placeholder {
                    Image(systemName: "medal")
                        .font(interfaceScale.font(size: 24))
                        .foregroundStyle(.secondary)
                }
                .scaledToFit()
                .frame(width: interfaceScale.scaled(52), height: interfaceScale.scaled(52))
                .frame(width: interfaceScale.scaled(62), height: interfaceScale.scaled(57))
                .overlay(alignment: .bottomTrailing) {
                    if let tier = achievement.tier, !tier.isEmpty {
                        Text(verbatim: tier)
                            .font(interfaceScale.font(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(minWidth: interfaceScale.scaled(23), minHeight: interfaceScale.scaled(16))
                            .background(Color.primary.opacity(0.12), in: Capsule())
                            .background(.background, in: Capsule())
                    }
                }
                .overlay {
                    if focusedAchievement == achievement.id {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedAchievement, equals: achievement.id)
        .inlineActionHover(cornerRadius: 8)
        .help(description)
        .accessibilityLabel(Text(verbatim: description))
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SyncIconButton(
                    isRefreshing: service.isLoading,
                    disabled: service.isLoading,
                    tooltip: String.l10n("sidebar.account.refresh"),
                    action: onRefresh
                )
                Button("sidebar.account.refresh", action: onRefresh)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(service.isLoading)
                Spacer(minLength: 0)
                // 时间留在操作行尾，长译文只截断辅助信息，不增加操作区高度。
                if let lastRefreshed {
                    Text(verbatim: lastRefreshed)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(lastRefreshed)
                }
            }
            Button(role: .destructive, action: onSignOut) {
                Label("auth.signOut", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .font(.system(size: interfaceScale.scaled(12)))
        .padding(16)
    }

    private func sectionHeader(_ title: Text, symbol: String) -> some View {
        Label { title } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .font(interfaceScale.font(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
    }

    /// 使用 URLComponents 保留用户名与成就 slug 的正确转义，不拼接网页查询字符串。
    private func openAchievements(slug: String? = nil) {
        guard var components = URLComponents(
            url: GitHubURLs.userProfile(login: user.login), resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "tab", value: "achievements")]
        if let slug { components.queryItems?.append(URLQueryItem(name: "achievement", value: slug)) }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private var failureNotice: some View {
        Text("profile.extras.loadFailed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var contentAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.1 : 0.18)
    }
}

/// 两个赞助方向各自折叠。保留展开按钮的网格位置，展开较长列表时仍可原地收起。
private struct ProfileSponsorsGroup: View {
    static let columnCount = 7

    let accounts: [GitHubSponsor]
    let title: LocalizedStringKey

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isToggleFocused: Bool
    @State private var isExpanded = false

    var body: some View {
        if !accounts.isEmpty {
            let previewCount = Self.columnCount * 2 - 1
            let hiddenCount = accounts.count - previewCount
            VStack(alignment: .leading, spacing: interfaceScale.scaled(5)) {
                Text(title)
                    .font(interfaceScale.font(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(
                    columns: Self.columns(at: interfaceScale),
                    alignment: .leading,
                    spacing: interfaceScale.scaled(6)
                ) {
                    ForEach(accounts.prefix(previewCount), content: avatar)
                    if hiddenCount > 0 {
                        expansionButton(hiddenCount: hiddenCount)
                    }
                    if isExpanded {
                        ForEach(accounts.dropFirst(previewCount), content: avatar)
                            .transition(.opacity)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    /// 给始终显示的滚动条留出余量，同时保证两行预览总是同一列数。
    static func columns(at scale: InterfaceScale) -> [GridItem] {
        Array(repeating: GridItem(.fixed(scale.scaled(36)), spacing: scale.scaled(6)), count: columnCount)
    }

    private func avatar(_ account: GitHubSponsor) -> some View {
        ProfileAccountAvatar(
            login: account.login,
            avatarUrl: account.avatarUrl,
            size: interfaceScale.scaled(36),
            cornerRadius: interfaceScale.scaled(18)
        )
    }

    /// 使用图标表达收起，保证长译文仍可使用同一点击区域。
    private func expansionButton(hiddenCount: Int) -> some View {
        let action: LocalizedStringKey = isExpanded ? "sidebar.collapse" : "sidebar.expand"
        let count = hiddenCount.formatted(.number.locale(locale))
        let size = interfaceScale.scaled(36)
        let shape = RoundedRectangle(cornerRadius: interfaceScale.scaled(8))
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                isExpanded.toggle()
            }
        } label: {
            Group {
                if isExpanded {
                    Image(systemName: "chevron.up")
                } else {
                    Text(verbatim: "+\(count)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 2)
                }
            }
            .font(interfaceScale.font(size: 12, weight: .semibold))
            .frame(width: size, height: size)
            .overlay {
                shape.strokeBorder(
                    isToggleFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isToggleFocused)
        .inlineActionHover(cornerRadius: interfaceScale.scaled(8))
        .help(Text(action))
        .accessibilityLabel(Text(action))
        .accessibilityValue(Text(verbatim: isExpanded ? "" : count))
    }
}

/// 骨架沿用各分区的真实列宽；共用项目时钟，减少动态效果时静态展示。
private struct ProfileExtrasSkeleton: View {
    let columns: [GridItem]
    let count: Int
    let size: CGFloat
    var height: CGFloat? = nil
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            LazyVGrid(columns: columns, alignment: .leading) {
                ForEach(0..<count, id: \.self) { _ in
                    SkeletonBlock(width: size, height: size, cornerRadius: cornerRadius, phase: phase, palette: palette)
                        .frame(height: height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}
