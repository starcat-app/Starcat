//
//  RAGStreamingPlainTextView.swift
//  Starcat
//
//  RAG 运行中思考的 AppKit 追加渲染。
//
//  SwiftUI `Text` 每次都对整段字符串做 CoreText 重排，思考越长越卡。这里把完整
//  文本留在 session，只把 delta 追加进 `NSTextStorage`；视口高度固定，避免外层
//  对话 ScrollView 跟着每个 token 重新测高。
//

import AppKit
import SwiftUI

/// 运行中思考视口：约 12 行，高度由当前字号算出，不随文本增长。
enum RAGStreamingPlainTextMetrics {
    static let visibleLineCount = 12
    /// 距底部小于该距离时继续贴底；用户上翻阅读时不再强行跳回。
    static let pinToBottomThreshold: CGFloat = 36
    /// AppKit 侧合流上限约 30fps，避免每个 token 都触发布局。
    static let flushIntervalNanoseconds: UInt64 = 33_000_000

    static func viewportHeight(for font: NSFont) -> CGFloat {
        let lineHeight = ceil(max(font.boundingRectForFont.height, font.pointSize * 1.2))
        return lineHeight * CGFloat(visibleLineCount)
    }

    static func reasoningFont(scale: InterfaceScale) -> NSFont {
        NSFont.systemFont(
            ofSize: scale.scaled(StarcatTypography.body.pointSize),
            weight: .regular
        )
    }

    /// 与完成后 SwiftUI `Text` 的 `.foregroundStyle(.secondary)` 对齐。
    /// `replaceCharacters(with: String)` 默认走 labelColor，必须每次写入都带上颜色。
    static func textAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }
}

/// 一轮思考的文本真源。完整字符串立即累计，供落库；`NSTextView` 只消费待追加片段。
///
/// 不能标 `@Observable`：否则 `append` 会把高频字符串重新送进 SwiftUI 属性图，
/// 又回到整段 `Text` 替换的老路径。
@MainActor
final class RAGStreamingPlainTextSession {
    private(set) var text = ""
    private var pending = ""
    private var flushTask: Task<Void, Never>?
    private weak var textView: NSTextView?

    /// 立即并入完整文本；真正写入 `NSTextStorage` 由合流任务完成。
    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text.append(contentsOf: delta)
        pending.append(contentsOf: delta)
        scheduleFlush()
    }

    /// 落库或步骤结束前把尚未绘制的片段刷进当前 `NSTextView`。
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        applyPendingToTextView()
    }

    /// `NSViewRepresentable` 挂接或复用 view 时调用。新 view 必须用完整 `text` 恢复，
    /// 不能只靠 pending：折叠、切会话都会拆掉旧 view。
    func attach(_ textView: NSTextView) {
        if self.textView === textView {
            return
        }
        detachCurrentView()
        self.textView = textView
        pending = ""
        replaceStorage(with: text, in: textView)
        scrollToEnd(in: textView, force: true)
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        flushNow()
        self.textView = nil
    }

    private func detachCurrentView() {
        textView = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: RAGStreamingPlainTextMetrics.flushIntervalNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.applyPendingToTextView()
            self.flushTask = nil
        }
    }

    private func applyPendingToTextView() {
        guard let textView, !pending.isEmpty else {
            pending = ""
            return
        }
        let chunk = pending
        pending = ""
        appendToStorage(chunk, in: textView)
    }

    private func replaceStorage(with string: String, in textView: NSTextView) {
        let storage = textView.textStorage ?? NSTextStorage()
        let attributed = NSAttributedString(
            string: string,
            attributes: reasoningAttributes(for: textView)
        )
        storage.beginEditing()
        storage.setAttributedString(attributed)
        storage.endEditing()
    }

    private func appendToStorage(_ chunk: String, in textView: NSTextView) {
        let storage = textView.textStorage ?? NSTextStorage()
        let wasPinned = isPinnedToBottom(textView)
        let attributed = NSAttributedString(
            string: chunk,
            attributes: reasoningAttributes(for: textView)
        )
        storage.beginEditing()
        storage.append(attributed)
        storage.endEditing()
        if wasPinned {
            // 追加后内容变高，原先贴底的视口会暂时离开底部；必须强制滚回。
            scrollToEnd(in: textView, force: true)
        }
    }

    private func reasoningAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
        RAGStreamingPlainTextMetrics.textAttributes(
            font: textView.font ?? RAGStreamingPlainTextMetrics.reasoningFont(scale: .standard)
        )
    }

    private func isPinnedToBottom(_ textView: NSTextView) -> Bool {
        guard let scrollView = textView.enclosingScrollView else { return true }
        let visible = scrollView.contentView.bounds
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        return documentHeight - visible.maxY <= RAGStreamingPlainTextMetrics.pinToBottomThreshold
    }

    private func scrollToEnd(in textView: NSTextView, force: Bool) {
        let length = textView.textStorage?.length ?? 0
        guard length > 0 else { return }
        if !force, !isPinnedToBottom(textView) { return }
        textView.scrollRangeToVisible(NSRange(location: max(0, length - 1), length: 1))
    }
}

