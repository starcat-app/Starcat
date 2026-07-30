//
//  KnowledgeRAGService.swift
//  Starcat
//
//  知识库 RAG 的端到端执行状态机：Planner -> SQL candidates -> hybrid retrieval ->
//  remote/attachments -> Generator。每个早停状态都显式返回，避免“没搜到仍让模型自由回答”。
//

import CryptoKit
import Foundation

enum KnowledgeRAGServiceEvent: Sendable {
    case state(RAGAnswerState)
    case execution(RAGExecutionEvent)
    case plan(RAGQueryPlan)
    case retrieval(RAGRetrievalResult)
    /// 只在当前运行态传递最终进入 Prompt 的洞察 XML；会话持久化仅保存 execution snapshot。
    case repositoryInsights([RAGRepositoryInsightsDocument])
    /// 只在本轮内存传递实际进入 Prompt 的 XML；execution trace 仅保存 snapshot。
    case repoContext(RAGRepoContextDocument)
    case remoteContextConfirmation([RAGResolvedRemoteWorkItem])
    case remoteContext([RAGRemoteContextBlock])
    case terminal(RAGTerminalResponse)
    /// 将实际拼入 Generator Prompt 的同一份快照交给工作台，供用户核对数据库事实来源。
    case metadataSnapshot(KnowledgeBaseMetadataSnapshot)
    /// 仅保存本轮内存快照，供 Composer 复用实际请求的 Context 占用；不写入历史记录。
    case contextUsage(RAGContextUsage)
    case debug(RAGDebugEvent)
    case delta(String)
    case completed(answer: String, model: String, citations: [RAGCitation], plan: RAGQueryPlan)
}

/// 默认会话可见的 RAG 执行事件。
///
/// 与 `RAGDebugEvent` 严格分层：这里仅描述用户已触发且可核验的操作结果，不包含完整
/// prompt、对话历史或模型参数；provider 已公开并由用户主动查看的推理文本例外。
enum RAGExecutionEvent: Sendable {
    case started(RAGExecutionStepKind)
    case planningCompleted(RAGQueryPlan)
    case reasoningDelta(RAGExecutionStepKind, String)
    case reasoningCompleted(RAGExecutionStepKind)
    case retrieval(RAGRetrievalProgress)
    case retrievalCompleted(RAGRetrievalResult)
    /// cache-only 加载完成，但尚未根据本轮 Context Window 投影。
    case repositoryInsightsPrepared([RAGRepositoryInsightsSnapshot])
    case repositoryInsightsProjectionStarted
    case repositoryInsightsCompleted([RAGRepositoryInsightsSnapshot])
    case repoContextProgress(RepoAIContextProgress)
    /// Provider 已准备合法 XML，但尚未按本轮模型总窗口计算最终发送投影。
    case repoContextPrepared(RAGRepoContextSnapshot)
    /// 投影发生在所有其它上下文已知之后，必须作为真实子状态展示，不能提前伪报完成。
    case repoContextProjectionStarted
    case repoContextCompleted(RAGRepoContextSnapshot)
    case remoteContextPrepared([RAGResolvedRemoteWorkItem])
    case webSearchPrepared([RAGWebSearchRequest])
    case remoteContextProgress(completed: Int, total: Int)
    case remoteContextCompleted([RAGRemoteContextBlock])
    case generationStarted(evidenceCount: Int)
    case generationCompleted(citationCount: Int)
    case terminated(RAGExecutionStepKind, summary: String)
}

/// RAG 工作台当前一轮的内存调试记录。
///
/// 这不是诊断日志，也不会进入会话持久化；只有 `RAGServiceRequest.isDebugEnabled` 为 true
/// 时才由 Service 发出，窗口关闭或关闭调试模式后即被释放。
struct RAGDebugEvent: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case request
        case plannerPrompt = "planner_prompt"
        case plannerResponse = "planner_response"
        case plan
        case candidates
        case structuredAnalytics = "structured_analytics"
        case rerank
        case retrieval
        case repositoryInsightsRequest = "repository_insights_request"
        case repositoryInsightsLoad = "repository_insights_load"
        case repositoryInsightsProjection = "repository_insights_projection"
        case repoContextRequest = "repo_context_request"
        case repoContextResponse = "repo_context_response"
        case repoContextProjection = "repo_context_projection"
        case remoteRequest = "remote_request"
        case remoteResponse = "remote_response"
        case remoteContext
        case prompt
        case response
        case compressionPrompt = "compression_prompt"
        case compressionResponse = "compression_response"
        case titlePrompt = "title_prompt"
        case titleResponse = "title_response"
        case failure
    }

    let id: UUID
    let stage: Stage
    let elapsedSeconds: TimeInterval
    let payload: String
    /// 检索诊断保留结构化快照而非已翻译文本。Debug Trace 可在用户切换显示语言后重新渲染，
    /// 不会出现标题是英文、正文仍停留在旧语言的割裂状态。
    let retrievalPayload: RAGRetrievalDebugPayload?
    /// Rerank 独立作为 Trace 行，避免用户必须展开“检索结果”才能确认是否实际调用。
    let rerankPayload: RAGRerankDebugPayload?

    init(
        id: UUID = UUID(),
        stage: Stage,
        elapsedSeconds: TimeInterval,
        payload: String,
        retrievalPayload: RAGRetrievalDebugPayload? = nil,
        rerankPayload: RAGRerankDebugPayload? = nil
    ) {
        self.id = id
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
        self.payload = payload
        self.retrievalPayload = retrievalPayload
        self.rerankPayload = rerankPayload
    }

    /// 统一在展示、复制或导出时生成文本；普通调试事件仍直接使用原始 payload。
    func renderedPayload() -> String {
        retrievalPayload?.renderedText() ?? rerankPayload?.renderedText() ?? payload
    }

    /// 内存上限按真实保存的字节数计算；结构化检索事件的最终分片不在 `payload` 内，不能漏算。
    var storedPayloadUTF8ByteCount: Int {
        payload.utf8.count
            + (retrievalPayload?.evidenceDetails.utf8.count ?? 0)
            + (rerankPayload?.storedPayloadUTF8ByteCount ?? 0)
    }
}

/// 检索阶段的可本地化调试快照。最终分片保持技术明细原文，用户可据此复核真正被送入模型的分片。
struct RAGRetrievalDebugPayload: Codable, Sendable {
    let diagnostics: RAGRetrievalDiagnostics?
    let evidenceDetails: String

    func renderedText() -> String {
        let diagnosticsText = diagnostics?.debugPayload()
            ?? String.l10n("rag.workspace.debug.retrieval.unavailable")
        guard !evidenceDetails.isEmpty else { return diagnosticsText }
        return [
            diagnosticsText,
            String.l10n("rag.workspace.debug.retrieval.evidenceDetails.title"),
            evidenceDetails
        ].joined(separator: "\n\n")
    }
}

/// 独立 Rerank Trace 的结构化快照。保留问题与候选映射以诊断排序，但不能写入地址、凭据或正文。
struct RAGRerankDebugPayload: Codable, Sendable {
    let diagnostics: RAGRerankDiagnostics

    func renderedText() -> String {
        guard let trace = diagnostics.trace else { return diagnostics.debugPayload() }
        let provider = switch diagnostics.provider {
        case .huggingFaceTEI: String.l10n("rag.workspace.rerank.provider.tei")
        case .cohereCompatible: String.l10n("rag.workspace.rerank.provider.cohere")
        case nil: String.l10n("rag.workspace.debug.retrieval.error.none")
        }
        var requestLines = [
            String(format: String.l10n("rag.workspace.debug.rerank.providerFormat"), provider),
            String(format: String.l10n("rag.workspace.debug.rerank.queryFormat"), trace.query),
            String(format: String.l10n("rag.workspace.debug.rerank.inputCountFormat"), trace.inputCandidates.count)
        ]
        if let model = trace.model, !model.isEmpty {
            requestLines.insert(String(format: String.l10n("rag.workspace.debug.rerank.modelFormat"), model), at: 1)
        }
        if let candidateLimit = trace.candidateLimit {
            requestLines.append(String(format: String.l10n("rag.workspace.debug.rerank.candidateLimitFormat"), candidateLimit))
        }
        requestLines += trace.inputCandidates.map { candidate in
            String(format: String.l10n("rag.workspace.debug.rerank.inputCandidateFormat"), candidate.inputIndex, candidate.repositoryName, sourceTitle(candidate.source), candidate.section, candidate.preRerankScore)
        }

        let appliedLines = trace.appliedOrder.compactMap { item -> String? in
            guard let inputIndex = item.inputIndex, let rerankScore = item.rerankScore else { return nil }
            return String(
                format: String.l10n("rag.workspace.debug.rerank.appliedResultFormat"),
                item.rank,
                inputIndex,
                rerankScore
            )
        }
        // 超过候选上限的分片只保留一条备注，避免大型召回结果把 Debug 面板刷成长列表。
        // 已发送但服务端漏回的候选单独说明，不能与“未发送”混为同一种降级原因。
        let appliedDetails = [
            appliedLines.map { "- \($0)" }.joined(separator: "\n"),
            renderedAppliedNotes().joined(separator: "\n")
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return [
            diagnostics.debugPayload(),
            String.l10n("rag.workspace.debug.rerank.request.title"),
            requestLines.map { "- \($0)" }.joined(separator: "\n"),
            String.l10n("rag.workspace.debug.rerank.applied.title"),
            appliedDetails
        ].joined(separator: "\n\n")
    }

    /// 返回需要在 Inspector 中降级为备注样式的行；复制与导出仍保留同一份可读文本。
    func renderedAppliedNotes() -> [String] {
        guard let trace = diagnostics.trace else { return [] }
        let missingResponseCount = trace.appliedOrder.filter { item in
            item.inputIndex != nil && item.rerankScore == nil
        }.count
        let unsentCount = trace.appliedOrder.filter { $0.inputIndex == nil }.count
        var notes: [String] = []
        if missingResponseCount > 0 {
            notes.append(String(
                format: String.l10n("rag.workspace.debug.rerank.appliedMissingResponseNoteFormat"),
                missingResponseCount
            ))
        }
        if unsentCount > 0 {
            notes.append(String(
                format: String.l10n("rag.workspace.debug.rerank.appliedUnsentNoteFormat"),
                trace.inputCandidates.count,
                unsentCount
            ))
        }
        return notes
    }

    var storedPayloadUTF8ByteCount: Int {
        // 结构化内容会落入会话级 Debug 文件，按编码后的真实字节数参与内存上限计算。
        (try? JSONEncoder().encode(self).count) ?? 0
    }

    private func sourceTitle(_ source: RAGChunkSource) -> String {
        switch source {
        case .readme: String.l10n("rag.browser.source.readme")
        case .notes: String.l10n("rag.browser.source.notes")
        case .summary: String.l10n("rag.browser.source.summary")
        case .metadata: String.l10n("rag.browser.source.metadata")
        }
    }
}

/// 一次独立的调试调用。问答与标题生成分别保存，不能共享平铺的事件数组。
enum RAGDebugTraceCategory: String, Codable, Sendable {
    case questionAnswer = "question_answer"
    case conversationTitle = "conversation_title"
}

struct RAGDebugTrace: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    let category: RAGDebugTraceCategory
    let startedAt: Date
    var state: State
    var events: [RAGDebugEvent]
}

