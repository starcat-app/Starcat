//
//  SingleLineTextField.swift
//  Starcat
//
//  macOS 设置页专用单行文本框（AppKit NSTextField 桥接）。
//
//  为什么不用 SwiftUI 原生 TextField / SecureField：
//  - Form(.grouped) 会把原生 TextField 的内容长度纳入布局协商，超长 URL / API Key
//    会把行顶成多行换行，或让相邻行输入框宽度不一致。
//  - NSTextField 可强制 `usesSingleLineMode` + `cell.isScrollable`，超长文本在框内
//    横向滚动，外层 SwiftUI 用绝对 `frame(width:)` 锁死视觉宽度。
//
//  首版用于 AI 提供商 Base URL（见 AISettingsView）；服务 Tab URL / API Key 复用同一组件。
//

import SwiftUI
import AppKit

struct SingleLineTextField: NSViewRepresentable {

    @Binding var text: String
    var isSecure: Bool = false
    /// 占位符；调用方传 `String.l10n(...)` 或固定英文。
    var prompt: String?
    var onSubmit: (() -> Void)?
    var usesPlainStyle = false
    var fontSize = NSFont.systemFontSize
    var fontWeight: NSFont.Weight = .regular
    var focus: Binding<Bool>?

    func makeNSView(context: Context) -> NSTextField {
        let textField: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = !usesPlainStyle
        textField.isBezeled = !usesPlainStyle
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = !usesPlainStyle
        textField.focusRingType = usesPlainStyle ? .none : .default
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byClipping
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        textField.controlSize = .regular
        textField.stringValue = text
        textField.placeholderString = prompt
        // 允许 SwiftUI 外层 frame(width:) 压窄字段，内容在 cell 内滚动而非撑开布局。
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.focus = focus
        if textField.stringValue != text {
            textField.stringValue = text
        }
        if textField.placeholderString != prompt {
            textField.placeholderString = prompt
        }
        let shouldFocus = focus?.wrappedValue == true
        if shouldFocus, textField.window?.firstResponder !== textField.currentEditor() {
            DispatchQueue.main.async { textField.window?.makeFirstResponder(textField) }
        } else if !shouldFocus, textField.window?.firstResponder === textField.currentEditor() {
            textField.window?.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var onSubmit: (() -> Void)?
        var focus: Binding<Bool>?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            focus?.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            focus?.wrappedValue = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // 中文输入法按 Return 时，`stringValue` 可能仍停在拼音草稿。先显式提交 marked text，
                // 再同步最终字符串并触发搜索，保证一次 Return 同时完成选词和提交。
                textView.unmarkText()
                text = textView.string
                if let textField = control as? NSTextField {
                    textField.stringValue = textView.string
                }
                onSubmit?()
                return true
            }
            return false
        }
    }
}
