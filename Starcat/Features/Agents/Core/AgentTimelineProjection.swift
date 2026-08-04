//
//  AgentTimelineProjection.swift
//  Starcat
//
//  Agent 持久化事实到工作台时间线的唯一投影。
//
//  UI 不再消费 step/trace/tool-output 临时事件，也不根据标题或数组下标猜步骤类型。
//  每个节点都直接来自 AgentMessage、AgentApprovalRequest 或 AgentArtifact，并按真实
//  sequence 排序，因此实时运行和历史恢复会得到同一条可审计时间线。
//

import Foundation

enum AgentTimelineItemKind: Equatable, Sendable {
    case user
    case assistant
    case toolCall
    case toolResult
    case approval
    case artifact
}

struct AgentTimelineItem: Identifiable, Sendable {
    var id: String
    var sequence: Int
    var order: Int
    var kind: AgentTimelineItemKind
    var title: String
    var text: String
    var reasoning: String?
    var input: String?
    var output: String?
    var log: String?
    var toolCallID: String?
    var toolStatus: AgentToolResultStatus?
    var sources: [AgentToolResultSource]
    var toolAudit: AgentToolAudit?
    var approval: AgentApprovalRequest?
    var artifact: AgentArtifact?
}

enum AgentTimelineProjection {
    static func makeItems(
        messages: [AgentMessage],
        approvals: [AgentApprovalRequest],
        artifacts: [AgentArtifact],
        userPrompt: String
    ) -> [AgentTimelineItem] {
        let callLocations = Dictionary(uniqueKeysWithValues: messages.flatMap { message in
            message.parts.compactMap { part -> (String, Int)? in
                guard case .toolCall(let call) = part else { return nil }
                return (call.id, message.sequence)
            }
        })
        let resultsByCallID = Dictionary(uniqueKeysWithValues: messages.flatMap { message in
            message.parts.compactMap { part -> (String, AgentToolResultMessage)? in
                guard case .toolResult(let result) = part else { return nil }
                return (result.toolCallID, result)
            }
        })

        var items: [AgentTimelineItem] = []
        for message in messages {
            switch message.role {
            case .user:
                let rawText = message.parts.compactMap { part -> String? in
                    guard case .text(let text) = part else { return nil }
                    return text
                }.joined(separator: "\n")
                let displayText = message.sequence == messages.first?.sequence ? userPrompt : rawText
                items.append(AgentTimelineItem(
                    id: "message-user-\(message.id.uuidString)",
                    sequence: message.sequence,
                    order: 0,
                    kind: .user,
                    title: String.l10n("agent.workspace.timeline.user"),
                    text: displayText,
                    sources: []
                ))
            case .assistant:
                let text = message.parts.compactMap { part -> String? in
                    guard case .text(let value) = part else { return nil }
                    return value
                }.joined(separator: "\n")
                let reasoning = message.parts.compactMap { part -> String? in
                    guard case .reasoning(let value) = part else { return nil }
                    return value
                }.joined(separator: "\n")
                if !text.isEmpty || !reasoning.isEmpty {
                    items.append(AgentTimelineItem(
                        id: "message-assistant-\(message.id.uuidString)",
                        sequence: message.sequence,
                        order: 0,
                        kind: .assistant,
                        title: "Starcat",
                        text: text,
                        reasoning: reasoning.isEmpty ? nil : reasoning,
                        sources: []
                    ))
                }
                for (index, part) in message.parts.enumerated() {
                    guard case .toolCall(let call) = part else { continue }
                    let result = resultsByCallID[call.id]
                    items.append(AgentTimelineItem(
                        id: "tool-call-\(call.id)",
                        sequence: message.sequence,
                        order: 10 + index,
                        kind: .toolCall,
                        title: call.name,
                        text: result?.status.localizedTitle ?? String.l10n("agent.tool.status.pending"),
                        input: call.rawInput ?? ((try? call.input.jsonString()) ?? "{}"),
                        toolCallID: call.id,
                        toolStatus: result?.status,
                        sources: []
                    ))
                }
            case .tool:
                for (index, part) in message.parts.enumerated() {
                    guard case .toolResult(let result) = part else { continue }
                    let object = result.output.objectValue
                    items.append(AgentTimelineItem(
                        id: "tool-result-\(result.toolCallID)-\(message.id.uuidString)",
                        sequence: message.sequence,
                        order: index,
                        kind: .toolResult,
                        title: result.toolName,
                        text: object?["summary"]?.stringValue ?? result.status.localizedTitle,
                        output: object?["detail"]?.stringValue ?? object?["output"]?.stringValue ?? ((try? result.output.jsonString()) ?? "{}"),
                        log: Self.resultLog(result),
                        toolCallID: result.toolCallID,
                        toolStatus: result.status,
                        sources: result.sources,
                        toolAudit: result.toolAudit
                    ))
                }
            }
        }

        for approval in approvals {
            items.append(AgentTimelineItem(
                id: "approval-\(approval.id.uuidString)",
                sequence: callLocations[approval.toolCallID] ?? approval.sequence,
                order: 90,
                kind: .approval,
                title: approval.toolName,
                text: approval.status.localizedTitle,
                input: (try? approval.input.jsonString()) ?? "{}",
                toolStatus: nil,
                sources: [],
                approval: approval
            ))
        }

        for artifact in artifacts {
            items.append(AgentTimelineItem(
                id: "artifact-\(artifact.id.uuidString)",
                sequence: artifact.sequence,
                order: 100,
                kind: .artifact,
                title: artifact.title,
                text: String(artifact.content.prefix(240)),
                sources: [],
                artifact: artifact
            ))
        }

        return items.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }

    private static func resultLog(_ result: AgentToolResultMessage) -> String {
        let persistedLog = result.output.objectValue?["log"]?.stringValue ?? ""
        let attemptLines = result.attempts.map { attempt in
            let error = attempt.errorSummary.map { " error=\($0)" } ?? ""
            return "attempt[\(attempt.number)]=\(attempt.status.rawValue) elapsed_ms=\(attempt.elapsedMilliseconds)\(error)"
        }
        let metadata = ([
            "status=\(result.status.rawValue)",
            "elapsed_ms=\(result.elapsedMilliseconds)",
            "attempt_count=\(result.attempts.count)",
            "source_count=\(result.sources.count)"
        ] + attemptLines).joined(separator: "\n")
        return persistedLog.isEmpty ? metadata : "\(metadata)\n\(persistedLog)"
    }
}
