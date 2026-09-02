//
//  OwnerCardSheet.swift
//  Starcat
//
//  仓库详情页 hero 区点击 owner 名弹出的「owner 卡片」。
//
//  内容：大头像 + 显示名 + @login + bio/链接行（复用 `ProfileLinksRow`）+ followers/following
//  统计（点击跳 GitHub 对应 tab）+ 底部关注按钮。
//
//  数据源：`OwnerFollowService`（`GET /users/{login}` 公开 profile + `GET/PUT/DELETE
//  /user/following/{login}` 关注动作）。profile 是公开数据，未登录也能展示；关注按钮
//  未登录时点击触发登录 sheet。
//

import SwiftUI
import AppKit

struct OwnerCardSheet: View {

    /// owner 的 GitHub login（如 `apple`）。
    let ownerLogin: String

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.dismiss) private var dismiss

    /// 拉取到的 owner 公开 profile；nil = 加载中或加载失败。
    @State private var profile: GitHubUserDTO?

    /// 是否已关注；nil = 未登录或查询中（此时按钮禁用）。
    @State private var isFollowing: Bool?

    /// 关注 / 取关操作进行中。
    @State private var isFollowingInFlight = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SheetCloseButton(action: { dismiss() })
            }
            .padding(.top, 8)
            .padding(.trailing, 8)

            VStack(spacing: 12) {
                avatar
                identity
                profileLinks
                statsRow
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            followButton
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .frame(width: 360)
        // sheet 闭包内根视图必须挂 .appLocaleEnvironment()，否则 Text("key") 卡在系统 locale。
        .appLocaleEnvironment()
        .task { await load() }
    }

    // MARK: - 头像

    private var avatar: some View {
        RemoteAvatar(
            urlString: profile?.avatarUrl ?? RepoAvatarURL.from(owner: ownerLogin),
            size: 72
        )
    }

    // MARK: - 名称 + login

    private var identity: some View {
        VStack(spacing: 3) {
            Text(verbatim: displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "@\(ownerLogin)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 显示名优先用 GitHub `name`（如 "Apple"），无则退回 login。
    private var displayName: String {
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return ownerLogin
    }

    // MARK: - bio + 链接行（复用 sidebar 的 ProfileLinksRow）

    @ViewBuilder
    private var profileLinks: some View {
        if let profile {
            ProfileLinksRow(user: profile)
        }
    }

    // MARK: - followers / following 统计

    private var statsRow: some View {
        HStack(spacing: 28) {
            statLink(
                value: profile?.followers,
                label: "repo.owner.followers",
                url: GitHubURLs.userFollowersTab(login: ownerLogin)
            )
            statLink(
                value: profile?.following,
                label: "repo.owner.following",
                url: GitHubURLs.userFollowingTab(login: ownerLogin)
            )
        }
        .padding(.top, 2)
    }

    /// 单个统计项：值 + 标签，整块点击跳 GitHub 对应 tab。
    private func statLink(value: Int?, label: LocalizedStringKey, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: value.map { String($0) } ?? "-")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(String.l10n("repo.owner.stat.help"))
    }

    // MARK: - 关注按钮

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Group {
                if isFollowingInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else if isFollowing == true {
                    Label("repo.owner.unfollow", systemImage: "person.badge.minus")
                } else {
                    Label("repo.owner.follow", systemImage: "person.badge.plus")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // 未登录 / 查询中 / 操作中时禁用，避免误触发。
        .disabled(isFollowing == nil || isFollowingInFlight)
        .tint(isFollowing == true ? Color.secondary : Color.accentColor)
    }

    // MARK: - 数据加载与动作

    private func load() async {
        // profile 是公开数据，始终拉取；失败时静默降级为「只有头像 + login」的卡片。
        if let fetched = try? await dependencies.ownerFollowService.profile(login: ownerLogin) {
            profile = fetched
        }

        // isFollowing 需要登录；未登录时保持 nil（按钮显示「关注」，点击触发登录 sheet）。
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
            // 失败保留原状态；网络层错误已由 GitHubAPIClient 记日志，UI 不弹窗（与 star 同构）。
        }
    }
}
