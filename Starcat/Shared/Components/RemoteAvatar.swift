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
