//
//  SidebarHeaderView.swift
//  Starcat
//
//  Sidebar 顶部用户信息卡片。
//
//  布局参考用户提供的设计图：
//  - 头像（圆形，56pt）
//  - 显示名 + @login
//  - 三栏统计：本地 Starred / 远程 Followers / 远程 Following
//  - 点击头像 → 跳转 GitHub 主页；右上角"…"按钮 → popover：退出登录
//
//  设计约束：
//  - 用 popover 而非 Menu，避免 macOS 26 toolbar 上 Menu(label: custom view)
//    导致的 sizing bug（详情见 docs/工程进度/2026-05-30 评审）
//  - 数据来源：本地 starred 计数走 HomeViewModel.totalCount；
//    Followers/Following 走 AuthSession 的 user 字段（首次 /user 调用时拉到）
//  - 未授权态：不渲染（Sidebar 在登录后才挂载）
//

import SwiftUI
import AppKit

struct SidebarHeaderView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var viewModel
    /// 用于打开 macOS 原生设置窗口（SettingsLink 的 programmatic 等效方式）
    @Environment(\.openSettings) private var openSettings

    /// 登录表单 sheet 显示状态。
    @State private var showLoginSheet: Bool = false

    var body: some View {
        VStack(spacing: 10) {
            switch authSession.state {
            case .authenticated(let user):
                avatarRow(user: user)
                identity(user: user)
                statsRow(user: user)
            case .unauthenticated, .awaitingUserCode:
                unauthenticatedAvatarRow()
                unauthenticatedIdentity()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(.bar)
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
        }
        .onChange(of: authSession.state) { _, newState in
            if newState.isAuthenticated {
                showLoginSheet = false
            }
        }
    }

    // MARK: - 未登录态

    private func unauthenticatedAvatarRow() -> some View {
        ZStack(alignment: .topTrailing) {
            UserAvatar(
                isLoggedIn: false,
                avatarUrl: nil,
                login: nil,
                onLoginTapped: { showLoginSheet = true }
            )
        }
    }

    private func unauthenticatedIdentity() -> some View {
        VStack(spacing: 2) {
            Text("未登录")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
    }

    // MARK: - 头像行（含账户菜单入口）

    private func avatarRow(user: GitHubUserDTO) -> some View {
        ZStack(alignment: .topTrailing) {
            UserAvatar(
                isLoggedIn: true,
                avatarUrl: user.avatarUrl,
                login: user.login,
                onLoginTapped: { showLoginSheet = true }
            )

            // 右上角账户菜单按钮（使用原生 Menu，获得系统一致样式）
            accountMenu()
        }
    }

    /// 账户操作菜单。使用 SwiftUI 原生 Menu 组件，自带圆角、hover 反馈等系统样式。
    @ViewBuilder
    private func accountMenu() -> some View {
        Menu {
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) {
                authSession.signOut()
            } label: {
                Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("账户")
    }

    // MARK: - 显示名 + login

    /// 显示用户身份信息：有 name 时显示 name，无 name 时显示 login
    /// 避免 name 与 login 相同时显示两个重复项
    @ViewBuilder
    private func identity(user: GitHubUserDTO) -> some View {
        VStack(spacing: 2) {
            if let name = user.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            } else {
                Text(user.login)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 三栏统计

    /// 构建三栏统计数据行，每项均可点击并跳转到对应 GitHub 页面。
    /// - Starred → https://github.com/{username}?tab=stars
    /// - Followers → https://github.com/{username}?tab=followers
    /// - Following → https://github.com/{username}?tab=following
    private func statsRow(user: GitHubUserDTO) -> some View {
        HStack(spacing: 0) {
            StatCell(
                value: viewModel.totalCount,
                label: "Starred",
                url: URL(string: "https://github.com/\(user.login)?tab=stars")
            )
            Divider().frame(height: 26)
            StatCell(
                value: user.followers ?? 0,
                label: "Followers",
                url: URL(string: "https://github.com/\(user.login)?tab=followers")
            )
            Divider().frame(height: 26)
            StatCell(
                value: user.following ?? 0,
                label: "Following",
                url: URL(string: "https://github.com/\(user.login)?tab=following")
            )
        }
        .padding(.top, 4)
    }

    private func openGitHubProfile(login: String) {
        guard let url = URL(string: "https://github.com/\(login)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 子组件

/// 单个统计列（数字 + 标签）。
///
/// - Parameters:
///   - value: 要显示的数字
///   - label: 统计标签（Starred / Followers / Following）
///   - url: 可选链接；传入时数字会变为可点击链接，点击后在新标签页打开对应 GitHub 页面
private struct StatCell: View {
    let value: Int
    let label: String
    let url: URL?

    var body: some View {
        VStack(spacing: 2) {
            if let url = url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(value, format: .number)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("打开 GitHub \(label) 页面")
            } else {
                Text(value, format: .number)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
