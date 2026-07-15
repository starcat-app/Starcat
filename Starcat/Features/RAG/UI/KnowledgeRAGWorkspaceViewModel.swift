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

/// 一份可直接安装到工作台中栏的持久化展示快照。
///
/// 除原始消息外同时缓存大纲和引用投影，缓存命中时不再在主线程扫描长会话。快照是
/// `Sendable` 值类型，首次构建可安全放到后台；SQLite 仍是唯一持久化真源。
struct RAGConversationPresentationSnapshot: Sendable {
    let detail: RAGConversationDetail
    let outlineTurns: [RAGConversationOutlineTurn]
    let citations: [RAGCitation]
}

/// 会话正文的窗口级 LRU 快照缓存。
///
/// 容量刻意有界，且任何持久化写入都由 ViewModel 主动失效对应项，不能把缓存变成第二套
/// 数据源。线性维护访问顺序的成本受几十项容量约束，比引入链表节点更简单可靠。
struct RAGConversationPresentationCache {
    private let capacity: Int
    private var snapshotsByID: [UUID: RAGConversationPresentationSnapshot] = [:]
    /// 最旧在前、最近使用在后。
    private var recency: [UUID] = []

    init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
    }

    var count: Int { snapshotsByID.count }

    mutating func value(for conversationID: UUID) -> RAGConversationPresentationSnapshot? {
        guard let snapshot = snapshotsByID[conversationID] else { return nil }
        touch(conversationID)
        return snapshot
    }

    mutating func insert(_ snapshot: RAGConversationPresentationSnapshot) {
        let conversationID = snapshot.detail.summary.id
        snapshotsByID[conversationID] = snapshot
        touch(conversationID)
        while recency.count > capacity {
            snapshotsByID[recency.removeFirst()] = nil
        }
    }

    mutating func remove(_ conversationID: UUID) {
        snapshotsByID[conversationID] = nil
        recency.removeAll { $0 == conversationID }
    }

    mutating func removeAll() {
        snapshotsByID.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ conversationID: UUID) {
        recency.removeAll { $0 == conversationID }
        recency.append(conversationID)
    }
}

/// 切换会话或关闭 RAG 工作台时暂存的 Composer 草稿。
///
/// 只活在 App 进程内存里：未发送的 `@repo` / 附件 / 输入文案 / 联网开关在工作台关闭重开后仍可恢复，
/// 但不能写成第二套持久化真源；App 退出或切换用户库后丢弃。
struct RAGComposerDraftSnapshot: Equatable {
    var draftQuestion: String = ""
    var selectedRepoContexts: [Repo] = []
    var attachments: [RAGComposerAttachment] = []
    var githubLinkContexts: [RAGGitHubLinkReference] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var webSearchEnabled = false
}

/// 按会话隔离 Composer 草稿的 App 级内存字典。
struct RAGComposerDraftStore {
    private var draftsByID: [UUID: RAGComposerDraftSnapshot] = [:]

    var count: Int { draftsByID.count }

    mutating func save(_ snapshot: RAGComposerDraftSnapshot, for conversationID: UUID) {
        draftsByID[conversationID] = snapshot
    }

    func draft(for conversationID: UUID) -> RAGComposerDraftSnapshot? {
        draftsByID[conversationID]
    }

    mutating func update(_ conversationID: UUID, _ mutate: (inout RAGComposerDraftSnapshot) -> Void) {
        var snapshot = draftsByID[conversationID] ?? RAGComposerDraftSnapshot()
        mutate(&snapshot)
        draftsByID[conversationID] = snapshot
    }

    mutating func remove(_ conversationID: UUID) {
        draftsByID[conversationID] = nil
    }

    mutating func removeAll() {
        draftsByID.removeAll(keepingCapacity: true)
    }

