//
//  AgentHarnessProcessPresentation.swift
//  Starcat
//
//  Harness 主对话的可读过程投影。完整 Trace 仍独立保留，内部协议事件不充当工作步骤。
//

import Foundation

/// 一条真实工具活动或公开内容块。排序使用共享 sequence，块身份沿用消息 UUID/index。
struct AgentHarnessProcessRow: Identifiable, Sendable {
    enum Content: Sendable {
        case trace(AgentTraceEvent)
        case block(AgentMessagePart)
    }

    let id: String
    let sequence: Int
    let order: Int
    let content: Content
    let summary: String?

    init(id: String, sequence: Int, order: Int, content: Content) {
        self.id = id
        self.sequence = sequence
        self.order = order
        self.content = content
        // 工具结果可能含大型 JSON；仅在事实变化时解析一次，不能跟随每个流式快照重算。
        switch content {
        case .trace(let event):
            summary = AgentTraceRowPresentation.summary(for: event).map { Self.preview($0) }
        case .block(.text(let text)), .block(.reasoning(let text)):
            summary = Self.preview(text)
        default:
            summary = nil
        }
    }

    /// 标题只消费有界纯文本，避免每次增量都解析 Markdown 或测量整段思考。
    static func preview(_ text: String, running: Bool = false) -> String {
        let bounded = running ? String(text.suffix(12_000)) : String(text.prefix(512))
        let paragraphs = running ? bounded.components(separatedBy: "\n\n") : [bounded]
        let paragraph = running
            ? paragraphs.last(where: { $0.contains("\n") }) ?? paragraphs.last ?? ""
            : bounded
        let line = paragraph.split(whereSeparator: \.isNewline).first.map(String.init) ?? paragraph
        return String(line.prefix(160)).replacingOccurrences(of: "**", with: "")
    }
}

/// 只生成展示数据，不删除、合并或改写持久化事件。未知事件的失败/阻塞始终提升到主过程。
enum AgentHarnessProcessPresentation {
    static func rows(
        presentation: AgentRunPresentation,
        traces: [AgentTraceEvent]
    ) -> [AgentHarnessProcessRow] {
        var rows = traces.filter(isVisible).map {
            AgentHarnessProcessRow(id: "trace-\($0.id)", sequence: $0.sequence, order: 0, content: .trace($0))
        }
        for section in presentation.processSections where section.kind == .progress {
            for item in section.items {
                appendBlocks(item.messageParts, item: item, reasoningOnly: false, to: &rows)
            }
        }
        if let final = presentation.finalAnswer {
            // 最终正文保持在过程区外，最后一步公开的 reasoning 仍可在过程区查阅。
            appendBlocks(final.messageParts, item: final, reasoningOnly: true, to: &rows)
        }
        return sorted(rows)
    }

    static func streamingRows(_ snapshot: AgentAssistantStreamSnapshot) -> [AgentHarnessProcessRow] {
        let visible = snapshot.blocks.filter { block in
            switch block.part {
            case .text(let text), .reasoning(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolCall, .toolResult:
                return false
            }
        }
        // 结算消息只保存公开的非空内容块，不含 tool-call 的原始 index 空洞。
        // 因此展示身份按同一可见块序号生成，原始 index 仅用于流式组装。
        return visible.enumerated().map { index, block in
            return AgentHarnessProcessRow(
                id: "message-assistant-\(snapshot.id.uuidString)-block-\(index)",
                sequence: snapshot.sequence,
                order: index,
                content: .block(block.part)
            )
        }
    }

    static func sorted(_ rows: [AgentHarnessProcessRow]) -> [AgentHarnessProcessRow] {
        rows.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }

    static func isVisible(_ event: AgentTraceEvent) -> Bool {
        if event.status == .failed || event.status == .waiting { return true }
        switch event.kind {
        case .tool, .mcpTool, .command, .webSearch, .fileChange, .reasoningSummary,
             .commentary, .plan, .todo, .warning, .retry, .error, .compaction, .approval:
            return true
        case .lifecycle, .message, .request, .unknown:
            return false
        }
    }

    private static func appendBlocks(
        _ parts: [AgentMessagePart],
        item: AgentTimelineItem,
        reasoningOnly: Bool,
        to rows: inout [AgentHarnessProcessRow]
    ) {
        let visibleParts = parts.isEmpty && !item.text.isEmpty ? [.text(item.text)] : parts
        for (index, part) in visibleParts.enumerated() {
            switch part {
            case .reasoning(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .text(let text):
                guard !reasoningOnly, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            case .toolCall, .toolResult:
                continue
            }
            rows.append(AgentHarnessProcessRow(
                id: "\(item.id)-block-\(index)",
                sequence: item.sequence,
                order: index,
                content: .block(part)
            ))
        }
    }
}
