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
/// Runtime 已实现写入与高成本工具的执行前审批闭环;当前正式 Weekly 和 Repo Insight
/// 只注册只读工具。后续接 tag/note/star 时必须声明对应权限,不能把写操作混进自动 loop。
enum AgentToolPermission: String, Codable, Hashable, Sendable {
    case readOnly
    /// 会访问开放网络、但不写入 Starcat 数据；必须同时经过 Run 级联网授权与隐私策略。
    case openWorldRead
    case requiresConfirmation
    case highCost

    var localizedTitle: String {
        switch self {
        case .readOnly: return String.l10n("agent.tool.permission.readOnly")
        case .openWorldRead: return String.l10n("agent.tool.permission.openWorldRead")
        case .requiresConfirmation: return String.l10n("agent.tool.permission.requiresConfirmation")
        case .highCost: return String.l10n("agent.tool.permission.highCost")
        }
    }

    var isAutomaticRead: Bool {
        self == .readOnly || self == .openWorldRead
    }
}

/// 工具级重试策略。只有无副作用工具可以声明自动重试。
struct AgentToolRetryPolicy: Codable, Hashable, Sendable {
    var maxRetries: Int
    var initialBackoffMilliseconds: Int

    static let none = AgentToolRetryPolicy(maxRetries: 0, initialBackoffMilliseconds: 0)
    static let transientRead = AgentToolRetryPolicy(maxRetries: 1, initialBackoffMilliseconds: 300)
}

/// 暴露给模型并由 Runtime 强制执行的工具定义。
struct AgentToolDefinition: Codable, Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var inputSchema: AgentJSONSchema
    var permission: AgentToolPermission
    var completesRun: Bool
    var timeoutMilliseconds: Int
    var retryPolicy: AgentToolRetryPolicy

    init(
        name: String,
        description: String,
        inputSchema: AgentJSONSchema,
        permission: AgentToolPermission = .readOnly,
        completesRun: Bool = false,
        timeoutMilliseconds: Int = 30_000,
        retryPolicy: AgentToolRetryPolicy = .none
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.permission = permission
        self.completesRun = completesRun
        self.timeoutMilliseconds = timeoutMilliseconds
        self.retryPolicy = retryPolicy
    }

    /// OpenAI-compatible function name 的共同约束；Registry 和模型 adapter 必须复用
    /// 同一判断，避免工具注册成功后才在真实 provider 请求阶段失败。
    static func isProviderCompatibleName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

/// Agent tool 的执行结果状态。
enum AgentToolStatus: String, Codable, Hashable, Sendable {
    case completed
    case skipped
    case failed

    var stepStatus: AgentStepStatus {
        switch self {
        case .completed:
            return .completed
        case .skipped:
            return .skipped
        case .failed:
            return .failed
        }
    }
}

/// Runtime 传给工具的一次调用输入。
struct AgentToolInput: Sendable {
    var toolCallID: String?
    var arguments: AgentJSONValue
    var prompt: String
    var context: AgentRunContext
    var values: [String: String]
    var payload: AgentToolPayload

    init(
        toolCallID: String? = nil,
        arguments: AgentJSONValue = .object([:]),
        prompt: String,
        context: AgentRunContext,
        values: [String: String] = [:],
        payload: AgentToolPayload = .none
    ) {
        self.toolCallID = toolCallID
        self.arguments = arguments
        self.prompt = prompt
        self.context = context
        self.values = values
        self.payload = payload
    }
}

/// Agent tool 的标准输出。
///
/// `payload` 只保存当前 Runtime 继续执行需要的轻量结构。模型可见的有界 output 仍会作为
/// message fact 持久化；完整原文、网页正文或大 JSON 应进入 artifact / cache。
struct AgentToolResult: Sendable {
    var status: AgentToolStatus
    var output: AgentToolOutput
    var trace: AgentTraceSpan
    var payload: AgentToolPayload
    var sources: [AgentToolResultSource]
    var toolAudit: AgentToolAudit?

    init(
        status: AgentToolStatus = .completed,
        output: AgentToolOutput,
        trace: AgentTraceSpan,
        payload: AgentToolPayload = .none,
        sources: [AgentToolResultSource] = [],
        toolAudit: AgentToolAudit? = nil
    ) {
        self.status = status
        self.output = output
        self.trace = trace
        self.payload = payload
        self.sources = sources
        self.toolAudit = toolAudit
    }
}

/// 当前框架内工具间传递的轻量 payload。
enum AgentToolPayload: Sendable {
    case none
    case topics([WeeklyReportTopic])
    case repo(AgentRepoSnapshot)
    case markdown(String)
    case externalContextMarkdown(String)
    /// 当前 run 内的有界知识证据；结构化检索审计由 `toolAudit` 随消息事实持久化。
    case knowledge(AgentKnowledgeResult)
}

/// 所有 Agent tool 的统一协议。
protocol AgentTool: Sendable {
    var definition: AgentToolDefinition { get }

    func execute(_ input: AgentToolInput) async -> AgentToolResult
}

extension AgentTool {
    var id: String { definition.name }
    var displayName: String { definition.name }
    var permission: AgentToolPermission { definition.permission }
}

/// Tool Registry 是 Runtime 和具体能力之间的唯一查找层。
///
/// Registry 在初始化时拒绝重复 id,避免不同工具互相覆盖;Runtime 发现缺工具时应显式失败,
/// 不能静默跳过,否则审计链会断。
struct AgentToolRegistry: Sendable {
    private let toolsByName: [String: any AgentTool]

    init(tools: [any AgentTool]) throws {
        var next: [String: any AgentTool] = [:]
        for tool in tools {
            let name = tool.definition.name
            guard AgentToolDefinition.isProviderCompatibleName(name) else {
                throw AgentToolRegistryError.invalidToolName(name)
            }
            guard next[name] == nil else {
                throw AgentToolRegistryError.duplicateToolName(name)
            }
            next[name] = tool
        }
        toolsByName = next
    }

    var definitions: [AgentToolDefinition] {
        toolsByName.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func tool(named name: String) throws -> any AgentTool {
        guard let tool = toolsByName[name] else {
            throw AgentToolRegistryError.missingTool(name)
        }
        return tool
    }

    func tools(named names: [String]) throws -> [any AgentTool] {
        try names.map { try tool(named: $0) }
    }

    /// 模型调用进入宿主执行器前的统一 schema 校验入口。
    func validatedTool(for call: AgentToolCall) throws -> any AgentTool {
        let tool = try tool(named: call.name)
        do {
            try tool.definition.inputSchema.validate(call.input)
        } catch {
            throw AgentToolRegistryError.invalidInput(
                toolName: call.name,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
        return tool
    }
}

enum AgentToolRegistryError: LocalizedError, Equatable, Sendable {
    case invalidToolName(String)
    case duplicateToolName(String)
    case missingTool(String)
    case invalidInput(toolName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidToolName(let name):
            return String(format: String.l10n("agent.tool.registry.invalidNameFormat"), name)
        case .duplicateToolName(let name):
            return String(format: String.l10n("agent.tool.registry.duplicateNameFormat"), name)
        case .missingTool(let name):
            return String(format: String.l10n("agent.tool.registry.missingToolFormat"), name)
        case .invalidInput(let toolName, let message):
            return String(format: String.l10n("agent.tool.registry.invalidInputFormat"), toolName, message)
        }
    }
}
