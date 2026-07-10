//
//  AgentRuntime.swift
//  Starcat
//
//  Agent Runtime 公共协议与未配置占位实现。
//
//  生产工作台在依赖注入完成后使用 `LoopAgentRuntime`。ViewModel 初始化期只使用
//  `UnavailableAgentRuntime`，它不会生成 demo 步骤、假产出物或人为延迟。
//

import Foundation

protocol AgentRuntime: Sendable {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent>
    func send(_ command: AgentRunCommand) async
}

extension AgentRuntime {
    func send(_ command: AgentRunCommand) async {}
}

struct UnavailableAgentRuntime: AgentRuntime {
    private let message: String

    init(message: String = AgentLoopModelError.missingProvider.localizedDescription) {
        self.message = message
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            continuation.yield(.runFailed(message))
            continuation.finish()
        }
    }
}
