//
//  AgentToolAudit.swift
//  Starcat
//
//  Agent 工具专用审计事实。
//
//  通用 tool output 负责回灌模型；本文件只保存 UI 回放所需的脱敏结构化数据。
//  它随 AgentToolResultMessage 一起写入 parts_json，避免建立第二套 trace 表或双写链路。
//

import Foundation

enum AgentToolAuditKind: String, Codable, Hashable, Sendable {
    case knowledgeRetrieval = "knowledge_retrieval"
}

/// 可扩展的工具审计信封。新增工具类型时应添加新的 optional payload，并保持旧字段可解码。
struct AgentToolAudit: Codable, Hashable, Sendable {
    var kind: AgentToolAuditKind
    var knowledgeRetrieval: AgentKnowledgeRetrievalAudit?

    static func knowledge(_ audit: AgentKnowledgeRetrievalAudit) -> AgentToolAudit {
        AgentToolAudit(kind: .knowledgeRetrieval, knowledgeRetrieval: audit)
    }
}

/// Knowledge RAG citation 的可持久化投影。
///
/// `RAGCitation` 还携带当前问答使用的运行期字段，不直接承担 Agent 历史契约。这里仅保存
/// Inspector 定位来源所需的信息，正文仍只存在于有界 tool output 与原知识库分片中。
struct AgentKnowledgeCitationAudit: Codable, Hashable, Sendable, Identifiable {
    var id: String { marker }
    var marker: String
    var chunkID: Int64?
    var repoID: Int64?
    var repoFullName: String
    var source: String
    var sectionTitle: String
    var score: Double
    var hitKind: String
    var vectorSimilarity: Double?
    var sourceURL: String?

    init(
        marker: String,
        chunkID: Int64?,
        repoID: Int64?,
        repoFullName: String,
        source: String,
        sectionTitle: String,
        score: Double,
        hitKind: String,
        vectorSimilarity: Double?,
        sourceURL: String?
    ) {
        self.marker = marker
        self.chunkID = chunkID
        self.repoID = repoID
        self.repoFullName = repoFullName
        self.source = source
        self.sectionTitle = sectionTitle
        self.score = score
        self.hitKind = hitKind
        self.vectorSimilarity = vectorSimilarity
        self.sourceURL = sourceURL
    }

    init(citation: RAGCitation) {
        marker = citation.marker
        chunkID = citation.chunkID
        repoID = citation.repoID
        repoFullName = citation.repoFullName
        source = citation.source.rawValue
        sectionTitle = citation.sectionTitle
        score = citation.score
        hitKind = citation.hitKind.rawValue
        vectorSimilarity = citation.vectorSimilarity
        sourceURL = citation.sourceURL?.absoluteString
    }
}

/// 一次 `knowledge_search` 的完整脱敏审计事实。
///
/// Trace 与 Diagnostics 复用 Knowledge RAG 已验证过的 Codable 模型；其中只含仓库/分片身份、
/// 排名、分数和门禁结果，不复制 README、notes 或 summary 正文。用户原始问题也不会写入这里。
struct AgentKnowledgeRetrievalAudit: Codable, Hashable, Sendable {
    var scopeMode: AIComposerExplicitRepoMode
    var frozenRepoIDs: [Int64]
    var explicitRepoIDs: [Int64]
    var evidenceBlockCount: Int
    var citations: [AgentKnowledgeCitationAudit]
    var retrievalTrace: RAGRetrievalTrace?
    var diagnostics: RAGRetrievalDiagnostics?
    var limitations: [String]

    init(
        scopeMode: AIComposerExplicitRepoMode,
        frozenRepoIDs: [Int64],
        explicitRepoIDs: [Int64],
        evidenceBlockCount: Int,
        citations: [AgentKnowledgeCitationAudit],
        retrievalTrace: RAGRetrievalTrace?,
        diagnostics: RAGRetrievalDiagnostics?,
        limitations: [String]
    ) {
        self.scopeMode = scopeMode
        self.frozenRepoIDs = frozenRepoIDs
        self.explicitRepoIDs = explicitRepoIDs
        self.evidenceBlockCount = evidenceBlockCount
        self.citations = citations
        self.retrievalTrace = retrievalTrace
        self.diagnostics = diagnostics
        self.limitations = limitations
    }

    init(result: AgentKnowledgeResult, context: AgentRunContext) {
        scopeMode = context.explicitRepoMode ?? .only
        frozenRepoIDs = context.knowledgeEligibleRepoIDs ?? context.repos.map(\.id)
        let frozenIDs = Set(frozenRepoIDs)
        explicitRepoIDs = (context.explicitRepos?.map(\.id) ?? []).filter(frozenIDs.contains)
        evidenceBlockCount = result.evidenceBlocks.count
        citations = result.citations.map(AgentKnowledgeCitationAudit.init)
        retrievalTrace = result.retrievalTrace
        diagnostics = result.diagnostics
        limitations = result.limitations
    }

    static func == (lhs: AgentKnowledgeRetrievalAudit, rhs: AgentKnowledgeRetrievalAudit) -> Bool {
        lhs.scopeMode == rhs.scopeMode
            && lhs.frozenRepoIDs == rhs.frozenRepoIDs
            && lhs.explicitRepoIDs == rhs.explicitRepoIDs
            && lhs.evidenceBlockCount == rhs.evidenceBlockCount
            && lhs.citations == rhs.citations
            && lhs.retrievalTrace == rhs.retrievalTrace
            && lhs.diagnostics == rhs.diagnostics
            && lhs.limitations == rhs.limitations
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(scopeMode)
        hasher.combine(frozenRepoIDs)
        hasher.combine(explicitRepoIDs)
        hasher.combine(evidenceBlockCount)
        hasher.combine(citations)
        // RAG trace/diagnostics 内含 Set，既有模型只承诺 Equatable/Codable。Hashable 允许
        // 不同值发生碰撞，因此这里使用稳定身份字段，不把无序集合的编码顺序带入 hash。
        hasher.combine(limitations)
    }
}

/// Timeline 与 Inspector 共享的稳定计数投影，避免两处 UI 分别解释 trace 的 optional 字段。
struct AgentKnowledgeAuditMetrics: Equatable, Sendable {
    var candidateCount: Int
    var keywordHitCount: Int
    var semanticHitCount: Int
    var finalEvidenceCount: Int
}

extension AgentKnowledgeRetrievalAudit {
    var metrics: AgentKnowledgeAuditMetrics {
        AgentKnowledgeAuditMetrics(
            candidateCount: retrievalTrace?.candidates.count ?? diagnostics?.candidateRepoCount ?? frozenRepoIDs.count,
            keywordHitCount: retrievalTrace?.keywordHits.count ?? diagnostics?.keywordRawCount ?? 0,
            semanticHitCount: retrievalTrace?.semanticHits.count ?? diagnostics?.vectorRawCount ?? 0,
            finalEvidenceCount: evidenceBlockCount
        )
    }
}
