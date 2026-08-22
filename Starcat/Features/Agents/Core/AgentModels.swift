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
import CryptoKit

/// Agent 如何取得业务仓库上下文。
///
/// 这是 Agent 工作流契约，不是 RAG 检索范围：Weekly 按时间窗口读取公共周报缓存，
/// Repo Insight 要求单仓目标；Star 和知识库都不能成为 Agent 的全局准入条件。
enum AgentRepositoryContextPolicy: Hashable, Sendable {
    case none
    /// Weekly Report 从 Weekly 多来源缓存冻结最近时间窗，不依赖用户是否 Star。
    case weeklyHotspots(days: Int)
    case singleRepository
    /// 写入型工作流只允许操作用户在 Composer 中明确选择并冻结的仓库集合。
    case selectedRepositories
}

/// 内置 Agent 的声明式运行策略。
struct AgentWorkflowPolicy: Hashable, Sendable {
    var repositoryContext: AgentRepositoryContextPolicy
    var executionMode: AgentExecutionMode
    var allowsManualRepositoryOverride: Bool
    var allowsEmptyRepositoryContext: Bool
    var usesDefaultPromptWhenEmpty: Bool
    var maximumSelectedRepositories: Int

    static let general = AgentWorkflowPolicy(
        repositoryContext: .none,
        executionMode: .readonlyPlanning,
        allowsManualRepositoryOverride: false,
        allowsEmptyRepositoryContext: true,
        usesDefaultPromptWhenEmpty: false,
        maximumSelectedRepositories: 0
    )
}

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
    /// 上下文来源、目标基数和执行权限必须由定义声明，Runtime/UI 不再按 Agent ID 猜测。
    let workflow: AgentWorkflowPolicy
    /// 注入 system prompt 的 Agent 专属规则；Runtime 只消费声明，不按 Agent ID 分支。
    let promptRules: [AgentPromptRule]
    /// 最终 Artifact 在 Inspector 中显示的标题；nil 时使用 Agent 标题。
    let artifactTitle: String?
    /// Runtime 路由契约。默认锁定进程内 Loop，外部 POC Agent 必须显式声明可用后端。
    let runtimePolicy: AgentRuntimePolicy
    /// 仅覆盖进程内 Loop 的工具调用预算；外部 Runtime 使用各自的会话预算与协议限制。
    let loopMaxToolCalls: Int?
    /// 模型在当前 Agent 中可见的工具 allowlist；数组顺序不代表执行顺序。
    let toolIDs: [String]
    /// 通过外部 Runtime 自带 MCP client 暴露的 Starcat 工具 allowlist。
    ///
    /// 它与 `toolIDs` 分开：前者由 Starcat Host 双向协议执行，后者由 Runtime
    /// 连接每轮临时 MCP Server 执行，不能用同一名称空间假装两种协议等价。
    let externalMCPToolIDs: [String]
    let artifactTypes: [AgentArtifactType]

    init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        capabilityLabels: [String],
        defaultPrompt: String,
        isEnabled: Bool,
        workflow: AgentWorkflowPolicy = .general,
        promptRules: [AgentPromptRule] = [],
        artifactTitle: String? = nil,
        runtimePolicy: AgentRuntimePolicy = .builtinOnly,
        loopMaxToolCalls: Int? = nil,
        toolIDs: [String] = [],
        externalMCPToolIDs: [String] = [],
        artifactTypes: [AgentArtifactType] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.capabilityLabels = capabilityLabels
        self.defaultPrompt = defaultPrompt
        self.isEnabled = isEnabled
        self.workflow = workflow
        self.promptRules = promptRules
        self.artifactTitle = artifactTitle
        self.runtimePolicy = runtimePolicy
        self.loopMaxToolCalls = loopMaxToolCalls
        self.toolIDs = toolIDs
        self.externalMCPToolIDs = externalMCPToolIDs
        self.artifactTypes = artifactTypes
    }
}

