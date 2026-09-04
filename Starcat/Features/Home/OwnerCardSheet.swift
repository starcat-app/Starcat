//
//  OwnerCardSheet.swift
//  Starcat
//
//  仓库详情页 hero 区点击 owner 名弹出的真实资料卡容器。
//
//  本视图只负责加载 GitHub 公开资料、贡献数据与关注状态，再交给
//  OwnerCardView 展示：明亮主题使用 A，黑暗主题使用 B。
//  贡献数据对组织账号可能不可用，因此 nil 时不渲染，也不预留高度。
//

import AppKit
import SwiftUI

struct OwnerCardSheet: View {

    /// owner 的 GitHub login（如 `apple`）。
    let ownerLogin: String

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.dismiss) private var dismiss

    /// 拉取到的 owner 公开 profile；nil = 加载中或加载失败。
    @State private var profile: GitHubUserDTO?

    /// 是否已关注；nil = 未登录或查询中。
    @State private var isFollowing: Bool?

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
            websiteURL: websiteURL,
            emailAddress: normalizedEmail,
            contributionPayload: contributionPayload,
            isFollowing: isFollowing,
            isFollowInFlight: isFollowingInFlight,
            isFollowActionEnabled: followActionEnabled,
            onOpenGitHub: openGitHubProfile,
            onClose: { dismiss() },
            onOpenWebsite: openWebsite,
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

    /// GitHub 允许 blog 不带 scheme；统一补成可直接打开的 HTTPS URL。
    private var websiteURL: URL? {
        guard let raw = profile?.blog?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        return URL(string: "https://\(raw)")
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

    private func openWebsite() {
        guard let websiteURL else { return }
        NSWorkspace.shared.open(websiteURL)
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
        if let contribution = try? await dependencies.ownerFollowService.contribution(login: ownerLogin) {
            contributionPayload = contribution
        }

        guard authSession.state.isAuthenticated else { return }
        if let following = try? await dependencies.ownerFollowService.isFollowing(login: ownerLogin) {
            isFollowing = following
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
