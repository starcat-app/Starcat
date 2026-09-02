//
//  OwnerCardSheet.swift
//  Starcat
//
//  仓库详情页 hero 区点击 owner 名弹出的「owner 卡片」。
//
//  视觉设计（2026-09-02 重做，参考 GitHub hover card + 现代 profile card）：
//  - 顶部 accent 渐变 banner，向下淡出到透明；
//  - 头像悬浮压在 banner 下缘，用 windowBackground 描边 + 轻阴影营造「浮出」层次；
//  - followers / following 用垂直分隔线做对称分栏；
//  - 关注按钮按状态切换：未关注 = accent 实心，已关注 = 浅底 + 主色文字。
//
//  内容：banner + 头像 + 显示名 + @login + bio/链接行（复用 `ProfileLinksRow`）+ 统计 + 关注按钮。
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
    @Environment(\.colorScheme) private var colorScheme

    /// 拉取到的 owner 公开 profile；nil = 加载中或加载失败。
    @State private var profile: GitHubUserDTO?

    /// 是否已关注；nil = 未登录或查询中（此时按钮禁用）。
    @State private var isFollowing: Bool?

    /// 关注 / 取关操作进行中。
    @State private var isFollowingInFlight = false

    /// owner 近一年的贡献草坪；nil = 未加载 / 加载失败（不渲染草坪区）。
    @State private var contributionPayload: ContributionCalendarPayload?

    var body: some View {
        VStack(spacing: 0) {
            banner

            avatar
                // 头像上移一半，圆心压在 banner 下缘，形成悬浮效果。
                .padding(.top, -40)

            identity
                .padding(.top, 8)
                .padding(.horizontal, 20)

            profileLinks
                .padding(.top, 10)
                .padding(.horizontal, 20)

            statsRow
                .padding(.top, 16)
                .padding(.horizontal, 20)

            contributionGraph
                .padding(.top, 16)
                .padding(.horizontal, 20)

            followButton
                .padding(.top, 16)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(width: 340)
        // sheet 闭包内根视图必须挂 .appLocaleEnvironment()，否则 Text("key") 卡在系统 locale。
        .appLocaleEnvironment()
        .task { await load() }
    }

    // MARK: - Banner（accent 渐变 + 右上角关闭）

    private var banner: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.85),
                    Color.accentColor.opacity(0.28),
                    Color.accentColor.opacity(0.03),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 68)

            SheetCloseButton(action: { dismiss() })
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
    }

    // MARK: - 头像（悬浮）

    private var avatar: some View {
        RemoteAvatar(
            urlString: profile?.avatarUrl ?? RepoAvatarURL.from(owner: ownerLogin),
            size: 80
        )
        // windowBackground 描边让头像从 banner 上「浮」出来；轻阴影增强层次。
        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
        .frame(maxWidth: .infinity)
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

    // MARK: - followers / following 统计（对称分栏）

    private var statsRow: some View {
        HStack(spacing: 0) {
            statLink(
                value: profile?.followers,
                label: "repo.owner.followers",
                url: GitHubURLs.userFollowersTab(login: ownerLogin)
            )
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            statLink(
                value: profile?.following,
                label: "repo.owner.following",
                url: GitHubURLs.userFollowingTab(login: ownerLogin)
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
        )
    }

    /// 单个统计项：值 + 标签，整块点击跳 GitHub 对应 tab。
    private func statLink(value: Int?, label: LocalizedStringKey, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            VStack(spacing: 3) {
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

    // MARK: - 贡献草坪（复用 sidebar 的渲染组件）

    @ViewBuilder
    private var contributionGraph: some View {
        if contributionPayload != nil {
            ContributionGraphView(
                payload: contributionPayload,
                // owner 草坪不缓存、刚拉取，相对时间无意义；传 nil 让 header 只显示贡献总数。
                lastFetchedAt: nil,
                login: ownerLogin
            )
            // sheet 里不跑贪吃蛇：注入暂停让草坪走静态分支，省 display-link 预算。
            .environment(\.starcatContinuousAnimationsPaused, true)
        }
    }

    // MARK: - 关注按钮（按状态切换视觉）

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
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            // 未关注 = accent 实心；已关注 = 浅底 + 主色文字，形成「取消关注」的次级观感。
            .foregroundStyle(isFollowing == true ? Color.primary : Color.white)
            .background(
                isFollowing == true
                    ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
                    : Color.accentColor,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 未登录 / 查询中 / 操作中时禁用，避免误触发。
        .disabled(isFollowing == nil || isFollowingInFlight)
        .pressableHover(scale: 1.0)
    }

    // MARK: - 数据加载与动作

    private func load() async {
        // profile 与贡献草坪都是公开数据；串行拉取即可（sheet 打开后渐进填充）。
        if let fetched = try? await dependencies.ownerFollowService.profile(login: ownerLogin) {
            profile = fetched
        }
        if let contribution = try? await dependencies.ownerFollowService.contribution(login: ownerLogin) {
            contributionPayload = contribution
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
