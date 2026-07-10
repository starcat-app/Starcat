//
//  LoopAgentRuntime.swift
//  Starcat
//
//  模型驱动的 Agent tool-calling 循环。
//
//  与旧固定 toolIDs 顺序不同，`toolIDs` 在这里仅作为工具可见性 allowlist。模型每轮
//  自主选择工具，宿主校验参数与权限后执行，并把每个 tool-result 回灌下一轮，直到模型
//  返回无 tool-call 的最终答复或 Session 预算终止运行。
//

import Foundation

enum LoopAgentRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case emptyModelResponse
    case requiredArtifactMissing
    case approvalRequired(String)

    var errorDescription: String? {
        switch self {
        case .emptyModelResponse:
            return String.l10n("agent.loop.error.emptyModelResponse")
        case .requiredArtifactMissing:
            return String.l10n("agent.loop.error.requiredArtifactMissing")
        case .approvalRequired(let toolName):
            return String(format: String.l10n("agent.loop.error.approvalRequiredFormat"), toolName)
        }
    }
}

private actor AgentRuntimeSessionRouter {
    private var activeSession: AgentRunSession?

    func activate(_ session: AgentRunSession) {
        activeSession = session
    }

    func deactivate(runID: UUID) async {
        guard let activeSession, activeSession.runID == runID else { return }
        self.activeSession = nil
    }

    func send(_ command: AgentRunCommand) async -> Bool {
        guard let activeSession else { return false }
        return await activeSession.apply(command)
    }
}

struct LoopAgentRuntime: AgentRuntime {
    private let modelClient: any AgentLoopModelClient
    private let promptBuilder: any AgentPromptBuilding
    private let toolRegistry: AgentToolRegistry
    private let runRepository: (any AgentRunRepositoryProtocol)?
    private let limits: AgentRunLimits
    private let mode: AgentExecutionMode
    private let localeIdentifier: String
    private let preferredLanguage: String
    private let externalSearchPolicy: AgentExternalSearchPolicy
    private let rules: [AgentPromptRule]
    private let sessionRouter = AgentRuntimeSessionRouter()
    private let approvalCoordinator = AgentApprovalCoordinator()

    init(
        modelClient: any AgentLoopModelClient,
        promptBuilder: any AgentPromptBuilding = AgentPromptBuilder(),
        toolRegistry: AgentToolRegistry,
        runRepository: (any AgentRunRepositoryProtocol)? = nil,
        limits: AgentRunLimits = AgentRunLimits(),
        mode: AgentExecutionMode = .reportGeneration,
        localeIdentifier: String = "zh-Hans",
        preferredLanguage: String = "Simplified Chinese",
        externalSearchPolicy: AgentExternalSearchPolicy = .init(
            isEnabled: false,
            provider: "disabled",
            allowsPrivateRepositories: false,
            aggregatesProviders: false
        ),
        rules: [AgentPromptRule] = []
    ) {
        self.modelClient = modelClient
        self.promptBuilder = promptBuilder
        self.toolRegistry = toolRegistry
        self.runRepository = runRepository
        self.limits = limits
        self.mode = mode
        self.localeIdentifier = localeIdentifier
        self.preferredLanguage = preferredLanguage
        self.externalSearchPolicy = externalSearchPolicy
        self.rules = rules
    }

