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
    let defaultShortcut: KeyboardShortcutConfiguration
    let onValidationError: (KeyboardShortcutConfiguration.ValidationError) -> Void
    let onRestoreDefault: () -> Void
    var conflictingShortcuts: Set<KeyboardShortcutConfiguration> = []
    var helpKey: LocalizedStringKey = "settings.general.shortcuts.search.help"

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 0) {
            // 符号串决定自然宽度；不把背景或无固有尺寸的 NSView 放进布局主树，避免重新撑满整行。
            // 按键符号是技术字面量，必须使用 verbatim；录制提示则单独走本地化重载。
            Text(verbatim: shortcut.displaySegments.joined(separator: " "))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .opacity(isRecording ? 0 : 1)
                .accessibilityHidden(isRecording)
                .overlay {
                    // 保留当前键位的占位尺寸，长译文只在录制区域截断，不让录制状态改变按钮宽度。
                    if isRecording {
                        Text("settings.general.shortcuts.recording")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .help(Text("settings.general.shortcuts.recording"))
                    }
                }
                .overlay {
                    ShortcutCaptureView(
                        isRecording: $isRecording,
                        onCapture: capture
                    )
                }

            if shortcut != defaultShortcut {
                // 恢复入口仍只在键位改过后出现；独占命中区，避免覆盖短组合或触发底下的录制层。
                Button(action: onRestoreDefault) {
                    Image(systemName: "xmark.circle.fill")
                        .font(SettingsIconMetrics.standardGlyph)
                        .foregroundStyle(.secondary)
                        .frame(
                            width: SettingsIconMetrics.actionFrameSize,
                            height: SettingsIconMetrics.actionFrameSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("settings.general.shortcuts.restoreDefault"))
                .accessibilityLabel(Text("settings.general.shortcuts.restoreDefault"))
                .padding(.trailing, 2)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                .allowsHitTesting(false)
        }
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
/// 即使当前关闭，键位仍参与六项命令的冲突检查，保证重新启用时不会抢占。
struct ConfigurableShortcutSettingRow: View {
    let titleKey: LocalizedStringKey
    @Binding var shortcut: KeyboardShortcutConfiguration
    let defaultShortcut: KeyboardShortcutConfiguration
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
                    defaultShortcut: defaultShortcut,
                    onValidationError: onValidationError,
                    onRestoreDefault: onRestoreDefault,
                    conflictingShortcuts: conflictingShortcuts,
                    helpKey: helpKey
                )
                .onChange(of: shortcut) { _, _ in
                    onShortcutChanged()
                }

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
