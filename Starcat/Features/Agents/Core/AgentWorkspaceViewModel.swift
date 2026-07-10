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
import UniformTypeIdentifiers

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
    var runTitle: String = String.l10n("agent.workspace.status.ready")
    var status: AgentRunStatus = .idle
    var approvals: [AgentApprovalRequest] = []
    var messages: [AgentMessage] = []
    var usage: AgentUsage = .zero
    var artifacts: [AgentArtifact] = []
    var historyRuns: [AgentRunRecord] = []
    var selectedArtifactID: UUID?
    var selectedHistoryRunID: String?
    var attachments: [AgentPromptAttachment] = []
    var assistantReasoningOutput: String = ""
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
        approvals = []
        messages = []
        usage = .zero
        artifacts = []
        selectedArtifactID = nil
        assistantReasoningOutput = ""
        assistantOutput = ""
        errorMessage = nil

        let contextProvider = contextProvider
        let runtime = runtime
        let promptAttachments = attachments
        attachments = []

        runTask = Task { [weak self] in
            var context = await contextProvider.makeContext(
                definition: selectedAgent,
                prompt: effectivePrompt
            )
            context.attachments = promptAttachments
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

    func attachTextFiles() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("agent.workspace.attachment.panelTitle")
        panel.allowedContentTypes = [.plainText, .sourceCode, .json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        do {
            let additions = try panel.urls.map(Self.loadAttachment)
            let merged = attachments + additions
            guard merged.count <= Self.maxAttachmentCount else {
                throw AgentAttachmentError.tooManyFiles(maximum: Self.maxAttachmentCount)
            }
            guard merged.reduce(0, { $0 + $1.byteCount }) <= Self.maxAttachmentTotalBytes else {
                throw AgentAttachmentError.totalTooLarge(maximumKilobytes: Self.maxAttachmentTotalBytes / 1_024)
            }
            attachments = merged
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAttachment(_ attachment: AgentPromptAttachment) {
        guard !isRunning else { return }
        attachments.removeAll { $0.id == attachment.id }
    }

    func copySelectedArtifact() {
        guard let content = selectedArtifact?.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(content, forType: .string) {
            errorMessage = String.l10n("agent.workspace.inspector.copyFailed")
        }
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
            errorMessage = String(
                format: String.l10n("agent.workspace.inspector.exportFailedFormat"),
                error.localizedDescription
            )
        }
    }

    private func apply(_ event: AgentRunEvent) {
        switch event {
        case .runStarted(let title):
            runTitle = title
            status = .running
        case .approvalUpdated(let approval):
            upsert(approval)
            if approval.status == .pending {
                status = .waitingForConfirmation
            } else {
                if status == .waitingForConfirmation { status = .running }
            }
        case .messageAppended(let message):
            activeRunID = message.runID
            messages.append(message)
            if message.role == .assistant {
                // 流式缓冲只显示尚未落库的增量；assistant message 成为事实后立即清空。
                assistantReasoningOutput = ""
                assistantOutput = ""
            }
        case .usageUpdated(let nextUsage):
            usage = nextUsage
        case .assistantReasoningDelta(let text):
            assistantReasoningOutput += text
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

    private func apply(_ snapshot: AgentRunSnapshotRecord) {
        activeRunID = UUID(uuidString: snapshot.run.id)
        selectedHistoryRunID = snapshot.run.id
        selectedAgentID = snapshot.run.agentId
        runTitle = snapshot.run.title
        prompt = snapshot.run.userPrompt
        status = AgentRunStatus(rawValue: snapshot.run.status) ?? .idle
        messages = snapshot.messages
        usage = snapshot.messages.compactMap(\.usage).reduce(.zero) { partial, next in
            var merged = partial
            merged.merge(next)
            return merged
        }
        approvals = snapshot.approvals
        artifacts = snapshot.artifacts
        selectedArtifactID = artifacts.first?.id
        assistantReasoningOutput = ""
        assistantOutput = ""
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

    func suggestedFilename(for artifact: AgentArtifact) -> String {
        guard artifact.type == .markdown else { return "starcat-agent-run.txt" }
        switch selectedAgentID {
        case BuiltInAgents.githubWeeklyReport.id:
            return "starcat-weekly-report.md"
        case BuiltInAgents.repoInsight.id:
            return "starcat-repo-insight.md"
        default:
            return "starcat-agent-artifact.md"
        }
    }

    private static let maxAttachmentCount = 5
    private static let maxAttachmentFileBytes = 64 * 1_024
    private static let maxAttachmentTotalBytes = 128 * 1_024

    private static func loadAttachment(from url: URL) throws -> AgentPromptAttachment {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw AgentAttachmentError.readFailed(name: url.lastPathComponent, detail: error.localizedDescription)
        }
        guard data.count <= maxAttachmentFileBytes else {
            throw AgentAttachmentError.fileTooLarge(
                name: url.lastPathComponent,
                maximumKilobytes: maxAttachmentFileBytes / 1_024
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw AgentAttachmentError.notUTF8(name: url.lastPathComponent)
        }
        return AgentPromptAttachment(name: url.lastPathComponent, content: content)
    }
}

private enum AgentAttachmentError: LocalizedError {
    case tooManyFiles(maximum: Int)
    case fileTooLarge(name: String, maximumKilobytes: Int)
    case totalTooLarge(maximumKilobytes: Int)
    case notUTF8(name: String)
    case readFailed(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles(let maximum):
            return String(format: String.l10n("agent.workspace.attachment.tooManyFormat"), maximum)
        case .fileTooLarge(let name, let maximumKilobytes):
            return String(format: String.l10n("agent.workspace.attachment.fileTooLargeFormat"), name, maximumKilobytes)
        case .totalTooLarge(let maximumKilobytes):
            return String(format: String.l10n("agent.workspace.attachment.totalTooLargeFormat"), maximumKilobytes)
        case .notUTF8(let name):
            return String(format: String.l10n("agent.workspace.attachment.notUTF8Format"), name)
        case .readFailed(let name, let detail):
            return String(format: String.l10n("agent.workspace.attachment.readFailedFormat"), name, detail)
        }
    }
}
