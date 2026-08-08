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
import CryptoKit
import Foundation
import Observation
import SwiftUI
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
    let estimatedTextUTF8Bytes: Int

    init(
        detail: RAGConversationDetail,
        outlineTurns: [RAGConversationOutlineTurn],
        citations: [RAGCitation]
    ) {
        self.detail = detail
        self.outlineTurns = outlineTurns
        self.citations = citations
        estimatedTextUTF8Bytes = Self.estimatedTextBytes(
            detail: detail,
            outlineTurns: outlineTurns,
            citations: citations
        )
    }

    private init(
        detail: RAGConversationDetail,
        outlineTurns: [RAGConversationOutlineTurn],
        citations: [RAGCitation],
        estimatedTextUTF8Bytes: Int
    ) {
        self.detail = detail
        self.outlineTurns = outlineTurns
        self.citations = citations
        self.estimatedTextUTF8Bytes = estimatedTextUTF8Bytes
    }

    /// 完整快照不是精确的堆内存镜像，但消息正文、摘要和展示投影占据主要可变空间。
    /// 缓存用这个稳定、无额外编码分配的估算值实施总字节预算，避免为测量缓存本身再
    /// JSON encode 一遍长会话。固定大小的 UUID、数值和 enum 由消息数预算兜底。
    private static func estimatedTextBytes(
        detail: RAGConversationDetail,
        outlineTurns: [RAGConversationOutlineTurn],
        citations: [RAGCitation]
    ) -> Int {
        summaryTextBytes(detail.summary)
            + (detail.contextSummary?.content.utf8.count ?? 0)
            + messagesTextBytes(detail.messages)
            + outlineTextBytes(outlineTurns)
            + citationsTextBytes(citations)
    }

    private static func summaryTextBytes(_ summary: RAGConversationSummary) -> Int {
        summary.title.utf8.count
            + summary.createdAt.utf8.count
            + summary.updatedAt.utf8.count
            + (summary.pinnedAt?.utf8.count ?? 0)
    }

    private static func messagesTextBytes(_ messages: [RAGStoredMessage]) -> Int {
        messages.reduce(0) { partial, message in
            var total = partial
            total += message.content.utf8.count
                + (message.model?.utf8.count ?? 0)
                + message.createdAt.utf8.count
            for citation in message.citations {
                total += citation.marker.utf8.count
                    + citation.repoFullName.utf8.count
                    + citation.sectionTitle.utf8.count
                    + (citation.sourceURL?.absoluteString.utf8.count ?? 0)
                    + (citation.evidenceContent?.utf8.count ?? 0)
            }
            for audit in message.remoteContextAudits {
                total += audit.id.utf8.count
                    + audit.title.utf8.count
                    + audit.fetchedAt.utf8.count
                    + (audit.sourceURL?.absoluteString.utf8.count ?? 0)
                    + (audit.errorMessage?.utf8.count ?? 0)
            }
            for step in message.executionTrace {
                total += step.details.reduce(0) { $0 + $1.utf8.count }
                    + (step.summary?.utf8.count ?? 0)
                for audit in step.remoteAuditItems ?? [] {
                    total += audit.id.utf8.count
                        + audit.repoFullName.utf8.count
                        + audit.querySummary.utf8.count
                        + (audit.requestURL?.absoluteString.utf8.count ?? 0)
                        + (audit.errorMessage?.utf8.count ?? 0)
                        + (audit.providerName?.utf8.count ?? 0)
                    total += audit.resultPreviews.reduce(0) {
                        $0 + $1.title.utf8.count + $1.url.absoluteString.utf8.count
                            + ($1.providerName?.utf8.count ?? 0)
                    }
                }
            }
            total += message.suggestedActions.reduce(0) { $0 + $1.question.utf8.count }
            return total
        }
    }

    private static func outlineTextBytes(_ turns: [RAGConversationOutlineTurn]) -> Int {
        turns.reduce(0) {
            $0 + $1.title.utf8.count + $1.preview.utf8.count + $1.timestampISO8601.utf8.count
        }
    }

    private static func citationsTextBytes(_ citations: [RAGCitation]) -> Int {
        citations.reduce(0) {
            $0 + $1.marker.utf8.count + $1.repoFullName.utf8.count + $1.sectionTitle.utf8.count
                + ($1.sourceURL?.absoluteString.utf8.count ?? 0)
                + ($1.evidenceContent?.utf8.count ?? 0)
        }
    }

    /// 将刚提交的完整轮次追加到现有投影。只处理两条新增消息，不重新扫描长会话。
    func appending(_ turn: RAGPersistedConversationTurn, summary: RAGConversationSummary) -> Self {
        let newMessages = [turn.userMessage, turn.assistantMessage]
        guard !detail.messages.contains(where: { $0.id == turn.userMessage.id || $0.id == turn.assistantMessage.id })
        else { return self }
        let newOutline = RAGConversationOutlineBuilder.completeTurns(from: newMessages)
        var seen = Set(citations.map(\.id))
        let addedCitations = turn.assistantMessage.citations.filter { seen.insert($0.id).inserted }
        let mergedCitations = (citations + addedCitations)
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.repoFullName.localizedStandardCompare($1.repoFullName) == .orderedAscending
            }
        let updatedDetail = RAGConversationDetail(
            summary: summary,
            messages: detail.messages + newMessages,
            contextSummary: detail.contextSummary
        )
        let updatedBytes = estimatedTextUTF8Bytes
            - Self.summaryTextBytes(detail.summary)
            + Self.summaryTextBytes(summary)
            + Self.messagesTextBytes(newMessages)
            + Self.outlineTextBytes(newOutline)
            + Self.citationsTextBytes(addedCitations)
        return Self(
            detail: updatedDetail,
            outlineTurns: outlineTurns + newOutline,
            citations: mergedCitations,
            estimatedTextUTF8Bytes: updatedBytes
        )
    }
}

/// 会话正文的窗口级 LRU 快照缓存。
///
/// 容量刻意有界，且任何持久化写入都由 ViewModel 主动失效对应项，不能把缓存变成第二套
/// 数据源。线性维护访问顺序的成本受几十项容量约束，比引入链表节点更简单可靠。
struct RAGConversationPresentationCache {
    private let capacity: Int
    private let maxMessageCount: Int
    private let maxEstimatedTextBytes: Int
    private var snapshotsByID: [UUID: RAGConversationPresentationSnapshot] = [:]
    /// 最旧在前、最近使用在后。
    private var recency: [UUID] = []
    private(set) var messageCount = 0
    private(set) var estimatedTextBytes = 0

    init(
        capacity: Int = 24,
        maxMessageCount: Int = 600,
        maxEstimatedTextBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.capacity = max(1, capacity)
        self.maxMessageCount = max(0, maxMessageCount)
        self.maxEstimatedTextBytes = max(0, maxEstimatedTextBytes)
    }

    var count: Int { snapshotsByID.count }

    mutating func value(for conversationID: UUID) -> RAGConversationPresentationSnapshot? {
        guard let snapshot = snapshotsByID[conversationID] else { return nil }
        touch(conversationID)
        return snapshot
    }

    /// 用户主动访问的快照按 LRU 腾出空间。单个超预算长会话仍会正常安装到工作台，
    /// 但不进入预取缓存，避免一个异常会话突破整个缓存上界。
    @discardableResult
    mutating func insert(_ snapshot: RAGConversationPresentationSnapshot) -> Bool {
        let conversationID = snapshot.detail.summary.id
        removeSnapshot(conversationID)
        let snapshotMessages = snapshot.detail.messages.count
        let snapshotBytes = snapshot.estimatedTextUTF8Bytes
        guard snapshotMessages <= maxMessageCount,
              snapshotBytes <= maxEstimatedTextBytes else { return false }
        snapshotsByID[conversationID] = snapshot
        messageCount += snapshotMessages
        estimatedTextBytes += snapshotBytes
        touch(conversationID)
        trimToBudget()
        return snapshotsByID[conversationID] != nil
    }

    /// 后台预取不得驱逐用户已经访问过的快照，也不能为了探测后续会话而持续制造 I/O。
    /// 返回 false 时调用方应停止本轮预取。
    @discardableResult
    mutating func insertPrefetched(_ snapshot: RAGConversationPresentationSnapshot) -> Bool {
        let conversationID = snapshot.detail.summary.id
        if snapshotsByID[conversationID] != nil { return true }
        let snapshotMessages = snapshot.detail.messages.count
        let snapshotBytes = snapshot.estimatedTextUTF8Bytes
        guard snapshotsByID.count < capacity,
              messageCount + snapshotMessages <= maxMessageCount,
              estimatedTextBytes + snapshotBytes <= maxEstimatedTextBytes else { return false }
        snapshotsByID[conversationID] = snapshot
        messageCount += snapshotMessages
        estimatedTextBytes += snapshotBytes
        touch(conversationID)
        return true
    }

