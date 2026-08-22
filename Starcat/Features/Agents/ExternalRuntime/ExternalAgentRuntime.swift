//
//  ExternalAgentRuntime.swift
//  Starcat
//
//  把统一外部进程 Host 投影成现有 AgentRuntime 事件协议。
//
//  外部 Runtime 与内置 Loop 共用 AgentRunRepository：消息、Artifact 和经过清洗的
//  Runtime Trace 都可恢复；原始 JSON-RPC 帧与隐藏思维链不落库。Codex 仅能调用
//  definition allowlist 内的 Starcat 只读工具。
//

import Foundation

struct ExternalAgentRuntime: AgentRuntime {
    let adapter: any ExternalAgentProtocolAdapter
    let host: ExternalAgentRuntimeHost
    let distributionGate: DistributionGate
    let selectedModelName: String?
    let reasoningEffort: String?
    let toolRegistry: AgentToolRegistry?
    let runRepository: (any AgentRunRepositoryProtocol)?

    init(
        adapter: any ExternalAgentProtocolAdapter,
        host: ExternalAgentRuntimeHost = ExternalAgentRuntimeHost(),
        distributionGate: DistributionGate = DistributionGate(),
        selectedModelName: String? = nil,
        reasoningEffort: String? = nil,
        toolRegistry: AgentToolRegistry? = nil,
        runRepository: (any AgentRunRepositoryProtocol)? = nil
    ) {
        self.adapter = adapter
        self.host = host
        self.distributionGate = distributionGate
        self.selectedModelName = selectedModelName
        self.reasoningEffort = reasoningEffort
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
            let projector = ExternalAgentEventProjector(
                runID: runID,
                definition: definition,
                backend: adapter.backend,
                runRepository: runRepository,
                continuation: continuation
            )
            let task = Task {
                let workingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("starcat-external-agent-\(runID.uuidString)", isDirectory: true)
                do {
                    try distributionGate.requireAvailable(.externalAgentRuntime)
                    try Self.validateRequiredContext(definition: definition, context: context)
                    let tools = try visibleTools(for: definition)
                    let toolCallHandler: ExternalAgentRuntimeHost.ToolCallHandler?
                    if tools.isEmpty {
                        toolCallHandler = nil
                    } else {
                        let executor = ExternalAgentToolExecutor(
                            registry: try requiredToolRegistry(),
                            allowedToolNames: Set(tools.map { $0.definition.name }),
                            prompt: prompt,
                            context: context
                        )
                        toolCallHandler = { request in
                            await executor.execute(request)
                        }
                    }
                    try FileManager.default.createDirectory(
                        at: workingDirectory,
                        withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: workingDirectory) }

                    await projector.start(userPrompt: prompt, context: context)
                    let externalPrompt = ExternalAgentPromptBuilder.build(
                        definition: definition,
                        prompt: prompt,
                        context: context
                    )
                    let request = ExternalAgentRunRequest(
                        runID: runID,
                        prompt: externalPrompt,
                        modelName: selectedModelName,
                        reasoningEffort: reasoningEffort,
                        workingDirectory: workingDirectory,
                        tools: tools.map(\.definition)
                    )
                    let driver = try adapter.makeDriver(request: request)
                    try await host.execute(
                        runID: runID,
                        driver: driver,
                        toolCallHandler: toolCallHandler
                    ) { event in
                        await projector.consume(event)
                    }
                    await projector.finishIfNeeded()
                } catch is CancellationError {
                    await host.cancel(runID: runID)
                    await projector.cancelIfNeeded()
                } catch DistributionGateError.directOnly {
                    await projector.failIfNeeded(ExternalAgentRuntimeError.directOnly.localizedDescription)
                } catch {
                    await projector.failIfNeeded(error.localizedDescription)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task { await host.cancel(runID: runID) }
            }
        }
    }

    func send(_ command: AgentRunCommand) async {
        if case .cancel(let runID) = command {
            await host.cancel(runID: runID)
        }
        // 外部 POC 首期只读，没有 Starcat approval decision 可转发。
    }

    private func visibleTools(for definition: AgentDefinition) throws -> [any AgentTool] {
        guard !definition.toolIDs.isEmpty else { return [] }
        let tools = try requiredToolRegistry().tools(named: definition.toolIDs)
        guard let nonReadTool = tools.first(where: { !$0.permission.isAutomaticRead }) else {
            return tools
        }
        throw ExternalAgentRuntimeError.protocolError(
            "External Agent Runtime cannot expose approval-gated tool: \(nonReadTool.definition.name)."
        )
    }

    private func requiredToolRegistry() throws -> AgentToolRegistry {
        guard let toolRegistry else {
            throw ExternalAgentRuntimeError.protocolError(
                "Starcat tool registry is unavailable for this external Agent."
            )
        }
        return toolRegistry
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
}

