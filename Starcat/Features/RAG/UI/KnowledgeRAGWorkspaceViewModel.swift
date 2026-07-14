//
//  KnowledgeRAGWorkspaceViewModel.swift
//  Starcat
//
//  知识库 RAG 工作台状态协调器。
//
//  关键约束：输入框的 @repo / 模型 / 附件是确定上下文，不从自然语言反推。
//  停止生成时必须保留用户问题；若已有流式文本则落库为未完成回答，若尚无输出则
//  仅保留用户消息并提供复制 / 原地编辑。
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// 刷新操作可能立即完成；保留最短可见时长，才能让用户确认点击已被接收。
enum KnowledgeRAGIndexRefreshPresentation {
    static let minimumVisibleDuration: Duration = .milliseconds(600)

    static func waitForMinimumDuration(
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async {
        let elapsed = startedAt.duration(to: clock.now)
        guard elapsed < minimumVisibleDuration else { return }
        try? await Task.sleep(for: minimumVisibleDuration - elapsed)
    }
}

@MainActor
@Observable
final class KnowledgeRAGWorkspaceViewModel {
    /// Debug 只用于当前窗口，仍必须有内存上界：Prompt/远程正文可能很大，长时间调试不应
    /// 因积累完整 payload 挤压正常回答渲染。
    private enum DebugTraceLimit {
        static let maxTraceCount = 24
        static let maxEventsPerTrace = 80
        static let maxPayloadUTF8Bytes = 16 * 1_024
        static let maxTotalPayloadUTF8Bytes = 512 * 1_024
    }
    private let dependencies: AppDependencies
    /// 打开独立详情窗需要共享主窗 HomeViewModel（star 状态 / registry）。
    private let homeViewModel: HomeViewModel
    private let conversationStore: any RAGConversationStoring
    /// Debug 历史是可随时删除的辅助文件，刻意与主会话 SQLite 解耦。
    private let debugFileStore: RAGDebugFileStore
    private var answerTask: Task<Void, Never>?
    /// 计时只覆盖用户实际等待的 RAG 主任务；标题生成和落库不延长用户看到的耗时。
    private var answerTimingTask: Task<Void, Never>?
    private var answerStartedAt: Date?
    /// 标题与首轮回答并行，但不同会话的轻量标题请求不能因用户切换历史而互相取消。
    /// generationID 是取消后的第二道保护：部分 Provider 即使收到 cancel 也可能稍后返回。
    private struct ConversationTitleGeneration {
        let id: UUID
        let debugTraceID: UUID?
        let task: Task<Void, Never>
    }
    private var conversationTitleGenerations: [UUID: ConversationTitleGeneration] = [:]
    /// store 读取未必会合作响应取消；generation 是提交结果前的第二道保护。
    private let conversationSelectionGate = RAGLatestRequestGate()
    private var remoteContextConsent: RAGRemoteContextConsent?
    private var linkDetectionTask: Task<Void, Never>?

    var conversations: [RAGConversationSummary] = []
    var conversationGroups: [RAGConversationGroup] = []
    /// 点选分组目录时设置；点选会话时清空。新会话写入此分组。
    var selectedGroupID: UUID?
    var selectedConversationID: UUID?
    var messages: [RAGStoredMessage] = []
    /// 在 messages 已经写入后递增。Answer Surface 监听它而非 selectedConversationID，
    /// 才能在历史 `LazyVStack` 真正拥有新内容后定位尾部。
    private(set) var loadedMessageSequence = 0
    var draftQuestion = ""
    var streamingAnswer = ""
    /// 流式阶段只提交稳定 Markdown chunk 与未闭合尾部，避免每个 delta 重解析完整回答。
    var streamingPresentation: StreamingMarkdownSnapshot?
    var answerState: RAGAnswerState = .idle
    /// 运行中每秒刷新，终态冻结为最后一个 LLM 响应结束时的真实耗时。
    var answerElapsedDuration: TimeInterval?
    /// 用户气泡原地编辑：非 nil 时该消息进入图 4 编辑态。
    var editingUserMessageID: UUID?
    var editingUserDraft = ""
    var queryPlan: RAGQueryPlan?
    var retrieval: RAGRetrievalResult?
    /// 当前轮默认可见的执行轨迹；完成后随 assistant message 持久化，Debug payload 不进入这里。
    var executionSteps: [RAGExecutionStep] = []
    var remoteBlocks: [RAGRemoteContextBlock] = []
    var pendingRemoteWorkItems: [RAGResolvedRemoteWorkItem] = []
    var approvedRemoteWorkItemIDs: Set<String> = []
    var selectedCitation: RAGCitation?
    var selectedCitationChunk: RAGChunk?
    /// 每次主动聚焦引用时递增；同 id 再点也会变，驱动右侧切回「证据」tab。
    private(set) var citationFocusSequence: Int = 0
    /// 回答内 S1 / 底部芯片要展开的「命中的分片」popover；nil 表示关闭。
    private(set) var citationChunkPopoverCitationID: UUID?
    var selectedRepoContexts: [Repo] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var attachments: [RAGComposerAttachment] = []
    var githubLinkContexts: [RAGGitHubLinkReference] = []
    /// 用户在 Composer 主动授权本轮联网。保持窗口级状态，连续追问无需重复开启；关闭后
    /// Planner 产生的普通 Web 请求会在执行层被清除，GitHub 实时请求仍需逐项确认。
    var webSearchEnabled = false
    /// 切换模型时立刻写入 AppSettings，关闭窗口后再开可恢复。
    var selectedModelID: String? {
        didSet {
            let trimmed = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if dependencies.settings.ragWorkspaceSelectedModelID != trimmed {
                dependencies.settings.ragWorkspaceSelectedModelID = trimmed
            }
        }
    }
    var knowledgeRepos: [Repo] = []
    private var isMentionPickerDismissed = false
    private var highlightedMentionRepoID: Int64?
    private var knowledgeCandidates: [RAGRepoCandidate] = []
    var indexCoverage = RAGIndexCoverage(
        knowledgeRepoCount: 0,
        indexedRepoCount: 0,
        totalChunks: 0,
        readyChunks: 0,
        pendingChunks: 0,
        failedChunks: 0,
        staleChunks: 0
    )
    /// Inspector 常显的本地知识库事实。回答流会用实际注入 Prompt 的快照覆盖它，避免面板与
    /// 当前轮模型看到的数据不一致；工作台初次打开时则主动读取一次，使用户无需先提问也能核验。
    var knowledgeBaseMetadataSnapshot: KnowledgeBaseMetadataSnapshot?
    /// RAG 工作台内「从 Stars 加入知识库」Sheet；空库空态 / 左栏 / 失败态共用。
    var isAddToLibraryPresented = false

    /// 知识库尚无任何仓库时，问答没有可检索边界。
    var isKnowledgeBaseEmpty: Bool {
        indexCoverage.knowledgeRepoCount == 0
    }
    var indexIssueChunks: [RAGIndexIssueKind: [RAGChunk]] = [:]
    var indexIssueHasMore: Set<RAGIndexIssueKind> = []
    var loadingIndexIssueKinds: Set<RAGIndexIssueKind> = []
    var isIndexing = false
    /// 直接透出 builder 的状态，让工作台显示真实构建阶段与数字进度。
    var indexingStatus: RAGIndexingStatus { dependencies.knowledgeRAGIndexBuilder.status }
    /// 自动入库与手动刷新共用 builder status，Inspector 因而能展示真实的本轮 embedding 进度。
    var indexEmbeddingProgress: (processedChunks: Int, totalChunks: Int)? {
        dependencies.knowledgeRAGIndexBuilder.status.embeddingProgress
    }
    /// 手动刷新结果在阶段切换后保持不变，供工作台连续展示 README 与分片进度。
    var indexRefreshSummary: RAGIndexRefreshSummary? { dependencies.knowledgeRAGIndexBuilder.refreshSummary }
    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var errorMessage: String? {
        didSet {
            if errorMessage == nil { workspaceError = nil }
        }
    }
    /// 友好错误模型与技术详情分离；错误 Sheet 只渲染前者，后者留在反馈诊断。
    var workspaceError: RAGWorkspaceError?
    private var retryQuestion: String?
    /// 最近一次实际请求的预算快照。用户开始编辑下一轮问题后，Composer 改为轻量预估，
    /// 避免把上轮的证据/远程上下文错误标记成当前输入。
    private var lastContextUsage: RAGContextUsage?
    /// 开关本身持久化；debug 事件只服务当前窗口，关闭开关立即清空，不进会话历史。
    var isDebugModeEnabled = false {
        didSet {
            if !isDebugModeEnabled { debugTraces = [] }
            if dependencies.settings.ragWorkspaceDebugModeEnabled != isDebugModeEnabled {
                dependencies.settings.ragWorkspaceDebugModeEnabled = isDebugModeEnabled
            }
        }
    }
    var debugTraces: [RAGDebugTrace] = []
    /// 当前会话已持久化的语义摘要；只覆盖 recent window 以外的消息，完整历史仍可浏览。
    private var conversationContextSummary: RAGConversationContextSummary?

    init(
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel,
        debugFileStore: RAGDebugFileStore = RAGDebugFileStore()
    ) {
        self.dependencies = dependencies
        self.homeViewModel = homeViewModel
        self.conversationStore = dependencies.ragConversationStore
        self.debugFileStore = debugFileStore
        let resolvedModelID = Self.resolveInitialModelID(
            savedModelID: dependencies.settings.ragWorkspaceSelectedModelID,
            availableModels: dependencies.knowledgeRAGChatModels,
            chatTask: dependencies.settings.aiChatTask
        )
        self.selectedModelID = resolvedModelID
        self.isDebugModeEnabled = dependencies.settings.ragWorkspaceDebugModeEnabled
        // init 内 didSet 不触发：把解析后的可用模型回写，清掉已删除/禁用的旧 ID。
        let trimmed = resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if dependencies.settings.ragWorkspaceSelectedModelID != trimmed {
            dependencies.settings.ragWorkspaceSelectedModelID = trimmed
        }
    }

    /// 优先恢复上次选用且仍可用的模型；否则对齐全局 chat task；再否则取列表首项。
    private static func resolveInitialModelID(
        savedModelID: String,
        availableModels: [AIModelDescriptor],
        chatTask: AIModelTaskConfiguration
    ) -> String? {
        let trimmed = savedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, availableModels.contains(where: { $0.id == trimmed }) {
            return trimmed
        }
        if let matched = availableModels.first(where: {
            $0.providerID == chatTask.providerID && $0.name == chatTask.resolvedModelName
        }) {
            return matched.id
        }
        return availableModels.first?.id
    }

