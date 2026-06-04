//
//  CopyFeedbackButton.swift
//  Starcat
//
//  通用「复制 + 点击反馈」按钮（HOM-150）。
//
//  模块职责：
//  - 接管"复制到剪贴板 + UI 反馈态切换 + 1.5s 自动复位"三件套，让调用方只关心
//    内容来源（`providesContent`）和外观（label closure 拿到 didCopy 自己渲染）。
//  - 三个调用点（摘要 header 复制、AI 气泡时间戳右侧复制、对话底部"复制全部"）
//    都通过这个组件统一行为：icon 切 `checkmark.circle.fill` + 绿色 + tooltip
//    切「已复制 ✓」，1.5s 后柔性回退。
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

    /// 点击时再求值的内容生成 closure。
    ///
    /// 之所以是 closure 而不是 `String`：
    /// 1. 流式状态下消息内容一直在变，传 String 会在 view init 时被锁死；
    /// 2. 对话级"复制全部"需要拼一段几 KB 的 Markdown，避免每次 view 重绘都拼一遍；
    /// 3. closure 让"按下瞬间才计算"成为统一姿势。
    let providesContent: () -> String

    /// 未复制态的 tooltip 文案；已复制态由本组件统一显示「已复制 ✓」。
    let tooltip: LocalizedStringKey

    /// 外观渲染。参数 `didCopy` 表示当前是否处于"已复制"反馈态（true = 复制完成
    /// 后 1.5s 内）。closure 拿到后自行决定 icon / 颜色 / 文字。
    @ViewBuilder let label: (Bool) -> Label

    @State private var didCopy: Bool = false

    /// 复位用的延迟任务句柄。
    ///
    /// 用 Task 而非 DispatchQueue.asyncAfter：
    /// 1. 用户连点时把旧任务 cancel 掉再起新的，比 dispatch 简洁；
    /// 2. 整个 view 是 SwiftUI / @MainActor，Task 完成回到 main 不需要额外 hop。
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: performCopy) {
            label(didCopy)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(didCopy ? "已复制 ✓" : tooltip)
    }

    /// 实际执行复制 + 切反馈态 + 排复位。
    private func performCopy() {
        let content = providesContent().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)

        resetTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            didCopy = true
        }
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                didCopy = false
            }
        }
    }
}
