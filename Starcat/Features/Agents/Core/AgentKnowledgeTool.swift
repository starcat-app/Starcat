//
//  AgentKnowledgeTool.swift
//  Starcat
//
//  Agent `knowledge_search` 的协议与 adapter。
//
//  真实候选回填、Knowledge RAG 检索、证据预算与 citation 投影由共享
//  `KnowledgeSearchCapabilityExecutor` 执行；本文件只负责把冻结的 AgentRunContext 映射为
//  capability request，并把共享结果映射为 Agent Tool、Timeline 与审计事实。
//

import Foundation

typealias AgentKnowledgeEvidenceBlock = KnowledgeSearchEvidenceBlock
typealias AgentKnowledgeResult = KnowledgeSearchCapabilityResult

/// 模型能够控制的知识检索参数。
///
/// 仓库 ID 与 only / prefer / exclude 不在这里暴露：它们来自 run 启动时冻结的
/// `AgentRunContext`。这条边界防止模型在中途 tool call 中扩大用户已经确认的范围。
struct AgentKnowledgeQuery: Equatable, Sendable {
    var text: String
    var maxRepositories: Int
}

/// Agent Tool 只依赖这个窄接口，测试无需构造整个 Runtime。
protocol AgentKnowledgeSearching: Sendable {
    func search(query: AgentKnowledgeQuery, context: AgentRunContext) async throws -> AgentKnowledgeResult
}

/// Preview / 测试默认注册项。Registry 保持完整工具表，但误调用时显式失败，不能返回
/// 看似成功的空证据掩盖依赖未装配问题。
struct UnavailableAgentKnowledgeSearcher: AgentKnowledgeSearching {
    func search(query: AgentKnowledgeQuery, context: AgentRunContext) async throws -> AgentKnowledgeResult {
        throw AgentKnowledgeError.unavailable
    }
}

/// Agent 冻结上下文到共享 `knowledge.search` capability 的 adapter。
struct AgentKnowledgeCapabilityAdapter: AgentKnowledgeSearching {
    private let executor: KnowledgeSearchCapabilityExecutor

    init(executor: KnowledgeSearchCapabilityExecutor) {
        self.executor = executor
    }

    func search(query: AgentKnowledgeQuery, context: AgentRunContext) async throws -> AgentKnowledgeResult {
        let repositoryScopeIDs = context.knowledgeEligibleRepoIDs ?? context.repos.map(\.id)
        let allowedIDs = Set(repositoryScopeIDs)
        do {
            return try await executor.execute(KnowledgeSearchCapabilityRequest(
                query: query.text,
                repositoryScopeIDs: repositoryScopeIDs,
                // 业务层已完成 only / prefer / exclude。Knowledge 只允许读取该结果中已入库的
                // 子集，不能再次解释 Composer 模式并扩大或清空范围。
                explicitRepoIDs: repositoryScopeIDs.filter(allowedIDs.contains),
                explicitMode: .only,
                maxRepositories: query.maxRepositories
            ))
        } catch let error as KnowledgeSearchCapabilityError {
            // Agent 已经发布到本分支的错误文案属于 Tool/Timeline 契约；共享 executor 使用
            // 入口无关文案，adapter 在边界上恢复 Agent 语义。
            throw AgentKnowledgeError(capabilityError: error)
        }
    }
}

struct AgentKnowledgeTool: AgentTool {
    private let searcher: any AgentKnowledgeSearching

    init(searcher: any AgentKnowledgeSearching) {
        self.searcher = searcher
    }

