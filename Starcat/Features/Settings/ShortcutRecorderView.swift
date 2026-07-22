//
//  ShortcutRecorderView.swift
//  Starcat
//
//  macOS 设置页快捷键控件：录制组合键，并为每个应用命令提供独立启停和恢复默认。
//  录制控件点击后让底层 NSView 成为 first responder，下一次 keyDown 直接转成
//  KeyboardShortcutConfiguration；Esc 取消，不修改原值。
//

import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var shortcut: KeyboardShortcutConfiguration
    let onValidationError: (KeyboardShortcutConfiguration.ValidationError) -> Void
    var conflictingShortcuts: Set<KeyboardShortcutConfiguration> = []
    var helpKey: LocalizedStringKey = "settings.general.shortcuts.search.help"

    @State private var isRecording = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)

            // i18n 注意（2026-06-16 dong4j 反馈"显示的是 key 名而不是翻译"修复）：
            // 原写法 `Text(isRecording ? "key" : shortcut.displayText)` 让 Swift 类型推断把
            // 字面量降级为 `String`（因为 displayText 是 String），整个表达式命中 SwiftUI
            // `Text(_ content: some StringProtocol)` 重载——这个重载**完全不查 xcstrings**，
            // 屏幕上直接渲染裸 key "settings.general.shortcuts.recording"。
            // 改用 if/else 分支让两个 Text 各自命中对应重载：
            // - isRecording 分支：单独的字面量 → `Text(_ key: LocalizedStringKey)` 正常本地化
            // - 非 isRecording 分支：`Text(verbatim:)` 显式声明"这是字面符号串（⌘K 等），
            //   不要尝试查表"，避免未来 displayText 偶然匹配上 xcstrings 的 key 被误本地化
            Group {
                if isRecording {
                    Text("settings.general.shortcuts.recording")
                } else {
                    Text(verbatim: shortcut.displayText)
                }
            }
            .font(.system(.body, design: .monospaced).weight(.medium))
            .foregroundStyle(isRecording ? Color.accentColor : .primary)

            ShortcutCaptureView(
                isRecording: $isRecording,
                onCapture: capture
            )
        }
        // 设置页右侧行内控件：按原 112pt 缩小约 1/3，给恢复图标留出横向空间。
        .frame(width: 76, height: 28)
        .help(helpKey)
    }

    private func capture(_ candidate: KeyboardShortcutConfiguration) {
        if let error = candidate.validationError(conflictingWith: conflictingShortcuts) {
            onValidationError(error)
            return
        }
        shortcut = candidate
    }
}

/// 设置页中的单个可配置应用快捷键行。
///
/// 开关只控制键盘注册，不会清空已经录制的组合，也不会禁用对应菜单或按钮。
/// 即使当前关闭，键位仍参与五项命令的冲突检查，保证重新启用时不会抢占。
struct ConfigurableShortcutSettingRow: View {
    let titleKey: LocalizedStringKey
    @Binding var shortcut: KeyboardShortcutConfiguration
    @Binding var isEnabled: Bool
    let onValidationError: (KeyboardShortcutConfiguration.ValidationError) -> Void
    let conflictingShortcuts: Set<KeyboardShortcutConfiguration>
    let helpKey: LocalizedStringKey
    let onShortcutChanged: () -> Void
    let onRestoreDefault: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(titleKey)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 8) {
                ShortcutRecorderView(
                    shortcut: $shortcut,
                    onValidationError: onValidationError,
                    conflictingShortcuts: conflictingShortcuts,
                    helpKey: helpKey
                )
                .onChange(of: shortcut) { _, _ in
                    onShortcutChanged()
                }

                ResetIconButton(
                    help: Text("settings.general.shortcuts.restoreDefault"),
                    action: onRestoreDefault
                )

                // 与 Section 中的总开关保持同一紧凑尺寸，并放在末尾对齐设置卡片右缘。
                Toggle(isOn: $isEnabled) {
                    Text(titleKey)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("settings.general.shortcuts.itemEnabled.help")
            }
        }
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (KeyboardShortcutConfiguration) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onRecordingChange = { isRecording = $0 }
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onRecordingChange = { isRecording = $0 }
        view.onCapture = onCapture
    }

    @MainActor
    final class CaptureView: NSView {
        var onRecordingChange: ((Bool) -> Void)?
        var onCapture: ((KeyboardShortcutConfiguration) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onRecordingChange?(true)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                window?.makeFirstResponder(nil)
                return
            }
            guard let shortcut = KeyboardShortcutConfiguration.make(from: event) else {
                NSSound.beep()
                return
            }
            onCapture?(shortcut)
            window?.makeFirstResponder(nil)
        }

        override func resignFirstResponder() -> Bool {
            onRecordingChange?(false)
            return super.resignFirstResponder()
        }
    }
}
