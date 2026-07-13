//
//  RAGComposerTextEditor.swift
//  Starcat
//
//  RAG Composer 的 AppKit 文本编辑器桥接。
//

import AppKit
import SwiftUI

/// RAG 输入框的 AppKit 桥接层。
///
/// SwiftUI `TextEditor` 会在弹性 VStack 中被扩展到远超 `maxHeight`，且 overlay
/// placeholder 无法与 NSTextView 的 insertion point 共享基线。本组件让 placeholder
/// 直接由同一个 NSTextView 绘制，并把内容实际高度回传给工作台，保证首帧两行且仍可
/// 在长问题时增长到调用方规定的上限。
struct RAGComposerTextEditor: NSViewRepresentable {
    static let verticalInset: CGFloat = 4

    enum Command {
        case returnKey(NSEvent.ModifierFlags)
        case upArrow
        case downArrow
        case escape
    }

    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let maximumHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    /// `@` 字形相对 NSScrollView 左上角的锚点（弹层挂这里，避免整框居中）。
    let onMentionAnchorChange: (CGPoint) -> Void
    let onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = RAGComposerTextView()

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
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
        guard let textView = scrollView.documentView as? RAGComposerTextView else { return }

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
        var parent: RAGComposerTextEditor

        init(parent: RAGComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RAGComposerTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight(for: textView)
            reportMentionAnchor(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // 去掉 capsLock 等噪声位，否则 .command 判断偶发失败。
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
                ceil(usedHeight + RAGComposerTextEditor.verticalInset * 2),
                parent.maximumHeight
            )
            parent.onHeightChange(height)
        }

        /// 把最后一个未完成 `@token` 的字形矩形换算到 scrollView 坐标，供 SwiftUI 弹层锚定。
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
            // AppKit Y 从底向上；SwiftUI topLeading offset 从顶向下，需要翻转。
            // 锚在 `@` 字形下缘，arrowEdge=.top 时弹层出现在光标正下方。
            let swiftY = scrollView.bounds.height - local.minY
            parent.onMentionAnchorChange(CGPoint(x: local.minX, y: swiftY))
        }
    }
}

/// placeholder 在 NSTextView 自身坐标系中绘制，基线与光标完全一致。
final class RAGComposerTextView: NSTextView {
    var placeholder = ""
    /// 键盘命令回调（Cmd+Enter 发送等）；由 Representable 注入。
    var onCommand: ((RAGComposerTextEditor.Command) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 36 = Return，76 = 小键盘 Enter。
        // Cmd+Enter 通常不会走 insertNewline:，必须在 keyDown 拦下再交给 onCommand
        // （是否真正发送由设置里的 aiChatRequiresCommandReturn 决定）。
        if (event.keyCode == 36 || event.keyCode == 76), flags.contains(.command) {
            if onCommand?(.returnKey(flags)) == true {
                return
            }
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
