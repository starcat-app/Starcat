//
//  StarcatMCPAgentOperations.swift
//  Starcat
//
//  Agent 任务公共适配。运行器、上下文、事件流、审批和落库与 App 工作台共用，
//  不打开窗口；审批是任务内容的一部分，不增加 MCP 设置权限。
//

import Foundation
import MCP

extension StarcatMCPPublicCatalog {
    static let agentSpecs: [StarcatMCPPublicSpec] = [
        .init(name: "list_agents", summary: "List App Agent definitions and supported runtime backends.", properties: [:]),
        .init(name: "get_agent_run", summary: "Read a persisted Agent run, messages, approvals and artifacts by run UUID.", properties: ["id": string()], required: ["id"]),
        .init(name: "start_agent_run", summary: "Run an App Agent with the same runtime factory, context and persistence as the workspace. Poll get_agent_execution for pending workflow approvals.", properties: preview.merging([
            "agent_id": string(), "goal": string(), "repo_ids": ids, "model_id": string(),
            "backend": string(AgentRuntimeBackend.allCases.map(\.rawValue)), "model": string(),
            "provider": string(), "reasoning_effort": string()
        ]) { _, new in new }, required: ["agent_id", "goal"], permission: "write", network: "configured_agent_runtime", task: true),
        .init(name: "get_agent_execution", summary: "Read a retained public Agent task's runtime status, workflow approvals and artifacts.", properties: ["task_id": string()], required: ["task_id"]),
        .init(name: "respond_agent_approval", summary: "Approve or reject an existing Agent workflow request through the App's runtime. Uses the same write access as other changes.", properties: preview.merging([
            "task_id": string(), "id": string(), "approved": boolean
        ]) { _, new in new }, required: ["task_id", "id", "approved"], permission: "write")
    ]
}

