//
//  AgentRuntimeRouterTests.swift
//  StarcatTests
//
//  多后端 Runtime 路由与能力矩阵契约测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Agent Runtime Router")
struct AgentRuntimeRouterTests {

    @Test("固定业务 Agent 即使偏好外部后端仍路由到 Loop")
    func fixedAgentStaysOnLoop() {
        let router = AgentRuntimeRouter(
            preferredBackend: .codexAppServer,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .codexAppServer: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.githubWeeklyReport) == .builtinLoop)
    }

    @Test("POC Agent 可以在 Codex 与 DeepSeek 之间切换")
    func externalAgentCanSwitchBackends() {
        let runtimes: [AgentRuntimeBackend: any AgentRuntime] = [
            .codexAppServer: EmptyRouterRuntime(),
            .deepSeekHarness: EmptyRouterRuntime(),
        ]
        let codexRouter = AgentRuntimeRouter(preferredBackend: .codexAppServer, runtimes: runtimes)
        let deepSeekRouter = AgentRuntimeRouter(preferredBackend: .deepSeekHarness, runtimes: runtimes)
        let agent = ExternalAgentPOCAgentDefinitions.general

        #expect(codexRouter.resolvedBackend(for: agent) == .codexAppServer)
        #expect(deepSeekRouter.resolvedBackend(for: agent) == .deepSeekHarness)
    }

    @Test("后端能力不把 DeepSeek rc.8 的协议缺口伪装成已支持")
    func capabilitiesPreserveProtocolDifferences() {
        #expect(AgentRuntimeCapabilities.codexAppServerPOC.supportsReliableCancellation)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsSteering)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsPersistentSession)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessRC8.supportsSteering)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessRC8.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessRC8.supportsReliableCancellation)
    }
}

private struct EmptyRouterRuntime: AgentRuntime {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { $0.finish() }
    }
}