/// Service 在 Planner 判断需要联网后暂停，工作台用 chip 让用户确认或移除资源。
/// 轮询式等待天然响应 Task cancellation，避免 continuation 在窗口关闭时悬挂。
actor RAGRemoteContextConsent {
    private var decision: Set<String>?

    func wait() async throws -> Set<String> {
        while decision == nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        return decision ?? []
    }

    func resolve(_ workItemIDs: Set<String>) {
        decision = workItemIDs
    }
}

protocol KnowledgeRAGRemoteContextProviding: Sendable {
    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock]
}

/// 远程上下文的逐请求调试事件。它刻意不携带请求头，避免 Debug Trace 暴露 GitHub Token；
/// 缓存命中也会显式上报，便于区分“没有网络请求”和“网络请求没有返回内容”。
struct RAGRemoteContextDebugEvent: Sendable {
    enum Outcome: Sendable {
        case request
        case response(statusCode: Int)
        case failure(String)
        case cacheHit
    }

    let repoFullName: String
    let resource: RAGRemoteContextResource
    let url: String?
    let outcome: Outcome

    var stage: RAGDebugEvent.Stage {
        switch outcome {
        case .request: .remoteRequest
        case .response, .failure, .cacheHit: .remoteResponse
        }
    }

    var payload: String {
        let common = "repo: \(repoFullName)\nresource: \(resource.rawValue)\nurl: \(url ?? "<cache>")"
        switch outcome {
        case .request:
            return "method: GET\n\(common)"
        case .response(let statusCode):
            return "status: \(statusCode)\n\(common)"
        case .failure(let error):
            return "error: \(error)\n\(common)"
        case .cacheHit:
            return "cache: hit\nnetworkRequest: skipped\n\(common)"
        }
    }
}

/// 只让具备逐请求观测能力的 Provider 接收 Debug 回调，旧的测试替身和第三方实现仍可
/// 保持原协议。生产 GitHub Provider 实现该协议后，每条真实 HTTP 调用都会进入 Trace。
protocol KnowledgeRAGDebuggableRemoteContextProviding: KnowledgeRAGRemoteContextProviding {
    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void,
        onDebug: @escaping @Sendable (RAGRemoteContextDebugEvent) -> Void
    ) async -> [RAGRemoteContextBlock]
}

struct EmptyKnowledgeRAGRemoteContextProvider: KnowledgeRAGRemoteContextProviding {
    func fetch(
        workItems: [RAGResolvedRemoteWorkItem],
        onProgress: @escaping @Sendable (RAGRemoteContextFetchProgress) -> Void
    ) async -> [RAGRemoteContextBlock] { [] }
}

/// 远程请求按 repo/resource 计数，而不是按返回 block 猜测进度。缓存命中也算已完成，
/// 因此用户看到的数字始终对应本轮真正需要处理的工作单元。
struct RAGRemoteContextFetchProgress: Sendable, Equatable {
    var completed: Int
    var total: Int
}

/// 首轮问题提交后并行生成会话标题的结果。标题调用独立于 RAG 主链路，因此失败不会影响问答。
enum RAGConversationTitleGenerationResult: Sendable {
    case completed(title: String, debugEvents: [RAGDebugEvent])
    case failed(debugEvents: [RAGDebugEvent])
    case cancelled
}

/// 压缩在主 RAG 流开始前完成，不能直接通过 `KnowledgeRAGServiceEvent.debug` 回传。
/// 因此把本次 LLM 调用的事件连同结果返回给 ViewModel，由它写入同一条问答 Trace。
enum RAGConversationCompressionResult: Sendable {
    case completed(summary: String, debugEvents: [RAGDebugEvent])
    case failed(debugEvents: [RAGDebugEvent])
}

/// 所有内部阶段共用的单向事件出口。阶段只能发布事件，不能持有 ViewModel 或反向读取 UI；
/// Debug 的时间基准与开关也在这里统一，避免每个阶段复制隐私门禁。
struct RAGServiceEventSink: Sendable {
    typealias Continuation = AsyncThrowingStream<KnowledgeRAGServiceEvent, Error>.Continuation

    let continuation: Continuation
    let isDebugEnabled: Bool
    let startedAt: Date

    func yield(_ event: KnowledgeRAGServiceEvent) {
        continuation.yield(event)
    }

    func debug(_ stage: RAGDebugEvent.Stage, _ payload: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        yield(.debug(RAGDebugEvent(
            stage: stage,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            payload: payload()
        )))
    }
}

/// Prompt 阶段完成后的只读交接物。`retrieval` 可能只多了 evidence-token 裁剪标记；
/// 其它召回内容保持不变，Generation 不再自行判断证据合法性。
struct RAGPromptPhaseOutput: Sendable {
    let prompt: RAGPromptBuildResult
    let retrieval: RAGRetrievalResult
    let evidenceCount: Int
}

struct RAGRemoteContextPhaseOutput: Sendable {
    let plan: RAGQueryPlan
    let blocks: [RAGRemoteContextBlock]
    let plannedRequests: [RAGRemoteContextRequest]
    let resolvedWorkItems: [RAGResolvedRemoteWorkItem]
}

struct RAGRepoContextPhaseOutput: Sendable {
    let document: RAGRepoContextDocument?
    let snapshot: RAGRepoContextSnapshot?
}

struct RAGRepositoryInsightsPhaseOutput: Sendable {
    let documents: [RAGRepositoryInsightsDocument]
    let snapshots: [RAGRepositoryInsightsSnapshot]
}

struct RAGRetrievalPhaseOutput: Sendable {
    let attachmentContexts: [RAGAttachmentContext]
    let analyticsResult: KnowledgeBaseAnalyticsResult?
    let candidates: [RAGRepoCandidate]
    let retrieval: RAGRetrievalResult
    let hasScopedQuery: Bool
    let localMissingReasonKey: String?
}

struct RAGPlanningPhaseOutput: Sendable {
    let plan: RAGQueryPlan
    let metadataSnapshot: KnowledgeBaseMetadataSnapshot?
}

struct KnowledgeRAGService: Sendable {
    /// 召回测试用于人工核验而非构造回答；固定上限避免调试窗口被低分尾部结果淹没。
    private static let retrievalTestMaxHits = 10

    private let planner: any KnowledgeRAGQueryPlanning
    private let candidateRepository: any RAGRepoCandidateRepositoryProtocol
    private let retriever: KnowledgeRAGRetriever
    private let remoteContextProvider: any KnowledgeRAGRemoteContextProviding
    private let webSearchProvider: any RAGWebSearchProviding
    private let attachmentProcessor: any RAGAttachmentProcessing
    private let repositoryInsightsProvider: (any RepositoryInsightsRAGContextProviding)?
    private let repositoryInsightsTokenBudget: Int
    private let repoContextProvider: (any RepoAIContextProviding)?
    private let repoContextTokenBudget: Int
    private let generatorClient: any AIClientProtocol
    private let generatorModel: String
    private let generatorParameters: AIModelParameters
    private let promptBuilder: KnowledgeRAGPromptBuilder
    /// 全局聚合事实与向量证据分离；读取失败时不能让原有问答失败。
    private let metadataSnapshotProvider: KnowledgeBaseMetadataSnapshotProvider?
    /// 结构化分析的执行权留在本地。模型仅能给出 `KnowledgeBaseAnalyticsPlan`。
    private let analyticsExecutor: (any KnowledgeBaseAnalyticsExecuting)?
    /// 压缩 / 标题与 Generator/Planner 一样走可配置模板；缺省用英文默认值。
    private let compressorPromptConfiguration: AIPromptConfiguration
    private let titlePromptConfiguration: AIPromptConfiguration
    private let outputLanguage: String

