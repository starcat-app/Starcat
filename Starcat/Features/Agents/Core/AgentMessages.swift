//
//  AgentMessages.swift
//  Starcat
//
//  Agent run 的可回放消息事实模型。
//
//  Runtime 事件适合实时驱动 UI，但事件丢失或 App 重启后不能作为事实源。本文件定义的消息、
//  tool-call、tool-result 和 usage 会被完整持久化；时间线、trace 与 Inspector 都应由它们投影。
//

import Foundation

enum AgentMessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
}

/// 模型请求宿主执行的一次工具调用。
struct AgentToolCall: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var input: AgentJSONValue
    /// Provider 返回的原始 arguments；非法 JSON 也必须保留，供 Inspector 审计。
    var rawInput: String?
    var sequence: Int

    init(id: String, name: String, input: AgentJSONValue, rawInput: String? = nil, sequence: Int) {
        self.id = id
        self.name = name
        self.input = input
        self.rawInput = rawInput
        self.sequence = sequence
    }
}

enum AgentToolResultStatus: String, Codable, Hashable, Sendable {
    case completed
    case skipped
    case failed
    case timedOut
    case rejected

    var localizedTitle: String {
        switch self {
        case .completed: return String.l10n("agent.tool.status.completed")
        case .skipped: return String.l10n("agent.tool.status.skipped")
        case .failed: return String.l10n("agent.tool.status.failed")
        case .timedOut: return String.l10n("agent.tool.status.timedOut")
        case .rejected: return String.l10n("agent.tool.status.rejected")
        }
    }
}

/// 单次工具执行尝试的持久化审计事实。
///
/// Runtime 只对只读工具自动重试；每次尝试仍需独立记录，避免历史页面只能看到最终结果，
/// 无法判断一次成功究竟经历过多少次超时或失败。
struct AgentToolExecutionAttempt: Codable, Hashable, Sendable, Identifiable {
    var id: Int { number }
    var number: Int
    var status: AgentToolResultStatus
    var elapsedMilliseconds: Int
    var errorSummary: String?
}

/// 工具结果中可单独展示和审计的来源。
struct AgentToolResultSource: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var url: String
    var provider: String?

    init(id: String = UUID().uuidString, title: String, url: String, provider: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.provider = provider
    }
}

/// 宿主工具执行后回灌给模型的结构化结果。
struct AgentToolResultMessage: Codable, Hashable, Sendable {
    var toolCallID: String
    var toolName: String
    var output: AgentJSONValue
    var isError: Bool
    var status: AgentToolResultStatus
    var elapsedMilliseconds: Int
    var attempts: [AgentToolExecutionAttempt]
    var sources: [AgentToolResultSource]
    /// 仅供历史回放与 Inspector 使用，不会回灌给模型。
    var toolAudit: AgentToolAudit?
    var sequence: Int

    init(
        toolCallID: String,
        toolName: String,
        output: AgentJSONValue,
        isError: Bool,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int = 0,
        attempts: [AgentToolExecutionAttempt] = [],
        sources: [AgentToolResultSource] = [],
        toolAudit: AgentToolAudit? = nil,
        sequence: Int
    ) {
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.output = output
        self.isError = isError
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.attempts = attempts
        self.sources = sources
        self.toolAudit = toolAudit
        self.sequence = sequence
    }
}

/// 单次或累计模型调用的 token/cost 使用量。
struct AgentUsage: Codable, Hashable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var estimatedCost: Decimal?

    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cachedTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int? = nil,
        estimatedCost: Decimal? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens ?? inputTokens + outputTokens
        self.estimatedCost = estimatedCost
    }

    static let zero = AgentUsage()

    mutating func merge(_ other: AgentUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedTokens += other.cachedTokens
        reasoningTokens += other.reasoningTokens
        totalTokens += other.totalTokens
        if let otherCost = other.estimatedCost {
            estimatedCost = (estimatedCost ?? 0) + otherCost
        }
    }
}

/// 一条 Agent 消息中的有序内容块。
///
/// 显式 `type` 编码保证数据库快照和 fixture 可读，也避免依赖 Swift 对 associated-value
/// enum 的编译器私有编码形状。
enum AgentMessagePart: Hashable, Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolResultMessage)
}