    func send(_ command: AgentRunCommand) async {
        guard await sessionRouter.send(command) else { return }
        _ = await approvalCoordinator.resolve(command)
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let runID = UUID()
            let session = AgentRunSession(runID: runID, limits: limits)
            let task = Task {
                await sessionRouter.activate(session)
                do {
                    try await execute(
                        runID: runID,
                        session: session,
                        definition: definition,
                        prompt: prompt,
                        context: context,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    await finishCancelled(runID: runID, session: session, continuation: continuation)
                } catch {
                    await finishFailed(
                        runID: runID,
                        session: session,
                        message: Self.errorMessage(error),
                        continuation: continuation
                    )
                }
                await sessionRouter.deactivate(runID: runID)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    let command = AgentRunCommand.cancel(runID: runID)
                    if await sessionRouter.send(command) {
                        _ = await approvalCoordinator.resolve(command)
                    }
                }
            }
        }
    }

    func resumePendingRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            guard snapshot.run.status == AgentRunStatus.waitingForConfirmation.rawValue,
                  let runID = UUID(uuidString: snapshot.run.id),
                  let pendingApproval = snapshot.approvals.last(where: { $0.status == .pending })
            else {
                continuation.yield(.runFailed(String.l10n("agent.loop.error.noPendingApproval")))
                continuation.finish()
                return
            }

            let session: AgentRunSession
            do {
                session = try AgentRunSession(
                    restoring: snapshot,
                    pendingApproval: pendingApproval,
                    limits: limits
                )
            } catch {
                continuation.yield(.runFailed(Self.errorMessage(error)))
                continuation.finish()
                return
            }

            let task = Task {
                await sessionRouter.activate(session)
                do {
                    try await execute(
                        runID: runID,
                        session: session,
                        definition: definition,
                        prompt: snapshot.run.userPrompt,
                        context: snapshot.context,
                        restoration: snapshot,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    await finishCancelled(runID: runID, session: session, continuation: continuation)
                } catch {
                    await finishFailed(
                        runID: runID,
                        session: session,
                        message: Self.errorMessage(error),
                        continuation: continuation
                    )
                }
                await sessionRouter.deactivate(runID: runID)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    let command = AgentRunCommand.cancel(runID: runID)
                    if await sessionRouter.send(command) {
                        _ = await approvalCoordinator.resolve(command)
                    }
                }
            }
        }
    }

    private func execute(
        runID: UUID,
        session: AgentRunSession,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext,
        restoration: AgentRunSnapshotRecord? = nil,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let allowedTools = try toolRegistry.tools(named: definition.toolIDs)
        let toolDefinitions = allowedTools.map(\.definition)
        let promptContext = AgentPromptContext(
            definition: definition,
            runContext: context,
            availableTools: toolDefinitions.map {
                AgentPromptToolSummary(name: $0.name, description: $0.description, permission: $0.permission)
            },
            rules: rules + definitionRules(definition) + artifactRules(toolDefinitions),
            preferredLanguage: preferredLanguage,
            externalSearch: externalSearchPolicy
        )
        let environment = AgentPromptEnvironment.current(
            mode: mode,
            locale: Locale(identifier: localeIdentifier)
        )
        var payload: AgentToolPayload = .none
        var values = Self.restoredValues(from: restoration?.messages ?? [])
        var artifactCount = restoration?.artifacts.count ?? 0

        if let restoration {
            continuation.yield(.runStarted(title: definition.title))
            let restored = try await resolveRestoredApproval(
                snapshot: restoration,
                runID: runID,
                session: session,
                prompt: prompt,
                context: context,
                values: values,
                continuation: continuation
            )
            let resultMessage = AgentToolResultMessage(
                toolCallID: restored.call.id,
                toolName: restored.call.name,
                output: restored.execution.output,
                isError: restored.execution.status != .completed && restored.execution.status != .skipped,
                status: restored.execution.status,
                elapsedMilliseconds: restored.execution.elapsedMilliseconds,
                sources: restored.execution.sources,
                sequence: restored.call.sequence
            )
            let toolMessage = try await session.append(
                role: .tool,
                turn: restored.turn,
                parts: [.toolResult(resultMessage)]
            )
            try await persistMessage(toolMessage, runStatus: .running)
            continuation.yield(.messageAppended(toolMessage))
            if let result = restored.execution.result {
                applyPayload(result.payload, payload: &payload, values: &values)
                emitLegacyToolEvents(result, continuation: continuation)
            }
        } else {
            let initialRequest = promptBuilder.buildTurnRequest(
                userInput: prompt,
                messages: [],
                environment: environment,
                context: promptContext
            )
            try await persistCreateRun(
                runID: runID,
                definition: definition,
                prompt: prompt,
                context: context
            )
            await persistRunStatus(runID: runID, status: .running)
            continuation.yield(.runStarted(title: definition.title))

            let userMessage = try await session.append(
                role: .user,
                turn: 0,
                parts: [.text(initialRequest.userPrompt)]
            )
            try await persistMessage(userMessage, runStatus: .running)
            continuation.yield(.messageAppended(userMessage))
        }

        while true {
            try Task.checkCancellation()
            let turn = try await session.beginIteration()
            let snapshot = await session.snapshot()
            try AgentMessageContract.validate(snapshot.messages)
            let promptRequest = promptBuilder.buildTurnRequest(
                userInput: prompt,
                messages: snapshot.messages,
                environment: environment,
                context: promptContext
            )
            let response = try await requestModel(
                runID: runID,
                promptRequest: promptRequest,
                tools: toolDefinitions,
                continuation: continuation
            )
            let calls = response.toolCalls.enumerated().map { index, modelCall in
                Self.agentToolCall(from: modelCall, sequence: turn * 1_000 + index)
            }
            var parts: [AgentMessagePart] = []
            if let reasoning = response.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                parts.append(.reasoning(reasoning))
            }
            let trimmedText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                let text = trimmedText
                parts.append(.text(text))
            }
            parts.append(contentsOf: calls.map(AgentMessagePart.toolCall))
            guard !parts.isEmpty else { throw LoopAgentRuntimeError.emptyModelResponse }

            let assistantMessage = try await session.append(
                role: .assistant,
                turn: turn,
                parts: parts,
                usage: response.usage
            )
            try await persistMessage(assistantMessage, runStatus: .running)
            continuation.yield(.messageAppended(assistantMessage))
            if response.usage != nil {
                continuation.yield(.usageUpdated(await session.snapshot().usage))
            }

            if calls.isEmpty {
                if definition.artifactTypes.contains(.markdown), artifactCount == 0 {
                    throw LoopAgentRuntimeError.requiredArtifactMissing
                }
                guard await session.finish(.completed) else { throw CancellationError() }
                let completedSnapshot = await session.snapshot()
                await persistRunStatus(
                    runID: runID,
                    status: .completed,
                    model: response.model,
                    usage: completedSnapshot.usage,
                    finishedAt: Date()
                )
                continuation.yield(.runCompleted)
                return
            }

            try await session.registerToolCalls(calls.count)
            var pendingCompletionArtifact: CompletionArtifactDraft?
            for call in calls {
                try Task.checkCancellation()
                let completesRun = (try? toolRegistry.tool(named: call.name).definition.completesRun) == true
                let execution = try await executeToolCall(
                    call,
                    runID: runID,
                    session: session,
                    prompt: prompt,
                    context: context,
                    values: values,
                    payload: payload,
                    continuation: continuation
                )
                let resultMessage = AgentToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    output: execution.output,
                    isError: execution.status != .completed && execution.status != .skipped,
                    status: execution.status,
                    elapsedMilliseconds: execution.elapsedMilliseconds,
                    sources: execution.sources,
                    sequence: call.sequence
                )
                let toolMessage = try await session.append(
                    role: .tool,
                    turn: turn,
                    parts: [.toolResult(resultMessage)]
                )
                try await persistMessage(toolMessage, runStatus: .running)
                continuation.yield(.messageAppended(toolMessage))

                if let result = execution.result {
                    applyPayload(result.payload, payload: &payload, values: &values)
                    emitLegacyToolEvents(result, continuation: continuation)
                    if case .markdown(let markdown) = result.payload {
                        if completesRun, execution.status == .completed {
                            // 完成工具的 artifact 延迟到本轮所有 tool-result 都写完后再提交，
                            // 即使模型并行请求多个工具，最终结果仍严格位于时间线底部。
                            pendingCompletionArtifact = CompletionArtifactDraft(
                                content: markdown,
                                toolCallID: call.id,
                                messageID: toolMessage.id
                            )
                        } else {
                            let artifact = AgentArtifact(
                                type: .markdown,
                                title: artifactTitle(for: definition),
                                content: markdown,
                                toolCallID: call.id,
                                messageID: toolMessage.id,
                                sequence: try await session.reserveSequence()
                            )
                            try await persistArtifact(artifact, runID: runID)
                            continuation.yield(.artifactCreated(artifact))
                            artifactCount += 1
                        }
                    } else if completesRun, execution.status == .completed {
                        throw LoopAgentRuntimeError.requiredArtifactMissing
                    }
                }
            }

            if let pendingCompletionArtifact {
                let artifact = AgentArtifact(
                    type: .markdown,
                    title: artifactTitle(for: definition),
                    content: pendingCompletionArtifact.content,
                    toolCallID: pendingCompletionArtifact.toolCallID,
                    messageID: pendingCompletionArtifact.messageID,
                    sequence: try await session.reserveSequence()
                )
                try await persistArtifact(artifact, runID: runID)
                continuation.yield(.artifactCreated(artifact))
                artifactCount += 1

                guard await session.finish(.completed) else { throw CancellationError() }
                let completedSnapshot = await session.snapshot()
                await persistRunStatus(
                    runID: runID,
                    status: .completed,
                    model: response.model,
                    usage: completedSnapshot.usage,
                    finishedAt: Date()
                )
                continuation.yield(.runCompleted)
                return
            }
        }
    }

    private func requestModel(
        runID: UUID,
        promptRequest: AgentPromptTurnRequest,
        tools: [AgentToolDefinition],
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> AgentModelResponse {
        var completed: AgentModelResponse?
        var streamedText = ""
        let stream = modelClient.stream(request: AgentModelRequest(
            prompt: promptRequest,
            tools: tools,
            metadata: ["run_id": runID.uuidString]
        ))
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                streamedText += delta
                continuation.yield(.assistantDelta(delta))
            case .reasoningDelta, .toolCallDelta, .usage:
                continue
            case .completed(let response):
                completed = response
            }
        }
        guard let completed else { throw LoopAgentRuntimeError.emptyModelResponse }
        if streamedText.isEmpty, !completed.text.isEmpty {
            continuation.yield(.assistantDelta(completed.text))
        }
        return completed
    }

    private func executeToolCall(
        _ call: AgentToolCall,
        runID: UUID,
        session: AgentRunSession,
        prompt: String,
        context: AgentRunContext,
        values: [String: String],
        payload: AgentToolPayload,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> ToolExecution {
        do {
            let tool = try toolRegistry.validatedTool(for: call)
            let input = AgentToolInput(
                toolCallID: call.id,
                arguments: call.input,
                prompt: prompt,
                context: context,
                values: values,
                payload: payload
            )
            if tool.permission != .readOnly {
                return try await executeApprovedTool(
                    tool: tool,
                    input: input,
                    call: call,
                    runID: runID,
                    session: session,
                    continuation: continuation
                )
            }
            return await executeWithPolicy(tool: tool, input: input, call: call)
        } catch {
            if error is CancellationError { throw error }
            return .failure(call: call, message: Self.errorMessage(error), status: .failed)
        }
    }

    private func executeApprovedTool(
        tool: any AgentTool,
        input: AgentToolInput,
        call: AgentToolCall,
        runID: UUID,
        session: AgentRunSession,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> ToolExecution {
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: tool.permission,
            sequence: call.sequence
        )
        try await session.requestApproval(approval)
        await approvalCoordinator.prepare(approval)
        try await persistApproval(approval, runStatus: .waitingForConfirmation)
        continuation.yield(.approvalUpdated(approval))
        continuation.yield(.confirmationRequested(AgentConfirmationAction(
            id: approval.id,
            title: call.name,
            detail: tool.permission.rawValue,
            toolName: call.name,
            input: call.rawInput ?? ((try? call.input.jsonString()) ?? "{}")
        )))

        return try await resolvePreparedApproval(
            approval: approval,
            tool: tool,
            input: input,
            call: call,
            session: session,
            continuation: continuation
        )
    }

    private func resolvePreparedApproval(
        approval: AgentApprovalRequest,
        tool: any AgentTool,
        input: AgentToolInput,
        call: AgentToolCall,
        session: AgentRunSession,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> ToolExecution {
        switch await approvalCoordinator.wait(for: approval.id) {
        case .cancelled:
            try await session.updateApprovalStatus(.cancelled, approvalID: approval.id)
            var cancelled = approval
            cancelled.status = .cancelled
            try await persistApproval(cancelled, runStatus: .cancelled)
            continuation.yield(.approvalUpdated(cancelled))
            throw CancellationError()
        case .rejected:
            let resolved = try await currentApproval(session: session, id: approval.id)
            try await persistApproval(resolved, runStatus: .running)
            continuation.yield(.approvalUpdated(resolved))
            await session.clearResolvedApproval()
            return .failure(
                call: call,
                message: String.l10n("agent.loop.error.approvalRejected"),
                status: .rejected
            )
        case .approved:
            var resolved = try await currentApproval(session: session, id: approval.id)
            try await persistApproval(resolved, runStatus: .running)
            continuation.yield(.approvalUpdated(resolved))

            try await session.updateApprovalStatus(.executing, approvalID: approval.id)
            resolved.status = .executing
            try await persistApproval(resolved, runStatus: .running)
            continuation.yield(.approvalUpdated(resolved))

            let execution = await executeWithPolicy(tool: tool, input: input, call: call)
            let finalStatus: AgentApprovalStatus = execution.status == .completed ? .executed : .failed
            try await session.updateApprovalStatus(finalStatus, approvalID: approval.id)
            resolved.status = finalStatus
            try await persistApproval(resolved, runStatus: .running)
            continuation.yield(.approvalUpdated(resolved))
            await session.clearResolvedApproval()
            return execution
        }
    }

    private func resolveRestoredApproval(
        snapshot: AgentRunSnapshotRecord,
        runID: UUID,
        session: AgentRunSession,
        prompt: String,
        context: AgentRunContext,
        values: [String: String],
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> RestoredApprovalExecution {
        guard let approval = snapshot.approvals.last(where: { $0.status == .pending }) else {
            throw LoopAgentRuntimeError.approvalRequired("missing pending approval")
        }
        let callAndTurn = snapshot.messages.lazy.compactMap { message -> (AgentToolCall, Int)? in
            for part in message.parts {
                guard case .toolCall(let call) = part, call.id == approval.toolCallID else { continue }
                return (call, message.turn)
            }
            return nil
        }.first
        guard let (call, turn) = callAndTurn,
              call.name == approval.toolName,
              call.input == approval.input
        else {
            throw LoopAgentRuntimeError.approvalRequired(approval.toolName)
        }

        let tool = try toolRegistry.validatedTool(for: call)
        guard tool.permission != .readOnly, tool.permission == approval.permission else {
            throw LoopAgentRuntimeError.approvalRequired(approval.toolName)
        }
        let input = AgentToolInput(
            toolCallID: call.id,
            arguments: call.input,
            prompt: prompt,
            context: context,
            values: values
        )

        await approvalCoordinator.prepare(approval)
        continuation.yield(.approvalUpdated(approval))
        continuation.yield(.confirmationRequested(AgentConfirmationAction(
            id: approval.id,
            title: call.name,
            detail: tool.permission.rawValue,
            toolName: call.name,
            input: call.rawInput ?? ((try? call.input.jsonString()) ?? "{}")
        )))
        let execution = try await resolvePreparedApproval(
            approval: approval,
            tool: tool,
            input: input,
            call: call,
            session: session,
            continuation: continuation
        )
        return RestoredApprovalExecution(call: call, turn: turn, execution: execution)
    }

    private func currentApproval(session: AgentRunSession, id: UUID) async throws -> AgentApprovalRequest {
        guard let approval = await session.snapshot().pendingApproval, approval.id == id else {
            throw AgentRunSessionError.waitingForConfirmation
        }
        return approval
    }

    private func executeWithPolicy(
        tool: any AgentTool,
        input: AgentToolInput,
        call: AgentToolCall
    ) async -> ToolExecution {
        let startedAt = Date()
        // 写入型和高成本工具即使定义误配 retryPolicy，也只允许执行一次；否则审批只
        // 覆盖一次调用却可能产生多次副作用。
        let policy = tool.permission == .readOnly ? tool.definition.retryPolicy : .none
        var attempt = 0
        while attempt <= policy.maxRetries {
            let outcome = await executeAttempt(
                tool: tool,
                input: input,
                timeoutMilliseconds: max(1, tool.definition.timeoutMilliseconds)
            )
            switch outcome {
            case .completed(let result):
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                if result.status != .failed || attempt == policy.maxRetries {
                    return ToolExecution(result: result, status: Self.resultStatus(result.status), elapsedMilliseconds: elapsed)
                }
            case .timedOut:
                if attempt == policy.maxRetries {
                    return .failure(
                        call: call,
                        message: String(format: String.l10n("agent.loop.error.toolTimeoutFormat"), call.name),
                        status: .timedOut,
                        elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
                    )
                }
            }
            attempt += 1
            if policy.initialBackoffMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(policy.initialBackoffMilliseconds) * 1_000_000)
            }
        }
        return .failure(call: call, message: "unreachable tool execution state", status: .failed)
    }

    private func executeAttempt(
        tool: any AgentTool,
        input: AgentToolInput,
        timeoutMilliseconds: Int
    ) async -> ToolAttemptOutcome {
        await withTaskGroup(of: ToolAttemptOutcome.self) { group in
            group.addTask { .completed(await tool.execute(input)) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    private func artifactRules(_ definitions: [AgentToolDefinition]) -> [AgentPromptRule] {
        let submitTools = definitions.filter(\.completesRun).map(\.name)
        guard !submitTools.isEmpty else { return [] }
        return [AgentPromptRule(
            id: "required-artifact",
            content: "Before the final answer, create the required artifact with one of: \(submitTools.joined(separator: ", "))."
        )]
    }

    private func definitionRules(_ definition: AgentDefinition) -> [AgentPromptRule] {
        switch definition.id {
        case BuiltInAgents.githubWeeklyReport.id:
            return [
                AgentPromptRule(
                    id: "weekly-local-facts",
                    content: "Treat repository IDs and metadata in Frozen Starcat Context as the only local facts. Do not claim live GitHub trends, releases, activity, README or license data unless a tool result provides that evidence."
                ),
                AgentPromptRule(
                    id: "weekly-artifact-contract",
                    content: "Use context_resolve_repos and repo_cluster_topics as needed, then submit exactly one structured artifact_build_weekly_report call. Cite only repository IDs returned by the frozen context."
                )
            ]
        case BuiltInAgents.repoInsight.id:
            return [
                AgentPromptRule(
                    id: "repo-insight-selection",
                    content: "Select the target with context_select_repo using repoID or exact fullName. Base repository facts only on the frozen Starcat context."
                ),
                AgentPromptRule(
                    id: "repo-insight-artifact-contract",
                    content: "Submit exactly one structured artifact_build_repo_insight call. State missing README, license, maintenance or live activity evidence as limitations rather than inventing it."
                )
            ]
        default:
            return []
        }
    }

    private func applyPayload(
        _ next: AgentToolPayload,
        payload: inout AgentToolPayload,
        values: inout [String: String]
    ) {
        switch next {
        case .none:
            return
        case .externalContextMarkdown(let markdown):
            values["externalContextMarkdown"] = markdown
        default:
            payload = next
        }
    }

    private func emitLegacyToolEvents(
        _ result: AgentToolResult,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) {
        let step = AgentRunStep(
            title: result.output.toolName,
            detail: result.output.summary,
            status: result.status.stepStatus
        )
        continuation.yield(.stepUpdated(step))
        continuation.yield(.toolOutput(result.output))
        continuation.yield(.trace(result.trace))
        if let action = result.confirmationAction {
            continuation.yield(.confirmationRequested(action))
        }
    }

    private func artifactTitle(for definition: AgentDefinition) -> String {
        switch definition.id {
        case BuiltInAgents.githubWeeklyReport.id:
            return String.l10n("agent.runtime.artifact.weeklyReport.title")
        default:
            return definition.title
        }
    }

    private func persistCreateRun(
        runID: UUID,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) async throws {
        _ = try await runRepository?.createRun(
            id: runID,
            definition: definition,
            prompt: prompt,
            context: context,
            createdAt: Date()
        )
    }

    private func persistRunStatus(
        runID: UUID,
        status: AgentRunStatus,
        model: String? = nil,
        usage: AgentUsage? = nil,
        errorMessage: String? = nil,
        finishedAt: Date? = nil
    ) async {
        do {
            try await runRepository?.updateRunStatus(
                runID: runID,
                status: status,
                model: model,
                usage: usage,
                errorMessage: errorMessage,
                finishedAt: finishedAt
            )
        } catch {
            AppLog.database.warning("Agent loop status persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistMessage(_ message: AgentMessage, runStatus: AgentRunStatus?) async throws {
        try await runRepository?.appendMessage(message, runStatus: runStatus)
    }

    private func persistApproval(_ approval: AgentApprovalRequest, runStatus: AgentRunStatus) async throws {
        try await runRepository?.saveApproval(approval, runStatus: runStatus)
    }

    private func persistArtifact(_ artifact: AgentArtifact, runID: UUID) async throws {
        try await runRepository?.appendArtifact(artifact, runID: runID)
    }

    private func finishFailed(
        runID: UUID,
        session: AgentRunSession,
        message: String,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        guard await session.finish(.failed(message)) else { return }
        await persistRunStatus(runID: runID, status: .failed, errorMessage: message, finishedAt: Date())
        continuation.yield(.runFailed(message))
    }

    private func finishCancelled(
        runID: UUID,
        session: AgentRunSession,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        _ = await session.finish(.cancelled)
        await persistRunStatus(runID: runID, status: .cancelled, finishedAt: Date())
        continuation.yield(.runCancelled)
    }

    private static func agentToolCall(from call: AgentModelToolCall, sequence: Int) -> AgentToolCall {
        let input: AgentJSONValue
        if let data = call.arguments.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AgentJSONValue.self, from: data) {
            input = decoded
        } else {
            input = .string(call.arguments)
        }
        return AgentToolCall(
            id: call.id,
            name: call.name,
            input: input,
            rawInput: call.arguments,
            sequence: sequence
        )
    }

    private static func resultStatus(_ status: AgentToolStatus) -> AgentToolResultStatus {
        switch status {
        case .completed:
            return .completed
        case .skipped:
            return .skipped
        case .failed:
            return .failed
        case .requiresConfirmation:
            return .rejected
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func restoredValues(from messages: [AgentMessage]) -> [String: String] {
        var values: [String: String] = [:]
        for message in messages where message.role == .tool {
            for part in message.parts {
                guard case .toolResult(let result) = part,
                      result.toolName == "external_search",
                      result.status == .completed,
                      let detail = result.output.objectValue?["detail"]?.stringValue,
                      detail.contains("external_context")
                else { continue }
                values["externalContextMarkdown"] = detail
            }
        }
        return values
    }
}

private enum ToolAttemptOutcome: Sendable {
    case completed(AgentToolResult)
    case timedOut
}

private struct CompletionArtifactDraft: Sendable {
    var content: String
    var toolCallID: String
    var messageID: UUID
}

private struct RestoredApprovalExecution: Sendable {
    var call: AgentToolCall
    var turn: Int
    var execution: ToolExecution
}

private struct ToolExecution: Sendable {
    var result: AgentToolResult?
    var output: AgentJSONValue
    var status: AgentToolResultStatus
    var elapsedMilliseconds: Int
    var sources: [AgentToolResultSource]

    init(
        result: AgentToolResult,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int
    ) {
        self.result = result
        self.output = .object([
            "summary": .string(result.output.summary),
            "detail": .string(result.output.detail),
            "output": .string(result.output.output),
            "log": .string(result.output.log)
        ])
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.sources = result.sources
    }

    static func failure(
        call: AgentToolCall,
        message: String,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int = 0
    ) -> ToolExecution {
        ToolExecution(
            result: nil,
            output: .object([
                "error": .string(message),
                "tool": .string(call.name),
                "arguments": .string(call.rawInput ?? "")
            ]),
            status: status,
            elapsedMilliseconds: elapsedMilliseconds,
            sources: []
        )
    }

    private init(
        result: AgentToolResult?,
        output: AgentJSONValue,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int,
        sources: [AgentToolResultSource]
    ) {
        self.result = result
        self.output = output
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.sources = sources
    }
}