    init(
        planner: any KnowledgeRAGQueryPlanning,
        candidateRepository: any RAGRepoCandidateRepositoryProtocol,
        retriever: KnowledgeRAGRetriever,
        remoteContextProvider: any KnowledgeRAGRemoteContextProviding = EmptyKnowledgeRAGRemoteContextProvider(),
        webSearchProvider: any RAGWebSearchProviding = EmptyRAGWebSearchProvider(),
        attachmentProcessor: any RAGAttachmentProcessing = RAGAttachmentProcessor(),
        repositoryInsightsProvider: (any RepositoryInsightsRAGContextProviding)? = nil,
        repositoryInsightsTokenBudget: Int = 8_000,
        repoContextProvider: (any RepoAIContextProviding)? = nil,
        repoContextTokenBudget: Int = 8_000,
        generatorClient: any AIClientProtocol,
        generatorModel: String,
        generatorParameters: AIModelParameters,
        promptBuilder: KnowledgeRAGPromptBuilder = .init(),
        metadataSnapshotProvider: KnowledgeBaseMetadataSnapshotProvider? = nil,
        analyticsExecutor: (any KnowledgeBaseAnalyticsExecuting)? = nil,
        compressorPromptConfiguration: AIPromptConfiguration = RAGDefaultPrompts.compressor,
        titlePromptConfiguration: AIPromptConfiguration = RAGDefaultPrompts.title,
        outputLanguage: String = "English"
    ) {
        self.planner = planner
        self.candidateRepository = candidateRepository
        self.retriever = retriever
        self.remoteContextProvider = remoteContextProvider
        self.webSearchProvider = webSearchProvider
        self.attachmentProcessor = attachmentProcessor
        self.repositoryInsightsProvider = repositoryInsightsProvider
        self.repositoryInsightsTokenBudget = min(max(repositoryInsightsTokenBudget, 1_024), 64 * 1_024)
        self.repoContextProvider = repoContextProvider
        self.repoContextTokenBudget = min(max(repoContextTokenBudget, 1_024), 64 * 1_024)
        self.generatorClient = generatorClient
        self.generatorModel = generatorModel
        self.generatorParameters = generatorParameters
        self.promptBuilder = promptBuilder
        self.metadataSnapshotProvider = metadataSnapshotProvider
        self.analyticsExecutor = analyticsExecutor
        self.compressorPromptConfiguration = compressorPromptConfiguration
        self.titlePromptConfiguration = titlePromptConfiguration
        self.outputLanguage = outputLanguage
    }

    func ask(
        request: RAGServiceRequest,
        history: [AIChatMessage] = [],
        remoteContextConsent: RAGRemoteContextConsent? = nil
    ) -> AsyncThrowingStream<KnowledgeRAGServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = request.debugTraceStartedAt ?? Date()
                let sink = RAGServiceEventSink(
                    continuation: continuation,
                    isDebugEnabled: request.isDebugEnabled,
                    startedAt: startedAt
                )