    /// 知识库边界变化后，草稿里已离开知识库的仓库不能继续作为显式上下文。
    mutating func pruneRepos(keepingIDs: Set<Int64>) {
        for conversationID in Array(draftsByID.keys) {
            draftsByID[conversationID]?.selectedRepoContexts.removeAll { !keepingIDs.contains($0.id) }
        }
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
    /// 回答属于会话而不是窗口当前选中项。generation ID 防止旧任务收尾误删同会话的新重试。
    private struct ConversationAnswerGeneration {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var answerGenerations: [UUID: ConversationAnswerGeneration] = [:]
    /// 切库或关闭窗口时明确放弃未完成回答，避免旧账户任务在新数据库上落库。
    @ObservationIgnored private var discardedAnswerConversationIDs: Set<UUID> = []
    /// 计时与回答一样属于原会话。允许 A 在后台继续时，用户在 B 发起另一轮而不覆盖 A 的耗时。
    @ObservationIgnored private var answerTimingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var answerStartedAtByConversation: [UUID: Date] = [:]
    @ObservationIgnored private var answerElapsedDurationsByConversation: [UUID: TimeInterval] = [:]
    /// 标题与首轮回答并行，但不同会话的轻量标题请求不能因用户切换历史而互相取消。
    /// generationID 是取消后的第二道保护：部分 Provider 即使收到 cancel 也可能稍后返回。
    private struct ConversationTitleGeneration {
        let id: UUID
        let debugTraceID: UUID?
        let task: Task<Void, Never>
    }
    /// 请求开始前冻结会话范围和模型配置。`preparedConversationHistory` 含 await，不能在其返回后
    /// 再读取当前 UI 的 composer，否则 A 会话可能误用用户已切到 B 后的新上下文。
    private struct QuestionRequestSnapshot {
        let composerContext: RAGComposerContext
        let modelID: String?
        let modelDisplayName: String
        let modelParameters: AIModelParameters
        let contextSummary: RAGConversationContextSummary?
        let isDebugEnabled: Bool
        let debugEndpoint: String?
    }
    @ObservationIgnored private var conversationTitleGenerations: [UUID: ConversationTitleGeneration] = [:]
    /// store 读取未必会合作响应取消；generation 是提交结果前的第二道保护。
    private let conversationSelectionGate = RAGLatestRequestGate()
    /// Debug 读取与正文选择分开；清空、关闭 Debug 或再次切换都会使迟到结果失效。
    private let debugTraceLoadGate = RAGLatestRequestGate()
    /// 最近会话的完整持久化展示快照。缓存不参与 Observation，写入后由本类显式失效。
    @ObservationIgnored private var conversationPresentationCache = RAGConversationPresentationCache()
    /// 工作台稳定后低优先级预热最近会话；关窗/切库必须取消，避免继续读取旧数据库。
    @ObservationIgnored private var conversationPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var remoteContextConsent: RAGRemoteContextConsent?
    /// 联网确认也属于原会话。任务在后台走到确认点后，用户切回该会话仍可继续批准或跳过。
    @ObservationIgnored private var remoteContextConsents: [UUID: RAGRemoteContextConsent] = [:]
    @ObservationIgnored private var pendingRemoteWorkItemsByConversation: [UUID: [RAGResolvedRemoteWorkItem]] = [:]
    @ObservationIgnored private var approvedRemoteWorkItemIDsByConversation: [UUID: Set<String>] = [:]
    @ObservationIgnored private var activeAnswerStatesByConversation: [UUID: RAGAnswerState] = [:]
    @ObservationIgnored private var activeUserMessagesByConversation: [UUID: RAGStoredMessage] = [:]
    @ObservationIgnored private var activeStreamingAnswersByConversation: [UUID: String] = [:]
    @ObservationIgnored private var activeStreamingPresentationsByConversation: [UUID: StreamingMarkdownSnapshot] = [:]
    @ObservationIgnored private var activeQueryPlansByConversation: [UUID: RAGQueryPlan] = [:]
    @ObservationIgnored private var activeRetrievalsByConversation: [UUID: RAGRetrievalResult] = [:]
    @ObservationIgnored private var activeContextUsageByConversation: [UUID: RAGContextUsage] = [:]
    @ObservationIgnored private var activeRemoteBlocksByConversation: [UUID: [RAGRemoteContextBlock]] = [:]
    /// 后台会话的可持久化时间线独立保存，避免切换后丢失执行审计或借用当前会话状态。
    @ObservationIgnored private var activeExecutionStepsByConversation: [UUID: [RAGExecutionStep]] = [:]
    /// 运行中的 Debug Trace 按会话隔离；切换后事件仍写原会话，并在切回时与磁盘历史合并。
    @ObservationIgnored private var liveDebugTracesByConversation: [UUID: [RAGDebugTrace]] = [:]
    @ObservationIgnored private var linkDetectionTask: Task<Void, Never>?

    var conversations: [RAGConversationSummary] = []
    var conversationGroups: [RAGConversationGroup] = []
    /// 点选分组目录时设置；点选会话时清空。新会话写入此分组。
    var selectedGroupID: UUID?
    var selectedConversationID: UUID?
    var messages: [RAGStoredMessage] = []
    /// 缓存未命中时使用轻量加载态，不能继续展示上一会话内容冒充当前选择。
    private(set) var isConversationLoading = false
    /// 只在持久化消息集合变化时重建，避免流式 revision 重复扫描历史消息。
    private(set) var conversationOutlineTurns: [RAGConversationOutlineTurn] = []
    /// Inspector 与 Answer Surface 共用同一份去重、排序后的引用投影。
    private(set) var conversationCitations: [RAGCitation] = []
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
    /// 用户在 Composer 主动授权本轮联网。按会话暂存，连续追问无需重复开启；关闭后
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
            if !isDebugModeEnabled {
                _ = debugTraceLoadGate.begin()
                debugTraces = []
                liveDebugTracesByConversation = [:]
            } else if let selectedConversationID {
                scheduleDebugTraceLoad(for: selectedConversationID)
            }
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

    /// 高频流式展示以 snapshot 为真源；`streamingAnswer` 只保留取消/失败收口期间的完整文本。
    var hasStreamingContent: Bool {
        !(streamingPresentation?.isEmpty ?? true) || !streamingAnswer.isEmpty
    }

    /// 「停止且尚无 AI 输出」时，末条用户消息常显复制 / 编辑。
    var pendingActionUserMessageID: UUID? {
        guard !isAnswering, !hasStreamingContent else { return nil }
        guard let last = messages.last, last.role == .user else { return nil }
        return last.id
    }

    var availableModels: [AIModelDescriptor] { dependencies.knowledgeRAGChatModels }

    var historicalRemoteContextAudits: [RAGRemoteContextAudit] {
        messages.flatMap(\.remoteContextAudits)
    }

    /// 当前轮结束后 `executionSteps` 会清空；Inspector 必须回退到最后一条 assistant
    /// 消息里的脱敏快照，用户切换历史会话时才不会看到空白计划。
    private var latestHistoricalExecutionTrace: [RAGExecutionStep]? {
        messages.reversed().first {
            $0.role == .assistant && $0.executionTrace.contains(where: { $0.queryPlan != nil })
        }?.executionTrace
    }

    var displayedQueryPlan: RAGQueryPlan? {
        if let queryPlan { return queryPlan }
        // 新问题已经进入消息列表、Planner 尚未返回时不能回放上一轮计划，否则会把旧计划
        // 错配到新问题上；停止后只留下孤立 user message 也遵循同一边界。
        guard messages.last?.role != .user else { return nil }
        return latestHistoricalExecutionTrace?.reversed().first(where: { $0.queryPlan != nil })?.queryPlan
    }

    var displayedRetrievalSnapshot: RAGRetrievalSnapshot? {
        if queryPlan != nil || messages.last?.role == .user {
            return retrieval.map(RAGRetrievalSnapshot.init(result:))
                ?? executionSteps.reversed().first(where: { $0.retrievalSnapshot != nil })?.retrievalSnapshot
        }
        return latestHistoricalExecutionTrace?.reversed()
            .first(where: { $0.retrievalSnapshot != nil })?.retrievalSnapshot
    }

    /// 当前轮优先使用内存结果；回答写入后回退到会话轨迹中的脱敏明细，保证漏斗 popover 与数字快照属于同一轮。
    var displayedRetrievalTrace: RAGRetrievalTrace? {
        if queryPlan != nil || messages.last?.role == .user {
            return retrieval?.trace
                ?? executionSteps.reversed().first(where: { $0.retrievalSnapshot?.trace != nil })?.retrievalSnapshot?.trace
        }
        return latestHistoricalExecutionTrace?.reversed()
            .first(where: { $0.retrievalSnapshot?.trace != nil })?.retrievalSnapshot?.trace
    }

    var displayedContextUsage: RAGContextUsage? {
        if queryPlan != nil || messages.last?.role == .user {
            return lastContextUsage
                ?? executionSteps.reversed()
                    .first(where: { $0.contextUsageSnapshot != nil })?.contextUsageSnapshot?.usage
        }
        return latestHistoricalExecutionTrace?.reversed()
            .first(where: { $0.contextUsageSnapshot != nil })?.contextUsageSnapshot?.usage
    }

    /// 计划快照与最近一轮问答绑定；原始问题从用户消息恢复，无需在 execution trace 再复制。
    var displayedPlanQuestion: String? {
        messages.last(where: { $0.role == .user })?.content
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
            // 与实际 Service 使用同一分片预算，避免 Composer 的 Context Usage 预览误导用户。
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
                scheduleConversationPrefetch(excluding: first.id)
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
                dependencies.ragComposerDraftStore.pruneRepos(keepingIDs: currentRepoIDs)
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
        let requestGeneration = conversationSelectionGate.begin()
        do {
            // 离开当前会话前先暂存未发送草稿，避免「新建」把 @repo / 附件带走。
            saveComposerDraft(for: selectedConversationID)
            // 当前选中目录时，新会话直接归入该一级分组。
            let conversation = try await conversationStore.createConversation(
                title: nil,
                groupID: selectedGroupID
            )
            conversations.insert(conversation, at: 0)
            // 创建本身已经成功时保留列表项，但若用户期间点选了别处，不再抢回当前选择。
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            selectedConversationID = conversation.id
            messages = []
            conversationContextSummary = nil
            conversationOutlineTurns = []
            conversationCitations = []
            isConversationLoading = false
            debugTraces = []
            liveDebugTracesByConversation[conversation.id] = []
            conversationPresentationCache.insert(
                RAGConversationPresentationSnapshot(
                    detail: RAGConversationDetail(summary: conversation, messages: [], contextSummary: nil),
                    outlineTurns: [],
                    citations: []
                )
            )
            resetTurnState()
            restoreComposerDraft(for: conversation.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectConversation(_ id: UUID) async {
        guard selectedConversationID != id || messages.isEmpty || isConversationLoading else { return }
        let previousConversationID = selectedConversationID
        let requestGeneration = conversationSelectionGate.begin()
        // 离开前写入 App 级内存草稿。回答态已有 *ByConversation；Composer 也必须按会话隔离，
        // 否则 resetTurnState 会把另一会话刚选的项目/附件清掉且无法恢复。
        if previousConversationID != id {
            saveComposerDraft(for: previousConversationID)
        }
        // 选择意图必须在第一次 await 之前提交：左栏立即响应，旧会话之后的流式事件也会
        // 因 selectedConversationID 已变化而停止投影到当前中栏。
        selectedConversationID = id
        selectedGroupID = nil
        debugTraces = []

        if let cached = conversationPresentationCache.value(for: id) {
            installSelectedConversation(cached)
            scheduleDebugTraceLoad(for: id)
            return
        }

        isConversationLoading = true
        messages = []
        conversationContextSummary = nil
        conversationOutlineTurns = []
        conversationCitations = []
        resetTurnState()
        restoreComposerDraft(for: id)
        restoreActiveAnswerPresentation(for: id)
        do {
            guard let detail = try await conversationStore.loadConversation(id: id) else {
                if conversationSelectionGate.isCurrent(requestGeneration) {
                    restorePreviousConversationAfterSelectionFailure(previousConversationID)
                }
                return
            }
            // 用户可能已点选另一会话。即使旧的 SQLite 读取此刻才返回，也不能覆盖 UI。
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            let snapshot = await Self.makePresentationSnapshot(from: detail)
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            installSelectedConversation(snapshot)
            scheduleDebugTraceLoad(for: id)
            // 切换会话不自动聚焦引用：用户停留在当前 Inspector tab，手动点芯片/正文 marker 再切「证据」。
        } catch {
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            restorePreviousConversationAfterSelectionFailure(previousConversationID)
            errorMessage = error.localizedDescription
        }
    }

    /// 读取失败时恢复点击前的已知快照。性能优化不能把一次临时 SQLite 错误变成“选中空会话”；
    /// 恢复后仍叠加原会话的最新运行态，后台回答不会因为失败回退而丢失可见进度。
    private func restorePreviousConversationAfterSelectionFailure(_ previousConversationID: UUID?) {
        guard let previousConversationID,
              let previous = conversationPresentationCache.value(for: previousConversationID) else {
            isConversationLoading = false
            return
        }
        selectedConversationID = previousConversationID
        installSelectedConversation(previous)
        scheduleDebugTraceLoad(for: previousConversationID)
    }

    /// 一次性安装选中会话的持久化快照，再叠加该会话仍在运行的瞬时状态。
    private func installSelectedConversation(_ snapshot: RAGConversationPresentationSnapshot) {
        let detail = snapshot.detail
        conversationPresentationCache.insert(snapshot)
        messages = detail.messages
        conversationContextSummary = detail.contextSummary
        conversationOutlineTurns = snapshot.outlineTurns
        conversationCitations = snapshot.citations
        loadedMessageSequence &+= 1
        resetTurnState()
        restoreComposerDraft(for: detail.summary.id)
        restoreActiveAnswerPresentation(for: detail.summary.id)
        isConversationLoading = false
    }

    /// 回答落库后刷新当前时间线，但不能重置 Composer、错误态或正在收尾的 generation。
    private func applyLoadedConversationMessages(_ detail: RAGConversationDetail) {
        let snapshot = Self.makePresentationSnapshotSynchronously(from: detail)
        conversationPresentationCache.insert(snapshot)
        messages = detail.messages
        conversationContextSummary = detail.contextSummary
        conversationOutlineTurns = snapshot.outlineTurns
        conversationCitations = snapshot.citations
        loadedMessageSequence &+= 1
    }

    private func restoreActiveAnswerPresentation(for conversationID: UUID) {
        if let activeUserMessage = activeUserMessagesByConversation[conversationID],
           !messages.contains(where: { $0.id == activeUserMessage.id }) {
            messages.append(activeUserMessage)
        }
        answerState = activeAnswerStatesByConversation[conversationID] ?? .idle
        answerElapsedDuration = answerElapsedDurationsByConversation[conversationID]
        streamingAnswer = activeStreamingAnswersByConversation[conversationID] ?? ""
        streamingPresentation = activeStreamingPresentationsByConversation[conversationID]
        queryPlan = activeQueryPlansByConversation[conversationID]
        retrieval = activeRetrievalsByConversation[conversationID]
        lastContextUsage = activeContextUsageByConversation[conversationID]
        remoteBlocks = activeRemoteBlocksByConversation[conversationID] ?? []
        executionSteps = activeExecutionStepsByConversation[conversationID] ?? []
        restoreRemoteContextState(for: conversationID)
    }

    /// 大纲和引用只依赖已落库消息；流式状态变化不能重复执行正则、去重和排序。
    private func rebuildConversationDerivedPresentation() {
        let derived = Self.makeDerivedPresentation(from: messages)
        conversationOutlineTurns = derived.outlineTurns
        conversationCitations = derived.citations
    }

    /// 首次会话安装把长文本预览压缩和引用排序移出 MainActor；缓存命中无需再次执行。
    private nonisolated static func makePresentationSnapshot(
        from detail: RAGConversationDetail,
        priority: TaskPriority = .userInitiated
    ) async -> RAGConversationPresentationSnapshot {
        await Task.detached(priority: priority) {
            makePresentationSnapshotSynchronously(from: detail)
        }.value
    }

    private nonisolated static func makePresentationSnapshotSynchronously(
        from detail: RAGConversationDetail
    ) -> RAGConversationPresentationSnapshot {
        let derived = makeDerivedPresentation(from: detail.messages)
        return RAGConversationPresentationSnapshot(
            detail: detail,
            outlineTurns: derived.outlineTurns,
            citations: derived.citations
        )
    }

    private nonisolated static func makeDerivedPresentation(
        from messages: [RAGStoredMessage]
    ) -> (outlineTurns: [RAGConversationOutlineTurn], citations: [RAGCitation]) {
        let outlineTurns = RAGConversationOutlineBuilder.completeTurns(from: messages)
        var seen = Set<UUID>()
        let citations = messages
            .flatMap(\.citations)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.repoFullName.localizedStandardCompare($1.repoFullName) == .orderedAscending
            }
        return (outlineTurns, citations)
    }

    /// Debug 不参与会话正文的关键路径。只在用户开启 Debug 时异步读取，并用独立
    /// generation 防止清空或快速切换后的迟到文件重新出现；历史仍完整展示，不改变功能。
    private func scheduleDebugTraceLoad(for conversationID: UUID) {
        let generation = debugTraceLoadGate.begin()
        guard isDebugModeEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let persisted = (try? await debugFileStore.load(conversationID: conversationID)) ?? []
            guard !Task.isCancelled,
                  isDebugModeEnabled,
                  selectedConversationID == conversationID,
                  debugTraceLoadGate.isCurrent(generation) else { return }
            let live = liveDebugTracesByConversation[conversationID] ?? []
            debugTraces = Dictionary(
                (persisted + live).map { ($0.id, $0) },
                uniquingKeysWith: { _, live in live }
            ).values.sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// 预热最近会话，以空间换取后续同帧切换。读取在 GRDB executor 上执行，主线程只接收
    /// 小型缓存写入；逐个读取避免启动时同时争抢数据库连接和解码 CPU。
    private func scheduleConversationPrefetch(excluding selectedID: UUID) {
        conversationPrefetchTask?.cancel()
        let ids = conversations.prefix(24).map(\.id).filter { $0 != selectedID }
        guard !ids.isEmpty else { return }
        conversationPrefetchTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(250))
            for id in ids {
                guard !Task.isCancelled else { return }
                guard answerGenerations[id] == nil else { continue }
                if let detail = try? await conversationStore.loadConversation(id: id),
                   answerGenerations[id] == nil {
                    let snapshot = await Self.makePresentationSnapshot(from: detail, priority: .utility)
                    guard !Task.isCancelled else { return }
                    if answerGenerations[id] == nil {
                        conversationPresentationCache.insert(snapshot)
                    }
                }
            }
        }
    }

    func deleteConversation(_ id: UUID) async {
        // 删除后的请求结果没有合法归属，必须丢弃而不是在取消回调中再补写用户消息。
        discardedAnswerConversationIDs.insert(id)
        cancelAnswer(for: id)
        cancelConversationTitleGeneration(for: id)
        do {
            try await conversationStore.deleteConversation(id: id)
            // Debug 文件是可丢弃数据：删除失败不能让已成功的会话删除回滚或报错。
            try? await debugFileStore.delete(conversationID: id)
            conversations.removeAll { $0.id == id }
            conversationPresentationCache.remove(id)
            dependencies.ragComposerDraftStore.remove(id)
            if selectedConversationID == id {
                if let next = conversations.first {
                    selectedConversationID = nil
                    await selectConversation(next.id)
                } else {
                    await newConversation()
                }
            }
        } catch {
            discardedAnswerConversationIDs.remove(id)
            errorMessage = error.localizedDescription
        }
    }

    /// 用户手动重命名：立刻写库但保持当前顺序；若自动标题仍在生成则取消，避免覆盖。
    func renameConversation(id: UUID, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelConversationTitleGeneration(for: id)
        do {
            try await conversationStore.renameConversation(id: id, title: trimmed)
            conversationPresentationCache.remove(id)
            updateConversationTitle(title: trimmed, for: id)
            // 重命名不改变 updated_at / pinned_at；回读只同步规范化标题与权威状态，顺序必须保持不变。
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 置顶 / 取消置顶：先本地乐观更新，再落库刷新，保证钉子图标与置顶区位置立刻响应。
    func setConversationPinned(id: UUID, isPinned: Bool) async {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].isPinned = isPinned
            conversations[index].pinnedAt = isPinned ? now : nil
            conversations.sort(by: Self.conversationListOrder)
        }
        do {
            try await conversationStore.setConversationPinned(id: id, isPinned: isPinned)
            conversationPresentationCache.remove(id)
            conversations = try await conversationStore.listConversations()
        } catch {
            errorMessage = error.localizedDescription
            // 写库失败时回读权威列表，撤销乐观态。
            conversations = (try? await conversationStore.listConversations()) ?? conversations
        }
    }

    func moveConversation(id: UUID, toGroupID groupID: UUID?) async {
        do {
            try await conversationStore.setConversationGroup(id: id, groupID: groupID)
            conversationPresentationCache.remove(id)
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
                conversationPresentationCache.remove(conversations[index].id)
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

    /// 所有置顶会话（跨分组 + 未分组）直接顶到侧栏列表最前，不单独成组。
    /// 顺序由 store 的 `pinned_at DESC` 保证：「最后置顶」永远在最上。
    var pinnedConversations: [RAGConversationSummary] {
        conversations.filter(\.isPinned)
    }

    /// 分组 / 未分组内的「未置顶」会话；置顶项已上浮到列表顶部，避免重复呈现。
    func unpinnedConversations(inGroupID groupID: UUID?) -> [RAGConversationSummary] {
        conversations.filter { $0.groupID == groupID && !$0.isPinned }
    }

    /// 与 `listConversations` SQL 一致：置顶优先，同组内最后置顶在前，其余按最近活跃。
    private static func conversationListOrder(_ lhs: RAGConversationSummary, _ rhs: RAGConversationSummary) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.isPinned, rhs.isPinned {
            let leftPinned = lhs.pinnedAt ?? ""
            let rightPinned = rhs.pinnedAt ?? ""
            if leftPinned != rightPinned { return leftPinned > rightPinned }
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    func send() {
        let question = draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID = selectedConversationID,
              !question.isEmpty,
              !isAnswering,
              composerBlockingReason == nil else { return }
        do {
            try dependencies.entitlementGate.requirePro(.knowledgeRAG)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        editingUserMessageID = nil
        editingUserDraft = ""
        // 发送当下立刻清输入框并同步草稿，避免 Task 调度前切走仍把同一段问题存回草稿。
        draftQuestion = ""
        dependencies.ragComposerDraftStore.update(conversationID) { draft in
            draft.draftQuestion = ""
        }
        startAnswerTiming(for: conversationID)
        activeAnswerStatesByConversation[conversationID] = .planning
        let priorMessages = messages
        let requestSnapshot = questionRequestSnapshot()
        let generationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await runQuestion(
                question,
                conversationID: conversationID,
                priorMessages: priorMessages,
                requestSnapshot: requestSnapshot,
                generationID: generationID
            )
        }
        answerGenerations[conversationID] = ConversationAnswerGeneration(id: generationID, task: task)
    }

    func cancelAnswer() {
        guard let conversationID = selectedConversationID else { return }
        cancelAnswer(for: conversationID)
        // 主动停止不是失败，清掉可能残留的错误弹窗。
        if isAnswering {
            answerState = .cancelled
            errorMessage = nil
        }
    }

    /// 只有用户明确停止或删除目标会话时才取消对应请求；选择其他会话绝不是取消理由。
    private func cancelAnswer(for conversationID: UUID) {
        answerGenerations.removeValue(forKey: conversationID)?.task.cancel()
        _ = finishAnswerTiming(for: conversationID)
        clearActiveAnswerPresentation(for: conversationID)
        clearRemoteContextState(for: conversationID)
    }

    /// 关闭 RAG 工作台前把当前会话 Composer 落盘；用户未切会话就关窗时也要保留草稿。
    func persistCurrentComposerDraft() {
        saveComposerDraft(for: selectedConversationID)
    }

    /// 关闭窗口或切换用户数据库时，所有进行中的请求都必须停止，避免旧账户结果落入新库。
    /// Composer 草稿由 `AppDependencies` 持有：普通关窗保留，切用户库前单独清空。
    func cancelAllAnswers() {
        conversationPrefetchTask?.cancel()
        conversationPrefetchTask = nil
        conversationPresentationCache.removeAll()
        _ = debugTraceLoadGate.begin()
        let runningConversationIDs = Set(answerGenerations.keys)
        discardedAnswerConversationIDs.formUnion(runningConversationIDs)
        for generation in answerGenerations.values { generation.task.cancel() }
        answerGenerations.removeAll()
        remoteContextConsents.removeAll()
        pendingRemoteWorkItemsByConversation.removeAll()
        approvedRemoteWorkItemIDsByConversation.removeAll()
        remoteContextConsent = nil
        for task in answerTimingTasks.values { task.cancel() }
        answerTimingTasks.removeAll()
        answerStartedAtByConversation.removeAll()
        answerElapsedDurationsByConversation.removeAll()
        answerElapsedDuration = nil
        // 标题生成虽然与主回答并行，但同样持有会话 store；关窗或切库时不能留下旧库写入。
        for conversationID in Array(conversationTitleGenerations.keys) {
            cancelConversationTitleGeneration(for: conversationID)
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
        rebuildConversationDerivedPresentation()
        conversationContextSummary = nil
        guard let conversationID = selectedConversationID else { return }
        conversationPresentationCache.remove(conversationID)
        startAnswerTiming(for: conversationID)
        activeAnswerStatesByConversation[conversationID] = .planning
        let priorMessages = messages
        let requestSnapshot = questionRequestSnapshot()
        let generationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            try? await conversationStore.deleteMessage(id: messageID)
            conversations = (try? await conversationStore.listConversations()) ?? conversations
            await runQuestion(
                question,
                conversationID: conversationID,
                priorMessages: priorMessages.filter { $0.id != messageID },
                requestSnapshot: requestSnapshot,
                generationID: generationID
            )
        }
        answerGenerations[conversationID] = ConversationAnswerGeneration(id: generationID, task: task)
    }

    /// 点击发送即进入可见处理态，而不是等待 Planner 或首个流式 token 返回。
    ///
    /// RAG 的主链包含历史压缩、规划、检索与生成；计时从这里开始才能如实反映用户等待。
    private func startAnswerTiming(for conversationID: UUID) {
        answerTimingTasks.removeValue(forKey: conversationID)?.cancel()
        let startedAt = Date()
        answerStartedAtByConversation[conversationID] = startedAt
        answerElapsedDurationsByConversation[conversationID] = 0
        if selectedConversationID == conversationID {
            answerElapsedDuration = 0
            answerState = .planning
        }
        answerTimingTasks[conversationID] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self,
                      self.answerStartedAtByConversation[conversationID] == startedAt else { return }
                let duration = Date().timeIntervalSince(startedAt)
                self.answerElapsedDurationsByConversation[conversationID] = duration
                if self.selectedConversationID == conversationID {
                    self.answerElapsedDuration = duration
                }
            }
        }
    }

    /// 最后一个 LLM 事件结束时冻结耗时；后续本地落库不能被误算进用户等待时间。
    @discardableResult
    private func finishAnswerTiming(for conversationID: UUID) -> TimeInterval {
        answerTimingTasks.removeValue(forKey: conversationID)?.cancel()
        guard let startedAt = answerStartedAtByConversation.removeValue(forKey: conversationID) else {
            return answerElapsedDurationsByConversation[conversationID] ?? 0
        }
        let duration = max(0, Date().timeIntervalSince(startedAt))
        answerElapsedDurationsByConversation[conversationID] = duration
        if selectedConversationID == conversationID {
            answerElapsedDuration = duration
        }
        return duration
    }

    /// 只有当前 generation 能结束该会话计时；旧任务收尾不能停止同会话的新重试计时器。
    private func finishAnswerTimingIfCurrent(
        for conversationID: UUID,
        generationID: UUID,
        fallbackStartedAt: Date
    ) -> TimeInterval {
        guard answerGenerations[conversationID]?.id == generationID else {
            return max(0, Date().timeIntervalSince(fallbackStartedAt))
        }
        return finishAnswerTiming(for: conversationID)
    }

    private func syncExecutionSteps(_ steps: [RAGExecutionStep], for conversationID: UUID) {
        activeExecutionStepsByConversation[conversationID] = steps
        if selectedConversationID == conversationID {
            executionSteps = steps
        }
    }

    private func updateAnswerState(_ state: RAGAnswerState, for conversationID: UUID) {
        if activeAnswerStatesByConversation[conversationID] != state {
            activeAnswerStatesByConversation[conversationID] = state
        }
        if selectedConversationID == conversationID, answerState != state {
            answerState = state
        }
    }

    /// 每个 `await` 后都要重新判断，不能缓存结果；否则 A 落库期间切到 B，迟到回调仍会覆盖 B。
    private func canUpdateVisibleAnswer(for conversationID: UUID, generationID: UUID) -> Bool {
        selectedConversationID == conversationID
            && (answerGenerations[conversationID]?.id == generationID
                || answerGenerations[conversationID] == nil)
    }

    private func clearActiveAnswerPresentation(for conversationID: UUID) {
        activeAnswerStatesByConversation[conversationID] = nil
        activeUserMessagesByConversation[conversationID] = nil
        activeStreamingAnswersByConversation[conversationID] = nil
        activeStreamingPresentationsByConversation[conversationID] = nil
        activeQueryPlansByConversation[conversationID] = nil
        activeRetrievalsByConversation[conversationID] = nil
        activeContextUsageByConversation[conversationID] = nil
        activeRemoteBlocksByConversation[conversationID] = nil
        activeExecutionStepsByConversation[conversationID] = nil
        answerElapsedDurationsByConversation[conversationID] = nil
    }

    private func questionRequestSnapshot() -> QuestionRequestSnapshot {
        QuestionRequestSnapshot(
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
                previousUserQuestion: nil,
                previousReferencedRepos: [],
                webSearchEnabled: webSearchEnabled,
                disabledRemoteResources: []
            ),
            modelID: selectedModelID,
            modelDisplayName: selectedModelDisplayName,
            modelParameters: selectedModelParameters,
            contextSummary: conversationContextSummary,
            isDebugEnabled: isDebugModeEnabled,
            debugEndpoint: selectedModelEndpoint
        )
    }

    func toggleRemoteWorkItem(_ id: String) {
        if approvedRemoteWorkItemIDs.contains(id) {
            approvedRemoteWorkItemIDs.remove(id)
        } else {
            approvedRemoteWorkItemIDs.insert(id)
        }
        if let conversationID = selectedConversationID {
            approvedRemoteWorkItemIDsByConversation[conversationID] = approvedRemoteWorkItemIDs
        }
    }

    func confirmRemoteContext() {
        guard let conversationID = selectedConversationID else { return }
        let consent = remoteContextConsents[conversationID]
        pendingRemoteWorkItems = []
        pendingRemoteWorkItemsByConversation[conversationID] = []
        remoteContextConsents[conversationID] = nil
        Task { await consent?.resolve(approvedRemoteWorkItemIDs) }
    }

    func skipRemoteContext() {
        guard let conversationID = selectedConversationID else { return }
        let consent = remoteContextConsents[conversationID]
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        pendingRemoteWorkItemsByConversation[conversationID] = []
        approvedRemoteWorkItemIDsByConversation[conversationID] = []
        remoteContextConsents[conversationID] = nil
        Task { await consent?.resolve([]) }
    }

    private func restoreRemoteContextState(for conversationID: UUID) {
        remoteContextConsent = remoteContextConsents[conversationID]
        pendingRemoteWorkItems = pendingRemoteWorkItemsByConversation[conversationID] ?? []
        approvedRemoteWorkItemIDs = approvedRemoteWorkItemIDsByConversation[conversationID] ?? []
    }

    private func clearRemoteContextState(for conversationID: UUID) {
        remoteContextConsents[conversationID] = nil
        pendingRemoteWorkItemsByConversation[conversationID] = nil
        approvedRemoteWorkItemIDsByConversation[conversationID] = nil
        if selectedConversationID == conversationID {
            remoteContextConsent = nil
            pendingRemoteWorkItems = []
            approvedRemoteWorkItemIDs = []
        }
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
        _ = debugTraceLoadGate.begin()
        debugTraces = []
        guard let conversationID = selectedConversationID else { return }
        liveDebugTracesByConversation[conversationID] = []
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

    /// 元数据数字下钻到主窗口。筛选通过 dispatcher 以完整临时快照发布，不触碰用户设置。
    func openMainWindowMetadataDestination(
        _ selection: SidebarItem,
        filters: GlobalRepoFilterState
    ) {
        dependencies.mainWindowNavigationDispatcher.navigate(
            to: .manage(selection),
            temporaryFilters: filters
        )
    }

    /// “标签总数”只负责露出主窗口 Tags 分类，不注入筛选。
    func revealMainWindowTags() {
        dependencies.mainWindowNavigationDispatcher.navigate(to: .revealTags)
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

    /// Star Top10 行用稳定 repo id 查实时对象，再复用独立详情窗入口。
    func openMetadataRepository(_ repository: KnowledgeBaseMetadataSnapshot.TopRepository) {
        Task {
            guard let repo = try? await dependencies.repoRepository.findById(repository.repoID) else { return }
            openLocalRepoDetail(repo)
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
        generationID: UUID,
        contextSummary: RAGConversationContextSummary?,
        modelParameters: AIModelParameters,
        isDebugEnabled: Bool,
        debugEndpoint: String?,
        debugTraceID: UUID?,
        debugTraceStartedAt: Date
    ) async throws -> [AIChatMessage] {
        let validSummary = contextSummary.flatMap { summary in
            summary.coveredMessageCount >= 0 && summary.coveredMessageCount <= messages.count
                ? summary
                : nil
        }
        let coveredCount = RAGConversationHistoryBuilder.compressionCoverageTarget(
            messages: messages,
            existingSummary: validSummary,
            contextWindowTokens: modelParameters.resolvedContextWindowTokens,
            maximumOutputTokens: modelParameters.maxCompletionTokens
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
            isDebugEnabled: isDebugEnabled,
            debugEndpoint: debugEndpoint
        )
        guard !Task.isCancelled,
              answerGenerations[conversationID]?.id == generationID else {
            throw CancellationError()
        }
        let compressed: String
        switch compression {
        case .completed(let summary, let debugEvents):
            appendDebugEvents(
                debugEvents,
                rebasingFrom: compressionStartedAt,
                traceStartedAt: debugTraceStartedAt,
                to: debugTraceID,
                conversationID: conversationID
            )
            compressed = summary
        case .failed(let debugEvents):
            appendDebugEvents(
                debugEvents,
                rebasingFrom: compressionStartedAt,
                traceStartedAt: debugTraceStartedAt,
                to: debugTraceID,
                conversationID: conversationID
            )
            // Provider 不可用时仍走相同的 coverage，避免下一轮又把旧原文无限带回请求。
            compressed = RAGConversationContextCompressor.fallback(
                existingSummary: validSummary?.content,
                messages: newlyCovered,
                tokenBudget: RAGConversationHistoryBuilder.summaryTokenLimit(
                    contextWindowTokens: modelParameters.resolvedContextWindowTokens,
                    maximumOutputTokens: modelParameters.maxCompletionTokens
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
            conversationPresentationCache.remove(conversationID)
            if selectedConversationID == conversationID { conversationContextSummary = summary }
        } catch {
            // 写盘失败时继续使用内存摘要完成本轮，避免存储短暂错误中断聊天；下一次加载
            // 会自然回退并再次尝试压缩。
            if selectedConversationID == conversationID { conversationContextSummary = summary }
        }
        return RAGConversationHistoryBuilder.build(from: messages, contextSummary: summary)
    }

    private func runQuestion(
        _ question: String,
        conversationID: UUID,
        priorMessages: [RAGStoredMessage],
        requestSnapshot: QuestionRequestSnapshot,
        generationID: UUID
    ) async {
        guard !Task.isCancelled,
              answerGenerations[conversationID]?.id == generationID else { return }
        let turnStartedAt = Date()
        let debugTraceStartedAt = Date()
        let debugTraceID = requestSnapshot.isDebugEnabled
            ? beginDebugTrace(
                category: .questionAnswer,
                startedAt: debugTraceStartedAt,
                conversationID: conversationID
            )
            : nil
        let isFirstTurn = priorMessages.isEmpty
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
        activeUserMessagesByConversation[conversationID] = userMessage
        activeStreamingAnswersByConversation[conversationID] = ""
        activeStreamingPresentationsByConversation[conversationID] = nil
        activeQueryPlansByConversation[conversationID] = nil
        activeRetrievalsByConversation[conversationID] = nil
        activeContextUsageByConversation[conversationID] = nil
        activeRemoteBlocksByConversation[conversationID] = nil
        if selectedConversationID == conversationID {
            messages.append(userMessage)
            draftQuestion = ""
            streamingAnswer = ""
            streamingPresentation = nil
            queryPlan = nil
            retrieval = nil
            lastContextUsage = nil
            executionSteps = []
            remoteBlocks = []
            pendingRemoteWorkItems = []
            approvedRemoteWorkItemIDs = []
            selectedCitation = nil
            selectedCitationChunk = nil
            citationChunkPopoverCitationID = nil
            errorMessage = nil
        }
        // 只清问题草稿。此时内存里的 @repo/附件可能已属于另一会话，绝不能反写回本会话。
        dependencies.ragComposerDraftStore.update(conversationID) { draft in
            draft.draftQuestion = ""
        }
        var completedPayload: (String, String, [RAGCitation])?
        var terminalReply: String?
        var suggestedActions: [RAGSuggestedQuestionAction] = []
        var collectedRemoteBlocks: [RAGRemoteContextBlock] = []
        var turnExecutionSteps: [RAGExecutionStep] = []
        syncExecutionSteps(turnExecutionSteps, for: conversationID)
        var turnState: RAGAnswerState = .planning
        var didStartTitleGeneration = false
        let streamingMessageID = UUID()
        let streamingTimestamp = Date()
        var accumulatedAnswer = ""
        // 正文发布严格限制为 8Hz。完整回答独立累计，较大的网络批次也不能绕过
        // UI 上限，否则单次回调中的 token 数越多，反而越容易触发连续重排。
        var answerPresentationThrottle = StreamingPresentationThrottle(minimumInterval: 0.125)
        var presentationRevision = 0
        var markdownAssembler = StreamingMarkdownAssembler()
        // Think 可能按 token 回调。完整文本留在 buffer，只有节流后的快照进入
        // `executionSteps`。运行态严格 5Hz 且只展示最近 8,000 字符，避免长 Think
        // 反复测量完整增长文本；终态仍从 buffer.text 发布完整内容并持久化。
        var planningReasoningBuffer = StreamingTextPresentationBuffer(
            throttleInterval: 0.20,
            immediateCharacterCount: nil,
            maximumPresentedCharacterCount: 8_000
        )
        var answerReasoningBuffer = StreamingTextPresentationBuffer(
            throttleInterval: 0.20,
            immediateCharacterCount: nil,
            maximumPresentedCharacterCount: 8_000
        )
        let initialStreamingPresentation = StreamingMarkdownSnapshot(
            messageID: streamingMessageID,
            timestamp: streamingTimestamp,
            stableMarkdownChunks: [],
            liveTail: "",
            revision: 0
        )
        activeStreamingPresentationsByConversation[conversationID] = initialStreamingPresentation
        if selectedConversationID == conversationID {
            streamingPresentation = initialStreamingPresentation
        }

        do {
            let service = try dependencies.makeKnowledgeRAGService(selectedModelID: requestSnapshot.modelID)
            let history = try await preparedConversationHistory(
                using: service,
                conversationID: conversationID,
                messages: priorMessages,
                generationID: generationID,
                contextSummary: requestSnapshot.contextSummary,
                modelParameters: requestSnapshot.modelParameters,
                isDebugEnabled: requestSnapshot.isDebugEnabled,
                debugEndpoint: requestSnapshot.debugEndpoint,
                debugTraceID: debugTraceID,
                debugTraceStartedAt: debugTraceStartedAt
            )
            guard !Task.isCancelled,
                  answerGenerations[conversationID]?.id == generationID else {
                throw CancellationError()
            }
            let consent = RAGRemoteContextConsent()
            remoteContextConsents[conversationID] = consent
            if selectedConversationID == conversationID {
                remoteContextConsent = consent
            }
            let request = RAGServiceRequest(
                rawQuestion: question,
                composerContext: RAGComposerContext(
                    explicitRepoIDs: requestSnapshot.composerContext.explicitRepoIDs,
                    explicitRepoReferences: requestSnapshot.composerContext.explicitRepoReferences,
                    webSearchRepoReferences: requestSnapshot.composerContext.webSearchRepoReferences,
                    explicitRepoMode: requestSnapshot.composerContext.explicitRepoMode,
                    selectedModelID: requestSnapshot.composerContext.selectedModelID,
                    attachments: requestSnapshot.composerContext.attachments,
                    pastedGitHubLinks: requestSnapshot.composerContext.pastedGitHubLinks,
                    previousUserQuestion: previousUserQuestion,
                    previousReferencedRepos: previousReferencedRepos,
                    webSearchEnabled: requestSnapshot.composerContext.webSearchEnabled,
                    disabledRemoteResources: requestSnapshot.composerContext.disabledRemoteResources
                ),
                conversationID: conversationID,
                isDebugEnabled: requestSnapshot.isDebugEnabled,
                debugEndpoint: requestSnapshot.debugEndpoint,
                debugTraceStartedAt: requestSnapshot.isDebugEnabled ? debugTraceStartedAt : nil
            )
            for try await event in service.ask(request: request, history: history, remoteContextConsent: consent) {
                // Provider 可能在 cancel 后仍送达缓冲事件；旧 generation 不得继续写状态或落库。
                guard answerGenerations[conversationID]?.id == generationID else {
                    throw CancellationError()
                }
                switch event {
                case .state(let state):
                    turnState = state
                    terminalReply = terminalReply ?? reply(for: state)
                    finishRunningExecutionIfNeeded(for: state, in: &turnExecutionSteps)
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    updateAnswerState(state, for: conversationID)
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
                            applyReasoningPresentation(
                                kind: kind,
                                text: presentation,
                                in: &turnExecutionSteps
                            )
                            syncExecutionSteps(turnExecutionSteps, for: conversationID)
                        }
                    case .reasoningCompleted(let kind):
                        let now = Date.timeIntervalSinceReferenceDate
                        let finalPresentation: String?
                        switch kind {
                        case .planningReasoning:
                            _ = planningReasoningBuffer.flush(now: now)
                            finalPresentation = planningReasoningBuffer.text
                        case .answerReasoning:
                            _ = answerReasoningBuffer.flush(now: now)
                            finalPresentation = answerReasoningBuffer.text
                        default:
                            finalPresentation = nil
                        }
                        if let finalPresentation, !finalPresentation.isEmpty {
                            applyReasoningPresentation(
                                kind: kind,
                                text: finalPresentation,
                                in: &turnExecutionSteps
                            )
                        }
                        applyExecution(event, to: &turnExecutionSteps)
                        syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    default:
                        applyExecution(event, to: &turnExecutionSteps)
                        syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    }
                case .plan(let plan):
                    activeQueryPlansByConversation[conversationID] = plan
                    if selectedConversationID == conversationID { queryPlan = plan }
                    // 纯闲聊已由本地引导响应处理，不值得再调用一次标题 LLM。其它首轮在
                    // Planner 完成后并行生成标题，不阻塞检索和回答。
                    if isFirstTurn, !didStartTitleGeneration, plan.mode != .guidedDiscovery {
                        didStartTitleGeneration = true
                        generateConversationTitle(
                            using: service,
                            conversationID: conversationID,
                            firstQuestion: question,
                            isDebugEnabled: requestSnapshot.isDebugEnabled,
                            debugEndpoint: requestSnapshot.debugEndpoint
                        )
                    }
                case .retrieval(let result):
                    activeRetrievalsByConversation[conversationID] = result
                    updateExecutionStep(in: &turnExecutionSteps, kind: .retrieval) { step in
                        step.retrievalSnapshot = RAGRetrievalSnapshot(result: result)
                    }
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    if selectedConversationID == conversationID {
                        retrieval = result
                    }
                case .remoteContextConfirmation(let workItems):
                    pendingRemoteWorkItemsByConversation[conversationID] = workItems
                    approvedRemoteWorkItemIDsByConversation[conversationID] = Set(workItems.map(\.id))
                    if selectedConversationID == conversationID {
                        pendingRemoteWorkItems = workItems
                        approvedRemoteWorkItemIDs = Set(workItems.map(\.id))
                    }
                case .remoteContext(let blocks):
                    collectedRemoteBlocks = blocks
                    activeRemoteBlocksByConversation[conversationID] = blocks
                    if selectedConversationID == conversationID { remoteBlocks = blocks }
                case .terminal(let response):
                    terminalReply = response.answer
                    suggestedActions = response.suggestedActions
                case .metadataSnapshot(let snapshot): knowledgeBaseMetadataSnapshot = snapshot
                case .contextUsage(let usage):
                    activeContextUsageByConversation[conversationID] = usage
                    // 规划步骤贯穿整轮且一定会持久化；把数字快照挂在这里，避免生成步骤尚未
                    // started 时事件无处承载，同时不保存 usage.promptPreview。
                    updateExecutionStep(in: &turnExecutionSteps, kind: .planning) { step in
                        step.contextUsageSnapshot = RAGContextUsageSnapshot(usage: usage)
                    }
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    if selectedConversationID == conversationID {
                        lastContextUsage = usage
                    }
                case .debug(let event):
                    appendDebugEvent(event, to: debugTraceID, conversationID: conversationID)
                case .delta(let text):
                    accumulatedAnswer += text
                    markdownAssembler.append(text)
                    let now = Date.timeIntervalSinceReferenceDate
                    // Provider 可能逐 token 或按大批次回调。两者都严格按 8Hz 发布；冻结
                    // 前缀不会在后续 token 到达时重复进入 MarkdownUI。
                    guard answerPresentationThrottle.shouldCommit(now: now) else { continue }
                    presentationRevision &+= 1
                    let presentation = StreamingMarkdownSnapshot(
                        messageID: streamingMessageID,
                        timestamp: streamingTimestamp,
                        stableMarkdownChunks: markdownAssembler.stableMarkdownChunks,
                        liveTail: markdownAssembler.liveTail,
                        revision: presentationRevision
                    )
                    activeStreamingPresentationsByConversation[conversationID] = presentation
                    if selectedConversationID == conversationID { streamingPresentation = presentation }
                case .completed(let answer, let model, let citations, _):
                    completedPayload = (answer, model, citations)
                }
            }
            guard !Task.isCancelled,
                  answerGenerations[conversationID]?.id == generationID else {
                throw CancellationError()
            }
            // Provider 失败或提前结束时未必发送 reasoningCompleted；落库前仍要补齐最后
            // 一批 Think，避免性能节流变成数据丢失。
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer,
                executionSteps: &turnExecutionSteps
            )
            syncExecutionSteps(turnExecutionSteps, for: conversationID)
            let processingDuration = finishAnswerTimingIfCurrent(
                for: conversationID,
                generationID: generationID,
                fallbackStartedAt: turnStartedAt
            )
            if discardedAnswerConversationIDs.contains(conversationID) {
                // 窗口关闭、切库或会话删除期间，底层 Provider 可能忽略取消后仍返回 completed。
                // 此处作为最后防线，确保它绝不会把旧结果写进已失效的会话/数据库。
            } else if let completedPayload {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: completedPayload.0,
                    model: completedPayload.1,
                    citations: completedPayload.2,
                    remoteContexts: collectedRemoteBlocks,
                    executionTrace: turnExecutionSteps,
                    suggestedActions: [],
                    processingDuration: processingDuration,
                    generationID: generationID
                )
            } else if let terminalReply, turnState != .cancelled {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: terminalReply,
                    model: requestSnapshot.modelDisplayName,
                    citations: [],
                    remoteContexts: collectedRemoteBlocks,
                    executionTrace: turnExecutionSteps,
                    suggestedActions: suggestedActions,
                    processingDuration: processingDuration,
                    generationID: generationID
                )
            } else if turnState == .cancelled, !discardedAnswerConversationIDs.contains(conversationID) {
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    processingDuration: processingDuration,
                    partialAnswer: accumulatedAnswer,
                    model: requestSnapshot.modelDisplayName,
                    remoteContexts: collectedRemoteBlocks,
                    executionTrace: turnExecutionSteps,
                    generationID: generationID
                )
            }
        } catch is CancellationError {
            turnState = .cancelled
            let canPublishCancelledState = answerGenerations[conversationID]?.id == generationID
                || answerGenerations[conversationID] == nil
            if canPublishCancelledState {
                updateAnswerState(.cancelled, for: conversationID)
            }
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer,
                executionSteps: &turnExecutionSteps
            )
            if canPublishCancelledState {
                syncExecutionSteps(turnExecutionSteps, for: conversationID)
            }
            if canPublishCancelledState, selectedConversationID == conversationID {
                streamingAnswer = accumulatedAnswer
            }
            if canPublishCancelledState {
                activeStreamingAnswersByConversation[conversationID] = accumulatedAnswer
            }
            let processingDuration = finishAnswerTimingIfCurrent(
                for: conversationID,
                generationID: generationID,
                fallbackStartedAt: turnStartedAt
            )
            if !discardedAnswerConversationIDs.contains(conversationID) {
                scheduleFinalizeCancelledTurn(
                    conversationID: conversationID,
                    userMessage: userMessage,
                    question: question,
                    processingDuration: processingDuration,
                    partialAnswer: accumulatedAnswer,
                    model: requestSnapshot.modelDisplayName,
                    remoteContexts: collectedRemoteBlocks,
                    executionTrace: turnExecutionSteps,
                    generationID: generationID
                )
            }
        } catch {
            flushReasoningPresentations(
                planning: &planningReasoningBuffer,
                answer: &answerReasoningBuffer,
                executionSteps: &turnExecutionSteps
            )
            // 停止按钮会 cancel Task；部分底层 API 不抛 CancellationError 而是带上
            // Task.isCancelled，不能当成「RAG 请求失败」弹窗。
            if Task.isCancelled {
                turnState = .cancelled
                let canPublishCancelledState = answerGenerations[conversationID]?.id == generationID
                    || answerGenerations[conversationID] == nil
                if canPublishCancelledState {
                    updateAnswerState(.cancelled, for: conversationID)
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                }
                if canPublishCancelledState, selectedConversationID == conversationID {
                    streamingAnswer = accumulatedAnswer
                }
                if canPublishCancelledState {
                    activeStreamingAnswersByConversation[conversationID] = accumulatedAnswer
                }
                let processingDuration = finishAnswerTimingIfCurrent(
                    for: conversationID,
                    generationID: generationID,
                    fallbackStartedAt: turnStartedAt
                )
                if !discardedAnswerConversationIDs.contains(conversationID) {
                    scheduleFinalizeCancelledTurn(
                        conversationID: conversationID,
                        userMessage: userMessage,
                        question: question,
                        processingDuration: processingDuration,
                        partialAnswer: accumulatedAnswer,
                        model: requestSnapshot.modelDisplayName,
                        remoteContexts: collectedRemoteBlocks,
                        executionTrace: turnExecutionSteps,
                        generationID: generationID
                    )
                }
            } else {
                turnState = .failed(error.localizedDescription)
                if answerGenerations[conversationID]?.id == generationID {
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    updateAnswerState(turnState, for: conversationID)
                    _ = finishAnswerTimingIfCurrent(
                        for: conversationID,
                        generationID: generationID,
                        fallbackStartedAt: turnStartedAt
                    )
                    if selectedConversationID == conversationID {
                        retryQuestion = question
                        presentWorkspaceError(error)
                    }
                    // 正常失败也必须与取消路径同样保留问题：用户能直接复制或编辑后重试，
                    // 不能因 Provider / 附件临时故障被迫重新输入。
                    scheduleFinalizeFailedTurn(
                        conversationID: conversationID,
                        userMessage: userMessage,
                        question: question,
                        generationID: generationID
                    )
                }
            }
        }
        let finishedDebugTrace = finishDebugTrace(
            debugTraceID,
            state: debugTraceState(for: turnState),
            conversationID: conversationID
        )
        if discardedAnswerConversationIDs.contains(conversationID) {
            // 删除会话后不能由迟到的任务重新创建其 Debug 文件；切库时也不能写入新账户目录。
            if let finishedDebugTrace {
                liveDebugTracesByConversation[conversationID]?.removeAll { $0.id == finishedDebugTrace.id }
            }
        } else {
            await persistDebugTrace(
                finishedDebugTrace,
                conversationID: conversationID,
                userMessageID: userMessage.id
            )
        }
        if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
            remoteContextConsent = nil
            if turnState != .generating { streamingPresentation = nil }
        }
        if answerGenerations[conversationID]?.id == generationID {
            clearRemoteContextState(for: conversationID)
            clearActiveAnswerPresentation(for: conversationID)
            answerGenerations[conversationID] = nil
        } else if answerGenerations[conversationID] == nil {
            // 主动停止会先移除 generation；若期间没有新重试，旧任务收尾仍负责释放快照。
            clearActiveAnswerPresentation(for: conversationID)
        }
        discardedAnswerConversationIDs.remove(conversationID)
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
        question: String,
        generationID: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                conversationPresentationCache.remove(conversationID)
                try await conversationStore.appendUserMessage(
                    conversationID: conversationID,
                    messageID: userMessage.id,
                    question: question,
                    createdAt: userMessage.createdAt
                )
                if canUpdateVisibleAnswer(for: conversationID, generationID: generationID),
                   let detail = try await conversationStore.loadConversation(id: conversationID),
                   canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                    applyLoadedConversationMessages(detail)
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
        processingDuration: TimeInterval,
        partialAnswer: String,
        model: String,
        remoteContexts: [RAGRemoteContextBlock],
        executionTrace: [RAGExecutionStep],
        generationID: UUID
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await finalizeCancelledTurn(
                conversationID: conversationID,
                userMessage: userMessage,
                question: question,
                processingDuration: processingDuration,
                partialAnswer: partialAnswer,
                model: model,
                remoteContexts: remoteContexts,
                executionTrace: executionTrace,
                generationID: generationID
            )
        }
    }

    /// 停止生成：保留用户问题；已有流式文本则落库半截回答，否则只落库用户消息。
    private func finalizeCancelledTurn(
        conversationID: UUID,
        userMessage: RAGStoredMessage,
        question: String,
        processingDuration: TimeInterval,
        partialAnswer: String,
        model: String,
        remoteContexts: [RAGRemoteContextBlock],
        executionTrace: [RAGExecutionStep],
        generationID: UUID
    ) async {
        let partial = partialAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if partial.isEmpty {
            // 尚无 AI 输出：保留气泡，落库用户消息，供复制 / 编辑。
            do {
                conversationPresentationCache.remove(conversationID)
                try await conversationStore.appendUserMessage(
                    conversationID: conversationID,
                    messageID: userMessage.id,
                    question: question,
                    createdAt: userMessage.createdAt
                )
                if canUpdateVisibleAnswer(for: conversationID, generationID: generationID),
                   let detail = try await conversationStore.loadConversation(id: conversationID),
                   canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                    applyLoadedConversationMessages(detail)
                }
                conversations = try await conversationStore.listConversations()
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗。
            } catch {
                // 落库失败仍保留内存中的用户气泡，避免「停止后问题消失」。
                if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                    errorMessage = error.localizedDescription
                }
            }
            if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                streamingAnswer = ""
            }
        } else {
            do {
                try await persistAnswer(
                    conversationID: conversationID,
                    question: question,
                    answer: partial,
                    model: model,
                    citations: [],
                    remoteContexts: remoteContexts,
                    executionTrace: executionTrace,
                    processingDuration: processingDuration,
                    generationID: generationID
                )
            } catch is CancellationError {
                // 忽略：停止路径不应弹失败窗；半截文本仍挂到时间线。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: model,
                    citations: [],
                    remoteContextAudits: [],
                    processingDuration: processingDuration,
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                    if !messages.contains(where: { $0.id == userMessage.id }) {
                        messages.append(userMessage)
                    }
                    if !messages.contains(where: { $0.role == .assistant && $0.content == partial }) {
                        messages.append(assistant)
                    }
                    rebuildConversationDerivedPresentation()
                    streamingAnswer = ""
                }
            } catch {
                // 落库失败时至少把半截流式文本挂成助手气泡，避免只剩用户问题。
                let assistant = RAGStoredMessage(
                    id: UUID(),
                    conversationID: conversationID,
                    role: .assistant,
                    content: partial,
                    model: model,
                    citations: [],
                    remoteContextAudits: [],
                    processingDuration: processingDuration,
                    createdAt: ISO8601DateFormatter.shared.string(from: Date())
                )
                if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
                    if !messages.contains(where: { $0.id == userMessage.id }) {
                        messages.append(userMessage)
                    }
                    messages.append(assistant)
                    rebuildConversationDerivedPresentation()
                    streamingAnswer = ""
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 标题请求从回答任务中拆开：仅使用首个问题，和检索/流式回答并行进行。
    /// 同一会话最多保留一个任务；切换会话不取消它，只有删除或人工重命名才明确作废。
    private func generateConversationTitle(
        using service: KnowledgeRAGService,
        conversationID: UUID,
        firstQuestion: String,
        isDebugEnabled: Bool,
        debugEndpoint: String?
    ) {
        cancelConversationTitleGeneration(for: conversationID)
        let generationID = UUID()
        let debugTraceID = isDebugEnabled
            ? beginDebugTrace(category: .conversationTitle, conversationID: conversationID)
            : nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await service.generateConversationTitle(
                firstQuestion: firstQuestion,
                isDebugEnabled: isDebugEnabled,
                debugEndpoint: debugEndpoint
            )
            guard !Task.isCancelled,
                  isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }

            switch result {
            case .completed(let title, let debugEvents):
                appendDebugEvents(debugEvents, to: debugTraceID, conversationID: conversationID)
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
                appendDebugEvents(debugEvents, to: debugTraceID, conversationID: conversationID)
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
        finishDebugTrace(generation.debugTraceID, state: .cancelled, conversationID: conversationID)
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
        finishDebugTrace(generation.debugTraceID, state: debugState, conversationID: conversationID)
        conversationTitleGenerations.removeValue(forKey: conversationID)
    }

    private func beginDebugTrace(
        category: RAGDebugTraceCategory,
        startedAt: Date = Date(),
        conversationID: UUID
    ) -> UUID {
        let trace = RAGDebugTrace(
            id: UUID(),
            category: category,
            startedAt: startedAt,
            state: .running,
            events: []
        )
        var liveTraces = liveDebugTracesByConversation[conversationID] ?? []
        liveTraces.append(trace)
        trimDebugTraceMemory(&liveTraces)
        liveDebugTracesByConversation[conversationID] = liveTraces
        if selectedConversationID == conversationID {
            debugTraces.append(trace)
            trimDebugTraceMemory(&debugTraces)
        }
        return trace.id
    }

    private func appendDebugEvent(
        _ event: RAGDebugEvent,
        to traceID: UUID?,
        conversationID: UUID
    ) {
        // 是否采集已在请求快照和 trace 创建时决定；后台 A 不应因当前 B 的 UI 设置变化而改写策略。
        guard let traceID else { return }
        let boundedEvent = Self.boundedDebugEvent(event)
        // GitHub 远程上下文会并发完成；continuation 的送达顺序不保证严格等于发生时间。
        // 按 Trace 相对时间插入，Inspector 的相邻事件耗时始终可解释，且缓存/网络混合时
        // 不会出现负耗时。
        var liveTraces = liveDebugTracesByConversation[conversationID] ?? []
        guard let liveIndex = liveTraces.firstIndex(where: { $0.id == traceID }) else { return }
        insertDebugEvent(boundedEvent, into: &liveTraces[liveIndex])
        trimDebugTraceMemory(&liveTraces)
        liveDebugTracesByConversation[conversationID] = liveTraces
        if selectedConversationID == conversationID,
           let visibleIndex = debugTraces.firstIndex(where: { $0.id == traceID }) {
            insertDebugEvent(boundedEvent, into: &debugTraces[visibleIndex])
            trimDebugTraceMemory(&debugTraces)
        }
    }

    private func insertDebugEvent(_ event: RAGDebugEvent, into trace: inout RAGDebugTrace) {
        let insertionIndex = trace.events.firstIndex {
            $0.elapsedSeconds > event.elapsedSeconds
        } ?? trace.events.endIndex
        trace.events.insert(event, at: insertionIndex)
        if trace.events.count > DebugTraceLimit.maxEventsPerTrace {
            trace.events.removeFirst(trace.events.count - DebugTraceLimit.maxEventsPerTrace)
        }
    }

    /// 保留结构化 Trace 的类型信息，仅裁剪可能包含长文本的通用 payload 与最终分片详情。
    /// Rerank 详情不应在此处降为普通字符串，否则独立的“重排序”行无法渲染其请求和返回。
    static func boundedDebugEvent(_ event: RAGDebugEvent) -> RAGDebugEvent {
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
            retrievalPayload: boundedRetrievalPayload,
            rerankPayload: event.rerankPayload
        )
        return boundedEvent
    }

    private func appendDebugEvents(
        _ events: [RAGDebugEvent],
        to traceID: UUID?,
        conversationID: UUID
    ) {
        for event in events {
            appendDebugEvent(event, to: traceID, conversationID: conversationID)
        }
    }

    /// 压缩调用在 `ask` 前完成，Service 返回的是以压缩起点为零的局部耗时。写入问答
    /// Trace 前须换算为全局耗时，Inspector 的相邻事件差分才能正确反映实际等待时间。
    private func appendDebugEvents(
        _ events: [RAGDebugEvent],
        rebasingFrom localStartedAt: Date,
        traceStartedAt: Date,
        to traceID: UUID?,
        conversationID: UUID
    ) {
        let offset = max(localStartedAt.timeIntervalSince(traceStartedAt), 0)
        for event in events {
            appendDebugEvent(
                Self.rebasedDebugEvent(event, offset: offset),
                to: traceID,
                conversationID: conversationID
            )
        }
    }

    /// 压缩等辅助调用会使用自己的计时起点；重设耗时时仍需原样保留两类结构化 Debug payload。
    static func rebasedDebugEvent(_ event: RAGDebugEvent, offset: TimeInterval) -> RAGDebugEvent {
        RAGDebugEvent(
            id: event.id,
            stage: event.stage,
            elapsedSeconds: offset + event.elapsedSeconds,
            payload: event.payload,
            retrievalPayload: event.retrievalPayload,
            rerankPayload: event.rerankPayload
        )
    }

    @discardableResult
    private func finishDebugTrace(
        _ traceID: UUID?,
        state: RAGDebugTrace.State,
        conversationID: UUID
    ) -> RAGDebugTrace? {
        guard let traceID else { return nil }
        var liveTraces = liveDebugTracesByConversation[conversationID] ?? []
        guard let liveIndex = liveTraces.firstIndex(where: { $0.id == traceID }) else { return nil }
        liveTraces[liveIndex].state = state
        let finished = liveTraces[liveIndex]
        liveDebugTracesByConversation[conversationID] = liveTraces
        if selectedConversationID == conversationID,
           let visibleIndex = debugTraces.firstIndex(where: { $0.id == traceID }) {
            debugTraces[visibleIndex].state = state
        }
        return finished
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
            liveDebugTracesByConversation[conversationID]?.removeAll { $0.id == trace.id }
        } catch {
            // 文件 Debug 是可选辅助信息；失败时保留本轮内存展示，不能中断正常问答。
        }
    }

    /// FIFO 清理最老事件/trace；普通会话与数据库永不依赖 debug trace，因此可安全释放。
    private func trimDebugTraceMemory(_ traces: inout [RAGDebugTrace]) {
        while traces.count > DebugTraceLimit.maxTraceCount {
            traces.removeFirst()
        }
        while debugPayloadByteCount(in: traces) > DebugTraceLimit.maxTotalPayloadUTF8Bytes {
            guard let traceIndex = traces.firstIndex(where: { !$0.events.isEmpty }) else { break }
            traces[traceIndex].events.removeFirst()
            if traces[traceIndex].events.isEmpty, traces.count > 1 {
                traces.remove(at: traceIndex)
            }
        }
    }

    private func debugPayloadByteCount(in traces: [RAGDebugTrace]) -> Int {
        traces.reduce(0) { traceTotal, trace in
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

    /// 标题一次性提交到列表与 SQLite。逐字动画过去每 32ms 修改全局 `conversations`
    /// 数组，会与流式 Markdown 和滚动争抢主线程；最终标题、生成时机和后台持久化语义不变。
    private func applyGeneratedConversationTitle(
        _ title: String,
        for conversationID: UUID,
        generationID: UUID
    ) async {
        guard isConversationTitleGenerationCurrent(generationID, for: conversationID) else { return }
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
            conversationPresentationCache.remove(conversationID)
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
    private func applyExecution(_ event: RAGExecutionEvent, to executionSteps: inout [RAGExecutionStep]) {
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
            updateExecutionStep(in: &executionSteps, kind: .planning) { step in
                step.details = plan.userVisiblePlan.planningNotes.isEmpty
                    ? [fallback]
                    : plan.userVisiblePlan.planningNotes
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.planning.summaryFormat"),
                    plan.userVisiblePlan.semantic
                )
                step.queryPlan = plan
                completeExecutionStep(&step)
            }

        case .reasoningDelta(let kind, let text):
            updateExecutionStep(in: &executionSteps, kind: kind) { step in
                if step.details.isEmpty {
                    step.details = [text]
                } else {
                    step.details[step.details.count - 1] += text
                }
            }

        case .reasoningCompleted(let kind):
            updateExecutionStep(in: &executionSteps, kind: kind) { step in
                // 推理流结束后取消 running 状态，时间线即自动折叠，为正式回答让出阅读空间。
                completeExecutionStep(&step)
            }

        case .retrieval(let progress):
            updateExecutionStep(in: &executionSteps, kind: .retrieval) { step in
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
            updateExecutionStep(in: &executionSteps, kind: .retrieval) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.retrieval.summaryFormat"),
                    result.bundles.count,
                    result.childHits.count
                )
                step.retrievalSnapshot = RAGRetrievalSnapshot(result: result)
                completeExecutionStep(&step)
            }

        case .remoteContextPrepared(let workItems):
            updateExecutionStep(in: &executionSteps, kind: .remoteContext) { step in
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
            updateExecutionStep(in: &executionSteps, kind: .remoteContext) { step in
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
            updateExecutionStep(in: &executionSteps, kind: .remoteContext) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.remote.progressFormat"),
                    completed,
                    total
                )
            }

        case .remoteContextCompleted(let blocks):
            updateExecutionStep(in: &executionSteps, kind: .remoteContext) { step in
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
            updateExecutionStep(in: &executionSteps, kind: .generation) { step in
                step.details = [String(
                    format: String.l10n("rag.workspace.execution.generation.startedFormat"), evidenceCount
                )]
            }

        case .generationCompleted(let citationCount):
            updateExecutionStep(in: &executionSteps, kind: .generation) { step in
                step.summary = String(
                    format: String.l10n("rag.workspace.execution.generation.summaryFormat"), citationCount
                )
                completeExecutionStep(&step)
            }

        case .terminated(let kind, let summary):
            updateExecutionStep(in: &executionSteps, kind: kind) { step in
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
    private func applyReasoningPresentation(
        kind: RAGExecutionStepKind,
        text: String,
        in executionSteps: inout [RAGExecutionStep]
    ) {
        updateExecutionStep(in: &executionSteps, kind: kind) { step in
            step.details = text.isEmpty ? [] : [text]
        }
    }

    /// Provider 在失败和取消路径上不保证发送 `reasoningCompleted`。所有退出路径都走
    /// 同一刷新逻辑，确保 UI 降频只减少重绘次数，不吞掉最后一批 Think。
    private func flushReasoningPresentations(
        planning: inout StreamingTextPresentationBuffer,
        answer: inout StreamingTextPresentationBuffer,
        executionSteps: inout [RAGExecutionStep]
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        _ = planning.flush(now: now)
        if !planning.text.isEmpty {
            applyReasoningPresentation(
                kind: .planningReasoning,
                text: planning.text,
                in: &executionSteps
            )
        }
        _ = answer.flush(now: now)
        if !answer.text.isEmpty {
            applyReasoningPresentation(
                kind: .answerReasoning,
                text: answer.text,
                in: &executionSteps
            )
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
        in executionSteps: inout [RAGExecutionStep],
        kind: RAGExecutionStepKind,
        _ update: (inout RAGExecutionStep) -> Void
    ) {
        guard let index = executionSteps.lastIndex(where: { $0.kind == kind }) else { return }
        update(&executionSteps[index])
    }

    private func finishRunningExecutionIfNeeded(
        for state: RAGAnswerState,
        in executionSteps: inout [RAGExecutionStep]
    ) {
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
        processingDuration: TimeInterval? = nil,
        generationID: UUID
    ) async throws {
        conversationPresentationCache.remove(conversationID)
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
        conversationPresentationCache.remove(conversationID)
        if canUpdateVisibleAnswer(for: conversationID, generationID: generationID),
           let detail = try await conversationStore.loadConversation(id: conversationID),
           canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
            applyLoadedConversationMessages(detail)
            // 回答完成后不自动选中引用，避免强制拉开右侧「证据」tab。
        }
        conversations = try await conversationStore.listConversations()
        if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
            streamingAnswer = ""
            streamingPresentation = nil
            executionSteps = []
            remoteBlocks = []
            attachments = []
            githubLinkContexts = []
        }
        // 附件是本轮一次性输入；后台完成后无论是否仍在看该会话，草稿都不能把已消耗附件带回来。
        dependencies.ragComposerDraftStore.update(conversationID) { draft in
            draft.attachments = []
            draft.githubLinkContexts = []
        }
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
        answerElapsedDuration = nil
        streamingAnswer = ""
        streamingPresentation = nil
        answerState = .idle
        editingUserMessageID = nil
        editingUserDraft = ""
        queryPlan = nil
        retrieval = nil
        lastContextUsage = nil
        remoteBlocks = []
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        // Composer 草稿（输入文案 / @repo / 附件 / 联网开关）由 save/restoreComposerDraft 按会话处理，
        // 这里绝不能无条件清空，否则切回原会话会丢失未发送上下文。
        errorMessage = nil
        selectedCitation = nil
        selectedCitationChunk = nil
        citationChunkPopoverCitationID = nil
    }

    /// 离开会话前把当前 Composer 写入 App 级内存草稿。空状态也要保存，避免清掉 chip 后又被旧草稿填回。
    private func saveComposerDraft(for conversationID: UUID?) {
        guard let conversationID else { return }
        dependencies.ragComposerDraftStore.save(
            RAGComposerDraftSnapshot(
                draftQuestion: draftQuestion,
                selectedRepoContexts: selectedRepoContexts,
                attachments: attachments,
                githubLinkContexts: githubLinkContexts,
                explicitRepoMode: explicitRepoMode,
                webSearchEnabled: webSearchEnabled
            ),
            for: conversationID
        )
    }

    /// 安装目标会话的 Composer；无草稿时回到空白，避免沿用上一会话的 chip。
    private func restoreComposerDraft(for conversationID: UUID) {
        let draft = dependencies.ragComposerDraftStore.draft(for: conversationID) ?? RAGComposerDraftSnapshot()
        draftQuestion = draft.draftQuestion
        selectedRepoContexts = draft.selectedRepoContexts
        attachments = draft.attachments
        githubLinkContexts = draft.githubLinkContexts
        explicitRepoMode = draft.explicitRepoMode
        webSearchEnabled = draft.webSearchEnabled
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
