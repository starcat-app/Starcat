//
//  ImagePasteTextEditor.swift
//  Starcat
//
//  NSTextView 撰写编辑器：测高自动伸缩 + placeholder + Esc 回传 + 剪贴板图片拦截回调。
//
//  来源（2026-11-01）：原为 GitHubNotificationDetailView 的私有类型
//  （GitHubNotificationCommentTextEditor / GitHubNotificationCommentScrollView /
//  GitHubNotificationCommentNSTextView），通知评论框与 Issues 工作台（评论框、
//  新建描述）共用同一套撰写体验，按铁律抽成单一来源，纯代码搬移不改行为。
//
//  关键约束：
//  - 必须走 NSTextView：SwiftUI `TextEditor` + overlay `Text` 的 placeholder 和
//    insertion point 不在同一坐标系。测高对齐 RAG `AICommandTextEditor`：
//    usedRect + inset，由外层钳制下限 / 上限，超出后内部滚动。
//  - `onPasteImage` 剪贴板有图时拦截 Cmd+V，先插入占位再异步上传；回调为 nil 时
//    回落系统默认粘贴（importsGraphics 已关，图片不会嵌入）。
//  - 撰写态 first responder 在 NSTextView，Esc 不会回到 SwiftUI，由 textView
//    doCommandBy 回传是否已处理。
//

import AppKit
import SwiftUI

struct ImagePasteTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEditable: Bool = true
    let maximumHeight: CGFloat
    var shouldBecomeFirstResponder: Bool = false
    let onHeightChange: (CGFloat) -> Void
    var onEditingChange: ((Bool) -> Void)? = nil
    /// 撰写态 first responder 在 NSTextView，Esc 不会回到 SwiftUI，这里回传是否已处理。
    var onEscape: (() -> Bool)? = nil
    /// 剪贴板有图时拦截 Cmd+V，先插入占位再异步上传。
    var onPasteImage: ((GitHubClipboardImage.Payload, String) -> Void)? = nil
    var onPasteImageError: ((GitHubUserAttachmentError) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ImagePasteMeasuringScrollView()
        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = ImagePasteTextView.contentInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.onPasteImage = context.coordinator.parent.onPasteImage
        textView.onPasteImageError = context.coordinator.parent.onPasteImageError

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.onMeasuredHeight = { [coordinator = context.coordinator] height in
            coordinator.parent.onHeightChange(height)
        }
        scrollView.maximumHeight = maximumHeight
        // 等容器拿到宽度后再测 usedRect，避免首帧按单行高度跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ImagePasteTextView else { return }
        if let measuringScroll = scrollView as? ImagePasteMeasuringScrollView {
            measuringScroll.onMeasuredHeight = { [coordinator = context.coordinator] height in
                coordinator.parent.onHeightChange(height)
            }
            measuringScroll.maximumHeight = maximumHeight
        }
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.onPasteImage = context.coordinator.parent.onPasteImage
        textView.onPasteImageError = context.coordinator.parent.onPasteImageError
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            // 手打字走 textDidChange，glyph 已经按当前宽度折行。
            // AI 流式写 draft 只进这里，立刻测高会把整段当成一行，框就停在 3 行。
            scrollView.layoutSubtreeIfNeeded()
            context.coordinator.reportHeight(for: textView)
            DispatchQueue.main.async {
                context.coordinator.reportHeight(for: textView)
            }
        }
        if shouldBecomeFirstResponder {
            context.coordinator.focusIfNeeded(textView, in: scrollView)
        } else {
            context.coordinator.didRequestFocus = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ImagePasteTextEditor
        var didRequestFocus = false

        init(parent: ImagePasteTextEditor) {
            self.parent = parent
        }

        func focusIfNeeded(_ textView: NSTextView, in scrollView: NSScrollView) {
            guard !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async {
                scrollView.window?.makeFirstResponder(textView)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onEditingChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEditingChange?(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ImagePasteTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            // 输入法候选未上屏时 Esc 应只取消拼音，不能收评论框。
            if textView.hasMarkedText() { return false }
            return parent.onEscape?() ?? false
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            if let scrollView = textView.enclosingScrollView {
                let width = scrollView.contentSize.width
                if width <= 1 { return }
                if abs(textView.frame.width - width) >= 0.5 {
                    textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, 1)))
                }
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let height = min(
                ceil(usedHeight + ImagePasteTextView.contentInset.height * 2),
                parent.maximumHeight
            )
            parent.onHeightChange(height)
        }
    }
}

final class ImagePasteMeasuringScrollView: NSScrollView {
    /// SwiftUI 侧的高度上限，layout 里测高后回传，让 AI 写入也能把外框撑开。
    var maximumHeight: CGFloat = 0
    var onMeasuredHeight: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0

    /// 空白处也能点进输入：textView 至少铺满当前 SwiftUI 框；内容更高时再长高，交给滚动。
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        let minHeight = contentSize.height
        var used = minHeight
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            used = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
        }
        let height = max(minHeight, used)
        textView.minSize = NSSize(width: 0, height: minHeight)
        if abs(textView.frame.width - width) >= 0.5 || abs(textView.frame.height - height) >= 0.5 {
            textView.setFrameSize(NSSize(width: width, height: height))
        }
        let reported = maximumHeight > 0 ? min(used, maximumHeight) : used
        guard abs(reported - lastReportedHeight) >= 0.5 else { return }
        lastReportedHeight = reported
        onMeasuredHeight?(reported)
    }
}

final class ImagePasteTextView: NSTextView {
    static let contentInset = NSSize(width: 8, height: 8)
    var placeholder = ""
    var onPasteImage: ((GitHubClipboardImage.Payload, String) -> Void)?
    var onPasteImageError: ((GitHubUserAttachmentError) -> Void)?

    /// 有图就走 GitHub 附件上传；不要让 NSTextView 把图嵌成附件（importsGraphics 已关）。
    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        // 只认 PNG / TIFF 字节。网页复制常同时带文字和预览图，不能靠 NSImage(pasteboard:) 抢粘贴。
        let hasImage = pasteboard.data(forType: .png) != nil
            || pasteboard.data(forType: .tiff) != nil
        guard hasImage else {
            super.paste(sender)
            return
        }
        guard let payload = GitHubClipboardImage.payload(from: pasteboard) else {
            onPasteImageError?(.imageTooLarge)
            return
        }
        guard let onPasteImage else {
            super.paste(sender)
            return
        }
        let placeholder = GitHubUserAttachment.uploadingPlaceholder(
            fileName: payload.fileName,
            token: UUID().uuidString
        )
        let inserted = GitHubUserAttachment.insertBlock(
            placeholder,
            into: string,
            selectedUTF16: selectedRange()
        )
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        if shouldChangeText(in: fullRange, replacementString: inserted.text) {
            string = inserted.text
            setSelectedRange(inserted.selectedUTF16)
            didChangeText()
        }
        onPasteImage(payload, placeholder)
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