    var isAnswering: Bool {
        switch answerState {
        case .planning, .retrieving, .awaitingRemoteContextConfirmation, .fetchingRemoteContext, .generating: return true
        default: return false
        }
    }

    /// 「停止且尚无 AI 输出」时，末条用户消息常显复制 / 编辑。
    var pendingActionUserMessageID: UUID? {
        guard !isAnswering, streamingAnswer.isEmpty else { return nil }
        guard let last = messages.last, last.role == .user else { return nil }
        return last.id
    }

    var availableModels: [AIModelDescriptor] { dependencies.knowledgeRAGChatModels }

    var historicalRemoteContextAudits: [RAGRemoteContextAudit] {
        messages.flatMap(\.remoteContextAudits)
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModelID })?.name
            ?? dependencies.settings.aiChatTask.resolvedModelName
    }

    /// 与 `AppDependencies.resolveRAGChatSelection` 同一优先级：选中模型参数优先，
    /// 否则回退全局 chat task，保证 UI 展示的窗口与实际 Service 请求一致。
    var selectedModelParameters: AIModelParameters {
        availableModels.first(where: { $0.id == selectedModelID })?.parameters
            ?? dependencies.settings.effectiveParameters(for: dependencies.settings.aiChatTask)
    }

    var composerContextUsage: RAGContextUsage {
        if draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastContextUsage {
            return lastContextUsage
        }
        return KnowledgeRAGPromptBuilder(
            // 与实际 Service 使用同一证据预算，避免 Composer 的 Context Usage 预览误导用户。
            maxEvidenceTokens: dependencies.settings.ragRetrievalSettings.evidenceTokenBudget,
            promptConfiguration: dependencies.settings.ragPromptSettings.generator,
            outputLanguage: LocaleStore.shared.selection.aiOutputLanguageDescriptor
        ).preview(
            question: draftQuestion,
            history: RAGConversationHistoryBuilder.build(
                from: messages,
                contextSummary: conversationContextSummary
            ),
            attachmentNames: attachments.map(\.filename),
            contextWindowTokens: selectedModelParameters.resolvedContextWindowTokens,
            maximumOutputTokens: selectedModelParameters.maxCompletionTokens
        )
    }

    /// 模型记录保存的是 provider profile ID；解析为枚举后，UI 才能复用统一的服务商 logo。
    var selectedModelProvider: AIServiceProvider? {
        guard let selectedModel = availableModels.first(where: { $0.id == selectedModelID }) else { return nil }
        return provider(for: selectedModel)
    }

    var selectedModelEndpoint: String? {
        let profileID = availableModels.first(where: { $0.id == selectedModelID })?.providerID
            ?? dependencies.settings.aiChatTask.providerID
        return dependencies.settings.aiProviderProfiles
            .first(where: { $0.id == profileID })?
            .baseURL
    }

    func provider(for model: AIModelDescriptor) -> AIServiceProvider? {
        dependencies.settings.aiProviderProfiles
            .first(where: { $0.id == model.providerID })?
            .provider
    }

    /// 提前阻断确定不可发送的附件条件。vision 能力在 OpenAI-compatible `/models` 中没有
    /// 统一字段，因此图片继续交给服务端校验；服务端拒绝时保留其原始可展示错误。
    var composerBlockingReason: String? {
        if attachments.count > 5 { return RAGAttachmentError.tooManyFiles.localizedDescription }
        if let attachment = attachments.first(where: { $0.sizeInBytes > 10 * 1_024 * 1_024 }) {
            return RAGAttachmentError.fileTooLarge(attachment.filename).localizedDescription
        }
        if attachments.reduce(Int64(0), { $0 + $1.sizeInBytes }) > 20 * 1_024 * 1_024 {
            return RAGAttachmentError.totalTooLarge.localizedDescription
        }
        if let attachment = attachments.first(where: { $0.handling == .unsupported }) {
            return RAGAttachmentError.unsupported(attachment.filename).localizedDescription
        }
        return nil
    }

    var mentionQuery: String? {
        guard let at = draftQuestion.lastIndex(of: "@") else { return nil }
        let suffix = draftQuestion[draftQuestion.index(after: at)...]
        guard !suffix.contains(where: \.isWhitespace) else { return nil }
        return String(suffix)
    }

    /// 当前 `@token` 对应的候选快照：已选置顶、关键词过滤、截断元数据。
    var mentionPickerSnapshot: RAGMentionPickerSnapshot {
        guard let query = mentionQuery else {
            return RAGMentionPickerSnapshot(
                suggestions: [],
                matchCount: 0,
                knowledgeCount: knowledgeCandidates.count,
                selectedCount: selectedRepoContexts.count,
                displayedCount: 0,
                isTruncated: false
            )
        }
        return RAGMentionPickerLogic.build(
            candidates: knowledgeCandidates,
            selected: selectedRepoContexts,
            query: query
        )
    }

    var mentionSuggestions: [Repo] {
        mentionPickerSnapshot.suggestions
    }

    func isMentionSelected(_ repo: Repo) -> Bool {
        selectedRepoContexts.contains { $0.id == repo.id }
    }

    /// 有未完成 `@token` 就展示弹层；无命中时走空态，不再直接关闭。
    var isMentionPickerPresented: Bool {
        !isMentionPickerDismissed && mentionQuery != nil
    }

    var highlightedMentionRepoIDValue: Int64? {
        let suggestions = mentionSuggestions
        guard !suggestions.isEmpty else { return nil }
        return suggestions.contains(where: { $0.id == highlightedMentionRepoID })
            ? highlightedMentionRepoID
            : suggestions.first?.id
    }

    func bootstrap() async {
        do {
            async let loadedConversations = conversationStore.listConversations()
            async let loadedGroups = conversationStore.listGroups()
            async let loadedCandidates = dependencies.ragCandidateRepository.fetchCandidates(
                plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge"),
                explicitRepoIDs: [],
                explicitMode: .only
            )
            conversations = try await loadedConversations
            conversationGroups = try await loadedGroups
            knowledgeCandidates = try await loadedCandidates
            knowledgeRepos = knowledgeCandidates.map(\.repo)
            try await refreshIndexCoverage()
            await refreshKnowledgeBaseMetadataSnapshot()
            if let first = conversations.first {
                await selectConversation(first.id)
            } else {
                await newConversation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 独立工作台打开期间，主窗口仍可能增删知识库 repo。每次边界变化都重新读取 SQL
    /// candidates，并移除已经不在知识库中的显式上下文，避免 @ picker 展示陈旧项目。
    func observeKnowledgeBoundaryChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            do {
                let candidates = try await dependencies.ragCandidateRepository.fetchCandidates(
                    plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "knowledge"),
                    explicitRepoIDs: [],
                    explicitMode: .only
                )
                knowledgeCandidates = candidates
                knowledgeRepos = candidates.map(\.repo)
                let currentRepoIDs = Set(knowledgeRepos.map(\.id))
                selectedRepoContexts.removeAll { !currentRepoIDs.contains($0.id) }
                try await refreshIndexCoverage()
                await refreshKnowledgeBaseMetadataSnapshot()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// README/notes/summary/metadata 的后台 source refresh 不由当前窗口发起，完成后仍要
    /// 立即反映 ready/pending/failed/stale 数量。
    func observeIndexChanges() async {
        let stream = NotificationCenter.default.notifications(named: .knowledgeRAGIndexDidChange)
        for await _ in stream {
            guard !Task.isCancelled else { break }
            try? await refreshIndexCoverage()
            await refreshKnowledgeBaseMetadataSnapshot()
        }
    }

    func newConversation() async {
        cancelAnswer()
        do {
            // 当前选中目录时，新会话直接归入该一级分组。
            let conversation = try await conversationStore.createConversation(
                title: nil,
                groupID: selectedGroupID
            )
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
            messages = []
            conversationContextSummary = nil
            debugTraces = []
            resetTurnState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectConversation(_ id: UUID) async {
        guard selectedConversationID != id || messages.isEmpty else { return }
        let requestGeneration = conversationSelectionGate.begin()
        cancelAnswer()
        do {
            guard let detail = try await conversationStore.loadConversation(id: id) else { return }
            // 用户可能已点选另一会话。即使旧的 SQLite 读取此刻才返回，也不能覆盖 UI。
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            selectedConversationID = id
            // 点选会话时目录选中态让位，避免误以为「新会话仍进目录」。
            selectedGroupID = nil
            messages = detail.messages
            conversationContextSummary = detail.contextSummary
            // Debug 文件按会话目录存放。会话切换时仅载入当前会话，避免不同问题的诊断混在一起。
            // 内存仍保持旧→新，才能让 FIFO 上限正确淘汰最早记录；Inspector 自己倒排展示。
            debugTraces = ((try? await debugFileStore.load(conversationID: id)) ?? [])
                .sorted { $0.startedAt < $1.startedAt }
            loadedMessageSequence &+= 1
            let initialCitation = messages.reversed().lazy.flatMap(\.citations).first
            resetTurnState()
            if let initialCitation { selectCitation(initialCitation) }
        } catch {
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ id: UUID) async {
        cancelConversationTitleGeneration(for: id)
        do {
            try await conversationStore.deleteConversation(id: id)
            // Debug 文件是可丢弃数据：删除失败不能让已成功的会话删除回滚或报错。
            try? await debugFileStore.delete(conversationID: id)
            conversations.removeAll { $0.id == id }
            if selectedConversationID == id {
                if let next = conversations.first {
                    selectedConversationID = nil
                    await selectConversation(next.id)
                } else {
                    await newConversation()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 用户手动重命名：立刻写库并刷新列表；若正在打字机生成标题则取消，避免覆盖。
    func renameConversation(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelConversationTitleGeneration(for: id)
        do {
            try await conversationStore.renameConversation(id: id, title: trimmed)
            updateConversationTitle(title: trimmed, for: id)
            // 列表按 updated_at 排序；重命名后刷新顺序，避免停留在旧位置。
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 置顶 / 取消置顶后刷新列表（置顶项排在最前）。
    func setConversationPinned(id: UUID, isPinned: Bool) async {
        do {
            try await conversationStore.setConversationPinned(id: id, isPinned: isPinned)
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveConversation(id: UUID, toGroupID groupID: UUID?) async {
        do {
            try await conversationStore.setConversationGroup(id: id, groupID: groupID)
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].groupID = groupID
            } else {
                conversations = try await conversationStore.listConversations()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createGroup(title: String?) async {
        do {
            let group = try await conversationStore.createGroup(title: title)
            conversationGroups.append(group)
            conversationGroups.sort { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.createdAt < rhs.createdAt
            }
            selectedGroupID = group.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameGroup(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await conversationStore.renameGroup(id: id, title: trimmed)
            if let index = conversationGroups.firstIndex(where: { $0.id == id }) {
                conversationGroups[index].title = trimmed
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(id: UUID) async {
        do {
            try await conversationStore.deleteGroup(id: id)
            conversationGroups.removeAll { $0.id == id }
            for index in conversations.indices where conversations[index].groupID == id {
                conversations[index].groupID = nil
            }
            if selectedGroupID == id {
                selectedGroupID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func conversations(inGroupID groupID: UUID?) -> [RAGConversationSummary] {
        conversations.filter { $0.groupID == groupID }
    }

    func send() {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, composerBlockingReason == nil else { return }
        do {
            try dependencies.entitlementGate.requirePro(.knowledgeRAG)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        editingUserMessageID = nil
        editingUserDraft = ""
        answerTask?.cancel()
        startAnswerTiming()
        answerTask = Task { [weak self] in
            await self?.runQuestion(question)
        }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        _ = finishAnswerTiming()
        // 主动停止不是失败，清掉可能残留的错误弹窗。
        if isAnswering {
            answerState = .cancelled
            errorMessage = nil
        }
    }

    func dismissError() {
        errorMessage = nil
        workspaceError = nil
    }

    /// 错误 Sheet 的动作只改变当前工作台状态，不做任何隐式网络重试或数据删除。
    func resolveWorkspaceErrorAction(_ action: RAGWorkspaceErrorAction) {
        switch action {
        case .retry, .checkNetwork:
            guard let retryQuestion, !isAnswering else { return }
            draftQuestion = retryQuestion
            dismissError()
            send()
        case .openAISettings:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            dismissError()
        case .removeAttachments:
            attachments = []
            dismissError()
        case .dismiss:
            dismissError()
        }
    }

    /// 复制停止态问题：写入剪贴板并回填底部输入框。
    @discardableResult
    func copyQuestionToComposerAndPasteboard(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        draftQuestion = trimmed
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(trimmed, forType: .string)
    }

    func beginEditUserMessage(_ messageID: UUID) {
        guard messages.contains(where: { $0.id == messageID && $0.role == .user }) else { return }
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        editingUserMessageID = messageID
        editingUserDraft = message.content
    }

    func cancelEditUserMessage() {
        editingUserMessageID = nil
        editingUserDraft = ""
    }

    /// 编辑态「发送」：删掉旧的无回答用户消息，用改后文案重新提问。
    func submitEditedUserMessage() {
        guard let messageID = editingUserMessageID else { return }
        let question = editingUserDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }
        do {
            try dependencies.entitlementGate.requirePro(.knowledgeRAG)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        editingUserMessageID = nil
        editingUserDraft = ""
        messages.removeAll { $0.id == messageID }
        conversationContextSummary = nil
        answerTask?.cancel()
        startAnswerTiming()
        answerTask = Task { [weak self] in
            guard let self else { return }
            try? await conversationStore.deleteMessage(id: messageID)
            conversations = (try? await conversationStore.listConversations()) ?? conversations
            await runQuestion(question)
        }
    }

    /// 点击发送即进入可见处理态，而不是等待 Planner 或首个流式 token 返回。
    ///
    /// RAG 的主链包含历史压缩、规划、检索与生成；计时从这里开始才能如实反映用户等待。
    private func startAnswerTiming() {
        answerTimingTask?.cancel()
        let startedAt = Date()
        answerStartedAt = startedAt
        answerElapsedDuration = 0
        answerState = .planning
        answerTimingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.answerStartedAt == startedAt else { return }
                self.answerElapsedDuration = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// 最后一个 LLM 事件结束时冻结耗时；后续本地落库不能被误算进用户等待时间。
    @discardableResult
    private func finishAnswerTiming() -> TimeInterval {
        answerTimingTask?.cancel()
        answerTimingTask = nil
        guard let startedAt = answerStartedAt else { return answerElapsedDuration ?? 0 }
        let duration = max(0, Date().timeIntervalSince(startedAt))
        answerStartedAt = nil
        answerElapsedDuration = duration
        return duration
    }

    func toggleRemoteWorkItem(_ id: String) {
        if approvedRemoteWorkItemIDs.contains(id) {
            approvedRemoteWorkItemIDs.remove(id)
        } else {
            approvedRemoteWorkItemIDs.insert(id)
        }
    }

    func confirmRemoteContext() {
        let consent = remoteContextConsent
        pendingRemoteWorkItems = []
        Task { await consent?.resolve(approvedRemoteWorkItemIDs) }
    }

    func skipRemoteContext() {
        let consent = remoteContextConsent
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        Task { await consent?.resolve([]) }
    }

    /// 历史推荐问题点击后恢复它创建时的知识库范围，并清掉当前输入框里互不相关的附件、
    /// GitHub 链接和旧联网授权。若仓库已离开知识库则明确报错，绝不静默扩大到全库。
    func sendSuggestedQuestion(_ action: RAGSuggestedQuestionAction) {
        guard !isAnswering else { return }
        let repos = action.repoIDs.compactMap { repoID in
            knowledgeRepos.first(where: { $0.id == repoID })
        }
        guard repos.count == action.repoIDs.count else {
            errorMessage = String.l10n("rag.workspace.guidance.repoUnavailable")
            return
        }
        selectedRepoContexts = repos
        explicitRepoMode = action.explicitRepoMode
        attachments = []
        githubLinkContexts = []
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        draftQuestion = action.question
        send()
    }

    /// 切换 `@` 多选：写入 / 移除 chip，但不清掉输入框里的 `@token`，便于连续勾选。
    func toggleMention(_ repo: Repo) {
        if let index = selectedRepoContexts.firstIndex(where: { $0.id == repo.id }) {
            selectedRepoContexts.remove(at: index)
        } else {
            selectedRepoContexts.append(repo)
        }
        highlightedMentionRepoID = repo.id
    }

    /// 全选当前列表可见结果（含已选置顶项与当前过滤命中）。
    func selectAllVisibleMentions() {
        for repo in mentionSuggestions where !selectedRepoContexts.contains(where: { $0.id == repo.id }) {
            selectedRepoContexts.append(repo)
        }
        highlightedMentionRepoID = mentionSuggestions.first?.id ?? highlightedMentionRepoID
    }

    /// 清空全部已选仓库 chip；不影响输入框 `@token`。
    func clearSelectedMentions() {
        selectedRepoContexts = []
        highlightedMentionRepoID = mentionSuggestions.first?.id
    }

    /// 方案 A：只清 `@` 后关键词，保留 `@`，弹层继续展示全量候选。
    func clearMentionFilter() {
        guard let at = draftQuestion.lastIndex(of: "@") else { return }
        let suffix = draftQuestion[draftQuestion.index(after: at)...]
        guard !suffix.contains(where: \.isWhitespace), !suffix.isEmpty else { return }
        draftQuestion.removeSubrange(draftQuestion.index(after: at)..<draftQuestion.endIndex)
        isMentionPickerDismissed = false
        highlightedMentionRepoID = nil
    }

    /// `@repo` 候选由输入框持有键盘焦点。这里仅移动高亮，不改变输入内容，Enter 才会
    /// 切换明确的 repo context，避免方向键意外修改问题文本。
    func moveMentionSelection(by offset: Int) {
        let suggestions = mentionSuggestions
        guard !suggestions.isEmpty else { return }
        let currentIndex = highlightedMentionRepoIDValue.flatMap { id in
            suggestions.firstIndex(where: { $0.id == id })
        } ?? (offset > 0 ? -1 : suggestions.count)
        let nextIndex = min(max(currentIndex + offset, 0), suggestions.count - 1)
        highlightedMentionRepoID = suggestions[nextIndex].id
    }

    func selectHighlightedMention() {
        guard let id = highlightedMentionRepoIDValue,
              let repo = mentionSuggestions.first(where: { $0.id == id }) else { return }
        toggleMention(repo)
    }

    /// Esc / 点空白关闭：清掉未完成的 `@token`，已勾选的 chip 保留。
    func dismissMentionPicker() {
        if let at = draftQuestion.lastIndex(of: "@") {
            let suffix = draftQuestion[draftQuestion.index(after: at)...]
            if !suffix.contains(where: \.isWhitespace) {
                draftQuestion.removeSubrange(at..<draftQuestion.endIndex)
            }
        }
        isMentionPickerDismissed = true
        highlightedMentionRepoID = nil
    }

    func handleDraftQuestionChanged() {
        // Esc 只关闭当前这次候选；继续编辑时重新打开，并让高亮回到当前候选集合的首项。
        isMentionPickerDismissed = false
        highlightedMentionRepoID = nil
        scheduleGitHubLinkDetection()
    }

    func removeMention(repoID: Int64) {
        selectedRepoContexts.removeAll { $0.id == repoID }
    }

    /// 清空输入框上方全部上下文 chip：已选仓库、附件、GitHub 链接。
    func clearComposerContext() {
        selectedRepoContexts = []
        attachments = []
        githubLinkContexts = []
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = String.l10n("rag.workspace.composer.attach")
        // 在选文件面板层过滤：不支持的类型直接置灰不可选，而不是选完再报错。
        panel.allowedContentTypes = Self.composerAttachmentContentTypes
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachments.contains(where: { $0.localURL == url }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            // 面板已过滤；仍用 conforms 兜底，避免扩展名欺骗。
            let handling: RAGAttachmentHandling =
                Self.isAllowedComposerAttachment(type) ? .textContext : .unsupported
            attachments.append(RAGComposerAttachment(
                id: UUID(),
                filename: url.lastPathComponent,
                contentType: type?.preferredMIMEType ?? "application/octet-stream",
                sizeInBytes: Int64(values?.fileSize ?? 0),
                localURL: url,
                handling: handling
            ))
        }
    }

    /// 仅允许纯文本 / Markdown / JSON / 源码；图片、PDF、二进制等不可选。
    private static let composerAttachmentContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .json, .sourceCode]
        if let markdown = UTType("net.daringfireball.markdown") {
            types.append(markdown)
        }
        if let md = UTType(filenameExtension: "md") {
            types.append(md)
        }
        if let markdown = UTType(filenameExtension: "markdown") {
            types.append(markdown)
        }
        return types
    }()

    private static func isAllowedComposerAttachment(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return composerAttachmentContentTypes.contains { type.conforms(to: $0) }
            || type.conforms(to: .text)
            || type.conforms(to: .json)
            || type.conforms(to: .sourceCode)
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func scheduleGitHubLinkDetection() {
        linkDetectionTask?.cancel()
        linkDetectionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                await self?.detectGitHubLink()
            } catch {
                // 新输入取消旧检测，不需要展示错误。
            }
        }
    }

    func removeGitHubLink(_ url: URL) {
        githubLinkContexts.removeAll { $0.url == url }
    }

    func openGitHubLink(_ reference: RAGGitHubLinkReference) {
        guard reference.relation == .knownButNotInKnowledge,
              let repoID = reference.matchedRepoID else {
            NSWorkspace.shared.open(reference.url)
            return
        }
        Task {
            if let repo = try? await dependencies.repoRepository.findById(repoID) {
                openLocalRepoDetail(repo)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        }
    }

    /// 当前会话全文（用户 / Starcat 分段），供顶部「复制全部 / 导出全部」使用。
    var conversationTranscriptMarkdown: String {
        messages.map { message in
            let roleLabel = message.role == .user
                ? String.l10n("rag.workspace.message.user")
                : String.l10n("rag.workspace.message.assistant")
            return "## \(roleLabel)\n\n\(message.content)"
        }.joined(separator: "\n\n")
    }

    func clearDebugTraces() {
        debugTraces = []
        guard let conversationID = selectedConversationID else { return }
        Task {
            // 清空只作用于当前会话目录，不能因 Debug 面板操作误删其它会话的可回溯记录。
            // Debug 文件不存在或写保护都不应影响工作台的正常问答。
            try? await debugFileStore.delete(conversationID: conversationID)
        }
    }

    /// 左侧标题与索引摘要都指向同一真实数据浏览器，避免用户误以为“知识库”只是装饰标签。
    func showKnowledgeBrowser(presentingWindow: NSWindow?) {
        KnowledgeRAGBrowserWindowController.show(
            dependencies: dependencies,
            homeViewModel: homeViewModel,
            centeredOver: presentingWindow
        )
    }

    /// 空库时打开批量入库 Sheet；入库后 IndexBuilder 会自动补 README 并建索引。
    func presentAddToLibrary() {
        isAddToLibraryPresented = true
    }

    /// 左栏知识库入口：空库走入库 Sheet，有仓库才打开只读浏览器。
    func openKnowledgeBaseEntry(presentingWindow: NSWindow?) {
        if isKnowledgeBaseEmpty {
            presentAddToLibrary()
        } else {
            showKnowledgeBrowser(presentingWindow: presentingWindow)
        }
    }

    var debugTraceText: String {
        debugTraces.sorted { $0.startedAt > $1.startedAt }.map { trace in
            let stepDurations = Self.debugEventStepDurations(for: trace.events)
            let events = trace.events.map { event in
                let step = stepDurations[event.id] ?? event.elapsedSeconds
                return """
                [\(event.stage.rawValue)] \(String(format: "%.3f", step))s (elapsed +\(String(format: "%.3f", event.elapsedSeconds))s)
                \(event.renderedPayload())
                """
            }.joined(separator: "\n\n")
            return """
            [\(trace.category.rawValue)] \(trace.startedAt.ISO8601Format())
            \(events)
            """
        }.joined(separator: "\n\n==========\n\n")
    }

    /// 导出单条调试 trace 为 Markdown，便于贴 issue / 对照 Prompt。
    func exportDebugTrace(_ trace: RAGDebugTrace) {
        let stamp = Self.debugExportFilenameFormatter.string(from: trace.startedAt)
        exportMarkdown(
            Self.debugTraceMarkdown(trace),
            suggestedName: "Starcat-RAG-Debug-\(trace.category.rawValue)-\(stamp).md"
        )
    }

    func exportAnswer(_ content: String) {
        exportMarkdown(content, suggestedName: "Starcat-RAG.md")
    }

    /// 导出当前会话全部对话。
    func exportConversation() {
        exportMarkdown(conversationTranscriptMarkdown, suggestedName: "Starcat-RAG-Conversation.md")
    }

    private func exportMarkdown(_ content: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 单条 trace → Markdown；stage payload 一律进自适应围栏，避免 Prompt 内 `#` / ``` 破坏大纲。
    private static func debugTraceMarkdown(_ trace: RAGDebugTrace) -> String {
        let stepDurations = debugEventStepDurations(for: trace.events)
        let header = """
        # \(debugTraceCategoryTitle(trace.category))

        - started_at: `\(debugExportTimestampFormatter.string(from: trace.startedAt))`
        - state: `\(debugTraceStateRaw(trace.state))`
        - category: `\(trace.category.rawValue)`
        - events: \(trace.events.count)

        """
        let body = trace.events.map { event in
            let step = stepDurations[event.id] ?? event.elapsedSeconds
            let title = "## \(event.stage.rawValue) (\(String(format: "%.3f", step))s, elapsed +\(String(format: "%.3f", event.elapsedSeconds))s)"
            return title + "\n\n" + fencedDebugPayload(event.renderedPayload())
        }.joined(separator: "\n\n")
        return header + "\n" + body + "\n"
    }

    /// 按内容里已有的最长 `` ` `` 串加长围栏，防止 Prompt / 返回正文提前闭合代码块后污染文档结构。
    private static func fencedDebugPayload(_ payload: String, language: String = "text") -> String {
        var tickCount = 3
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            var count = 0
            for character in line {
                if character == "`" {
                    count += 1
                    tickCount = max(tickCount, count + 1)
                } else {
                    count = 0
                }
            }
        }
        let fence = String(repeating: "`", count: tickCount)
        // 正文前后各留空行，部分渲染器对「围栏贴内容」更稳。
        return "\(fence)\(language)\n\(payload)\n\(fence)"
    }

    /// 由累计 elapsed 差分得到本步耗时；与 Inspector 展示口径一致。
    private static func debugEventStepDurations(for events: [RAGDebugEvent]) -> [UUID: TimeInterval] {
        var durations: [UUID: TimeInterval] = [:]
        var previousElapsed: TimeInterval = 0
        for event in events {
            durations[event.id] = max(0, event.elapsedSeconds - previousElapsed)
            previousElapsed = event.elapsedSeconds
        }
        return durations
    }

    private static func debugTraceCategoryTitle(_ category: RAGDebugTraceCategory) -> String {
        switch category {
        case .questionAnswer:
            return String.l10n("rag.workspace.debug.category.questionAnswer")
        case .conversationTitle:
            return String.l10n("rag.workspace.debug.category.conversationTitle")
        }
    }

    private static func debugTraceStateRaw(_ state: RAGDebugTrace.State) -> String {
        switch state {
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private static let debugExportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let debugExportFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func rebuildIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                try await dependencies.knowledgeRAGIndexBuilder.rebuildKnowledgeBase()
                try await refreshIndexCoverage()
            } catch {
                errorMessage = error.localizedDescription
            }
            await KnowledgeRAGIndexRefreshPresentation.waitForMinimumDuration(startedAt: startedAt, clock: clock)
            isIndexing = false
        }
    }

    func loadIndexIssueChunks(_ kind: RAGIndexIssueKind, append: Bool = false) async {
        guard !loadingIndexIssueKinds.contains(kind) else { return }
        loadingIndexIssueKinds.insert(kind)
        defer { loadingIndexIssueKinds.remove(kind) }
        do {
            let existing = indexIssueChunks[kind, default: []]
            let page = try await dependencies.ragChunkRepository.fetchIndexIssueChunks(
                kind: kind,
                model: dependencies.settings.aiEmbeddingTask.resolvedModelName,
                limit: append ? 10 : 5,
                offset: append ? existing.count : 0
            )
            indexIssueChunks[kind] = append ? existing + page.chunks : page.chunks
            if page.hasMore {
                indexIssueHasMore.insert(kind)
            } else {
                indexIssueHasMore.remove(kind)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func indexIssueChunks(for kind: RAGIndexIssueKind) -> [RAGChunk] {
        indexIssueChunks[kind, default: []]
    }

    func isLoadingIndexIssue(_ kind: RAGIndexIssueKind) -> Bool {
        loadingIndexIssueKinds.contains(kind)
    }

    func hasMoreIndexIssueChunks(_ kind: RAGIndexIssueKind) -> Bool {
        indexIssueHasMore.contains(kind)
    }

    func knowledgeRepositoryName(for id: Int64) -> String {
        knowledgeRepos.first(where: { $0.id == id })?.fullName ?? "#\(id)"
    }

    func selectCitation(_ citation: RAGCitation) {
        // 右侧证据换到另一条时，关掉正文 S1 的分片弹层。
        if let openID = citationChunkPopoverCitationID, openID != citation.id {
            citationChunkPopoverCitationID = nil
            RAGCitationChunkNSPopoverPresenter.shared.dismiss()
        }
        selectedCitation = citation
        selectedCitationChunk = nil
        // 即使还是同一条引用，也要通知 Inspector：用户可能正停在「调试/计划/索引」。
        citationFocusSequence &+= 1
        guard let chunkID = citation.chunkID else { return }
        Task { [weak self] in
            guard let self else { return }
            let chunk = try? await dependencies.ragChunkRepository.fetchChunks(ids: [chunkID]).first
            guard selectedCitation?.id == citation.id else { return }
            selectedCitationChunk = chunk
            // 正文 S1 弹层若仍指向本条，用全文替换 loading。
            if citationChunkPopoverCitationID == citation.id {
                RAGCitationChunkNSPopoverPresenter.shared.update(
                    citation: citation,
                    chunk: chunk,
                    isMissing: chunk == nil,
                    interfaceScale: dependencies.settings.interfaceScale
                )
            }
        }
    }

    /// 回答正文蓝色 `[S1]`：在点击位置弹出与 Inspector 同尺寸的命中分片，并同步右侧证据。
    /// 底部芯片不走这里。
    func presentCitationChunk(_ citation: RAGCitation) {
        let clickPoint = NSEvent.mouseLocation
        citationChunkPopoverCitationID = citation.id
        selectCitation(citation)
        let scale = dependencies.settings.interfaceScale
        let isMissing = citation.chunkID == nil
        RAGCitationChunkNSPopoverPresenter.shared.present(
            citation: citation,
            chunk: nil,
            isMissing: isMissing,
            screenPoint: clickPoint,
            interfaceScale: scale,
            onDismiss: { [weak self] in
                self?.citationChunkPopoverCitationID = nil
            }
        )
    }

    func dismissCitationChunkPopover() {
        guard citationChunkPopoverCitationID != nil else { return }
        citationChunkPopoverCitationID = nil
        RAGCitationChunkNSPopoverPresenter.shared.dismiss()
    }

    /// 证据列表手风琴：再点同一条则收起。
    func toggleCitation(_ citation: RAGCitation) {
        if selectedCitation?.id == citation.id {
            selectedCitation = nil
            selectedCitationChunk = nil
            citationChunkPopoverCitationID = nil
            RAGCitationChunkNSPopoverPresenter.shared.dismiss()
            return
        }
        selectCitation(citation)
    }

    /// 证据卡「Starcat 详情」：只开独立详情窗。
    /// 不调 `selectCitation`——该按钮只在已展开行出现；再选一次会清掉 `selectedCitationChunk` 并异步重拉，证据区会闪一次。
    func openCitation(_ citation: RAGCitation) {
        Task {
            await openLocalRepoDetail(for: citation)
        }
    }

    /// 回答正文里的 `starcat-rag://citation/<uuid>`：弹出命中分片，并同步右侧证据选中。
    /// 底部引用芯片不走此路径（芯片只 `selectCitation`）。
    /// - Returns: 是否已处理（调用方不应再走通用 `handleLink`）。
    @discardableResult
    func openCitationLink(_ url: URL) -> Bool {
        guard url.scheme == "starcat-rag", url.host == "citation" else { return false }
        let idString = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: idString),
              let citation = messages.flatMap(\.citations).first(where: { $0.id == id }) else {
            return false
        }
        presentCitationChunk(citation)
        return true
    }

    func openGitHub(_ citation: RAGCitation) {
        if let url = citation.sourceURL { NSWorkspace.shared.open(url) }
    }

    /// 回答 / 中间结果里的外链分流。
    ///
    /// 设计约定（§11.7.5）：只有「GitHub **repo** 链接」才尝试开本地详情。
    /// 因此仅当路径恰好是 `owner/repo`（无 `/issues`、`/pull/`、`/blob/` 等后缀）
    /// 且本地已收录时，才开 Starcat 详情窗；issues / releases 等深层 URL 一律浏览器，
    /// 避免像 `…/BetterDisplay/issues?q=…` 这种外链被误导向详情页。
    func handleLink(_ url: URL) {
        if openCitationLink(url) { return }
        let host = url.host?.lowercased()
        guard host == "github.com" || host == "www.github.com" else {
            NSWorkspace.shared.open(url)
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        // `parts.count == 2` → 纯仓库首页；更深路径不是 repo 链接语义。
        guard parts.count == 2 else {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            if let repo = try? await dependencies.repoRepository.findByOwnerName(owner: parts[0], name: parts[1]) {
                openLocalRepoDetail(repo)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 本地已收录仓库走独立详情窗；与推荐卡片 / 主窗「新窗打开」一致，不激活主窗口 selection。
    private func openLocalRepoDetail(_ repo: Repo) {
        RepoDetailWindowController.show(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
    }

    private func openLocalRepoDetail(for citation: RAGCitation) async {
        if let repo = try? await dependencies.repoRepository.findById(citation.repoID) {
            openLocalRepoDetail(repo)
        } else if let url = citation.sourceURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// 在发起下一轮问答前增量压缩已离开 recent window 的消息。压缩失败只能降级为本地
    /// 受限摘要，不能让一项辅助优化阻断用户提问；成功结果带 coverage 落库，重开窗口后
    /// 仍可继续增量合并而非重新发送整段历史。压缩在主 `ask` 之前执行，故须将其 Debug
    /// 事件按同一 Trace 起点重定位，不能让后续步骤的耗时倒退。
    private func preparedConversationHistory(
        using service: KnowledgeRAGService,
        conversationID: UUID,
        messages: [RAGStoredMessage],
        debugTraceID: UUID?,
        debugTraceStartedAt: Date
    ) async throws -> [AIChatMessage] {
        let validSummary = conversationContextSummary.flatMap { summary in
            summary.coveredMessageCount >= 0 && summary.coveredMessageCount <= messages.count
                ? summary
                : nil
        }
        let coveredCount = RAGConversationHistoryBuilder.compressionCoverageTarget(
            messages: messages,
            existingSummary: validSummary,
            contextWindowTokens: selectedModelParameters.resolvedContextWindowTokens,
            maximumOutputTokens: selectedModelParameters.maxCompletionTokens
        )
        if validSummary?.coveredMessageCount == coveredCount {
            return RAGConversationHistoryBuilder.build(from: messages, contextSummary: validSummary)
        }

        let alreadyCovered = validSummary?.coveredMessageCount ?? 0
        let newlyCovered = Array(messages.dropFirst(alreadyCovered).prefix(coveredCount - alreadyCovered))
        guard !newlyCovered.isEmpty else {
            return RAGConversationHistoryBuilder.build(from: messages, contextSummary: validSummary)
        }

        let compressionStartedAt = Date()
        let compression = try await service.compressConversationHistory(
            existingSummary: validSummary?.content,
            messages: newlyCovered,
            isDebugEnabled: isDebugModeEnabled,
            debugEndpoint: selectedModelEndpoint
        )
        let compressed: String
        switch compression {
        case .completed(let summary, let debugEvents):
            appendDebugEvents(
                debugEvents,
                rebasingFrom: compressionStartedAt,
                traceStartedAt: debugTraceStartedAt,
                to: debugTraceID
            )
            compressed = summary
        case .failed(let debugEvents):
            appendDebugEvents(
                debugEvents,
                rebasingFrom: compressionStartedAt,
                traceStartedAt: debugTraceStartedAt,
                to: debugTraceID
            )
            // Provider 不可用时仍走相同的 coverage，避免下一轮又把旧原文无限带回请求。
            compressed = RAGConversationContextCompressor.fallback(
                existingSummary: validSummary?.content,
                messages: newlyCovered,
                tokenBudget: RAGConversationHistoryBuilder.summaryTokenLimit(
                    contextWindowTokens: selectedModelParameters.resolvedContextWindowTokens,
                    maximumOutputTokens: selectedModelParameters.maxCompletionTokens
                )
            )
        }
        let summary = RAGConversationContextSummary(
            content: compressed,
            coveredMessageCount: coveredCount
        )
        do {
            try await conversationStore.saveContextSummary(
                conversationID: conversationID,
                content: summary.content,
                coveredMessageCount: summary.coveredMessageCount
            )
            conversationContextSummary = summary
        } catch {
            // 写盘失败时继续使用内存摘要完成本轮，避免存储短暂错误中断聊天；下一次加载
            // 会自然回退并再次尝试压缩。
            conversationContextSummary = summary
        }
        return RAGConversationHistoryBuilder.build(from: messages, contextSummary: summary)
    }

    private func runQuestion(_ question: String) async {
        guard let conversationID = selectedConversationID else {
            _ = finishAnswerTiming()
            return
        }
        let debugTraceStartedAt = Date()
        let debugTraceID = isDebugModeEnabled
            ? beginDebugTrace(category: .questionAnswer, startedAt: debugTraceStartedAt)
            : nil
        let isFirstTurn = messages.isEmpty
        let priorMessages = messages
        let previousUserQuestion = priorMessages.last(where: { $0.role == .user })?.content
        let previousReferencedRepos: [RAGPlannerRepoReference] = {
            guard let previousAssistant = priorMessages.last(where: { $0.role == .assistant }) else { return [] }
            var seen = Set<Int64>()
            return previousAssistant.citations.compactMap { citation in
                guard seen.insert(citation.repoID).inserted else { return nil }
                return RAGPlannerRepoReference(id: citation.repoID, fullName: citation.repoFullName)
            }
        }()
        let userMessage = RAGStoredMessage(
            id: UUID(),
            conversationID: conversationID,
            role: .user,
            content: question,
            model: nil,
            citations: [],
            remoteContextAudits: [],
            createdAt: ISO8601DateFormatter.shared.string(from: Date())
        )
        messages.append(userMessage)
        draftQuestion = ""
        streamingAnswer = ""
        streamingPresentation = nil
        queryPlan = nil
        retrieval = nil
        executionSteps = []
        remoteBlocks = []
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        selectedCitation = nil
        selectedCitationChunk = nil
        citationChunkPopoverCitationID = nil
        errorMessage = nil
        var completedPayload: (String, String, [RAGCitation])?
        var terminalReply: String?
        var suggestedActions: [RAGSuggestedQuestionAction] = []
        var didStartTitleGeneration = false
        let streamingMessageID = UUID()
        let streamingTimestamp = Date()
        var accumulatedAnswer = ""
        var pendingCharacterCount = 0
        var lastPresentationCommitAt: TimeInterval = 0
        var presentationRevision = 0
        var markdownAssembler = StreamingMarkdownAssembler()
        // Think 可能按 token 回调。完整文本留在 buffer，只有节流后的快照进入
        // `executionSteps`，避免每个 token 都让 @MainActor 重建整条时间线。
        var planningReasoningBuffer = StreamingTextPresentationBuffer()
        var answerReasoningBuffer = StreamingTextPresentationBuffer()
        let presentationThrottleInterval: TimeInterval = 0.10
        let immediatePresentationCharacterCount = 96
        streamingPresentation = StreamingMarkdownSnapshot(
            messageID: streamingMessageID,
            timestamp: streamingTimestamp,
            stableMarkdownChunks: [],
            liveTail: "",
            revision: 0
        )

        do {
            let service = try dependencies.makeKnowledgeRAGService(selectedModelID: selectedModelID)
            let history = try await preparedConversationHistory(
                using: service,
                conversationID: conversationID,
                messages: priorMessages,
                debugTraceID: debugTraceID,
                debugTraceStartedAt: debugTraceStartedAt
            )
            let consent = RAGRemoteContextConsent()
            remoteContextConsent = consent
            let request = RAGServiceRequest(
                rawQuestion: question,
                composerContext: RAGComposerContext(
                    explicitRepoIDs: selectedRepoContexts.map(\.id),
                    explicitRepoReferences: selectedRepoContexts.map {
                        RAGPlannerRepoReference(id: $0.id, fullName: $0.fullName)
                    },
                    webSearchRepoReferences: selectedRepoContexts.compactMap { repo in
                        guard !repo.isPrivate || dependencies.settings.externalSearchAllowPrivateRepos else {
                            return nil
                        }
                        return RAGPlannerRepoReference(id: repo.id, fullName: repo.fullName)
                    },
                    explicitRepoMode: explicitRepoMode,
                    selectedModelID: selectedModelID,
                    attachments: attachments,
                    pastedGitHubLinks: githubLinkContexts,
                    previousUserQuestion: previousUserQuestion,
                    previousReferencedRepos: previousReferencedRepos,
                    webSearchEnabled: webSearchEnabled,
                    disabledRemoteResources: []
                ),
                conversationID: conversationID,
                isDebugEnabled: isDebugModeEnabled,
                debugEndpoint: selectedModelEndpoint,
                debugTraceStartedAt: isDebugModeEnabled ? debugTraceStartedAt : nil
            )
            for try await event in service.ask(request: request, history: history, remoteContextConsent: consent) {
                switch event {
                case .state(let state):
                    answerState = state
                    terminalReply = terminalReply ?? reply(for: state)
                    finishRunningExecutionIfNeeded(for: state)
                case .execution(let event):
                    switch event {
                    case .reasoningDelta(let kind, let text):
                        let now = Date.timeIntervalSinceReferenceDate
                        let presentation: String?
                        switch kind {
                        case .planningReasoning:
                            presentation = planningReasoningBuffer.append(text, now: now)
                        case .answerReasoning:
                            presentation = answerReasoningBuffer.append(text, now: now)
                        default:
                            presentation = nil
                        }
                        if let presentation {
                            applyReasoningPresentation(kind: kind, text: presentation)
                        }
                    case .reasoningCompleted(let kind):
                        let now = Date.timeIntervalSinceReferenceDate
                        let finalPresentation: String?
                        switch kind {
                        case .planningReasoning:
                            finalPresentation = planningReasoningBuffer.flush(now: now)
                        case .answerReasoning:
                            finalPresentation = answerReasoningBuffer.flush(now: now)
                        default:
                            finalPresentation = nil
                        }
                        if let finalPresentation {
                            applyReasoningPresentation(kind: kind, text: finalPresentation)
                        }
                        applyExecution(event)
                    default:
                        applyExecution(event)
                    }
                case .plan(let plan):
                    queryPlan = plan
                    // 纯闲聊已由本地引导响应处理，不值得再调用一次标题 LLM。其它首轮在
                    // Planner 完成后并行生成标题，不阻塞检索和回答。
                    if isFirstTurn, !didStartTitleGeneration, plan.mode != .guidedDiscovery {
                        didStartTitleGeneration = true
                        generateConversationTitle(
                            using: service,
                            conversationID: conversationID,
                            firstQuestion: question
                        )
                    }
                case .retrieval(let result): retrieval = result
                case .remoteContextConfirmation(let workItems):
                    pendingRemoteWorkItems = workItems
                    approvedRemoteWorkItemIDs = Set(workItems.map(\.id))
                case .remoteContext(let blocks): remoteBlocks = blocks
                case .terminal(let response):
                    terminalReply = response.answer
                    suggestedActions = response.suggestedActions
                case .metadataSnapshot(let snapshot): knowledgeBaseMetadataSnapshot = snapshot
                case .contextUsage(let usage): lastContextUsage = usage
                case .debug(let event):
                    appendDebugEvent(event, to: debugTraceID)
                case .delta(let text):
                    accumulatedAnswer += text
                    markdownAssembler.append(text)
                    pendingCharacterCount += text.count
                    let now = Date.timeIntervalSinceReferenceDate
                    // Provider 可能逐 token 回调；最多约 10Hz 触发 SwiftUI 更新，较大网络批次
                    // 则立即可见。冻结前缀不会在后续 token 到达时重复进入 MarkdownUI。
                    guard now - lastPresentationCommitAt >= presentationThrottleInterval
                            || pendingCharacterCount >= immediatePresentationCharacterCount else { continue }
                    lastPresentationCommitAt = now
                    pendingCharacterCount = 0
                    presentationRevision &+= 1
                    streamingAnswer = accumulatedAnswer
                    streamingPresentation = StreamingMarkdownSnapshot(
                        messageID: streamingMessageID,
                        timestamp: streamingTimestamp,
                        stableMarkdownChunks: markdownAssembler.stableMarkdownChunks,
                        liveTail: markdownAssembler.liveTail,
                        revision: presentationRevision
                    )
                case .completed(let answer, let model, let citations, _):
                    completedPayload = (answer, model, citations)
                }
            }
            // Provider 失败或提前结束时未必发送 reasoningCompleted；落库前仍要补齐最后
            // 一批 Think，避免性能节流变成数据丢失。
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer
            )
            let processingDuration = finishAnswerTiming()
            if let completedPayload {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: completedPayload.0,
                    model: completedPayload.1,
                    citations: completedPayload.2,
                    remoteContexts: remoteBlocks,
                    executionTrace: executionSteps,
                    suggestedActions: [],
                    processingDuration: processingDuration
                )
            } else if let terminalReply, answerState != .cancelled {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: terminalReply,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContexts: remoteBlocks,
                    executionTrace: executionSteps,
                    suggestedActions: suggestedActions,
                    processingDuration: processingDuration
                )
            } else if answerState == .cancelled {
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    processingDuration: processingDuration
                )
            }
        } catch is CancellationError {
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer
            )
            streamingAnswer = accumulatedAnswer
            answerState = .cancelled
            let processingDuration = finishAnswerTiming()
            scheduleFinalizeCancelledTurn(
                conversationID: conversationID,
                userMessage: userMessage,
                question: question,
                processingDuration: processingDuration
            )
        } catch {
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer
            )
            // 停止按钮会 cancel Task；部分底层 API 不抛 CancellationError 而是带上
            // Task.isCancelled，不能当成「RAG 请求失败」弹窗。
            if Task.isCancelled {
                streamingAnswer = accumulatedAnswer
                answerState = .cancelled
                let processingDuration = finishAnswerTiming()
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    processingDuration: processingDuration
                )
            } else {
                answerState = .failed(error.localizedDescription)
                _ = finishAnswerTiming()
                retryQuestion = question
                presentWorkspaceError(error)
                // 正常失败也必须与取消路径同样保留问题：用户能直接复制或编辑后重试，
                // 不能因 Provider / 附件临时故障被迫重新输入。
                scheduleFinalizeFailedTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question
                )
            }
        }
        let finishedDebugTrace = finishDebugTrace(debugTraceID, state: debugTraceState(for: answerState))
        await persistDebugTrace(
            finishedDebugTrace,
            conversationID: conversationID,
            userMessageID: userMessage.id
        )
        remoteContextConsent = nil
        if answerState != .generating { streamingPresentation = nil }
        answerTask = nil
    }

    private func presentWorkspaceError(_ error: Error) {
        errorMessage = error.localizedDescription
        workspaceError = RAGWorkspaceError(error: error)
    }

    /// 非取消错误的恢复路径。先尽力把用户问题落库，落库失败时仍保留已显示的气泡；
    /// 后续由 error sheet 提示错误，用户可使用气泡上的复制/编辑动作恢复。
    private func scheduleFinalizeFailedTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await conversationStore.appendUserMessage(
                    conversationID: conversationID,
                    messageID: userMessage.id,
                    question: question,
                    createdAt: userMessage.createdAt
                )
                guard selectedConversationID == conversationID else { return }
                if let detail = try await conversationStore.loadConversation(id: conversationID) {
                    messages = detail.messages
                    conversationContextSummary = detail.contextSummary
                    loadedMessageSequence &+= 1
                }
                conversations = try await conversationStore.listConversations()
            } catch {
                // 不覆盖原始 Provider 错误；内存气泡仍可让用户复制或编辑问题。
            }
        }
    }

    /// 在已取消的回答 Task 之外落库：否则 `appendUserMessage` 等 await 会再抛
    /// `CancellationError`，被误写成 errorMessage 弹出「RAG 请求失败」。
    private func scheduleFinalizeCancelledTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String,
        processingDuration: TimeInterval
    ) {
        let partial = streamingAnswer
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 若调度时流式文本已被清空，用快照补回，避免竞态丢半截回答。
            if streamingAnswer.isEmpty, !partial.isEmpty {
                streamingAnswer = partial
            }
            await finalizeCancelledTurn(
                conversationID: conversationID,
                userMessage: userMessage,
                question: question,
                processingDuration: processingDuration
            )
        }
    }

    /// 停止生成：保留用户问题；已有流式文本则落库半截回答，否则只落库用户消息。
    private func finalizeCancelledTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String,
        processingDuration: TimeInterval
    ) async {
        let partial = streamingAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial.isEmpty {
            // 尚无 AI 输出：保留气泡，落库用户消息，供复制 / 编辑。
            do {
                try await conversationStore.appendUserMessage(
                    conversationID: conversationID,
                    messageID: userMessage.id,
                    question: question,
                    createdAt: userMessage.createdAt
                )
                if let detail = try await conversationStore.loadConversation(id: conversationID) {
                    messages = detail.messages
                    conversationContextSummary = detail.contextSummary
                    loadedMessageSequence &+= 1
                }
                conversations = try await conversationStore.listConversations()
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗。
            } catch {
                // 落库失败仍保留内存中的用户气泡，避免「停止后问题消失」。
                errorMessage = error.localizedDescription
            }
            streamingAnswer = ""
        } else {
            do {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContexts: remoteBlocks,
                    executionTrace: executionSteps,
                    processingDuration: processingDuration
                )
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗；半截文本仍挂到时间线。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContextAudits: [],
                    processingDuration: processingDuration,
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if !messages.contains(where: { $0.id == userMessage.id }) {
                    messages.append(userMessage)
                }
                if !messages.contains(where: { $0.role == .assistant && $0.content == partial }) {
                    messages.append(assistant)
                }
                streamingAnswer = ""
            } catch {
                // 落库失败时至少把半截流式文本挂成助手气泡，避免只剩用户问题。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: selectedModelDisplayName,
                    citations: [],
                    remoteContextAudits: [],
                    processingDuration: processingDuration,
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if !messages.contains(where: { $0.id == userMessage.id }) {
                    messages.append(userMessage)
                }
                messages.append(assistant)
                streamingAnswer = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 标题请求从回答任务中拆开：仅使用首个问题，和检索/流式回答并行进行。
    /// 同一会话最多保留一个任务；切换会话不取消它，只有删除或人工重命名才明确作废。
    private func generateConversationTitle(
        using service: KnowledgeRAGService,
        conversationID: UUID,
        firstQuestion: String
    ) {
        cancelConversationTitleGeneration(for: conversationID)
        let generationID = UUID()
        let debugEnabled = isDebugModeEnabled
        let debugEndpoint = selectedModelEndpoint
        let debugTraceID = debugEnabled ? beginDebugTrace(category: .conversationTitle) : nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await service.generateConversationTitle(
                firstQuestion: firstQuestion,
                isDebugEnabled: debugEnabled,
                debugEndpoint: debugEndpoint
            )
            guard !Task.isCancelled,
                  isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }

            switch result {
            case .completed(let title, let debugEvents):
                appendDebugEvents(debugEvents, to: debugTraceID)
                await applyGeneratedConversationTitle(
                    title,
                    for: conversationID,
                    generationID: generationID
                )
                finishConversationTitleGeneration(
                    generationID,
                    for: conversationID,
                    debugState: .completed
                )
            case .failed(let debugEvents):
                appendDebugEvents(debugEvents, to: debugTraceID)
                finishConversationTitleGeneration(
                    generationID,
                    for: conversationID,
                    debugState: .failed
                )
            case .cancelled:
                finishConversationTitleGeneration(
                    generationID,
                    for: conversationID,
                    debugState: .cancelled
                )
            }
        }
        // 当前方法位于 MainActor；Task 会在本次同步状态更新完成后才取得执行机会，
        // 因而结果回调开始前 generation 已登记，可用其拦截延迟返回的已取消请求。
        conversationTitleGenerations[conversationID] = ConversationTitleGeneration(
            id: generationID,
            debugTraceID: debugTraceID,
            task: task
        )
    }

    private func cancelConversationTitleGeneration(for conversationID: UUID) {
        guard let generation = conversationTitleGenerations.removeValue(forKey: conversationID) else { return }
        generation.task.cancel()
        finishDebugTrace(generation.debugTraceID, state: .cancelled)
    }

    private func isConversationTitleGenerationCurrent(
        _ generationID: UUID,
        for conversationID: UUID
    ) -> Bool {
        conversationTitleGenerations[conversationID]?.id == generationID
    }

    private func finishConversationTitleGeneration(
        _ generationID: UUID,
        for conversationID: UUID,
        debugState: RAGDebugTrace.State
    ) {
        guard let generation = conversationTitleGenerations[conversationID],
              generation.id == generationID else { return }
        finishDebugTrace(generation.debugTraceID, state: debugState)
        conversationTitleGenerations.removeValue(forKey: conversationID)
    }

    private func beginDebugTrace(
        category: RAGDebugTraceCategory,
        startedAt: Date = Date()
    ) -> UUID {
        let trace = RAGDebugTrace(
            id: UUID(),
            category: category,
            startedAt: startedAt,
            state: .running,
            events: []
        )
        debugTraces.append(trace)
        trimDebugTraceMemory()
        return trace.id
    }

    private func appendDebugEvent(_ event: RAGDebugEvent, to traceID: UUID?) {
        guard isDebugModeEnabled, let traceID,
              let index = debugTraces.firstIndex(where: { $0.id == traceID }) else { return }
        let boundedPayload = String(
            decoding: event.payload.utf8.prefix(DebugTraceLimit.maxPayloadUTF8Bytes),
            as: UTF8.self
        )
        let boundedRetrievalPayload = event.retrievalPayload.map { payload in
            RAGRetrievalDebugPayload(
                diagnostics: payload.diagnostics,
                evidenceDetails: String(
                    decoding: payload.evidenceDetails.utf8.prefix(DebugTraceLimit.maxPayloadUTF8Bytes),
                    as: UTF8.self
                )
            )
        }
        let boundedEvent = RAGDebugEvent(
            stage: event.stage,
            elapsedSeconds: event.elapsedSeconds,
            payload: boundedPayload,
            retrievalPayload: boundedRetrievalPayload
        )
        // GitHub 远程上下文会并发完成；continuation 的送达顺序不保证严格等于发生时间。
        // 按 Trace 相对时间插入，Inspector 的相邻事件耗时始终可解释，且缓存/网络混合时
        // 不会出现负耗时。
        let insertionIndex = debugTraces[index].events.firstIndex {
            $0.elapsedSeconds > boundedEvent.elapsedSeconds
        } ?? debugTraces[index].events.endIndex
        debugTraces[index].events.insert(boundedEvent, at: insertionIndex)
        if debugTraces[index].events.count > DebugTraceLimit.maxEventsPerTrace {
            debugTraces[index].events.removeFirst(
                debugTraces[index].events.count - DebugTraceLimit.maxEventsPerTrace
            )
        }
        trimDebugTraceMemory()
    }

    private func appendDebugEvents(_ events: [RAGDebugEvent], to traceID: UUID?) {
        for event in events { appendDebugEvent(event, to: traceID) }
    }

    /// 压缩调用在 `ask` 前完成，Service 返回的是以压缩起点为零的局部耗时。写入问答
    /// Trace 前须换算为全局耗时，Inspector 的相邻事件差分才能正确反映实际等待时间。
    private func appendDebugEvents(
        _ events: [RAGDebugEvent],
        rebasingFrom localStartedAt: Date,
        traceStartedAt: Date,
        to traceID: UUID?
    ) {
        let offset = max(localStartedAt.timeIntervalSince(traceStartedAt), 0)
        for event in events {
            appendDebugEvent(
                RAGDebugEvent(
                    stage: event.stage,
                    elapsedSeconds: offset + event.elapsedSeconds,
                    payload: event.payload,
                    retrievalPayload: event.retrievalPayload
                ),
                to: traceID
            )
        }
    }

    @discardableResult
    private func finishDebugTrace(_ traceID: UUID?, state: RAGDebugTrace.State) -> RAGDebugTrace? {
        guard let traceID, let index = debugTraces.firstIndex(where: { $0.id == traceID }) else { return nil }
        debugTraces[index].state = state
        return debugTraces[index]
    }

    /// 仅在本轮结束后写一次完整 JSON，避免 token 级 Debug event 产生高频磁盘 I/O。
    private func persistDebugTrace(
        _ trace: RAGDebugTrace?,
        conversationID: UUID,
        userMessageID: UUID
    ) async {
        guard let trace else { return }
        do {
            try await debugFileStore.save(
                trace: trace,
                conversationID: conversationID,
                userMessageID: userMessageID
            )
        } catch {
            // 文件 Debug 是可选辅助信息；失败时保留本轮内存展示，不能中断正常问答。
        }
    }

    /// FIFO 清理最老事件/trace；普通会话与数据库永不依赖 debug trace，因此可安全释放。
    private func trimDebugTraceMemory() {
        while debugTraces.count > DebugTraceLimit.maxTraceCount {
            debugTraces.removeFirst()
        }
        while debugPayloadByteCount > DebugTraceLimit.maxTotalPayloadUTF8Bytes {
            guard let traceIndex = debugTraces.firstIndex(where: { !$0.events.isEmpty }) else { break }
            debugTraces[traceIndex].events.removeFirst()
            if debugTraces[traceIndex].events.isEmpty, debugTraces.count > 1 {
                debugTraces.remove(at: traceIndex)
            }
        }
    }

    private var debugPayloadByteCount: Int {
        debugTraces.reduce(0) { traceTotal, trace in
            traceTotal + trace.events.reduce(0) { $0 + $1.storedPayloadUTF8ByteCount }
        }
    }

    private func debugTraceState(for answerState: RAGAnswerState) -> RAGDebugTrace.State {
        switch answerState {
        case .cancelled: return .cancelled
        case .failed: return .failed
        default: return .completed
        }
    }

    /// 当前会话保留逐字展示；若用户中途切到历史会话，则直接落库完整标题，避免后台任务
    /// 因不再可见而丢失结果。
    private func applyGeneratedConversationTitle(
        _ title: String,
        for conversationID: UUID,
        generationID: UUID
    ) async {
        guard isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
        if selectedConversationID == conversationID {
            await typewriteConversationTitle(title, for: conversationID, generationID: generationID)
        } else {
            await persistGeneratedConversationTitle(title, for: conversationID, generationID: generationID)
        }
    }

    /// 动画期间只改内存中的列表标题，完成后才写数据库，避免历史记录被半截文本污染。
    private func typewriteConversationTitle(
        _ title: String,
        for conversationID: UUID,
        generationID: UUID
    ) async {
        guard isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
        updateConversationTitle(title: "", for: conversationID)
        var displayedTitle = ""
        for character in title {
            do {
                try await Task.sleep(for: .milliseconds(32))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
            if selectedConversationID != conversationID {
                await persistGeneratedConversationTitle(title, for: conversationID, generationID: generationID)
                return
            }
            displayedTitle.append(character)
            updateConversationTitle(title: displayedTitle, for: conversationID)
        }
        guard !Task.isCancelled,
              isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
        await persistGeneratedConversationTitle(title, for: conversationID, generationID: generationID)
    }

    /// 后台会话不播放标题动画。先更新内存，再写 SQLite 并刷新排序；任何人工重命名都会
    /// 先使 generationID 失效，因此延迟返回的自动标题不能覆盖用户输入。
    private func persistGeneratedConversationTitle(
        _ title: String,
        for conversationID: UUID,
        generationID: UUID
    ) async {
        guard isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
        updateConversationTitle(title: title, for: conversationID)
        do {
            try await conversationStore.renameConversation(id: conversationID, title: title)
            guard isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
            conversations = try await conversationStore.listConversations()
        } catch {
            // 标题失败不应影响已完成的问答；内存标题仍保留，下一次加载会使用数据库旧标题。
        }
    }

    private func updateConversationTitle(title: String, for conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].title = title
    }

    /// 将 Service 的结构化事件投影为普通用户可读的步骤。
    ///
    /// 这里刻意不消费 Debug trace：后者带完整 prompt / 历史，只适合开发排障。默认轨迹
    /// 只展示已经发生的操作、查询规划、provider 公开的推理文本和可核验的数量结果。
    private func applyExecution(_ event: RAGExecutionEvent) {
        switch event {
        case .started(let kind):
            let transitionTime = Date()
            for index in executionSteps.indices where executionSteps[index].state == .running {
                executionSteps[index].state = .completed
                if executionSteps[index].completedAt == nil {
                    executionSteps[index].completedAt = transitionTime
                }
            }
            executionSteps.append(RAGExecutionStep(kind: kind))

        case .planningCompleted(let plan):
            let fallback = String(
                format: String.l10n("rag.workspace.execution.planning.fallbackFormat"),
                plan.userVisiblePlan.scope,
                plan.userVisiblePlan.semantic
            )
            updateExecutionStep(kind: .planning) { step in
                step.details = plan.userVisiblePlan.planningNotes.isEmpty
                    ? [fallback]
                    : plan.userVisiblePlan.planningNotes
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.planning.summaryFormat"),
                    plan.userVisiblePlan.semantic
                )
                completeExecutionStep(&step)
            }

        case .reasoningDelta(let kind, let text):
            updateExecutionStep(kind: kind) { step in
                if step.details.isEmpty {
                    step.details = [text]
                } else {
                    step.details[step.details.count - 1] += text
                }
            }

        case .reasoningCompleted(let kind):
            updateExecutionStep(kind: kind) { step in
                // 推理流结束后取消 running 状态，时间线即自动折叠，为正式回答让出阅读空间。
                completeExecutionStep(&step)
            }

        case .retrieval(let progress):
            updateExecutionStep(kind: .retrieval) { step in
                switch progress {
                case .candidateSelectionCompleted(let count):
                    step.details.append(String(
                        format: String.l10n("rag.workspace.execution.retrieval.candidatesFormat"), count
                    ))
                case .keywordSearchStarted:
                    step.details.append(String.l10n("rag.workspace.execution.retrieval.keywordStarted"))
                case .keywordSearchCompleted(let count):
                    step.details.append(String(
                        format: String.l10n("rag.workspace.execution.retrieval.keywordCompletedFormat"), count
                    ))
                case .semanticSearchStarted:
                    step.details.append(String.l10n("rag.workspace.execution.retrieval.semanticStarted"))
                case .semanticSearchCompleted(let count):
                    step.details.append(String(
                        format: String.l10n("rag.workspace.execution.retrieval.semanticCompletedFormat"), count
                    ))
                case .evidencePacked(let hitCount, let bundleCount):
                    step.details.append(String(
                        format: String.l10n("rag.workspace.execution.retrieval.evidencePackedFormat"),
                        hitCount,
                        bundleCount
                    ))
                }
            }

        case .retrievalCompleted(let result):
            updateExecutionStep(kind: .retrieval) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.retrieval.summaryFormat"),
                    result.bundles.count,
                    result.childHits.count
                )
                completeExecutionStep(&step)
            }

        case .remoteContextPrepared(let workItems):
            updateExecutionStep(kind: .remoteContext) { step in
                let githubItems = workItems.map { workItem in
                    RAGRemoteExecutionAuditItem(
                        id: workItem.id,
                        repoFullName: workItem.candidate.repo.fullName,
                        resource: workItem.request.resource,
                        querySummary: workItem.request.query,
                        requestURL: nil,
                        status: .pending,
                        transport: nil,
                        httpStatusCode: nil,
                        resultCount: nil,
                        errorMessage: nil,
                        startedAt: nil,
                        completedAt: nil,
                        providerName: "GitHub"
                    )
                }
                let githubIDs = Set(githubItems.map(\.id))
                let existing = (step.remoteAuditItems ?? []).filter { !githubIDs.contains($0.id) }
                step.remoteAuditItems = existing + githubItems
            }

        case .webSearchPrepared(let requests):
            updateExecutionStep(kind: .remoteContext) { step in
                let webItems = requests.map { request in
                    RAGRemoteExecutionAuditItem(
                        id: request.id,
                        repoFullName: "",
                        resource: .externalWeb,
                        querySummary: request.query,
                        requestURL: nil,
                        status: .pending,
                        transport: nil,
                        httpStatusCode: nil,
                        resultCount: nil,
                        errorMessage: nil,
                        startedAt: nil,
                        completedAt: nil,
                        providerName: "External Search"
                    )
                }
                let webIDs = Set(webItems.map(\.id))
                let existing = (step.remoteAuditItems ?? []).filter { !webIDs.contains($0.id) }
                step.remoteAuditItems = existing + webItems
            }

        case .remoteContextProgress(let completed, let total):
            updateExecutionStep(kind: .remoteContext) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.remote.progressFormat"),
                    completed,
                    total
                )
            }

        case .remoteContextCompleted(let blocks):
            updateExecutionStep(kind: .remoteContext) { step in
                let blocksByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
                step.remoteAuditItems = (step.remoteAuditItems ?? []).map { item in
                    guard let block = blocksByID[item.id] else { return item }
                    var completed = item
                    completed.requestURL = block.requestURL
                    completed.status = switch block.outcome {
                    case .success: .succeeded
                    case .empty: .empty
                    case .failed: .failed
                    }
                    completed.transport = block.transport
                    completed.httpStatusCode = block.httpStatusCode
                    completed.resultCount = block.resultCount
                    completed.errorMessage = block.errorMessage
                    completed.startedAt = block.startedAt
                    completed.completedAt = block.completedAt
                    completed.providerName = block.providerName ?? completed.providerName
                    completed.querySummary = block.querySummary ?? completed.querySummary
                    completed.resultPreviews = block.resultPreviews
                    return completed
                }
                step.details = []
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.remote.summaryFormat"), blocks.count
                )
                completeExecutionStep(&step)
            }

        case .generationStarted(let evidenceCount):
            updateExecutionStep(kind: .generation) { step in
                step.details = [String(
                    format: String.l10n("rag.workspace.execution.generation.startedFormat"), evidenceCount
                )]
            }

        case .generationCompleted(let citationCount):
            updateExecutionStep(kind: .generation) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.generation.summaryFormat"), citationCount
                )
                completeExecutionStep(&step)
            }

        case .terminated(let kind, let summary):
            updateExecutionStep(kind: kind) { step in
                step.summary = summary
                completeExecutionStep(&step)
                if kind == .remoteContext {
                    step.state = .skipped
                    step.remoteAuditItems = (step.remoteAuditItems ?? []).map { item in
                        var skipped = item
                        skipped.status = .skipped
                        skipped.completedAt = .now
                        return skipped
                    }
                }
            }
        }
    }

    /// 用稳定的单条详情承载节流后的完整 Think。数组下标不变，配合时间线按 index
    /// 标识后，SwiftUI 只更新文字内容，不会把每个 token 当成一棵全新的 View 子树。
    private func applyReasoningPresentation(kind: RAGExecutionStepKind, text: String) {
        updateExecutionStep(kind: kind) { step in
            step.details = text.isEmpty ? [] : [text]
        }
    }

    /// Provider 在失败和取消路径上不保证发送 `reasoningCompleted`。所有退出路径都走
    /// 同一刷新逻辑，确保 UI 降频只减少重绘次数，不吞掉最后一批 Think。
    private func flushReasoningPresentations(
        planning: inout StreamingTextPresentationBuffer,
        answer: inout StreamingTextPresentationBuffer
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        if let finalPlanning = planning.flush(now: now) {
            applyReasoningPresentation(kind: .planningReasoning, text: finalPlanning)
        }
        if let finalAnswer = answer.flush(now: now) {
            applyReasoningPresentation(kind: .answerReasoning, text: finalAnswer)
        }
    }

    /// 所有终态共用同一时间戳，避免 UI 只能从近似事件时间倒推步骤耗时。
    private func completeExecutionStep(_ step: inout RAGExecutionStep, at time: Date = .now) {
        step.state = .completed
        if step.completedAt == nil {
            step.completedAt = time
        }
    }

    private func updateExecutionStep(
        kind: RAGExecutionStepKind,
        _ update: (inout RAGExecutionStep) -> Void
    ) {
        guard let index = executionSteps.lastIndex(where: { $0.kind == kind }) else { return }
        update(&executionSteps[index])
    }

    private func finishRunningExecutionIfNeeded(for state: RAGAnswerState) {
        let isFailure: Bool
        if case .failed = state { isFailure = true } else { isFailure = false }
        guard state == .cancelled || isFailure else { return }
        for index in executionSteps.indices where executionSteps[index].state == .running {
            completeExecutionStep(&executionSteps[index])
            executionSteps[index].summary = state == .cancelled
                ? String.l10n("rag.workspace.execution.cancelled")
                : String.l10n("rag.workspace.execution.failed")
        }
    }

    private func persistAnswer(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock],
        executionTrace: [RAGExecutionStep] = [],
        suggestedActions: [RAGSuggestedQuestionAction] = [],
        processingDuration: TimeInterval? = nil
    ) async throws {
        try await conversationStore.appendTurn(
            conversationID: conversationID,
            question: question,
            answer: answer,
            model: model,
            citations: citations,
            remoteContexts: remoteContexts,
            executionTrace: executionTrace,
            suggestedActions: suggestedActions,
            processingDuration: processingDuration
        )
        if let detail = try await conversationStore.loadConversation(id: conversationID) {
            messages = detail.messages
            conversationContextSummary = detail.contextSummary
            loadedMessageSequence &+= 1
            if let citation = citations.first { selectCitation(citation) }
        }
        conversations = try await conversationStore.listConversations()
        streamingAnswer = ""
        streamingPresentation = nil
        executionSteps = []
        remoteBlocks = []
        attachments = []
        githubLinkContexts = []
    }

    private func refreshIndexCoverage() async throws {
        indexCoverage = try await dependencies.knowledgeRAGIndexBuilder.coverage()
        indexIssueChunks = [:]
        indexIssueHasMore = []
    }

    /// 面板初次展示与知识库边界/索引变化后都从固定 SQL 重新读取。失败不能影响问答或索引刷新；
    /// 下一次成功读取会自然覆盖旧值，而真正发送给模型的一轮快照仍由 Service 事件优先覆盖。
    private func refreshKnowledgeBaseMetadataSnapshot() async {
        do {
            knowledgeBaseMetadataSnapshot = try await KnowledgeBaseMetadataSnapshotProvider(
                database: dependencies.database,
                embeddingModel: embeddingModel
            ).fetch()
        } catch {
            AppLog.ai.warning("RAG metadata panel refresh degraded: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resetTurnState() {
        answerTimingTask?.cancel()
        answerTimingTask = nil
        answerStartedAt = nil
        answerElapsedDuration = nil
        draftQuestion = ""
        streamingAnswer = ""
        streamingPresentation = nil
        answerState = .idle
        editingUserMessageID = nil
        editingUserDraft = ""
        queryPlan = nil
        retrieval = nil
        remoteBlocks = []
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        selectedRepoContexts = []
        attachments = []
        githubLinkContexts = []
        errorMessage = nil
        selectedCitation = nil
        selectedCitationChunk = nil
        citationChunkPopoverCitationID = nil
    }

    private func reply(for state: RAGAnswerState) -> String? {
        switch state {
        case .needsClarification(let question): return question
        case .noKnowledgeRepos: return String.l10n("rag.workspace.state.noKnowledgeRepos")
        case .noCandidates: return String.l10n("rag.workspace.state.noCandidates")
        case .noIndex: return String.l10n("rag.workspace.state.noIndex")
        case .noRelevantChunks: return String.l10n("rag.workspace.state.noRelevantChunks")
        default: return nil
        }
    }

    private func detectGitHubLink() async {
        let pattern = #"https?://github\.com/([^/\s]+)/([^/\s?#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: draftQuestion,
                range: NSRange(draftQuestion.startIndex..., in: draftQuestion)
              ),
              let urlRange = Range(match.range(at: 0), in: draftQuestion),
              let ownerRange = Range(match.range(at: 1), in: draftQuestion),
              let repoRange = Range(match.range(at: 2), in: draftQuestion) else { return }
        let rawURL = String(draftQuestion[urlRange])
        guard let url = URL(string: rawURL), !githubLinkContexts.contains(where: { $0.url == url }) else { return }
        let owner = String(draftQuestion[ownerRange])
        let name = String(draftQuestion[repoRange]).replacingOccurrences(of: ".git", with: "")

        if let candidate = knowledgeCandidates.first(where: {
            $0.repo.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.repo.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if !selectedRepoContexts.contains(where: { $0.id == candidate.repo.id }) {
                selectedRepoContexts.append(candidate.repo)
            }
            draftQuestion.removeSubrange(urlRange)
            draftQuestion = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        let known = try? await dependencies.repoRepository.findByOwnerName(owner: owner, name: name)
        githubLinkContexts.append(RAGGitHubLinkReference(
            url: url,
            owner: owner,
            repo: name,
            matchedRepoID: known?.id,
            relation: known == nil ? .external : .knownButNotInKnowledge
        ))
        draftQuestion.removeSubrange(urlRange)
        draftQuestion = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
