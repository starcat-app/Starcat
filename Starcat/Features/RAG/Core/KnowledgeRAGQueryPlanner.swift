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
            return "问题不能为空"
        case .invalidPlan(let reason):
            return "查询计划无效：\(reason)"
        }
    }
}

protocol KnowledgeRAGQueryPlanning: Sendable {
    func plan(question: String, composerContext: RAGComposerContext) async throws -> RAGQueryPlan
}

struct KnowledgeRAGQueryPlanner: KnowledgeRAGQueryPlanning {
    private let client: any AIClientProtocol
    private let model: String
    private let parameters: AIModelParameters

    init(client: any AIClientProtocol, model: String, parameters: AIModelParameters) {
        self.client = client
        self.model = model
        self.parameters = parameters
    }

    func plan(question: String, composerContext: RAGComposerContext) async throws -> RAGQueryPlan {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw RAGQueryPlannerError.emptyQuestion }

        let request = AIChatRequest(
            systemPrompt: Self.systemPrompt,
            userPrompt: userPrompt(question: question, context: composerContext),
            model: model,
            parameters: parameters,
            responseFormat: .jsonObject
        )
        do {
            let response = try await client.chat(request: request)
            return try Self.decodeAndValidate(response.content, fallbackQuestion: question)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 部分 OpenAI-compatible 服务忽略 response_format 或会在 JSON 外加解释；
            // 第二次明确要求只返 JSON，仍失败才走 semantic-only。
            var retry = request
            retry.userPrompt += "\n\n上一次输出无法解析。只返回一个符合 schema 的 JSON object，不要 Markdown 代码块或说明。"
            do {
                let response = try await client.chat(request: retry)
                return try Self.decodeAndValidate(response.content, fallbackQuestion: question)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Self.semanticFallback(question)
            }
        }
    }

    private func userPrompt(question: String, context: RAGComposerContext) -> String {
        let explicit = context.explicitRepoIDs.map(String.init).joined(separator: ",")
        return """
            用户问题：\(question)

            输入框确定上下文（只供理解，本地执行器会再次强制执行）：
            - explicitRepoIDs: [\(explicit)]
            - explicitRepoMode: \(context.explicitRepoMode.rawValue)
            - attachmentCount: \(context.attachments.count)

            请输出查询计划 JSON。
            """
    }

    static func decodeAndValidate(_ raw: String, fallbackQuestion: String) throws -> RAGQueryPlan {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else {
            throw RAGQueryPlannerError.invalidPlan("JSON 编码失败")
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
        plan.remoteContextRequests = plan.remoteContextRequests.map {
            RAGRemoteContextRequest(
                resource: $0.resource,
                query: String($0.query.prefix(300)),
                reason: String($0.reason.prefix(500)),
                maxRepos: min(max($0.maxRepos, 1), 5),
                perRepoLimit: min(max($0.perRepoLimit, 1), 10)
            )
        }

        switch plan.mode {
        case .semanticOnly:
            guard !plan.semanticQuery.isEmpty else { throw RAGQueryPlannerError.invalidPlan("semantic_only 缺少 semanticQuery") }
            // 模型偶尔会选错 mode，但过滤字段本身有效时不丢掉用户约束。
            if plan.filters.hasEffectiveConditions || plan.sort != nil {
                plan.mode = .filteredSemantic
            }
        case .filteredSemantic:
            guard !plan.semanticQuery.isEmpty else { throw RAGQueryPlannerError.invalidPlan("filtered_semantic 缺少 semanticQuery") }
            if !plan.filters.hasEffectiveConditions, plan.sort == nil {
                plan.mode = .semanticOnly
            }
        case .structuredOnly:
            guard plan.filters.hasEffectiveConditions || plan.sort != nil else {
                throw RAGQueryPlannerError.invalidPlan("structured_only 没有结构化条件")
            }
        case .needsClarification:
            guard let clarification = plan.clarificationQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clarification.isEmpty else {
                throw RAGQueryPlannerError.invalidPlan("needs_clarification 缺少追问")
            }
            plan.clarificationQuestion = clarification
            plan.confidence = .needsClarification
        }
        if plan.userVisiblePlan.semantic.isEmpty {
            plan.userVisiblePlan.semantic = plan.semanticQuery
        }
        if plan.userVisiblePlan.scope.isEmpty {
            plan.userVisiblePlan.scope = "知识库"
        }
        return plan
    }

    private static func validateRanges(_ filters: RAGRepoFilter) throws {
        let values = [filters.minStars, filters.maxStars, filters.minForks, filters.maxForks].compactMap { $0 }
        guard values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 }) else {
            throw RAGQueryPlannerError.invalidPlan("数值条件超出范围")
        }
        if let min = filters.minStars, let max = filters.maxStars, min > max {
            throw RAGQueryPlannerError.invalidPlan("minStars 大于 maxStars")
        }
        if let min = filters.minForks, let max = filters.maxForks, min > max {
            throw RAGQueryPlannerError.invalidPlan("minForks 大于 maxForks")
        }
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
            userVisiblePlan: .init(scope: "知识库", chips: ["查询计划已降级"], semantic: question)
        )
    }

    private static let systemPrompt = """
        你是 Starcat 的 Query Planner。你只输出 JSON 查询计划，不回答用户问题。

        数据边界：默认且只能查询用户 Starcat 知识库中的 GitHub repo。本地执行器会强制执行该边界。
        支持字段：status(using/read/unread)、languages、tags、minStars、maxStars、minForks、maxForks、license、includeArchived、includeForks、starredAfter、starredBefore、libraryUpdatedAfter、libraryUpdatedBefore、repoCreatedAfter、repoCreatedBefore、pushedAfter、pushedBefore。
        日期输出 ISO-8601。不要创造字段。用户没有筛选语义时 filters 必须是空 object。

        mode：
        - semantic_only：没有结构化筛选，semanticQuery 是优化后的检索问题。
        - filtered_semantic：先按 filters/sort 过滤，再用 semanticQuery 检索。
        - structured_only：只需列表、排序或统计，不做 child chunk 召回。
        - needs_clarification：日期含义或意图无法确定，必须提供 clarificationQuestion。

        “从某日期开始”没有说明是 star、入库、创建还是 push 时间时，必须 needs_clarification。
        普通问题 remoteContextRequests 必须为空。只有明确依赖 GitHub 现场数据时才请求：
        github_issues、github_pull_requests、github_releases、github_contributors、github_commit_activity、github_security_advisories。

        输出 schema：
        {
          "mode":"semantic_only|filtered_semantic|structured_only|needs_clarification",
          "semanticQuery":"string",
          "filters":{},
          "sort":null或{"field":"stars|forks|pushedAt|repoCreatedAt|libraryUpdatedAt|starredAt","direction":"asc|desc"},
          "candidateLimit":null或integer,
          "remoteContextRequests":[{"resource":"github_issues","query":"string","reason":"string","maxRepos":5,"perRepoLimit":10}],
          "confidence":"high|medium|needs_clarification",
          "clarificationQuestion":null或string,
          "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"string"}
        }
        """
}
