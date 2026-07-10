//
//  AgentWorkspaceViewModel.swift
//  Starcat
//
//  Agent Workspace 的状态协调器。
//
//  ViewModel 只消费 AgentRunEvent 并维护 UI 状态，不知道具体 Agent 如何实现。
//  这是为了保证后续接入真实 tool-calling runtime 时，不需要重写 Workspace UI。
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentWorkspaceViewModel {

    private var runtime: any AgentRuntime
    private var contextProvider: any AgentRunContextProviding
    private var runRepository: (any AgentRunRepositoryProtocol)?
    private var runTask: Task<Void, Never>?
    private var activeRunID: UUID?

    let agents: [AgentDefinition]
    var selectedAgentID: String
    var prompt: String
    var runTitle: String = "Ready"
    var status: AgentRunStatus = .idle
    var planSteps: [AgentPlanStep] = []
    var steps: [AgentRunStep] = []
    var toolOutputs: [AgentToolOutput] = []
    var traceSpans: [AgentTraceSpan] = []
    var pendingConfirmations: [AgentConfirmationAction] = []
    var approvals: [AgentApprovalRequest] = []
    var messages: [AgentMessage] = []
    var usage: AgentUsage = .zero
    var artifacts: [AgentArtifact] = []
    var historyRuns: [AgentRunRecord] = []
    var selectedArtifactID: UUID?
    var selectedHistoryRunID: String?
    var assistantOutput: String = ""
    var errorMessage: String?

    init(
        agents: [AgentDefinition] = BuiltInAgents.all,
        runtime: any AgentRuntime = UnavailableAgentRuntime(),
        contextProvider: any AgentRunContextProviding = EmptyAgentRunContextProvider()
    ) {
        self.agents = agents
        self.runtime = runtime
        self.contextProvider = contextProvider
        self.selectedAgentID = agents.first?.id ?? ""
        self.prompt = ""
    }

    var selectedAgent: AgentDefinition? {
        agents.first { $0.id == selectedAgentID }
    }

    var selectedArtifact: AgentArtifact? {
        guard let selectedArtifactID else { return artifacts.first }
        return artifacts.first { $0.id == selectedArtifactID } ?? artifacts.first
    }

    var isRunning: Bool {
        status == .planning || status == .running || status == .waitingForConfirmation
    }

    func selectAgent(_ agent: AgentDefinition) {
        guard !isRunning else { return }
        selectedAgentID = agent.id
    }

    func configureContextProvider(_ provider: any AgentRunContextProviding) {
        guard !isRunning else { return }
        contextProvider = provider
    }

    func configureRuntime(_ runtime: any AgentRuntime) {
        guard !isRunning else { return }
        self.runtime = runtime
    }

    func configureRunRepository(_ repository: any AgentRunRepositoryProtocol) {
        guard !isRunning else { return }
        runRepository = repository
    }

    func reloadHistory(limit: Int = 20) async {
        guard let runRepository else { return }
        do {
            historyRuns = try await runRepository.recentRuns(limit: limit)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openHistoryRun(_ run: AgentRunRecord) async {
        guard !isRunning, let runRepository, let runID = UUID(uuidString: run.id) else { return }
        do {
            guard let snapshot = try await runRepository.snapshot(runID: runID) else { return }
            apply(snapshot)
            if snapshot.run.status == AgentRunStatus.waitingForConfirmation.rawValue,
               let definition = agents.first(where: { $0.id == snapshot.run.agentId }),
               snapshot.approvals.contains(where: { $0.status == .pending }) {
                resumePendingRun(snapshot, definition: definition)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run() {
        guard let selectedAgent, selectedAgent.isEnabled else { return }
        let effectivePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectivePrompt.isEmpty else { return }

        runTask?.cancel()
        status = .planning
        runTitle = selectedAgent.title
        planSteps = []
        steps = []
        toolOutputs = []
        traceSpans = []
        pendingConfirmations = []
        approvals = []
        messages = []
        usage = .zero
        artifacts = []
        selectedArtifactID = nil
        assistantOutput = ""
        errorMessage = nil

        let contextProvider = contextProvider
        let runtime = runtime

        runTask = Task { [weak self] in
            let context = await contextProvider.makeContext(
                definition: selectedAgent,
                prompt: effectivePrompt
            )
            let stream = runtime.run(
                definition: selectedAgent,
                prompt: effectivePrompt,
                context: context
            )
            for await event in stream {
                await MainActor.run {
                    self?.apply(event)
                }
            }
            await self?.reloadHistory()
        }
    }

    func cancel() {
        let runtime = runtime
        let runID = activeRunID
        runTask?.cancel()
        runTask = nil
        status = .cancelled
        if let runID {
            Task { await runtime.send(.cancel(runID: runID)) }
        }
    }

    func approve(_ approval: AgentApprovalRequest) {
        sendApprovalDecision(approval, decision: .approved)
    }

    func reject(_ approval: AgentApprovalRequest) {
        sendApprovalDecision(approval, decision: .rejected)
    }

    func copySelectedArtifact() {
        guard let content = selectedArtifact?.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
    }

    func exportSelectedArtifact() {
        guard let artifact = selectedArtifact else { return }
        let panel = NSSavePanel()
        panel.title = String.l10n("agent.workspace.exportPanel.title")
        panel.nameFieldStringValue = suggestedFilename(for: artifact)
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try artifact.content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ event: AgentRunEvent) {
        switch event {
        case .runStarted(let title):
            runTitle = title
            status = .running
        case .planCreated(let plan):
            planSteps = plan
        case .stepStarted:
            status = .running
        case .stepUpdated(let step):
            upsert(step)
        case .toolOutput(let output):
            toolOutputs.append(output)
        case .trace(let span):
            upsert(span)
        case .confirmationRequested(let action):
            if !pendingConfirmations.contains(where: { $0.id == action.id }) {
                pendingConfirmations.append(action)
            }
        case .approvalUpdated(let approval):
            upsert(approval)
            if approval.status == .pending {
                status = .waitingForConfirmation
            } else {
                pendingConfirmations.removeAll { $0.id == approval.id }
                if status == .waitingForConfirmation { status = .running }
            }
        case .messageAppended(let message):
            activeRunID = message.runID
            messages.append(message)
        case .usageUpdated(let nextUsage):
            usage = nextUsage
        case .assistantDelta(let text):
            assistantOutput += text
        case .artifactCreated(let artifact):
            artifacts.append(artifact)
            if selectedArtifactID == nil {
                selectedArtifactID = artifact.id
            }
        case .runCompleted:
            status = .completed
            runTask = nil
        case .runFailed(let message):
            status = .failed
            errorMessage = message
            runTask = nil
        case .runCancelled:
            status = .cancelled
            runTask = nil
        }
    }

    private func upsert(_ step: AgentRunStep) {
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            steps[index] = step
        } else {
            steps.append(step)
        }
    }

    private func upsert(_ span: AgentTraceSpan) {
        if let index = traceSpans.firstIndex(where: { $0.id == span.id }) {
            traceSpans[index] = span
        } else {
            traceSpans.append(span)
        }
    }

    private func apply(_ snapshot: AgentRunSnapshotRecord) {
        activeRunID = UUID(uuidString: snapshot.run.id)
        selectedHistoryRunID = snapshot.run.id
        selectedAgentID = snapshot.run.agentId
        runTitle = snapshot.run.title
        prompt = snapshot.run.userPrompt
        status = AgentRunStatus(rawValue: snapshot.run.status) ?? .idle
        planSteps = []
        messages = snapshot.messages
        usage = snapshot.messages.compactMap(\.usage).reduce(.zero) { partial, next in
            var merged = partial
            merged.merge(next)
            return merged
        }
        let projection = Self.legacyProjection(from: snapshot.messages)
        steps = projection.steps
        toolOutputs = projection.outputs
        traceSpans = projection.traces
        approvals = snapshot.approvals
        pendingConfirmations = approvals.filter { $0.status == .pending }.map { approval in
            AgentConfirmationAction(
                id: approval.id,
                title: approval.toolName,
                detail: approval.permission.rawValue,
                toolName: approval.toolName,
                input: (try? approval.input.jsonString()) ?? "{}"
            )
        }
        artifacts = snapshot.artifacts
        selectedArtifactID = artifacts.first?.id
        assistantOutput = Self.finalAssistantText(snapshot.messages)
        errorMessage = snapshot.run.errorMessage
    }

    /// 打开等待审批的历史 run 时只重建暂停状态。Runtime 会先发出 pending 事件并等待，
    /// 不会因为 App 重启或用户打开历史记录就自动执行原工具。
    private func resumePendingRun(
        _ snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) {
        let runtime = runtime
        runTask?.cancel()
        runTask = Task { [weak self] in
            let stream = runtime.resumePendingRun(snapshot: snapshot, definition: definition)
            for await event in stream {
                await MainActor.run { self?.apply(event) }
            }
            await self?.reloadHistory()
        }
    }

    private static func legacyProjection(
        from messages: [AgentMessage]
    ) -> (steps: [AgentRunStep], outputs: [AgentToolOutput], traces: [AgentTraceSpan]) {
        let calls = messages.flatMap { message in
            message.parts.compactMap { part -> AgentToolCall? in
                guard case .toolCall(let call) = part else { return nil }
                return call
            }
        }
        let results = Dictionary(uniqueKeysWithValues: messages.flatMap { message in
            message.parts.compactMap { part -> (String, AgentToolResultMessage)? in
                guard case .toolResult(let result) = part else { return nil }
                return (result.toolCallID, result)
            }
        })
        let steps = calls.map { call in
            let result = results[call.id]
            return AgentRunStep(
                title: call.name,
                detail: result?.status.rawValue ?? "pending",
                status: stepStatus(result?.status)
            )
        }
        let outputs = calls.compactMap { call -> AgentToolOutput? in
            guard let result = results[call.id] else { return nil }
            let output = (try? result.output.jsonString()) ?? "{}"
            return AgentToolOutput(
                toolName: call.name,
                summary: result.status.rawValue,
                detail: output,
                input: call.rawInput ?? ((try? call.input.jsonString()) ?? "{}"),
                output: output,
                log: "elapsed_ms=\(result.elapsedMilliseconds)"
            )
        }
        let traces = outputs.map { output in
            AgentTraceSpan(
                kind: "Tool",
                title: output.toolName,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log,
                status: output.summary == AgentToolResultStatus.completed.rawValue ? .completed : .failed,
                relatedToolOutputID: output.id
            )
        }
        return (steps, outputs, traces)
    }

    private func upsert(_ approval: AgentApprovalRequest) {
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
            approvals[index] = approval
        } else {
            approvals.append(approval)
        }
    }

    private func sendApprovalDecision(
        _ approval: AgentApprovalRequest,
        decision: AgentApprovalDecision
    ) {
        guard approval.status == .pending else { return }
        let runtime = runtime
        Task {
            await runtime.send(.decideApproval(
                runID: approval.runID,
                approvalID: approval.id,
                toolCallID: approval.toolCallID,
                decision: decision
            ))
        }
    }

    private static func stepStatus(_ status: AgentToolResultStatus?) -> AgentStepStatus {
        switch status {
        case .completed:
            return .completed
        case .skipped:
            return .skipped
        case .failed, .timedOut, .rejected:
            return .failed
        case nil:
            return .pending
        }
    }

    private static func finalAssistantText(_ messages: [AgentMessage]) -> String {
        messages.reversed().first(where: { $0.role == .assistant })?.parts.compactMap { part in
            guard case .text(let text) = part else { return nil }
            return text
        }.joined(separator: "\n") ?? ""
    }

    private func suggestedFilename(for artifact: AgentArtifact) -> String {
        switch artifact.type {
        case .markdown:
            return "starcat-weekly-report.md"
        case .log:
            return "starcat-agent-run.txt"
        }
    }
}
