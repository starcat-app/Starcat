//
//  EmptyStateView.swift
//  Starcat
//
//  通用「空状态 / 列表为空 / 未选择」视图。
//
//  ────────────────────────────────────────────────────────────────────────────
//  为什么要抽这个组件（2026-06-14, dong4j 决策）
//  ────────────────────────────────────────────────────────────────────────────
//
//  在抽出之前，项目里有 13 处几乎一模一样的「VStack { SF Symbol + 标题 +
//  描述 }」写法散落在 RepoListView / RepoDetailView / ActivityView /
//  WeeklyContentView / WeeklyDetailView / ActivityDetailView /
//  ActivityReleaseDetailContent / ReleaseTimelineView / TagEditorView /
//  RepoAIWindowContentView 等多处。重复代码导致两个问题：
//
//  1. 视觉不一致：图标 size 在 32 / 36 / 40 / 42 / 56 之间漂；spacing
//     在 10 / 12 之间漂；描述行有的 .secondary、有的 .tertiary。
//  2. 修改不收敛：dong4j 反馈「浅色主题下 .tertiary 看不清」时，需要逐
//     一去改 13 处。本组件存在的最大价值就是「未来再调整对比度只动一处」。
//
//  ────────────────────────────────────────────────────────────────────────────
//  对比度 / 颜色方案（2026-06-14）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 图标、标题、描述统一用 `.secondary`。
//  - 不再用 `.tertiary`：浅色主题下 `.tertiary` 对比度只有 ~1.5:1，远低
//    于 WCAG AA 的 4.5:1，肉眼接近「灰糊」在白色背景上；提升到 `.secondary`
//    后浅色 / 深色两个主题都能维持基本可读。
//  - 视觉层级靠 `font` 区分（图标大尺寸 / 标题 `.headline` / 描述 `.caption`），
//    无需再用颜色拉档。
//  - 已知折中：B 类调用方（TagEditorView / ReleaseTimelineView /
//    ActivityReleaseDetailContent）原本标题是默认 `.primary`，迁移后会
//    一并降到 `.secondary`，与全局保持一致；如果以后要让标题更突出，统一
//    在本文件里把 `Text(title).foregroundStyle(.secondary)` 改成
//    `.primary` 即可，零侵入。
//
//  ────────────────────────────────────────────────────────────────────────────
//  外部约束 / 设计取舍
//  ────────────────────────────────────────────────────────────────────────────
//
//  - frame 不在组件里强加。13 处调用方对 frame 需求不同（部分要 maxWidth
//    + maxHeight infinity，部分只要 maxWidth infinity，部分要 minHeight
//    280），全部由调用方包一层 `.frame(...)` 控制。
//  - subtitle 同时支持 `LocalizedStringKey`（走 String Catalog）和已经
//    格式化好的 `String`（用 `Text(verbatim:)`，避免 SwiftUI 把里面的
//    特殊字符当成本地化键解析）。两个参数互斥，外部按场景挑一个传。
//  - `accessory` 是 trailing `@ViewBuilder`，默认 `EmptyView()`。WeeklyContentView
//    错误态需要在描述下方追加"重试"按钮，就用它放进来；不需要按钮的调
//    用方完全可以忽略。
//

import SwiftUI

/// 通用空状态视图。图标 + 标题 + 可选描述 + 可选 accessory。
///
/// 典型用法：
/// ```swift
/// EmptyStateView(
///     systemImage: "bubble.left.and.bubble.right",
///     title: "ai.assistant.chat.empty.title",
///     subtitle: "ai.assistant.chat.empty.description",
///     subtitleHorizontalPadding: 40
/// )
/// .frame(maxWidth: .infinity)
/// ```
///
/// 带「重试」按钮的错误态：
/// ```swift
/// EmptyStateView(
///     systemImage: "exclamationmark.triangle",
///     title: "weekly.error.title",
///     subtitleText: errorMessage
/// ) {
///     Button("weekly.action.retry", action: retry)
///         .controlSize(.small)
/// }
/// ```
struct EmptyStateView<Accessory: View>: View {

    let systemImage: String
    let title: LocalizedStringKey

    /// 本地化描述键。与 `subtitleText` 互斥，二选一传。
    let subtitle: LocalizedStringKey?

    /// 已格式化的描述文本（如错误信息、动态拼接的字符串）。与 `subtitle` 互斥。
    let subtitleText: String?

    /// 图标字号。默认 36。常见值：32（紧凑）/ 36（标准）/ 40-42（中等）/ 56（detail 占位）。
    let iconSize: CGFloat

    /// VStack 间距。默认 10。
    let spacing: CGFloat

    /// 描述行的水平 padding。默认 0；超长描述（如带"BYOK 配置说明"）传 24-40 让文本不顶到边。
    let subtitleHorizontalPadding: CGFloat

    /// 在描述下方追加的自定义内容（通常是 Button）。默认无。
    let accessory: Accessory

    init(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleText: String? = nil,
        iconSize: CGFloat = 36,
        spacing: CGFloat = 10,
        subtitleHorizontalPadding: CGFloat = 0,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.subtitleText = subtitleText
        self.iconSize = iconSize
        self.spacing = spacing
        self.subtitleHorizontalPadding = subtitleHorizontalPadding
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            subtitleView

            accessory
        }
    }

    /// 描述行：subtitle / subtitleText / 都没传 三种情况。
    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, subtitleHorizontalPadding)
        } else if let subtitleText {
            Text(verbatim: subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, subtitleHorizontalPadding)
        }
    }
}

// MARK: - Preview

#Preview("AI Chat 空态（中文）") {
    EmptyStateView(
        systemImage: "bubble.left.and.bubble.right",
        title: "ai.assistant.chat.empty.title",
        subtitle: "ai.assistant.chat.empty.description",
        subtitleHorizontalPadding: 40
    )
    .frame(width: 480, height: 280)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("AI Chat 空态（英文）") {
    EmptyStateView(
        systemImage: "bubble.left.and.bubble.right",
        title: "ai.assistant.chat.empty.title",
        subtitle: "ai.assistant.chat.empty.description",
        subtitleHorizontalPadding: 40
    )
    .frame(width: 480, height: 280)
    .environment(\.locale, Locale(identifier: "en"))
}

#Preview("Detail 大占位") {
    EmptyStateView(
        systemImage: "doc.text.magnifyingglass",
        title: "empty.noSelection",
        subtitle: "empty.selectFromList",
        iconSize: 56,
        spacing: 12
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(width: 640, height: 400)
}

#Preview("带重试按钮") {
    EmptyStateView(
        systemImage: "exclamationmark.triangle",
        title: "weekly.detail.emptyTitle",
        subtitle: "weekly.detail.emptySubtitle",
        spacing: 12
    ) {
        Button("weekly.action.retry") {}
            .controlSize(.small)
    }
    .frame(width: 480, height: 320)
}
