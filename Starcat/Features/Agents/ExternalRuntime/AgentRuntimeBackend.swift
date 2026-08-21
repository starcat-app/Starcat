//
//  AgentRuntimeBackend.swift
//  Starcat
//
//  Agent Runtime 后端声明、能力矩阵与路由器。
//
//  后端选择属于 AgentDefinition 的声明式契约，不允许 Workspace 根据 Agent ID
//  临时分支。这样固定业务 Agent 可以继续锁定 Loop，而 General / Research POC
//  可以在 Codex App Server 与 DeepSeek Harness 之间切换。
//

import Foundation

/// Starcat 当前可识别的 Agent 执行后端。
enum AgentRuntimeBackend: String, CaseIterable, Codable, Hashable, Sendable {
    case builtinLoop
    case codexAppServer
    case deepSeekHarness

    var displayName: String {
        switch self {
        case .builtinLoop: return "LoopAgentRuntime"
        case .codexAppServer: return "Codex App Server"
        case .deepSeekHarness: return "DeepSeek Harness"
        }
    }
}

/// UI 和产品层只能依据能力矩阵展示操作，不能假设所有外部后端协议等价。
struct AgentRuntimeCapabilities: Equatable, Sendable {
    var supportsResume: Bool
    var supportsSteering: Bool
    var supportsInteractiveApproval: Bool
    var supportsFileDiff: Bool
    var supportsSubagents: Bool
    var supportsPersistentSession: Bool
    var supportsReliableCancellation: Bool

    static let builtinLoop = AgentRuntimeCapabilities(
        supportsResume: true,
        supportsSteering: false,
        supportsInteractiveApproval: true,
        supportsFileDiff: false,
        supportsSubagents: false,
        supportsPersistentSession: true,
        supportsReliableCancellation: true
    )

    static let codexAppServerPOC = AgentRuntimeCapabilities(
        supportsResume: false,
        supportsSteering: false,
        supportsInteractiveApproval: false,
        supportsFileDiff: false,
        supportsSubagents: false,
        supportsPersistentSession: false,
        supportsReliableCancellation: true
    )

    /// rc.8 的 stdio JSON-RPC 没有 cancel、session close 和双向 approval。
    static let deepSeekHarnessRC8 = AgentRuntimeCapabilities(
        supportsResume: false,
        supportsSteering: false,
        supportsInteractiveApproval: false,
        supportsFileDiff: false,
        supportsSubagents: false,
        supportsPersistentSession: false,
        supportsReliableCancellation: false
    )
}

/// 单个 Agent 允许使用哪些后端，以及没有用户偏好时选择哪个后端。
struct AgentRuntimePolicy: Hashable, Sendable {
    var allowedBackends: Set<AgentRuntimeBackend>
    var defaultBackend: AgentRuntimeBackend

    init(allowedBackends: Set<AgentRuntimeBackend>, defaultBackend: AgentRuntimeBackend) {
        precondition(allowedBackends.contains(defaultBackend), "Default runtime must be allowed")
        self.allowedBackends = allowedBackends
        self.defaultBackend = defaultBackend
    }

    static let builtinOnly = AgentRuntimePolicy(
        allowedBackends: [.builtinLoop],
        defaultBackend: .builtinLoop
    )

    static let externalPOC = AgentRuntimePolicy(
        allowedBackends: [.codexAppServer, .deepSeekHarness],
        defaultBackend: .codexAppServer
    )
}

/// 把 Workspace 与具体 Runtime 解耦，并保持现有 `AgentRuntime` 协议不变。
///
/// Router 每次 run 都按 definition 的 policy 解析后端。命令广播给已装配的 Runtime：
/// `AgentRunCommand` 自带 runID，非目标 Runtime 会安全忽略；这样无需为 POC 扩数据库或
/// 修改公共命令协议来保存 runID → backend 映射。
struct AgentRuntimeRouter: AgentRuntime {
    let preferredBackend: AgentRuntimeBackend
    let runtimes: [AgentRuntimeBackend: any AgentRuntime]

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        resolvedRuntime(for: definition).run(
            definition: definition,
            prompt: prompt,
            context: context
        )
    }

    func resumePendingRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        resolvedRuntime(for: definition).resumePendingRun(snapshot: snapshot, definition: definition)
    }

    func retryFailedRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        resolvedRuntime(for: definition).retryFailedRun(snapshot: snapshot, definition: definition)
    }

    func send(_ command: AgentRunCommand) async {
        for runtime in runtimes.values {
            await runtime.send(command)
        }
    }

    func resolvedBackend(for definition: AgentDefinition) -> AgentRuntimeBackend? {
        let policy = definition.runtimePolicy
        if policy.allowedBackends.contains(preferredBackend), runtimes[preferredBackend] != nil {
            return preferredBackend
        }
        if runtimes[policy.defaultBackend] != nil {
            return policy.defaultBackend
        }
        return nil
    }

    private func resolvedRuntime(for definition: AgentDefinition) -> any AgentRuntime {
        guard let backend = resolvedBackend(for: definition), let runtime = runtimes[backend] else {
            return UnavailableAgentRuntime(
                message: "No available runtime for \(definition.title)."
            )
        }
        return runtime
    }
}
