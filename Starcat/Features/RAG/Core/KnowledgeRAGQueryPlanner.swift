//
//  KnowledgeRAGQueryPlanner.swift
//  Starcat
//
//  使用小型 AI 把自然语言问题转换为受限 RAGQueryPlan。
//
//  Planner 不回答问题，也不直接访问数据库。模型输出必须经过本地 decode、范围钳制和
//  mode 一致性检查；两次 JSON 失败后降级为原问题的 semantic_only，避免规则解析器膨胀。
//

import Foundation

enum RAGQueryPlannerError: Error, LocalizedError, Equatable {
    case emptyQuestion
    case invalidPlan(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            return String.l10n("rag.core.plan.error.emptyQuestion")
        case .invalidPlan(let reason):
            return String(
                format: String.l10n("rag.core.plan.error.invalidFormat"),
                reason
            )
        }
    }
}

protocol KnowledgeRAGQueryPlanning: Sendable {
    /// 将 provider 公开的推理增量交给交互层；规划结果本身仍须在流结束后才解析。
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void
    ) async throws -> RAGQueryPlan
}

/// Planner 的原始 LLM 调用只在 Debug 模式下可见。通过可选的子协议提供观测能力，避免
/// 把 Debug 细节强加给轻量测试替身或其它 Planner 实现。
protocol KnowledgeRAGDebuggableQueryPlanning: KnowledgeRAGQueryPlanning {
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void,
        onDebugEvent: @escaping (RAGDebugEvent.Stage, String) -> Void
    ) async throws -> RAGQueryPlan
}

/// 元数据由 Service 读取一次后显式传入。Planner 仍不能直接读数据库，测试替身也无需因此增加依赖。
protocol KnowledgeRAGMetadataAwareQueryPlanning: KnowledgeRAGQueryPlanning {
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        metadataSnapshot: KnowledgeBaseMetadataSnapshot?,
        onReasoningDelta: @escaping (String) -> Void,
        onDebugEvent: @escaping (RAGDebugEvent.Stage, String) -> Void
    ) async throws -> RAGQueryPlan
}

extension KnowledgeRAGQueryPlanning {
    func plan(question: String, composerContext: RAGComposerContext) async throws -> RAGQueryPlan {
        try await plan(question: question, composerContext: composerContext, onReasoningDelta: { _ in })
    }
}

struct KnowledgeRAGQueryPlanner: KnowledgeRAGDebuggableQueryPlanning, KnowledgeRAGMetadataAwareQueryPlanning {
    private let client: any AIClientProtocol
    private let model: String
    private let parameters: AIModelParameters
    private let promptConfiguration: AIPromptConfiguration
    private let outputLanguage: String

    init(
        client: any AIClientProtocol,
        model: String,
        parameters: AIModelParameters,
        promptConfiguration: AIPromptConfiguration = RAGDefaultPrompts.planner,
        outputLanguage: String = "English"
    ) {
        self.client = client
        self.model = model
        self.parameters = parameters
        self.promptConfiguration = promptConfiguration
        self.outputLanguage = outputLanguage
    }

    func plan(question: String, composerContext: RAGComposerContext) async throws -> RAGQueryPlan {
        try await plan(question: question, composerContext: composerContext, onReasoningDelta: { _ in })
    }