extension StarcatMCPPublicFacade {
    /// 仅保存公共任务对应的工作台对象；任务过期或切号后释放，历史仍由原 Repository 保存。
    func callAgentOperation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        for id in Array(agentExecutions.keys) where (try? tasks.status(id: id)) == nil { agentExecutions.removeValue(forKey: id) }
        let definitions = app.distributionGate.isAvailable(.externalAgentRuntime) ? ExternalAgentDefinitions.all + BuiltInAgents.all : BuiltInAgents.all
        switch name {
        case "list_agents":
            return .array(definitions.map { definition in
                .object(["id": .string(definition.id), "title": .string(definition.title), "enabled": .bool(definition.isEnabled),
                         "backends": .array(definition.runtimePolicy.allowedBackends.map(\.rawValue).sorted().map(Value.string))])
            })
        case "list_agent_runs":
            let limit = arguments["limit"]?.intValue ?? 20
            let offset = arguments["offset"]?.intValue ?? 0
            let rows = try await app.agentRunRepository.recentRuns(limit: offset + limit + 1)
            return .object(["items": .array(try rows.dropFirst(offset).prefix(limit).map(StarcatMCPJSON.value)),
                            "has_more": .bool(rows.count > offset + limit),
                            "next_offset": rows.count > offset + limit ? .int(offset + limit) : .null])
        case "get_agent_run":
            guard let id = arguments["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let snapshot = try await app.agentRunRepository.snapshot(runID: id) else { throw StarcatMCPError.notFound("Agent run not found.") }
            return .object([
                "run": try StarcatMCPJSON.value(snapshot.run),
                "messages": .array(try snapshot.messages.map { try StarcatMCPJSON.value(AgentMessageRecord(message: $0)) }),
                "approvals": try StarcatMCPJSON.value(snapshot.approvals),
                "artifacts": Self.agentArtifacts(snapshot.artifacts)
            ])
        case "get_agent_execution", "respond_agent_approval":
            let id = arguments["task_id"]?.stringValue ?? ""
            guard let model = agentExecutions[id] else { throw StarcatMCPError.notFound("Agent execution expired or unavailable.") }
            if name == "respond_agent_approval" {
                guard let request = model.approvals.first(where: { $0.id.uuidString.caseInsensitiveCompare(arguments["id"]?.stringValue ?? "") == .orderedSame }),
                      request.status == .pending else { throw StarcatMCPError.notFound("Pending approval not found.") }
                if arguments["dry_run"]?.boolValue ?? true { return preview(name, target: .string(request.id.uuidString)) }
                if arguments["approved"]?.boolValue == true { model.approve(request) }
                else { model.reject(request) }
            }
            return .object([
                "task": try tasks.status(id: id), "runtime_status": .string(model.status.rawValue),
                "run_id": model.executionRunID.map { .string($0.uuidString) } ?? .null,
                "approvals": try StarcatMCPJSON.value(model.approvals), "artifacts": Self.agentArtifacts(model.artifacts)
            ])
        case "start_agent_run":
            guard let definition = definitions.first(where: { $0.id == arguments["agent_id"]?.stringValue && $0.isEnabled }) else { throw StarcatMCPError.notFound("Enabled Agent not found.") }
            let goal = try nonBlank(arguments, key: "goal")
            let requestedBackend = arguments["backend"]?.stringValue.flatMap(AgentRuntimeBackend.init(rawValue:)) ?? .builtinLoop
            let backend = definition.runtimePolicy.resolvedBackend(for: requestedBackend)
            let model = AgentWorkspaceViewModel(agents: definitions)
            model.selectAgent(definition)
            model.configureModelOptions(app.knowledgeRAGChatModels, defaultProviderID: app.settings.aiChatTask.providerID, defaultModelName: app.settings.aiChatTask.resolvedModelName)
            if let selected = arguments["model_id"]?.stringValue { model.selectedModelID = selected }
            for value in arguments["repo_ids"]?.arrayValue ?? [] {
                let repo = try await resolve(["repo_id": value], app: app)
                model.selectedRepoContexts.append(.init(id: repo.id, owner: repo.owner, name: repo.name, fullName: repo.fullName, language: repo.language, starsCount: repo.starsCount))
            }
            model.prompt = goal
            model.configureRuntimeSelection(backend: backend, providerName: arguments["provider"]?.stringValue,
                                            modelName: arguments["model"]?.stringValue, reasoningEffort: arguments["reasoning_effort"]?.stringValue)
            let catalog = GRDBAgentRepositoryCatalog(database: app.database)
            model.configureContextProvider(RepositoryAgentRunContextProvider(repoRepository: app.repoRepository, repositoryCatalog: catalog))
            model.configureRunRepository(app.agentRunRepository)
            model.configureRuntime(app.makeWorkspaceAgentRuntime(
                modelID: model.selectedModelID, backend: backend, modelName: arguments["model"]?.stringValue,
                reasoningEffort: arguments["reasoning_effort"]?.stringValue, mode: definition.workflow.executionMode,
                localeIdentifier: Locale.current.identifier, preferredLanguage: Locale(identifier: "en").localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
            ))
            guard model.canSubmit else { throw StarcatMCPError.invalidArguments("Check the Agent's required repository context, backend and configured model.") }
            if arguments["dry_run"]?.boolValue ?? true { return preview(name, target: .object(["agent_id": .string(definition.id), "backend": .string(backend.rawValue)])) }
            let result = try tasks.start(kind: name) {
                try await model.runAndWait()
                return .object(["runtime_status": .string(model.status.rawValue), "run_id": model.executionRunID.map { .string($0.uuidString) } ?? .null,
                                "artifacts": Self.agentArtifacts(model.artifacts)])
            }
            if let taskID = result.objectValue?["task_id"]?.stringValue { agentExecutions[taskID] = model }
            return result
        default: throw StarcatMCPError.unsupported("Unknown Agent operation.")
        }
    }

    /// 产物直接返回内容，调用方决定保存路径；不让 App 写到远端 CLI 的文件路径。
    static func agentArtifacts(_ artifacts: [AgentArtifact]) -> Value {
        .array(artifacts.map { .object(["id": .string($0.id.uuidString), "type": .string($0.type.rawValue), "title": .string($0.title), "content": .string($0.content)]) })
    }
}