/// Codex dynamic tool request 的宿主执行边界。
///
/// Executor 再次校验 allowlist、schema 与权限，并在 actor 内保存工具链的轻量 payload。
/// 这使 `context_select_repo → external_search → artifact_build_*` 等既有工作流可以继续复用，
/// 同时不会把 SQLite、文件系统或任意 Swift capability 直接暴露给外部进程。
private actor ExternalAgentToolExecutor {
    private enum AttemptOutcome: Sendable {
        case completed(AgentToolResult)
        case timedOut
    }

    private let registry: AgentToolRegistry
    private let allowedToolNames: Set<String>
    private let prompt: String
    private let context: AgentRunContext
    private var values: [String: String] = [:]
    private var payload: AgentToolPayload = .none

    init(
        registry: AgentToolRegistry,
        allowedToolNames: Set<String>,
        prompt: String,
        context: AgentRunContext
    ) {
        self.registry = registry
        self.allowedToolNames = allowedToolNames
        self.prompt = prompt
        self.context = context
    }

    func execute(_ request: ExternalAgentToolRequest) async -> ExternalAgentToolExecutionResult {
        do {
            guard allowedToolNames.contains(request.name) else {
                throw LoopAgentRuntimeError.toolNotVisible(request.name)
            }
            let call = AgentToolCall(
                id: request.callID,
                name: request.name,
                input: request.input,
                rawInput: request.rawInput,
                sequence: 0
            )
            let tool = try registry.validatedTool(for: call)
            guard tool.permission.isAutomaticRead else {
                throw ExternalAgentRuntimeError.protocolError(
                    "External Agent Runtime rejected non-read-only tool: \(request.name)."
                )
            }
            let input = AgentToolInput(
                toolCallID: request.callID,
                arguments: request.input,
                prompt: prompt,
                context: context,
                values: values,
                payload: payload
            )
            let result = await executeWithPolicy(tool: tool, input: input)
            applyPayload(result.payload)
            return Self.project(result)
        } catch {
            return Self.failure(error.localizedDescription)
        }
    }

    private func executeWithPolicy(
        tool: any AgentTool,
        input: AgentToolInput
    ) async -> AgentToolResult {
        let policy = tool.definition.retryPolicy
        var attempt = 0
        while attempt <= policy.maxRetries {
            let outcome = await executeAttempt(
                tool: tool,
                input: input,
                timeoutMilliseconds: max(1, tool.definition.timeoutMilliseconds)
            )
            switch outcome {
            case .completed(let result):
                if result.status != .failed || attempt == policy.maxRetries {
                    return result
                }
            case .timedOut:
                if attempt == policy.maxRetries {
                    return Self.timedOut(toolName: tool.definition.name)
                }
            }
            attempt += 1
            if policy.initialBackoffMilliseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(policy.initialBackoffMilliseconds) * 1_000_000
                )
            }
        }
        return Self.timedOut(toolName: tool.definition.name)
    }

    private func executeAttempt(
        tool: any AgentTool,
        input: AgentToolInput,
        timeoutMilliseconds: Int
    ) async -> AttemptOutcome {
        await withTaskGroup(of: AttemptOutcome.self) { group in
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

    private func applyPayload(_ next: AgentToolPayload) {
        switch next {
        case .none:
            return
        case .externalContextMarkdown(let markdown):
            let existing = values["externalContextMarkdown"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            values["externalContextMarkdown"] = [existing, markdown]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        default:
            payload = next
        }
    }

    private static func project(_ result: AgentToolResult) -> ExternalAgentToolExecutionResult {
        let output: AgentJSONValue = .object([
            "status": .string(result.status.rawValue),
            "summary": .string(result.output.summary),
            "detail": .string(result.output.detail),
            "output": .string(result.output.output),
            "log": .string(result.output.log),
            "sources": .array(result.sources.map { source in
                .object([
                    "title": .string(source.title),
                    "url": .string(source.url),
                    "provider": source.provider.map(AgentJSONValue.string) ?? .null,
                ])
            }),
        ])
        return ExternalAgentToolExecutionResult(
            output: output,
            modelText: (try? output.jsonString()) ?? result.output.summary,
            isError: result.status == .failed,
            artifactMarkdown: {
                guard case .markdown(let markdown) = result.payload else { return nil }
                return markdown
            }()
        )
    }

    private static func failure(_ message: String) -> ExternalAgentToolExecutionResult {
        let output = AgentJSONValue.object([
            "status": .string(AgentToolStatus.failed.rawValue),
            "summary": .string(message),
        ])
        return ExternalAgentToolExecutionResult(
            output: output,
            modelText: (try? output.jsonString()) ?? message,
            isError: true,
            artifactMarkdown: nil
        )
    }

    private static func timedOut(toolName: String) -> AgentToolResult {
        let message = "Starcat tool timed out: \(toolName)."
        return AgentToolResult(
            status: .failed,
            output: AgentToolOutput(toolName: toolName, summary: message, detail: message),
            trace: AgentTraceSpan(
                kind: "tool",
                title: toolName,
                summary: message,
                input: "",
                output: message,
                log: message,
                status: .failed
            )
        )
    }
}

/// 把 Provider 事件归一化成 Workspace 已消费的消息、流式文本与终态。
private actor ExternalAgentEventProjector {
    private let runID: UUID
    private let definition: AgentDefinition
    private let backend: AgentRuntimeBackend
    private let runRepository: (any AgentRunRepositoryProtocol)?
    private let continuation: AsyncStream<AgentRunEvent>.Continuation
    private var sequence = 0
    private var traceSequence = 0
    private var traceSequences: [String: Int] = [:]
    private var traceStartedAt: [String: Date] = [:]
    private var traceSummaries: [String: String] = [:]
    private var traceDetails: [String: [AgentTraceDetail]] = [:]
    private var assistantText = ""
    private var finalAssistantText: String?
    private var runtimeModelName: String?
    private var latestUsage: AgentUsage?
    private var artifactCount = 0
    private var isTerminal = false
    private var hasTerminalErrorTrace = false

    init(
        runID: UUID,
        definition: AgentDefinition,
        backend: AgentRuntimeBackend,
        runRepository: (any AgentRunRepositoryProtocol)?,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) {
        self.runID = runID
        self.definition = definition
        self.backend = backend
        self.runRepository = runRepository
        self.continuation = continuation
    }

    func start(userPrompt: String, context: AgentRunContext) async {
        // External Runtime 的模型由各自工作台选择器提供；持久化时必须冻结这份运行上下文，
        // 不能回退到 Starcat 内置 Loop 的模型，也不能在终态把已经记录的模型清空。
        runtimeModelName = context.runtimeModelName
        if let runRepository {
            do {
                _ = try await runRepository.createRun(
                    id: runID,
                    definition: definition,
                    prompt: userPrompt,
                    context: context,
                    createdAt: Date()
                )
                try await runRepository.updateRunStatus(
                    runID: runID,
                    status: .running,
                    model: runtimeModelName,
                    usage: nil,
                    errorMessage: nil,
                    finishedAt: nil
                )
            } catch {
                AppLog.ai.error("[ExternalAgentRuntime] persist start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation.yield(.runStarted(title: definition.title))
        _ = await appendMessage(role: .user, parts: [.text(userPrompt)])
    }

    func consume(_ event: ExternalAgentProtocolEvent) async {
        guard !isTerminal else { return }
        switch event {
        case .trace(let providerEvent):
            await projectTrace(providerEvent)
        case .assistantDelta(let delta):
            assistantText += delta
            continuation.yield(.assistantDelta(delta))
        case .reasoningDelta(let delta):
            // raw reasoning 只服务当前 Run 的瞬时反馈；历史恢复依赖 Adapter 明确投影的
            // reasoning summary trace，不能把隐藏思维链混入 assistant message 落库。
            continuation.yield(.assistantReasoningDelta(delta))
        case .assistantMessage(let text, let usage):
            if !text.isEmpty { finalAssistantText = text }
            if let usage {
                latestUsage = usage
                continuation.yield(.usageUpdated(usage))
            }
        case .toolCall(let id, let name, let input, let rawInput):
            await projectTrace(ExternalAgentTraceEvent(
                id: "tool:\(id)",
                kind: .tool,
                status: .running,
                title: name,
                summary: "Starcat tool call",
                details: [AgentTraceDetail(
                    label: String.l10n("agent.workspace.trace.input"),
                    value: rawInput ?? (try? input.jsonString()) ?? "{}",
                    format: .json
                )],
                startedAt: Date()
            ))
            _ = await appendMessage(
                role: .assistant,
                parts: [.toolCall(AgentToolCall(
                    id: id,
                    name: name,
                    input: input,
                    rawInput: rawInput,
                    sequence: sequence
                ))]
            )
        case .toolResult(let id, let name, let output, let isError):
            let resultSummary = Self.nonBlank(output.objectValue?["summary"]?.stringValue)
            await projectTrace(ExternalAgentTraceEvent(
                id: "tool:\(id)",
                kind: .tool,
                status: isError ? .failed : .completed,
                title: name,
                summary: resultSummary ?? (isError ? "Tool call failed" : "Tool call completed"),
                details: [AgentTraceDetail(
                    label: isError
                        ? String.l10n("error.loadFailed")
                        : String.l10n("agent.workspace.trace.output"),
                    value: (try? output.jsonString()) ?? "{}",
                    format: isError ? .error : .json
                )],
                completedAt: Date()
            ))
            _ = await appendMessage(
                role: .tool,
                parts: [.toolResult(AgentToolResultMessage(
                    toolCallID: id,
                    toolName: name,
                    output: output,
                    isError: isError,
                    status: isError ? .failed : .completed,
                    sequence: sequence
                ))]
            )
        case .artifactMarkdown(let markdown, let toolCallID):
            let artifact = AgentArtifact(
                type: .markdown,
                title: definition.artifactTitle ?? definition.title,
                content: markdown,
                toolCallID: toolCallID,
                sequence: sequence
            )
            sequence += 1
            artifactCount += 1
            if let runRepository {
                try? await runRepository.appendArtifact(artifact, runID: runID)
            }
            continuation.yield(.artifactCreated(artifact))
        case .usage(let usage):
            latestUsage = usage
            continuation.yield(.usageUpdated(usage))
        case .completed:
            await complete()
        case .cancelled:
            isTerminal = true
            await persistTerminal(status: .cancelled, errorMessage: nil)
            continuation.yield(.runCancelled)
        case .failed(let message):
            if !hasTerminalErrorTrace {
                await projectFailureTrace(message)
            }
            isTerminal = true
            await persistTerminal(status: .failed, errorMessage: message)
            continuation.yield(.runFailed(message))
        }
    }

    func finishIfNeeded() async {
        if !isTerminal { await complete() }
    }

    func cancelIfNeeded() async {
        guard !isTerminal else { return }
        isTerminal = true
        await persistTerminal(status: .cancelled, errorMessage: nil)
        continuation.yield(.runCancelled)
    }

    func failIfNeeded(_ message: String) async {
        guard !isTerminal else { return }
        await projectFailureTrace(message)
        isTerminal = true
        await persistTerminal(status: .failed, errorMessage: message)
        continuation.yield(.runFailed(message))
    }

    private func complete() async {
        guard !isTerminal else { return }
        let text = finalAssistantText ?? assistantText
        if !text.isEmpty {
            let messageID = await appendMessage(role: .assistant, parts: [.text(text)], usage: latestUsage)
            if definition.artifactTypes.contains(.markdown), artifactCount == 0 {
                let artifact = AgentArtifact(
                    type: .markdown,
                    title: definition.artifactTitle ?? definition.title,
                    content: text,
                    messageID: messageID,
                    sequence: sequence
                )
                if let runRepository {
                    try? await runRepository.appendArtifact(artifact, runID: runID)
                }
                continuation.yield(.artifactCreated(artifact))
            }
        }
        isTerminal = true
        await persistTerminal(status: .completed, errorMessage: nil)
        continuation.yield(.runCompleted)
    }

    @discardableResult
    private func appendMessage(
        role: AgentMessageRole,
        parts: [AgentMessagePart],
        usage: AgentUsage? = nil
    ) async -> UUID {
        let message = AgentMessage(
            runID: runID,
            role: role,
            turn: 0,
            sequence: sequence,
            parts: parts,
            usage: usage
        )
        sequence += 1
        if let runRepository {
            do {
                try await runRepository.appendMessage(message, runStatus: .running)
            } catch {
                AppLog.ai.error("[ExternalAgentRuntime] persist message failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation.yield(.messageAppended(message))
        return message.id
    }

    private func projectTrace(_ providerEvent: ExternalAgentTraceEvent) async {
        let stableID = "\(runID.uuidString):\(providerEvent.id)"
        let assignedSequence: Int
        if let existing = traceSequences[providerEvent.id] {
            assignedSequence = existing
        } else {
            assignedSequence = traceSequence
            traceSequence += 1
            traceSequences[providerEvent.id] = assignedSequence
        }
        let startedAt = traceStartedAt[providerEvent.id] ?? providerEvent.startedAt ?? Date()
        traceStartedAt[providerEvent.id] = startedAt
        let summary = Self.nonBlank(providerEvent.summary) ?? traceSummaries[providerEvent.id]
        if let summary { traceSummaries[providerEvent.id] = summary }
        let details = Self.mergingTraceDetails(
            traceDetails[providerEvent.id] ?? [],
            with: providerEvent.details
        )
        traceDetails[providerEvent.id] = details
        let event = AgentTraceEvent(
            id: stableID,
            runID: runID,
            backend: backend,
            providerEventID: providerEvent.id,
            parentID: providerEvent.parentID.map { "\(runID.uuidString):\($0)" },
            sequence: assignedSequence,
            kind: providerEvent.kind,
            status: providerEvent.status,
            title: providerEvent.title,
            summary: summary,
            details: details,
            attempt: providerEvent.attempt,
            durationMilliseconds: providerEvent.durationMilliseconds,
            startedAt: startedAt,
            completedAt: providerEvent.completedAt
        )
        if event.kind == .error, event.status == .failed {
            hasTerminalErrorTrace = true
        }
        if let runRepository {
            do {
                try await runRepository.saveTraceEvent(event)
            } catch {
                AppLog.ai.error("[ExternalAgentRuntime] persist trace failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        continuation.yield(.traceUpdated(event))
    }

    /// Provider 的增量帧可能携带空字符串；空值不能覆盖前一帧已经保存的摘要。
    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// started/delta/completed 会反复 upsert 同一个 Provider event。后续帧经常只携带
    /// 新增字段，例如 tool completed 只有 Output；按 label 合并才能保留 started 时的 Input，
    /// 同时让 reasoning summary delta 替换同一块内容而不是无限追加重复详情。
    private static func mergingTraceDetails(
        _ existing: [AgentTraceDetail],
        with incoming: [AgentTraceDetail]
    ) -> [AgentTraceDetail] {
        var merged = existing
        for detail in incoming {
            if let index = merged.firstIndex(where: { $0.label == detail.label }) {
                merged[index] = detail
            } else {
                merged.append(detail)
            }
        }
        return merged
    }

    /// 进程退出、协议损坏与 watchdog 超时发生在 Adapter 事件之外，也必须进入同一条
    /// Runtime Trace。这样主错误横幅负责结论，过程行负责给出可展开的诊断上下文。
    private func projectFailureTrace(_ message: String) async {
        await projectTrace(ExternalAgentTraceEvent(
            id: "runtime-error:\(UUID().uuidString)",
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
        ))
    }

    private func persistTerminal(status: AgentRunStatus, errorMessage: String?) async {
        guard let runRepository else { return }
        do {
            try await runRepository.updateRunStatus(
                runID: runID,
                status: status,
                model: runtimeModelName,
                usage: latestUsage,
                errorMessage: errorMessage,
                finishedAt: Date()
            )
        } catch {
            AppLog.ai.error("[ExternalAgentRuntime] persist terminal failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum ExternalAgentPromptBuilder {
    static func build(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> String {
        var sections = [
            "# Starcat External Agent Runtime POC",
            "You are running inside Starcat's read-only external runtime boundary.",
            "Do not modify files, run shell commands, spawn subagents, or request additional permissions.",
            "Respond in Markdown and use only the user request, Frozen Starcat Context, and available Starcat dynamic tools.",
        ]
        if !definition.promptRules.isEmpty {
            sections.append("## Agent rules\n" + definition.promptRules.map { "- \($0.content)" }.joined(separator: "\n"))
        }
        sections.append("## User request\n\(prompt)")
        sections.append("## Frozen Starcat Context\nSource: \(context.sourceDescription)\nGenerated at: \(context.generatedAt.ISO8601Format())")

        if !context.repos.isEmpty {
            let repos = context.repos.map { repo in
                "- \(repo.fullName) | language=\(repo.language ?? "unknown") | stars=\(repo.starsCount) | \(repo.description ?? "no description")"
            }.joined(separator: "\n")
            sections.append("### Repositories\n\(repos)")
        }
        if !context.attachments.isEmpty {
            let attachments = context.attachments.map { attachment in
                "### Attachment: \(attachment.name)\n```text\n\(attachment.content)\n```"
            }.joined(separator: "\n\n")
            sections.append("## Attachments\n\(attachments)")
        }
        if let failureReason = context.failureReason {
            sections.append("## Context limitation\n\(failureReason)")
        }
        return sections.joined(separator: "\n\n")
    }
}
