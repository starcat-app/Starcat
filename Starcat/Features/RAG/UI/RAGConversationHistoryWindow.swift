//
//  RAGConversationHistoryWindow.swift
//  Starcat
//
//  RAG 历史会话的按轮渲染窗口与“加载更早”入口。
//

import SwiftUI

/// 控制 SwiftUI 实际布局多少轮历史消息，不改变 ViewModel 保存的完整消息数组。
///
/// 一轮以 user 消息为稳定起点，并包含下一条 user 消息之前的所有内容。这样即使最后一轮
/// 仍在等待 assistant，或历史里存在不完整消息，也不会把 user/assistant 从中间切开。
struct RAGConversationHistoryWindow: Equatable, Sendable {
    static let initialVisibleTurnCount = 2
    static let earlierTurnPageSize = 10

    private(set) var conversationID: UUID?
    private(set) var visibleTurnCount = initialVisibleTurnCount
    private(set) var knownTurnCount = 0

    /// 点开另一个历史会话时必须重新收口为最新 2 轮；不能继承上一会话已经展开的窗口。
    mutating func reset(conversationID: UUID?, messages: [RAGStoredMessage]) {
        self.conversationID = conversationID
        knownTurnCount = Self.turnStartIndices(in: messages).count
        visibleTurnCount = min(Self.initialVisibleTurnCount, knownTurnCount)
    }

    /// 当前会话新增轮次时同步扩大窗口，保留用户本次会话中已经看见的内容。
    /// 历史安装使用 `reset`，因此不会通过这里把全部历史误展开。
    mutating func reconcileCurrentConversation(
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) {
        guard self.conversationID == conversationID else {
            reset(conversationID: conversationID, messages: messages)
            return
        }

        let turnCount = Self.turnStartIndices(in: messages).count
        if turnCount > knownTurnCount {
            visibleTurnCount += turnCount - knownTurnCount
        }
        knownTurnCount = turnCount
        visibleTurnCount = min(visibleTurnCount, turnCount)
    }

    func visibleMessages(
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) -> ArraySlice<RAGStoredMessage> {
        visiblePresentation(
            conversationID: conversationID,
            messages: messages
        ).messages
    }

    /// 同时返回可见切片与“是否还有更早消息”，让高频 `body` 只扫描一次轮次起点。
    ///
    /// 旧调用先取 `visibleMessages`，再由 `hasEarlierMessages` 内部重复取一次；长会话越大，
    /// 每次布局的双重线性扫描越明显。保留两个兼容方法给测试和命令式调用，主界面走此入口。
    func visiblePresentation(
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) -> (messages: ArraySlice<RAGStoredMessage>, hasEarlierMessages: Bool) {
        let effectiveVisibleTurnCount = self.conversationID == conversationID
            ? visibleTurnCount
            : Self.initialVisibleTurnCount
        let startIndex = Self.visibleStartIndex(
            in: messages,
            visibleTurnCount: effectiveVisibleTurnCount
        )
        let visibleMessages = messages[startIndex...]
        return (
            messages: visibleMessages,
            hasEarlierMessages: visibleMessages.startIndex > messages.startIndex
        )
    }

    func hasEarlierMessages(
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) -> Bool {
        guard !messages.isEmpty else { return false }
        return visiblePresentation(
            conversationID: conversationID,
            messages: messages
        ).hasEarlierMessages
    }

    /// 每次只向前扩 10 轮，并返回扩窗前的首条消息，供调用方恢复视口。
    mutating func loadEarlier(
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) -> UUID? {
        guard self.conversationID == conversationID else {
            reset(conversationID: conversationID, messages: messages)
            return nil
        }
        let previousFirstID = visibleMessages(
            conversationID: conversationID,
            messages: messages
        ).first?.id
        let turnCount = Self.turnStartIndices(in: messages).count
        visibleTurnCount = min(turnCount, visibleTurnCount + Self.earlierTurnPageSize)
        knownTurnCount = turnCount
        return previousFirstID
    }

    /// 大纲允许跳到尚未渲染的旧轮次。先把目标轮到会话末尾全部纳入窗口，下一次布局后
    /// `ScrollViewReader` 才能找到目标 message identity。
    @discardableResult
    mutating func revealMessage(
        _ messageID: UUID,
        conversationID: UUID?,
        messages: [RAGStoredMessage]
    ) -> Bool {
        guard self.conversationID == conversationID,
              let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        let starts = Self.turnStartIndices(in: messages)
        guard !starts.isEmpty else { return false }
        let targetTurnStart = starts.last(where: { $0 <= messageIndex }) ?? messages.startIndex
        let requiredTurnCount = starts.filter { $0 >= targetTurnStart }.count
        guard requiredTurnCount > visibleTurnCount else { return false }
        visibleTurnCount = requiredTurnCount
        knownTurnCount = starts.count
        return true
    }

    private static func visibleStartIndex(
        in messages: [RAGStoredMessage],
        visibleTurnCount: Int
    ) -> Int {
        let starts = turnStartIndices(in: messages)
        guard !starts.isEmpty else { return messages.startIndex }
        // 缓存未命中的历史选择会先把 messages 清空，再异步安装 SQLite 结果。
        // SwiftUI 可能在 onChange reset 之前先求值一次正文；此时窗口仍是 0，必须按
        // 首屏 2 轮兜底，不能用 starts.count 作为数组下标。
        let resolvedVisibleTurnCount = visibleTurnCount > 0
            ? visibleTurnCount
            : min(initialVisibleTurnCount, starts.count)
        guard resolvedVisibleTurnCount < starts.count else { return messages.startIndex }
        return starts[starts.count - resolvedVisibleTurnCount]
    }

    private static func turnStartIndices(in messages: [RAGStoredMessage]) -> [Int] {
        messages.indices.filter { messages[$0].role == .user }
    }
}

/// 历史窗口只做内存投影，点击后立即完成；按钮无需伪造网络加载态。
struct RAGLoadEarlierHistoryButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label("rag.workspace.history.loadEarlier", systemImage: "chevron.up.circle")
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("rag.workspace.history.loadEarlier.help")
            Spacer()
        }
    }
}
