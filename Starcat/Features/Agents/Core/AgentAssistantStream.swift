//
//  AgentAssistantStream.swift
//  Starcat
//
//  DeepSeek 单步公开内容的瞬时组装与有界展示，不把逐 token 帧写入 Trace 或数据库。
//

import Foundation

/// 展示快照沿用最终消息的 UUID 和 sequence；结算只替换内容，不更换过程行身份。
struct AgentAssistantStreamSnapshot: Equatable, Sendable {
    struct Block: Equatable, Identifiable, Sendable {
        let id: Int
        let part: AgentMessagePart
    }

    let id: UUID
    let sequence: Int
    let blocks: [Block]
}

/// 由 ExternalAgentEventProjector actor 独占。完整内容只在结算/中断时落库，
/// 主线程每 150ms 接收一次快照；新内容块立即发布，保持 reasoning/text 的原始顺序。
struct AgentAssistantStreamBuffer {
    let id = UUID()
    let sequence: Int
    let turn: Int
    let step: Int
    private var blocks: [Int: AgentMessagePart] = [:]
    private var lastPublishedAt: TimeInterval?

    var parts: [AgentMessagePart] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    /// block-end 是权威替换，不能把完整文本再次追加到之前的 delta 后面。
    mutating func append(
        index: Int,
        part: AgentMessagePart,
        replacing: Bool,
        now: TimeInterval
    ) -> AgentAssistantStreamSnapshot? {
        let isNewBlock = blocks[index] == nil
        switch (blocks.removeValue(forKey: index), part) {
        case (.text(var old), .text(let delta)) where !replacing:
            old.append(delta)
            blocks[index] = .text(old)
        case (.reasoning(var old), .reasoning(let delta)) where !replacing:
            old.append(delta)
            blocks[index] = .reasoning(old)
        default:
            blocks[index] = part
        }
        guard isNewBlock || replacing || now - (lastPublishedAt ?? -.infinity) >= 0.15 else {
            return nil
        }
        lastPublishedAt = now
        return snapshot
    }

    /// 重试清空同一步尚未结算的内容；保留身份与排序位置，避免旧尝试和新尝试拼接。
    mutating func reset() {
        blocks.removeAll()
        lastPublishedAt = nil
    }

    var snapshot: AgentAssistantStreamSnapshot {
        // 每个块保留自己的位置与摘要。共享预算防止长思考遮掉后续正文，也不让完整
        // 未结算内容在每次 SwiftUI 测量中无限增长；数据库仍接收未经展示裁剪的 parts。
        let limit = max(1, 12_000 / max(1, blocks.count))
        return AgentAssistantStreamSnapshot(
            id: id,
            sequence: sequence,
            blocks: blocks.keys.sorted().compactMap { index in
                guard let part = blocks[index] else { return nil }
                let bounded: AgentMessagePart
                switch part {
                case .text(let text): bounded = .text(String(text.suffix(limit)))
                case .reasoning(let text): bounded = .reasoning(String(text.suffix(limit)))
                case .toolCall, .toolResult: return nil
                }
                return .init(id: index, part: bounded)
            }
        )
    }
}
