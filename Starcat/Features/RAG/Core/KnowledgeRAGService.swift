//
//  KnowledgeRAGService.swift
//  Starcat
//
//  知识库 RAG 的端到端执行状态机：Planner -> SQL candidates -> hybrid retrieval ->
//  remote/attachments -> Generator。每个早停状态都显式返回，避免“没搜到仍让模型自由回答”。
//

import Foundation

enum KnowledgeRAGServiceEvent: Sendable {
    case state(RAGAnswerState)
    case execution(RAGExecutionEvent)
    case plan(RAGQueryPlan)
    case retrieval(RAGRetrievalResult)
    case remoteContextConfirmation([RAGResolvedRemoteWorkItem])
    case remoteContext([RAGRemoteContextBlock])
    case terminal(RAGTerminalResponse)
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
struct RAGDebugEvent: Identifiable, Sendable {
    enum Stage: String, Sendable {
        case request
        case plannerPrompt = "planner_prompt"
        case plannerResponse = "planner_response"
        case plan
        case candidates
        case retrieval
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

    let id = UUID()
    let stage: Stage
    let elapsedSeconds: TimeInterval
    let payload: String
}

/// 一次独立的调试调用。问答与标题生成分别保存，不能共享平铺的事件数组。
enum RAGDebugTraceCategory: String, Sendable {
    case questionAnswer = "question_answer"
    case conversationTitle = "conversation_title"
}

struct RAGDebugTrace: Identifiable, Sendable {
    enum State: Sendable {
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

struct KnowledgeRAGService: Sendable {
    /// 召回测试用于人工核验而非构造回答；固定上限避免调试窗口被低分尾部结果淹没。
    private static let retrievalTestMaxHits = 10

    private let planner: any KnowledgeRAGQueryPlanning
    private let candidateRepository: any RAGRepoCandidateRepositoryProtocol
    private let retriever: KnowledgeRAGRetriever
    private let remoteContextProvider: any KnowledgeRAGRemoteContextProviding
    private let webSearchProvider: any RAGWebSearchProviding
    private let attachmentProcessor: any RAGAttachmentProcessing
    private let generatorClient: any AIClientProtocol
    private let generatorModel: String
    private let generatorParameters: AIModelParameters
    private let promptBuilder: KnowledgeRAGPromptBuilder
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
        generatorClient: any AIClientProtocol,
        generatorModel: String,
        generatorParameters: AIModelParameters,
        promptBuilder: KnowledgeRAGPromptBuilder = .init(),
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
        self.generatorClient = generatorClient
        self.generatorModel = generatorModel
        self.generatorParameters = generatorParameters
        self.promptBuilder = promptBuilder
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
                func emitDebug(_ stage: RAGDebugEvent.Stage, _ payload: @autoclosure () -> String) {
                    guard request.isDebugEnabled else { return }
                    continuation.yield(RAGDebugEvent(
                        stage: stage,
                        elapsedSeconds: Date().timeIntervalSince(startedAt),
                        payload: payload()
                    ).event)
                }