    let definition = AgentToolDefinition(
        name: "knowledge_search",
        description: "Search indexed Starcat knowledge inside the frozen run repository scope. Returns bounded evidence with citations and retrieval audit; never performs GitHub or web fetches.",
        inputSchema: AgentJSONSchema(
            type: .object,
            properties: [
                "query": AgentJSONSchema(type: .string, description: "Focused factual search query"),
                "maxRepositories": AgentJSONSchema(
                    type: .integer,
                    description: "Maximum frozen-scope repositories to search (1...30)",
                    defaultValue: .number(12)
                )
            ],
            required: ["query"]
        ),
        permission: .readOnly,
        timeoutMilliseconds: 45_000,
        retryPolicy: .transientRead
    )

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let arguments = input.arguments.objectValue ?? [:]
        let query = arguments["query"]?.stringValue ?? ""
        let maxRepositories = min(max(arguments["maxRepositories"]?.integerValue ?? 12, 1), 30)
        let serializedInput = (try? input.arguments.jsonString()) ?? "{}"
        if input.context.knowledgeEligibleRepoIDs?.isEmpty == true {
            let message = String.l10n("agent.knowledge.status.noEligibleRepositories")
            let output = AgentToolOutput(
                toolName: id,
                summary: String.l10n("agent.tool.status.skipped"),
                detail: message,
                input: serializedInput,
                output: "evidence: []\nlimitation: \(message)",
                log: message
            )
            return AgentToolResult(
                status: .skipped,
                output: output,
                trace: AgentTraceSpan(
                    kind: String.l10n("agent.trace.kind.knowledgeRetrieval"),
                    title: id,
                    summary: output.summary,
                    input: serializedInput,
                    output: output.output,
                    log: message,
                    status: .skipped,
                    relatedToolOutputID: output.id
                )
            )
        }
        do {
            let result = try await searcher.search(
                query: AgentKnowledgeQuery(text: query, maxRepositories: maxRepositories),
                context: input.context
            )
            let outputText = result.evidenceMarkdown.isEmpty
                ? "evidence: []"
                : result.evidenceMarkdown
            let audit = Self.auditSummary(result: result, context: input.context)
            let output = AgentToolOutput(
                toolName: id,
                summary: String(
                    format: String.l10n("agent.knowledge.summaryFormat"),
                    result.evidenceBlocks.count,
                    result.citations.count
                ),
                detail: audit,
                input: serializedInput,
                output: outputText,
                log: String.l10n("agent.knowledge.log.reused")
            )
            let sources = result.citations.compactMap { citation -> AgentToolResultSource? in
                guard let url = citation.sourceURL?.absoluteString else { return nil }
                return AgentToolResultSource(
                    id: citation.marker,
                    title: "[\(citation.marker)] \(citation.repoFullName) / \(citation.sectionTitle)",
                    url: url,
                    provider: "Starcat Knowledge RAG"
                )
            }
            return AgentToolResult(
                output: output,
                trace: AgentTraceSpan(
                    kind: String.l10n("agent.trace.kind.knowledgeRetrieval"),
                    title: id,
                    summary: output.summary,
                    input: serializedInput,
                    output: outputText,
                    log: audit,
                    relatedToolOutputID: output.id
                ),
                payload: .knowledge(result),
                sources: sources,
                toolAudit: .knowledge(AgentKnowledgeRetrievalAudit(result: result, context: input.context))
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let output = AgentToolOutput(
                toolName: id,
                summary: String.l10n("agent.tool.status.failed"),
                detail: message,
                input: serializedInput,
                output: "error: \(message)",
                log: message
            )
            return AgentToolResult(
                status: .failed,
                output: output,
                trace: AgentTraceSpan(
                    kind: String.l10n("agent.trace.kind.knowledgeRetrieval"),
                    title: id,
                    summary: output.summary,
                    input: serializedInput,
                    output: output.output,
                    log: message,
                    status: .failed,
                    relatedToolOutputID: output.id
                )
            )
        }
    }

    private static func auditSummary(result: AgentKnowledgeResult, context: AgentRunContext) -> String {
        let trace = result.retrievalTrace
        let outcome = result.diagnostics?.outcome.rawValue ?? "unknown"
        let mode = context.explicitRepoMode?.rawValue ?? "legacy"
        let limitations = result.limitations.isEmpty ? "none" : result.limitations.joined(separator: " | ")
        return """
        scope_mode: \(mode)
        frozen_repo_count: \(context.repos.count)
        candidate_count: \(trace?.candidates.count ?? 0)
        keyword_hit_count: \(trace?.keywordHits.count ?? 0)
        semantic_hit_count: \(trace?.semanticHits.count ?? 0)
        final_evidence_count: \(trace?.finalEvidence.count ?? 0)
        outcome: \(outcome)
        limitations: \(limitations)
        """
    }
}

enum AgentKnowledgeError: LocalizedError, Equatable, Sendable {
    case emptyQuery
    case emptyRepositoryScope
    case repositoryScopeChanged
    case unavailable

    init(capabilityError: KnowledgeSearchCapabilityError) {
        switch capabilityError {
        case .emptyQuery: self = .emptyQuery
        case .emptyRepositoryScope: self = .emptyRepositoryScope
        case .repositoryScopeChanged: self = .repositoryScopeChanged
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return String.l10n("agent.knowledge.error.emptyQuery")
        case .emptyRepositoryScope:
            return String.l10n("agent.knowledge.error.emptyRepositoryScope")
        case .repositoryScopeChanged:
            return String.l10n("agent.knowledge.error.repositoryScopeChanged")
        case .unavailable:
            return String.l10n("agent.knowledge.error.unavailable")
        }
    }
}
