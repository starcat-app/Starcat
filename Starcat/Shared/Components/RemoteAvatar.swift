//
//  RemoteAvatar.swift
//  Starcat
//
//  通用远程头像 / 缩略图组件。
//
//  设计要点：
//  - 用 Kingfisher 替代 AsyncImage：内置内存 + 磁盘缓存，列表滑动时不会重复请求
//  - 圆形裁剪（GitHub avatar 风格），可选描边
//  - 三态：加载中（占位 SF symbol）/ 成功 / 失败（fallback symbol）
//  - GitHub 头像支持 `?s=128` 调整尺寸；caller 不强制管，Kingfisher 缓存键基于完整 URL
//

import SwiftUI
import Kingfisher
import AppKit

/// 远程加载的圆形头像。
///
/// 使用示例：
/// ```swift
/// RemoteAvatar(urlString: user.avatarUrl, size: 40)
/// ```
struct RemoteAvatar: View {

    /// 远程 URL 字符串；nil 或非法 URL 时显示 fallback。
    let urlString: String?

    /// 圆形直径（pt）。
    var size: CGFloat = 32

    /// 加载失败时显示的 SF Symbol（默认人形图标）。
    var fallbackSymbol: String = "person.crop.circle.fill"

    /// 是否描边。
    var showBorder: Bool = true

    var body: some View {
        Group {
            if let url = urlString.flatMap(URL.init(string:)) {
                KFImage(url)
                    .resizable()
                    .placeholder { placeholder }
                    .fade(duration: 0.15)
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            if showBorder {
                Circle().stroke(.secondary.opacity(0.18), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Image(systemName: fallbackSymbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.tertiary)
            .padding(2)
    }
}

/// 用户头像组件
///
/// 根据登录状态区分渲染逻辑：
/// - 未登录：显示默认图标，点击打开登录弹窗
/// - 已登录：显示远程头像，点击打开 GitHub 用户主页
struct UserAvatar: View {
    /// 是否已登录
    let isLoggedIn: Bool
    /// 用户头像 URL（已登录时使用）
    let avatarUrl: String?
    /// 用户登录名，用于构建主页链接
    let login: String?
    /// 点击未登录头像时触发，用于打开登录弹窗
    let onLoginTapped: () -> Void

    /// 头像大小
    var size: CGFloat = 56

    var body: some View {
        Button {
            if isLoggedIn, let login = login {
                openGitHubProfile(login: login)
            } else {
                onLoginTapped()
            }
        } label: {
            if isLoggedIn {
                RemoteAvatar(urlString: avatarUrl, size: size)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: size, height: size)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isLoggedIn ? Text("avatar.openGithubProfile") : Text("avatar.loginGithub"))
    }

    private func openGitHubProfile(login: String) {
        guard let url = URL(string: "https://github.com/\(login)") else { return }
        NSWorkspace.shared.open(url)
    }
}
