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
}
