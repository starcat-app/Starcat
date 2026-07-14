//
//  CommonActionIconButtons.swift
//  Starcat
//
//  常用 icon-only 操作按钮的共享入口。
//
//  设计约束：
//  - 只承接全 App 重复出现的轻量工具按钮，避免每个页面手写字号 / 命中区 / focus ring。
//  - 删除入口默认不使用红色；危险色留给确认弹窗中的最终 destructive 按钮。
//  - 重置入口使用同一个 `arrow.counterclockwise` 语义，调用方按所在 surface 传入尺寸。
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
struct ResetIconButton: View {
    let help: Text
    let action: () -> Void
    var font: Font = SyncIconButton.defaultFont
    var frameSize: CGFloat = SyncIconButton.defaultFrameSize

    @State private var didReset = false
    @State private var feedbackResetTask: Task<Void, Never>?
    @Environment(\.starcatReduceMotion) private var reduceMotion

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
        Button(action: performReset) {
            Image(systemName: didReset ? "checkmark.circle.fill" : "arrow.counterclockwise")
                .font(font)
                .foregroundStyle(didReset ? Color.green : .secondary)
                .frame(width: frameSize, height: frameSize)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(help)
    }

    /// 先执行业务重置，再进入短暂成功反馈；连点时取消未完成的旧复位。
    private func performReset() {
        action()
        feedbackResetTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            didReset = true
        }
        feedbackResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                didReset = false
            }
        }
    }
}
