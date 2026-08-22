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

    @Test("Codex 选择会路由支持只读工具的业务 Agent")
    func readOnlyBusinessAgentUsesCodex() {
        let router = AgentRuntimeRouter(
            preferredBackend: .codexAppServer,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .codexAppServer: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.githubWeeklyReport) == .codexAppServer)
    }

    @Test("不兼容外部后端时不静默回退 Loop")
    func incompatibleExternalBackendDoesNotFallback() {
        let router = AgentRuntimeRouter(
            preferredBackend: .codexAppServer,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .codexAppServer: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.untaggedTidy) == nil)
    }

    @Test("DeepSeek 尚不承载 Starcat 只读业务工具")
    func deepSeekDoesNotPretendToSupportBusinessTools() {
        let router = AgentRuntimeRouter(
            preferredBackend: .deepSeekHarness,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .deepSeekHarness: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.repoInsight) == nil)
    }

    @Test("研究类 Loop Agent 使用 96 次工具预算，写入 Agent 保持默认预算")
    func loopToolBudgetsAreDefinitionScoped() {
        #expect(BuiltInAgents.githubWeeklyReport.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.repoInsight.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.repoAlternatives.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.untaggedTidy.loopMaxToolCalls == nil)
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

    @Test("后端能力不把 DeepSeek POC 的协议缺口伪装成已支持")
    func capabilitiesPreserveProtocolDifferences() {
        #expect(AgentRuntimeCapabilities.codexAppServerPOC.supportsReliableCancellation)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsSteering)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.codexAppServerPOC.supportsPersistentSession)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessPOC.supportsSteering)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessPOC.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.deepSeekHarnessPOC.supportsReliableCancellation)
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
