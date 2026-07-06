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

    private let runtime: any AgentRuntime
    private var contextProvider: any AgentRunContextProviding
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
    var selectedArtifactID: UUID?
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
        self.prompt = agents.first?.defaultPrompt ?? ""
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
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .idle {
            prompt = agent.defaultPrompt
        }
    }

    func configureContextProvider(_ provider: any AgentRunContextProviding) {
        guard !isRunning else { return }
        contextProvider = provider
    }

    func run() {
        guard let selectedAgent, selectedAgent.isEnabled else { return }
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

        let currentPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = currentPrompt.isEmpty ? selectedAgent.defaultPrompt : currentPrompt
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
        panel.title = "Export Agent Artifact"
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

    private func suggestedFilename(for artifact: AgentArtifact) -> String {
        switch artifact.type {
        case .markdown:
            return "starcat-weekly-report.md"
        case .log:
            return "starcat-agent-run.txt"
        }
    }
}
