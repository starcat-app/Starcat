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
    case plan(RAGQueryPlan)
    case retrieval(RAGRetrievalResult)
    case remoteContextConfirmation([RAGRemoteContextRequest])
    case remoteContext([RAGRemoteContextBlock])
    case debug(RAGDebugEvent)
    case delta(String)
    case completed(answer: String, model: String, citations: [RAGCitation], plan: RAGQueryPlan)
}

/// RAG 工作台当前一轮的内存调试记录。
///
/// 这不是诊断日志，也不会进入会话持久化；只有 `RAGServiceRequest.isDebugEnabled` 为 true
/// 时才由 Service 发出，窗口关闭或关闭调试模式后即被释放。
struct RAGDebugEvent: Identifiable, Sendable {
    enum Stage: String, Sendable {
        case request
        case plan
        case candidates
        case retrieval
        case remoteContext
        case prompt
        case response
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
    private var decision: Set<RAGRemoteContextResource>?

    func wait() async throws -> Set<RAGRemoteContextResource> {
        while decision == nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        return decision ?? []
    }

    func resolve(_ resources: Set<RAGRemoteContextResource>) {
        decision = resources
    }
}

protocol KnowledgeRAGRemoteContextProviding: Sendable {
    func fetch(requests: [RAGRemoteContextRequest], candidates: [RAGRepoCandidate]) async -> [RAGRemoteContextBlock]
}

struct EmptyKnowledgeRAGRemoteContextProvider: KnowledgeRAGRemoteContextProviding {
    func fetch(requests: [RAGRemoteContextRequest], candidates: [RAGRepoCandidate]) async -> [RAGRemoteContextBlock] { [] }
}

/// 首轮问答完成后生成会话标题的结果。标题调用独立于 RAG 主链路，因此失败不会影响问答。
enum RAGConversationTitleGenerationResult: Sendable {
    case completed(title: String, debugEvents: [RAGDebugEvent])
    case failed(debugEvents: [RAGDebugEvent])
    case cancelled
}

struct KnowledgeRAGService: Sendable {
    private let planner: any KnowledgeRAGQueryPlanning
    private let candidateRepository: any RAGRepoCandidateRepositoryProtocol
    private let retriever: KnowledgeRAGRetriever
    private let remoteContextProvider: any KnowledgeRAGRemoteContextProviding
    private let attachmentProcessor: any RAGAttachmentProcessing
    private let generatorClient: any AIClientProtocol
    private let generatorModel: String
    private let generatorParameters: AIModelParameters
    private let promptBuilder: KnowledgeRAGPromptBuilder

    init(
        planner: any KnowledgeRAGQueryPlanning,
        candidateRepository: any RAGRepoCandidateRepositoryProtocol,
        retriever: KnowledgeRAGRetriever,
        remoteContextProvider: any KnowledgeRAGRemoteContextProviding = EmptyKnowledgeRAGRemoteContextProvider(),
        attachmentProcessor: any RAGAttachmentProcessing = RAGAttachmentProcessor(),
        generatorClient: any AIClientProtocol,
        generatorModel: String,
        generatorParameters: AIModelParameters,
        promptBuilder: KnowledgeRAGPromptBuilder = .init()
    ) {
        self.planner = planner
        self.candidateRepository = candidateRepository
        self.retriever = retriever
        self.remoteContextProvider = remoteContextProvider
        self.attachmentProcessor = attachmentProcessor
        self.generatorClient = generatorClient
        self.generatorModel = generatorModel
        self.generatorParameters = generatorParameters
        self.promptBuilder = promptBuilder
    }

