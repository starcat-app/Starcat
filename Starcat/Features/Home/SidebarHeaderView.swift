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
//  - 头像旁的"…"按钮 → popover：在 GitHub 打开 + 退出登录
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

    /// 用户头像旁"…"菜单 popover 显示状态。
    @State private var showAccountMenu: Bool = false

    var body: some View {
        if case .authenticated(let user) = authSession.state {
            VStack(spacing: 10) {
                avatarRow(user: user)
                identity(user: user)
                statsRow(user: user)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(.bar)
        }
    }

    // MARK: - 头像行（含右上角 popover 入口）

    private func avatarRow(user: GitHubUserDTO) -> some View {
        ZStack(alignment: .topTrailing) {
            // 头像本身不响应点击；交互入口放在右上角 ⋯ 按钮
            RemoteAvatar(urlString: user.avatarUrl, size: 56)
                .fixedSize()
                .frame(maxWidth: .infinity)

            // 右上角"⋯"按钮：弹 popover（账户操作）
            Button {
                showAccountMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("账户")
            .popover(isPresented: $showAccountMenu, arrowEdge: .top) {
                accountPopover(user: user)
            }
        }
    }

    // MARK: - 显示名 + login

    @ViewBuilder
    private func identity(user: GitHubUserDTO) -> some View {
        VStack(spacing: 2) {
            if let name = user.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Text("@\(user.login)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 三栏统计

    private func statsRow(user: GitHubUserDTO) -> some View {
        HStack(spacing: 0) {
            StatCell(value: viewModel.totalCount, label: "Starred")
            Divider().frame(height: 26)
            StatCell(value: user.followers ?? 0, label: "Followers")
            Divider().frame(height: 26)
            StatCell(value: user.following ?? 0, label: "Following")
        }
        .padding(.top, 4)
    }

    // MARK: - Popover 内容（账户操作）

    private func accountPopover(user: GitHubUserDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openGitHubProfile(login: user.login)
                showAccountMenu = false
            } label: {
                Label("在 GitHub 查看", systemImage: "safari")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button(role: .destructive) {
                authSession.signOut()
                showAccountMenu = false
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 200)
    }

    private func openGitHubProfile(login: String) {
        guard let url = URL(string: "https://github.com/\(login)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 子组件

/// 单个统计列（数字 + 标签）。
private struct StatCell: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
