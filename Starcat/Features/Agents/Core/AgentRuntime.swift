//
//  AgentRuntime.swift
//  Starcat
//
//  Agent 运行时协议与默认实现。
//
//  DefaultAgentRuntime 先执行 Starcat 本地 read-only tools,把真实上下文、工具输入输出和
//  Artifact 串成可审计事件流。后续接入 OpenAI tool-calling 时，应保留同一套事件语义。
//

import Foundation

/// Agent runtime 统一协议。
protocol AgentRuntime: Sendable {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent>
}

/// Runtime 的轻量执行配置。
///
/// 这里先把“计划/步骤/产物标题”从 `DefaultAgentRuntime.run` 中抽离出来。它不是完整
/// planner,只负责把不同内置 Agent 的固定执行骨架集中管理;后续接模型 tool-calling
/// 或用户确认写操作时,可以继续让 Runtime 事件流保持稳定。
private struct AgentExecutionProfile {
    let plan: [AgentPlanStep]
    let steps: [AgentRunStep]
    let artifactTitle: String

    init(definition: AgentDefinition, context: AgentRunContext) {
        switch definition.id {
        case BuiltInAgents.githubWeeklyReport.id:
            plan = Self.weeklyPlan(context: context)
            steps = Self.weeklySteps()
            artifactTitle = String.l10n("agent.runtime.artifact.weeklyReport.title")
        default:
            plan = Self.genericPlan(definition: definition, context: context)
            steps = Self.genericSteps(definition: definition)
            artifactTitle = definition.title
        }
    }

    private static func weeklyPlan(context: AgentRunContext) -> [AgentPlanStep] {
        [
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.goal.title"),
                detail: String.l10n("agent.runtime.plan.goal.detail")
            ),
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.context.title"),
                detail: String(format: String.l10n("agent.runtime.plan.context.detailFormat"), context.repos.count)
            ),
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.artifact.title"),
                detail: String.l10n("agent.runtime.plan.artifact.detail")
            )
        ]
    }

    private static func weeklySteps() -> [AgentRunStep] {
        [
            AgentRunStep(
                title: String.l10n("agent.runtime.step.parseGoal.title"),
                detail: String.l10n("agent.runtime.step.parseGoal.detail")
            ),
            AgentRunStep(
                title: String.l10n("agent.runtime.step.resolveRepos.title"),
                detail: String.l10n("agent.runtime.step.resolveRepos.detail")
            ),
            AgentRunStep(
                title: String.l10n("agent.runtime.step.externalSearch.title"),
                detail: String.l10n("agent.runtime.step.externalSearch.detail")
            ),
            AgentRunStep(
                title: String.l10n("agent.runtime.step.clusterTopics.title"),
                detail: String.l10n("agent.runtime.step.clusterTopics.detail")
            ),
            AgentRunStep(
                title: String.l10n("agent.runtime.step.buildDraft.title"),
                detail: String.l10n("agent.runtime.step.buildDraft.detail")
            )
        ]
    }

    private static func genericPlan(definition: AgentDefinition, context: AgentRunContext) -> [AgentPlanStep] {
        [
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.goal.title"),
                detail: String(format: String.l10n("agent.runtime.plan.genericGoal.detailFormat"), definition.title)
            ),
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.context.title"),
                detail: String(format: String.l10n("agent.runtime.plan.context.detailFormat"), context.repos.count)
            ),
            AgentPlanStep(
                title: String.l10n("agent.runtime.plan.artifact.title"),
                detail: String.l10n("agent.runtime.plan.genericArtifact.detail")
            )
        ]
    }

    private static func genericSteps(definition: AgentDefinition) -> [AgentRunStep] {
        definition.toolIDs.map { toolID in
            AgentRunStep(
                title: toolID,
                detail: String(format: String.l10n("agent.runtime.step.genericTool.detailFormat"), toolID)
            )
        }
    }
}

/// 默认 Agent 运行时。
struct DefaultAgentRuntime: AgentRuntime {

    private let stepStartDelayNanoseconds: UInt64
    private let stepCompletionDelayNanoseconds: UInt64
    private let textGenerator: any AgentTextGenerating
    private let toolRegistry: AgentToolRegistry
    private let runRepository: (any AgentRunRepositoryProtocol)?

