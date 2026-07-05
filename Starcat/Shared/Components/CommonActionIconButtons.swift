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
struct ResetIconButton: View {
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
            Image(systemName: "arrow.counterclockwise")
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
