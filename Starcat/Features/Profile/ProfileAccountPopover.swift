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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("profile.extras.title")
                    .font(.system(size: interfaceScale.scaled(15), weight: .semibold))
                Text(verbatim: "@\(user.login)")
                    .font(.system(size: interfaceScale.scaled(12)))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    achievementsSection
                    organizationsSection
                    sponsorsSection
                        .animation(contentAnimation, value: service.snapshot.sponsors)
                }
                .padding(16)
            }
            .frame(height: interfaceScale.scaled(360))
            Divider()
            accountActions
        }
        .frame(width: interfaceScale.scaled(340))
        .task(id: user.id) { service.load(user: user) }
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("profile.extras.achievements", symbol: "medal")
            if let achievements = service.snapshot.achievements {
                if achievements.isEmpty {
                    Text("profile.extras.achievements.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58))], spacing: 12) {
                        ForEach(achievements) { achievement in
                            achievementButton(achievement)
                        }
                    }
                }
            } else if !service.failures.contains(.achievements) {
                ProfileExtrasSkeleton(isGrid: true)
            }
            if service.failures.contains(.achievements) { failureNotice }
            Button {
                openAchievements()
            } label: {
                Label("profile.extras.achievements.open", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .animation(contentAnimation, value: service.snapshot.achievements)
    }

    private var organizationsSection: some View {
        let result = service.snapshot.organizations
        let organizations = result?.organizations ?? user.organizations ?? []
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("profile.extras.organizations", symbol: "building.2")
            if result == nil && !service.failures.contains(.organizations) {
                ProfileExtrasSkeleton(isGrid: false)
            } else if organizations.isEmpty {
                Text("profile.extras.organizations.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProfileOrganizationsView(organizations: organizations)
            }
            Text("profile.extras.organizations.access")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if result?.accessLimited == true || service.failures.contains(.organizations) {
                Text("profile.extras.organizations.limited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(contentAnimation, value: result)
    }

    @ViewBuilder
    private var sponsorsSection: some View {
        if let sponsors = service.snapshot.sponsors {
            if !sponsors.sponsors.isEmpty || !sponsors.sponsoring.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: "GitHub Sponsors")
                    } icon: {
                        Image(systemName: "heart")
                    }
                    .font(.system(size: interfaceScale.scaled(12), weight: .semibold))
                    sponsorRows(sponsors.sponsors, title: "profile.extras.sponsors.received")
                    sponsorRows(sponsors.sponsoring, title: "profile.extras.sponsors.given")
                    if service.failures.contains(.sponsors) { failureNotice }
                }
                .transition(.opacity)
            } else if service.failures.contains(.sponsors) {
                failureNotice
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "GitHub Sponsors").font(.caption.weight(.semibold))
                if service.failures.contains(.sponsors) {
                    failureNotice
                } else {
                    ProfileExtrasSkeleton(isGrid: false)
                }
            }
        }
    }

    /// 勋章原图为 40pt，等级保留 GitHub 原文；点击进入该用户对应的官方成就详情。
    private func achievementButton(_ achievement: GitHubAchievement) -> some View {
        Button {
            openAchievements(slug: achievement.id)
        } label: {
            VStack(spacing: 2) {
                KFImage(achievement.imageURL)
                    .resizable()
                    .cancelOnDisappear(true)
                    .placeholder {
                        Image(systemName: "medal")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                Text(verbatim: achievement.tier ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(scale: reduceMotion ? 1 : 1.04)
        .help([achievement.name, achievement.tier].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel(Text(verbatim: [achievement.name, achievement.tier].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder
    private func sponsorRows(_ accounts: [GitHubSponsor], title: LocalizedStringKey) -> some View {
        if !accounts.isEmpty {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 2) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    ProfileAccountRow(login: account.login, avatarUrl: account.avatarUrl, rowIndex: index)
                }
            }
        }
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
                    .disabled(service.isLoading)
                Spacer(minLength: 0)
            }
            if let lastRefreshed {
                Text(verbatim: lastRefreshed)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    private func sectionHeader(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: interfaceScale.scaled(12), weight: .semibold))
            .foregroundStyle(.primary)
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

/// 共用项目的单时钟骨架；静态减少动效由 SkeletonAnimatedPhase 统一处理。
private struct ProfileExtrasSkeleton: View {
    let isGrid: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            if isGrid {
                HStack(spacing: 18) {
                    ForEach(0..<4) { _ in
                        SkeletonBlock(width: 40, height: 40, cornerRadius: 8, phase: phase, palette: palette)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(0..<2) { _ in
                        HStack(spacing: 10) {
                            SkeletonBlock(width: 32, height: 32, cornerRadius: 7, phase: phase, palette: palette)
                            SkeletonBlock(width: 150, height: 12, phase: phase, palette: palette)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