    /// 规划 JSON 仍须完整接收后再解析，但 provider 若公开推理流，会在这里实时转交调用方。
    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void = { _ in }
    ) async throws -> RAGQueryPlan {
        try await plan(
            question: question,
            composerContext: composerContext,
            metadataSnapshot: nil,
            onReasoningDelta: onReasoningDelta,
            onDebugEvent: { _, _ in }
        )
    }

    func plan(
        question: String,
        composerContext: RAGComposerContext,
        onReasoningDelta: @escaping (String) -> Void,
        onDebugEvent: @escaping (RAGDebugEvent.Stage, String) -> Void
    ) async throws -> RAGQueryPlan {
        try await plan(
            question: question,
            composerContext: composerContext,
            metadataSnapshot: nil,
            onReasoningDelta: onReasoningDelta,
            onDebugEvent: onDebugEvent
        )
    }

    func plan(
        question: String,
        composerContext: RAGComposerContext,
        metadataSnapshot: KnowledgeBaseMetadataSnapshot?,
        onReasoningDelta: @escaping (String) -> Void,
        onDebugEvent: @escaping (RAGDebugEvent.Stage, String) -> Void
    ) async throws -> RAGQueryPlan {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw RAGQueryPlannerError.emptyQuestion }

        let request = AIChatRequest(
            systemPrompt: promptConfiguration.renderedSystemPrompt(placeholders: [
                "outputLanguage": outputLanguage
            ]),
            userPrompt: renderedUserPrompt(question: question, context: composerContext, metadataSnapshot: metadataSnapshot),
            model: model,
            parameters: parameters,
            responseFormat: .jsonObject
        )
        let firstContent = try await runLLMRequest(
            request,
            attempt: 1,
            onReasoningDelta: onReasoningDelta,
            onDebugEvent: onDebugEvent
        )
        do {
            return try Self.decodeAndValidate(firstContent, fallbackQuestion: question)
        } catch {
            guard Self.isPlanFormatError(error) else { throw error }
            // 部分 OpenAI-compatible 服务忽略 response_format 或会在 JSON 外加解释；只有
            // 这种“已经收到但无法解析”的格式失败才值得重试和 semantic fallback。网络、
            // 认证和配置错误必须交给 UI 的可恢复提示，不能伪装成成功的降级检索。
            var retry = request
            retry.userPrompt += "\n\nPrevious output could not be parsed. Return only one JSON object that matches the schema. No Markdown fences or commentary."
            let retryContent = try await runLLMRequest(
                retry,
                attempt: 2,
                onReasoningDelta: onReasoningDelta,
                onDebugEvent: onDebugEvent
            )
            do {
                return try Self.decodeAndValidate(retryContent, fallbackQuestion: question)
            } catch {
                guard Self.isPlanFormatError(error) else { throw error }
                onDebugEvent(.failure, String.l10n("rag.core.plan.debug.unparseableFallback"))
                return Self.semanticFallback(question)
            }
        }
    }

    /// 每次真实 Planner LLM 请求都在调用前后成对写入 Trace。`responseFormat` 与重试后的
    /// 完整 userPrompt 一同记录，避免 Debug 面板只看到最终 Plan 而无法复盘模型输入。
    private func runLLMRequest(
        _ request: AIChatRequest,
        attempt: Int,
        onReasoningDelta: @escaping (String) -> Void,
        onDebugEvent: @escaping (RAGDebugEvent.Stage, String) -> Void
    ) async throws -> String {
        onDebugEvent(.plannerPrompt, """
        attempt: \(attempt)
        model: \(request.model)
        parameters: \(String(reflecting: request.parameters))
        responseFormat: \(String(reflecting: request.responseFormat))

        systemPrompt:
        \(request.systemPrompt)

        userPrompt:
        \(request.userPrompt)
        """)
        do {
            let content = try await streamedContent(request: request, onReasoningDelta: onReasoningDelta)
            onDebugEvent(.plannerResponse, """
            attempt: \(attempt)
            model: \(request.model)

            content:
            \(content)
            """)
            return content
        } catch {
            onDebugEvent(
                .failure,
                String(
                    format: String.l10n("rag.core.plan.debug.requestFailedFormat"),
                    attempt,
                    error.localizedDescription
                )
            )
            throw error
        }
    }

    private func streamedContent(
        request: AIChatRequest,
        onReasoningDelta: (String) -> Void
    ) async throws -> String {
        var content = ""
        for try await event in client.chatStream(request: request) {
            switch event {
            case .reasoningDelta(let delta):
                onReasoningDelta(delta)
            case .reasoningCompleted:
                break
            case .delta(let delta):
                content += delta
            case .completed(let response):
                if content.isEmpty { content = response.content }
            }
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.emptyResponse
        }
        return content
    }

    private func renderedUserPrompt(
        question: String,
        context: RAGComposerContext,
        metadataSnapshot: KnowledgeBaseMetadataSnapshot?
    ) -> String {
        let explicit = context.explicitRepoReferences
            .map { "\($0.id):\($0.fullName)" }
            .joined(separator: ", ")
        let attachments = context.attachments
            .map { "\($0.filename) (\($0.contentType), \($0.handling.rawValue))" }
            .joined(separator: ", ")
        let links = context.pastedGitHubLinks
            .map { "\($0.owner)/\($0.repo) [\($0.relation.rawValue)]" }
            .joined(separator: ", ")
        let previousRepos = context.previousReferencedRepos
            .map { "\($0.id):\($0.fullName)" }
            .joined(separator: ", ")
        let basePrompt = promptConfiguration.renderedUserPrompt(placeholders: [
            "outputLanguage": outputLanguage,
            "question": question,
            // 旧版用户自定义 Planner prompt 仍可能引用这两个占位符；保留值仅为兼容，
            // 默认 prompt 已改用带仓库名和附件描述的最小上下文。
            "explicitRepoIDs": context.explicitRepoIDs.map(String.init).joined(separator: ","),
            "attachmentCount": String(context.attachments.count),
            "explicitRepositories": explicit.isEmpty ? "[]" : "[\(explicit)]",
            "explicitRepoMode": context.explicitRepoMode.rawValue,
            "attachmentDescriptors": attachments.isEmpty ? "[]" : "[\(attachments)]",
            "pastedGitHubLinks": links.isEmpty ? "[]" : "[\(links)]",
            "previousUserQuestion": context.previousUserQuestion ?? "<none>",
            "previousReferencedRepositories": previousRepos.isEmpty ? "[]" : "[\(previousRepos)]",
            "webSearchEnabled": String(context.webSearchEnabled)
        ])
        let metadataContext = metadataSnapshot.map { "\n\n\($0.plannerPromptContext())" } ?? ""
        return basePrompt + metadataContext + Self.analyticsCapabilityPrompt
    }

    static func decodeAndValidate(_ raw: String, fallbackQuestion: String) throws -> RAGQueryPlan {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else {
            throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.jsonEncoding"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.githubDate(from: value) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            for format in ["yyyy-MM-dd", "yyyy.MM.dd", "yyyy/MM/dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date: \(value)")
        }
        var plan = try decoder.decode(RAGQueryPlan.self, from: data)
        try validateRanges(plan.filters)
        plan.semanticQuery = plan.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.candidateLimit = plan.candidateLimit.map { min(max($0, 1), 1_000) }
        plan.remoteContextRequests = normalizeRemoteContextRequests(plan.remoteContextRequests)
        plan.webSearchRequests = normalizeWebSearchRequests(plan.webSearchRequests)
        plan.fallbackQuestions = normalizedFallbackQuestions(plan.fallbackQuestions)
        if let analytics = plan.analytics {
            plan.analytics = try analytics.validated()
            // 聚合/排行由本地执行器完成，不需要分片检索，也不能附带任意联网副作用。
            plan.mode = .structuredOnly
            plan.semanticQuery = ""
            plan.remoteContextRequests = []
            plan.webSearchRequests = []
            plan.requiresLiveEvidence = false
        }

        switch plan.mode {
        case .semanticOnly:
            guard !plan.semanticQuery.isEmpty else {
                throw RAGQueryPlannerError.invalidPlan(
                    String(format: String.l10n("rag.core.plan.error.semanticQueryMissingFormat"), "semantic_only")
                )
            }
            // 模型偶尔会选错 mode，但过滤字段本身有效时不丢掉用户约束。
            if plan.filters.hasEffectiveConditions || plan.sort != nil {
                plan.mode = .filteredSemantic
            }
        case .filteredSemantic:
            guard !plan.semanticQuery.isEmpty else {
                throw RAGQueryPlannerError.invalidPlan(
                    String(format: String.l10n("rag.core.plan.error.semanticQueryMissingFormat"), "filtered_semantic")
                )
            }
            if !plan.filters.hasEffectiveConditions, plan.sort == nil {
                plan.mode = .semanticOnly
            }
        case .structuredOnly:
            guard plan.analytics != nil || plan.filters.hasEffectiveConditions || plan.sort != nil else {
                throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.structuredConditionsMissing"))
            }
        case .guidedDiscovery:
            // 引导模式不执行任何数据访问。即使不可信 Planner 同时给了过滤或联网请求，
            // 本地也必须清空，不能让一条闲聊问题触发隐藏副作用。
            plan.semanticQuery = ""
            plan.filters = .init()
            plan.sort = nil
            plan.candidateLimit = nil
            plan.remoteContextRequests = []
            plan.webSearchRequests = []
            plan.requiresLiveEvidence = false
        case .needsClarification:
            guard let clarification = plan.clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clarification.isEmpty else {
                throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.clarificationMissing"))
            }
            plan.clarificationQuestion = clarification
            plan.confidence = .needsClarification
        }
        if plan.userVisiblePlan.semantic.isEmpty {
            plan.userVisiblePlan.semantic = plan.semanticQuery
        }
        if plan.userVisiblePlan.scope.isEmpty {
            plan.userVisiblePlan.scope = RAGUserVisiblePlan.defaultScope
        }
        // 这是展示给用户的“查询规划”，而非模型隐藏推理。限制条数和长度，既保证可扫描，
        // 也避免兼容 provider 误把长篇说明塞进执行时间线。
        plan.userVisiblePlan.planningNotes = plan.userVisiblePlan.planningNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { String($0.prefix(180)) }
        return plan
    }

    /// 作为不可编辑的附加约束拼到 Planner 请求。即使用户保留旧自定义模板，模型也仍能知道
    /// 可选择的业务 DSL；同时不暴露 SQLite 表、列或 SQL 语法。
    private static let analyticsCapabilityPrompt = """

    For aggregate/ranking/filter questions, optionally include analytics. It is a local-only DSL:
    {"dimension":"repository|language|status|tag|null","measure":"count|max_stars|average_stars|max_forks|average_forks|repositories_with_ai_summary|repositories_with_private_notes|repositories_with_ai_generated_notes|repositories_with_recently_edited_private_notes|repositories_with_recently_generated_ai_summaries|excluded_rag_chunks|repositories_without_readme|repositories_without_indexable_source","direction":"asc|desc","limit":1}
    Use analytics only for a database aggregation or ranking. Never use SQL, table names, column names, expressions, or additional analytics fields. Set mode=structured_only when analytics is present.
    """

    private static func validateRanges(_ filters: RAGRepoFilter) throws {
        let values = [filters.minStars, filters.maxStars, filters.minForks, filters.maxForks].compactMap { $0 }
        guard values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }) else {
            throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.numericRange"))
        }
        if let min = filters.minStars, let max = filters.maxStars, min > max {
            throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.minStarsExceedsMax"))
        }
        if let min = filters.minForks, let max = filters.maxForks, min > max {
            throw RAGQueryPlannerError.invalidPlan(String.l10n("rag.core.plan.error.minForksExceedsMax"))
        }
    }

    private static func isPlanFormatError(_ error: Error) -> Bool {
        error is RAGQueryPlannerError || error is DecodingError
    }

    /// Planner 是不可信输入。这里在用户确认前收敛同一 resource/query 的重复项，并把本轮
    /// GitHub 工作单元限制为 8 个（最多 3 类请求）。这既防止兼容 Provider 重复规划，也让
    /// 确认弹窗所展示的请求数与实际联网工作量一致。
    private static func normalizeRemoteContextRequests(
        _ requests: [RAGRemoteContextRequest]
    ) -> [RAGRemoteContextRequest] {
        let maxRequestCount = 3
        var seen = Set<String>()
        var unique: [RAGRemoteContextRequest] = []
        for request in requests {
            guard unique.count < maxRequestCount else { break }
            // 普通 Web 查询有独立的 Request/Provider；拒绝不可信 Planner 把它塞进
            // GitHub repo 工作项，避免错误路由到 GitHub API。
            guard request.resource != .externalWeb else { continue }
            let query = String(request.query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            let identity = "\(request.resource.rawValue)|\(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))|\(request.state.rawValue)|\(request.sort.rawValue)|\(request.order.rawValue)"
            guard seen.insert(identity).inserted else { continue }
            unique.append(RAGRemoteContextRequest(
                resource: request.resource,
                query: query,
                reason: String(request.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
                maxRepos: min(max(request.maxRepos, 1), 5),
                perRepoLimit: min(max(request.perRepoLimit, 1), 10),
                state: request.state,
                sort: request.sort,
                order: request.order
            ))
        }
        // 先去重、再均分总工作量。原先按输入顺序先取满 5 个 repo，会让第一类请求
        // 吞掉预算，后面的不同资源根本没有机会执行；均分后仍严格不超过 8 个 repo，
        // 也让确认弹窗与实际请求范围更符合用户的“多类现场信息”意图。
        var remainingFetches = 8
        return unique.enumerated().map { index, request in
            let remainingRequests = unique.count - index
            let fairShare = Int(ceil(Double(remainingFetches) / Double(remainingRequests)))
            let maxRepos = min(request.maxRepos, fairShare)
            remainingFetches -= maxRepos
            var normalized = request
            normalized.maxRepos = maxRepos
            return normalized
        }
    }

    private static func normalizeWebSearchRequests(
        _ requests: [RAGWebSearchRequest]
    ) -> [RAGWebSearchRequest] {
        var seen = Set<String>()
        return requests.compactMap { request in
            let query = String(request.query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            guard !query.isEmpty else { return nil }
            let identity = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { return nil }
            return RAGWebSearchRequest(
                query: query,
                reason: String(request.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                maxResults: min(max(request.maxResults, 1), 10)
            )
        }.prefix(2).map { $0 }
    }

    private static func normalizedFallbackQuestions(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        return questions.compactMap { raw in
            let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty,
                  question.count <= 120,
                  seen.insert(question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
            else { return nil }
            return question
        }.prefix(3).map { $0 }
    }

    private static func extractJSONObject(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    static func semanticFallback(_ question: String) -> RAGQueryPlan {
        RAGQueryPlan(
            mode: .semanticOnly,
            semanticQuery: question,
            confidence: .medium,
            userVisiblePlan: .init(scope: "Knowledge Base", chips: ["Query plan degraded"], semantic: question)
        )
    }
}