    private mutating func trimToBudget() {
        while snapshotsByID.count > capacity
            || messageCount > maxMessageCount
            || estimatedTextBytes > maxEstimatedTextBytes {
            guard let oldest = recency.first else { break }
            removeSnapshot(oldest)
        }
    }

    mutating func remove(_ conversationID: UUID) {
        removeSnapshot(conversationID)
    }

    mutating func removeAll() {
        snapshotsByID.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        messageCount = 0
        estimatedTextBytes = 0
    }

    private mutating func touch(_ conversationID: UUID) {
        recency.removeAll { $0 == conversationID }
        recency.append(conversationID)
    }

    private mutating func removeSnapshot(_ conversationID: UUID) {
        if let removed = snapshotsByID.removeValue(forKey: conversationID) {
            messageCount -= removed.detail.messages.count
            estimatedTextBytes -= removed.estimatedTextUTF8Bytes
        }
        recency.removeAll { $0 == conversationID }
    }
}

/// 切换会话或关闭 RAG 工作台时暂存的 Composer 草稿。
///
/// 只活在 App 进程内存里：未发送的 `@repo` / 附件 / 输入文案 / 联网与深度思考开关在工作台关闭重开后仍可恢复，
/// 但不能写成第二套持久化真源；App 退出或切换用户库后丢弃。
struct RAGComposerDraftSnapshot: Equatable {
    var draftQuestion: String = ""
    var selectedRepoContexts: [Repo] = []
    var attachments: [RAGComposerAttachment] = []
    var githubLinkContexts: [RAGGitHubLinkReference] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var webSearchEnabled = false
    var deepThinkingEnabled = false
    /// 上下文面板排序；只影响面板候选，不改主窗口列表。
    var mentionSortOption: RepoSortOption = RAGComposerMentionSort.default
    /// 上下文面板筛选；不含知识库分组。
    var mentionFilters: RAGComposerMentionFilters = .empty
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

/// 一轮回答在所属会话上的完整展示运行态。它只承载可恢复到工作台的值，不持有 generation、
/// 计时 Task 或授权 actor；后几者有独立取消生命周期，混入会让值快照承担资源所有权。
struct RAGConversationRuntimeState {
    var answerState: RAGAnswerState = .idle
    var userMessage: RAGStoredMessage?
    var streamingAnswer = ""
    var streamingPresentation: StreamingMarkdownSnapshot?
    var queryPlan: RAGQueryPlan?
    var retrieval: RAGRetrievalResult?
    var contextUsage: RAGContextUsage?
    /// 当前轮实际进入 Prompt 的洞察 XML；与 RepoContext 一样只保存在运行态内存。
    var repositoryInsightsDocuments: [RAGRepositoryInsightsDocument] = []
    /// XML 只属于当前运行态，不进入 SQLite；历史会话通过 execution snapshot 校验磁盘缓存后重建。
    var repoContextDocument: RAGRepoContextDocument?
    var remoteBlocks: [RAGRemoteContextBlock] = []
    var executionSteps: [RAGExecutionStep] = []
    var elapsedDuration: TimeInterval?
}

@MainActor
@Observable
final class KnowledgeRAGWorkspaceViewModel {
    /// 小库一次缓存轻量投影；超过阈值后改为按 `@token` 查询首屏，避免启动期线性驻留。
    private static let mentionCatalogThreshold = 500
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
    /// 正文引用弹层关闭或切换后，迟到的分片读取不能写入下一次打开的弹层。
    private let citationChunkPopoverGate = RAGLatestRequestGate()
    /// 最近会话的完整持久化展示快照。缓存不参与 Observation，写入后由本类显式失效。
    @ObservationIgnored private var conversationPresentationCache = RAGConversationPresentationCache()
    /// 工作台稳定后低优先级预热最近会话；关窗/切库必须取消，避免继续读取旧数据库。
    @ObservationIgnored private var conversationPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var remoteContextConsent: RAGRemoteContextConsent?
    /// 联网确认也属于原会话。任务在后台走到确认点后，用户切回该会话仍可继续批准或跳过。
    @ObservationIgnored private var remoteContextConsents: [UUID: RAGRemoteContextConsent] = [:]
    @ObservationIgnored private var pendingRemoteWorkItemsByConversation: [UUID: [RAGResolvedRemoteWorkItem]] = [:]
    @ObservationIgnored private var approvedRemoteWorkItemIDsByConversation: [UUID: Set<String>] = [:]
    /// 后台回答的展示值必须同进同退；单一字典避免新增字段时漏掉 restore/clear 其中一端。
    @ObservationIgnored private var conversationRuntimeStates: [UUID: RAGConversationRuntimeState] = [:]
    /// 运行中的 Debug Trace 按会话隔离；切换后事件仍写原会话，并在切回时与磁盘历史合并。
    @ObservationIgnored private var liveDebugTracesByConversation: [UUID: [RAGDebugTrace]] = [:]
    @ObservationIgnored private var linkDetectionTask: Task<Void, Never>?
    /// 历史 XML 读取必须跟随会话选择取消；commit/hash 不匹配时保持 nil，绝不展示后来版本。
    @ObservationIgnored private var repoContextHistoryLoadTask: Task<Void, Never>?
    /// 洞察历史同样只在 hash 全匹配时恢复；删除或更新 Artifact 后保持空正文。
    @ObservationIgnored private var repositoryInsightsHistoryLoadTask: Task<Void, Never>?

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
    /// 才能在历史消息真正拥有新内容后定位尾部。
    private(set) var loadedMessageSequence = 0
    /// 只在“点开并安装历史会话”时递增。回答落库刷新不会改它，Answer Surface 因而
    /// 能把历史首屏重置为 2 轮，同时保留当前会话已经展开的轮次。
    private(set) var conversationHistoryInstallSequence = 0
    var draftQuestion = ""
    var streamingAnswer = ""
    /// 流式阶段只提交稳定 Markdown chunk 与未闭合尾部，避免每个 delta 重解析完整回答。
    var streamingPresentation: StreamingMarkdownSnapshot?
    var answerState: RAGAnswerState = .idle
    /// 运行中由消息头的局部时钟推进，终态冻结为最后一个 LLM 响应结束时的真实耗时。
    var answerElapsedDuration: TimeInterval?
    /// 只暴露当前会话的起点，让读秒在标签局部刷新，不因 Provider 无 delta 而停顿。
    var answerStartedAt: Date? {
        guard let selectedConversationID else { return nil }
        return answerStartedAtByConversation[selectedConversationID]
    }
    /// 用户气泡原地编辑：非 nil 时该消息进入图 4 编辑态。
    var editingUserMessageID: UUID?
    var editingUserDraft = ""
    var queryPlan: RAGQueryPlan?
    var retrieval: RAGRetrievalResult?
    /// 当前轮最终进入 Prompt 的洞察 XML 投影；历史会话稍后通过审计 hash 按需回放。
    private(set) var repositoryInsightsDocuments: [RAGRepositoryInsightsDocument] = []
    /// 当前轮实际进入 Prompt 的 XML 投影；只保存在内存，供引用详情作为独立证据展示。
    private(set) var repoContextDocument: RAGRepoContextDocument?
    /// 当前轮默认可见的执行轨迹；完成后随 assistant message 持久化，Debug payload 不进入这里。
    var executionSteps: [RAGExecutionStep] = []
    var remoteBlocks: [RAGRemoteContextBlock] = []
    var pendingRemoteWorkItems: [RAGResolvedRemoteWorkItem] = []
    var approvedRemoteWorkItemIDs: Set<String> = []
    var selectedCitation: RAGCitation?
    var selectedCitationChunk: RAGChunk?
    /// 底部引用芯片（及证据列表点选）主动聚焦时递增；同 id 再点也会变，驱动右侧切回「引用」tab。
    /// 正文蓝色 S1 只弹窗，不 bump 本序列。
    private(set) var citationFocusSequence: Int = 0
    /// 正文蓝色 S1 的「命中的分片」popover；nil 表示关闭。底部芯片不打开此弹层。
    private(set) var citationChunkPopoverCitationID: UUID?
    var selectedRepoContexts: [Repo] = [] {
        didSet {
            // RepoContext 只能绑定唯一明确项目。用户把范围扩成多项目或清空时立即关掉，
            // 不能只在发送瞬间静默忽略，否则蓝色开关会给出错误授权反馈。
            if !Self.canEnableDeepThinking(repoCount: selectedRepoContexts.count), deepThinkingEnabled {
                deepThinkingEnabled = false
            }
        }
    }
    /// 明确上下文仓库上限（见 `RAGMentionPickerLogic.maxSelectedRepoContexts`）。
    static var maxSelectedRepoContexts: Int { RAGMentionPickerLogic.maxSelectedRepoContexts }
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var attachments: [RAGComposerAttachment] = []
    var githubLinkContexts: [RAGGitHubLinkReference] = []
    /// 用户在 Composer 主动授权本轮联网。按会话暂存，连续追问无需重复开启；关闭后
    /// Planner 产生的普通 Web 请求会在执行层被清除，GitHub 实时请求仍需逐项确认。
    var webSearchEnabled = false
    /// 与联网开关同属按会话 Composer 草稿；附件数量不参与可用性判断。
    var deepThinkingEnabled = false
    var canEnableDeepThinking: Bool {
        Self.canEnableDeepThinking(repoCount: selectedRepoContexts.count)
    }

