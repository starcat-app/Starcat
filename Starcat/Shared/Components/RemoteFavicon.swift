//
//  RemoteFavicon.swift
//  Starcat
//
//  网页搜索结果卡片左侧的 favicon 加载组件。
//
//  ────────────────────────────────────────────────────────────────────────────
//  两段 fallback 加载策略（2026-06-13, dong4j 决策）
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. 先打源站 `https://{host}/favicon.ico` —— HTTP 标准约定路径，命中即用
//  2. 失败 fallback 到 Google s2 API：`https://www.google.com/s2/favicons?domain={host}&sz=64`
//  3. 都失败 → SF Symbol `globe` 占位
//
//  为什么不一开始就用 Google s2 单源：
//  - 源站 `/favicon.ico` 能拿到站点原版 favicon（Google s2 返回的有时是缩略/裁剪版）
//  - 命中时省一次"绕道 Google"的网络跳转，对国内用户更快
//  - 失败成本可控：Kingfisher onFailure 回调里切到 s2，用户只会看到一次 fade 过渡
//
//  为什么 fallback 必须用 Google s2 而不是别的兜底：
//  - Google s2 命中率 ≈ 99%（Google 提前抓 + 归一化为 PNG，永不返回 ICO 多帧）
//  - Kingfisher 默认不解 ICO 容器，源站直返 .ico 即使 200 也可能解码失败
//  - Google s2 永远返回 PNG，Kingfisher 直接吃，无格式问题
//
//  已踩过的坑（防止后续协作者改坏）：
//  - **必须用 `currentURL == nil` 守护 onFailure 切换**：否则 Google s2 也失败
//    会触发第二次 onFailure → 再次 setState → KFImage 重新加载 → 死循环
//  - **不能在 onAppear 里 reset `currentURL = nil`**：否则 row 重用时会从 primary
//    重新打源站，浪费请求；Kingfisher 缓存键基于完整 URL，复用机制自洽
//  - Kingfisher 解码失败（HTML 兜底页 / SVG 不在支持列表 / ICO 多帧）也会触发
//    onFailure，所以"200 但不是图片"也能自动落到 s2 ✅
//
//  ────────────────────────────────────────────────────────────────────────────
//  视觉规格
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 默认 18pt 边长
//  - 圆角矩形 4pt 剪裁（**不是圆形**，保留 favicon 原本是矩形 logo 的语义）
//  - 加载中 / 失败：SF Symbol `globe` + tertiary 颜色，与卡片整体灰度系统一致
//  - fade 过渡 0.15s（与 RemoteAvatar 一致）
//

import SwiftUI
import Kingfisher

/// 远程加载的站点 favicon。
///
/// 使用示例：
/// ```swift
/// RemoteFavicon(host: "github.com", size: 18)
/// ```
struct RemoteFavicon: View {

    /// 站点 host（不含 scheme / path），如 `"github.com"`。
    /// 空字符串时直接落到 placeholder。
    let host: String

    /// 圆角矩形剪裁后的边长（pt）。
    var size: CGFloat = 18

    /// onFailure 触发后切到的 fallback URL。
    /// 状态机：nil = 尚未失败，仍在用 primary；non-nil = 已切到 Google s2。
    @State private var fallbackURL: URL?

    var body: some View {
        Group {
            if host.isEmpty {
                placeholder
            } else if let url = activeURL {
                KFImage(url)
                    .placeholder { placeholder }
                    .onFailure { _ in
                        // 仅切换一次：避免 fallback 也失败时触发死循环。
                        // 已切到 fallbackURL 后再失败 → Kingfisher 维持显示 placeholder。
                        if fallbackURL == nil {
                            fallbackURL = Self.fallbackURL(for: host)
                        }
                    }
                    .fade(duration: 0.15)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// 当前激活的 URL：优先 fallback（若已切换），否则 primary。
    private var activeURL: URL? {
        fallbackURL ?? Self.primaryURL(for: host)
    }

    /// SF Symbol globe 占位，色彩同 RemoteAvatar.placeholder。
    /// 故意弱化：favicon 加载前 / 失败时的装饰占位，非可读正文（CLAUDE.md UI 颜色规范例外）。
    @ViewBuilder
    private var placeholder: some View {
        Image(systemName: "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.tertiary)
            .padding(2)
    }

    // MARK: - URL 构造

    /// 第一阶段：源站根目录 `/favicon.ico`。
    static func primaryURL(for host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://\(trimmed)/favicon.ico")
    }

    /// 第二阶段：Google s2 favicon API（永远 PNG，命中率 ≈ 99%）。
    /// `sz=64` 在 retina 上 18pt 显示足够锐利；不需要更高分辨率（增加流量）。
    static func fallbackURL(for host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: trimmed),
            URLQueryItem(name: "sz", value: "64")
        ]
        return components.url
    }
}

#Preview("RemoteFavicon · 多 host") {
    HStack(spacing: 12) {
        RemoteFavicon(host: "github.com")
        RemoteFavicon(host: "developer.apple.com")
        RemoteFavicon(host: "openai.com")
        RemoteFavicon(host: "")   // 空 host fallback
        RemoteFavicon(host: "this-domain-should-not-exist-12345.invalid") // 网络失败 fallback
    }
    .padding()
}