                do {
                    emitDebug(.request, """
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
                    continuation.yield(.state(.planning))
                    continuation.yield(.execution(.started(.planning)))
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
                        continuation.yield(.plan(plan))
                        continuation.yield(.execution(.planningCompleted(plan)))
                        continuation.yield(.terminal(terminal))
                        continuation.yield(.state(.completed))
                        continuation.finish()
                        return
                    }
                    var hasPlanningReasoning = false
                    let onReasoningDelta: (String) -> Void = { text in
                        guard !text.isEmpty else { return }
                        if !hasPlanningReasoning {
                            hasPlanningReasoning = true
                            continuation.yield(.execution(.started(.planningReasoning)))
                        }
                        continuation.yield(.execution(.reasoningDelta(.planningReasoning, text)))
                    }
                    var plan: RAGQueryPlan
                    if let debuggablePlanner = planner as? any KnowledgeRAGDebuggableQueryPlanning {
                        plan = try await debuggablePlanner.plan(
                            question: request.rawQuestion,
                            composerContext: request.composerContext,
                            onReasoningDelta: onReasoningDelta,
                            onDebugEvent: { stage, payload in
                                emitDebug(stage, "endpoint: \(request.debugEndpoint ?? "<unknown>")\n\n\(payload)")
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
                        continuation.yield(.execution(.reasoningCompleted(.planningReasoning)))
                    }
                    // Planner 是概率模型，可能漏报“最新 Issues”这类稳定的实时 GitHub 意图。
                    // 执行层在这里补齐高置信请求，并只在 Composer 明确授权后保留普通 Web 查询。
                    plan = RAGNetworkIntentResolver.resolve(
                        question: request.rawQuestion,
                        plan: plan,
                        composerContext: request.composerContext
                    )
                    plan.remoteContextRequests.removeAll {
                        request.composerContext.disabledRemoteResources.contains($0.resource)
                    }
                    emitDebug(.plan, """
                    mode: \(plan.mode.rawValue)
                    semanticQuery: \(plan.semanticQuery)
                    filters: \(String(reflecting: plan.filters))
                    candidateLimit: \(plan.candidateLimit.map(String.init) ?? "<default>")
                    clarificationQuestion: \(plan.clarificationQuestion ?? "<none>")
                    remoteContextRequests: \(plan.remoteContextRequests.map { "\($0.resource.rawValue): \($0.reason)" }.joined(separator: "\n"))
                    webSearchRequests: \(plan.webSearchRequests.map { "\($0.query): \($0.reason)" }.joined(separator: "\n"))
                    requiresLiveEvidence: \(plan.requiresLiveEvidence)
                    """)
                    continuation.yield(.plan(plan))
                    continuation.yield(.execution(.planningCompleted(plan)))
                    if plan.mode == .guidedDiscovery {
                        continuation.yield(.terminal(RAGQueryGuidance.guidedResponse(
                            plan: plan,
                            composerContext: request.composerContext
                        )))
                        continuation.yield(.state(.completed))
                        continuation.finish()
                        return
                    }
                    if plan.mode == .needsClarification {
                        continuation.yield(.state(.needsClarification(plan.clarificationQuestion ?? "请补充查询条件")))
                        continuation.finish()
                        return
                    }

                    // 附件属于本轮独立证据，必须在知识库早停判断之前处理；否则“知识库无命中
                    // 但用户上传了 PDF/图片”的合法问答会被错误截断。
                    var attachmentContexts = try await attachmentProcessor.process(request.composerContext.attachments)
                    attachmentContexts.append(contentsOf: request.composerContext.pastedGitHubLinks.map { reference in
                        RAGAttachmentContext(
                            attachmentID: UUID(),
                            filename: "GitHub: \(reference.owner)/\(reference.repo)",
                            content: "用户显式提供 GitHub 链接：\(reference.url.absoluteString)；Starcat 关系：\(reference.relation.rawValue)",
                            supportsFactualAnswer: false
                        )
                    })

                    continuation.yield(.state(.retrieving))
                    continuation.yield(.execution(.started(.retrieval)))
                    let candidates = try await candidateRepository.fetchCandidates(
                        plan: plan,
                        explicitRepoIDs: request.composerContext.explicitRepoIDs,
                        explicitMode: request.composerContext.explicitRepoMode
                    )
                    emitDebug(.candidates, candidates.map { candidate in
                        """
                        repo: \(candidate.repo.fullName)
                        status: \(candidate.status.rawValue)
                        tags: \(candidate.tagNames.joined(separator: ", "))
                        """
                    }.joined(separator: "\n---\n"))
                    continuation.yield(.execution(.retrieval(.candidateSelectionCompleted(candidates.count))))
                    let hasScopedQuery = plan.filters.hasEffectiveConditions
                        || !request.composerContext.explicitRepoIDs.isEmpty
                    var localMissingReasonKey: String?
                    let retrieval: RAGRetrievalResult
                    if candidates.isEmpty {
                        retrieval = RAGRetrievalResult(candidates: [], bundles: [], childHits: [])
                        let missingReasonKey = hasScopedQuery
                            ? "rag.workspace.execution.noCandidates"
                            : "rag.workspace.execution.noKnowledgeRepos"
                        localMissingReasonKey = missingReasonKey
                        continuation.yield(.execution(.terminated(
                            .retrieval,
                            summary: String.l10n(missingReasonKey)
                        )))
                    } else if plan.mode == .structuredOnly {
                        retrieval = RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
                        continuation.yield(.execution(.retrievalCompleted(retrieval)))
                    } else {
                        if try await retriever.hasReadyChunks(repoIDs: candidates.map(\.repo.id)) {
                            retrieval = try await retriever.retrieve(
                                semanticQuery: plan.semanticQuery,
                                candidates: candidates,
                                explicitMode: request.composerContext.explicitRepoMode,
                                explicitRepoIDs: request.composerContext.explicitRepoIDs,
                                progress: { progress in
                                    continuation.yield(.execution(.retrieval(progress)))
                                }
                            )
                            if retrieval.bundles.isEmpty {
                                localMissingReasonKey = "rag.workspace.execution.noEvidence"
                                continuation.yield(.execution(.terminated(
                                    .retrieval,
                                    summary: String.l10n("rag.workspace.execution.noEvidence")
                                )))
                            } else {
                                continuation.yield(.execution(.retrievalCompleted(retrieval)))
                            }
                        } else {
                            retrieval = RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
                            localMissingReasonKey = "rag.workspace.execution.noIndex"
                            continuation.yield(.execution(.terminated(
                                .retrieval,
                                summary: String.l10n("rag.workspace.execution.noIndex")
                            )))
                        }
                    }
                    emitDebug(.retrieval, retrieval.bundles.map { bundle in
                        let hits = bundle.matchedChildren.map { hit in
                            "\(hit.kind.rawValue) score=\(hit.score) source=\(hit.chunk.source.rawValue) section=\(hit.chunk.sectionPath)"
                        }.joined(separator: "\n")
                        return "repo: \(bundle.candidate.repo.fullName)\nscore: \(bundle.score)\nhits:\n\(hits)"
                    }.joined(separator: "\n---\n"))
                    continuation.yield(.retrieval(retrieval))

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
                        continuation.yield(.execution(.started(.remoteContext)))
                        let approvedWorkItems: [RAGResolvedRemoteWorkItem]
                        if request.composerContext.webSearchEnabled {
                            approvedWorkItems = resolvedRemoteWorkItems
                        } else if !resolvedRemoteWorkItems.isEmpty {
                            continuation.yield(.state(.awaitingRemoteContextConfirmation))
                            continuation.yield(.remoteContextConfirmation(resolvedRemoteWorkItems))
                            let approvedIDs = try await remoteContextConsent?.wait() ?? []
                            approvedWorkItems = resolvedRemoteWorkItems.filter { approvedIDs.contains($0.id) }
                        } else {
                            approvedWorkItems = []
                        }
                        continuation.yield(.execution(.remoteContextPrepared(approvedWorkItems)))
                        continuation.yield(.execution(.webSearchPrepared(plannedWebSearchRequests)))
                        if approvedWorkItems.isEmpty && plannedWebSearchRequests.isEmpty {
                            plan.remoteContextRequests = []
                            continuation.yield(.execution(.terminated(
                                .remoteContext,
                                summary: String.l10n("rag.workspace.execution.remoteSkipped")
                            )))
                        } else {
                            plan.remoteContextRequests = Self.uniqueRequests(in: approvedWorkItems)
                            continuation.yield(.state(.fetchingRemoteContext))
                            let totalNetworkRequests = approvedWorkItems.count + plannedWebSearchRequests.count
                            if !approvedWorkItems.isEmpty {
                                let onGitHubProgress: @Sendable (RAGRemoteContextFetchProgress) -> Void = { progress in
                                    continuation.yield(.execution(.remoteContextProgress(
                                        completed: progress.completed,
                                        total: totalNetworkRequests
                                    )))
                                }
                                let githubBlocks: [RAGRemoteContextBlock]
                                if let debuggableProvider = remoteContextProvider as? any KnowledgeRAGDebuggableRemoteContextProviding {
                                    githubBlocks = await debuggableProvider.fetch(
                                        workItems: approvedWorkItems,
                                        onProgress: onGitHubProgress,
                                        onDebug: { event in
                                            // 该回调来自 Provider 的 TaskGroup，不能捕获本地非 Sendable
                                            // `emitDebug`。直接写入同一 continuation，时间仍相对问答 Trace。
                                            guard request.isDebugEnabled else { return }
                                            continuation.yield(.debug(RAGDebugEvent(
                                                stage: event.stage,
                                                elapsedSeconds: Date().timeIntervalSince(startedAt),
                                                payload: event.payload
                                            )))
                                        }
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
                                        continuation.yield(.execution(.remoteContextProgress(
                                            completed: githubRequestCount + progress.completed,
                                            total: totalNetworkRequests
                                        )))
                                    }
                                )
                                remoteBlocks.append(contentsOf: webBlocks)
                            }
                            emitDebug(.remoteContext, remoteBlocks.map { block in
                                """
                                title: \(block.title)
                                sourceURL: \(block.sourceURL?.absoluteString ?? "<none>")
                                error: \(block.errorMessage ?? "<none>")
                                content:
                                \(block.content)
                                """
                            }.joined(separator: "\n---\n"))
                            continuation.yield(.remoteContext(remoteBlocks))
                            continuation.yield(.execution(.remoteContextCompleted(remoteBlocks)))
                        }
                    }

                    let hasStructuredEvidence = plan.mode == .structuredOnly && !retrieval.candidates.isEmpty
                    let hasLocalEvidence = !retrieval.bundles.isEmpty
                    let hasRemoteEvidence = remoteBlocks.contains {
                        $0.outcome == .success && $0.resultCount > 0 && !$0.content.isEmpty
                    }
                    let hasAttachmentEvidence = attachmentContexts.contains {
                        $0.supportsFactualAnswer && (!$0.content.isEmpty || $0.imageData != nil)
                    }
                    if plan.requiresLiveEvidence, !hasRemoteEvidence {
                        let answerKey = remoteBlocks.contains(where: { $0.outcome == .failed })
                            ? "rag.workspace.guidance.remoteFailedReply"
                            : "rag.workspace.guidance.remoteEmptyReply"
                        continuation.yield(.terminal(RAGQueryGuidance.noEvidenceResponse(
                            plan: plan,
                            composerContext: request.composerContext,
                            answerKey: answerKey
                        )))
                        continuation.yield(.state(.noRelevantChunks))
                        continuation.finish()
                        return
                    }
                    guard hasStructuredEvidence || hasLocalEvidence || hasRemoteEvidence || hasAttachmentEvidence else {
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
                        continuation.yield(.terminal(RAGQueryGuidance.noEvidenceResponse(
                            plan: plan,
                            composerContext: request.composerContext,
                            answerKey: answerKey
                        )))
                        continuation.yield(.state(terminalState))
                        continuation.finish()
                        return
                    }
                    let prompt = promptBuilder.build(
                        question: request.rawQuestion,
                        plan: plan,
                        retrieval: retrieval,
                        remoteBlocks: remoteBlocks,
                        attachmentContexts: attachmentContexts,
                        history: history,
                        contextWindowTokens: generatorParameters.resolvedContextWindowTokens,
                        maximumOutputTokens: generatorParameters.maxCompletionTokens
                    )
                    continuation.yield(.contextUsage(prompt.contextUsage))

                    continuation.yield(.state(.generating))
                    continuation.yield(.execution(.started(.generation)))
                    let evidenceCount = retrieval.bundles.count
                        + (hasStructuredEvidence ? retrieval.candidates.count : 0)
                        + remoteBlocks.filter { $0.outcome == .success && $0.resultCount > 0 }.count
                        + attachmentContexts.filter(\.supportsFactualAnswer).count
                    continuation.yield(.execution(.generationStarted(evidenceCount: evidenceCount)))
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
                        parameters: generationParameters
                    )
                    emitDebug(.prompt, """
                    endpoint: \(request.debugEndpoint ?? "<unknown>")
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
                                continuation.yield(.execution(.started(.answerReasoning)))
                            }
                            continuation.yield(.execution(.reasoningDelta(.answerReasoning, text)))
                        case .reasoningCompleted:
                            guard hasAnswerReasoning, !answerReasoningCompleted else { continue }
                            answerReasoningCompleted = true
                            continuation.yield(.execution(.reasoningCompleted(.answerReasoning)))
                        case .delta(let text):
                            answer += text
                            continuation.yield(.delta(text))
                        case .completed(let response):
                            responseModel = response.model
                            if answer.isEmpty { answer = response.content }
                        }
                    }
                    if hasAnswerReasoning, !answerReasoningCompleted {
                        continuation.yield(.execution(.reasoningCompleted(.answerReasoning)))
                    }
                    let citations = promptBuilder.citationsUsed(in: answer, prompt: prompt)
                    emitDebug(.response, """
                    model: \(responseModel)
                    citations: \(citations.map(\.repoFullName))

                    content:
                    \(answer)
                    """)
                    continuation.yield(.state(.completed))
                    continuation.yield(.execution(.generationCompleted(citationCount: citations.count)))
                    continuation.yield(.completed(answer: answer, model: responseModel, citations: citations, plan: plan))
                    continuation.finish()
                } catch is CancellationError {
                    emitDebug(.failure, "cancelled")
                    continuation.yield(.state(.cancelled))
                    continuation.finish()
                } catch {
                    emitDebug(.failure, error.localizedDescription)
                    continuation.yield(.state(.failed(error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
            parameters: parameters
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
                    payload: "会话压缩失败，已回退本地受限摘要：\(error.localizedDescription)"
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
            parameters: parameters
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
                        payload: "会话标题生成失败：模型返回了空标题"
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
                    payload: "会话标题生成失败：\(error.localizedDescription)"
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

private extension RAGDebugEvent {
    var event: KnowledgeRAGServiceEvent { .debug(self) }
}