    /// 单项目门禁只看显式项目数量。保持纯函数后，草稿恢复和 UI 状态可以共享并直接回归，
    /// 不会误把附件数量、联网状态或当前输入内容混入授权判断。
    nonisolated static func canEnableDeepThinking(repoCount: Int) -> Bool {
        repoCount == 1
    }
    /// 切换模型时立刻写入 AppSettings，关闭窗口后再开可恢复。
    var selectedModelID: String? {
        didSet {
            let trimmed = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if dependencies.settings.ragWorkspaceSelectedModelID != trimmed {
                dependencies.settings.ragWorkspaceSelectedModelID = trimmed
            }
        }
    }
    /// 仓库上下文面板由 + 或独立的 `@` 触发；搜索词不再混入用户问题。
    var isContextPickerPresented = false
    /// 面板内筛选浮层是否打开；Esc 分层关闭时优先收起它，而不是整块面板。
    var isContextPickerFilterPresented = false
    /// 筛选内「新增语言」popover 是否打开。
    var isContextPickerLanguageAddPresented = false
    var contextPickerQuery = ""
    /// 面板排序；与联网开关/已选 repo 同级写入 Composer 草稿。
    var mentionSortOption: RepoSortOption = RAGComposerMentionSort.default {
        didSet {
            guard oldValue != mentionSortOption, !isRestoringComposerDraft else { return }
            saveComposerDraft(for: selectedConversationID)
            schedulePagedMentionQueryIfNeeded(force: true)
        }
    }
    /// 面板筛选；语言名单复用 `AppSettings.interestedLanguages`，勾选结果进草稿。
    var mentionFilters: RAGComposerMentionFilters = .empty {
        didSet {
            guard oldValue != mentionFilters, !isRestoringComposerDraft else { return }
            saveComposerDraft(for: selectedConversationID)
            schedulePagedMentionQueryIfNeeded(force: true)
        }
    }
    /// 恢复草稿时跳过 sort/filter 的 didSet，避免尚未装完会话就触发 SQL。
    private var isRestoringComposerDraft = false
    private var highlightedMentionRepoID: Int64?
    private var mentionCandidates: [RAGMentionCandidate] = []
    /// 小型知识库平时在内存筛选；输入关键词后也必须改走 SQL，才能覆盖笔记与 AI 摘要。
    private var baseMentionCandidates: [RAGMentionCandidate] = []
    /// 大库分页时不会常驻全部候选，但索引问题抽屉仍需要稳定显示仓库名。
    /// 这里只缓存轻量名称，不把完整 Repo 重新带回内存，避免抵消分页收益。
    private var mentionRepositoryNames: [Int64: String] = [:]
    private var mentionKnowledgeCount = 0
    private var mentionUsesPagedQuery = false
    private var loadedMentionQuery = ""
    private var loadedMentionMatchCount = 0
    private var loadedMentionHasMore = false
    private var mentionQueryTask: Task<Void, Never>?
    /// 只共享纯值读模型；工作台自己的问题抽屉、重建任务和进度状态仍留在本 ViewModel。
    var indexStatus = RAGIndexStatusProjection.empty
    /// `.empty` 也是初始占位值，不能在 coverage 首次读取完成前把“未知”误判为真实空库。
    private(set) var hasLoadedIndexCoverage = false
    /// Inspector 常显的本地知识库事实。回答流会用实际注入 Prompt 的快照覆盖它，避免面板与
    /// 当前轮模型看到的数据不一致；工作台初次打开时则主动读取一次，使用户无需先提问也能核验。
    var knowledgeBaseMetadataSnapshot: KnowledgeBaseMetadataSnapshot?
    /// RAG 工作台内「从 Stars 加入知识库」Sheet；空库空态 / 左栏 / 失败态共用。
    var isAddToLibraryPresented = false
    /// 标题编辑 sheet 必须挂在工作台根视图上；挂在窄侧栏会被系统压成接近 alert 的宽度。
    var titleEditRequest: RAGWorkspaceTitleEditRequest?
    var titleEditDraft = ""

    /// 知识库尚无任何仓库时，问答没有可检索边界。
    var isKnowledgeBaseEmpty: Bool {
        Self.resolveKnowledgeBaseEmptyState(
            indexStatus: indexStatus,
            hasLoadedIndexCoverage: hasLoadedIndexCoverage
        )
    }

    /// coverage 加载前的 `.empty` 只是占位值；入口路由必须把“未知”和“真实空库”分开。
    nonisolated static func resolveKnowledgeBaseEmptyState(
        indexStatus: RAGIndexStatusProjection,
        hasLoadedIndexCoverage: Bool
    ) -> Bool {
        hasLoadedIndexCoverage && indexStatus.isKnowledgeBaseEmpty
    }
    var indexIssueChunks: [RAGIndexIssueKind: [RAGChunk]] = [:]
    var indexIssueHasMore: Set<RAGIndexIssueKind> = []
    var loadingIndexIssueKinds: Set<RAGIndexIssueKind> = []
    var isIndexing = false
    /// 直接透出 builder 的状态，让工作台显示真实构建阶段与数字进度。
    var indexingStatus: RAGIndexingStatus { dependencies.knowledgeRAGIndexBuilder.status }
    /// 手动刷新结果在阶段切换后保持不变，供工作台连续展示 README 与分片进度。
    var indexRefreshSummary: RAGIndexRefreshSummary? { dependencies.knowledgeRAGIndexBuilder.refreshSummary }
    var embeddingModel: String { dependencies.settings.aiEmbeddingTask.resolvedModelName }
    var configuredEmbeddingModelName: String? { dependencies.settings.configuredEmbeddingModelName }
    var embeddingConfigurationIssue: AIEmbeddingError? { dependencies.settings.embeddingConfigurationIssue }
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

    /// 当前运行轮优先；历史回放从最后一条 assistant 的脱敏 execution trace 读取。
    var displayedRepoContextSnapshot: RAGRepoContextSnapshot? {
        if queryPlan != nil || messages.last?.role == .user {
            return repoContextDocument?.snapshot
                ?? executionSteps.reversed().first(where: { $0.repoContextSnapshot != nil })?.repoContextSnapshot
        }
        return latestHistoricalExecutionTrace?.reversed()
            .first(where: { $0.repoContextSnapshot != nil })?.repoContextSnapshot
    }

    /// 当前轮优先使用最终投影文档；历史轮只读取持久化的审计快照。
    var displayedRepositoryInsightsSnapshots: [RAGRepositoryInsightsSnapshot] {
        if queryPlan != nil || messages.last?.role == .user {
            if !repositoryInsightsDocuments.isEmpty {
                return repositoryInsightsDocuments.map(\.snapshot)
            }
            return executionSteps.reversed()
                .first(where: { $0.repositoryInsightsSnapshots != nil })?
                .repositoryInsightsSnapshots ?? []
        }
        return latestHistoricalExecutionTrace?.reversed()
            .first(where: { $0.repositoryInsightsSnapshots != nil })?
            .repositoryInsightsSnapshots ?? []
    }

    func repositoryInsightsDocument(for citation: RAGCitation) -> RAGRepositoryInsightsDocument? {
        guard let repoID = citation.repoID else { return nil }
        return repositoryInsightsDocuments.first {
            $0.snapshot.repoID == repoID
                && $0.snapshot.repoFullName == citation.repoFullName
        }
    }

