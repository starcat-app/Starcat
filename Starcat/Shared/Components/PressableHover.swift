//
//  PressableHover.swift
//  Starcat
//
//  共享 hover 反馈 modifier：
//  - `pressableHover` 给 hero logo / Stat / 头像等纯视觉元素提供 opacity + scale 反馈。
//  - `inlineActionHover` 给详情页文字操作与整行操作提供底色、文字层级和手型光标反馈。
//  - `toolbarIconHover` 给已有方底的 22pt 工具条图标加深浅底 + 手型光标，不缩放。
//
//  设计动机：
//  - 2026-06-02 dong4j 反馈：两个详情页（Manage / Trending）的可点击元素
//    （Stars / Forks / Watchers / Hero logo / Contributors）虽然都能点击，
//    但没有 hover 视觉反馈，用户无法感知"这是可点击的"。
//  - 之前 `TrendingHeroAvatarButton` 内嵌了一份 `@State + .onHover + .opacity +
//    withAnimation + reduceMotion`，再加几处就成 5 份重复。
//  - 抽成 modifier 后调用方一行 `.pressableHover()` 解决，零样板代码。
//
//  视觉规范（2026-06-02 dong4j 反馈"opacity 0.78 太弱"调整为 opacity + scale 组合）：
//  - 默认 hover 透明度 0.7（之前 0.78，反馈过弱已加强）
//  - 默认 hover scale 1.06（之前无）——iOS 触感反馈风格，让元素"动起来"，
//    比纯 opacity 反馈明显。对 64pt hero logo 增加 ~3.8pt、对 32pt 头像增加 ~2pt、
//    对 Stats item 增加 ~1.8pt，刚好"大元素反馈更明显"，符合视觉重要性梯度。
//  - 默认 0.15s easeOut 过渡。
//  - **强制尊重 `accessibilityReduceMotion`**：开启时动画时长归零，瞬切。
//
//  使用范围（截至 2026-06-02）：
//  - `TrendingHeroAvatarButton`（Trending 详情页 hero logo）
//  - `RepoHeroAvatarButton`（Manage 详情页 hero logo）
//  - `RepoDetailView.statsSection` 的 Stars / Forks / Watchers Button
//  - `RepoDetailView.trendingStatsSection` 的 Stars / Forks Button
//  - `RepoDetailView.contributorAvatar` 的贡献者头像 Button
//
//  关键约束：
//  - 必须配 `.buttonStyle(.plain) + .focusEffectDisabled()` 一起用，否则系统
//    Button 自带的边框 / focus ring 会盖过 opacity 反馈。
//  - 不要在 `.onHover` 触发的视图自身上做 `.contentShape` —— modifier 假定
//    被修饰的视图已经定义好 hit-test 区域（Button label 默认是 label 形状）。
//

import SwiftUI

/// 给可点击的纯视觉元素加 hover 反馈（opacity + scale 组合）。
///
/// 内部维护一个 `@State` 跟踪 hover 状态，hover 时把目标视图的不透明度从 1.0
/// 降到 `hoveredOpacity`（默认 0.7）且尺寸放大到 `hoveredScale`（默认 1.06），
/// 用 easeOut 过渡。比纯 opacity 反馈明显，让用户更容易感知"可点击"。
///
/// 自动尊重 `accessibilityReduceMotion`：开启时把动画时长设为 0，状态切换瞬时完成。
/// scale 仍然生效（瞬切），保证 reduceMotion 用户也能看到 hover 反馈，只是没动效过渡。
struct PressableOpacityHover: ViewModifier {
    /// hover 时的目标不透明度。默认 0.7（之前 0.78 反馈过弱已加强）。
    var hoveredOpacity: Double = 0.7

    /// hover 时的目标 scale。默认 1.06，iOS 触感反馈风格。
    /// 设为 1.0 即可关闭 scale 效果（如仅需 opacity 反馈的特殊场景）。
    var hoveredScale: Double = 1.06

    /// 过渡动画时长（秒）。reduceMotion 模式下会被强制归零。
    var duration: Double = 0.15

    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? hoveredScale : 1.0)
            .opacity(isHovered ? hoveredOpacity : 1.0)
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : duration)) {
                    isHovered = hovering
                }
            }
    }
}

