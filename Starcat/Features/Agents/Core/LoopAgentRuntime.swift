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
    case contextUnavailable
    case repositoryContextEmpty
    case duplicateCompletionArtifact
    case toolNotVisible(String)

    var errorDescription: String? {
        switch self {
        case .emptyModelResponse:
            return String.l10n("agent.loop.error.emptyModelResponse")
        case .requiredArtifactMissing:
            return String.l10n("agent.loop.error.requiredArtifactMissing")
        case .approvalRequired(let toolName):
            return String(format: String.l10n("agent.loop.error.approvalRequiredFormat"), toolName)
        case .contextUnavailable:
            return String.l10n("agent.loop.error.contextUnavailable")
        case .repositoryContextEmpty:
            return String.l10n("agent.loop.error.repositoryContextEmpty")
        case .duplicateCompletionArtifact:
            return String.l10n("agent.loop.error.duplicateCompletionArtifact")
        case .toolNotVisible(let toolName):
            return String(format: String.l10n("agent.loop.error.toolNotVisibleFormat"), toolName)
        }
    }
}

private actor AgentRuntimeTaskHandle {
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        if cancellationRequested {
            task.cancel()
        } else {
            self.task = task
        }
    }

    func cancel() {
        cancellationRequested = true
        task?.cancel()
    }
}

private actor AgentRuntimeSessionRouter {
    private var activeSession: AgentRunSession?
    private var activeTaskHandle: AgentRuntimeTaskHandle?

    func activate(_ session: AgentRunSession, taskHandle: AgentRuntimeTaskHandle) {
        activeSession = session
        activeTaskHandle = taskHandle
    }

    func deactivate(runID: UUID) async {
        guard let activeSession, activeSession.runID == runID else { return }
        self.activeSession = nil
        activeTaskHandle = nil
    }

    func send(_ command: AgentRunCommand) async -> Bool {
        guard let activeSession else { return false }
        let accepted = await activeSession.apply(command)
        if accepted, case .cancel = command {
            // Session 状态变化本身无法唤醒正在等待网络流的 task，必须同时取消执行任务。
            await activeTaskHandle?.cancel()
        }
        return accepted
    }
}

private enum AgentRunRestoration: Sendable {
    case pendingApproval(AgentRunSnapshotRecord)
    case failedRetry(AgentRunSnapshotRecord)

    var snapshot: AgentRunSnapshotRecord {
        switch self {
        case .pendingApproval(let snapshot), .failedRetry(let snapshot):
            return snapshot
        }
    }

    var logLabel: String {
        switch self {
        case .pendingApproval: return "approval"
        case .failedRetry: return "failure"
        }
    }
}

/// Provider 原始流式增量进入 Workspace `MainActor` 前的批处理器。
///
/// Provider 可能在一次长回答中产生数千个 token 事件。若每个事件都直接进入
/// `AgentWorkspaceViewModel`，即使展示层随后再节流，主线程仍需要先消费全部事件并触发
/// Observation 检查。这里按固定时间窗合并正文与 reasoning，完整文本仍由模型响应和消息
/// 持久化保存，批处理只降低 UI 事件频率，不改变 Agent 的消息事实或 tool-calling 语义。
struct AgentStreamDeltaBatcher {
    static let defaultEmissionInterval: TimeInterval = 0.1

    private let emissionInterval: TimeInterval
    private var pendingText = ""
    private var pendingReasoning = ""
    private var lastEmissionTime: TimeInterval?

    init(emissionInterval: TimeInterval = Self.defaultEmissionInterval) {
        self.emissionInterval = max(0, emissionInterval)
    }

    mutating func appendText(_ delta: String, now: TimeInterval) -> [AgentRunEvent] {
        guard !delta.isEmpty else { return [] }
        pendingText += delta
        return flushIfDue(now: now)
    }

    mutating func appendReasoning(_ delta: String, now: TimeInterval) -> [AgentRunEvent] {
        guard !delta.isEmpty else { return [] }
        pendingReasoning += delta
        return flushIfDue(now: now)
    }

    mutating func flush() -> [AgentRunEvent] {
        drain()
    }

