//
//  AgentTools.swift
//  Starcat
//
//  Agent 工具系统的最小共享协议。
//
//  Runtime 通过 tool id 调用能力,而不是直接依赖某个 Agent 的静态函数。
//  这样 Weekly、回忆搜索、替代品发现等 Agent 可以复用同一套执行、审计和权限边界。
//

import Foundation

/// Agent tool 的权限边界。
///
/// 当前只实现只读工具。写入、高成本和确认型工具先建立状态语义,后续接 tag/note/star
/// 时必须走确认流,不能把写操作混进自动 loop。
enum AgentToolPermission: String, Hashable, Sendable {
    case readOnly
    case requiresConfirmation
    case highCost
}

/// Agent tool 的执行结果状态。
enum AgentToolStatus: String, Hashable, Sendable {
    case completed
    case skipped
    case failed
    case requiresConfirmation

    var stepStatus: AgentStepStatus {
        switch self {
        case .completed:
            return .completed
        case .skipped:
            return .skipped
        case .failed:
            return .failed
        case .requiresConfirmation:
            return .pending
        }
    }
}

/// Runtime 传给工具的一次调用输入。
struct AgentToolInput: Sendable {
    var prompt: String
    var context: AgentRunContext
    var values: [String: String]
    var payload: AgentToolPayload

    init(
        prompt: String,
        context: AgentRunContext,
        values: [String: String] = [:],
        payload: AgentToolPayload = .none
    ) {
        self.prompt = prompt
        self.context = context
        self.values = values
        self.payload = payload
    }
}

/// Agent tool 的标准输出。
///
/// `payload` 只保存当前 Runtime 继续执行需要的轻量结构。完整原文、网页正文或大 JSON
/// 后续应进入 artifact / cache,不得无限塞进 LLM prompt。
struct AgentToolResult: Sendable {
    var status: AgentToolStatus
    var output: AgentToolOutput
    var trace: AgentTraceSpan
    var payload: AgentToolPayload

    init(
        status: AgentToolStatus = .completed,
        output: AgentToolOutput,
        trace: AgentTraceSpan,
        payload: AgentToolPayload = .none
    ) {
        self.status = status
        self.output = output
        self.trace = trace
        self.payload = payload
    }
}

/// 当前框架内工具间传递的轻量 payload。
enum AgentToolPayload: Sendable {
    case none
    case topics([WeeklyReportTopic])
    case markdown(String)
    case externalContextMarkdown(String)
}

/// 所有 Agent tool 的统一协议。
protocol AgentTool: Sendable {
    var id: String { get }
    var displayName: String { get }
    var permission: AgentToolPermission { get }

    func execute(_ input: AgentToolInput) async -> AgentToolResult
}

/// Tool Registry 是 Runtime 和具体能力之间的唯一查找层。
///
/// Registry 在初始化时拒绝重复 id,避免不同工具互相覆盖;Runtime 发现缺工具时应显式失败,
/// 不能静默跳过,否则审计链会断。
struct AgentToolRegistry: Sendable {
    private let toolsByID: [String: any AgentTool]

    init(tools: [any AgentTool]) throws {
        var next: [String: any AgentTool] = [:]
        for tool in tools {
            guard next[tool.id] == nil else {
                throw AgentToolRegistryError.duplicateToolID(tool.id)
            }
            next[tool.id] = tool
        }
        toolsByID = next
    }

    func tool(for id: String) throws -> any AgentTool {
        guard let tool = toolsByID[id] else {
            throw AgentToolRegistryError.missingTool(id)
        }
        return tool
    }

    func tools(for ids: [String]) throws -> [any AgentTool] {
        try ids.map { try tool(for: $0) }
    }
}

enum AgentToolRegistryError: LocalizedError, Equatable, Sendable {
    case duplicateToolID(String)
    case missingTool(String)

    var errorDescription: String? {
        switch self {
        case .duplicateToolID(let id):
            return "Duplicate Agent tool id: \(id)"
        case .missingTool(let id):
            return "Missing Agent tool: \(id)"
        }
    }
}
