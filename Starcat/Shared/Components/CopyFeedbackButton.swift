//
//  CopyFeedbackButton.swift
//  Starcat
//
//  通用「复制 + 点击反馈」按钮。
//
//  模块职责：
//  - 接管"复制到剪贴板 + UI 反馈态切换 + 1.5s 自动复位"三件套，让调用方只关心
//    内容来源（`providesContent`）和外观（label closure 拿到 didCopy 自己渲染）。
//  - 所有需要即时反馈的复制入口都必须复用本组件：调用方在 `label` 中以
//    `didCopy` 切换为绿色 `checkmark.circle.fill`，本组件负责 1.5s 反馈窗口、
//    动画与连续点击重新计时，避免每个页面各自维护一套易抖动的状态机。
//
//  关键约束：
//  - `providesContent` 是 closure 而非 `String`：调用方在 view init 时还没准备好
//    最终内容（流式中、对话中），closure 让"点击瞬间再求值"成为唯一靠谱姿势。
//  - 复位用 `Task.sleep` + cancel 旧任务：用户快速连点不会出现"刚切完又被旧
//    任务复位"的抖动；离开 view 时 @State 析构会一起带走 task ref，Task 自身
//    检测 isCancelled 后安全退出。
//  - 整体走 `.buttonStyle(.plain) + .focusEffectDisabled()`，遵守项目的「自定义
//    按钮必须显式禁用 focus ring」强制规则；外观完全由调用方的 label closure 决定。
//

import SwiftUI

/// 复制按钮的外观底座。
///
/// 默认 `.plain` 适合工具栏和文字操作；仅已有表单边框的入口可用 `.bordered`，避免
/// 为接入反馈组件而改变既有信息层级。
enum CopyFeedbackButtonStyle {
    case plain
    case bordered
}

/// 通用复制按钮，封装"复制 + 反馈"完整状态机。
///
/// 用法示例：
/// ```swift
/// CopyFeedbackButton(
///     tooltip: "复制摘要到剪贴板",
///     providesContent: { insight.summaryMarkdown ?? insight.summary }
/// ) { didCopy in
///     Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
///         .foregroundStyle(didCopy ? Color.green : Color.primary)
///         .contentTransition(.symbolEffect(.replace))
/// }
/// ```
///
/// label closure 拿到的 `Bool` 是当前是否处于"已复制"反馈态，调用方据此切换 icon
/// / 颜色 / 文案。`.contentTransition(.symbolEffect(.replace))` 让 SF Symbol 在
/// 两个名字之间做柔性切换，建议都加上。
struct CopyFeedbackButton<Label: View>: View {

    /// 实际剪贴板写入动作。返回 `false` 时不切换成功反馈，避免渲染失败却误报“已复制”。
    private let copyAction: () -> Bool

    /// 未复制态的 tooltip 文案；已复制态由本组件统一显示「已复制 ✓」。
    let tooltip: LocalizedStringKey

    /// 默认保持轻量工具按钮；已有表单边框的复制入口显式使用 `.bordered`。
    let style: CopyFeedbackButtonStyle

    /// 外观渲染。参数 `didCopy` 表示当前是否处于"已复制"反馈态（true = 复制完成
    /// 后 1.5s 内）。调用方必须用它切换为绿色 `checkmark.circle.fill`，以便所有
    /// 复制入口遵循同一成功反馈语义。
    @ViewBuilder let label: (Bool) -> Label

    @State private var didCopy: Bool = false

    /// 复位用的延迟任务句柄。
    ///
    /// 用 Task 而非 DispatchQueue.asyncAfter：
    /// 1. 用户连点时把旧任务 cancel 掉再起新的，比 dispatch 简洁；
    /// 2. 整个 view 是 SwiftUI / @MainActor，Task 完成回到 main 不需要额外 hop。
    @State private var resetTask: Task<Void, Never>?

    /// 2026-06-15:已复制反馈态切换 0.15s/0.2s 渐变在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 保留 `style` 在 label 之前的调用顺序，才能同时支持普通 trailing closure 和
    /// `style: .bordered` 的表单入口；依赖成员初始化器会丢失带默认值的 `let` 参数。
    init(
        providesContent: @escaping () -> String,
        tooltip: LocalizedStringKey,
        style: CopyFeedbackButtonStyle = .plain,
        @ViewBuilder label: @escaping (Bool) -> Label
    ) {
        self.copyAction = {
            let content = providesContent().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return false }

            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(content, forType: .string)
        }
        self.tooltip = tooltip
        self.style = style
        self.label = label
    }

    /// 图片等非文本内容也通过相同的成功反馈状态机复制到剪贴板。
    init(
        performCopy: @escaping () -> Bool,
        tooltip: LocalizedStringKey,
        style: CopyFeedbackButtonStyle = .plain,
        @ViewBuilder label: @escaping (Bool) -> Label
    ) {
        self.copyAction = performCopy
        self.tooltip = tooltip
        self.style = style
        self.label = label
    }

    var body: some View {
        switch style {
        case .plain:
            button
                .buttonStyle(.plain)
                .focusEffectDisabled()
        case .bordered:
            button
                .buttonStyle(.bordered)
                .focusEffectDisabled()
        }
    }

    /// 共用 Button 本体，保证两种视觉外观仍共享同一复制状态机和 tooltip 语义。
    private var button: some View {
        Button(action: performCopy) {
            label(didCopy)
                // 统一给 label 注入 Symbol 过渡；既避免各调用点遗漏动画，也会在用户
                // 开启“减少动态效果”时降级为无动画切换。
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .help(didCopy ? "common.copy.copied" : tooltip)
    }

    /// 实际执行复制 + 切反馈态 + 排复位。
    private func performCopy() {
        guard copyAction() else { return }

        resetTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            didCopy = true
        }
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                didCopy = false
            }
        }
    }
}
