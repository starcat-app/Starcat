//
//  AICommandTextEditor.swift
//  Starcat
//
//  RAG 与 Agent 工作台共享的 AppKit 多行命令输入内核。
//

import AppKit
import SwiftUI

/// AI 工作台统一使用的 AppKit 文本编辑器桥接层。
///
/// SwiftUI `TextEditor` 在弹性 VStack 中会忽略稳定的高度上限，placeholder 也难以与
/// insertion point 共享基线。这里由 NSTextView 同时负责绘制、测高和键盘命令，再由
/// RAG / Agent 各自决定“发送、换行、@ 候选导航”的产品语义。
struct AICommandTextEditor: NSViewRepresentable {
    static let verticalInset: CGFloat = 4

    enum Command {
        case mentionTrigger
        case returnKey(NSEvent.ModifierFlags)
        case upArrow
        case downArrow
        case escape
    }

    /// 业务层可把 `@` 接管为 Composer 命令；输入法存在 marked text 时必须交还给文本系统处理。
    static func shouldRouteMentionTrigger(characters: String?, hasMarkedText: Bool) -> Bool {
        !hasMarkedText && characters == "@"
    }

    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let maximumHeight: CGFloat
    var isEditable: Bool = true
    let onHeightChange: (CGFloat) -> Void
    /// `@` 字形相对 NSScrollView 左上角的锚点，供业务层把候选面板挂到光标附近。
    let onMentionAnchorChange: (CGPoint) -> Void
    let onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = AICommandTextView()

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.isEditable = isEditable
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        // Cmd+Enter 多数情况下不会进 insertNewline:，必须在 keyDown 拦截。
        textView.onCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onCommand(command) ?? false
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 首次布局后再计算 usedRect，避免 NSTextLayoutManager 尚未拿到容器宽度时
        // 错报单行高度，导致窗口打开的一帧内输入框跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
            context.coordinator.reportMentionAnchor(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? AICommandTextView else { return }

        textView.font = font
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.onCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onCommand(command) ?? false
        }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.reportHeight(for: textView)
        }
        context.coordinator.reportMentionAnchor(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AICommandTextEditor

        init(parent: AICommandTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? AICommandTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight(for: textView)
            reportMentionAnchor(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let modifiers = (NSApp.currentEvent?.modifierFlags ?? [])
                    .intersection(.deviceIndependentFlagsMask)
                return parent.onCommand(.returnKey(modifiers))
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.upArrow)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.downArrow)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.escape)
            default:
                return false
            }
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let height = min(
                ceil(usedHeight + AICommandTextEditor.verticalInset * 2),
                parent.maximumHeight
            )
            parent.onHeightChange(height)
        }

        /// 把最后一个未完成 `@token` 的字形矩形换算到 scrollView 坐标。
        func reportMentionAnchor(for textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView,
                  let at = textView.string.lastIndex(of: "@") else { return }
            let after = textView.string.index(after: at)
            let suffix = textView.string[after...]
            guard !suffix.contains(where: \.isWhitespace) else { return }

            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }

            let location = textView.string.utf16.distance(from: textView.string.startIndex, to: at)
            var actualRange = NSRange(location: 0, length: 0)
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: location, length: 1),
                actualRange: &actualRange
            )
            guard let window = textView.window, screenRect != .zero else { return }
            let windowRect = window.convertFromScreen(screenRect)
            let local = scrollView.convert(windowRect, from: nil)
            // AppKit Y 从底向上，SwiftUI topLeading offset 从顶向下，需要翻转。
            let swiftY = scrollView.bounds.height - local.minY
            parent.onMentionAnchorChange(CGPoint(x: local.minX, y: swiftY))
        }
    }
}

/// placeholder 在 NSTextView 自身坐标系中绘制，保证基线与光标一致。
private final class AICommandTextView: NSTextView {
    var placeholder = ""
    var onCommand: ((AICommandTextEditor.Command) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if AICommandTextEditor.shouldRouteMentionTrigger(
            characters: event.characters,
            hasMarkedText: hasMarkedText()
        ), onCommand?(.mentionTrigger) == true {
            // 业务层接管后不调用 super，确保 `@` 从未写入 NSTextView。
            return
        }
        // 36 = Return，76 = 小键盘 Enter。Cmd+Enter 通常不会走 insertNewline:。
        if (event.keyCode == 36 || event.keyCode == 76), flags.contains(.command),
           onCommand?(.returnKey(flags)) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}
