//
//  ShortcutRecorderView.swift
//  Starcat
//
//  macOS 设置页快捷键录制控件。点击后让底层 NSView 成为 first responder，下一次
//  keyDown 直接转成 KeyboardShortcutConfiguration；Esc 取消，不修改原值。
//

import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var shortcut: KeyboardShortcutConfiguration
    let onValidationError: (KeyboardShortcutConfiguration.ValidationError) -> Void

    @State private var isRecording = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)

            Text(isRecording ? "settings.general.shortcuts.recording" : shortcut.displayText)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(isRecording ? Color.accentColor : .primary)

            ShortcutCaptureView(
                isRecording: $isRecording,
                onCapture: capture
            )
        }
        .frame(width: 112, height: 28)
        .help("settings.general.shortcuts.search.help")
    }

    private func capture(_ candidate: KeyboardShortcutConfiguration) {
        if let error = candidate.validationError {
            onValidationError(error)
            return
        }
        shortcut = candidate
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
