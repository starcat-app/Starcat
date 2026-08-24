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

    @Test("Direct Release 读取用户选择的外部 Runtime，App Store 强制回退 Loop")
    func runtimePreferenceRespectsDistributionChannel() throws {
        let suiteName = "AgentRuntimeRouterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgentRuntimeBackend.deepSeekHarness.rawValue, forKey: ExternalAgentRuntimePreferences.backendKey)

        #expect(
            ExternalAgentRuntimePreferences.selectedBackend(
                defaults: defaults,
                distributionGate: DistributionGate(channel: .direct)
            ) == .deepSeekHarness
        )
        #expect(
            ExternalAgentRuntimePreferences.selectedBackend(
                defaults: defaults,
                distributionGate: DistributionGate(channel: .appStore)
            ) == .builtinLoop
        )
    }

    @Test("产品键迁移保留旧 Runtime 配置且不覆盖新值")
    func runtimePreferenceMigratesLegacyDefaultsOnce() throws {
        let suiteName = "AgentRuntimeRouterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgentRuntimeBackend.codexAppServer.rawValue, forKey: "DebugExternalAgentRuntimeBackend")
        defaults.set("/tmp/codex", forKey: "DebugCodexExecutablePath")
        defaults.set("keep-current", forKey: ExternalAgentRuntimePreferences.codexModelKey)
        defaults.set("legacy-model", forKey: "DebugCodexModel")

        ExternalAgentRuntimePreferences.migrateLegacyDefaults(defaults)

        #expect(defaults.string(forKey: ExternalAgentRuntimePreferences.backendKey) == "codexAppServer")
        #expect(defaults.string(forKey: ExternalAgentRuntimePreferences.codexExecutablePathKey) == "/tmp/codex")
        #expect(defaults.string(forKey: ExternalAgentRuntimePreferences.codexModelKey) == "keep-current")
    }

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

    @Test("不兼容外部后端时按 Agent 契约回退默认 Runtime")
    func incompatibleExternalBackendUsesDefinitionDefault() {
        let router = AgentRuntimeRouter(
            preferredBackend: .codexAppServer,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .codexAppServer: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.untaggedTidy) == .builtinLoop)
    }

    @Test("DeepSeek 可承载只读业务 Agent")
    func deepSeekSupportsReadOnlyBusinessTools() {
        let router = AgentRuntimeRouter(
            preferredBackend: .deepSeekHarness,
            runtimes: [
                .builtinLoop: EmptyRouterRuntime(),
                .deepSeekHarness: EmptyRouterRuntime(),
            ]
        )

        #expect(router.resolvedBackend(for: BuiltInAgents.repoInsight) == .deepSeekHarness)
    }

    @Test("研究类 Loop Agent 使用 96 次工具预算，写入 Agent 保持默认预算")
    func loopToolBudgetsAreDefinitionScoped() {
        #expect(BuiltInAgents.githubWeeklyReport.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.repoInsight.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.repoAlternatives.loopMaxToolCalls == 96)
        #expect(BuiltInAgents.untaggedTidy.loopMaxToolCalls == nil)
    }

    @Test("外部 Agent 可以在 Codex 与 DeepSeek 之间切换")
    func externalAgentCanSwitchBackends() {
        let runtimes: [AgentRuntimeBackend: any AgentRuntime] = [
            .codexAppServer: EmptyRouterRuntime(),
            .deepSeekHarness: EmptyRouterRuntime(),
        ]
        let codexRouter = AgentRuntimeRouter(preferredBackend: .codexAppServer, runtimes: runtimes)
        let deepSeekRouter = AgentRuntimeRouter(preferredBackend: .deepSeekHarness, runtimes: runtimes)
        let agent = ExternalAgentDefinitions.general

        #expect(codexRouter.resolvedBackend(for: agent) == .codexAppServer)
        #expect(deepSeekRouter.resolvedBackend(for: agent) == .deepSeekHarness)
    }

    @Test("后端能力不把 DeepSeek 的协议缺口伪装成已支持")
    func capabilitiesPreserveProtocolDifferences() {
        #expect(AgentRuntimeCapabilities.codexAppServer.supportsReliableCancellation)
        #expect(!AgentRuntimeCapabilities.codexAppServer.supportsSteering)
        #expect(!AgentRuntimeCapabilities.codexAppServer.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.codexAppServer.supportsPersistentSession)
        #expect(!AgentRuntimeCapabilities.deepSeekHarness.supportsSteering)
        #expect(!AgentRuntimeCapabilities.deepSeekHarness.supportsInteractiveApproval)
        #expect(!AgentRuntimeCapabilities.deepSeekHarness.supportsReliableCancellation)
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