    func repositoryInsightsSnapshot(for citation: RAGCitation) -> RAGRepositoryInsightsSnapshot? {
        guard let repoID = citation.repoID else { return nil }
        return displayedRepositoryInsightsSnapshots.first {
            $0.repoID == repoID && $0.repoFullName == citation.repoFullName
        }
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

    /// 当前上下文面板的候选快照：已选置顶、关键词过滤、截断元数据。
    var mentionPickerSnapshot: RAGMentionPickerSnapshot {
        if mentionUsesPagedQuery || !contextPickerQuery.isEmpty {
            guard contextPickerQuery == loadedMentionQuery else {
                return RAGMentionPickerSnapshot(
                    suggestions: selectedRepoContexts.map(RAGMentionCandidate.init(repo:)),
                    matchCount: 0,
                    knowledgeCount: mentionKnowledgeCount,
                    selectedCount: selectedRepoContexts.count,
                    displayedCount: selectedRepoContexts.count,
                    isTruncated: false
                )
            }
            return RAGMentionPickerLogic.build(
                candidates: mentionCandidates,
                selected: selectedRepoContexts,
                query: "",
                knowledgeCount: mentionKnowledgeCount,
                knownMatchCount: loadedMentionMatchCount,
                pageHasMore: loadedMentionHasMore
            )
        }
        return RAGMentionPickerLogic.build(
            candidates: mentionCandidates,
            selected: selectedRepoContexts,
            query: contextPickerQuery,
            knowledgeCount: mentionKnowledgeCount
        )
    }

    var mentionSuggestions: [RAGMentionCandidate] {
        mentionPickerSnapshot.suggestions
    }

    func isMentionSelected(_ candidate: RAGMentionCandidate) -> Bool {
        selectedRepoContexts.contains { $0.id == candidate.id }
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
            async let loadedMentions = dependencies.ragCandidateRepository.fetchMentionCandidates(
                query: "",
                limit: Self.mentionCatalogThreshold + 1,
                offset: 0,
                sort: mentionSortOption,
                filters: mentionFilters
            )
            conversations = try await loadedConversations
            conversationGroups = try await loadedGroups
            applyInitialMentionPage(try await loadedMentions)
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
                let page = try await dependencies.ragCandidateRepository.fetchMentionCandidates(
                    query: "",
                    limit: Self.mentionCatalogThreshold + 1,
                    offset: 0,
                    sort: mentionSortOption,
                    filters: mentionFilters
                )
                applyInitialMentionPage(page)
                let currentRepoIDs = Set(try await dependencies.ragCandidateRepository
                    .fetchMentionRepos(ids: selectedRepoContexts.map(\.id)).map(\.id))
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
            dismissMentionPicker()
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

    /// 切换会话时骨架至少亮这么久，缓存命中也能看到 shimmer；读库更慢时不再额外拖延。
    nonisolated private static let conversationSwitchSkeletonMinimum: Duration = .milliseconds(320)

    func selectConversation(_ id: UUID) async {
        guard selectedConversationID != id || messages.isEmpty || isConversationLoading else { return }
        let previousConversationID = selectedConversationID
        let requestGeneration = conversationSelectionGate.begin()
        let isSwitchingConversation = previousConversationID != id
        let skeletonStartedAt = ContinuousClock.now

        // 离开前写入 App 级内存草稿。回答态已有 *ByConversation；Composer 也必须按会话隔离，
        // 否则 resetTurnState 会把另一会话刚选的项目/附件清掉且无法恢复。
        if isSwitchingConversation {
            saveComposerDraft(for: previousConversationID)
            // 上下文选择面板按当前会话 Composer 工作；切走会话时必须收起，避免浮在另一会话上。
            dismissMentionPicker()
            // 立刻进骨架：清掉上一会话正文。缓存命中也不能跳过——否则重装大消息树时中栏会假死无反馈。
            isConversationLoading = true
            messages = []
            conversationContextSummary = nil
            conversationOutlineTurns = []
            conversationCitations = []
            resetTurnState()
        }

        // 选择意图必须在第一次 await 之前提交：左栏立即响应，旧会话之后的流式事件也会
        // 因 selectedConversationID 已变化而停止投影到当前中栏。
        selectedConversationID = id
        selectedGroupID = nil
        debugTraces = []

        if isSwitchingConversation {
            // 让 SwiftUI 先画出一帧骨架，再装缓存或读库；否则同帧 loading→安装会看不见骨架。
            await Task.yield()
            guard conversationSelectionGate.isCurrent(requestGeneration) else { return }
        }

        if let cached = conversationPresentationCache.value(for: id) {
            if isSwitchingConversation {
                await Self.waitForMinimumConversationSkeleton(from: skeletonStartedAt)
                guard conversationSelectionGate.isCurrent(requestGeneration) else { return }
            }
            installSelectedConversation(cached)
            scheduleDebugTraceLoad(for: id)
            return
        }

        if !isConversationLoading {
            isConversationLoading = true
            messages = []
            conversationContextSummary = nil
            conversationOutlineTurns = []
            conversationCitations = []
            resetTurnState()
        }
        // Composer 可先恢复；运行中的回答态等 install 时再叠，避免加载期消息区被瞬时态干扰。
        restoreComposerDraft(for: id)
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
            if isSwitchingConversation {
                await Self.waitForMinimumConversationSkeleton(from: skeletonStartedAt)
                guard conversationSelectionGate.isCurrent(requestGeneration) else { return }
            }
            installSelectedConversation(snapshot)
            scheduleDebugTraceLoad(for: id)
            // 切换会话不自动聚焦引用：用户停留在当前 Inspector tab，手动点芯片/正文 marker 再切「证据」。
        } catch {
            guard !Task.isCancelled, conversationSelectionGate.isCurrent(requestGeneration) else { return }
            restorePreviousConversationAfterSelectionFailure(previousConversationID)
            errorMessage = error.localizedDescription
        }
    }

    /// 读库已超过最短时间则立刻返回；仅缓存命中过快时补足，让骨架 shimmer 跑起来。
    private nonisolated static func waitForMinimumConversationSkeleton(
        from startedAt: ContinuousClock.Instant
    ) async {
        let elapsed = ContinuousClock.now - startedAt
        guard elapsed < conversationSwitchSkeletonMinimum else { return }
        try? await Task.sleep(for: conversationSwitchSkeletonMinimum - elapsed)
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
        conversationHistoryInstallSequence &+= 1
        resetTurnState()
        restoreComposerDraft(for: detail.summary.id)
        restoreActiveAnswerPresentation(for: detail.summary.id)
        scheduleHistoricalRepositoryInsightsLoad(for: detail.summary.id)
        scheduleHistoricalRepoContextLoad(for: detail.summary.id)
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
        let runtime = conversationRuntimeStates[conversationID] ?? RAGConversationRuntimeState()
        if let activeUserMessage = runtime.userMessage,
           !messages.contains(where: { $0.id == activeUserMessage.id }) {
            messages.append(activeUserMessage)
        }
        answerState = runtime.answerState
        answerElapsedDuration = runtime.elapsedDuration
        streamingAnswer = runtime.streamingAnswer
        streamingPresentation = runtime.streamingPresentation
        queryPlan = runtime.queryPlan
        retrieval = runtime.retrieval
        lastContextUsage = runtime.contextUsage
        repositoryInsightsDocuments = runtime.repositoryInsightsDocuments
        repoContextDocument = runtime.repoContextDocument
        remoteBlocks = runtime.remoteBlocks
        executionSteps = runtime.executionSteps
        restoreRemoteContextState(for: conversationID)
    }

    /// 历史消息只持久化洞察 hash/token 快照。这里逐仓库读取可删除的 Artifact，并通过
    /// repo/source/xml 三重身份校验恢复当时投影；更新或删除后保持只展示审计字段。
    private func scheduleHistoricalRepositoryInsightsLoad(for conversationID: UUID) {
        repositoryInsightsHistoryLoadTask?.cancel()
        guard conversationRuntimeStates[conversationID]?.repositoryInsightsDocuments.isEmpty ?? true else {
            return
        }
        let snapshots = displayedRepositoryInsightsSnapshots.filter {
            $0.outcome == .success && $0.sentTokens > 0
        }
        guard !snapshots.isEmpty else { return }

        repositoryInsightsHistoryLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled, selectedConversationID == conversationID else { return }
            var restoredDocuments: [RAGRepositoryInsightsDocument] = []
            for snapshot in snapshots {
                guard !Task.isCancelled, selectedConversationID == conversationID else { return }
                let nameParts = snapshot.repoFullName
                    .split(separator: "/", maxSplits: 1)
                    .map(String.init)
                guard nameParts.count == 2 else { continue }
                var repo = Repo.makeMinimal(owner: nameParts[0], name: nameParts[1])
                repo.id = snapshot.repoID
                guard let artifact = await dependencies.repositoryInsightsContextCoordinator
                    .loadArtifact(for: repo),
                      let restored = RAGRepositoryInsightsHistoryRestorer.restore(
                          snapshot: snapshot,
                          artifact: artifact
                      )
                else {
                    continue
                }
                restoredDocuments.append(restored)
            }
            guard !Task.isCancelled, selectedConversationID == conversationID else { return }
            updateRuntimeState(for: conversationID) {
                $0.repositoryInsightsDocuments = restoredDocuments
            }
            repositoryInsightsDocuments = restoredDocuments
        }
    }