/// 一次 Agent run 的状态。
enum AgentRunStatus: String, Codable, Hashable, Sendable {
    case idle
    case planning
    case running
    case waitingForConfirmation
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
enum AgentArtifactType: String, Codable, Hashable, Sendable {
    case markdown
    case log

    var title: String {
        switch self {
        case .markdown:
            return String.l10n("agent.artifact.type.markdown")
        case .log:
            return String.l10n("agent.artifact.type.log")
        }
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
    var toolCallID: String?
    var messageID: UUID?
    var sequence: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        type: AgentArtifactType,
        title: String,
        content: String,
        toolCallID: String? = nil,
        messageID: UUID? = nil,
        sequence: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.content = content
        self.toolCallID = toolCallID
        self.messageID = messageID
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

/// Agent run 的上下文快照。
///
/// run 开始时冻结上下文，而不是让 Runtime 持有列表的 live binding。这样用户在 Agent
/// 执行过程中切换筛选、刷新列表或打开别的窗口，都不会污染当前 run 的审计记录。
struct AgentRunContext: Codable, Hashable, Sendable {
    var sourceDescription: String
    var generatedAt: Date
    var repos: [AgentRepoSnapshot]
    var attachments: [AgentPromptAttachment]
    var failureReason: String?
    /// 以下字段均为 optional，确保 v19 之前已经写入的 context JSON 仍可直接解码。
    var explicitRepos: [AIComposerRepoReference]?
    var explicitRepoMode: AIComposerExplicitRepoMode?
    var selectedModelID: String?
    /// Runtime 字段保持 optional，确保新增前已经落库的 context JSON 可继续解码。
    var runtimeBackend: AgentRuntimeBackend?
    var runtimeModelName: String?
    var runtimeReasoningEffort: String?
    var githubLinks: [AIComposerGitHubLink]?
    var webSearchEnabled: Bool?
    /// 业务上下文中已经进入知识库的仓库 ID。nil 仅代表旧快照，需兼容旧运行记录。
    var knowledgeEligibleRepoIDs: [Int64]?

    init(
        sourceDescription: String,
        generatedAt: Date = Date(),
        repos: [AgentRepoSnapshot] = [],
        attachments: [AgentPromptAttachment] = [],
        failureReason: String? = nil,
        explicitRepos: [AIComposerRepoReference]? = nil,
        explicitRepoMode: AIComposerExplicitRepoMode? = nil,
        selectedModelID: String? = nil,
        runtimeBackend: AgentRuntimeBackend? = nil,
        runtimeModelName: String? = nil,
        runtimeReasoningEffort: String? = nil,
        githubLinks: [AIComposerGitHubLink]? = nil,
        webSearchEnabled: Bool? = nil,
        knowledgeEligibleRepoIDs: [Int64]? = nil
    ) {
        self.sourceDescription = sourceDescription
        self.generatedAt = generatedAt
        self.repos = repos
        self.attachments = attachments
        self.failureReason = failureReason
        self.explicitRepos = explicitRepos
        self.explicitRepoMode = explicitRepoMode
        self.selectedModelID = selectedModelID
        self.runtimeBackend = runtimeBackend
        self.runtimeModelName = runtimeModelName
        self.runtimeReasoningEffort = runtimeReasoningEffort
        self.githubLinks = githubLinks
        self.webSearchEnabled = webSearchEnabled
        self.knowledgeEligibleRepoIDs = knowledgeEligibleRepoIDs
    }

    static let empty = AgentRunContext(sourceDescription: "Agent Workspace")

    /// 数据库只保留附件名称、大小和摘要；正文仅在当前 Runtime 内存中存活。
    var persistenceSnapshot: AgentRunContext {
        var snapshot = self
        snapshot.attachments = attachments.map(\.persistenceSnapshot)
        return snapshot
    }

    /// App 重启后附件正文无法恢复；审批中的 run 必须据此阻止继续执行旧工具链。
    var hasUnavailableAttachmentBodies: Bool {
        attachments.contains { attachment in
            attachment.content.isEmpty && (attachment.originalByteCount ?? 0) > 0
        }
    }
}

/// Composer 在点击发送时冻结的不可变输入。
///
/// Context Provider 只读取这份值快照，不再读取正在变化的 SwiftUI 状态，因此切换 Agent、
/// 修改仓库范围或关闭联网都不会反向污染已经启动的 run。
struct AgentRunInput: Hashable, Sendable {
    var goal: String
    var agentID: String
    var explicitRepos: [AIComposerRepoReference]
    var explicitRepoMode: AIComposerExplicitRepoMode
    var selectedModelID: String?
    var attachments: [AgentPromptAttachment]
    var githubLinks: [AIComposerGitHubLink]
    var webSearchEnabled: Bool
    var source: String
    var runtimeBackend: AgentRuntimeBackend? = nil
    var runtimeModelName: String? = nil
    var runtimeReasoningEffort: String? = nil
}

/// 用户显式附加到一次 run 的 UTF-8 文本快照。
///
/// 只保存文件名和内容，不保存本地绝对路径；历史审计可以回放输入，但不会把用户目录
/// 结构泄露给模型或写入数据库。
struct AgentPromptAttachment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var content: String
    /// UTType identifier；optional 让旧版 context JSON 保持可解码。
    var contentType: String?
    var originalByteCount: Int?
    var contentHash: String?

    init(
        id: UUID = UUID(),
        name: String,
        content: String,
        contentType: String? = nil,
        originalByteCount: Int? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.contentType = contentType
        self.originalByteCount = originalByteCount
        self.contentHash = contentHash
    }

    var byteCount: Int { originalByteCount ?? content.utf8.count }

    var persistenceSnapshot: AgentPromptAttachment {
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        return AgentPromptAttachment(
            id: id,
            name: name,
            content: "",
            contentType: contentType,
            originalByteCount: byteCount,
            contentHash: contentHash ?? digest
        )
    }
}

/// Agent 可消费的仓库快照。
///
/// 这里只保留生成周刊需要的稳定字段，避免把完整 `Repo` 行直接塞进 Runtime。后续要补
/// README / note / tag 时，也应继续通过快照字段扩展，而不是让工具层读取 UI 状态。
struct AgentRepoSnapshot: Codable, Identifiable, Hashable, Sendable {
    let id: Int64
    var owner: String
    var name: String
    var fullName: String
    var description: String?
    var language: String?
    var starsCount: Int
    var topics: [String]
    var isPrivate: Bool
    var isStarred: Bool
    var starredAt: String?
    var htmlUrl: String
    /// 数据来源由 Agent 目录冻结；旧 run 没有该字段时保持 nil，兼容历史持久化快照。
    var sourceIDs: [String]? = nil
    /// 多来源目录首次/最近观察时间。Weekly Report 用它解释热点时间窗，而不是 Star 时间。
    var firstObservedAt: String? = nil
    var latestObservedAt: String? = nil

    var displaySummary: String {
        let languagePart = language.map { " · \($0)" } ?? ""
        let sourcePart = sourceIDs.map { values in
            values.isEmpty ? "" : " · \(values.joined(separator: ", "))"
        } ?? ""
        return String(
            format: String.l10n("agent.repoSnapshot.summaryFormat"),
            fullName,
            languagePart + sourcePart,
            starsCount
        )
    }
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
/// UI 只消费事件，不直接调用 Runtime 内部状态。这样未来把本地 read-only tools
/// 替换成模型 tool-calling runtime 或 AgentRunKit runtime 时，Workspace 不需要重写。
enum AgentRunEvent: Sendable {
    case runStarted(title: String)
    case traceUpdated(AgentTraceEvent)
    case approvalUpdated(AgentApprovalRequest)
    case messageAppended(AgentMessage)
    case usageUpdated(AgentUsage)
    case assistantReasoningDelta(String)
    case assistantDelta(String)
    case artifactCreated(AgentArtifact)
    case runCompleted
    case runFailed(String)
    case runCancelled
}
