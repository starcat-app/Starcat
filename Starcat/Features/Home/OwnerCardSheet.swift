//
//  OwnerCardSheet.swift
//  Starcat
//
//  仓库详情页 hero 区点击 owner 名弹出的真实资料卡容器。
//
//  本视图负责加载 GitHub 公开资料、社交账号与贡献数据；关注状态由详情页传入并双向同步，
//  避免打开卡片时重复请求。数据交给 OwnerCardView 展示：明亮主题使用 A，黑暗主题使用 B。
//  贡献数据对组织账号可能不可用，因此 nil 时不渲染，也不预留高度。
//

import AppKit
import SwiftUI

struct OwnerCardSheet: View {

    /// owner 的 GitHub login（如 `apple`）。
    let ownerLogin: String

    /// 详情页已查询的关注状态；卡片内关注 / 取关成功后同步回详情页。
    @Binding var isFollowing: Bool?

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.dismiss) private var dismiss

    /// 拉取到的 owner 公开 profile；nil = 加载中或加载失败。
    @State private var profile: GitHubUserDTO?

    /// GitHub 独立 Social accounts 端点返回的公开链接。
    @State private var socialAccounts: [GitHubSocialAccountDTO] = []

    /// 关注 / 取关操作进行中。
    @State private var isFollowingInFlight = false

    /// owner 近一年的贡献草坪；nil = 未加载或不可用，不渲染贡献区。
    @State private var contributionPayload: ContributionCalendarPayload?

    var body: some View {
        OwnerCardView(
            avatarURL: profile?.avatarUrl ?? RepoAvatarURL.from(owner: ownerLogin),
            displayName: displayName,
            login: ownerLogin,
            bio: profile?.bio,
            followers: profile?.followers,
            following: profile?.following,
            externalLinks: externalLinks,
            emailAddress: normalizedEmail,
            contributionPayload: contributionPayload,
            isFollowing: isFollowing,
            isFollowInFlight: isFollowingInFlight,
            isFollowActionEnabled: followActionEnabled,
            onOpenGitHub: openGitHubProfile,
            onClose: { dismiss() },
            onOpenExternalLink: openExternalLink,
            onComposeEmail: composeEmail,
            onOpenFollowers: openFollowers,
            onOpenFollowing: openFollowing,
            onToggleFollow: {
                Task { await toggleFollow() }
            }
        )
        // sheet 闭包内根视图必须注入应用 locale，否则 Text("key") 会停留在系统 locale。
        .appLocaleEnvironment()
        .task { await load() }
    }

    // MARK: - 展示数据

    /// 显示名优先使用 GitHub name；空值退回稳定的 login。
    private var displayName: String {
        guard let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return ownerLogin
        }
        return name
    }

    /// 统一合并旧 profile 字段与 Social accounts，保证 X 兜底并消除重复入口。
    private var externalLinks: [OwnerCardExternalLink] {
        OwnerCardExternalLink.make(profile: profile, socialAccounts: socialAccounts)
    }

    private var normalizedEmail: String? {
        guard let email = profile?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return nil
        }
        return email
    }

    /// 未登录时必须允许点击以唤起登录；登录后的状态查询期才禁用。
    private var followActionEnabled: Bool {
        !authSession.state.isAuthenticated || isFollowing != nil
    }

    // MARK: - 外部动作

    private func openGitHubProfile() {
        NSWorkspace.shared.open(GitHubURLs.userProfile(login: ownerLogin))
    }

    private func openExternalLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func composeEmail() {
        guard let normalizedEmail,
              let url = URL(string: "mailto:\(normalizedEmail)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openFollowers() {
        NSWorkspace.shared.open(GitHubURLs.userFollowersTab(login: ownerLogin))
    }

    private func openFollowing() {
        NSWorkspace.shared.open(GitHubURLs.userFollowingTab(login: ownerLogin))
    }

    // MARK: - 数据加载与关注

    private func load() async {
        // profile 与贡献数据都是公开接口。贡献请求失败（常见于组织账号）时保持 nil。
        if let fetched = try? await dependencies.ownerFollowService.profile(login: ownerLogin) {
            profile = fetched
        }
        if let fetched = try? await dependencies.ownerFollowService.socialAccounts(login: ownerLogin) {
            socialAccounts = fetched
        }
        if let contribution = try? await dependencies.ownerFollowService.contribution(login: ownerLogin) {
            contributionPayload = contribution
        }
    }

    private func toggleFollow() async {
        guard authSession.state.isAuthenticated else {
            authSession.requestLoginSheet()
            return
        }
        guard let current = isFollowing, !isFollowingInFlight else { return }

        isFollowingInFlight = true
        defer { isFollowingInFlight = false }

        do {
            try await dependencies.ownerFollowService.setFollowing(!current, login: ownerLogin)
            isFollowing = !current
        } catch {
            // 失败保留原状态；网络层已经记录错误，资料卡不额外打断用户。
        }
    }
}
