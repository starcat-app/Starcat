//
//  AgentModels.swift
//  Starcat
//
//  Agent 底座的共享数据模型。
//
//  这些类型刻意保持轻量和值语义：Agent Workspace、Runtime、Artifact 预览
//  都通过它们交换状态，避免后续每个 Agent 直接绑定自己的 ViewModel 或业务 Service。
//

import Foundation

/// 内置 Agent 的静态定义。
///
/// AgentDefinition 描述“这个 Agent 能做什么”，不保存某次运行状态。这样后续新增
/// Repo Insight、Release Watcher 等 Agent 时，只需要注册新的定义与工具，不需要复制
/// Workspace UI。
struct AgentDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let capabilityLabels: [String]
    let defaultPrompt: String
    let isEnabled: Bool
}

/// 一次 Agent run 的状态。
enum AgentRunStatus: String, Sendable {
    case idle
    case planning
    case running
    case completed
    case failed
    case cancelled
}

/// 单个执行步骤的状态。
enum AgentStepStatus: String, Sendable {
    case pending
    case running
    case completed
    case failed
    case skipped
}

/// Agent 产出物类型。
enum AgentArtifactType: String, Sendable {
    case markdown
    case log

    var title: String {
        switch self {
        case .markdown:
            return "Markdown"
        case .log:
            return "Run Log"
        }
    }
}

/// Runtime 生成的执行计划步骤。
///
/// 计划步骤和时间线步骤分开保存：计划是 Agent 准备怎么做，时间线是实际做到了哪一步。
/// 后续接入真实 tool-calling 后，计划可来自模型 structured output，而时间线来自工具执行事件。
struct AgentPlanStep: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var detail: String

    init(
        id: UUID = UUID(),
        title: String,
        detail: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// Agent 时间线中的一个步骤。
struct AgentRunStep: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var detail: String
    var status: AgentStepStatus

    init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: AgentStepStatus = .pending
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// Agent 工具输出摘要。
///
/// 这里先记录 compact output,而不是完整原始数据。真实 tool-calling 接入后,完整原始响应
/// 应进入 artifact / run storage,喂回 LLM 和展示给用户的都必须是预算受控的摘要。
struct AgentToolOutput: Identifiable, Hashable, Sendable {
    let id: UUID
    var toolName: String
    var summary: String
    var detail: String
    var input: String
    var output: String
    var log: String

    init(
        id: UUID = UUID(),
        toolName: String,
        summary: String,
        detail: String,
        input: String = "",
        output: String = "",
        log: String = ""
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.input = input
        self.output = output
        self.log = log
    }
}

/// Agent 产出物。
struct AgentArtifact: Identifiable, Hashable, Sendable {
    let id: UUID
    let type: AgentArtifactType
    var title: String
    var content: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        type: AgentArtifactType,
        title: String,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.createdAt = createdAt
    }
}

/// Agent run 的上下文快照。
///
/// P0 先保存入口描述。后续接入列表多选时，把 SelectionSnapshot、筛选条件等冻结在这里，
/// 保证用户切换列表筛选不会污染正在运行或历史查看的 Agent run。
struct AgentRunContext: Hashable, Sendable {
    var sourceDescription: String

    static let empty = AgentRunContext(sourceDescription: "Agent Workspace")
}

/// Agent run 中可展开审计的一条 span。
///
/// Step / Tool / AI generation / Artifact 都统一投影成 trace span。这样 UI 不需要根据
/// 不同事件临时拼“看起来像输入输出”的文本，Runtime 和工具层也能把真实参数、结果和日志
/// 原样交给用户审查。
struct AgentTraceSpan: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: String
    var title: String
    var summary: String
    var input: String
    var output: String
    var log: String
    var status: AgentStepStatus
    var relatedStepID: UUID?
    var relatedToolOutputID: UUID?
    var relatedArtifactID: UUID?

    init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        summary: String,
        input: String,
        output: String,
        log: String,
        status: AgentStepStatus = .completed,
        relatedStepID: UUID? = nil,
        relatedToolOutputID: UUID? = nil,
        relatedArtifactID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.input = input
        self.output = output
        self.log = log
        self.status = status
        self.relatedStepID = relatedStepID
        self.relatedToolOutputID = relatedToolOutputID
        self.relatedArtifactID = relatedArtifactID
    }
}

/// Runtime 发给 Workspace 的事件。
///
/// UI 只消费事件，不直接调用 Runtime 内部状态。这样未来把 P0 deterministic runtime
/// 替换成 tool-calling runtime 或 AgentRunKit runtime 时，Workspace 不需要重写。
enum AgentRunEvent: Sendable {
    case runStarted(title: String)
    case planCreated([AgentPlanStep])
    case stepStarted(id: UUID)
    case stepUpdated(AgentRunStep)
    case toolOutput(AgentToolOutput)
    case trace(AgentTraceSpan)
    case assistantDelta(String)
    case artifactCreated(AgentArtifact)
    case runCompleted
    case runFailed(String)
    case runCancelled
}
