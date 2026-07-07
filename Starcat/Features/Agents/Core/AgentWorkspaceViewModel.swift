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

    let agents: [AgentDefinition]
    var selectedAgentID: String
    var prompt: String
    var runTitle: String = "Ready"
    var status: AgentRunStatus = .idle
    var planSteps: [AgentPlanStep] = []
    var steps: [AgentRunStep] = []
    var toolOutputs: [AgentToolOutput] = []
    var traceSpans: [AgentTraceSpan] = []
    var artifacts: [AgentArtifact] = []
    var historyRuns: [AgentRunRecord] = []
    var selectedArtifactID: UUID?
    var selectedHistoryRunID: String?
    var assistantOutput: String = ""
    var errorMessage: String?

    init(
        agents: [AgentDefinition] = BuiltInAgents.all,
        runtime: any AgentRuntime = DefaultAgentRuntime(),
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
        status == .planning || status == .running
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
        runTask?.cancel()
        runTask = nil
        status = .cancelled
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
        selectedHistoryRunID = snapshot.run.id
        selectedAgentID = snapshot.run.agentId
        runTitle = snapshot.run.title
        prompt = snapshot.run.userPrompt
        status = AgentRunStatus(rawValue: snapshot.run.status) ?? .idle
        planSteps = []
        steps = snapshot.steps.map(Self.step(from:))
        toolOutputs = snapshot.toolOutputs.map(Self.toolOutput(from:))
        traceSpans = snapshot.traces.map(Self.trace(from:))
        artifacts = snapshot.artifacts.map(Self.artifact(from:))
        selectedArtifactID = artifacts.first?.id
        assistantOutput = snapshot.run.assistantOutput
        errorMessage = snapshot.run.errorMessage
    }

    private static func step(from record: AgentRunStepRecord) -> AgentRunStep {
        AgentRunStep(
            id: uuid(record.id),
            title: record.title,
            detail: record.detail,
            status: AgentStepStatus(rawValue: record.status) ?? .pending
        )
    }

    private static func trace(from record: AgentTraceRecord) -> AgentTraceSpan {
        AgentTraceSpan(
            id: uuid(record.id),
            kind: record.kind,
            title: record.title,
            summary: record.summary,
            input: record.input,
            output: record.output,
            log: record.log,
            status: AgentStepStatus(rawValue: record.status) ?? .pending,
            relatedToolOutputID: record.relatedToolOutputId.flatMap(UUID.init(uuidString:)),
            relatedArtifactID: record.relatedArtifactId.flatMap(UUID.init(uuidString:))
        )
    }

    private static func toolOutput(from record: AgentToolOutputRecord) -> AgentToolOutput {
        AgentToolOutput(
            id: uuid(record.id),
            toolName: record.toolName,
            summary: record.summary,
            detail: record.detail,
            input: record.input,
            output: record.output,
            log: record.log
        )
    }

    private static func artifact(from record: AgentArtifactRecord) -> AgentArtifact {
        AgentArtifact(
            id: uuid(record.id),
            type: AgentArtifactType(rawValue: record.type) ?? .log,
            title: record.title,
            content: record.content,
            createdAt: ISO8601DateFormatter.shared.date(from: record.createdAt) ?? Date()
        )
    }

    private static func uuid(_ raw: String) -> UUID {
        UUID(uuidString: raw) ?? UUID()
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