/// 一对会话级思考 session。规划思考与回答思考不会同时增长，但仍按步骤拆开，
/// 避免切步骤时把旧文本残留到新 `NSTextView`。
@MainActor
struct RAGLiveReasoningSessions {
    let planning = RAGStreamingPlainTextSession()
    let answer = RAGStreamingPlainTextSession()

    func session(for kind: RAGExecutionStepKind) -> RAGStreamingPlainTextSession? {
        switch kind {
        case .planningReasoning:
            return planning
        case .answerReasoning:
            return answer
        default:
            return nil
        }
    }
}

/// 固定高度的只读思考视口。`updateNSView` 禁止把完整 `string` 赋回 TextKit，
/// 否则又会整段重排。
struct RAGStreamingPlainTextView: NSViewRepresentable {
    let session: RAGStreamingPlainTextSession
    let font: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        applyReasoningAppearance(to: textView, font: font)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.enabledTextCheckingTypes = 0

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay

        context.coordinator.session = session
        session.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.session !== session {
            context.coordinator.session.detach(textView)
            context.coordinator.session = session
            applyReasoningAppearance(to: textView, font: font)
            session.attach(textView)
        } else {
            applyReasoningAppearanceIfNeeded(to: textView, font: font)
        }
        let width = max(scrollView.contentSize.width, scrollView.bounds.width)
        if width > 0 {
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        coordinator.session.detach(textView)
    }

    /// 先设 font 会把 `textColor` 打回 labelColor，必须随后再设 secondary。
    private func applyReasoningAppearance(to textView: NSTextView, font: NSFont) {
        textView.font = font
        textView.textColor = .secondaryLabelColor
        textView.insertionPointColor = .clear
        textView.typingAttributes = RAGStreamingPlainTextMetrics.textAttributes(font: font)
    }

    /// 字号没变时不要重设 font，否则 AppKit 会把已有文本刷回主色。
    private func applyReasoningAppearanceIfNeeded(to textView: NSTextView, font: NSFont) {
        guard textView.font?.pointSize != font.pointSize else {
            textView.textColor = .secondaryLabelColor
            textView.typingAttributes = RAGStreamingPlainTextMetrics.textAttributes(font: font)
            return
        }
        applyReasoningAppearance(to: textView, font: font)
        let storage = textView.textStorage
        let length = storage?.length ?? 0
        if length > 0 {
            storage?.addAttributes(
                RAGStreamingPlainTextMetrics.textAttributes(font: font),
                range: NSRange(location: 0, length: length)
            )
        }
    }

    final class Coordinator {
        var session: RAGStreamingPlainTextSession

        init(session: RAGStreamingPlainTextSession) {
            self.session = session
        }
    }
}

/// SwiftUI 侧把字号档位转成固定高度视口，高度变化只来自界面缩放，不来自文本长度。
struct RAGStreamingReasoningViewport: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    let session: RAGStreamingPlainTextSession

    var body: some View {
        let font = RAGStreamingPlainTextMetrics.reasoningFont(scale: interfaceScale)
        RAGStreamingPlainTextView(session: session, font: font)
            .frame(height: RAGStreamingPlainTextMetrics.viewportHeight(for: font))
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(ObjectIdentifier(session))
    }
}
