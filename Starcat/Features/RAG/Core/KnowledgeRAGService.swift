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
    case delta(String)
    case completed(answer: String, model: String, citations: [RAGCitation], plan: RAGQueryPlan)
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
                do {
                    continuation.yield(.state(.planning))
                    var plan = try await planner.plan(question: request.rawQuestion, composerContext: request.composerContext)
                    plan.remoteContextRequests.removeAll {
                        request.composerContext.disabledRemoteResources.contains($0.resource)
                    }
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
                    continuation.yield(.state(.completed))
                    continuation.yield(.completed(answer: answer, model: responseModel, citations: citations, plan: plan))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.state(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.state(.failed(error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