    private mutating func flushIfDue(now: TimeInterval) -> [AgentRunEvent] {
        if let lastEmissionTime, now - lastEmissionTime < emissionInterval {
            return []
        }
        lastEmissionTime = now
        return drain()
    }

    private mutating func drain() -> [AgentRunEvent] {
        var events: [AgentRunEvent] = []
        if !pendingReasoning.isEmpty {
            events.append(.assistantReasoningDelta(pendingReasoning))
            pendingReasoning = ""
        }
        if !pendingText.isEmpty {
            events.append(.assistantDelta(pendingText))
            pendingText = ""
        }
        return events
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
        if case .cancel(let runID) = command {
            // 用户取消的持久化不能依赖 Provider 流是否及时响应 Task cancellation。
            await persistRunStatus(runID: runID, status: .cancelled, finishedAt: Date())
            AppLog.ai.info("[AgentRuntime] run.cancel.requested runID=\(runID.uuidString, privacy: .public)")
        }
        _ = await approvalCoordinator.resolve(command)
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let runID = UUID()
            let session = AgentRunSession(runID: runID, limits: resolvedLimits(for: definition))
            let taskHandle = AgentRuntimeTaskHandle()
            let task = Task {
                AppLog.ai.info("[AgentRuntime] run.start runID=\(runID.uuidString, privacy: .public) agent=\(definition.id, privacy: .public) mode=\(mode.rawValue, privacy: .public)")
                await sessionRouter.activate(session, taskHandle: taskHandle)
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
                    let state = await session.snapshot().state
                    if Task.isCancelled || state == .cancelled {
                        await finishCancelled(runID: runID, session: session, continuation: continuation)
                    } else {
                        await finishFailed(
                            runID: runID,
                            session: session,
                            message: Self.errorMessage(error),
                            continuation: continuation
                        )
                    }
                }
                await sessionRouter.deactivate(runID: runID)
                continuation.finish()
            }
            Task { await taskHandle.install(task) }

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
        guard snapshot.run.status == AgentRunStatus.waitingForConfirmation.rawValue,
              snapshot.run.agentId == definition.id,
              let pendingApproval = snapshot.approvals.last(where: { $0.status == .pending })
        else {
            return failedStream(String.l10n("agent.loop.error.noPendingApproval"))
        }
        do {
            let session = try AgentRunSession(
                restoring: snapshot,
                pendingApproval: pendingApproval,
                limits: resolvedLimits(for: definition)
            )
            return resumeRestoredRun(
                session: session,
                definition: definition,
                restoration: .pendingApproval(snapshot)
            )
        } catch {
            return failedStream(Self.errorMessage(error))
        }
    }

    func retryFailedRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        guard snapshot.run.agentId == definition.id else {
            return failedStream(String.l10n("agent.loop.error.retryUnavailable"))
        }
        do {
            let session = try AgentRunSession(
                retrying: snapshot,
                limits: resolvedLimits(for: definition)
            )
            return resumeRestoredRun(
                session: session,
                definition: definition,
                restoration: .failedRetry(snapshot)
            )
        } catch {
            return failedStream(Self.errorMessage(error))
        }
    }

    /// 两种恢复都继续同一个持久化 Run，因此共用 task、取消和终态竞争处理；差异只留在
    /// `execute` 的恢复前置步骤，避免新增一条容易漂移的 Runtime 循环。
    private func resumeRestoredRun(
        session: AgentRunSession,
        definition: AgentDefinition,
        restoration: AgentRunRestoration
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let runID = session.runID
            let taskHandle = AgentRuntimeTaskHandle()
            let task = Task {
                AppLog.ai.info("[AgentRuntime] run.resume runID=\(runID.uuidString, privacy: .public) agent=\(definition.id, privacy: .public) reason=\(restoration.logLabel, privacy: .public)")
                await sessionRouter.activate(session, taskHandle: taskHandle)
                do {
                    try await execute(
                        runID: runID,
                        session: session,
                        definition: definition,
                        prompt: restoration.snapshot.run.userPrompt,
                        context: restoration.snapshot.context,
                        restoration: restoration,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    await finishCancelled(runID: runID, session: session, continuation: continuation)
                } catch {
                    let state = await session.snapshot().state
                    if Task.isCancelled || state == .cancelled {
                        await finishCancelled(runID: runID, session: session, continuation: continuation)
                    } else {
                        await finishFailed(
                            runID: runID,
                            session: session,
                            message: Self.errorMessage(error),
                            continuation: continuation
                        )
                    }
                }
                await sessionRouter.deactivate(runID: runID)
                continuation.finish()
            }
            Task { await taskHandle.install(task) }

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

    private func failedStream(_ message: String) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            continuation.yield(.runFailed(message))
            continuation.finish()
        }
    }

    private func execute(
        runID: UUID,
        session: AgentRunSession,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext,
        restoration: AgentRunRestoration? = nil,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let registeredTools = try toolRegistry.tools(named: definition.toolIDs)
        let allowedTools = visibleTools(from: registeredTools)
        let toolDefinitions = allowedTools.map(\.definition)
        let completionToolDefinitions = toolDefinitions.filter(\.completesRun)
        let visibleToolNames = Set(toolDefinitions.map(\.name))
        var effectiveExternalSearchPolicy = externalSearchPolicy
        effectiveExternalSearchPolicy.isEnabled = externalSearchPolicy.isEnabled
            && context.webSearchEnabled != false
        let promptContext = AgentPromptContext(
            definition: definition,
            runContext: context,
            availableTools: toolDefinitions.map {
                AgentPromptToolSummary(name: $0.name, description: $0.description, permission: $0.permission)
            },
            rules: rules + definitionRules(definition) + artifactRules(toolDefinitions),
            preferredLanguage: preferredLanguage,
            externalSearch: effectiveExternalSearchPolicy
        )
        let environment = AgentPromptEnvironment.current(
            mode: mode,
            locale: Locale(identifier: localeIdentifier)
        )
        var payload: AgentToolPayload = .none
        var values = Self.restoredValues(from: restoration?.snapshot.messages ?? [])
        var artifactCount = restoration?.snapshot.artifacts.count ?? 0

        switch restoration {
        case .pendingApproval(let snapshot):
            continuation.yield(.runStarted(title: definition.title))
            let restored = try await resolveRestoredApproval(
                snapshot: snapshot,
                runID: runID,
                session: session,
                prompt: prompt,
                context: context,
                values: values,
                visibleToolNames: visibleToolNames,
                continuation: continuation
            )
            AppLog.ai.info("[AgentRuntime] tool.restored runID=\(runID.uuidString, privacy: .public) turn=\(restored.turn, privacy: .public) sequence=\(restored.call.sequence, privacy: .public) toolCallID=\(restored.call.id, privacy: .public) tool=\(restored.call.name, privacy: .public) status=\(restored.execution.status.rawValue, privacy: .public)")
            let resultMessage = AgentToolResultMessage(
                toolCallID: restored.call.id,
                toolName: restored.call.name,
                output: restored.execution.output,
                isError: restored.execution.status != .completed && restored.execution.status != .skipped,
                status: restored.execution.status,
                elapsedMilliseconds: restored.execution.elapsedMilliseconds,
                attempts: restored.execution.attempts,
                sources: restored.execution.sources,
                toolAudit: restored.execution.toolAudit,
                sequence: restored.call.sequence
            )
            let toolMessage = try await session.append(
                role: .tool,
                turn: restored.turn,
                parts: [.toolResult(resultMessage)]
            )
            try await persistMessage(toolMessage, runStatus: .running)
            try await emitTraceEvents(for: toolMessage, continuation: continuation)
            continuation.yield(.messageAppended(toolMessage))
            if let result = restored.execution.result {
                applyPayload(result.payload, payload: &payload, values: &values)
            }
        case .failedRetry:
            try Self.validateRequiredContext(definition: definition, context: context)
            let restoredSession = await session.snapshot()
            try await persistRetryStarted(runID: runID, usage: restoredSession.usage)
            continuation.yield(.runStarted(title: definition.title))
        case nil:
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
            try Self.validateRequiredContext(definition: definition, context: context)
        }

        while true {
            try Task.checkCancellation()
            let turn = try await session.beginIteration()
            let snapshot = await session.snapshot()
            try AgentMessageContract.validate(snapshot.messages)
            let isFinalizationTurn = artifactCount == 0
                && !completionToolDefinitions.isEmpty
                && turn == limits.maxIterations - 1
            let requestTools = isFinalizationTurn ? completionToolDefinitions : toolDefinitions
            let turnVisibleToolNames = Set(requestTools.map(\.name))
            var turnPromptContext = promptContext
            if isFinalizationTurn {
                // Prompt 中的工具摘要必须和 Provider 真正收到的工具集合一致。只缩小 Provider
                // tools 而保留读取工具说明，会诱导模型继续请求一个本轮已不可用的工具。
                turnPromptContext.availableTools = requestTools.map {
                    AgentPromptToolSummary(name: $0.name, description: $0.description, permission: $0.permission)
                }
                turnPromptContext.rules.append(finalizationRule(requestTools))
            }
            let promptRequest = promptBuilder.buildTurnRequest(
                userInput: prompt,
                messages: snapshot.messages,
                environment: environment,
                context: turnPromptContext
            )
            let response = try await requestModel(
                runID: runID,
                promptRequest: promptRequest,
                tools: requestTools,
                toolChoice: isFinalizationTurn ? .required : .auto,
                continuation: continuation
            )
            AppLog.ai.info("[AgentRuntime] model.completed runID=\(runID.uuidString, privacy: .public) turn=\(turn, privacy: .public) toolCalls=\(response.toolCalls.count, privacy: .public) tokens=\(response.usage?.totalTokens ?? 0, privacy: .public)")
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
            try await emitTraceEvents(for: assistantMessage, continuation: continuation)
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
                AppLog.ai.info("[AgentRuntime] run.completed runID=\(runID.uuidString, privacy: .public) turn=\(turn, privacy: .public) tokens=\(completedSnapshot.usage.totalTokens, privacy: .public) artifacts=\(artifactCount, privacy: .public)")
                continuation.yield(.runCompleted)
                return
            }

            try await session.registerToolCalls(calls.count)
            var pendingCompletionArtifact: CompletionArtifactDraft?
            for call in calls {
                try Task.checkCancellation()
                let completesRun = (try? toolRegistry.tool(named: call.name).definition.completesRun) == true
                if completesRun, pendingCompletionArtifact != nil {
                    // 一个 run 只能有一个终态 artifact。若同轮覆盖前一个，审计记录会把
                    // 模型的首个提交静默抹掉，因此直接终止并要求模型下一次只提交一次。
                    throw LoopAgentRuntimeError.duplicateCompletionArtifact
                }
                let execution = try await executeToolCall(
                    call,
                    runID: runID,
                    session: session,
                    prompt: prompt,
                    context: context,
                    values: values,
                    payload: payload,
                    visibleToolNames: turnVisibleToolNames,
                    continuation: continuation
                )
                AppLog.ai.info("[AgentRuntime] tool.completed runID=\(runID.uuidString, privacy: .public) turn=\(turn, privacy: .public) sequence=\(call.sequence, privacy: .public) toolCallID=\(call.id, privacy: .public) tool=\(call.name, privacy: .public) status=\(execution.status.rawValue, privacy: .public) attempts=\(execution.attempts.count, privacy: .public)")
                let resultMessage = AgentToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    output: execution.output,
                    isError: execution.status != .completed && execution.status != .skipped,
                    status: execution.status,
                    elapsedMilliseconds: execution.elapsedMilliseconds,
                    attempts: execution.attempts,
                    sources: execution.sources,
                    toolAudit: execution.toolAudit,
                    sequence: call.sequence
                )
                let toolMessage = try await session.append(
                    role: .tool,
                    turn: turn,
                    parts: [.toolResult(resultMessage)]
                )
                try await persistMessage(toolMessage, runStatus: .running)
                try await emitTraceEvents(for: toolMessage, continuation: continuation)
                continuation.yield(.messageAppended(toolMessage))

                if let result = execution.result {
                    applyPayload(result.payload, payload: &payload, values: &values)
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
                AppLog.ai.info("[AgentRuntime] run.completed runID=\(runID.uuidString, privacy: .public) turn=\(turn, privacy: .public) tokens=\(completedSnapshot.usage.totalTokens, privacy: .public) artifacts=\(artifactCount, privacy: .public)")
                continuation.yield(.runCompleted)
                return
            }
        }
    }

    private func requestModel(
        runID: UUID,
        promptRequest: AgentPromptTurnRequest,
        tools: [AgentToolDefinition],
        toolChoice: AIChatToolChoice,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> AgentModelResponse {
        var completed: AgentModelResponse?
        var streamedText = ""
        var streamedReasoning = ""
        var deltaBatcher = AgentStreamDeltaBatcher()
        let stream = modelClient.stream(request: AgentModelRequest(
            prompt: promptRequest,
            tools: tools,
            toolChoice: toolChoice,
            metadata: ["run_id": runID.uuidString]
        ))
        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    streamedText += delta
                    for batchedEvent in deltaBatcher.appendText(
                        delta,
                        now: Date.timeIntervalSinceReferenceDate
                    ) {
                        continuation.yield(batchedEvent)
                    }
                case .reasoningDelta(let delta):
                    streamedReasoning += delta
                    for batchedEvent in deltaBatcher.appendReasoning(
                        delta,
                        now: Date.timeIntervalSinceReferenceDate
                    ) {
                        continuation.yield(batchedEvent)
                    }
                case .toolCallDelta, .usage:
                    continue
                case .completed(let response):
                    completed = response
                }
            }
        } catch {
            // Provider 失败或任务取消时也保留已经到达的尾部增量，避免错误行出现前
            // 正文突然缺一截；随后仍把原始错误交给上层统一收口 Run 状态。
            for batchedEvent in deltaBatcher.flush() {
                continuation.yield(batchedEvent)
            }
            throw error
        }
        // 正常结束时补发不足一个时间窗的尾部增量，避免短回答或最后一批 token 丢失。
        for batchedEvent in deltaBatcher.flush() {
            continuation.yield(batchedEvent)
        }
        try Task.checkCancellation()
        guard let completed else { throw LoopAgentRuntimeError.emptyModelResponse }
        if streamedText.isEmpty, !completed.text.isEmpty {
            continuation.yield(.assistantDelta(completed.text))
        }
        if streamedReasoning.isEmpty,
           let reasoning = completed.reasoning,
           !reasoning.isEmpty {
            // 非流式 Provider 只在 completed 中返回 reasoning，仍通过相同事件进入 UI。
            continuation.yield(.assistantReasoningDelta(reasoning))
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
        visibleToolNames: Set<String>,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws -> ToolExecution {
        do {
            guard visibleToolNames.contains(call.name) else {
                return .failure(
                    call: call,
                    message: LoopAgentRuntimeError.toolNotVisible(call.name).localizedDescription,
                    status: .failed
                )
            }
            let tool = try toolRegistry.validatedTool(for: call)
            let input = AgentToolInput(
                toolCallID: call.id,
                arguments: call.input,
                prompt: prompt,
                context: context,
                values: values,
                payload: payload
            )
            if !tool.permission.isAutomaticRead {
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
        AppLog.ai.info("[AgentRuntime] approval.pending runID=\(runID.uuidString, privacy: .public) sequence=\(call.sequence, privacy: .public) toolCallID=\(call.id, privacy: .public) tool=\(call.name, privacy: .public) permission=\(tool.permission.rawValue, privacy: .public)")
        continuation.yield(.approvalUpdated(approval))

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
            AppLog.ai.info("[AgentRuntime] approval.cancelled runID=\(approval.runID.uuidString, privacy: .public) toolCallID=\(approval.toolCallID, privacy: .public)")
            try await session.updateApprovalStatus(.cancelled, approvalID: approval.id)
            var cancelled = approval
            cancelled.status = .cancelled
            try await persistApproval(cancelled, runStatus: .cancelled)
            continuation.yield(.approvalUpdated(cancelled))
            throw CancellationError()
        case .rejected:
            AppLog.ai.info("[AgentRuntime] approval.rejected runID=\(approval.runID.uuidString, privacy: .public) toolCallID=\(approval.toolCallID, privacy: .public)")
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
            AppLog.ai.info("[AgentRuntime] approval.approved runID=\(approval.runID.uuidString, privacy: .public) toolCallID=\(approval.toolCallID, privacy: .public)")
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
        visibleToolNames: Set<String>,
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
        guard visibleToolNames.contains(call.name) else {
            throw LoopAgentRuntimeError.toolNotVisible(call.name)
        }

        let tool = try toolRegistry.validatedTool(for: call)
        guard !tool.permission.isAutomaticRead, tool.permission == approval.permission else {
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
        let policy = tool.permission.isAutomaticRead ? tool.definition.retryPolicy : .none
        var attempt = 0
        var attempts: [AgentToolExecutionAttempt] = []
        while attempt <= policy.maxRetries {
            let attemptStartedAt = Date()
            let outcome = await executeAttempt(
                tool: tool,
                input: input,
                // 工具可以声明更短 deadline，但不能突破本次 run 的全局单工具上限。
                timeoutMilliseconds: max(
                    1,
                    min(tool.definition.timeoutMilliseconds, limits.defaultToolTimeoutMilliseconds)
                )
            )
            let attemptElapsed = Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)
            switch outcome {
            case .completed(let result):
                let status = Self.resultStatus(result.status)
                attempts.append(AgentToolExecutionAttempt(
                    number: attempt + 1,
                    status: status,
                    elapsedMilliseconds: attemptElapsed,
                    errorSummary: status == .failed ? result.output.summary : nil
                ))
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                if result.status != .failed || attempt == policy.maxRetries {
                    return ToolExecution(
                        result: result,
                        status: status,
                        elapsedMilliseconds: elapsed,
                        attempts: attempts
                    )
                }
            case .timedOut:
                let timeoutMessage = String(format: String.l10n("agent.loop.error.toolTimeoutFormat"), call.name)
                attempts.append(AgentToolExecutionAttempt(
                    number: attempt + 1,
                    status: .timedOut,
                    elapsedMilliseconds: attemptElapsed,
                    errorSummary: timeoutMessage
                ))
                if attempt == policy.maxRetries {
                    return .failure(
                        call: call,
                        message: timeoutMessage,
                        status: .timedOut,
                        elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                        attempts: attempts
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

    /// 最后一次模型机会不再允许继续扩张证据范围，只允许基于已持久化事实提交终态产物。
    /// 这是由 `completesRun` 驱动的 Runtime 通用规则，不绑定 Weekly 或任何具体 Agent ID。
    private func finalizationRule(_ definitions: [AgentToolDefinition]) -> AgentPromptRule {
        let submitTools = definitions.map(\.name).joined(separator: ", ")
        return AgentPromptRule(
            id: "runtime-finalization",
            content: "This is the final allowed model turn. Use exactly one available completion tool now (\(submitTools)) and build its structured arguments from facts already present in the message history. Do not request more evidence and do not return a prose-only answer."
        )
    }

    private func visibleTools(from tools: [any AgentTool]) -> [any AgentTool] {
        switch mode {
        case .approvedAction:
            return tools
        case .readonlyPlanning, .reportGeneration, .backgroundDigest:
            return tools.filter { $0.permission.isAutomaticRead }
        }
    }

    /// 研究/分析 Agent 的证据链通常超过通用默认值；预算由 definition 声明，避免把
    /// 全局 32 一刀切放大后同时削弱简单 Agent 与写入型 Agent 的失控保护。
    private func resolvedLimits(for definition: AgentDefinition) -> AgentRunLimits {
        guard let maxToolCalls = definition.loopMaxToolCalls else { return limits }
        var resolved = limits
        resolved.maxToolCalls = max(1, maxToolCalls)
        return resolved
    }

    private static func validateRequiredContext(
        definition: AgentDefinition,
        context: AgentRunContext
    ) throws {
        if context.failureReason != nil {
            throw LoopAgentRuntimeError.contextUnavailable
        }
        if !definition.workflow.allowsEmptyRepositoryContext, context.repos.isEmpty {
            throw LoopAgentRuntimeError.repositoryContextEmpty
        }
    }

    private func definitionRules(_ definition: AgentDefinition) -> [AgentPromptRule] {
        definition.promptRules
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
            values["externalContextMarkdown"] = Self.mergingExternalContextMarkdown(
                values["externalContextMarkdown"],
                with: markdown
            )
        default:
            payload = next
        }
    }

    private func artifactTitle(for definition: AgentDefinition) -> String {
        definition.artifactTitle ?? definition.title
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

    /// 重试前必须原子清除旧错误与 finishedAt。若这一步落库失败，不能继续请求 Provider，
    /// 否则 UI 与历史会同时把同一个 Run 视为 failed/running 两种状态。
    private func persistRetryStarted(runID: UUID, usage: AgentUsage) async throws {
        try await runRepository?.restartFailedRun(runID: runID, usage: usage)
    }

    private func persistMessage(_ message: AgentMessage, runStatus: AgentRunStatus?) async throws {
        try await runRepository?.appendMessage(message, runStatus: runStatus)
    }

    /// Built-in Loop 没有 Provider item lifecycle，因此从它自己的强类型消息事实生成原生
    /// trace：reasoning summary、tool call 与带 attempt 的 tool result。这里不猜测固定阶段，
    /// 同一 prompt 是否出现哪些行完全由该次模型响应决定。
    private func emitTraceEvents(
        for message: AgentMessage,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async throws {
        for (partIndex, part) in message.parts.enumerated() {
            let trace: AgentTraceEvent?
            switch part {
            case .reasoning(let summary):
                trace = AgentTraceEvent(
                    id: "\(message.runID.uuidString):reasoning:\(message.id.uuidString)",
                    runID: message.runID,
                    backend: .builtinLoop,
                    providerEventID: message.id.uuidString,
                    sequence: message.sequence * 10 + partIndex,
                    kind: .reasoningSummary,
                    status: .completed,
                    title: String.l10n("agent.workspace.trace.kind.thinking"),
                    summary: summary,
                    details: [.init(
                        label: String.l10n("agent.workspace.timeline.reasoning"),
                        value: summary,
                        format: .markdown
                    )],
                    startedAt: message.createdAt,
                    completedAt: message.createdAt
                )
            case .toolCall(let call):
                trace = AgentTraceEvent(
                    id: "\(message.runID.uuidString):tool:\(call.id)",
                    runID: message.runID,
                    backend: .builtinLoop,
                    providerEventID: call.id,
                    sequence: call.sequence * 10,
                    kind: .tool,
                    status: .running,
                    title: call.name,
                    summary: String.l10n("agent.workspace.trace.tool.started"),
                    details: [.init(
                        label: String.l10n("agent.workspace.trace.input"),
                        value: call.rawInput ?? (try? call.input.jsonString()) ?? "{}",
                        format: .json
                    )],
                    startedAt: message.createdAt
                )
            case .toolResult(let result):
                var details = [AgentTraceDetail(
                    label: result.isError
                        ? String.l10n("error.loadFailed")
                        : String.l10n("agent.workspace.trace.output"),
                    value: (try? result.output.jsonString()) ?? "{}",
                    format: result.isError ? .error : .json
                )]
                details.append(contentsOf: result.attempts.map { attempt in
                    let error = attempt.errorSummary.map { ": \($0)" } ?? ""
                    return AgentTraceDetail(
                        label: String.localizedStringWithFormat(
                            String.l10n("agent.workspace.trace.attemptFormat"),
                            attempt.number
                        ),
                        value: "\(attempt.status.localizedTitle) · \(attempt.elapsedMilliseconds) ms\(error)",
                        format: attempt.errorSummary == nil ? .text : .error
                    )
                })
                trace = AgentTraceEvent(
                    id: "\(message.runID.uuidString):tool:\(result.toolCallID)",
                    runID: message.runID,
                    backend: .builtinLoop,
                    providerEventID: result.toolCallID,
                    sequence: result.sequence * 10,
                    kind: .tool,
                    status: Self.traceStatus(from: result.status),
                    title: result.toolName,
                    summary: result.status.localizedTitle,
                    details: details,
                    attempt: result.attempts.last?.number,
                    durationMilliseconds: result.elapsedMilliseconds,
                    // Tool result 自带总耗时但消息时间是完成时间；倒推开始时间可让 upsert
                    // 保留与 running 行一致的生命周期，而不是在完成时重置计时起点。
                    startedAt: message.createdAt.addingTimeInterval(
                        -Double(result.elapsedMilliseconds) / 1_000
                    ),
                    completedAt: message.createdAt
                )
            case .text:
                trace = nil
            }
            guard let trace else { continue }
            try await runRepository?.saveTraceEvent(trace)
            continuation.yield(.traceUpdated(trace))
        }
    }

    private static func traceStatus(from status: AgentToolResultStatus) -> AgentTraceStatus {
        switch status {
        case .completed: return .completed
        case .skipped, .rejected: return .skipped
        case .failed, .timedOut: return .failed
        }
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
        let trace = AgentTraceEvent(
            id: "\(runID.uuidString):runtime-error",
            runID: runID,
            backend: .builtinLoop,
            providerEventID: "runtime-error",
            sequence: Int.max - 1,
            kind: .error,
            status: .failed,
            title: String.l10n("error.loadFailed"),
            summary: message,
            details: [.init(
                label: String.l10n("error.loadFailed"),
                value: message,
                format: .error
            )],
            completedAt: Date()
        )
        do {
            try await runRepository?.saveTraceEvent(trace)
        } catch {
            // Trace 辅助诊断不能反过来吞掉真正的 run failure；终态持久化仍继续执行。
            AppLog.database.warning("Agent loop failure trace persistence failed: \(error.localizedDescription, privacy: .public)")
        }
        continuation.yield(.traceUpdated(trace))
        await persistRunStatus(runID: runID, status: .failed, errorMessage: message, finishedAt: Date())
        AppLog.ai.error("[AgentRuntime] run.failed runID=\(runID.uuidString, privacy: .public) error=\(message, privacy: .private)")
        continuation.yield(.runFailed(message))
    }

    private func finishCancelled(
        runID: UUID,
        session: AgentRunSession,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        _ = await session.finish(.cancelled)
        await persistRunStatus(runID: runID, status: .cancelled, finishedAt: Date())
        AppLog.ai.info("[AgentRuntime] run.cancelled runID=\(runID.uuidString, privacy: .public)")
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
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return AgentErrorSanitizer.sanitize(message)
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
                values["externalContextMarkdown"] = mergingExternalContextMarkdown(
                    values["externalContextMarkdown"],
                    with: detail
                )
            }
        }
        return values
    }

    /// 同一个 Run 允许多次收窄 External Search；Artifact 校验必须看到全部批次证据。
    /// 这里只合并 Runtime 的瞬时值，不改写模型消息历史，也不会把跨 Run 的网页内容串在一起。
    private static func mergingExternalContextMarkdown(
        _ existing: String?,
        with next: String
    ) -> String {
        let normalizedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedNext.isEmpty else { return existing ?? "" }
        guard let existing, !existing.isEmpty else { return normalizedNext }
        guard existing != normalizedNext else { return existing }
        return existing + "\n\n" + normalizedNext
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
    var attempts: [AgentToolExecutionAttempt]
    var sources: [AgentToolResultSource]

    var toolAudit: AgentToolAudit? { result?.toolAudit }

    init(
        result: AgentToolResult,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int,
        attempts: [AgentToolExecutionAttempt]
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
        self.attempts = attempts
        self.sources = result.sources
    }

    static func failure(
        call: AgentToolCall,
        message: String,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int = 0,
        attempts: [AgentToolExecutionAttempt] = []
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
            attempts: attempts,
            sources: []
        )
    }

    private init(
        result: AgentToolResult?,
        output: AgentJSONValue,
        status: AgentToolResultStatus,
        elapsedMilliseconds: Int,
        attempts: [AgentToolExecutionAttempt],
        sources: [AgentToolResultSource]
    ) {
        self.result = result
        self.output = output
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
        self.attempts = attempts
        self.sources = sources
    }
}