    /// 历史消息只持久化 RepoContext 的 commit/hash/token 快照。这里从共享缓存读取 XML，
    /// 先核验“同一 commit + 同一原文 hash”，再按当时 sentTokens 重建投影；任何一项不符
    /// 都保持只展示审计元数据，避免把后来生成的新代码上下文冒充旧回答证据。
    private func scheduleHistoricalRepoContextLoad(for conversationID: UUID) {
        repoContextHistoryLoadTask?.cancel()
        guard conversationRuntimeStates[conversationID]?.repoContextDocument == nil,
              let snapshot = displayedRepoContextSnapshot,
              snapshot.outcome == .success,
              snapshot.sentTokens > 0,
              let expectedCommitSHA = snapshot.commitSHA,
              let expectedHash = snapshot.contentHash else {
            return
        }
        let nameParts = snapshot.repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard nameParts.count == 2 else { return }

        repoContextHistoryLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled, selectedConversationID == conversationID else { return }
            let storage = RepoContextStorage.shared
            guard let stored = try? storage.existingProject(owner: nameParts[0], repo: nameParts[1]),
                  stored.metadata.commitSha == expectedCommitSHA,
                  let xml = try? storage.loadContextXml(owner: nameParts[0], repo: nameParts[1]) else { return }
            let actualHash = SHA256.hash(data: Data(xml.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualHash == expectedHash,
                  let projection = try? RAGRepoContextXMLProjector().project(
                    xml,
                    tokenBudget: snapshot.sentTokens
                  ),
                  !Task.isCancelled,
                  selectedConversationID == conversationID else { return }
            var restoredSnapshot = snapshot
            restoredSnapshot.originalTokens = projection.originalTokens
            restoredSnapshot.sentTokens = projection.projectedTokens
            restoredSnapshot.wasProjected = projection.wasProjected
            restoredSnapshot.projectionReason = projection.reason
            repoContextDocument = RAGRepoContextDocument(
                snapshot: restoredSnapshot,
                xml: projection.xml
            )
        }
    }

    /// Swift Dictionary 的 value 是值类型；集中 read-modify-write 才能保证同一会话的字段
    /// 一起更新，并让调用点不再自行创建十余个平行字典。
    private func updateRuntimeState(
        for conversationID: UUID,
        _ update: (inout RAGConversationRuntimeState) -> Void
    ) {
        var runtime = conversationRuntimeStates[conversationID] ?? RAGConversationRuntimeState()
        update(&runtime)
        conversationRuntimeStates[conversationID] = runtime
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
                    if answerGenerations[id] == nil,
                       !conversationPresentationCache.insertPrefetched(snapshot) {
                        // 已达到消息数或文本字节预算；继续读取只会制造启动 I/O，且无法缓存。
                        return
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

    /// 打开会话重命名 sheet（由根视图呈现，避免窄侧栏压宽度）。
    func presentRenameConversation(_ conversation: RAGConversationSummary) {
        titleEditDraft = conversation.title
        titleEditRequest = .renameConversation(conversation.id)
    }

    /// 打开分组重命名 sheet。
    func presentRenameGroup(_ group: RAGConversationGroup) {
        titleEditDraft = group.title
        titleEditRequest = .renameGroup(group.id)
    }

    /// 打开新建分组 sheet。
    func presentCreateGroup() {
        titleEditDraft = String.l10n("rag.workspace.group.newTitle")
        titleEditRequest = .createGroup
    }

    func dismissTitleEdit() {
        titleEditRequest = nil
        titleEditDraft = ""
    }

    /// 确认标题编辑：先关 sheet，再落库，避免确认瞬间输入框跟着闪一下。
    func confirmTitleEdit() async {
        let draft = titleEditDraft
        guard let request = titleEditRequest else { return }
        titleEditRequest = nil
        titleEditDraft = ""
        switch request {
        case .renameConversation(let conversationID):
            await renameConversation(id: conversationID, title: draft)
        case .renameGroup(let groupID):
            await renameGroup(id: groupID, title: draft)
        case .createGroup:
            await createGroup(title: draft)
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
        // 乐观更新：先改内存列表，避免系统拖拽预览尚未卸完时源行还停在旧位置造成残影。
        let previousGroupID = conversations.first(where: { $0.id == id })?.groupID
        applyConversationGroupLocally(id: id, groupID: groupID, animated: false)

        do {
            try await conversationStore.setConversationGroup(id: id, groupID: groupID)
            conversationPresentationCache.remove(id)
        } catch {
            // 写库失败：回滚到拖拽前分组。
            applyConversationGroupLocally(id: id, groupID: previousGroupID, animated: false)
            if conversations.contains(where: { $0.id == id }) == false {
                conversations = (try? await conversationStore.listConversations()) ?? conversations
            }
            errorMessage = error.localizedDescription
        }
    }

    /// 仅更新内存中的 `groupID`；拖拽落点必须关动画，防止与系统 lift preview 叠影。
    private func applyConversationGroupLocally(id: UUID, groupID: UUID?, animated: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            conversations[index].groupID = groupID
            conversationPresentationCache.remove(id)
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
        // 发送后问题区需要让出空间给回答流；已选仓库仍保留在 chip，只收起选择面板。
        dismissMentionPicker()
        // 发送当下立刻清输入框并同步草稿，避免 Task 调度前切走仍把同一段问题存回草稿。
        draftQuestion = ""
        dependencies.ragComposerDraftStore.update(conversationID) { draft in
            draft.draftQuestion = ""
        }
        startAnswerTiming(for: conversationID)
        updateRuntimeState(for: conversationID) { $0.answerState = .planning }
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
        conversationRuntimeStates.removeAll()
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

    /// 错误 Alert 的动作只改变当前工作台状态，不做任何隐式网络重试或数据删除。
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
        updateRuntimeState(for: conversationID) { $0.answerState = .planning }
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
        updateRuntimeState(for: conversationID) { $0.elapsedDuration = 0 }
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
                // 后台会话仍每秒保存恢复快照；当前消息头由局部 TimelineView
                // 刷新，避免为一个读秒使整个流式回答树重算。
                self.updateRuntimeState(for: conversationID) { $0.elapsedDuration = duration }
            }
        }
    }

    /// 最后一个 LLM 事件结束时冻结耗时；后续本地落库不能被误算进用户等待时间。
    @discardableResult
    private func finishAnswerTiming(for conversationID: UUID) -> TimeInterval {
        answerTimingTasks.removeValue(forKey: conversationID)?.cancel()
        guard let startedAt = answerStartedAtByConversation.removeValue(forKey: conversationID) else {
            return conversationRuntimeStates[conversationID]?.elapsedDuration ?? 0
        }
        let duration = max(0, Date().timeIntervalSince(startedAt))
        updateRuntimeState(for: conversationID) { $0.elapsedDuration = duration }
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
        updateRuntimeState(for: conversationID) { $0.executionSteps = steps }
        if selectedConversationID == conversationID {
            executionSteps = steps
        }
    }

    private func updateAnswerState(_ state: RAGAnswerState, for conversationID: UUID) {
        if conversationRuntimeStates[conversationID]?.answerState != state {
            updateRuntimeState(for: conversationID) { $0.answerState = state }
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
        conversationRuntimeStates[conversationID] = nil
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
                deepThinkingEnabled: deepThinkingEnabled && canEnableDeepThinking,
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let repos = try await dependencies.ragCandidateRepository.fetchMentionRepos(ids: action.repoIDs)
                guard repos.count == action.repoIDs.count else {
                    errorMessage = String.l10n("rag.workspace.guidance.repoUnavailable")
                    return
                }
                guard !isAnswering else { return }
                // 建议问题可能带出旧的大范围选择；统一钳制到上限，避免绕过手动多选保护。
                selectedRepoContexts = Array(repos.prefix(Self.maxSelectedRepoContexts))
                explicitRepoMode = action.explicitRepoMode
                attachments = []
                githubLinkContexts = []
                pendingRemoteWorkItems = []
                approvedRemoteWorkItemIDs = []
                draftQuestion = action.question
                send()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 切换上下文仓库：面板保持打开，方便连续多选；已达上限时只能取消勾选。
    func toggleMention(_ candidate: RAGMentionCandidate) {
        if let index = selectedRepoContexts.firstIndex(where: { $0.id == candidate.id }) {
            selectedRepoContexts.remove(at: index)
        } else {
            guard selectedRepoContexts.count < Self.maxSelectedRepoContexts else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard selectedRepoContexts.count < Self.maxSelectedRepoContexts,
                          let repo = try await dependencies.ragCandidateRepository
                        .fetchMentionRepos(ids: [candidate.id]).first,
                          !selectedRepoContexts.contains(where: { $0.id == repo.id }) else { return }
                    selectedRepoContexts.append(repo)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        highlightedMentionRepoID = candidate.id
    }

    /// 清空全部已选仓库 chip；不影响面板内的搜索词。
    func clearSelectedMentions() {
        selectedRepoContexts = []
        highlightedMentionRepoID = mentionSuggestions.first?.id
    }

    func clearMentionFilter() {
        contextPickerQuery = ""
        highlightedMentionRepoID = nil
        schedulePagedMentionQueryIfNeeded(force: true)
    }

    func handleContextPickerQueryChanged() {
        highlightedMentionRepoID = nil
        schedulePagedMentionQueryIfNeeded()
    }

    /// 面板的键盘导航仅移动高亮，Enter 才切换明确的 repo context。
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

    /// 关闭上下文面板；已勾选的 chip 与用户问题均保留。
    func dismissMentionPicker() {
        isContextPickerLanguageAddPresented = false
        isContextPickerFilterPresented = false
        isContextPickerPresented = false
        highlightedMentionRepoID = nil
    }

    /// Esc 分层：语言添加 → 筛选浮层 → 整块上下文面板。返回是否已消费该按键。
    @discardableResult
    func handleContextPickerEscape() -> Bool {
        guard isContextPickerPresented else { return false }
        if isContextPickerLanguageAddPresented {
            isContextPickerLanguageAddPresented = false
            return true
        }
        if isContextPickerFilterPresented {
            isContextPickerFilterPresented = false
            return true
        }
        dismissMentionPicker()
        return true
    }

    /// `+` 与独立的 `@` 是同一入口。`@` 被消费掉，绝不能泄露进最终问题。
    func presentContextPicker() {
        isContextPickerPresented = true
        isContextPickerFilterPresented = false
        isContextPickerLanguageAddPresented = false
        highlightedMentionRepoID = nil
        schedulePagedMentionQueryIfNeeded(force: true)
    }

    func handleDraftQuestionChanged() {
        // `@` 是明确的快捷触发。消费这个字符可避免它泄露进最终问题。
        if draftQuestion.last == "@" {
            draftQuestion.removeLast()
            presentContextPicker()
        }
        scheduleGitHubLinkDetection()
    }

    private func applyInitialMentionPage(_ page: RAGMentionCandidatePage) {
        mentionKnowledgeCount = page.knowledgeCount
        mentionUsesPagedQuery = page.knowledgeCount > Self.mentionCatalogThreshold
        mentionCandidates = mentionUsesPagedQuery
            ? Array(page.candidates.prefix(RAGMentionPickerLogic.unselectedDisplayLimit))
            : page.candidates
        baseMentionCandidates = mentionCandidates
        cacheMentionRepositoryNames(page.candidates)
        loadedMentionQuery = ""
        loadedMentionMatchCount = page.matchCount
        loadedMentionHasMore = mentionUsesPagedQuery
    }

    /// 大库搜索按 120ms 合并；排序/筛选变更可 `force` 立即重查。
    /// Wiki 筛选在 MainActor 用 DiskWikiCache 后裁切（仓库层只下推 SQLite 条件）。
    private func schedulePagedMentionQueryIfNeeded(force: Bool = false) {
        mentionQueryTask?.cancel()
        guard isContextPickerPresented || force else { return }
        let query = contextPickerQuery
        let sort = mentionSortOption
        let filters = mentionFilters
        let needsSQL = force
            || mentionUsesPagedQuery
            || !query.isEmpty
            || filters.isActive
            || sort != RAGComposerMentionSort.default
        guard needsSQL else {
            // 小库 + 默认排序筛选 + 无关键词：回到启动时装好的内存目录。
            mentionCandidates = baseMentionCandidates
            loadedMentionQuery = ""
            loadedMentionMatchCount = baseMentionCandidates.count
            loadedMentionHasMore = false
            return
        }
        // force 时即使面板未开也预取，打开时已是正确列表；面板未开则跳过 UI 等待。
        guard isContextPickerPresented || force else { return }
        mentionQueryTask = Task { [weak self] in
            do {
                if !force {
                    try await Task.sleep(for: .milliseconds(120))
                }
                guard let self else { return }
                let page = try await self.fetchMentionCandidatesApplyingWikiIfNeeded(
                    query: query,
                    sort: sort,
                    filters: filters
                )
                try Task.checkCancellation()
                guard self.contextPickerQuery == query,
                      self.mentionSortOption == sort,
                      self.mentionFilters == filters else { return }
                self.mentionCandidates = page.candidates
                self.cacheMentionRepositoryNames(page.candidates)
                self.mentionKnowledgeCount = page.knowledgeCount
                self.loadedMentionQuery = query
                self.loadedMentionMatchCount = page.matchCount
                self.loadedMentionHasMore = page.hasMore
            } catch is CancellationError {
                // 连续输入会取消旧查询；不是用户可见错误。
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// SQL 拉取后再按 Wiki 磁盘缓存裁切；无 Wiki 筛选时原样返回。
    private func fetchMentionCandidatesApplyingWikiIfNeeded(
        query: String,
        sort: RepoSortOption,
        filters: RAGComposerMentionFilters
    ) async throws -> RAGMentionCandidatePage {
        let limit = RAGMentionPickerLogic.unselectedDisplayLimit
        guard filters.wikiAvailability != .unknown else {
            return try await dependencies.ragCandidateRepository.fetchMentionCandidates(
                query: query,
                limit: limit,
                offset: 0,
                sort: sort,
                filters: filters
            )
        }

        var sqlFilters = filters
        sqlFilters.wikiAvailability = .unknown
        let pageSize = max(limit * 2, 40)
        var scanOffset = 0
        var window: [RAGMentionCandidate] = []
        var knowledgeCount = 0
        var exhausted = false

        while window.count < limit + 1 {
            let page = try await dependencies.ragCandidateRepository.fetchMentionCandidates(
                query: query,
                limit: pageSize,
                offset: scanOffset,
                sort: sort,
                filters: sqlFilters
            )
            knowledgeCount = page.knowledgeCount
            if page.candidates.isEmpty {
                exhausted = true
                break
            }
            for candidate in page.candidates where matchesWikiAvailability(candidate, filter: filters.wikiAvailability) {
                window.append(candidate)
                if window.count >= limit + 1 { break }
            }
            scanOffset += page.candidates.count
            if !page.hasMore {
                exhausted = true
                break
            }
            if scanOffset > 5_000 { break }
        }

        return RAGMentionCandidatePage(
            candidates: Array(window.prefix(limit)),
            knowledgeCount: knowledgeCount,
            matchCount: window.count,
            hasMore: window.count > limit || (!exhausted && window.count >= limit)
        )
    }

    private func matchesWikiAvailability(
        _ candidate: RAGMentionCandidate,
        filter: RepoSignalAvailabilityFilter
    ) -> Bool {
        let snapshot = DiskWikiCache.shared.load(owner: candidate.owner, repo: candidate.name)
        guard let snapshot else {
            return filter == .unknown
        }
        let hasWiki = !snapshot.indexedLinks.isEmpty
        switch filter {
        case .unknown: return true
        case .available: return hasWiki
        case .missing: return !hasWiki
        }
    }

    func resetMentionFilters() {
        mentionFilters = .empty
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
    func showKnowledgeBrowser(
        presentingWindow: NSWindow?,
        settingsNavigation: RAGSettingsNavigationAction
    ) {
        KnowledgeRAGBrowserWindowController.show(
            dependencies: dependencies,
            homeViewModel: homeViewModel,
            settingsNavigation: settingsNavigation,
            centeredOver: presentingWindow
        )
    }

    /// 空库时打开批量入库 Sheet；入库后 IndexBuilder 会自动补 README 并建索引。
    func presentAddToLibrary() {
        isAddToLibraryPresented = true
    }

    /// 左栏知识库入口：空库走入库 Sheet，有仓库才打开只读浏览器。
    func openKnowledgeBaseEntry(
        presentingWindow: NSWindow?,
        settingsNavigation: RAGSettingsNavigationAction
    ) {
        if isKnowledgeBaseEmpty {
            presentAddToLibrary()
        } else {
            showKnowledgeBrowser(
                presentingWindow: presentingWindow,
                settingsNavigation: settingsNavigation
            )
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
            let uncachedRepoIDs = Set(page.chunks.map(\.repoId)).filter { mentionRepositoryNames[$0] == nil }
            if !uncachedRepoIDs.isEmpty {
                let repos = try await dependencies.ragCandidateRepository.fetchMentionRepos(ids: Array(uncachedRepoIDs))
                for repo in repos {
                    mentionRepositoryNames[repo.id] = repo.fullName
                }
            }
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
        mentionRepositoryNames[id]
            ?? mentionCandidates.first(where: { $0.id == id })?.fullName
            ?? selectedRepoContexts.first(where: { $0.id == id })?.fullName
            ?? "#\(id)"
    }

    private func cacheMentionRepositoryNames(_ candidates: [RAGMentionCandidate]) {
        for candidate in candidates {
            mentionRepositoryNames[candidate.id] = candidate.fullName
        }
    }

    func selectCitation(_ citation: RAGCitation) {
        // 右侧证据换到另一条时，关掉正文 S1 的分片弹层。
        if let openID = citationChunkPopoverCitationID, openID != citation.id {
            citationChunkPopoverCitationID = nil
            _ = citationChunkPopoverGate.begin()
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
                    interfaceScale: dependencies.settings.interfaceScale,
                    settings: dependencies.settings
                )
            }
        }
    }

    /// 回答正文蓝色 `[S1]`：只在点击位置弹出命中分片，不选中右侧证据、不 bump `citationFocusSequence`。
    /// 底部芯片走 `selectCitation`，负责右侧自动导航。
    func presentCitationChunk(_ citation: RAGCitation) {
        // RepoContext 不是数据库分片，没有 chunkID。正文 marker 应定位右侧独立 XML 证据卡，
        // 不能复用“分片缺失”popover，否则会把正常的仓库级证据误报成索引损坏。
        if citation.source == .repoContext || citation.source == .knowledgeBaseMetadata {
            selectCitation(citation)
            return
        }
        // 同一 marker 的快速连点只保留第一次：popover 已经处于 loading / 展示态时重新创建，
        // 会先关闭再打开，既造成闪烁，也让上一轮异步读取有机会命中新弹层。
        guard citationChunkPopoverCitationID != citation.id else { return }

        let clickPoint = NSEvent.mouseLocation
        let requestGeneration = citationChunkPopoverGate.begin()
        citationChunkPopoverCitationID = citation.id
        let scale = dependencies.settings.interfaceScale
        let isMissing = citation.chunkID == nil
        RAGCitationChunkNSPopoverPresenter.shared.present(
            citation: citation,
            chunk: nil,
            isMissing: isMissing,
            screenPoint: clickPoint,
            interfaceScale: scale,
            settings: dependencies.settings,
            onDismiss: { [weak self] in
                guard let self,
                      self.citationChunkPopoverGate.isCurrent(requestGeneration) else { return }
                self.citationChunkPopoverCitationID = nil
                _ = self.citationChunkPopoverGate.begin()
            }
        )
        // 弹层先以 loading 出现；正文路径不碰 selectedCitation，避免 Inspector 跳转。
        guard let chunkID = citation.chunkID else { return }
        Task { [weak self] in
            guard let self else { return }
            let chunk = try? await dependencies.ragChunkRepository.fetchChunks(ids: [chunkID]).first
            guard citationChunkPopoverCitationID == citation.id,
                  citationChunkPopoverGate.isCurrent(requestGeneration) else { return }
            RAGCitationChunkNSPopoverPresenter.shared.update(
                citation: citation,
                chunk: chunk,
                isMissing: chunk == nil,
                interfaceScale: dependencies.settings.interfaceScale,
                settings: dependencies.settings
            )
        }
    }

    func dismissCitationChunkPopover() {
        guard citationChunkPopoverCitationID != nil else { return }
        citationChunkPopoverCitationID = nil
        _ = citationChunkPopoverGate.begin()
        RAGCitationChunkNSPopoverPresenter.shared.dismiss()
    }

    /// 证据列表手风琴：再点同一条则收起。
    func toggleCitation(_ citation: RAGCitation) {
        if selectedCitation?.id == citation.id {
            selectedCitation = nil
            selectedCitationChunk = nil
            citationChunkPopoverCitationID = nil
            _ = citationChunkPopoverGate.begin()
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

    /// 回答正文里的 `starcat-rag://citation/<uuid>`：只弹出命中分片。
    /// 底部引用芯片不走此路径（芯片只 `selectCitation` → 右侧导航）。
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
        if let repoID = citation.repoID,
           let repo = try? await dependencies.repoRepository.findById(repoID) {
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
                guard let repoID = citation.repoID,
                      seen.insert(repoID).inserted else { return nil }
                return RAGPlannerRepoReference(id: repoID, fullName: citation.repoFullName)
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
        updateRuntimeState(for: conversationID) { runtime in
            runtime.userMessage = userMessage
            runtime.streamingAnswer = ""
            runtime.streamingPresentation = nil
            runtime.queryPlan = nil
            runtime.retrieval = nil
            runtime.contextUsage = nil
            runtime.repositoryInsightsDocuments = []
            runtime.repoContextDocument = nil
            runtime.remoteBlocks = []
        }
        if selectedConversationID == conversationID {
            messages.append(userMessage)
            draftQuestion = ""
            streamingAnswer = ""
            streamingPresentation = nil
            queryPlan = nil
            retrieval = nil
            lastContextUsage = nil
            repositoryInsightsDocuments = []
            repoContextDocument = nil
            executionSteps = []
            remoteBlocks = []
            pendingRemoteWorkItems = []
            approvedRemoteWorkItemIDs = []
            selectedCitation = nil
            selectedCitationChunk = nil
            citationChunkPopoverCitationID = nil
            _ = citationChunkPopoverGate.begin()
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
        // 正文发布严格限制为 15Hz。完整回答独立累计，较大的网络批次也不能绕过
        // UI 上限，否则单次回调中的 token 数越多，反而越容易触发连续重排。
        var answerPresentationThrottle = StreamingPresentationThrottle(
            minimumInterval: RAGStreamingPresentationCadence.answerInterval
        )
        var presentationRevision = 0
        var markdownAssembler = StreamingMarkdownAssembler()
        // Think 可能按 token 回调。完整文本留在 buffer，只有节流后的快照进入
        // `executionSteps`。运行态严格 10Hz 且只展示最近 8,000 字符，避免长 Think
        // 反复测量完整增长文本；终态仍从 buffer.text 发布完整内容并持久化。
        var planningReasoningBuffer = StreamingTextPresentationBuffer(
            throttleInterval: RAGStreamingPresentationCadence.reasoningInterval,
            immediateCharacterCount: nil,
            maximumPresentedCharacterCount: 8_000
        )
        var answerReasoningBuffer = StreamingTextPresentationBuffer(
            throttleInterval: RAGStreamingPresentationCadence.reasoningInterval,
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
        updateRuntimeState(for: conversationID) { $0.streamingPresentation = initialStreamingPresentation }
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
                    deepThinkingEnabled: requestSnapshot.composerContext.deepThinkingEnabled,
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
                    updateRuntimeState(for: conversationID) { $0.queryPlan = plan }
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
                    updateRuntimeState(for: conversationID) { $0.retrieval = result }
                    updateExecutionStep(in: &turnExecutionSteps, kind: .retrieval) { step in
                        step.retrievalSnapshot = RAGRetrievalSnapshot(result: result)
                    }
                    syncExecutionSteps(turnExecutionSteps, for: conversationID)
                    if selectedConversationID == conversationID {
                        retrieval = result
                    }
                case .repositoryInsights(let documents):
                    updateRuntimeState(for: conversationID) {
                        $0.repositoryInsightsDocuments = documents
                    }
                    if selectedConversationID == conversationID {
                        repositoryInsightsDocuments = documents
                    }
                case .repoContext(let document):
                    updateRuntimeState(for: conversationID) { $0.repoContextDocument = document }
                    if selectedConversationID == conversationID {
                        repoContextDocument = document
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
                    updateRuntimeState(for: conversationID) { $0.remoteBlocks = blocks }
                    if selectedConversationID == conversationID { remoteBlocks = blocks }
                case .terminal(let response):
                    terminalReply = response.answer
                    suggestedActions = response.suggestedActions
                case .metadataSnapshot(let snapshot): knowledgeBaseMetadataSnapshot = snapshot
                case .contextUsage(let usage):
                    updateRuntimeState(for: conversationID) { $0.contextUsage = usage }
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
                    updateRuntimeState(for: conversationID) { $0.streamingPresentation = presentation }
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
                updateRuntimeState(for: conversationID) { $0.streamingAnswer = accumulatedAnswer }
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
                    updateRuntimeState(for: conversationID) { $0.streamingAnswer = accumulatedAnswer }
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

        case .repositoryInsightsPrepared(let snapshots):
            updateExecutionStep(in: &executionSteps, kind: .repositoryInsights) { step in
                step.repositoryInsightsSnapshots = snapshots
                step.details = [String(
                    format: String.l10n("rag.workspace.execution.repositoryInsights.preparedFormat"),
                    snapshots.filter { $0.outcome == .success }.count,
                    snapshots.count
                )]
            }

        case .repositoryInsightsProjectionStarted:
            updateExecutionStep(in: &executionSteps, kind: .repositoryInsights) { step in
                let detail = String.l10n("rag.workspace.execution.repositoryInsights.projecting")
                if step.details.last != detail {
                    step.details.append(detail)
                }
            }

        case .repositoryInsightsCompleted(let snapshots):
            updateExecutionStep(in: &executionSteps, kind: .repositoryInsights) { step in
                let sentCount = snapshots.filter { $0.outcome == .success && $0.sentTokens > 0 }.count
                let sentTokens = snapshots.reduce(0) { $0 + $1.sentTokens }
                let isPromptPlaceholderMissing = snapshots.contains {
                    $0.degradationReason == RAGRepositoryInsightsReason.promptPlaceholderMissing
                }
                step.repositoryInsightsSnapshots = snapshots
                step.details.append(String(
                    format: String.l10n("rag.workspace.execution.repositoryInsights.tokensFormat"),
                    sentCount,
                    sentTokens
                ))
                step.summary = sentCount > 0
                    ? String(
                        format: String.l10n("rag.workspace.execution.repositoryInsights.completedFormat"),
                        sentCount
                    )
                    : String.l10n(
                        isPromptPlaceholderMissing
                            ? "rag.workspace.execution.repositoryInsights.promptNotEnabled"
                            : "rag.workspace.execution.repositoryInsights.unavailable"
                    )
                completeExecutionStep(&step)
                if sentCount == 0 {
                    step.state = .skipped
                }
            }

        case .repoContextProgress(let progress):
            updateExecutionStep(in: &executionSteps, kind: .repoContext) { step in
                let key = switch progress {
                case .resolvingBranch: "rag.workspace.execution.repoContext.resolvingBranch"
                case .checkingCache: "rag.workspace.execution.repoContext.checkingCache"
                case .downloadingArchive: "rag.workspace.execution.repoContext.downloadingArchive"
                case .packingContext: "rag.workspace.execution.repoContext.packingContext"
                }
                let detail = String.l10n(key)
                if step.details.last != detail {
                    step.details.append(detail)
                }
            }

        case .repoContextPrepared(let snapshot):
            updateExecutionStep(in: &executionSteps, kind: .repoContext) { step in
                step.repoContextSnapshot = snapshot
                step.details.append(String(
                    format: String.l10n("rag.workspace.execution.repoContext.xmlPreparedFormat"),
                    snapshot.originalTokens
                ))
            }

        case .repoContextProjectionStarted:
            updateExecutionStep(in: &executionSteps, kind: .repoContext) { step in
                let detail = String.l10n("rag.workspace.execution.repoContext.projecting")
                if step.details.last != detail {
                    step.details.append(detail)
                }
            }

        case .repoContextCompleted(let snapshot):
            updateExecutionStep(in: &executionSteps, kind: .repoContext) { step in
                step.repoContextSnapshot = snapshot
                step.details.removeAll {
                    $0.hasPrefix(String.l10n("rag.workspace.execution.repoContext.tokenDetailPrefix"))
                }
                step.details.append(String(
                    format: String.l10n("rag.workspace.execution.repoContext.tokensFormat"),
                    snapshot.sentTokens
                ))
                step.summary = switch snapshot.outcome {
                case .success: String.l10n("rag.workspace.execution.repoContext.completed")
                case .featureDisabled: String.l10n("rag.workspace.execution.repoContext.disabled")
                case .degraded: String.l10n("rag.workspace.execution.repoContext.degraded")
                }
                completeExecutionStep(&step)
                if snapshot.outcome != .success {
                    step.state = .skipped
                }
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
        let persistedTurn = try await conversationStore.appendTurn(
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
        let summary = mergePersistedConversationSummary(persistedTurn.summary)
        if canUpdateVisibleAnswer(for: conversationID, generationID: generationID) {
            let current = RAGConversationPresentationSnapshot(
                detail: RAGConversationDetail(
                    summary: summary,
                    messages: messages,
                    contextSummary: conversationContextSummary
                ),
                outlineTurns: conversationOutlineTurns,
                citations: conversationCitations
            )
            let updated = current.appending(persistedTurn, summary: summary)
            conversationPresentationCache.insert(updated)
            messages = updated.detail.messages
            conversationOutlineTurns = updated.outlineTurns
            conversationCitations = updated.citations
            loadedMessageSequence &+= 1
            // 回答完成后不自动选中引用，避免强制拉开右侧「证据」tab。
        } else if let cached = conversationPresentationCache.value(for: conversationID) {
            conversationPresentationCache.insert(cached.appending(persistedTurn, summary: summary))
        }
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

    /// appendTurn 只改变首轮默认标题与真实活跃时间；Pin、分组和人工/AI 标题可能在回答期间
    /// 被另一个 UI 操作更新，不能用事务开始时的旧 summary 覆盖这些较新的本地状态。
    private func mergePersistedConversationSummary(_ persisted: RAGConversationSummary) -> RAGConversationSummary {
        guard let index = conversations.firstIndex(where: { $0.id == persisted.id }) else {
            conversations.append(persisted)
            return persisted
        }
        var merged = conversations[index]
        if merged.title == String.l10n("rag.workspace.newConversation") {
            merged.title = persisted.title
        }
        merged.updatedAt = persisted.updatedAt
        conversations[index] = merged
        return merged
    }

    private func refreshIndexCoverage() async throws {
        indexStatus = try await dependencies.knowledgeRAGIndexBuilder.coverage()
        hasLoadedIndexCoverage = true

        // 索引通知到达时，已经展开的问题抽屉必须刷新第一页，不能直接清空缓存：
        // 展开状态归 Inspector 所有，ViewModel 清空后不会触发再次加载，最终会把
        // “缓存被清空”误画成“暂无匹配分片”。用已有 key 作为已加载集合，既避免
        // 未展开类别的额外查询，也让状态变化后的列表与顶部计数保持一致。
        for kind in Array(indexIssueChunks.keys) {
            await loadIndexIssueChunks(kind)
        }
    }

    /// 面板初次展示与知识库边界/索引变化后都从固定 SQL 重新读取。失败不能影响问答或索引刷新；
    /// 下一次成功读取会自然覆盖旧值，而真正发送给模型的一轮快照仍由 Service 事件优先覆盖。
    private func refreshKnowledgeBaseMetadataSnapshot() async {
        do {
            knowledgeBaseMetadataSnapshot = try await KnowledgeBaseMetadataSnapshotProvider(
                database: dependencies.database,
                embeddingModel: embeddingModel,
                cache: dependencies.knowledgeBaseMetadataSnapshotCache
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
        repositoryInsightsDocuments = []
        repoContextDocument = nil
        lastContextUsage = nil
        remoteBlocks = []
        pendingRemoteWorkItems = []
        approvedRemoteWorkItemIDs = []
        // Composer 草稿（输入文案 / @repo / 附件 / 联网与深度思考开关）由 save/restoreComposerDraft 按会话处理，
        // 这里绝不能无条件清空，否则切回原会话会丢失未发送上下文。
        errorMessage = nil
        selectedCitation = nil
        selectedCitationChunk = nil
        citationChunkPopoverCitationID = nil
        _ = citationChunkPopoverGate.begin()
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
                webSearchEnabled: webSearchEnabled,
                deepThinkingEnabled: deepThinkingEnabled,
                mentionSortOption: mentionSortOption,
                mentionFilters: mentionFilters
            ),
            for: conversationID
        )
    }

    /// 安装目标会话的 Composer；无草稿时回到空白，避免沿用上一会话的 chip。
    private func restoreComposerDraft(for conversationID: UUID) {
        let draft = dependencies.ragComposerDraftStore.draft(for: conversationID) ?? RAGComposerDraftSnapshot()
        isRestoringComposerDraft = true
        draftQuestion = draft.draftQuestion
        selectedRepoContexts = Array(draft.selectedRepoContexts.prefix(Self.maxSelectedRepoContexts))
        attachments = draft.attachments
        githubLinkContexts = draft.githubLinkContexts
        explicitRepoMode = draft.explicitRepoMode
        webSearchEnabled = draft.webSearchEnabled
        deepThinkingEnabled = draft.deepThinkingEnabled
            && Self.canEnableDeepThinking(repoCount: selectedRepoContexts.count)
        mentionSortOption = draft.mentionSortOption
        mentionFilters = draft.mentionFilters
        isRestoringComposerDraft = false
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

        let visibleCandidate = mentionCandidates.first(where: {
            $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        })
        // 大库分页下，目标仓库可能不在当前首屏。用精确 full_name 触发一次轻量查询，
        // 不能因为 UI 没加载到它就误判为“已知但未入知识库”。
        var candidate = visibleCandidate
        if candidate == nil,
           let page = try? await dependencies.ragCandidateRepository.fetchMentionCandidates(
               query: "\(owner)/\(name)",
               limit: 5,
               offset: 0,
               sort: mentionSortOption,
               filters: .empty
           ) {
            candidate = page.candidates.first(where: {
                $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            })
        }
        if let candidate {
            mentionRepositoryNames[candidate.id] = candidate.fullName
            if !selectedRepoContexts.contains(where: { $0.id == candidate.id }),
               selectedRepoContexts.count < Self.maxSelectedRepoContexts,
               let repo = try? await dependencies.ragCandidateRepository.fetchMentionRepos(ids: [candidate.id]).first {
                selectedRepoContexts.append(repo)
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
