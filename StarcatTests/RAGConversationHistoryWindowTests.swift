//
//  RAGConversationHistoryWindowTests.swift
//  StarcatTests
//
//  锁住 RAG 历史会话按轮窗口的首屏、分批扩展和大纲跳转边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAGConversationHistoryWindow")
struct RAGConversationHistoryWindowTests {
    private let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Test("打开历史会话只投影最新两轮")
    func initialWindowShowsLatestTwoTurns() {
        let messages = makeTurns(5)
        var window = RAGConversationHistoryWindow()

        window.reset(conversationID: conversationID, messages: messages)
        let visible = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))

        #expect(visible.map(\.id) == Array(messages.suffix(4)).map(\.id))
        #expect(window.hasEarlierMessages(conversationID: conversationID, messages: messages))
    }

    @Test("每次手动加载十轮直至完整历史")
    func loadingEarlierExpandsTenTurnsPerPage() {
        let messages = makeTurns(25)
        var window = RAGConversationHistoryWindow()
        window.reset(conversationID: conversationID, messages: messages)

        let previousFirstID = window.loadEarlier(
            conversationID: conversationID,
            messages: messages
        )
        let firstPage = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))
        _ = window.loadEarlier(conversationID: conversationID, messages: messages)
        let secondPage = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))
        _ = window.loadEarlier(conversationID: conversationID, messages: messages)
        let allMessages = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))

        #expect(previousFirstID == messages[messages.count - 4].id)
        #expect(firstPage.count == 24)
        #expect(secondPage.count == 44)
        #expect(allMessages.count == 50)
        #expect(!window.hasEarlierMessages(conversationID: conversationID, messages: messages))
    }

    @Test("当前会话新增一轮时保留已经展开的起点")
    func currentConversationGrowthPreservesVisibleHistory() {
        var messages = makeTurns(15)
        var window = RAGConversationHistoryWindow()
        window.reset(conversationID: conversationID, messages: messages)
        _ = window.loadEarlier(conversationID: conversationID, messages: messages)
        let previousFirstID = window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ).first?.id

        messages.append(contentsOf: makeTurn(15))
        window.reconcileCurrentConversation(conversationID: conversationID, messages: messages)

        #expect(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ).first?.id == previousFirstID)
    }

    @Test("大纲跳到窗口外时自动展开到目标轮")
    func outlineRevealExpandsThroughTargetTurn() {
        let messages = makeTurns(20)
        let targetUserID = messages[2].id
        var window = RAGConversationHistoryWindow()
        window.reset(conversationID: conversationID, messages: messages)

        let didExpand = window.revealMessage(
            targetUserID,
            conversationID: conversationID,
            messages: messages
        )
        let visible = window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        )
        let repeatedReveal = window.revealMessage(
            targetUserID,
            conversationID: conversationID,
            messages: messages
        )

        #expect(didExpand)
        #expect(visible.first?.id == targetUserID)
        #expect(!repeatedReveal)
    }

    @Test("等待回答的末条用户消息仍按一轮计算")
    func pendingUserMessageCountsAsTurn() {
        var messages = makeTurns(3)
        let pending = makeMessage(turn: 3, role: .user)
        messages.append(pending)
        var window = RAGConversationHistoryWindow()

        window.reset(conversationID: conversationID, messages: messages)
        let visible = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))

        #expect(visible.first?.role == .user)
        #expect(visible.last?.id == pending.id)
        #expect(visible.count == 3)
    }

    @Test("异步历史安装前的零轮窗口不越界")
    func emptyLoadingWindowFallsBackToLatestTwoTurns() {
        let messages = makeTurns(5)
        var window = RAGConversationHistoryWindow()
        window.reset(conversationID: conversationID, messages: [])

        // 模拟 messages 已设置、SwiftUI onChange 尚未执行的瞬时求值顺序。
        let visible = Array(window.visibleMessages(
            conversationID: conversationID,
            messages: messages
        ))

        #expect(visible.map(\.id) == Array(messages.suffix(4)).map(\.id))
    }

    private func makeTurns(_ count: Int) -> [RAGStoredMessage] {
        (0..<count).flatMap(makeTurn)
    }

    private func makeTurn(_ turn: Int) -> [RAGStoredMessage] {
        [
            makeMessage(turn: turn, role: .user),
            makeMessage(turn: turn, role: .assistant)
        ]
    }

    private func makeMessage(turn: Int, role: RAGStoredMessageRole) -> RAGStoredMessage {
        let rawID = turn * 2 + (role == .assistant ? 2 : 1)
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", rawID))!
        return RAGStoredMessage(
            id: id,
            conversationID: conversationID,
            role: role,
            content: role == .user ? "Question \(turn)" : "Answer \(turn)",
            model: role == .assistant ? "test-model" : nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: "2026-07-15T00:00:\(String(format: "%02d", turn % 60))Z"
        )
    }
}
