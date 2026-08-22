//
//  AgentTimelineProjection.swift
//  Starcat
//
//  Agent 持久化事实到工作台 Run Surface 的唯一投影。
//
//  UI 不再消费 step/trace/tool-output 临时事件，也不根据标题或数组下标猜步骤类型。
//  每个节点都直接来自 AgentMessage、AgentApprovalRequest 或 AgentArtifact，并按真实
//  sequence 排序。tool call/result 只在展示层按 toolCallID 合并，不改写任何审计事实。
//

import Foundation

enum AgentTimelineItemKind: Equatable, Sendable {
    case user
    case assistant
    case toolExecution
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
    /// 工具提供的用户可读运行叙事。它与完整审计日志分开，避免主界面暴露
    /// status / elapsed_ms 等实现细节，同时仍保留 log 作为持久化事实投影。
    var narrative: String? = nil
    var reasoning: String?
    var input: String?
    var output: String?
    var log: String?
    var toolCallID: String?
    /// 确定性活动分组键。它只来自工具名，不能由模型生成或依赖本地化文案。
    var presentationKey: String? = nil
    var toolStatus: AgentToolResultStatus?
    var sources: [AgentToolResultSource]
    var toolAudit: AgentToolAudit?
    var approval: AgentApprovalRequest?
    var artifact: AgentArtifact?

    /// disclosure 只能在确实存在可读审计数据时出现，否则用户展开后会得到空白区域。
    /// 工具标题与摘要已在主行展示，不属于可展开详情。
    var hasExecutionDetails: Bool {
        [input, output, log].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } || !sources.isEmpty || toolAudit?.knowledgeRetrieval != nil
    }
}

/// Run Surface 过程区中的稳定展示分组。
struct AgentProcessSection: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case progress
        case activity
        case approval
    }

    var id: String
    var kind: Kind
    var items: [AgentTimelineItem]
}

/// 一次 Run 的双层展示投影：过程可追踪，最终结果可直接阅读。
struct AgentRunPresentation: Sendable {
    var userItems: [AgentTimelineItem]
    var processSections: [AgentProcessSection]
    var finalAnswer: AgentTimelineItem?
    var inlineArtifacts: [AgentTimelineItem]
    var isProcessExpandedByDefault: Bool
}

enum AgentTimelineProjection {
    private struct LocatedResult {
        var value: AgentToolResultMessage
    }

    /// 从同一份持久化事实生成 Run Surface。完成态默认收起过程，失败和审批态展开，
    /// 历史恢复与实时运行因此不会出现两套展示规则。
    static func makePresentation(
        messages: [AgentMessage],
        approvals: [AgentApprovalRequest],
        artifacts: [AgentArtifact],
        userPrompt: String,
        status: AgentRunStatus
    ) -> AgentRunPresentation {
        let items = makeItems(
            messages: messages,
            approvals: approvals,
            artifacts: artifacts,
            userPrompt: userPrompt
        )
        let assistantItems = items.filter { $0.kind == .assistant && !$0.text.isEmpty }
        let lastToolResultSequence = messages.lazy
            .filter { message in
                message.parts.contains { part in
                    if case .toolResult = part { return true }
                    return false
                }
            }
            .map(\.sequence)
            .max()
        let finalAnswer = assistantItems.last { item in
            guard let lastToolResultSequence else { return true }
            return item.sequence > lastToolResultSequence
        }
        let processItems = items.filter { item in
            switch item.kind {
            case .assistant:
                // 原始 reasoning 永远不进入普通 Run Surface；只有明确的用户可见文本可作为进度。
                return item.id != finalAnswer?.id && !item.text.isEmpty
            case .toolExecution, .approval:
                return true
            case .user, .artifact:
                return false
            }
        }

        return AgentRunPresentation(
            userItems: items.filter { $0.kind == .user },
            processSections: makeProcessSections(processItems),
            finalAnswer: finalAnswer,
            inlineArtifacts: items.filter { $0.kind == .artifact && $0.artifact?.type == .markdown },
            isProcessExpandedByDefault: status != .completed && status != .cancelled
        )
    }

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
            message.parts.compactMap { part -> (String, LocatedResult)? in
                guard case .toolResult(let result) = part else { return nil }
                return (result.toolCallID, LocatedResult(value: result))
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
                    let locatedResult = resultsByCallID[call.id]
                    let result = locatedResult?.value
                    let object = result?.output.objectValue
                    items.append(AgentTimelineItem(
                        id: "tool-execution-\(call.id)",
                        sequence: message.sequence,
                        order: 10 + index,
                        kind: .toolExecution,
                        title: displayTitle(for: call.name),
                        text: object?["summary"]?.stringValue
                            ?? result?.status.localizedTitle
                            ?? String.l10n("agent.tool.status.pending"),
                        narrative: result.flatMap(Self.resultNarrative),
                        input: call.rawInput ?? ((try? call.input.jsonString()) ?? "{}"),
                        output: object?["detail"]?.stringValue
                            ?? object?["output"]?.stringValue
                            ?? result.flatMap { try? $0.output.jsonString() },
                        log: result.map(Self.resultLog),
                        toolCallID: call.id,
                        presentationKey: call.name,
                        toolStatus: result?.status,
                        sources: result?.sources ?? [],
                        toolAudit: result?.toolAudit
                    ))
                }
            case .tool:
                // tool result 已按 toolCallID 合并回对应 call；消息本身仍保留在持久化事实中。
                continue
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

    /// 相邻同工具执行可聚合；Approval、进度文本与失败执行都是强边界。
    private static func makeProcessSections(_ items: [AgentTimelineItem]) -> [AgentProcessSection] {
        var sections: [AgentProcessSection] = []
        for item in items {
            switch item.kind {
            case .toolExecution:
                let canAppend = item.toolStatus != .failed
                    && item.toolStatus != .timedOut
                    && item.toolStatus != .rejected
                    && sections.last?.kind == .activity
                    && sections.last?.items.last?.presentationKey == item.presentationKey
                    && sections.last?.items.last?.toolStatus != .failed
                    && sections.last?.items.last?.toolStatus != .timedOut
                    && sections.last?.items.last?.toolStatus != .rejected
                if canAppend {
                    sections[sections.count - 1].items.append(item)
                } else {
                    sections.append(AgentProcessSection(id: "activity-\(item.id)", kind: .activity, items: [item]))
                }
            case .approval:
                sections.append(AgentProcessSection(id: "approval-\(item.id)", kind: .approval, items: [item]))
            case .assistant:
                sections.append(AgentProcessSection(id: "progress-\(item.id)", kind: .progress, items: [item]))
            case .user, .artifact:
                continue
            }
        }
        return sections
    }

    /// 已知与未知工具都使用相同的本地确定性降级，不把内部 snake_case 原样暴露为标题。
    private static func displayTitle(for toolName: String) -> String {
        toolName
            .split(separator: "_")
            .map(String.init)
            .joined(separator: " ")
            .localizedCapitalized
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

    /// 工具协议里的 output.log 是面向用户的完成说明；技术元数据由 resultLog 单独生成。
    /// 两者不能混用，否则用户可读的任务叙事会退化成运行时调试日志。
    private static func resultNarrative(_ result: AgentToolResultMessage) -> String? {
        let persistedLog = result.output.objectValue?["log"]?.stringValue ?? ""
        let narrative = persistedLog.trimmingCharacters(in: .whitespacesAndNewlines)
        return narrative.isEmpty ? nil : narrative
    }
}
