//
//  CommonActionIconButtons.swift
//  Starcat
//
//  常用 icon-only 操作按钮的共享入口。
//
//  设计约束：
//  - 只承接全 App 重复出现的轻量工具按钮，避免每个页面手写字号 / 命中区 / focus ring。
//  - 删除入口默认不使用红色；危险色留给确认弹窗中的最终 destructive 按钮。
//  - 重置入口使用同一个 `arrow.counterclockwise.circle` 语义，调用方按所在 surface 传入尺寸。
//  - 点击成功后短暂显示绿色 `checkmark.circle.fill`（与 CopyFeedbackButton 同窗口）。
//

import SwiftUI

/// icon-only 删除 / 清空入口。
struct DestructiveIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SyncIconButton.defaultFont
    var frameSize: CGFloat = SyncIconButton.defaultFrameSize

    init(
        help: Text,
        font: Font = SyncIconButton.defaultFont,
        frameSize: CGFloat = SyncIconButton.defaultFrameSize,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(font)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// icon-only 重置 / 恢复默认入口。
///
/// 点击后与 `CopyFeedbackButton` 对齐：1.5s 内切为绿色 `checkmark.circle.fill`，
/// 连点取消旧复位任务并重新计时；开启「减少动态效果」时跳过状态与 Symbol 动画。
///
/// 静止态用 `arrow.counterclockwise.circle`（圆形同源），避免与 `checkmark.circle.fill`
/// 做 `.symbolEffect(.replace)` 时几何差太大、回切时卡在成功态不还原（RAG 设置页曾踩）。
struct ResetIconButton: View {
    let help: Text
    let action: () -> Void
    /// 设置页 icon-only 统一采用 15pt glyph + 28pt 命中区；不要再继承旧刷新按钮的 18pt 紧凑尺寸。
    var font: Font = .system(size: 15, weight: .medium)
    var frameSize: CGFloat = 28

    @State private var didReset = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @Environment(\.starcatReduceMotion) private var reduceMotion

    init(
        help: Text,
        font: Font = .system(size: 15, weight: .medium),
        frameSize: CGFloat = 28,
        action: @escaping () -> Void
    ) {
        self.help = help
        self.action = action
        self.font = font
        self.frameSize = frameSize
    }

    var body: some View {
        Button(action: performReset) {
            Image(systemName: didReset ? "checkmark.circle.fill" : "arrow.counterclockwise.circle")
                .font(font)
                .foregroundStyle(didReset ? Color.green : .secondary)
                .frame(width: frameSize, height: frameSize)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(help)
        .accessibilityLabel(help)
        .onDisappear {
            // Sheet / 分组重建时收掉未完成复位，避免悬挂 Task 写已释放 @State。
            feedbackResetTask?.cancel()
            feedbackResetTask = nil
        }
    }

    /// 先执行业务重置；等父级状态落定后再进成功反馈，避免同帧重建打断 Symbol 回切。
    private func performReset() {
        action()
        feedbackResetTask?.cancel()
        feedbackResetTask = Task { @MainActor in
            // 让 `apply` / `restoreCurrentTab` 触发的父级刷新先跑完。
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                didReset = true
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                didReset = false
            }
        }
    }
}