                do {
                    sink.debug(.request, """
                    question:
                    \(request.rawQuestion)

                    explicitRepoIDs: \(request.composerContext.explicitRepoIDs)
                    explicitRepoMode: \(request.composerContext.explicitRepoMode.rawValue)
                    selectedModelID: \(request.composerContext.selectedModelID ?? "<default>")
                    attachments: \(request.composerContext.attachments.map(\.filename))
                    pastedGitHubLinks: \(request.composerContext.pastedGitHubLinks.map { $0.url.absoluteString })
                    history:
                    \(history.enumerated().map { "[\($0.offset)] \($0.element.role.rawValue):\n\($0.element.content)" }.joined(separator: "\n\n"))
                    """)
                    guard let planningOutput = try await runPlanningPhase(request: request, sink: sink) else {
                        continuation.finish()
                        return
                    }
                    var plan = planningOutput.plan
                    let metadataSnapshot = planningOutput.metadataSnapshot

                    let retrievalOutput = try await runRetrievalPhase(
                        request: request,
                        plan: plan,
                        sink: sink
                    )
                    let attachmentContexts = retrievalOutput.attachmentContexts
                    let analyticsResult = retrievalOutput.analyticsResult
                    let candidates = retrievalOutput.candidates
                    let retrieval = retrievalOutput.retrieval
                    let hasScopedQuery = retrievalOutput.hasScopedQuery
                    let localMissingReasonKey = retrievalOutput.localMissingReasonKey

                    let repositoryInsightsOutput = try await runRepositoryInsightsPhase(
                        request: request,
                        candidates: candidates,
                        retrieval: retrieval,
                        sink: sink
                    )

                    let repoContextOutput = try await runRepoContextPhase(
                        request: request,
                        plan: plan,
                        sink: sink
                    )

                    let remoteOutput = try await runRemoteContextPhase(
                        request: request,
                        plan: plan,
                        candidates: candidates,
                        retrieval: retrieval,
                        consent: remoteContextConsent,
                        sink: sink
                    )
                    plan = remoteOutput.plan
                    let remoteBlocks = remoteOutput.blocks
                    let plannedRemoteRequests = remoteOutput.plannedRequests
                    let resolvedRemoteWorkItems = remoteOutput.resolvedWorkItems

                    guard let promptOutput = runPromptPhase(
                        request: request,
                        plan: plan,
                        retrieval: retrieval,
                        metadataSnapshot: metadataSnapshot,
                        analyticsResult: analyticsResult,
                        repositoryInsightsDocuments: repositoryInsightsOutput.documents,
                        repositoryInsightsSnapshots: repositoryInsightsOutput.snapshots,
                        repoContextDocument: repoContextOutput.document,
                        remoteBlocks: remoteBlocks,
                        attachmentContexts: attachmentContexts,
                        history: history,
                        candidates: candidates,
                        hasScopedQuery: hasScopedQuery,
                        localMissingReasonKey: localMissingReasonKey,
                        plannedRemoteRequests: plannedRemoteRequests,
                        resolvedRemoteWorkItems: resolvedRemoteWorkItems,
                        sink: sink
                    ) else {
                        continuation.finish()
                        return
                    }
                    try await runGenerationPhase(
                        prompt: promptOutput.prompt,
                        attachmentContexts: attachmentContexts,
                        plan: plan,
                        evidenceCount: promptOutput.evidenceCount,
                        debugEndpoint: request.debugEndpoint,
                        sink: sink
                    )
                    continuation.finish()
                } catch is CancellationError {
                    sink.debug(.failure, "cancelled")
                    continuation.yield(.state(.cancelled))
                    continuation.finish()
                } catch {
                    sink.debug(.failure, error.localizedDescription)
                    continuation.yield(.state(.failed(error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Planner 阶段拥有纯社交早停、元数据快照、模型规划、联网意图补全与澄清门禁。
    /// 返回 nil 表示已经发布终止事件，后续阶段不得访问 Repository 或 Provider。
    func runPlanningPhase(
        request: RAGServiceRequest,
        sink: RAGServiceEventSink
    ) async throws -> RAGPlanningPhaseOutput? {
        sink.yield(.state(.planning))
        sink.yield(.execution(.started(.planning)))
        if let terminal = RAGQueryGuidance.pureSocialResponse(
            question: request.rawQuestion,
            composerContext: request.composerContext
        ) {
            let plan = RAGQueryPlan(
                mode: .guidedDiscovery,
                semanticQuery: "",
                fallbackQuestions: terminal.suggestedActions.map(\.question),
                userVisiblePlan: .init(
                    scope: String.l10n("rag.workspace.guidance.scope"),
                    chips: [],
                    semantic: "",
                    planningNotes: [String.l10n("rag.workspace.guidance.socialPlan")]
                )
            )
            sink.yield(.plan(plan))
            sink.yield(.execution(.planningCompleted(plan)))
            sink.yield(.terminal(terminal))
            sink.yield(.state(.completed))
            return nil
        }
        // 同一轮只读一次快照：Planner 只消费精简库存摘要，Generator 仍使用完整快照。
        // 读取失败必须降级为空，不能因为可选聚合统计阻断正常检索与问答。
        let metadataSnapshot: KnowledgeBaseMetadataSnapshot?
        do {
            metadataSnapshot = try await metadataSnapshotProvider?.fetch()
        } catch {
            metadataSnapshot = nil
            AppLog.ai.warning("RAG metadata snapshot degraded: \(error.localizedDescription, privacy: .public)")
        }
        var hasPlanningReasoning = false
        let onReasoningDelta: (String) -> Void = { text in
            guard !text.isEmpty else { return }
            if !hasPlanningReasoning {
                hasPlanningReasoning = true
                sink.yield(.execution(.started(.planningReasoning)))
            }
            sink.yield(.execution(.reasoningDelta(.planningReasoning, text)))
        }
        var plan: RAGQueryPlan
        if let metadataAwarePlanner = planner as? any KnowledgeRAGMetadataAwareQueryPlanning {
            plan = try await metadataAwarePlanner.plan(
                question: request.rawQuestion,
                composerContext: request.composerContext,
                metadataSnapshot: metadataSnapshot,
                onReasoningDelta: onReasoningDelta,
                onDebugEvent: { stage, payload in
                    sink.debug(stage, "endpoint: \(request.debugEndpoint ?? "<unknown>")\n\n\(payload)")
                }
            )
        } else if let debuggablePlanner = planner as? any KnowledgeRAGDebuggableQueryPlanning {
            plan = try await debuggablePlanner.plan(
                question: request.rawQuestion,
                composerContext: request.composerContext,
                onReasoningDelta: onReasoningDelta,
                onDebugEvent: { stage, payload in
                    sink.debug(stage, "endpoint: \(request.debugEndpoint ?? "<unknown>")\n\n\(payload)")
                }
            )
        } else {
            plan = try await planner.plan(
                question: request.rawQuestion,
                composerContext: request.composerContext,
                onReasoningDelta: onReasoningDelta
            )
        }
        if hasPlanningReasoning {
            sink.yield(.execution(.reasoningCompleted(.planningReasoning)))
        }
        // Planner 是概率模型，可能漏报“最新 Issues”这类稳定的实时 GitHub 意图。
        // 执行层在这里补齐高置信请求，并只在 Composer 明确授权后保留普通 Web 查询。
        plan = RAGNetworkIntentResolver.resolve(
            question: request.rawQuestion,
            plan: plan,
            composerContext: request.composerContext
        )
        plan = RAGExplicitRepositoryPlanGuard.resolve(
            question: request.rawQuestion,
            plan: plan,
            composerContext: request.composerContext
        )
        plan.remoteContextRequests.removeAll {
            request.composerContext.disabledRemoteResources.contains($0.resource)
        }
        // RepoContext 目标只能来自本地唯一显式选择。Planner 不参与目标选择，即使返回了
        // 伪造字段也会被这里覆盖；不满足单项目条件时明确清空。
        if request.composerContext.deepThinkingEnabled,
           request.composerContext.explicitRepoIDs.count == 1,
           request.composerContext.explicitRepoReferences.count == 1,
           let repoID = request.composerContext.explicitRepoIDs.first,
           let reference = request.composerContext.explicitRepoReferences.first,
           reference.id == repoID {
            plan.repoContextRequest = RAGRepoContextRequest(
                repoID: repoID,
                repoFullName: reference.fullName,
                reason: String.l10n("rag.workspace.repoContext.planReason"),
                configuredTokenBudget: repoContextTokenBudget
            )
            if !plan.userVisiblePlan.planningNotes.contains(where: { $0 == String.l10n("rag.workspace.repoContext.planNote") }) {
                plan.userVisiblePlan.planningNotes = Array(
                    (plan.userVisiblePlan.planningNotes + [String.l10n("rag.workspace.repoContext.planNote")]).prefix(3)
                )
            }
        } else {
            plan.repoContextRequest = nil
        }
        sink.debug(.plan, """
        mode: \(plan.mode.rawValue)
        semanticQuery: \(plan.semanticQuery)
        filters: \(String(reflecting: plan.filters))
        candidateLimit: \(plan.candidateLimit.map(String.init) ?? "<default>")
        clarificationQuestion: \(plan.clarificationQuestion ?? "<none>")
        remoteContextRequests: \(plan.remoteContextRequests.map { "\($0.resource.rawValue): \($0.reason)" }.joined(separator: "\n"))
        webSearchRequests: \(plan.webSearchRequests.map { "\($0.query): \($0.reason)" }.joined(separator: "\n"))
        requiresLiveEvidence: \(plan.requiresLiveEvidence)
        repoContextRequest: \(String(reflecting: plan.repoContextRequest))
        analytics: \(String(reflecting: plan.analytics))
        """)
        sink.yield(.plan(plan))
        sink.yield(.execution(.planningCompleted(plan)))
        if plan.mode == .guidedDiscovery {
            sink.yield(.terminal(RAGQueryGuidance.guidedResponse(
                plan: plan,
                composerContext: request.composerContext
            )))
            sink.yield(.state(.completed))
            return nil
        }
        if plan.mode == .needsClarification {
            sink.yield(.state(.needsClarification(
                plan.clarificationQuestion ?? String.l10n("rag.core.service.clarificationFallback")
            )))
            return nil
        }
        return RAGPlanningPhaseOutput(plan: plan, metadataSnapshot: metadataSnapshot)
    }

    /// 洞察上下文位于本地检索之后：显式范围按用户选中的仓库读取，普通检索只读取
    /// 最终保留 bundle，且 Coordinator 固定使用 cache-only，不能为一次 RAG 问答额外联网。
    func runRepositoryInsightsPhase(
        request: RAGServiceRequest,
        candidates: [RAGRepoCandidate],
        retrieval: RAGRetrievalResult,
        sink: RAGServiceEventSink
    ) async throws -> RAGRepositoryInsightsPhaseOutput {
        guard let provider = repositoryInsightsProvider else {
            return RAGRepositoryInsightsPhaseOutput(documents: [], snapshots: [])
        }
        let repositories = RAGRepositoryInsightsTargetResolver.resolve(
            composerContext: request.composerContext,
            candidates: candidates,
            retrieval: retrieval
        )
        guard !repositories.isEmpty else {
            return RAGRepositoryInsightsPhaseOutput(documents: [], snapshots: [])
        }

        sink.yield(.execution(.started(.repositoryInsights)))
        sink.debug(.repositoryInsightsRequest, """
        mode: cache_only
        targetCount: \(repositories.count)
        repositoryIDs: \(repositories.map(\.id))
        repositories: \(repositories.map(\.fullName))
        configuredTokenBudget: \(repositoryInsightsTokenBudget)
        """)
        let result = await RAGRepositoryInsightsContextLoader(
            provider: provider,
            configuredTokenBudget: repositoryInsightsTokenBudget
        ).load(repositories: repositories)
        try Task.checkCancellation()
        sink.yield(.execution(.repositoryInsightsPrepared(result.snapshots)))
        sink.debug(.repositoryInsightsLoad, """
        requestedCount: \(repositories.count)
        loadedCount: \(result.documents.count)
        unavailableCount: \(result.snapshots.filter { $0.outcome != .success }.count)
        snapshots:
        \(result.snapshots.map {
            "\($0.repoFullName) outcome=\($0.outcome.rawValue) sourceHash=\($0.sourceHash ?? "<none>") xmlHash=\($0.xmlHash ?? "<none>") originalTokens=\($0.originalTokens)"
        }.joined(separator: "\n"))
        """)
        return RAGRepositoryInsightsPhaseOutput(
            documents: result.documents,
            snapshots: result.snapshots
        )
    }

    /// RepoContext 位于本地检索之后、联网之前。这样时间线顺序稳定，且代码上下文失败时
    /// 仍可保留本地分片、附件或后续联网证据继续回答。
    func runRepoContextPhase(
        request: RAGServiceRequest,
        plan: RAGQueryPlan,
        sink: RAGServiceEventSink
    ) async throws -> RAGRepoContextPhaseOutput {
        guard let repoRequest = plan.repoContextRequest else {
            return RAGRepoContextPhaseOutput(document: nil, snapshot: nil)
        }
        sink.yield(.execution(.started(.repoContext)))
        sink.debug(.repoContextRequest, """
        repoID: \(repoRequest.repoID)
        repoFullName: \(repoRequest.repoFullName)
        configuredTokenBudget: \(repoRequest.configuredTokenBudget)
        reason: \(repoRequest.reason)
        """)

        guard request.composerContext.deepThinkingEnabled,
              request.composerContext.explicitRepoIDs == [repoRequest.repoID],
              let provider = repoContextProvider,
              let repo = try await candidateRepository.fetchMentionRepos(ids: [repoRequest.repoID]).first,
              repo.fullName == repoRequest.repoFullName else {
            let snapshot = degradedRepoContextSnapshot(
                request: repoRequest,
                outcome: .degraded,
                reason: "single_repository_scope_required"
            )
            sink.yield(.execution(.repoContextCompleted(snapshot)))
            sink.debug(.repoContextResponse, "outcome: degraded\nreason: single_repository_scope_required")
            return RAGRepoContextPhaseOutput(document: nil, snapshot: snapshot)
        }

        do {
            let outcome = try await provider.contextOutcome(for: repo) { progress in
                sink.yield(.execution(.repoContextProgress(progress)))
            }
            switch outcome {
            case .success(let result):
                let trimmedXML = result.xml.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedXML.isEmpty,
                      let parsedXML = try? XMLDocument(xmlString: trimmedXML),
                      parsedXML.rootElement()?.name == "repository" else {
                    let snapshot = degradedRepoContextSnapshot(
                        request: repoRequest,
                        outcome: .degraded,
                        reason: "invalid_or_empty_repo_context_xml"
                    )
                    sink.yield(.execution(.repoContextCompleted(snapshot)))
                    sink.debug(
                        .repoContextResponse,
                        "outcome: degraded\nreason: invalid_or_empty_repo_context_xml"
                    )
                    return RAGRepoContextPhaseOutput(document: nil, snapshot: snapshot)
                }
                let hash = SHA256.hash(data: Data(result.xml.utf8)).map { String(format: "%02x", $0) }.joined()
                let snapshot = RAGRepoContextSnapshot(
                    repoID: repo.id,
                    repoFullName: repo.fullName,
                    commitSHA: result.metadata.commitSha,
                    contentHash: hash,
                    configuredTokenBudget: repoRequest.configuredTokenBudget,
                    originalTokens: TokenEstimator.estimate(text: result.xml),
                    sentTokens: 0,
                    cacheHit: result.cacheHit,
                    outcome: .success,
                    wasProjected: false,
                    projectionReason: nil,
                    citationMarker: nil,
                    preparedAt: .now
                )
                let document = RAGRepoContextDocument(snapshot: snapshot, xml: result.xml)
                sink.yield(.execution(.repoContextPrepared(snapshot)))
                sink.debug(.repoContextResponse, """
                outcome: success
                repoFullName: \(repo.fullName)
                commitSHA: \(result.metadata.commitSha)
                contentHash: \(hash)
                cacheHit: \(result.cacheHit)
                configuredTokenBudget: \(repoRequest.configuredTokenBudget)
                originalTokens: \(snapshot.originalTokens)
                """)
                return RAGRepoContextPhaseOutput(document: document, snapshot: snapshot)
            case .featureDisabled:
                let snapshot = degradedRepoContextSnapshot(
                    request: repoRequest,
                    outcome: .featureDisabled,
                    reason: "repo_context_feature_disabled"
                )
                sink.yield(.execution(.repoContextCompleted(snapshot)))
                sink.debug(.repoContextResponse, "outcome: feature_disabled")
                return RAGRepoContextPhaseOutput(document: nil, snapshot: snapshot)
            case .degraded(let reason):
                let snapshot = degradedRepoContextSnapshot(
                    request: repoRequest,
                    outcome: .degraded,
                    reason: String(describing: reason)
                )
                sink.yield(.execution(.repoContextCompleted(snapshot)))
                sink.debug(.repoContextResponse, "outcome: degraded\nreason: \(String(describing: reason))")
                return RAGRepoContextPhaseOutput(document: nil, snapshot: snapshot)
            }
        } catch is CancellationError {
            provider.cleanupTemporaryContextPreparation(for: repo)
            throw CancellationError()
        }
    }

    private func degradedRepoContextSnapshot(
        request: RAGRepoContextRequest,
        outcome: RAGRepoContextOutcome,
        reason: String
    ) -> RAGRepoContextSnapshot {
        RAGRepoContextSnapshot(
            repoID: request.repoID,
            repoFullName: request.repoFullName,
            commitSHA: nil,
            contentHash: nil,
            configuredTokenBudget: request.configuredTokenBudget,
            originalTokens: 0,
            sentTokens: 0,
            cacheHit: false,
            outcome: outcome,
            wasProjected: false,
            projectionReason: nil,
            degradationReason: reason,
            citationMarker: nil,
            preparedAt: .now
        )
    }

    /// Retrieval 阶段负责附件预处理、本地结构化分析、候选查询与混合召回；输出保留早停
    /// 原因，但把最终“是否足够回答”的决定交给 Prompt 证据门禁。
    func runRetrievalPhase(
        request: RAGServiceRequest,
        plan: RAGQueryPlan,
        sink: RAGServiceEventSink
    ) async throws -> RAGRetrievalPhaseOutput {
        // 附件属于本轮独立证据，必须在知识库早停判断之前处理；否则“知识库无命中
        // 但用户上传了文本附件”的合法问答会被错误截断。
        var attachmentContexts = try await attachmentProcessor.process(request.composerContext.attachments)
        attachmentContexts.append(contentsOf: request.composerContext.pastedGitHubLinks.map { reference in
            RAGAttachmentContext(
                attachmentID: UUID(),
                filename: "GitHub: \(reference.owner)/\(reference.repo)",
                // 这是送入 Prompt 的证据协议，不是 UI 固定文案。维持稳定中文标签，
                // 避免历史 Debug / 回放随 App locale 改变而产生不同语义。
                content: "用户显式提供 GitHub 链接：\(reference.url.absoluteString)；Starcat 关系：\(reference.relation.rawValue)",
                supportsFactualAnswer: false
            )
        })

        sink.yield(.state(.retrieving))
        sink.yield(.execution(.started(.retrieval)))
        let analyticsResult: KnowledgeBaseAnalyticsResult?
        if let analyticsPlan = plan.analytics, let analyticsExecutor {
            analyticsResult = try await analyticsExecutor.execute(plan: analyticsPlan, filters: plan.filters)
            sink.debug(.structuredAnalytics, """
            validated_analytics:
            dimension: \(analyticsPlan.dimension?.rawValue ?? "<none>")
            measure: \(analyticsPlan.measure.rawValue)
            direction: \(analyticsPlan.direction.rawValue)
            limit: \(analyticsPlan.limit)

            enforced_scope: library_state = in_library
            filters: \(String(reflecting: plan.filters))
            raw_sql: not recorded; local executor maps the validated DSL to fixed SQL.

            result:
            \(analyticsResult?.promptContext() ?? "<none>")
            """)
        } else {
            analyticsResult = nil
        }
        // analytics 已由固定聚合 SQL 给出完整结果；再加载 1,000 个候选并塞入
        // structured rows 既浪费 I/O，也会让“排行”答案混入无关的项目清单。
        let candidates: [RAGRepoCandidate]
        if plan.analytics == nil {
            candidates = try await candidateRepository.fetchCandidates(
                plan: plan,
                explicitRepoIDs: request.composerContext.explicitRepoIDs,
                explicitMode: request.composerContext.explicitRepoMode
            )
        } else {
            candidates = []
        }
        sink.debug(.candidates, candidates.map { candidate in
            """
            repo: \(candidate.repo.fullName)
            status: \(candidate.status.rawValue)
            tags: \(candidate.tagNames.joined(separator: ", "))
            """
        }.joined(separator: "\n---\n"))
        sink.yield(.execution(.retrieval(.candidateSelectionCompleted(candidates.count))))
        let hasScopedQuery = plan.filters.hasEffectiveConditions
            || !request.composerContext.explicitRepoIDs.isEmpty
        var localMissingReasonKey: String?
        let retrieval: RAGRetrievalResult
        if candidates.isEmpty {
            retrieval = RAGRetrievalResult(
                candidates: [],
                bundles: [],
                childHits: [],
                diagnostics: retriever.diagnostics(candidateRepoCount: 0, outcome: .noCandidates)
            )
            let missingReasonKey = hasScopedQuery
                ? "rag.workspace.execution.noCandidates"
                : "rag.workspace.execution.noKnowledgeRepos"
            localMissingReasonKey = missingReasonKey
            sink.yield(.execution(.terminated(.retrieval, summary: String.l10n(missingReasonKey))))
        } else if plan.mode == .structuredOnly {
            retrieval = RAGRetrievalResult(
                candidates: candidates,
                bundles: [],
                childHits: [],
                diagnostics: retriever.diagnostics(
                    candidateRepoCount: candidates.count,
                    outcome: .skippedStructured
                )
            )
            sink.yield(.execution(.retrievalCompleted(retrieval)))
        } else if !retriever.hasEnabledSources {
            retrieval = RAGRetrievalResult(
                candidates: candidates,
                bundles: [],
                childHits: [],
                diagnostics: retriever.diagnostics(
                    candidateRepoCount: candidates.count,
                    outcome: .sourcesDisabled
                )
            )
            localMissingReasonKey = "rag.workspace.execution.noEvidence"
            sink.yield(.execution(.terminated(
                .retrieval,
                summary: String.l10n("rag.workspace.execution.noEvidence")
            )))
        } else if try await retriever.hasReadyChunks(repoIDs: candidates.map(\.repo.id)) {
            retrieval = try await retriever.retrieve(
                semanticQuery: plan.semanticQuery,
                keywordQueries: plan.keywordQueries,
                candidates: candidates,
                explicitMode: request.composerContext.explicitRepoMode,
                explicitRepoIDs: request.composerContext.explicitRepoIDs,
                progress: { progress in sink.yield(.execution(.retrieval(progress))) }
            )
            if retrieval.bundles.isEmpty {
                localMissingReasonKey = "rag.workspace.execution.noEvidence"
                sink.yield(.execution(.terminated(
                    .retrieval,
                    summary: String.l10n("rag.workspace.execution.noEvidence")
                )))
            } else {
                sink.yield(.execution(.retrievalCompleted(retrieval)))
            }
        } else {
            retrieval = RAGRetrievalResult(
                candidates: candidates,
                bundles: [],
                childHits: [],
                diagnostics: retriever.diagnostics(
                    candidateRepoCount: candidates.count,
                    outcome: .noReadyChunks
                )
            )
            localMissingReasonKey = "rag.workspace.execution.noIndex"
            sink.yield(.execution(.terminated(
                .retrieval,
                summary: String.l10n("rag.workspace.execution.noIndex")
            )))
        }
        let evidenceDetails: String = retrieval.bundles.map { bundle in
            let hits = bundle.matchedChildren.map { hit in
                "\(hit.kind.rawValue) score=\(hit.score) source=\(hit.chunk.source.rawValue) section=\(hit.chunk.sectionPath)"
            }.joined(separator: "\n")
            return "repo: \(bundle.candidate.repo.fullName)\nscore: \(bundle.score)\nhits:\n\(hits)"
        }.joined(separator: "\n---\n")
        if sink.isDebugEnabled {
            if let rerank = retrieval.diagnostics?.rerank {
                sink.yield(.debug(RAGDebugEvent(
                    stage: .rerank,
                    elapsedSeconds: Date().timeIntervalSince(sink.startedAt),
                    payload: "",
                    rerankPayload: RAGRerankDebugPayload(diagnostics: rerank)
                )))
            }
            sink.yield(.debug(RAGDebugEvent(
                stage: .retrieval,
                elapsedSeconds: Date().timeIntervalSince(sink.startedAt),
                payload: "",
                retrievalPayload: RAGRetrievalDebugPayload(
                    diagnostics: retrieval.diagnostics,
                    evidenceDetails: evidenceDetails
                )
            )))
        }
        sink.yield(.retrieval(retrieval))
        return RAGRetrievalPhaseOutput(
            attachmentContexts: attachmentContexts,
            analyticsResult: analyticsResult,
            candidates: candidates,
            retrieval: retrieval,
            hasScopedQuery: hasScopedQuery,
            localMissingReasonKey: localMissingReasonKey
        )
    }

    /// Remote Context 阶段独占授权等待与两类网络 Provider；输出只保留经用户许可后的计划
    /// 和临时证据块，不负责判断这些证据是否足以回答。
    func runRemoteContextPhase(
        request: RAGServiceRequest,
        plan initialPlan: RAGQueryPlan,
        candidates: [RAGRepoCandidate],
        retrieval: RAGRetrievalResult,
        consent: RAGRemoteContextConsent?,
        sink: RAGServiceEventSink
    ) async throws -> RAGRemoteContextPhaseOutput {
        var plan = initialPlan
        var remoteBlocks: [RAGRemoteContextBlock] = []
        let plannedRemoteRequests = plan.remoteContextRequests
        let plannedWebSearchRequests = plan.webSearchRequests
        let resolvedRemoteWorkItems = Self.resolveRemoteWorkItems(
            requests: plannedRemoteRequests,
            candidates: candidates,
            retrieval: retrieval,
            explicitRepoIDs: request.composerContext.explicitRepoIDs
        )
        if !resolvedRemoteWorkItems.isEmpty || !plannedWebSearchRequests.isEmpty {
            // 联网步骤必须在授权等待和真实请求之前出现，用户才能审计“为什么暂停”以及
            // 后续到底访问了什么。Composer 联网开关本身就是本轮显式授权，开启时不再
            // 为结构化 GitHub 请求重复弹确认；未开启仍保留 repo × resource 细粒度确认。
            sink.yield(.execution(.started(.remoteContext)))
            let approvedWorkItems: [RAGResolvedRemoteWorkItem]
            if request.composerContext.webSearchEnabled {
                approvedWorkItems = resolvedRemoteWorkItems
            } else if !resolvedRemoteWorkItems.isEmpty {
                sink.yield(.state(.awaitingRemoteContextConfirmation))
                sink.yield(.remoteContextConfirmation(resolvedRemoteWorkItems))
                let approvedIDs = try await consent?.wait() ?? []
                approvedWorkItems = resolvedRemoteWorkItems.filter { approvedIDs.contains($0.id) }
            } else {
                approvedWorkItems = []
            }
            sink.yield(.execution(.remoteContextPrepared(approvedWorkItems)))
            sink.yield(.execution(.webSearchPrepared(plannedWebSearchRequests)))
            if approvedWorkItems.isEmpty && plannedWebSearchRequests.isEmpty {
                plan.remoteContextRequests = []
                sink.yield(.execution(.terminated(
                    .remoteContext,
                    summary: String.l10n("rag.workspace.execution.remoteSkipped")
                )))
            } else {
                plan.remoteContextRequests = Self.uniqueRequests(in: approvedWorkItems)
                sink.yield(.state(.fetchingRemoteContext))
                let totalNetworkRequests = approvedWorkItems.count + plannedWebSearchRequests.count
                if !approvedWorkItems.isEmpty {
                    let onGitHubProgress: @Sendable (RAGRemoteContextFetchProgress) -> Void = { progress in
                        sink.yield(.execution(.remoteContextProgress(
                            completed: progress.completed,
                            total: totalNetworkRequests
                        )))
                    }
                    let githubBlocks: [RAGRemoteContextBlock]
                    if let provider = remoteContextProvider as? any KnowledgeRAGDebuggableRemoteContextProviding {
                        githubBlocks = await provider.fetch(
                            workItems: approvedWorkItems,
                            onProgress: onGitHubProgress,
                            onDebug: { event in sink.debug(event.stage, event.payload) }
                        )
                    } else {
                        githubBlocks = await remoteContextProvider.fetch(
                            workItems: approvedWorkItems,
                            onProgress: onGitHubProgress
                        )
                    }
                    remoteBlocks.append(contentsOf: githubBlocks)
                }
                if !plannedWebSearchRequests.isEmpty {
                    let githubRequestCount = approvedWorkItems.count
                    let webBlocks = await webSearchProvider.fetch(
                        requests: plannedWebSearchRequests,
                        onProgress: { progress in
                            sink.yield(.execution(.remoteContextProgress(
                                completed: githubRequestCount + progress.completed,
                                total: totalNetworkRequests
                            )))
                        }
                    )
                    remoteBlocks.append(contentsOf: webBlocks)
                }
                sink.debug(.remoteContext, remoteBlocks.map { block in
                    """
                    title: \(block.title)
                    sourceURL: \(block.sourceURL?.absoluteString ?? "<none>")
                    error: \(block.errorMessage ?? "<none>")
                    content:
                    \(block.content)
                    """
                }.joined(separator: "\n---\n"))
                sink.yield(.remoteContext(remoteBlocks))
                sink.yield(.execution(.remoteContextCompleted(remoteBlocks)))
            }
        }
        return RAGRemoteContextPhaseOutput(
            plan: plan,
            blocks: remoteBlocks,
            plannedRequests: plannedRemoteRequests,
            resolvedWorkItems: resolvedRemoteWorkItems
        )
    }

    /// Prompt 阶段拥有最终证据门禁与 token packing。返回 nil 表示已经发布可解释的本地终止
    /// 状态；Generation 因而永远只接收至少一种合法证据且已完成预算裁剪的 Prompt。
    func runPromptPhase(
        request: RAGServiceRequest,
        plan: RAGQueryPlan,
        retrieval initialRetrieval: RAGRetrievalResult,
        metadataSnapshot: KnowledgeBaseMetadataSnapshot?,
        analyticsResult: KnowledgeBaseAnalyticsResult?,
        repositoryInsightsDocuments: [RAGRepositoryInsightsDocument],
        repositoryInsightsSnapshots: [RAGRepositoryInsightsSnapshot],
        repoContextDocument: RAGRepoContextDocument?,
        remoteBlocks: [RAGRemoteContextBlock],
        attachmentContexts: [RAGAttachmentContext],
        history: [AIChatMessage],
        candidates: [RAGRepoCandidate],
        hasScopedQuery: Bool,
        localMissingReasonKey: String?,
        plannedRemoteRequests: [RAGRemoteContextRequest],
        resolvedRemoteWorkItems: [RAGResolvedRemoteWorkItem],
        sink: RAGServiceEventSink
    ) -> RAGPromptPhaseOutput? {
        var retrieval = initialRetrieval
        let hasStructuredEvidence = plan.mode == .structuredOnly && !retrieval.candidates.isEmpty
        let hasAnalyticsEvidence = analyticsResult != nil
        let hasLocalEvidence = !retrieval.bundles.isEmpty
        let hasRepositoryInsightsCandidate = !repositoryInsightsDocuments.isEmpty
        let hasRepoContextEvidence = repoContextDocument?.snapshot.outcome == .success
            && repoContextDocument?.xml.isEmpty == false
        let hasRemoteEvidence = remoteBlocks.contains {
            $0.outcome == .success && $0.resultCount > 0 && !$0.content.isEmpty
        }
        let hasAttachmentEvidence = attachmentContexts.contains {
            $0.supportsFactualAnswer && (!$0.content.isEmpty || $0.imageData != nil)
        }
        if plan.requiresLiveEvidence, !hasRemoteEvidence {
            completeRepositoryInsights(
                loadedSnapshots: repositoryInsightsSnapshots,
                projectedDocuments: [],
                missingProjectionReason: "live_evidence_gate_rejected",
                sink: sink
            )
            let answerKey = remoteBlocks.contains(where: { $0.outcome == .failed })
                ? "rag.workspace.guidance.remoteFailedReply"
                : "rag.workspace.guidance.remoteEmptyReply"
            sink.yield(.terminal(RAGQueryGuidance.noEvidenceResponse(
                plan: plan,
                composerContext: request.composerContext,
                answerKey: answerKey
            )))
            sink.yield(.state(.noRelevantChunks))
            return nil
        }
        guard hasAnalyticsEvidence || hasStructuredEvidence || hasLocalEvidence
                || hasRepositoryInsightsCandidate || hasRepoContextEvidence
                || hasRemoteEvidence || hasAttachmentEvidence
        else {
            completeRepositoryInsights(
                loadedSnapshots: repositoryInsightsSnapshots,
                projectedDocuments: [],
                missingProjectionReason: "no_usable_artifact",
                sink: sink
            )
            let answerKey: String
            let terminalState: RAGAnswerState
            if localMissingReasonKey == "rag.workspace.execution.noIndex" {
                answerKey = "rag.workspace.guidance.noIndexReply"
                terminalState = .noIndex
            } else if candidates.isEmpty {
                answerKey = hasScopedQuery
                    ? "rag.workspace.guidance.noCandidatesReply"
                    : "rag.workspace.guidance.noKnowledgeReposReply"
                terminalState = hasScopedQuery ? .noCandidates : .noKnowledgeRepos
            } else if !plannedRemoteRequests.isEmpty && resolvedRemoteWorkItems.isEmpty {
                answerKey = "rag.workspace.guidance.remoteScopeRequiredReply"
                terminalState = .noRelevantChunks
            } else if !remoteBlocks.isEmpty {
                answerKey = remoteBlocks.contains(where: { $0.outcome == .failed })
                    ? "rag.workspace.guidance.remoteFailedReply"
                    : "rag.workspace.guidance.remoteEmptyReply"
                terminalState = .noRelevantChunks
            } else {
                answerKey = "rag.workspace.guidance.noEvidenceReply"
                terminalState = .noRelevantChunks
            }
            sink.yield(.terminal(RAGQueryGuidance.noEvidenceResponse(
                plan: plan,
                composerContext: request.composerContext,
                answerKey: answerKey
            )))
            sink.yield(.state(terminalState))
            return nil
        }
        if repoContextDocument != nil {
            sink.yield(.execution(.repoContextProjectionStarted))
        }
        if !repositoryInsightsDocuments.isEmpty {
            sink.yield(.execution(.repositoryInsightsProjectionStarted))
        }
        let prompt = promptBuilder.build(
            question: request.rawQuestion,
            plan: plan,
            retrieval: retrieval,
            metadataSnapshot: metadataSnapshot,
            analyticsResult: analyticsResult,
            repositoryInsightsDocuments: repositoryInsightsDocuments,
            repoContextDocument: repoContextDocument,
            remoteBlocks: remoteBlocks,
            attachmentContexts: attachmentContexts,
            history: history,
            contextWindowTokens: generatorParameters.resolvedContextWindowTokens,
            maximumOutputTokens: generatorParameters.maxCompletionTokens
        )
        // 极小模型窗口或损坏 XML 可能让投影失败。无论是否还有其它证据，都先把
        // RepoContext 明确收口为 degraded，避免时间线被后续步骤隐式完成后伪装成功。
        if prompt.repoContextDocument == nil, let source = repoContextDocument {
            var degraded = source.snapshot
            degraded.sentTokens = 0
            degraded.outcome = .degraded
            degraded.wasProjected = false
            degraded.projectionReason = nil
            degraded.degradationReason = "total_context_projection_unavailable"
            degraded.citationMarker = nil
            sink.debug(.repoContextProjection, """
            repoFullName: \(degraded.repoFullName)
            outcome: degraded
            reason: total_context_projection_unavailable
            """)
            sink.yield(.execution(.repoContextCompleted(degraded)))
        }
        completeRepositoryInsights(
            loadedSnapshots: repositoryInsightsSnapshots,
            projectedDocuments: prompt.repositoryInsightsDocuments,
            missingProjectionReason: prompt.repositoryInsightsOmissionReason
                ?? RAGRepositoryInsightsReason.totalContextProjectionUnavailable,
            sink: sink
        )
        if !prompt.repositoryInsightsDocuments.isEmpty {
            sink.yield(.repositoryInsights(prompt.repositoryInsightsDocuments))
        }
        // RepoContext 是唯一证据时必须回到无证据门禁，不能把没有 XML 的 Prompt
        // 交给 Generator 自由回答。
        let hasNonRepoEvidence = hasAnalyticsEvidence || hasStructuredEvidence || hasLocalEvidence
            || hasRemoteEvidence || hasAttachmentEvidence
        guard hasNonRepoEvidence || !prompt.repositoryInsightsDocuments.isEmpty
                || prompt.repoContextDocument != nil
        else {
            sink.yield(.terminal(RAGQueryGuidance.noEvidenceResponse(
                plan: plan,
                composerContext: request.composerContext,
                answerKey: "rag.workspace.guidance.noEvidenceReply"
            )))
            sink.yield(.state(.noRelevantChunks))
            return nil
        }
        if let projected = prompt.repoContextDocument {
            sink.debug(.repoContextProjection, """
            repoFullName: \(projected.snapshot.repoFullName)
            configuredTokenBudget: \(projected.snapshot.configuredTokenBudget)
            originalTokens: \(projected.snapshot.originalTokens)
            sentTokens: \(projected.snapshot.sentTokens)
            wasProjected: \(projected.snapshot.wasProjected)
            reason: \(projected.snapshot.projectionReason ?? "<none>")
            """)
            sink.yield(.repoContext(projected))
            sink.yield(.execution(.repoContextCompleted(projected.snapshot)))
        }
        // 最终 evidence token 预算发生在 Retriever 之后。把裁剪结论回写到同一份
        // 脱敏轨迹并再次通知 UI，当前会话与持久化执行轨迹才会看到一致的筛除原因。
        if !prompt.evidenceTokenLimitedChunkIDs.isEmpty {
            retrieval.trace?.markEvidenceTokenLimited(chunkIDs: prompt.evidenceTokenLimitedChunkIDs)
            sink.yield(.retrieval(retrieval))
        }
        if let metadataSnapshot { sink.yield(.metadataSnapshot(metadataSnapshot)) }
        sink.yield(.contextUsage(prompt.contextUsage))
        let evidenceCount = retrieval.bundles.count
            + (hasStructuredEvidence ? retrieval.candidates.count : 0)
            + remoteBlocks.filter { $0.outcome == .success && $0.resultCount > 0 }.count
            + attachmentContexts.filter(\.supportsFactualAnswer).count
            + prompt.repositoryInsightsDocuments.count
            + (prompt.repoContextDocument == nil ? 0 : 1)
        return RAGPromptPhaseOutput(
            prompt: prompt,
            retrieval: retrieval,
            evidenceCount: evidenceCount
        )
    }

    /// 将 Builder 的最终投影结果回写到审计快照。Debug 与会话历史只记录 hash/token，
    /// 不复制 XML 正文；成功加载但未进入 Prompt 的 Artifact 必须明确标记为 degraded。
    private func completeRepositoryInsights(
        loadedSnapshots: [RAGRepositoryInsightsSnapshot],
        projectedDocuments: [RAGRepositoryInsightsDocument],
        missingProjectionReason: String,
        sink: RAGServiceEventSink
    ) {
        guard !loadedSnapshots.isEmpty else { return }
        let projectedByRepoID = Dictionary(
            uniqueKeysWithValues: projectedDocuments.map { ($0.snapshot.repoID, $0.snapshot) }
        )
        let completedSnapshots = loadedSnapshots.map { loaded in
            if let projected = projectedByRepoID[loaded.repoID] {
                return projected
            }
            guard loaded.outcome == .success else { return loaded }
            var degraded = loaded
            degraded.sentTokens = 0
            degraded.outcome = .degraded
            degraded.wasProjected = false
            degraded.projectionReason = nil
            degraded.degradationReason = missingProjectionReason
            degraded.citationMarker = nil
            return degraded
        }
        sink.debug(.repositoryInsightsProjection, """
        completedCount: \(completedSnapshots.count)
        sentCount: \(completedSnapshots.filter { $0.outcome == .success && $0.sentTokens > 0 }.count)
        snapshots:
        \(completedSnapshots.map {
            "\($0.repoFullName) outcome=\($0.outcome.rawValue) originalTokens=\($0.originalTokens) sentTokens=\($0.sentTokens) projected=\($0.wasProjected) reason=\($0.projectionReason ?? $0.degradationReason ?? "<none>") citation=\($0.citationMarker ?? "<none>")"
        }.joined(separator: "\n"))
        """)
        sink.yield(.execution(.repositoryInsightsCompleted(completedSnapshots)))
    }

    /// Generation 阶段只消费已经完成预算裁剪的 Prompt，不再读取 Planner、Repository 或
    /// 联网 Provider。这样可独立验证输出上限、reasoning/delta 顺序与 citation 映射。
    func runGenerationPhase(
        prompt: RAGPromptBuildResult,
        attachmentContexts: [RAGAttachmentContext],
        plan: RAGQueryPlan,
        evidenceCount: Int,
        debugEndpoint: String?,
        sink: RAGServiceEventSink
    ) async throws {
        sink.yield(.state(.generating))
        sink.yield(.execution(.started(.generation)))
        sink.yield(.execution(.generationStarted(evidenceCount: evidenceCount)))
        // Provider 不一定会主动把 max token 限制在 Context Window 内。这里用同一份
        // 预算快照收紧输出上限，确保“输入 + 预留输出”不会超过模型窗口。
        var generationParameters = generatorParameters
        generationParameters.maxCompletionTokens = min(
            generationParameters.maxCompletionTokens,
            prompt.contextUsage.reservedOutputTokens
        )
        let chatRequest = AIChatRequest(
            systemPrompt: prompt.systemPrompt,
            userPrompt: prompt.userPrompt,
            history: prompt.history,
            images: attachmentContexts.compactMap { context in
                guard let data = context.imageData, let contentType = context.contentType else { return nil }
                return AIChatImageInput(data: data, contentType: contentType)
            },
            // selectedModelID 是 UI 的 provider::model 标识，依赖容器已经把它
            // 解析为真实模型名，不能把复合 id 直接发给 OpenAI-compatible API。
            model: generatorModel,
            parameters: generationParameters,
            usageContext: AIUsageContext(feature: .rag, phase: "answer")
        )
        sink.debug(.prompt, """
        endpoint: \(debugEndpoint ?? "<unknown>")
        model: \(chatRequest.model)
        parameters: \(String(reflecting: chatRequest.parameters))
        images: \(chatRequest.images.map { "\($0.contentType) \($0.data.count) bytes" })

        systemPrompt:
        \(chatRequest.systemPrompt)

        history:
        \(chatRequest.history.enumerated().map { "[\($0.offset)] \($0.element.role.rawValue):\n\($0.element.content)" }.joined(separator: "\n\n"))

        userPrompt:
        \(chatRequest.userPrompt)
        """)
        var answer = ""
        var responseModel = chatRequest.model
        var hasAnswerReasoning = false
        var answerReasoningCompleted = false
        for try await event in generatorClient.chatStream(request: chatRequest) {
            try Task.checkCancellation()
            switch event {
            case .reasoningDelta(let text):
                guard !text.isEmpty else { continue }
                if !hasAnswerReasoning {
                    hasAnswerReasoning = true
                    sink.yield(.execution(.started(.answerReasoning)))
                }
                sink.yield(.execution(.reasoningDelta(.answerReasoning, text)))
            case .reasoningCompleted:
                guard hasAnswerReasoning, !answerReasoningCompleted else { continue }
                answerReasoningCompleted = true
                sink.yield(.execution(.reasoningCompleted(.answerReasoning)))
            case .delta(let text):
                answer += text
                sink.yield(.delta(text))
            case .completed(let response):
                responseModel = response.model
                if answer.isEmpty { answer = response.content }
            }
        }
        if hasAnswerReasoning, !answerReasoningCompleted {
            sink.yield(.execution(.reasoningCompleted(.answerReasoning)))
        }
        let citations = promptBuilder.citationsUsed(in: answer, prompt: prompt)
        sink.debug(.response, """
        model: \(responseModel)
        citations: \(citations.map(\.repoFullName))

        content:
        \(answer)
        """)
        sink.yield(.state(.completed))
        sink.yield(.execution(.generationCompleted(citationCount: citations.count)))
        sink.yield(.completed(answer: answer, model: responseModel, citations: citations, plan: plan))
    }

    /// 远程范围只接受用户显式仓库或本轮真实命中的 bundle。候选 SQL 列表可能很大，也可能
    /// 只是过滤结果；直接取前五个会把一次模糊联网意图扩散到用户没有确认的仓库。
    private static func resolveRemoteWorkItems(
        requests: [RAGRemoteContextRequest],
        candidates: [RAGRepoCandidate],
        retrieval: RAGRetrievalResult,
        explicitRepoIDs: [Int64]
    ) -> [RAGResolvedRemoteWorkItem] {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.repo.id, $0) })
        let targets: [RAGRepoCandidate]
        if !explicitRepoIDs.isEmpty {
            targets = explicitRepoIDs.compactMap { candidateByID[$0] }
        } else {
            var seen = Set<Int64>()
            targets = retrieval.bundles.compactMap { bundle in
                seen.insert(bundle.candidate.repo.id).inserted ? bundle.candidate : nil
            }
        }
        guard !targets.isEmpty else { return [] }

        return requests.enumerated().flatMap { requestIndex, request in
            targets.prefix(request.maxRepos).map { candidate in
                RAGResolvedRemoteWorkItem(
                    id: "\(candidate.repo.id):\(request.resource.rawValue):\(requestIndex)",
                    candidate: candidate,
                    request: request
                )
            }
        }
    }

    private static func uniqueRequests(in workItems: [RAGResolvedRemoteWorkItem]) -> [RAGRemoteContextRequest] {
        var requests: [RAGRemoteContextRequest] = []
        for workItem in workItems where !requests.contains(workItem.request) {
            requests.append(workItem.request)
        }
        return requests
    }

    /// 将已离开 recent window 的消息压缩为可持久化语义摘要。该调用不经过 Planner、检索、
    /// 远程上下文或附件，避免为压缩额外读取知识库；失败由 ViewModel 回退到本地受限摘要，
    /// 绝不能阻断用户本轮提问。
    func compressConversationHistory(
        existingSummary: String?,
        messages: [RAGStoredMessage],
        isDebugEnabled: Bool,
        debugEndpoint: String?
    ) async throws -> RAGConversationCompressionResult {
        guard !messages.isEmpty else {
            return .completed(
                summary: existingSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                debugEvents: []
            )
        }
        let startedAt = Date()
        var parameters = generatorParameters
        parameters.temperature = 0.1
        parameters.topP = 0.9
        let requestedOutputTokens = min(max(parameters.maxCompletionTokens, 512), 2_000)
        var compressionBudget = RAGContextBudget(
            contextWindowTokens: generatorParameters.resolvedContextWindowTokens,
            requestedOutputTokens: requestedOutputTokens
        )
        // 压缩请求与主问答使用同一模型窗口。先预留输出并裁掉输入，避免 4K 模型仍收到
        // “8K 输入 + 2K 输出”的压缩调用而超窗。
        parameters.maxCompletionTokens = compressionBudget.reservedOutputTokens
        parameters.streamEnabled = false
        let systemPrompt = compressionBudget.consume(
            compressorPromptConfiguration.renderedSystemPrompt(placeholders: [
                "outputLanguage": outputLanguage,
            ]),
            kind: .system
        )
        let request = AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: RAGConversationContextCompressor.renderedUserPrompt(
                configuration: compressorPromptConfiguration,
                existingSummary: existingSummary,
                messages: messages,
                tokenBudget: compressionBudget.remainingInputTokens
            ),
            model: generatorModel,
            parameters: parameters,
            usageContext: AIUsageContext(feature: .rag, phase: "compression")
        )
        var debugEvents: [RAGDebugEvent] = []
        if isDebugEnabled {
            debugEvents.append(RAGDebugEvent(
                stage: .compressionPrompt,
                elapsedSeconds: 0,
                payload: """
                endpoint: \(debugEndpoint ?? "<unknown>")
                model: \(request.model)
                parameters: \(String(reflecting: request.parameters))

                systemPrompt:
                \(request.systemPrompt)

                userPrompt:
                \(request.userPrompt)
                """
            ))
        }
        do {
            let response = try await generatorClient.chat(request: request)
            try Task.checkCancellation()
            let summary = RAGContextBudget.clip(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines),
                toTokenBudget: RAGConversationHistoryBuilder.summaryTokenLimit(
                    contextWindowTokens: generatorParameters.resolvedContextWindowTokens,
                    maximumOutputTokens: generatorParameters.maxCompletionTokens
                )
            )
            guard !summary.isEmpty else { throw AIClientError.emptyResponse }
            if isDebugEnabled {
                debugEvents.append(RAGDebugEvent(
                    stage: .compressionResponse,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    payload: """
                    model: \(response.model)

                    content:
                    \(response.content)

                    normalizedSummary:
                    \(summary)
                    """
                ))
            }
            return .completed(summary: summary, debugEvents: debugEvents)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isDebugEnabled {
                debugEvents.append(RAGDebugEvent(
                    stage: .failure,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    payload: String(
                        format: String.l10n("rag.core.service.debug.compressionFallbackFormat"),
                        error.localizedDescription
                    )
                ))
            }
            return .failed(debugEvents: debugEvents)
        }
    }

    /// 基于首个用户问题生成会话标题。
    ///
    /// 这里故意不复用 `ask`：标题不需要 Planner、知识库检索、远程上下文或问答历史，
    /// 既避免额外的 RAG 成本，也确保不会把知识库内容发送给这次轻量调用。
    func generateConversationTitle(
        firstQuestion: String,
        isDebugEnabled: Bool,
        debugEndpoint: String?
    ) async -> RAGConversationTitleGenerationResult {
        let startedAt = Date()
        var parameters = generatorParameters
        parameters.temperature = 0.2
        parameters.topP = 0.9
        parameters.maxCompletionTokens = 64
        parameters.streamEnabled = false
        let request = AIChatRequest(
            systemPrompt: titlePromptConfiguration.renderedSystemPrompt(placeholders: [
                "outputLanguage": outputLanguage,
            ]),
            userPrompt: titlePromptConfiguration.renderedUserPrompt(placeholders: [
                "firstQuestion": firstQuestion,
            ]),
            model: generatorModel,
            parameters: parameters,
            usageContext: AIUsageContext(feature: .rag, phase: "title")
        )
        var debugEvents: [RAGDebugEvent] = []
        if isDebugEnabled {
            debugEvents.append(RAGDebugEvent(
                stage: .titlePrompt,
                elapsedSeconds: 0,
                payload: """
                endpoint: \(debugEndpoint ?? "<unknown>")
                model: \(request.model)
                parameters: \(String(reflecting: request.parameters))

                systemPrompt:
                \(request.systemPrompt)

                userPrompt:
                \(request.userPrompt)
                """
            ))
        }

        do {
            let response = try await generatorClient.chat(request: request)
            try Task.checkCancellation()
            let title = Self.normalizedConversationTitle(response.content)
            guard !title.isEmpty else {
                if isDebugEnabled {
                    debugEvents.append(RAGDebugEvent(
                        stage: .failure,
                        elapsedSeconds: Date().timeIntervalSince(startedAt),
                        payload: String.l10n("rag.core.service.debug.titleEmpty")
                    ))
                }
                return .failed(debugEvents: debugEvents)
            }
            if isDebugEnabled {
                debugEvents.append(RAGDebugEvent(
                    stage: .titleResponse,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    payload: """
                    model: \(response.model)

                    content:
                    \(response.content)

                    normalizedTitle:
                    \(title)
                    """
                ))
            }
            return .completed(title: title, debugEvents: debugEvents)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if isDebugEnabled {
                debugEvents.append(RAGDebugEvent(
                    stage: .failure,
                    elapsedSeconds: Date().timeIntervalSince(startedAt),
                    payload: String(
                        format: String.l10n("rag.core.service.debug.titleFailureFormat"),
                        error.localizedDescription
                    )
                ))
            }
            return .failed(debugEvents: debugEvents)
        }
    }

    /// 面向知识库管理器的召回验证入口：绕过 Planner 与回答生成，只复用真实混合检索。
    func testRetrieval(query: String) async throws -> RAGRetrievalResult {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return RAGRetrievalResult(candidates: [], bundles: [], childHits: []) }
        let candidates = try await candidateRepository.fetchCandidates(
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: normalized),
            explicitRepoIDs: [],
            explicitMode: .only
        )
        guard try await retriever.hasReadyChunks(repoIDs: candidates.map(\.repo.id)) else {
            return RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
        }
        let result = try await retriever.retrieve(
            semanticQuery: normalized,
            candidates: candidates,
            explicitMode: .only,
            explicitRepoIDs: []
        )
        return RAGRetrievalResult(
            candidates: result.candidates,
            bundles: result.bundles,
            childHits: Array(result.childHits.prefix(Self.retrievalTestMaxHits))
        )
    }

    /// 防御性清理模型偶发的引用符、换行和过长输出；不会改写标题语义。
    private static func normalizedConversationTitle(_ rawTitle: String) -> String {
        let firstLine = rawTitle
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`"))
        return String(trimmed.prefix(48))
    }

}

/// 显式限定仓库后，Planner 只能决定“怎么检索”，不能在尚未检索时断言仓库没有证据。
/// 纯寒暄已在进入 Planner 前由 `RAGQueryGuidance.pureSocialResponse` 终止，因此这里仅恢复
/// 修正显式仓库范围内无法落到真实仓库证据的计划，避免模型用全库事实替代仓库事实。
enum RAGExplicitRepositoryPlanGuard {
    static func resolve(
        question: String,
        plan initialPlan: RAGQueryPlan,
        composerContext: RAGComposerContext
    ) -> RAGQueryPlan {
        var plan = initialPlan
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composerContext.explicitRepoMode == .only,
              !composerContext.explicitRepoIDs.isEmpty,
              !query.isEmpty,
              plan.mode == .guidedDiscovery || plan.analytics != nil
        else { return plan }

        plan.mode = .semanticOnly
        plan.semanticQuery = query
        // Analytics DSL 当前只表达全知识库聚合，不能回答某个显式仓库是否拥有笔记等事实。
        // 清空后交给受 explicitRepoIDs 限定的检索链，从该仓库的真实分片得出结论。
        plan.analytics = nil
        // Metadata 是 keyword-only 分片；加入稳定的英文兜底可保证中文仓库事实问题仍会
        // 进入 Metadata FTS，同时候选范围已由 explicitRepoIDs 强制约束，不会扩大数据边界。
        plan.keywordQueries = [query, "metadata"]
        plan.confidence = .medium
        plan.clarificationQuestion = nil
        plan.fallbackQuestions = []
        plan.userVisiblePlan = RAGUserVisiblePlan(
            chips: composerContext.explicitRepoReferences.map(\.fullName),
            semantic: query
        )
        return plan
    }
}