    /// 创建 P0 默认运行时。
    ///
    /// 延迟值默认服务于 UI 演示：步骤不要瞬间闪过，用户能看清 Agent 正在推进。
    /// 测试可以把延迟注入为 0，避免单测依赖固定等待时间。
    init(
        stepStartDelayNanoseconds: UInt64 = 280_000_000,
        stepCompletionDelayNanoseconds: UInt64 = 420_000_000,
        textGenerator: any AgentTextGenerating = DisabledAgentTextGenerator(),
        toolRegistry: AgentToolRegistry = Self.makeDefaultToolRegistry(),
        runRepository: (any AgentRunRepositoryProtocol)? = nil
    ) {
        self.stepStartDelayNanoseconds = stepStartDelayNanoseconds
        self.stepCompletionDelayNanoseconds = stepCompletionDelayNanoseconds
        self.textGenerator = textGenerator
        self.toolRegistry = toolRegistry
        self.runRepository = runRepository
    }

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
                let runID = UUID()
                let terminationState = AgentRuntimeTerminationState()
                let task = Task {
                    var runLog: [String] = []
                    let executionProfile = AgentExecutionProfile(definition: definition, context: context)
                    let plan = executionProfile.plan
                    let steps = executionProfile.steps
                    var traceIndex = 0
                    var toolOutputIndex = 0
                    var artifactIndex = 0
                await Self.persistCreateRun(
                    repository: runRepository,
                    runID: runID,
                    definition: definition,
                    prompt: prompt,
                    context: context
                )
                guard !Task.isCancelled, await terminationState.shouldContinue() else {
                    await Self.persistRunStatus(
                        repository: runRepository,
                        runID: runID,
                        status: .cancelled,
                        finishedAt: Date()
                    )
                    await terminationState.markTerminal()
                    continuation.finish()
                    return
                }
                let tools: [any AgentTool]
                do {
                    tools = try toolRegistry.tools(for: definition.toolIDs)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await Self.persistRunStatus(
                        repository: runRepository,
                        runID: runID,
                        status: .failed,
                        errorMessage: message,
                        finishedAt: Date()
                    )
                    await terminationState.markTerminal()
                    continuation.yield(.runFailed(message))
                    continuation.finish()
                    return
                }
                var payload: AgentToolPayload = .none
                var values: [String: String] = [:]
                var draftMarkdown = ""
                var draftToolOutput: AgentToolOutput?

                continuation.yield(.runStarted(title: definition.title))
                await Self.persistRunStatus(repository: runRepository, runID: runID, status: .running)
                runLog.append("Run started: \(definition.title)")

                continuation.yield(.planCreated(plan))
                runLog.append("Plan created: \(plan.count) steps")

                for (index, tool) in tools.enumerated() {
                    let step = steps.indices.contains(index) ? steps[index] : AgentRunStep(
                        title: tool.displayName,
                        detail: String(format: String.l10n("agent.runtime.step.genericTool.detailFormat"), tool.id)
                    )
                    try? await Task.sleep(nanoseconds: stepStartDelayNanoseconds)
                    guard !Task.isCancelled else {
                        await Self.persistRunStatus(
                            repository: runRepository,
                            runID: runID,
                            status: .cancelled,
                            finishedAt: Date()
                        )
                        await terminationState.markTerminal()
                        continuation.yield(.runCancelled)
                        continuation.finish()
                        return
                    }

                    var running = step
                    running.status = .running
                    continuation.yield(.stepStarted(id: running.id))
                    continuation.yield(.stepUpdated(running))
                    await Self.persistStep(repository: runRepository, step: running, runID: runID, index: index)
                    runLog.append("Step started: \(running.title)")

                    let toolResult = await tool.execute(AgentToolInput(
                        prompt: prompt,
                        context: context,
                        values: values,
                        payload: payload
                    ))
                    switch toolResult.payload {
                    case .none:
                        break
                    case .externalContextMarkdown(let markdown):
                        // External Search 是补充上下文,不是下一个工具的唯一输入。
                        // 保存在 values 中,避免后续 topic payload 覆盖掉网络搜索结果。
                        values["externalContextMarkdown"] = markdown
                    default:
                        payload = toolResult.payload
                    }
                    if case .markdown(let markdown) = toolResult.payload {
                        draftMarkdown = markdown
                        draftToolOutput = toolResult.output
                    }

                    try? await Task.sleep(nanoseconds: stepCompletionDelayNanoseconds)
                    guard !Task.isCancelled else {
                        await Self.persistRunStatus(
                            repository: runRepository,
                            runID: runID,
                            status: .cancelled,
                            finishedAt: Date()
                        )
                        await terminationState.markTerminal()
                        continuation.yield(.runCancelled)
                        continuation.finish()
                        return
                    }

                    var completed = step
                    completed.status = toolResult.status.stepStatus
                    completed.detail = toolResult.output.summary
                    continuation.yield(.stepUpdated(completed))
                    await Self.persistStep(repository: runRepository, step: completed, runID: runID, index: index)
                    runLog.append("Step completed: \(completed.title)")

                    continuation.yield(.toolOutput(toolResult.output))
                    await Self.persistToolOutput(repository: runRepository, output: toolResult.output, runID: runID, index: toolOutputIndex)
                    toolOutputIndex += 1
                    continuation.yield(.trace(toolResult.trace))
                    await Self.persistTrace(repository: runRepository, trace: toolResult.trace, runID: runID, index: traceIndex)
                    traceIndex += 1
                    runLog.append("Tool output: \(toolResult.output.toolName) - \(toolResult.output.summary)")

                    if let action = toolResult.confirmationAction {
                        continuation.yield(.confirmationRequested(action))
                        runLog.append("Confirmation requested: \(action.title)")
                    }

                    if toolResult.status == .failed, Self.isBlockingFailure(tool) {
                        await Self.persistRunStatus(
                            repository: runRepository,
                            runID: runID,
                            status: .failed,
                            errorMessage: toolResult.output.detail,
                            finishedAt: Date()
                        )
                        await terminationState.markTerminal()
                        continuation.yield(.runFailed(toolResult.output.detail))
                        continuation.finish()
                        return
                    }
                }

                let markdown: String
                do {
                    let generated = try await textGenerator.generateAgentMarkdown(
                        definition: definition,
                        prompt: prompt,
                        context: context,
                        draftMarkdown: draftMarkdown
                    )
                    markdown = generated
                    continuation.yield(.assistantDelta(generated))
                    let llmTrace = AgentTraceSpan(
                        kind: "LLM",
                        title: String.l10n("agent.runtime.trace.llm.title"),
                        summary: "\(generated.count) chars",
                        input: String(draftMarkdown.prefix(1_200)),
                        output: String(generated.prefix(1_200)),
                        log: "model_output=markdown"
                    )
                    continuation.yield(.trace(llmTrace))
                    await Self.persistTrace(repository: runRepository, trace: llmTrace, runID: runID, index: traceIndex)
                    traceIndex += 1
                    runLog.append("LLM generation completed: \(generated.count) chars")
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let failedTrace = AgentTraceSpan(
                        kind: "LLM",
                        title: String.l10n("agent.runtime.trace.llm.title"),
                        summary: String.l10n("agent.runtime.trace.summary.failed"),
                        input: String(draftMarkdown.prefix(1_200)),
                        output: message,
                        log: "model_output=failed",
                        status: .failed
                    )
                    continuation.yield(.trace(failedTrace))
                    await Self.persistTrace(repository: runRepository, trace: failedTrace, runID: runID, index: traceIndex)
                    await Self.persistRunStatus(
                        repository: runRepository,
                        runID: runID,
                        status: .failed,
                        errorMessage: message,
                        finishedAt: Date()
                    )
                    await terminationState.markTerminal()
                    continuation.yield(.runFailed(message))
                    continuation.finish()
                    return
                }
                let markdownArtifact = AgentArtifact(
                    type: .markdown,
                    title: executionProfile.artifactTitle,
                    content: markdown
                )
                let artifactInput = draftToolOutput?.input ?? "artifact.buildMarkdown"
                let artifactOutput = draftToolOutput?.output ?? String(markdown.prefix(1_200))
                let artifactLog = draftToolOutput?.log ?? "Created Markdown artifact from generated output."
                let artifactTrace = AgentTraceSpan(
                    kind: "Artifact",
                    title: markdownArtifact.title,
                    summary: markdownArtifact.type.title,
                    input: artifactInput,
                    output: artifactOutput,
                    log: artifactLog,
                    relatedToolOutputID: draftToolOutput?.id,
                    relatedArtifactID: markdownArtifact.id
                )
                continuation.yield(.trace(artifactTrace))
                await Self.persistTrace(repository: runRepository, trace: artifactTrace, runID: runID, index: traceIndex)
                continuation.yield(.artifactCreated(markdownArtifact))
                await Self.persistArtifact(repository: runRepository, artifact: markdownArtifact, runID: runID, index: artifactIndex)
                artifactIndex += 1
                let logArtifact = AgentArtifact(
                    type: .log,
                    title: String.l10n("agent.runtime.artifact.runLog.title"),
                    content: Self.makeRunLog(runLog, context: context)
                )
                continuation.yield(.artifactCreated(logArtifact))
                await Self.persistArtifact(repository: runRepository, artifact: logArtifact, runID: runID, index: artifactIndex)
                await Self.persistRunStatus(
                    repository: runRepository,
                    runID: runID,
                    status: .completed,
                    assistantOutput: markdown,
                    finishedAt: Date()
                )
                await terminationState.markTerminal()
                continuation.yield(.runCompleted)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    guard await terminationState.requestCancellation() else { return }
                    await Self.persistRunStatus(
                        repository: runRepository,
                        runID: runID,
                        status: .cancelled,
                        finishedAt: Date()
                    )
                }
            }
        }
    }

    static func makeDefaultToolRegistry() -> AgentToolRegistry {
        do {
            return try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        } catch {
            preconditionFailure("Default Agent tool registry is invalid: \(error)")
        }
    }

    private static func makeRunLog(_ lines: [String], context: AgentRunContext) -> String {
        """
        # Agent Run Log

        > Runtime: DefaultAgentRuntime read-only tools
        > Context: \(context.sourceDescription)
        > Constraint: no write operations

        \(lines.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    private static func isBlockingFailure(_ tool: any AgentTool) -> Bool {
        // External Search 只是补充来源,不能因为 provider/API 暂时失败阻断本地周刊生成。
        // 核心工具仍保持 fail-fast,否则 artifact 可能基于缺失的本地上下文生成。
        tool.id != "external.search"
    }

    private static func persistCreateRun(
        repository: (any AgentRunRepositoryProtocol)?,
        runID: UUID,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) async {
        do {
            _ = try await repository?.createRun(
                id: runID,
                definition: definition,
                prompt: prompt,
                context: context,
                createdAt: Date()
            )
        } catch {
            AppLog.database.warning("Agent run persistence create failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "agent-history",
                operation: "agentRun.create",
                message: "Agent run history could not create a run record",
                underlying: DiagnosticEvent.summarize(error),
                context: ["runID": runID.uuidString]
            )
        }
    }

    private static func persistRunStatus(
        repository: (any AgentRunRepositoryProtocol)?,
        runID: UUID,
        status: AgentRunStatus,
        assistantOutput: String? = nil,
        errorMessage: String? = nil,
        finishedAt: Date? = nil
    ) async {
        do {
            try await repository?.updateRunStatus(
                runID: runID,
                status: status,
                assistantOutput: assistantOutput,
                errorMessage: errorMessage,
                finishedAt: finishedAt
            )
        } catch {
            AppLog.database.warning("Agent run persistence status failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "agent-history",
                operation: "agentRun.updateStatus",
                message: "Agent run history could not persist its final status",
                underlying: DiagnosticEvent.summarize(error),
                context: ["runID": runID.uuidString, "status": status.rawValue]
            )
        }
    }

    private static func persistStep(
        repository: (any AgentRunRepositoryProtocol)?,
        step: AgentRunStep,
        runID: UUID,
        index: Int
    ) async {
        do {
            try await repository?.upsertStep(step, runID: runID, index: index, updatedAt: Date())
        } catch {
            AppLog.database.warning("Agent run persistence step failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func persistTrace(
        repository: (any AgentRunRepositoryProtocol)?,
        trace: AgentTraceSpan,
        runID: UUID,
        index: Int
    ) async {
        do {
            try await repository?.appendTrace(trace, runID: runID, index: index, createdAt: Date())
        } catch {
            AppLog.database.warning("Agent run persistence trace failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func persistToolOutput(
        repository: (any AgentRunRepositoryProtocol)?,
        output: AgentToolOutput,
        runID: UUID,
        index: Int
    ) async {
        do {
            try await repository?.appendToolOutput(output, runID: runID, index: index, createdAt: Date())
        } catch {
            AppLog.database.warning("Agent run persistence tool output failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func persistArtifact(
        repository: (any AgentRunRepositoryProtocol)?,
        artifact: AgentArtifact,
        runID: UUID,
        index: Int
    ) async {
        do {
            try await repository?.appendArtifact(artifact, runID: runID, index: index)
        } catch {
            AppLog.database.warning("Agent run persistence artifact failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 协调 `AsyncStream` 终止和 runtime 主任务的状态写入。
///
/// `onTermination` 会在正常完成和外部取消时都触发,不能直接把 run 标为 cancelled。
/// 这个 actor 用一个终态标记把“已经完成 / 失败 / 主动取消”和“消费者提前取消 stream”
/// 分开,保证历史记录不会被误写,也不会漏掉取消态。
private actor AgentRuntimeTerminationState {
    private var isTerminal = false
    private var isCancellationRequested = false

    func markTerminal() {
        isTerminal = true
    }

    func shouldContinue() -> Bool {
        !isCancellationRequested
    }

    func requestCancellation() -> Bool {
        guard !isTerminal else { return false }
        isCancellationRequested = true
        return true
    }
}
