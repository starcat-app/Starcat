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

/// Runtime 发给 Workspace 的事件。
///
/// UI 只消费事件，不直接调用 Runtime 内部状态。这样未来把 P0 deterministic runtime
/// 替换成 tool-calling runtime 或 AgentRunKit runtime 时，Workspace 不需要重写。
enum AgentRunEvent: Sendable {
    case runStarted(title: String)
    case stepStarted(id: UUID)
    case stepUpdated(AgentRunStep)
    case assistantDelta(String)
    case artifactCreated(AgentArtifact)
    case runCompleted
    case runFailed(String)
    case runCancelled
}
