//
//  RAGStreamingPlainTextSessionTests.swift
//  StarcatTests
//
//  运行中思考必须把完整字符串留在 session，不能依赖 SwiftUI Text 的整段替换。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@Suite("RAG streaming plain text session")
struct RAGStreamingPlainTextSessionTests {
    @Test("delta 立即进入完整文本，空片段忽略")
    @MainActor
    func appendAccumulatesFullTextWithoutView() {
        let session = RAGStreamingPlainTextSession()
        session.append("先")
        session.append("分析请求")
        session.append("")
        #expect(session.text == "先分析请求")
    }

    @Test("规划与回答思考分属两个 session")
    @MainActor
    func liveSessionsKeepPlanningAndAnswerSeparate() {
        let sessions = RAGLiveReasoningSessions()
        sessions.planning.append("规划")
        sessions.answer.append("回答")
        #expect(sessions.session(for: .planningReasoning)?.text == "规划")
        #expect(sessions.session(for: .answerReasoning)?.text == "回答")
        #expect(sessions.session(for: .planning) == nil)
    }

    @Test("思考视口高度随字号变化，但不随文本长度变化")
    func viewportHeightDependsOnFontNotText() {
        let compact = NSFont.systemFont(ofSize: 12)
        let comfortable = NSFont.systemFont(ofSize: 16)
        let compactHeight = RAGStreamingPlainTextMetrics.viewportHeight(for: compact)
        let comfortableHeight = RAGStreamingPlainTextMetrics.viewportHeight(for: comfortable)

        #expect(comfortableHeight > compactHeight)
        #expect(compactHeight >= CGFloat(RAGStreamingPlainTextMetrics.visibleLineCount) * compact.pointSize)
    }

    @Test("思考文本属性与完成后的 secondary 字色一致")
    func reasoningAttributesUseSecondaryLabelColor() {
        let font = NSFont.systemFont(ofSize: 13)
        let attrs = RAGStreamingPlainTextMetrics.textAttributes(font: font)
        #expect(attrs[.foregroundColor] as? NSColor == NSColor.secondaryLabelColor)
        #expect(attrs[.font] as? NSFont == font)
    }

    @Test("replaceAll 覆盖完整文本，供历史展开一次写入")
    @MainActor
    func replaceAllReplacesAccumulatedText() {
        let session = RAGStreamingPlainTextSession()
        session.append("旧内容")
        session.replaceAll(with: "完整思考")
        #expect(session.text == "完整思考")
        session.append("续")
        #expect(session.text == "完整思考续")
    }

    @Test("对话 Think 用 caption 字号，小于 RAG 时间线 body")
    func chatCaptionFontSmallerThanRAGBody() {
        let body = RAGStreamingPlainTextMetrics.reasoningFont(scale: .standard, typography: .body)
        let caption = RAGStreamingPlainTextMetrics.reasoningFont(scale: .standard, typography: .caption)
        #expect(caption.pointSize < body.pointSize)
        #expect(body.pointSize == 13)
        #expect(caption.pointSize == 12)
    }

    @Test("增量追加、收起和重新挂接不丢尾段，并保持思考文本的辅助字色")
    @MainActor
    func textSurvivesAppendAndReattachment() throws {
        let session = RAGStreamingPlainTextSession()
        let font = NSFont.systemFont(ofSize: 14)
        let oldScrollView = RAGStreamingPlainTextView.makeUnadornedScrollView(font: font)
        let oldView = try #require(oldScrollView.documentView as? NSTextView)
        session.attach(oldView, pinsToBottom: false)
        session.append("开头🪐")
        session.flushNow()
        session.append("尚未合流的尾段")
        session.detach(oldView)
        #expect(oldView.string == "开头🪐尚未合流的尾段")

        session.append("后台继续")
        session.flushNow()
        let newScrollView = RAGStreamingPlainTextView.makeUnadornedScrollView(font: font)
        let newView = try #require(newScrollView.documentView as? NSTextView)
        session.attach(newView, pinsToBottom: false)
        session.append("再打开")
        session.flushNow()

        #expect(newView.string == "开头🪐尚未合流的尾段后台继续再打开")
        #expect(oldView.string == "开头🪐尚未合流的尾段")
        let storage = try #require(newView.textStorage)
        #expect(storage.length == (session.text as NSString).length)
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { color, _, _ in
            #expect(color as? NSColor == NSColor.secondaryLabelColor)
        }
    }

    @Test("高频小片段只在合流时编辑一次 TextKit，完整内容立即可读取")
    @MainActor
    func burstIsBufferedWithoutPerTokenStorageEdits() throws {
        let session = RAGStreamingPlainTextSession()
        let scrollView = RAGStreamingPlainTextView.makeUnadornedScrollView(font: .systemFont(ofSize: 14))
        let textView = try #require(scrollView.documentView as? NSTextView)
        let storage = try #require(textView.textStorage)
        session.attach(textView, pinsToBottom: false)
        let edits = StreamingStorageEditCounter()
        storage.delegate = edits

        // 不让主 actor 在循环中挂起，模拟网络瞬间返回大量小 delta；不依赖计时或帧率阈值。
        for _ in 0..<10_000 { session.append("字") }
        #expect(session.text == String(repeating: "字", count: 10_000))
        #expect(storage.length == 0)
        #expect(edits.count == 0)
        session.flushNow()
        #expect(textView.string == session.text)
        #expect(edits.count == 1)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.secondaryLabelColor)
    }

    @Test("空会话的相同视图无需反复清空，首批输出挂接与合流不会重复追加")
    @MainActor
    func emptyAttachmentDoesNotRewriteStorage() throws {
        let session = RAGStreamingPlainTextSession()
        let scrollView = RAGStreamingPlainTextView.makeUnadornedScrollView(font: .systemFont(ofSize: 14))
        let textView = try #require(scrollView.documentView as? NSTextView)
        let storage = try #require(textView.textStorage)
        session.attach(textView, pinsToBottom: false)
        let edits = StreamingStorageEditCounter()
        storage.delegate = edits

        session.attachIfNeeded(textView, pinsToBottom: false)
        session.attachIfNeeded(textView, pinsToBottom: false)
        #expect(edits.count == 0)
        session.append("首批输出")
        session.attachIfNeeded(textView, pinsToBottom: false)
        session.flushNow()
        #expect(textView.string == "首批输出")
        #expect(edits.count == 1)
    }
}

/// 记录 TextKit 的真实编辑次数；用同步批次断言合流，避免性能测试依赖机器速度。
private final class StreamingStorageEditCounter: NSObject, NSTextStorageDelegate {
    private(set) var count = 0

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        count += 1
    }
}
