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
//  - GitHub 头像支持 `?s=` / `?size=` 调整尺寸；`RemoteAvatar` 按显示直径自动注入，
//    降低列表 / 瀑布流首屏 Kingfisher 解码压力（Kingfisher cache key = 完整 URL）。
//

import SwiftUI
import Kingfisher
import AppKit

/// GitHub 头像 URL 按 UI 显示尺寸推导 CDN 像素参数。
///
/// 关键约束：
/// - `avatars.githubusercontent.com` 用 `s`（像素）；
/// - `github.com/{owner}.png` redirect 端点用 `size`；
/// - 默认按 @2x 屏推导并钳制在 32…256，避免 32pt 圆仍拉原图。
enum GitHubAvatarURL {
    static func imageURL(from urlString: String?, displayDiameter: CGFloat) -> URL? {
        guard let urlString, !urlString.isEmpty else { return nil }
        guard var components = URLComponents(string: urlString) else {
            return URL(string: urlString)
        }

        let host = components.host?.lowercased() ?? ""
        let pixelSize = clampedPixelSize(for: displayDiameter)

        if host == "avatars.githubusercontent.com" {
            upsertQueryItem(name: "s", value: "\(pixelSize)", on: &components)
            return components.url
        }

        if host == "github.com", components.path.hasSuffix(".png") {
            upsertQueryItem(name: "size", value: "\(pixelSize)", on: &components)
            return components.url
        }

        return components.url ?? URL(string: urlString)
    }

    private static func clampedPixelSize(for displayDiameter: CGFloat) -> Int {
        let scaled = Int(ceil(displayDiameter * 2))
        return min(max(scaled, 32), 256)
    }

    private static func upsertQueryItem(name: String, value: String, on components: inout URLComponents) {
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
    }
}

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
            if let url = GitHubAvatarURL.imageURL(from: urlString, displayDiameter: size) {
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
        // 故意弱化：头像加载失败 / URL 为空时的 SF Symbol 占位，非可读正文（CLAUDE.md UI 颜色规范例外）。
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
    @Environment(AppSettings.self) private var settings

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
                ZStack(alignment: .bottomTrailing) {
                    RemoteAvatar(urlString: avatarUrl, size: size)
                        .fixedSize()

                    if settings.isProUser {
                        AvatarProBadge()
                            // 2026-06-06 dong4j 反馈：原 (x:5, y:3) 导致
                            //   ① 徽章底部超出头像圆底 ~3pt（y:3 把它往下推了）
                            //   ② 整体偏左，需要往右再挪一点
                            // 修复：y 改为 0（与 ZStack bottomTrailing 自然底对齐，
                            // 徽章 Capsule 底部与头像圆 bounding box 底部齐平）；
                            // x 从 5 增到 8（视觉上像"嵌"在头像右下角而不是压住下沿）。
                            .offset(x: 8, y: 0)
                    }
                }
                .frame(width: size + 10, height: size + 6)
                .frame(maxWidth: .infinity)
            } else {
                // 故意弱化：未登录 sidebar 占位头像，非操作主文案（CLAUDE.md UI 颜色规范例外）。
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: size, height: size)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 2026-06-02 dong4j 要求统一 hover 反馈：sidebar 用户头像加 `.pressableHover()`，
        // 与详情页 hero logo / Stats / Contributors 头像保持同款交互反馈。
        // 详见 `Shared/Components/PressableHover.swift`。
        .pressableHover()
        .help(isLoggedIn ? Text("avatar.openGithubProfile") : Text("avatar.loginGithub"))
    }

    private func openGitHubProfile(login: String) {
        NSWorkspace.shared.open(GitHubURLs.userProfile(login: login))
    }
}

private struct AvatarProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.yellow, .orange, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.75), lineWidth: 0.7)
            }
            .accessibilityLabel(Text("Pro"))
    }
}