/// 给详情页中的行内文字操作和整行操作提供一致、克制的可点击反馈。
///
/// 与 `pressableHover` 的区别：
/// - 图片、头像适合用缩放表达可点击；
/// - caption 文字和整行标题若缩放会产生视觉跳动，因此这里只改变语义色和圆角底色。
///
/// `.pointerStyle(.link)` 明确鼠标命中的是操作入口；键盘 focus ring 仍由调用方按项目规范
/// 使用 `.focusEffectDisabled()` 管理，避免这个 modifier 隐式改变 Button 的焦点策略。
private struct InlineActionHover: ViewModifier {
    let cornerRadius: CGFloat
    let backgroundOpacity: Double

    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? Color.secondary.opacity(backgroundOpacity) : Color.clear)
            )
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: isHovered
            )
    }
}

/// 给工具条方钮加 hover：浅底略加深 + 手型光标。
///
/// `pressableHover` 的 scale 会让 22pt 工具行跳动，违反 DESIGN.md「hover 不改变布局尺寸」。
/// 通知详情顶栏的 Starcat / GitHub / 翻译已经有 `squareLogoActionChrome` 浅底，
/// 这里只叠一层 `primary 8%`，光标改成 link，让用户看出来能点。
private struct ToolbarIconHover: ViewModifier {
    var cornerRadius: CGFloat = 6

    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                    .allowsHitTesting(false)
            )
            .pointerStyle(.link)
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovered
            )
    }
}

extension View {
    /// 给可点击的纯视觉元素（图标 / 头像 / 文字按钮）加 hover 透明度反馈。
    ///
    /// 是 macOS 经典 image-button 模式（Preview.app / Finder 同款），克制不浮夸。
    /// 自动尊重 `accessibilityReduceMotion`。
    ///
    /// 使用示例：
    /// ```swift
    /// Button { /* ... */ } label: {
    ///     RemoteAvatar(urlString: url, size: 64)
    /// }
    /// .buttonStyle(.plain)
    /// .focusEffectDisabled()
    /// .pressableHover()       // ← 一行加 hover 反馈
    /// .help("repo.openOnGithub")
    /// ```
    ///
    /// - Parameters:
    ///   - opacity: hover 时的目标透明度，默认 0.7。
    ///   - scale: hover 时的目标尺寸倍率，默认 1.06。设为 1.0 关闭 scale 效果。
    ///   - duration: 过渡动画时长（秒），默认 0.15。reduceMotion 用户会自动归零。
    func pressableHover(
        opacity: Double = 0.7,
        scale: Double = 1.06,
        duration: Double = 0.15
    ) -> some View {
        modifier(PressableOpacityHover(
            hoveredOpacity: opacity,
            hoveredScale: scale,
            duration: duration
        ))
    }

    /// 给 caption 文字按钮或整行 Button 增加 hover 底色与手型光标。
    ///
    /// 调用方先设置合适的 padding 和 contentShape，本 modifier 只负责视觉和 pointer 反馈，
    /// 从而让紧凑文字入口与整行入口能共享语义，但保留各自的命中区域。
    func inlineActionHover(
        cornerRadius: CGFloat = 6,
        backgroundOpacity: Double = 0.10
    ) -> some View {
        modifier(InlineActionHover(
            cornerRadius: cornerRadius,
            backgroundOpacity: backgroundOpacity
        ))
    }

    /// 给 22pt 工具条图标加 hover 浅底和手型光标，不缩放。
    func toolbarIconHover(cornerRadius: CGFloat = 6) -> some View {
        modifier(ToolbarIconHover(cornerRadius: cornerRadius))
    }

    /// 可点入口统一手型光标。plain / bordered Button 默认仍是箭头。
    func clickablePointer() -> some View {
        pointerStyle(.link)
    }
}

#Preview("PressableHover 演示") {
    VStack(spacing: 20) {
        Text("把鼠标移到下面的图标上 →")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 40) {
            Button {} label: {
                Image(systemName: "star.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("默认 opacity 0.7 + scale 1.06")

            Button {} label: {
                Image(systemName: "heart.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover(opacity: 0.5, scale: 1.1)
            .help("更明显 opacity 0.5 + scale 1.1")

            Button {} label: {
                Image(systemName: "bolt.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover(opacity: 0.85, scale: 1.0)
            .help("仅 opacity 模式 0.85（关闭 scale）")
        }
    }
    .padding(40)
}
