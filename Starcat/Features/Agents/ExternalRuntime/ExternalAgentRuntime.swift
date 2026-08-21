//
//  ExternalAgentRuntime.swift
//  Starcat
//
//  把统一外部进程 Host 投影成现有 AgentRuntime 事件协议。
//
//  POC 不新增数据库字段，也不把外部 Session 当作 Starcat 历史事实源；每次 run 只在
//  内存中生成消息和 Artifact。固定业务 Agent 仍由 LoopAgentRuntime 持久化与恢复。
//

import Foundation

struct ExternalAgentRuntime: AgentRuntime {
    let adapter: any ExternalAgentProtocolAdapter
    let host: ExternalAgentRuntimeHost
    let distributionGate: DistributionGate
    let selectedModelName: String?

    init(
        adapter: any ExternalAgentProtocolAdapter,
        host: ExternalAgentRuntimeHost = ExternalAgentRuntimeHost(),
        distributionGate: DistributionGate = DistributionGate(),
        selectedModelName: String? = nil
    ) {
        self.adapter = adapter
        self.host = host
        self.distributionGate = distributionGate
        self.selectedModelName = selectedModelName
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
                continuation: continuation
            )
            let task = Task {
                let workingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("starcat-external-agent-\(runID.uuidString)", isDirectory: true)
                do {
                    try distributionGate.requireAvailable(.externalAgentRuntime)
                    try FileManager.default.createDirectory(
                        at: workingDirectory,
                        withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: workingDirectory) }

                    await projector.start(userPrompt: prompt)
                    let externalPrompt = ExternalAgentPromptBuilder.build(
                        definition: definition,
                        prompt: prompt,
                        context: context
                    )
                    let request = ExternalAgentRunRequest(
                        runID: runID,
                        prompt: externalPrompt,
                        modelName: selectedModelName,
                        workingDirectory: workingDirectory
                    )
                    let driver = try adapter.makeDriver(request: request)
                    try await host.execute(runID: runID, driver: driver) { event in
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
}

/// 把 Provider 事件归一化成 Workspace 已消费的消息、流式文本与终态。
private actor ExternalAgentEventProjector {
    private let runID: UUID
    private let definition: AgentDefinition
    private let continuation: AsyncStream<AgentRunEvent>.Continuation
    private var sequence = 0
    private var assistantText = ""
    private var finalAssistantText: String?
    private var reasoningText = ""
    private var latestUsage: AgentUsage?
    private var isTerminal = false

    init(
        runID: UUID,
        definition: AgentDefinition,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) {
        self.runID = runID
        self.definition = definition
        self.continuation = continuation
    }

    func start(userPrompt: String) {
        continuation.yield(.runStarted(title: definition.title))
        appendMessage(role: .user, parts: [.text(userPrompt)])
    }

    func consume(_ event: ExternalAgentProtocolEvent) {
        guard !isTerminal else { return }
        switch event {
        case .assistantDelta(let delta):
            assistantText += delta
            continuation.yield(.assistantDelta(delta))
        case .reasoningDelta(let delta):
            reasoningText += delta
            continuation.yield(.assistantReasoningDelta(delta))
        case .assistantMessage(let text, let usage):
            if !text.isEmpty { finalAssistantText = text }
            if let usage {
                latestUsage = usage
                continuation.yield(.usageUpdated(usage))
            }
        case .toolCall(let id, let name, let input, let rawInput):
            appendMessage(
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
            appendMessage(
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
        case .usage(let usage):
            latestUsage = usage
            continuation.yield(.usageUpdated(usage))
        case .completed:
            complete()
        case .cancelled:
            isTerminal = true
            continuation.yield(.runCancelled)
        case .failed(let message):
            isTerminal = true
            continuation.yield(.runFailed(message))
        }
    }

    func finishIfNeeded() {
        if !isTerminal { complete() }
    }

    func cancelIfNeeded() {
        guard !isTerminal else { return }
        isTerminal = true
        continuation.yield(.runCancelled)
    }

    func failIfNeeded(_ message: String) {
        guard !isTerminal else { return }
        isTerminal = true
        continuation.yield(.runFailed(message))
    }

    private func complete() {
        guard !isTerminal else { return }
        let text = finalAssistantText ?? assistantText
        if !text.isEmpty {
            var parts: [AgentMessagePart] = []
            if !reasoningText.isEmpty { parts.append(.reasoning(reasoningText)) }
            parts.append(.text(text))
            let messageID = appendMessage(role: .assistant, parts: parts, usage: latestUsage)
            if definition.artifactTypes.contains(.markdown) {
                continuation.yield(.artifactCreated(AgentArtifact(
                    type: .markdown,
                    title: definition.artifactTitle ?? definition.title,
                    content: text,
                    messageID: messageID,
                    sequence: sequence
                )))
            }
        }
        isTerminal = true
        continuation.yield(.runCompleted)
    }

    @discardableResult
    private func appendMessage(
        role: AgentMessageRole,
        parts: [AgentMessagePart],
        usage: AgentUsage? = nil
    ) -> UUID {
        let message = AgentMessage(
            runID: runID,
            role: role,
            turn: 0,
            sequence: sequence,
            parts: parts,
            usage: usage
        )
        sequence += 1
        continuation.yield(.messageAppended(message))
        return message.id
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
            "Respond in Markdown and use only the user request plus Frozen Starcat Context below.",
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
