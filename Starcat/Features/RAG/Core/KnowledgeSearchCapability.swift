//
//  KnowledgeSearchCapability.swift
//  Starcat
//
//  Starcat 知识库证据检索的共享 Capability 执行层。
//
//  该能力复用 Knowledge RAG 的候选仓库、混合召回、RRF、Rerank 与 parent packing，
//  但不依赖 Agent Runtime、MCP SDK、SwiftUI 或 localhost listener。调用方必须先提供
//  已授权的仓库 ID 范围；executor 只能缩小范围，不能自行扩展到整个知识库。
//

import Foundation

enum KnowledgeSearchCapabilities {
    static let search = StarcatCapabilityDefinition(
        id: "knowledge.search",
        summary: "Retrieve bounded indexed evidence and citations inside a caller-provided repository scope.",
        permission: .readOnly
    )
}

/// 共享 Knowledge Search executor 的稳定请求。
struct KnowledgeSearchCapabilityRequest: Equatable, Sendable {
    var query: String
    var repositoryScopeIDs: [Int64]
    var explicitRepoIDs: [Int64]
    var explicitMode: RAGExplicitRepoMode
    var maxRepositories: Int
}

/// 一段已经过总 token 预算的本地知识证据。
struct KnowledgeSearchEvidenceBlock: Equatable, Sendable {
    var marker: String
    var repositoryName: String
    var sectionTitle: String
    var content: String
    var chunkIDs: Set<Int64>
}

/// `knowledge.search` 的共享领域结果。
///
/// `evidenceBlocks` / `citations` 可直接交给调用方组织输出；trace 与 diagnostics 保留 RAG
/// 原始检索事实。结果不包含 Generator 回答，避免 Agent 或未来 MCP 再次解释一份模型生成文本。
struct KnowledgeSearchCapabilityResult: Sendable {
    var evidenceBlocks: [KnowledgeSearchEvidenceBlock]
    var citations: [RAGCitation]
    var retrievalTrace: RAGRetrievalTrace?
    var diagnostics: RAGRetrievalDiagnostics?
    var limitations: [String]

    var evidenceMarkdown: String {
        evidenceBlocks.map { block in
            "[\(block.marker)] \(block.repositoryName) / \(block.sectionTitle)\n\(block.content)"
        }.joined(separator: "\n\n---\n\n")
    }
}

/// Executor 的候选仓库窄接口。调用方提供的 repo IDs 是唯一可见边界。
protocol KnowledgeSearchCandidateProviding: Sendable {
    func candidates(repoIDs: [Int64], query: String) async throws -> [RAGRepoCandidate]
}

/// 使用现有 RAG Candidate Repository 精确回填调用方授权的仓库 IDs。
struct RAGKnowledgeSearchCandidateProvider: KnowledgeSearchCandidateProviding {
    private let repository: any RAGRepoCandidateRepositoryProtocol

    init(repository: any RAGRepoCandidateRepositoryProtocol) {
        self.repository = repository
    }

    func candidates(repoIDs: [Int64], query: String) async throws -> [RAGRepoCandidate] {
        guard !repoIDs.isEmpty else { return [] }
        return try await repository.fetchCandidates(
            plan: RAGQueryPlan(
                mode: .semanticOnly,
                semanticQuery: query,
                candidateLimit: repoIDs.count
            ),
            explicitRepoIDs: repoIDs,
            explicitMode: .only
        )
    }
}

/// Retriever 的窄接口让 capability 复用真实 RAG 算法，同时可独立验证范围与投影逻辑。
protocol KnowledgeSearchRetrieving: Sendable {
    func retrieve(
        semanticQuery: String,
        keywordQueries: [String],
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64]
    ) async throws -> RAGRetrievalResult
}

extension KnowledgeRAGRetriever: KnowledgeSearchRetrieving {
    func retrieve(
        semanticQuery: String,
        keywordQueries: [String],
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64]
    ) async throws -> RAGRetrievalResult {
        try await retrieve(
            semanticQuery: semanticQuery,
            keywordQueries: keywordQueries,
            candidates: candidates,
            explicitMode: explicitMode,
            explicitRepoIDs: explicitRepoIDs,
            progress: { _ in }
        )
    }
}

