//
//  AgentRuntimeFactory.swift
//  Starcat
//
//  工作台与公共 API 共用运行器装配。模型、知识检索、工具写入与持久化的业务约束
//  保留在既有 Runtime/Capability；传输入口不能自行裁剪成另一套 Agent 实现。
//

import Foundation

extension AppDependencies {
    /// 选择信息由调用方冻结；已经启动的 run 持有该实例，不随设置变更而替换。
    func makeWorkspaceAgentRuntime(
        modelID: String?, backend: AgentRuntimeBackend, modelName: String?, reasoningEffort: String?,
        mode: AgentExecutionMode, localeIdentifier: String, preferredLanguage: String
    ) -> any AgentRuntime {
        let externalSearch = ExternalSearchAgentTool(collector: AppSettingsAgentExternalSearchCollector(settings: settings))
        let searcher: any AgentKnowledgeSearching
        do {
            searcher = try makeAgentKnowledgeCapabilityAdapter(selectedModelID: modelID)
        } catch {
            // 可选知识能力配置失败不能阻止其余工具工作，与工作台现有降级语义一致。
            AppLog.ai.warning("Agent knowledge tool unavailable: \(error.localizedDescription, privacy: .public)")
            searcher = UnavailableAgentKnowledgeSearcher()
        }
        var runtimes: [AgentRuntimeBackend: any AgentRuntime] = [:]
        let registry: AgentToolRegistry?
        do {
            registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: externalSearch,
                knowledgeTool: AgentKnowledgeTool(searcher: searcher),
                additionalTools: UntaggedTidyAgentTools.make(executor: makeRepositoryTagCapability())
            ))
        } catch {
            registry = nil
            runtimes[.builtinLoop] = UnavailableAgentRuntime(message: error.localizedDescription)
        }
        if let registry {
            do {
                runtimes[.builtinLoop] = LoopAgentRuntime(
                    modelClient: try AgentLoopModelClientFactory.make(settings: settings, selectedModelID: modelID),
                    toolRegistry: registry, runRepository: agentRunRepository, mode: mode,
                    localeIdentifier: localeIdentifier, preferredLanguage: preferredLanguage,
                    externalSearchPolicy: AgentExternalSearchPolicy.current(settings: settings)
                )
            } catch {
                runtimes[.builtinLoop] = UnavailableAgentRuntime(message: error.localizedDescription)
            }
        }
        if backend != .builtinLoop {
            do {
                runtimes[backend] = ExternalAgentRuntime(
                    adapter: try ExternalAgentRuntimePreferences.makeAdapter(backend: backend, settings: settings),
                    distributionGate: distributionGate, selectedModelName: modelName, reasoningEffort: reasoningEffort,
                    localeIdentifier: localeIdentifier, preferredLanguage: preferredLanguage,
                    toolRegistry: registry, runRepository: agentRunRepository,
                    mcpBridgeFactory: { toolSet in try await self.mcpService.makeTransientBridge(toolSet: toolSet) }
                )
            } catch {
                runtimes[backend] = UnavailableAgentRuntime(message: error.localizedDescription)
            }
        }
        return AgentRuntimeRouter(preferredBackend: backend, runtimes: runtimes)
    }
}