extension AgentMessagePart: Codable {
    private enum PartType: String, Codable {
        case text
        case reasoning
        case toolCall
        case toolResult
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case toolCall
        case toolResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PartType.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .reasoning:
            self = .reasoning(try container.decode(String.self, forKey: .text))
        case .toolCall:
            self = .toolCall(try container.decode(AgentToolCall.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(AgentToolResultMessage.self, forKey: .toolResult))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoning(let text):
            try container.encode(PartType.reasoning, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolCall(let call):
            try container.encode(PartType.toolCall, forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(result, forKey: .toolResult)
        }
    }
}

/// run 中可持久化、可回放的一条消息。
struct AgentMessage: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var runID: UUID
    var role: AgentMessageRole
    var turn: Int
    var sequence: Int
    var parts: [AgentMessagePart]
    var usage: AgentUsage?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        role: AgentMessageRole,
        turn: Int,
        sequence: Int,
        parts: [AgentMessagePart],
        usage: AgentUsage? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.role = role
        self.turn = turn
        self.sequence = sequence
        self.parts = parts
        self.usage = usage
        self.createdAt = createdAt
    }
}

/// 同一模型轮次的消息集合，供 Runtime 和测试按 turn 读取。
struct AgentTurn: Codable, Hashable, Sendable, Identifiable {
    var id: Int { index }
    var index: Int
    var messages: [AgentMessage]
}

/// 在进入 Repository 或模型下一轮前验证消息图的关联关系。
enum AgentMessageContract {
    static func validate(_ messages: [AgentMessage]) throws {
        guard let runID = messages.first?.runID else { return }
        var previousSequence = -1
        var calls: [String: AgentToolCall] = [:]
        var completedCallIDs: Set<String> = []

        for message in messages {
            guard message.runID == runID else {
                throw AgentMessageContractError.mixedRunIDs
            }
            guard message.sequence > previousSequence else {
                throw AgentMessageContractError.nonIncreasingSequence(message.sequence)
            }
            guard message.turn >= 0, !message.parts.isEmpty else {
                throw AgentMessageContractError.invalidMessage(message.id)
            }
            previousSequence = message.sequence

            for part in message.parts {
                try validate(part, role: message.role, calls: &calls, completedCallIDs: &completedCallIDs)
            }
        }
    }

    private static func validate(
        _ part: AgentMessagePart,
        role: AgentMessageRole,
        calls: inout [String: AgentToolCall],
        completedCallIDs: inout Set<String>
    ) throws {
        switch (role, part) {
        case (.user, .text), (.assistant, .text), (.assistant, .reasoning):
            return
        case (.assistant, .toolCall(let call)):
            guard !call.id.isEmpty, !call.name.isEmpty else {
                throw AgentMessageContractError.invalidToolCall(call.id)
            }
            guard calls[call.id] == nil else {
                throw AgentMessageContractError.duplicateToolCallID(call.id)
            }
            calls[call.id] = call
        case (.tool, .toolResult(let result)):
            guard let call = calls[result.toolCallID] else {
                throw AgentMessageContractError.unknownToolCallID(result.toolCallID)
            }
            guard call.name == result.toolName else {
                throw AgentMessageContractError.toolNameMismatch(callID: result.toolCallID)
            }
            guard completedCallIDs.insert(result.toolCallID).inserted else {
                throw AgentMessageContractError.duplicateToolResult(result.toolCallID)
            }
        default:
            throw AgentMessageContractError.invalidPartForRole(role)
        }
    }
}

enum AgentMessageContractError: LocalizedError, Equatable, Sendable {
    case mixedRunIDs
    case nonIncreasingSequence(Int)
    case invalidMessage(UUID)
    case invalidPartForRole(AgentMessageRole)
    case invalidToolCall(String)
    case duplicateToolCallID(String)
    case unknownToolCallID(String)
    case toolNameMismatch(callID: String)
    case duplicateToolResult(String)

    var errorDescription: String? {
        switch self {
        case .mixedRunIDs:
            return String.l10n("agent.message.error.mixedRunIDs")
        case .nonIncreasingSequence(let sequence):
            return String(format: String.l10n("agent.message.error.nonIncreasingSequenceFormat"), sequence)
        case .invalidMessage(let id):
            return String(format: String.l10n("agent.message.error.invalidMessageFormat"), id.uuidString)
        case .invalidPartForRole(let role):
            return String(format: String.l10n("agent.message.error.invalidPartForRoleFormat"), role.rawValue)
        case .invalidToolCall(let id):
            return String(format: String.l10n("agent.message.error.invalidToolCallFormat"), id)
        case .duplicateToolCallID(let id):
            return String(format: String.l10n("agent.message.error.duplicateToolCallFormat"), id)
        case .unknownToolCallID(let id):
            return String(format: String.l10n("agent.message.error.unknownToolCallFormat"), id)
        case .toolNameMismatch(let callID):
            return String(format: String.l10n("agent.message.error.toolNameMismatchFormat"), callID)
        case .duplicateToolResult(let id):
            return String(format: String.l10n("agent.message.error.duplicateToolResultFormat"), id)
        }
    }
}