/// Knowledge RAG 证据检索的共享业务执行器。
struct KnowledgeSearchCapabilityExecutor: Sendable {
    private let candidateProvider: any KnowledgeSearchCandidateProviding
    private let retriever: any KnowledgeSearchRetrieving
    private let maxEvidenceTokens: Int

    init(
        candidateProvider: any KnowledgeSearchCandidateProviding,
        retriever: any KnowledgeSearchRetrieving,
        maxEvidenceTokens: Int = 1_600
    ) {
        self.candidateProvider = candidateProvider
        self.retriever = retriever
        // 普通 tool result 还会执行字符总预算。这里先按 token 收口，避免后续 compactor
        // 从 JSON 中间硬截断并破坏 citation marker 与正文的对应关系。
        self.maxEvidenceTokens = max(1, maxEvidenceTokens)
    }

    /// 在调用方给定的仓库范围内检索结构化证据。
    func execute(_ request: KnowledgeSearchCapabilityRequest) async throws -> KnowledgeSearchCapabilityResult {
        let normalized = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw KnowledgeSearchCapabilityError.emptyQuery }
        guard !request.repositoryScopeIDs.isEmpty else {
            throw KnowledgeSearchCapabilityError.emptyRepositoryScope
        }

        let limit = min(max(request.maxRepositories, 1), 30)
        let scopedIDs = Array(request.repositoryScopeIDs.prefix(limit))
        let fetched = try await candidateProvider.candidates(repoIDs: scopedIDs, query: normalized)
        let fetchedByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.repo.id, $0) })
        // Candidate SQL 有自己的稳定排序；capability 必须恢复调用方授权范围的顺序。
        // 对 Agent prefer 模式而言，显式仓库已经由 Context Provider 放在最前面。
        let candidates = scopedIDs.compactMap { fetchedByID[$0] }
        guard candidates.count == scopedIDs.count else {
            throw KnowledgeSearchCapabilityError.repositoryScopeChanged
        }

        let retrieval = try await retriever.retrieve(
            semanticQuery: normalized,
            keywordQueries: [],
            candidates: candidates,
            explicitMode: request.explicitMode,
            explicitRepoIDs: request.explicitRepoIDs
        )
        return Self.project(retrieval: retrieval, maxEvidenceTokens: maxEvidenceTokens)
    }

    /// 与 RAG Prompt Builder 保持相同的 metadata-first 预算语义：先保证每个结果仓库的
    /// 元数据命中，再依序加入 parent 正文。被预算裁掉的 chunk 会回写 retrieval trace。
    private static func project(
        retrieval: RAGRetrievalResult,
        maxEvidenceTokens: Int
    ) -> KnowledgeSearchCapabilityResult {
        let drafts = evidenceDrafts(retrieval.bundles)
        let assembly = assemble(drafts: drafts, tokenLimit: maxEvidenceTokens)
        var trace = retrieval.trace
        trace?.markEvidenceTokenLimited(chunkIDs: assembly.limitedChunkIDs)

        var limitations: [String] = []
        if retrieval.bundles.isEmpty {
            limitations.append("No relevant indexed evidence was found in the provided repository scope.")
        }
        if !assembly.limitedChunkIDs.isEmpty {
            limitations.append("Some matched chunks were omitted by the knowledge evidence budget.")
        }
        if retrieval.diagnostics?.vectorErrorDescription != nil {
            limitations.append("Vector retrieval was unavailable; keyword retrieval remained active.")
        }
        if retrieval.diagnostics?.keywordErrorDescription != nil {
            limitations.append("Keyword retrieval was unavailable; vector retrieval remained active.")
        }

        return KnowledgeSearchCapabilityResult(
            evidenceBlocks: assembly.blocks.map { $0.block },
            citations: assembly.blocks.map { $0.citation },
            retrievalTrace: trace,
            diagnostics: retrieval.diagnostics,
            limitations: limitations
        )
    }

    private struct EvidenceDraft {
        var block: KnowledgeSearchEvidenceBlock
        var citation: RAGCitation
    }

    private struct EvidenceAssembly {
        var blocks: [(block: KnowledgeSearchEvidenceBlock, citation: RAGCitation)]
        var limitedChunkIDs: Set<Int64>
    }

    private static func evidenceDrafts(_ bundles: [RepoContextBundle]) -> [EvidenceDraft] {
        var metadataDrafts: [EvidenceDraft] = []
        var parentDrafts: [EvidenceDraft] = []
        for bundle in bundles {
            if let hit = bundle.matchedChildren.first(where: { $0.chunk.source == .metadata }),
               let content = bundle.metadataContent,
               !content.isEmpty {
                let marker = "pending"
                let title = hit.chunk.parentTitle.isEmpty ? hit.chunk.title : hit.chunk.parentTitle
                metadataDrafts.append(EvidenceDraft(
                    block: KnowledgeSearchEvidenceBlock(
                        marker: marker,
                        repositoryName: bundle.candidate.repo.fullName,
                        sectionTitle: title,
                        content: content,
                        chunkIDs: Set([hit.chunk.id].compactMap { $0 })
                    ),
                    citation: citation(marker: marker, bundle: bundle, hit: hit, sectionTitle: title)
                ))
            }

            for parent in bundle.sectionParents {
                let parentHits = bundle.matchedChildren.filter {
                    parent.childChunkIDs.contains($0.chunk.id ?? -1)
                }
                guard let hit = parentHits.first ?? bundle.matchedChildren.first else { continue }
                let marker = "pending"
                parentDrafts.append(EvidenceDraft(
                    block: KnowledgeSearchEvidenceBlock(
                        marker: marker,
                        repositoryName: bundle.candidate.repo.fullName,
                        sectionTitle: parent.title,
                        content: parent.content,
                        chunkIDs: Set(parentHits.compactMap { $0.chunk.id })
                    ),
                    citation: citation(marker: marker, bundle: bundle, hit: hit, sectionTitle: parent.title)
                ))
            }
        }
        return (metadataDrafts + parentDrafts).enumerated().map { index, source in
            var draft = source
            let marker = "S\(index + 1)"
            draft.block.marker = marker
            draft.citation.marker = marker
            return draft
        }
    }

    private static func citation(
        marker: String,
        bundle: RepoContextBundle,
        hit: RAGChildHit,
        sectionTitle: String
    ) -> RAGCitation {
        RAGCitation(
            id: UUID(),
            marker: marker,
            chunkID: hit.chunk.id,
            repoID: bundle.candidate.repo.id,
            repoFullName: bundle.candidate.repo.fullName,
            repoLanguage: bundle.candidate.repo.language,
            source: RAGCitationSource(chunkSource: hit.chunk.source),
            sectionTitle: sectionTitle,
            score: hit.score,
            hitKind: hit.kind,
            vectorSimilarity: hit.vectorSimilarity,
            scoreBreakdown: hit.scoreBreakdown,
            sourceURL: URL(string: bundle.candidate.repo.htmlUrl)
        )
    }

    private static func assemble(drafts: [EvidenceDraft], tokenLimit: Int) -> EvidenceAssembly {
        var accepted: [(block: KnowledgeSearchEvidenceBlock, citation: RAGCitation)] = []
        var limitedChunkIDs = Set<Int64>()
        for (index, draft) in drafts.enumerated() {
            let candidate = (accepted.map { rendered($0.block) } + [rendered(draft.block)])
                .joined(separator: "\n\n---\n\n")
            guard TokenEstimator.estimate(text: candidate) <= tokenLimit else {
                for omitted in drafts.dropFirst(index) {
                    limitedChunkIDs.formUnion(omitted.block.chunkIDs)
                }
                break
            }
            accepted.append((draft.block, draft.citation))
        }
        return EvidenceAssembly(blocks: accepted, limitedChunkIDs: limitedChunkIDs)
    }

    private static func rendered(_ block: KnowledgeSearchEvidenceBlock) -> String {
        "[\(block.marker)] \(block.repositoryName) / \(block.sectionTitle)\n\(block.content)"
    }
}

enum KnowledgeSearchCapabilityError: LocalizedError, Equatable, Sendable {
    case emptyQuery
    case emptyRepositoryScope
    case repositoryScopeChanged

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Knowledge search query cannot be empty."
        case .emptyRepositoryScope:
            return "The provided repository scope is empty."
        case .repositoryScopeChanged:
            return "The repository scope is no longer fully available; knowledge search stopped without widening access."
        }
    }
}
