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
    private var currentRunSnapshot: AgentRunSnapshotRecord?
    private var externalUsageStartedAt: Double?
    private var hasRecordedExternalUsage = false
    /// Composer 在发送后会立即清空附件与临时选择；Inspector 必须持有本次 Run 的冻结上下文，
    /// 否则实时运行期间只能看到空的“下一次输入”，历史记录与实时记录也会表现不一致。
    private(set) var currentRunContext: AgentRunContext?
    private var hasInitializedHistory = false
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
    /// Provider 往往按 token 推送增量。若每个 token 都直接写入 Observable，SwiftUI 会在长回答中
    /// 反复解析 Markdown、测量时间线并滚动，最终可能饿死同在主线程消费的 Runtime 事件。
    /// 复用 RAG 已验证的展示节流器：完整文本仍保留在 buffer，UI 只接收有界、低频快照。
    private var assistantReasoningPresentationBuffer = AgentWorkspaceViewModel.makeStreamingPresentationBuffer()
    private var assistantPresentationBuffer = AgentWorkspaceViewModel.makeStreamingPresentationBuffer()
    /// 流式正文会频繁触发 SwiftUI 求值，但持久化消息、审批和产物通常没有变化。
    /// 投影缓存按独立 revision 失效，避免每个展示快照都重新扫描整条历史消息链。
    @ObservationIgnored private var cachedTimelinePresentation: (revision: Int, value: AgentRunPresentation)?
    @ObservationIgnored private var cachedTraceTimelineSnapshot: (revision: Int, value: AgentTraceTimelineSnapshot)?
    @ObservationIgnored private var traceEventIndexesByID: [String: Int] = [:]
    @ObservationIgnored private var traceEventIndexIsCurrent = false
    @ObservationIgnored private var isApplyingInternalTraceMutation = false
    private var timelinePresentationRevision = 0
    private var traceTimelineRevision = 0
    private(set) var repositoryPickerSnapshot = AgentRepositoryPickerSnapshot.empty
    /// 回归测试用：只有查询、筛选、来源、排序或目录变化才允许递增。
    private(set) var repositoryPickerDerivationCountForTesting = 0
    /// 回归测试用：证明一批 token 不会退化成同等数量的 SwiftUI 刷新。
    private(set) var streamingPresentationUpdateCountForTesting = 0
    /// 回归测试用：流式正文变化不应让持久化时间线和 Trace 快照跟着重建。
    private(set) var timelineProjectionBuildCountForTesting = 0
    private(set) var traceProjectionBuildCountForTesting = 0

    private(set) var agents: [AgentDefinition]
    var selectedAgentID: String
    /// 当前 Run 的原始用户问题只服务时间线展示；Composer `prompt` 始终代表下一次可编辑输入。
    /// 两者不能复用，否则快照刷新会把已经发送的内容重新塞回输入框。
    private(set) var currentRunUserPrompt = "" {
        didSet { invalidateTimelinePresentation() }
    }
    var prompt: String
    var runTitle: String = String.l10n("agent.workspace.status.ready")
    var status: AgentRunStatus = .idle {
        didSet { invalidateTimelinePresentation() }
    }
    var approvals: [AgentApprovalRequest] = [] {
        didSet { invalidateTimelinePresentation() }
    }
    var messages: [AgentMessage] = [] {
        didSet { invalidateTimelinePresentation() }
    }
    /// Runtime 原生过程按稳定 id 原位更新，避免 Codex 的 delta/completed 把一项拆成多行。
    var traceEvents: [AgentTraceEvent] = [] {
        didSet {
            traceTimelineRevision &+= 1
            cachedTraceTimelineSnapshot = nil
            guard !isApplyingInternalTraceMutation else { return }
            traceEventIndexIsCurrent = false
        }
    }
    var usage: AgentUsage = .zero
    var artifacts: [AgentArtifact] = [] {
        didSet { invalidateTimelinePresentation() }
    }
    var historyRuns: [AgentRunRecord] = []
    var inspectorTab: AgentInspectorTab = .run
    var selectedArtifactID: UUID?
    var selectedToolCallID: String?
    var selectedTraceEventID: String?
    var selectedHistoryRunID: String?
    var attachments: [AgentPromptAttachment] = []
    var selectedRepoContexts: [AIComposerRepoReference] = [] {
        didSet { rebuildRepositoryPickerPresentation() }
    }
    var explicitRepoMode: AIComposerExplicitRepoMode = .only
    var availableModels: [AIModelDescriptor] = []
    var selectedModelID: String?
    private(set) var runtimeBackend = AgentRuntimeBackend.builtinLoop
    private(set) var runtimeProviderName: String?
    private(set) var runtimeModelName: String?
    private(set) var runtimeReasoningEffort: String?
    private(set) var runtimeSelectionAvailable = true
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

    /// 返回与当前持久化 Run 事实对应的时间线快照。`assistantOutput` 的流式变化不在
    /// revision 中，因此 150ms 展示刷新只更新正在生成的叶子行，不再重扫历史消息。
    func timelinePresentation() -> AgentRunPresentation {
        let revision = timelinePresentationRevision
        if let cachedTimelinePresentation,
           cachedTimelinePresentation.revision == revision {
            return cachedTimelinePresentation.value
        }
        let value = AgentTimelineProjection.makePresentation(
            messages: messages,
            approvals: approvals,
            artifacts: artifacts,
            userPrompt: currentRunUserPrompt,
            status: status
        )
        cachedTimelinePresentation = (revision, value)
        timelineProjectionBuildCountForTesting &+= 1
        return value
    }

    /// Trace 父子树只在 Runtime Trace 事实变化时重建；展开状态仍由 View 本地投影，
    /// 既避免流式 Markdown 连带重算，也不会让折叠状态污染持久化模型。
    func traceTimelineSnapshot() -> AgentTraceTimelineSnapshot {
        let revision = traceTimelineRevision
        if let cachedTraceTimelineSnapshot,
           cachedTraceTimelineSnapshot.revision == revision {
            return cachedTraceTimelineSnapshot.value
        }
        let value = AgentTraceTimelinePresentation.makeSnapshot(traceEvents)
        cachedTraceTimelineSnapshot = (revision, value)
        traceProjectionBuildCountForTesting &+= 1
        return value
    }

    private func invalidateTimelinePresentation() {
        timelinePresentationRevision &+= 1
        cachedTimelinePresentation = nil
    }

    var selectedAgent: AgentDefinition? {
        agents.first { $0.id == selectedAgentID }
    }

    var selectedArtifact: AgentArtifact? {
        guard let selectedArtifactID else { return artifacts.first }
        return artifacts.first { $0.id == selectedArtifactID } ?? artifacts.first
    }

    var selectedTraceEvent: AgentTraceEvent? {
        guard let selectedTraceEventID else { return nil }
        return traceEvents.first { $0.id == selectedTraceEventID }
    }

    var currentRunRecord: AgentRunRecord? {
        currentRunSnapshot?.run
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

    var canRetryFailedRun: Bool {
        guard !isRunning,
              status == .failed,
              let snapshot = currentRunSnapshot,
              let definition = agents.first(where: { $0.id == snapshot.run.agentId && $0.isEnabled })
        else { return false }
        guard definition.id == selectedAgentID else { return false }
        return (try? AgentRunRetryPolicy.validatedRunID(for: snapshot)) != nil
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
              runtimeSelectionAvailable,
              !effectivePrompt(for: selectedAgent).isEmpty
        else { return false }
        // 外部 Runtime 拥有独立 Provider/Model 目录，不能被内置 Loop 的 selectedModelID
        // 阻断。DeepSeek 必须已经解析出已验证 Provider；Codex 目录失败时仍允许使用
        // App Server 默认模型，以保留其官方回退语义。
        if runtimeBackend == .builtinLoop {
            guard let selectedModelID,
                  availableModels.contains(where: { $0.id == selectedModelID })
            else { return false }
        } else if runtimeBackend == .deepSeekHarness {
            guard runtimeProviderName?.isEmpty == false,
                  runtimeModelName?.isEmpty == false
            else { return false }
        }

        switch selectedAgent.workflow.repositoryContext {
        case .none, .weeklyHotspots:
            return true
        case .singleRepository:
            return selectedRepoContexts.count == 1 || (selectedRepoContexts.isEmpty && githubLinks.count == 1)
        case .selectedRepositories:
            return !selectedRepoContexts.isEmpty
                && selectedRepoContexts.count <= selectedAgent.workflow.maximumSelectedRepositories
        }
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModelID })?.name ?? "—"
    }

    func selectAgent(_ agent: AgentDefinition) {
        guard !isRunning, agent.id != selectedAgentID else { return }
        draftsByAgentID[selectedAgentID] = prompt
        selectedAgentID = agent.id
        prompt = draftsByAgentID[agent.id] ?? ""
        clearRunPresentationForAgentChange()
        if agent.workflow.maximumSelectedRepositories == 0 {
            selectedRepoContexts = []
        } else if selectedRepoContexts.count > agent.workflow.maximumSelectedRepositories {
            selectedRepoContexts = Array(selectedRepoContexts.prefix(agent.workflow.maximumSelectedRepositories))
        }
        if case .singleRepository = agent.workflow.repositoryContext {
            explicitRepoMode = .only
        } else if case .selectedRepositories = agent.workflow.repositoryContext {
            explicitRepoMode = .only
        }
        handlePromptChanged()
    }

    /// 切换业务分类后，中栏必须表达“新 Agent 尚未运行”，不能继续展示上一个 Agent
    /// 的消息、步骤、用量或错误。Composer 草稿与仓库选择单独管理，不在这里误删。
    private func clearRunPresentationForAgentChange() {
        runTask?.cancel()
        runTask = nil
        activeRunID = nil
        currentRunSnapshot = nil
        currentRunContext = nil
        currentRunUserPrompt = ""
        runTitle = String.l10n("agent.workspace.status.ready")
        status = .idle
        approvals = []
        messages = []
        traceEvents = []
        usage = .zero
        artifacts = []
        inspectorTab = .run
        selectedArtifactID = nil
        selectedToolCallID = nil
        selectedTraceEventID = nil
        selectedHistoryRunID = nil
        resetStreamingPresentation(resetUpdateCount: true)
        errorMessage = nil
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

    /// 冻结下一次运行实际使用的后端和 Provider 模型。正在运行时拒绝替换，避免 UI
    /// 中途切换后让历史上下文记录成与当前进程不同的参数。
    func configureRuntimeSelection(
        backend: AgentRuntimeBackend,
        providerName: String? = nil,
        modelName: String?,
        reasoningEffort: String?,
        isAvailable: Bool = true
    ) {
        guard !isRunning else { return }
        runtimeBackend = backend
        runtimeProviderName = providerName
        runtimeModelName = modelName
        runtimeReasoningEffort = reasoningEffort
        runtimeSelectionAvailable = isAvailable
    }

    func configureRunRepository(_ repository: any AgentRunRepositoryProtocol) {
        guard !isRunning else { return }
        runRepository = repository
        hasInitializedHistory = false
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

    /// 每个 Workspace 生命周期只执行一次启动恢复。它不能并入普通 `reloadHistory`：
    /// Run 结束后的列表刷新也会调用后者，若重复执行就可能把本进程仍在推进的 Run
    /// 误判为上次启动遗留任务。
    func initializeHistory(limit: Int = 20) async {
        guard !hasInitializedHistory, let runRepository else {
            await reloadHistory(limit: limit)
            return
        }
        hasInitializedHistory = true
        do {
            _ = try await runRepository.recoverInterruptedRuns(
                errorMessage: String.l10n("agent.persistence.error.runInterrupted"),
                recoveredAt: Date()
            )
            historyRuns = try await runRepository.recentRuns(limit: limit)
        } catch {
            // 初始化失败后保留重试机会，避免一次瞬时数据库错误让历史永久空白。
            hasInitializedHistory = false
            errorMessage = error.localizedDescription
        }
    }

    func openHistoryRun(_ run: AgentRunRecord) async {
        guard !isRunning, let runRepository, let runID = UUID(uuidString: run.id) else { return }
        do {
            guard let snapshot = try await runRepository.snapshot(runID: runID) else { return }
            apply(snapshot)
            if case .usageUpdated(let historicalUsage) = await withEstimatedCost(.usageUpdated(usage)) {
                usage = historicalUsage
            }
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

    func retryFailedRun() {
        guard canRetryFailedRun,
              let snapshot = currentRunSnapshot,
              let definition = agents.first(where: { $0.id == snapshot.run.agentId })
        else { return }

        runTask?.cancel()
        status = .planning
        errorMessage = nil
        resetStreamingPresentation(resetUpdateCount: true)
        externalUsageStartedAt = Date().timeIntervalSince1970
        hasRecordedExternalUsage = false
        let runtime = runtime
        runTask = Task { [weak self] in
            let stream = runtime.retryFailedRun(snapshot: snapshot, definition: definition)
            for await event in stream {
                guard let self else { return }
                let pricedEvent = await self.withEstimatedCost(event)
                self.apply(pricedEvent)
            }
            await self?.reloadHistory()
            await self?.refreshActiveRunSnapshot()
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
        traceEvents = []
        usage = .zero
        artifacts = []
        inspectorTab = .run
        selectedArtifactID = nil
        selectedToolCallID = nil
        selectedTraceEventID = nil
        resetStreamingPresentation(resetUpdateCount: true)
        errorMessage = nil
        currentRunSnapshot = nil
        currentRunContext = nil
        selectedHistoryRunID = nil
        currentRunUserPrompt = effectivePrompt
        externalUsageStartedAt = Date().timeIntervalSince1970
        hasRecordedExternalUsage = false

        let input = AgentRunInput(
            goal: effectivePrompt,
            agentID: selectedAgent.id,
            explicitRepos: selectedRepoContexts,
            explicitRepoMode: explicitRepoMode,
            selectedModelID: runtimeBackend == .builtinLoop ? selectedModelID : nil,
            attachments: attachments,
            githubLinks: githubLinks,
            webSearchEnabled: webSearchEnabled,
            source: "Agent Workspace",
            runtimeBackend: runtimeBackend,
            runtimeProviderName: runtimeProviderName,
            runtimeModelName: runtimeModelName,
            runtimeReasoningEffort: runtimeReasoningEffort
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
            await MainActor.run {
                self?.currentRunContext = context
            }
            let stream = runtime.run(
                definition: selectedAgent,
                prompt: input.goal,
                context: context
            )
            for await event in stream {
                guard let self else { return }
                let pricedEvent = await self.withEstimatedCost(event)
                self.apply(pricedEvent)
            }
            await self?.reloadHistory()
            await self?.refreshActiveRunSnapshot()
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
        inspectorTab = .artifacts
        selectedArtifactID = artifactID
        selectedToolCallID = nil
        selectedTraceEventID = nil
    }

    func selectKnowledgeAudit(toolCallID: String) {
        selectedToolCallID = toolCallID
        selectedTraceEventID = nil
    }

    func selectInspectorTab(_ tab: AgentInspectorTab) {
        inspectorTab = tab
        selectedToolCallID = nil
        selectedTraceEventID = nil
    }

    func selectTraceEvent(_ eventID: String) {
        selectedTraceEventID = eventID
        selectedToolCallID = nil
    }

    func clearInspectorDetail() {
        selectedToolCallID = nil
        selectedTraceEventID = nil
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
        case .traceUpdated(let trace):
            upsert(trace)
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
                resetStreamingPresentation(resetUpdateCount: false)
            }
        case .usageUpdated(let nextUsage):
            usage = nextUsage
        case .assistantReasoningDelta(let text):
            if let snapshot = assistantReasoningPresentationBuffer.append(
                text,
                now: Date.timeIntervalSinceReferenceDate
            ) {
                assistantReasoningOutput = snapshot
                streamingPresentationUpdateCountForTesting += 1
            }
        case .assistantDelta(let text):
            if let snapshot = assistantPresentationBuffer.append(
                text,
                now: Date.timeIntervalSinceReferenceDate
            ) {
                assistantOutput = snapshot
                streamingPresentationUpdateCountForTesting += 1
            }
        case .artifactCreated(let artifact):
            artifacts.append(artifact)
            if selectedArtifactID == nil {
                selectedArtifactID = artifact.id
            }
        case .runCompleted:
            flushStreamingPresentation()
            status = .completed
            recordExternalUsageIfNeeded(status: .succeeded)
            runTask = nil
        case .runFailed(let message):
            flushStreamingPresentation()
            status = .failed
            errorMessage = message
            recordExternalUsageIfNeeded(status: .failed)
            runTask = nil
        case .runCancelled:
            flushStreamingPresentation()
            status = .cancelled
            recordExternalUsageIfNeeded(status: .cancelled)
            runTask = nil
        }
    }

    /// Runtime usage 帧先补齐费用再进入 Observable，避免右侧检查器短暂显示旧价格。
    /// 内置 Loop 也使用同一计算口径，但不会再次写入聚合事件，因为底层 HTTP 调用已经
    /// 由 `AIUsageRecorder` 逐次记录。
    private func withEstimatedCost(_ event: AgentRunEvent) async -> AgentRunEvent {
        guard case .usageUpdated(var nextUsage) = event,
              nextUsage.estimatedCost == nil,
              let model = runtimeModelName ?? currentRunContext?.runtimeModelName,
              let estimate = await AIModelPricingCatalog.shared.estimate(
                  model: model,
                  providerKind: runtimeProviderName ?? currentRunContext?.runtimeProviderName ?? runtimeBackend.rawValue,
                  operation: .chat,
                  inputTokens: nextUsage.inputTokens,
                  outputTokens: nextUsage.outputTokens,
                  cachedInputTokens: nextUsage.cachedTokens,
                  cacheWriteInputTokens: nextUsage.cacheWriteTokens
              )
        else { return event }
        nextUsage.estimatedCost = estimate.usd
        nextUsage.estimatedCostSource = estimate.source
        nextUsage.pricingModel = estimate.matchedModel
        nextUsage.pricingRevision = estimate.revision
        return .usageUpdated(nextUsage)
    }

    /// 外部 Runtime 不经过 Starcat 的 HTTP adapter，因此在终态补一条聚合事件；内置
    /// Runtime 已按模型请求逐条采集，若再次写入会造成 Agent 用量与费用翻倍。
    private func recordExternalUsageIfNeeded(status: AIUsageStatus) {
        guard runtimeBackend != .builtinLoop,
              !hasRecordedExternalUsage,
              let startedAt = externalUsageStartedAt
        else { return }
        hasRecordedExternalUsage = true
        let completedAt = Date().timeIntervalSince1970
        let hasUsage = usage.totalTokens > 0 || usage.inputTokens > 0 || usage.outputTokens > 0
        let event = AIUsageEvent(
            id: UUID().uuidString,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: max(0, Int((completedAt - startedAt) * 1_000)),
            providerId: runtimeProviderName ?? runtimeBackend.rawValue,
            providerKind: runtimeProviderName ?? runtimeBackend.rawValue,
            model: runtimeModelName ?? currentRunContext?.runtimeModelName ?? "unknown",
            feature: AIUsageFeature.agent.rawValue,
            phase: selectedAgentID,
            operation: AIUsageOperation.chat.rawValue,
            inputTokens: hasUsage ? usage.inputTokens : nil,
            outputTokens: hasUsage ? usage.outputTokens : nil,
            totalTokens: hasUsage ? usage.totalTokens : nil,
            cachedInputTokens: hasUsage ? usage.cachedTokens : nil,
            cacheWriteInputTokens: usage.cacheWriteTokens,
            reasoningOutputTokens: hasUsage ? usage.reasoningTokens : nil,
            itemCount: 1,
            usageSource: hasUsage ? AIUsageSource.provider.rawValue : AIUsageSource.unavailable.rawValue,
            status: status.rawValue,
            errorCategory: nil,
            correlationId: activeRunID?.uuidString,
            estimatedCostUSD: usage.estimatedCost.map { NSDecimalNumber(decimal: $0).doubleValue },
            costSource: usage.estimatedCostSource,
            pricingModel: usage.pricingModel,
            pricingRevision: usage.pricingRevision
        )
        Task { await AIUsageRecorder.shared.record(event) }
    }

    private static func makeStreamingPresentationBuffer() -> StreamingTextPresentationBuffer {
        StreamingTextPresentationBuffer(
            throttleInterval: 0.15,
            immediateCharacterCount: 256,
            // 运行中只展示尾部窗口；完整响应仍由 Runtime 消息持久化，不能让临时 Markdown
            // 随异常 Provider 输出无限增大并再次拖垮 Run Surface。
            maximumPresentedCharacterCount: 12_000
        )
    }

    private func resetStreamingPresentation(resetUpdateCount: Bool) {
        assistantReasoningPresentationBuffer = Self.makeStreamingPresentationBuffer()
        assistantPresentationBuffer = Self.makeStreamingPresentationBuffer()
        assistantReasoningOutput = ""
        assistantOutput = ""
        if resetUpdateCount {
            streamingPresentationUpdateCountForTesting = 0
        }
    }

    private func flushStreamingPresentation() {
        let now = Date.timeIntervalSinceReferenceDate
        if let snapshot = assistantReasoningPresentationBuffer.flush(now: now) {
            assistantReasoningOutput = snapshot
            streamingPresentationUpdateCountForTesting += 1
        }
        if let snapshot = assistantPresentationBuffer.flush(now: now) {
            assistantOutput = snapshot
            streamingPresentationUpdateCountForTesting += 1
        }
    }

    private func apply(_ snapshot: AgentRunSnapshotRecord) {
        currentRunSnapshot = snapshot
        currentRunContext = snapshot.context
        activeRunID = UUID(uuidString: snapshot.run.id)
        selectedHistoryRunID = snapshot.run.id
        // 历史快照切换 Agent 时保留每个 Agent 尚未发送的草稿；持久化 user_prompt
        // 只恢复到 Run 展示字段，绝不能覆盖 Composer 或草稿缓存。
        draftsByAgentID[selectedAgentID] = prompt
        selectedAgentID = snapshot.run.agentId
        runTitle = snapshot.run.title
        currentRunUserPrompt = snapshot.run.userPrompt
        prompt = draftsByAgentID[selectedAgentID] ?? ""
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
        // 历史页的过程标题、模型与推理强度必须来自该次 Run 的冻结上下文，不能继续
        // 显示当前 Composer 选择，否则 Codex/DeepSeek/Built-in 轨迹会被贴错后端标签。
        runtimeBackend = snapshot.context.runtimeBackend ?? .builtinLoop
        runtimeProviderName = snapshot.context.runtimeProviderName
        runtimeModelName = snapshot.context.runtimeModelName
        runtimeReasoningEffort = snapshot.context.runtimeReasoningEffort
        if let modelID = snapshot.context.selectedModelID,
           availableModels.contains(where: { $0.id == modelID }) {
            selectedModelID = modelID
        }
        // 历史附件正文按隐私契约不可恢复，不能重新塞回可发送 Composer。
        attachments = []
        status = AgentRunStatus(rawValue: snapshot.run.status) ?? .idle
        messages = snapshot.messages
        traceEvents = snapshot.traceEvents
        usage = snapshot.messages.compactMap(\.usage).reduce(.zero) { partial, next in
            var merged = partial
            merged.merge(next)
            return merged
        }
        approvals = snapshot.approvals
        artifacts = snapshot.artifacts
        inspectorTab = .run
        selectedArtifactID = artifacts.first?.id
        selectedToolCallID = nil
        selectedTraceEventID = nil
        resetStreamingPresentation(resetUpdateCount: true)
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
                guard let self else { return }
                let pricedEvent = await self.withEstimatedCost(event)
                self.apply(pricedEvent)
            }
            await self?.reloadHistory()
            await self?.refreshActiveRunSnapshot()
        }
    }

    private func refreshActiveRunSnapshot() async {
        guard let runRepository, let activeRunID else { return }
        do {
            currentRunSnapshot = try await runRepository.snapshot(runID: activeRunID)
        } catch {
            // 主错误（例如 Provider 失败）比历史刷新错误更重要，不能被后台刷新覆盖。
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func upsert(_ approval: AgentApprovalRequest) {
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
            approvals[index] = approval
        } else {
            approvals.append(approval)
        }
    }

    private func upsert(_ trace: AgentTraceEvent) {
        ensureTraceEventIndex()
        if let index = traceEventIndexesByID[trace.id] {
            isApplyingInternalTraceMutation = true
            traceEvents[index] = trace
            isApplyingInternalTraceMutation = false
        } else {
            let canAppendInOrder = traceEvents.last.map { last in
                !Self.traceEventPrecedes(trace, last)
            } ?? true

            if canAppendInOrder {
                let insertedIndex = traceEvents.count
                isApplyingInternalTraceMutation = true
                traceEvents.append(trace)
                isApplyingInternalTraceMutation = false
                traceEventIndexesByID[trace.id] = insertedIndex
                return
            }

            // 绝大多数 Runtime 事件按 sequence 单调到达，可直接 O(1) 追加。只有恢复或
            // Adapter 迟到事件破坏顺序时才复制并排序一次，避免每条事件都 O(n log n)。
            var reordered = traceEvents
            reordered.append(trace)
            reordered.sort(by: Self.traceEventPrecedes)
            isApplyingInternalTraceMutation = true
            traceEvents = reordered
            isApplyingInternalTraceMutation = false
            rebuildTraceEventIndex()
        }
    }

    private func ensureTraceEventIndex() {
        guard !traceEventIndexIsCurrent else { return }
        rebuildTraceEventIndex()
    }

    private func rebuildTraceEventIndex() {
        traceEventIndexesByID = Dictionary(
            uniqueKeysWithValues: traceEvents.enumerated().map { index, event in
                (event.id, index)
            }
        )
        traceEventIndexIsCurrent = true
    }

    private static func traceEventPrecedes(_ lhs: AgentTraceEvent, _ rhs: AgentTraceEvent) -> Bool {
        if lhs.sequence == rhs.sequence {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.sequence < rhs.sequence
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