    func ask(
        request: RAGServiceRequest,
        history: [AIChatMessage] = [],
        remoteContextConsent: RAGRemoteContextConsent? = nil
    ) -> AsyncThrowingStream<KnowledgeRAGServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
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
                    var plan = try await planner.plan(question: request.rawQuestion, composerContext: request.composerContext)
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
                    """)
                    continuation.yield(.plan(plan))
                    if plan.mode == .needsClarification {
                        continuation.yield(.state(.needsClarification(plan.clarificationQuestion ?? "请补充查询条件")))
                        continuation.finish()
                        return
                    }

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
                    guard !candidates.isEmpty else {
                        let hasScope = plan.filters.hasEffectiveConditions || !request.composerContext.explicitRepoIDs.isEmpty
                        continuation.yield(.state(hasScope ? .noCandidates : .noKnowledgeRepos))
                        continuation.finish()
                        return
                    }

                    let retrieval: RAGRetrievalResult
                    if plan.mode == .structuredOnly {
                        retrieval = RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
                    } else {
                        continuation.yield(.state(.retrieving))
                        guard try await retriever.hasReadyChunks(repoIDs: candidates.map(\.repo.id)) else {
                            continuation.yield(.state(.noIndex))
                            continuation.finish()
                            return
                        }
                        retrieval = try await retriever.retrieve(
                            semanticQuery: plan.semanticQuery,
                            candidates: candidates,
                            explicitMode: request.composerContext.explicitRepoMode,
                            explicitRepoIDs: request.composerContext.explicitRepoIDs
                        )
                        guard !retrieval.bundles.isEmpty else {
                            continuation.yield(.state(.noRelevantChunks))
                            continuation.finish()
                            return
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
                    if !plan.remoteContextRequests.isEmpty {
                        continuation.yield(.state(.awaitingRemoteContextConfirmation))
                        continuation.yield(.remoteContextConfirmation(plan.remoteContextRequests))
                        // 非工作台调用方可能没有确认 UI。缺少 consent 时必须默认跳过联网，
                        // 不能因为调用方少传一个参数就静默批准 Issues/PR 等远程请求。
                        let approvedResources = try await remoteContextConsent?.wait() ?? []
                        plan.remoteContextRequests.removeAll { !approvedResources.contains($0.resource) }
                    }
                    if !plan.remoteContextRequests.isEmpty {
                        continuation.yield(.state(.fetchingRemoteContext))
                        remoteBlocks = await remoteContextProvider.fetch(
                            requests: plan.remoteContextRequests,
                            candidates: Array(candidates.prefix(5))
                        )
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
                    }
                    var attachmentContexts = try await attachmentProcessor.process(request.composerContext.attachments)
                    attachmentContexts.append(contentsOf: request.composerContext.pastedGitHubLinks.map { reference in
                        RAGAttachmentContext(
                            attachmentID: UUID(),
                            filename: "GitHub: \(reference.owner)/\(reference.repo)",
                            content: "用户显式提供 GitHub 链接：\(reference.url.absoluteString)；Starcat 关系：\(reference.relation.rawValue)"
                        )
                    })
                    let prompt = promptBuilder.build(
                        question: request.rawQuestion,
                        plan: plan,
                        retrieval: retrieval,
                        remoteBlocks: remoteBlocks,
                        attachmentContexts: attachmentContexts
                    )

                    continuation.yield(.state(.generating))
                    let chatRequest = AIChatRequest(
                        systemPrompt: prompt.systemPrompt,
                        userPrompt: prompt.userPrompt,
                        history: history,
                        images: attachmentContexts.compactMap { context in
                            guard let data = context.imageData, let contentType = context.contentType else { return nil }
                            return AIChatImageInput(data: data, contentType: contentType)
                        },
                        // selectedModelID 是 UI 的 provider::model 标识，依赖容器已经把它
                        // 解析为真实模型名，不能把复合 id 直接发给 OpenAI-compatible API。
                        model: generatorModel,
                        parameters: generatorParameters
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
                    for try await event in generatorClient.chatStream(request: chatRequest) {
                        try Task.checkCancellation()
                        switch event {
                        case .delta(let text):
                            answer += text
                            continuation.yield(.delta(text))
                        case .completed(let response):
                            responseModel = response.model
                            if answer.isEmpty { answer = response.content }
                        }
                    }
                    let citations = promptBuilder.citationsUsed(in: answer, prompt: prompt)
                    emitDebug(.response, """
                    model: \(responseModel)
                    citations: \(citations.map(\.repoFullName))

                    content:
                    \(answer)
                    """)
                    continuation.yield(.state(.completed))
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
            systemPrompt: Self.conversationTitleSystemPrompt,
            userPrompt: "用户的第一个问题：\n\(firstQuestion)",
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

    private static let conversationTitleSystemPrompt = """
    你是会话标题生成器。请根据用户的第一个问题生成一个简短、准确的中文标题。

    要求：
    - 仅输出标题文本，不要解释、不要引号、不要 Markdown、不要句末标点。
    - 体现用户的核心意图，避免“关于”“请问”“帮我”等无意义前缀。
    - 长度控制在 8 到 24 个中文字符；必要时可保留技术术语、代码名或英文缩写。
    - 不得编造问题中不存在的信息。
    """

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
