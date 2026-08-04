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

    static let maxSelectedRepoContexts = RAGMentionPickerLogic.maxSelectedRepoContexts
    private static let repositoryCatalogFreshnessInterval: TimeInterval = 60

    private var runtime: any AgentRuntime
    private var contextProvider: any AgentRunContextProviding
    private var runRepository: (any AgentRunRepositoryProtocol)?
    private var repositoryCatalog: (any AgentRepositoryCatalogProviding)?
    private var runTask: Task<Void, Never>?
    private var mentionTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var draftsByAgentID: [String: String] = [:]
    private var hasLoadedRepositoryCatalog = false
    private var isRepositoryCatalogLoading = false
    private var repositoryCatalogLoadID: UUID?
    private var repositoryCatalogLoadedAt: Date?
    private var isBatchingRepositoryPickerCriteria = false
    private var repositoryCatalogCandidates: [AgentRepositoryCandidate] = []
    private var repositoryCandidatesByID: [Int64: AgentRepositoryCandidate] = [:]
    private var repositorySourcesByID: [Int64: [AgentRepositorySource]] = [:]
    private var orderedRepositoryCandidates: [AgentRepositoryCandidate] = []
    private var matchedRepositoryCandidates = AgentRepositoryPickerMatches(candidates: [], candidateIDs: [])
    private(set) var repositoryPickerSnapshot = AgentRepositoryPickerSnapshot.empty
    /// 回归测试用：只有查询、筛选、来源、排序或目录变化才允许递增。
    private(set) var repositoryPickerDerivationCountForTesting = 0

    private(set) var agents: [AgentDefinition]
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
    var selectedToolCallID: String?
    var selectedHistoryRunID: String?
    var attachments: [AgentPromptAttachment] = []
    var selectedRepoContexts: [AIComposerRepoReference] = [] {
        didSet { rebuildRepositoryPickerPresentation() }
    }
    var explicitRepoMode: AIComposerExplicitRepoMode = .only
    var availableModels: [AIModelDescriptor] = []
    var selectedModelID: String?
    var webSearchEnabled = false
    var githubLinks: [AIComposerGitHubLink] = []
    var isContextPickerPresented = false
    var contextPickerQuery = "" {
        didSet {
            guard contextPickerQuery != oldValue else { return }
            rebuildRepositoryPickerMatches()
        }
    }
    var mentionCandidates: [RAGMentionCandidate] = []
    var repositoryPickerFilters = RAGComposerMentionFilters.empty {
        didSet {
            guard repositoryPickerFilters != oldValue, !isBatchingRepositoryPickerCriteria else { return }
            rebuildRepositoryPickerMatches()
        }
    }
    var repositoryPickerSortOption: RepoSortOption = .updatedDesc {
        didSet {
            guard repositoryPickerSortOption != oldValue else { return }
            rebuildRepositoryPickerOrder()
        }
    }
    var selectedRepositorySources: Set<AgentRepositorySource> = [] {
        didSet {
            guard selectedRepositorySources != oldValue, !isBatchingRepositoryPickerCriteria else { return }
            rebuildRepositoryPickerMatches()
        }
    }
    var isContextPickerFilterPresented = false
    var isContextPickerLanguageAddPresented = false
    var highlightedMentionIndex = 0
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

    var selectedKnowledgeAudit: AgentKnowledgeRetrievalAudit? {
        guard let selectedToolCallID else { return nil }
        return messages.lazy.compactMap { message in
            message.parts.lazy.compactMap { part -> AgentKnowledgeRetrievalAudit? in
                guard case .toolResult(let result) = part,
                      result.toolCallID == selectedToolCallID
                else { return nil }
                return result.toolAudit?.knowledgeRetrieval
            }.first
        }.first
    }

    var isRunning: Bool {
        status == .planning || status == .running || status == .waitingForConfirmation
    }

    var selectedAgentRequiresRepositories: Bool {
        guard let selectedAgent else { return false }
        if case .singleRepository = selectedAgent.workflow.repositoryContext { return true }
        return false
    }

    var selectedAgentSupportsRepositorySelection: Bool {
        selectedAgent?.workflow.allowsManualRepositoryOverride == true
    }

    var maximumSelectedRepoContexts: Int {
        selectedAgent?.workflow.maximumSelectedRepositories ?? 0
    }

    /// 与 RAG 仓库选择器保持一致：已选仓库固定置顶，即使它不匹配当前筛选词也不能消失。
    var displayedMentionCandidates: [RAGMentionCandidate] {
        if hasLoadedRepositoryCatalog {
            return repositoryPickerSnapshot.suggestions.map(\.mentionCandidate)
        }
        let candidatesByID = Dictionary(uniqueKeysWithValues: mentionCandidates.map { ($0.id, $0) })
        let selectedCandidates = selectedRepoContexts.map { reference in
            candidatesByID[reference.id] ?? RAGMentionCandidate(reference: reference)
        }
        let selectedIDs = Set(selectedCandidates.map(\.id))
        return selectedCandidates + mentionCandidates.filter { !selectedIDs.contains($0.id) }
    }

    var repositoryPickerTotalCount: Int {
        hasLoadedRepositoryCatalog ? repositoryPickerSnapshot.totalCount : mentionCandidates.count
    }

    var repositoryPickerMatchCount: Int {
        hasLoadedRepositoryCatalog ? repositoryPickerSnapshot.matchCount : mentionCandidates.count
    }

    var repositoryPickerDisplayedCount: Int {
        hasLoadedRepositoryCatalog ? repositoryPickerSnapshot.displayedCount : displayedMentionCandidates.count
    }

    var isRepositoryPickerTruncated: Bool {
        hasLoadedRepositoryCatalog && repositoryPickerSnapshot.isTruncated
    }

    /// 按钮和键盘发送共用同一校验，避免 UI 显示不可发送但 Return 仍启动 run。
    var canSubmit: Bool {
        guard !isRunning,
              let selectedAgent,
              selectedAgent.isEnabled,
              let selectedModelID,
              availableModels.contains(where: { $0.id == selectedModelID }),
              !effectivePrompt(for: selectedAgent).isEmpty
        else { return false }

        switch selectedAgent.workflow.repositoryContext {
        case .none, .weeklyHotspots:
            return true
        case .singleRepository:
            return selectedRepoContexts.count == 1 || (selectedRepoContexts.isEmpty && githubLinks.count == 1)
        }
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModelID })?.name ?? "—"
    }

    func selectAgent(_ agent: AgentDefinition) {
        guard !isRunning else { return }
        draftsByAgentID[selectedAgentID] = prompt
        selectedAgentID = agent.id
        prompt = draftsByAgentID[agent.id] ?? ""
        if agent.workflow.maximumSelectedRepositories == 0 {
            selectedRepoContexts = []
        } else if selectedRepoContexts.count > agent.workflow.maximumSelectedRepositories {
            selectedRepoContexts = Array(selectedRepoContexts.prefix(agent.workflow.maximumSelectedRepositories))
        }
        if case .singleRepository = agent.workflow.repositoryContext {
            explicitRepoMode = .only
        }
        handlePromptChanged()
    }

    /// `.xcstrings` 运行时切换后重建定义中的已解析 String，同时保留当前 Agent 身份。
    func refreshLocalizedDefinitions(_ definitions: [AgentDefinition]) {
        guard !isRunning else { return }
        agents = definitions
        if !agents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = agents.first?.id ?? ""
        }
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

    func configureRepositoryCatalog(_ catalog: any AgentRepositoryCatalogProviding) {
        guard !isRunning else { return }
        mentionTask?.cancel()
        repositoryCatalog = catalog
        repositoryCatalogLoadedAt = nil
        isRepositoryCatalogLoading = false
        repositoryCatalogLoadID = nil
        // 工作台建立依赖后立即预热目录；用户首次打开选择器时优先使用内存快照，
        // 不把四张表的读取、合并和首轮排序阻塞在点击动作上。
        refreshMentionCandidates(force: true)
    }

    func configureModelOptions(
        _ models: [AIModelDescriptor],
        defaultProviderID: String,
        defaultModelName: String
    ) {
        guard !isRunning else { return }
        availableModels = models
        if let selectedModelID, models.contains(where: { $0.id == selectedModelID }) {
            return
        }
        selectedModelID = models.first(where: {
            $0.providerID == defaultProviderID && $0.name == defaultModelName
        })?.id ?? models.first?.id
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
                guard !snapshot.context.hasUnavailableAttachmentBodies else {
                    // 附件正文按隐私契约不持久化，重启后不能假装仍拥有完整输入继续执行。
                    errorMessage = String.l10n("agent.loop.error.contextUnavailable")
                    return
                }
                resumePendingRun(snapshot, definition: definition)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run() {
        guard canSubmit, let selectedAgent else { return }
        let effectivePrompt = effectivePrompt(for: selectedAgent)

        runTask?.cancel()
        status = .planning
        runTitle = selectedAgent.title
        approvals = []
        messages = []
        usage = .zero
        artifacts = []
        selectedArtifactID = nil
        selectedToolCallID = nil
        assistantReasoningOutput = ""
        assistantOutput = ""
        errorMessage = nil

        let input = AgentRunInput(
            goal: effectivePrompt,
            agentID: selectedAgent.id,
            explicitRepos: selectedRepoContexts,
            explicitRepoMode: explicitRepoMode,
            selectedModelID: selectedModelID,
            attachments: attachments,
            githubLinks: githubLinks,
            webSearchEnabled: webSearchEnabled,
            source: "Agent Workspace"
        )
        let contextProvider = contextProvider
        let runtime = runtime
        // 输入已经冻结进 AgentRunInput，发送后立即清空 Composer 与当前 Agent 草稿。
        // 不能等 run 完成再清空，否则长任务期间输入框会一直残留已发送内容。
        prompt = ""
        draftsByAgentID[selectedAgent.id] = ""
        attachments = []
        dismissContextPicker()

        runTask = Task { [weak self] in
            let context = await contextProvider.makeContext(
                definition: selectedAgent,
                input: input
            )
            let stream = runtime.run(
                definition: selectedAgent,
                prompt: input.goal,
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
        var allowedContentTypes: [UTType] = [.plainText, .sourceCode, .json]
        if let markdown = UTType(filenameExtension: "md") {
            allowedContentTypes.append(markdown)
        }
        panel.allowedContentTypes = allowedContentTypes
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

    func selectArtifact(_ artifactID: UUID) {
        selectedArtifactID = artifactID
        selectedToolCallID = nil
    }

    func selectKnowledgeAudit(toolCallID: String) {
        selectedToolCallID = toolCallID
    }

    // MARK: - Composer context

    func handlePromptChanged() {
        guard !isRunning else { return }
        draftsByAgentID[selectedAgentID] = prompt
        githubLinks = AIComposerGitHubLinkDetector.links(in: prompt)
    }

    /// Agent 把 `@` 当成打开仓库选择器的命令，正文绑定值在整个过程中保持不变。
    func handleMentionTrigger() -> Bool {
        guard !isRunning, selectedAgentSupportsRepositorySelection else { return false }
        presentContextPicker()
        return true
    }

    func presentContextPicker() {
        guard !isRunning else { return }
        contextPickerQuery = ""
        isContextPickerPresented = true
        refreshMentionCandidates()
    }

    func handleContextPickerQueryChanged() {
        guard isContextPickerPresented else { return }
        highlightedMentionIndex = 0
    }

    func dismissContextPicker() {
        isContextPickerPresented = false
        isContextPickerFilterPresented = false
        isContextPickerLanguageAddPresented = false
        highlightedMentionIndex = 0
    }

    func handleContextPickerEscape() -> Bool {
        guard isContextPickerPresented else { return false }
        dismissContextPicker()
        return true
    }

    func moveMentionSelection(by offset: Int) {
        guard !displayedMentionCandidates.isEmpty else { return }
        highlightedMentionIndex = min(
            max(highlightedMentionIndex + offset, 0),
            displayedMentionCandidates.count - 1
        )
    }

    func selectHighlightedMention() {
        let candidates = displayedMentionCandidates
        guard candidates.indices.contains(highlightedMentionIndex) else { return }
        toggleRepoContext(candidates[highlightedMentionIndex])
    }

    func toggleRepoContext(_ candidate: RAGMentionCandidate) {
        guard !isRunning else { return }
        if let index = selectedRepoContexts.firstIndex(where: { $0.id == candidate.id }) {
            selectedRepoContexts.remove(at: index)
        } else {
            let maximum = maximumSelectedRepoContexts
            guard maximum > 0 else { return }
            if maximum == 1 {
                selectedRepoContexts.removeAll()
            }
            guard selectedRepoContexts.count < maximum else {
                errorMessage = String(
                    format: String.l10n("agent.workspace.repositoryPicker.selectionLimit"),
                    maximum
                )
                return
            }
            selectedRepoContexts.append(AIComposerRepoReference(
                id: candidate.id,
                owner: candidate.owner,
                name: candidate.name,
                fullName: candidate.fullName,
                language: candidate.language,
                starsCount: candidate.starsCount
            ))
        }
    }

    func removeRepoContext(_ reference: AIComposerRepoReference) {
        guard !isRunning else { return }
        selectedRepoContexts.removeAll { $0.id == reference.id }
    }

    func clearSelectedRepoContexts() {
        guard !isRunning else { return }
        selectedRepoContexts.removeAll()
    }

    func clearContextPickerQuery() {
        guard !isRunning else { return }
        contextPickerQuery = ""
        highlightedMentionIndex = 0
    }

    func resetRepositoryPickerFilters() {
        guard !isRunning else { return }
        // 两组筛选状态必须作为一次事务更新，否则 reset 会连续扫描两次全量目录。
        isBatchingRepositoryPickerCriteria = true
        repositoryPickerFilters = .empty
        selectedRepositorySources = []
        isBatchingRepositoryPickerCriteria = false
        rebuildRepositoryPickerMatches()
        highlightedMentionIndex = 0
    }

    func repositorySources(for repoID: Int64) -> [AgentRepositorySource] {
        repositorySourcesByID[repoID] ?? []
    }

    private func refreshMentionCandidates(force: Bool = false) {
        guard let repositoryCatalog, !isRepositoryCatalogLoading else { return }
        if !force,
           let repositoryCatalogLoadedAt,
           Date().timeIntervalSince(repositoryCatalogLoadedAt) < Self.repositoryCatalogFreshnessInterval {
            return
        }
        isRepositoryCatalogLoading = true
        let loadID = UUID()
        repositoryCatalogLoadID = loadID
        mentionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // 已取消的旧任务不能清掉新任务的 loading 状态。
                if self.repositoryCatalogLoadID == loadID {
                    self.isRepositoryCatalogLoading = false
                    self.repositoryCatalogLoadID = nil
                    self.mentionTask = nil
                }
            }
            do {
                // 目录读取合并本地 repos 与 Weekly / Trending / Discovery 缓存；Star 和
                // 知识库只作为筛选维度，绝不能再次成为 Agent 的候选准入条件。
                let candidates = try await repositoryCatalog.candidates()
                guard !Task.isCancelled, self.repositoryCatalogLoadID == loadID else { return }
                self.applyRepositoryCatalog(candidates)
            } catch {
                guard !Task.isCancelled else { return }
                // 后台预热失败不应污染工作台；用户已经打开选择器时才显示读取错误。
                if self.isContextPickerPresented {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 一次性建立全量目录的 ID/来源索引，并启动分层派生。目录规模来自本地多来源
    /// 去重结果，不能使用 RAG 知识库数量或 Star 数量代替。
    private func applyRepositoryCatalog(_ candidates: [AgentRepositoryCandidate]) {
        repositoryCatalogCandidates = candidates
        repositoryCandidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        repositorySourcesByID = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (candidate.id, candidate.sources.sorted { $0.rawValue < $1.rawValue })
        })
        hasLoadedRepositoryCatalog = true
        repositoryCatalogLoadedAt = Date()
        rebuildRepositoryPickerOrder()
        highlightedMentionIndex = 0
    }

    /// 目录或排序变化时才执行全量排序。查询与筛选继续复用该稳定顺序。
    private func rebuildRepositoryPickerOrder() {
        guard hasLoadedRepositoryCatalog else { return }
        orderedRepositoryCandidates = AgentRepositoryPickerLogic.ordered(
            candidates: repositoryCatalogCandidates,
            sort: repositoryPickerSortOption
        )
        rebuildRepositoryPickerMatches()
    }

    /// 查询、筛选和来源变化只做一次线性扫描，不再重复排序。
    private func rebuildRepositoryPickerMatches() {
        guard hasLoadedRepositoryCatalog, !isBatchingRepositoryPickerCriteria else { return }
        matchedRepositoryCandidates = AgentRepositoryPickerLogic.matched(
            orderedCandidates: orderedRepositoryCandidates,
            query: contextPickerQuery,
            filters: repositoryPickerFilters,
            selectedSources: selectedRepositorySources
        )
        repositoryPickerDerivationCountForTesting += 1
        rebuildRepositoryPickerPresentation()
    }

    /// 选择、取消与一键清空只重建最多 80 行的展示投影，不触发全量筛选或排序。
    private func rebuildRepositoryPickerPresentation() {
        guard hasLoadedRepositoryCatalog else { return }
        repositoryPickerSnapshot = AgentRepositoryPickerLogic.present(
            candidatesByID: repositoryCandidatesByID,
            matches: matchedRepositoryCandidates,
            selected: selectedRepoContexts,
            totalCount: repositoryCatalogCandidates.count
        )
        if repositoryPickerSnapshot.suggestions.isEmpty {
            highlightedMentionIndex = 0
        } else if highlightedMentionIndex >= repositoryPickerSnapshot.suggestions.count {
            highlightedMentionIndex = repositoryPickerSnapshot.suggestions.count - 1
        }
    }

    private func effectivePrompt(for agent: AgentDefinition) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return agent.workflow.usesDefaultPromptWhenEmpty ? agent.defaultPrompt : ""
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
        draftsByAgentID[selectedAgentID] = prompt
        selectedRepoContexts = snapshot.context.explicitRepos
            ?? snapshot.context.repos.map { repo in
                AIComposerRepoReference(
                    id: repo.id,
                    owner: repo.owner,
                    name: repo.name,
                    fullName: repo.fullName,
                    language: repo.language,
                    starsCount: repo.starsCount
                )
            }
        explicitRepoMode = snapshot.context.explicitRepoMode ?? .only
        githubLinks = snapshot.context.githubLinks ?? []
        webSearchEnabled = snapshot.context.webSearchEnabled ?? false
        if let modelID = snapshot.context.selectedModelID,
           availableModels.contains(where: { $0.id == modelID }) {
            selectedModelID = modelID
        }
        // 历史附件正文按隐私契约不可恢复，不能重新塞回可发送 Composer。
        attachments = []
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
        selectedToolCallID = nil
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
        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.plainText.identifier
        return AgentPromptAttachment(
            name: url.lastPathComponent,
            content: content,
            contentType: contentType
        )
    }
}

private extension RAGMentionCandidate {
    /// 历史 run 或当前筛选结果不含已选仓库时，用轻量引用补出置顶行。
    init(reference: AIComposerRepoReference) {
        id = reference.id
        owner = reference.owner
        name = reference.name
        fullName = reference.fullName
        language = reference.language
        starsCount = reference.starsCount
        ownerAvatar = nil
        chunkCount = 0
        hasAISummary = false
        hasPrivateNote = false
        normalizedSearchText = Self.normalize([reference.fullName, reference.language ?? ""].joined(separator: " "))
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
