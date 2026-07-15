//
//  RAGSearchProviders.swift
//  Starcat
//
//  知识库 RAG 的 keyword / vector provider 边界与默认 SQLite 实现。
//
//  Provider 只负责 child chunk 召回；知识库范围由候选 repo id 和底层 Repository 的
//  `library_state = in_library` 双重约束保证。Meilisearch / Qdrant 可在不改 Retriever 的
//  前提下替换对应 provider。
//

import Foundation

protocol RAGKeywordSearchProvider: Sendable {
    var backendName: String { get }
    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit]
}

protocol RAGVectorSearchProvider: Sendable {
    var backendName: String { get }
    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit]
}

struct SQLiteRAGKeywordSearchProvider: RAGKeywordSearchProvider {
    let backendName = "SQLite FTS5"
    private let repository: any RAGChunkRepositoryProtocol

    init(repository: any RAGChunkRepositoryProtocol) {
        self.repository = repository
    }

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        let hits = try await repository.keywordSearch(query: query, model: model, repoIDs: repoIDs, limit: limit)
        // SQLite bm25 的绝对值与语料规模有关，跨查询不可直接比较；这里保留相对次序，
        // 由 fusion 使用 reciprocal rank 与 vector 统一量纲。
        return hits.enumerated().map { index, hit in
            RAGChildHit(chunk: hit.chunk, score: 1 / Double(index + 1), kind: .keyword)
        }
    }
}

struct SQLiteRAGVectorSearchProvider: RAGVectorSearchProvider {
    let backendName = "SQLite BLOB"
    private let repository: any RAGChunkRepositoryProtocol

    init(repository: any RAGChunkRepositoryProtocol) {
        self.repository = repository
    }

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        guard !queryVector.isEmpty, limit > 0 else { return [] }
        var topMatches: [RAGVectorMatch] = []
        let cosineQuery = CosineSimilarityQuery(queryVector)
        // SQLite 没有向量索引时仍需要扫过 embedding BLOB，但只分页读取 id/repo/vector，
        // 并把内存保留在 Top-K；正文在排名完成后才回填，避免大知识库随检索线性膨胀。
        for repoIDBatch in Self.idBatches(repoIDs) {
            var afterID: Int64?
            while !Task.isCancelled {
                let embeddings = try await repository.fetchReadyEmbeddings(
                    model: model,
                    repoIDs: repoIDBatch,
                    afterID: afterID,
                    limit: Self.embeddingScanPageSize
                )
                guard !embeddings.isEmpty else { break }
                for embedding in embeddings {
                    let score = cosineQuery.similarity(to: embedding.vector)
                    guard score.isFinite else { continue }
                    insertTopMatch(
                        RAGVectorMatch(chunkID: embedding.chunkID, score: score),
                        into: &topMatches,
                        limit: limit
                    )
                }
                afterID = embeddings.last?.chunkID
                if embeddings.count < Self.embeddingScanPageSize { break }
            }
        }
        try Task.checkCancellation()
        let chunkByID = Dictionary(uniqueKeysWithValues: try await repository.fetchReadyChunks(
            ids: topMatches.map(\.chunkID),
            model: model
        ).compactMap { chunk in
            chunk.id.map { ($0, chunk) }
        })
        return topMatches.compactMap { match in
            guard let chunk = chunkByID[match.chunkID] else { return nil }
            return RAGChildHit(chunk: chunk, score: match.score, kind: .vector, vectorSimilarity: match.score)
        }
    }

    private static let embeddingScanPageSize = 400
    private static let maxIDsPerQuery = 900

    private static func idBatches(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: maxIDsPerQuery).map {
            Array(ids[$0..<min($0 + maxIDsPerQuery, ids.count)])
        }
    }

    /// 小而固定的候选数组等价于 Top-K 最小堆的内存边界；K 最大只来自 Retriever 的 childLimit。
    private func insertTopMatch(_ match: RAGVectorMatch, into matches: inout [RAGVectorMatch], limit: Int) {
        if matches.count == limit, let lowest = matches.last, match.score <= lowest.score { return }
        matches.append(match)
        matches.sort { $0.score > $1.score }
        if matches.count > limit { matches.removeLast() }
    }
}

private struct RAGVectorMatch: Sendable {
    var chunkID: Int64
    var score: Double
}

struct RAGHybridFusionConfiguration: Equatable, Sendable {
    var rrfConstant = 60.0
    var keywordWeight = 1.0
    var keywordScoreWeight = 0.12
    var vectorWeight = 1.15
    var vectorScoreWeight = 0.20
    var preferRepoBoost = 0.08
    var perRepoLimit = 3
    var totalLimit = 24
}

/// Fusion 在最终上限裁剪前后的计数，供 Retriever 的 Debug 漏斗解释结果来源。
struct RAGHybridFusionDiagnostics: Codable, Equatable, Sendable {
    var uniqueCount = 0
    var perRepositoryLimitFilteredCount = 0
    var totalLimitFilteredCount = 0
}

struct RAGHybridFusionResult: Equatable, Sendable {
    var hits: [RAGChildHit]
    var diagnostics: RAGHybridFusionDiagnostics
}

protocol RAGReranking: Sendable {
    /// Debug Trace 记录请求实际采用的上限与模型，但不记录 endpoint、Token 或候选正文。
    var provider: RAGRerankProvider { get }
    var debugCandidateLimit: Int? { get }
    var debugModel: String? { get }
    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)]
}

extension RAGReranking {
    /// 自定义 reranker 不必为了 Debug 增加额外配置；实际内置 provider 会提供精确值。
    var debugCandidateLimit: Int? { nil }
    var debugModel: String? { nil }
}

/// Hugging Face Text Embeddings Inference 的 `/rerank` 协议适配。
///
/// TEI 在容器启动时确定模型，因此不能发送 Cohere 的 `model` / `top_n` 字段；协议边界独立
/// 于召回流程，避免服务端字段差异渗透到 RAG 排序逻辑。
struct HuggingFaceTEIRAGReranker: RAGReranking {
    private let configuration: RAGRerankConfiguration
    private let apiKey: String?
    private let httpClient: any RAGHTTPClientProtocol

    let provider: RAGRerankProvider = .huggingFaceTEI
    var debugCandidateLimit: Int? { configuration.candidateLimit }
    var debugModel: String? { nil }

    init(
        configuration: RAGRerankConfiguration,
        apiKey: String? = nil,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration.normalized
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = normalizedAPIKey.isEmpty ? nil : normalizedAPIKey
        self.httpClient = httpClient
    }

    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)] {
        guard configuration.validationMessage == nil, let url = URL(string: configuration.endpoint) else {
            throw RAGExternalBackendError.invalidConfiguration(
                configuration.validationMessage ?? String.l10n("rag.core.backend.error.rerankEndpoint")
            )
        }
        let selected = Array(candidates.prefix(configuration.candidateLimit))
        guard !selected.isEmpty else { return [] }
        let documents = selected.map { hit in
            [hit.chunk.title, hit.chunk.sectionPath, String(hit.chunk.content.prefix(6_000))]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        let body = TEIRerankRequest(query: query, texts: documents)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await httpClient.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw RAGExternalBackendError.http(backend: "Hugging Face TEI Rerank", status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        let results = try JSONDecoder().decode([TEIRerankResult].self, from: data)
        guard !results.isEmpty else { throw RAGExternalBackendError.invalidResponse("Hugging Face TEI Rerank") }
        return results.compactMap { result in
            guard selected.indices.contains(result.index) else { return nil }
            return (selected[result.index], result.score)
        }.sorted { $0.score > $1.score }
    }

    private struct TEIRerankRequest: Encodable {
        let query: String
        let texts: [String]
    }

    private struct TEIRerankResult: Decodable {
        let index: Int
        let score: Double
    }
}

/// Cohere v2 Rerank 兼容协议适配。
///
/// 服务方必须返回 `results[].index/relevance_score`；这与 TEI 的顶层数组 `score` 刻意分开，
/// 避免“兼容”名称掩盖两个不可互换的 JSON 协议。
struct CohereCompatibleRAGReranker: RAGReranking {
    private let configuration: RAGRerankConfiguration
    private let apiKey: String?
    private let httpClient: any RAGHTTPClientProtocol

    let provider: RAGRerankProvider = .cohereCompatible
    var debugCandidateLimit: Int? { configuration.candidateLimit }
    var debugModel: String? { configuration.model }

    init(
        configuration: RAGRerankConfiguration,
        apiKey: String? = nil,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration.normalized
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = normalizedAPIKey.isEmpty ? nil : normalizedAPIKey
        self.httpClient = httpClient
    }

    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)] {
        guard configuration.validationMessage == nil, let url = URL(string: configuration.endpoint) else {
            throw RAGExternalBackendError.invalidConfiguration(
                configuration.validationMessage ?? String.l10n("rag.core.backend.error.rerankEndpoint")
            )
        }
        let selected = Array(candidates.prefix(configuration.candidateLimit))
        guard !selected.isEmpty else { return [] }
        let documents = selected.map(Self.rerankDocument)
        let body = CohereRerankRequest(
            model: configuration.model,
            query: query,
            documents: documents,
            topN: selected.count
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await httpClient.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw RAGExternalBackendError.http(backend: "Cohere-compatible Rerank", status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(CohereRerankResponse.self, from: data)
        guard !decoded.results.isEmpty else { throw RAGExternalBackendError.invalidResponse("Cohere-compatible Rerank") }
        return decoded.results.compactMap { result in
            guard selected.indices.contains(result.index) else { return nil }
            return (selected[result.index], result.relevanceScore)
        }.sorted { $0.score > $1.score }
    }

    private static func rerankDocument(_ hit: RAGChildHit) -> String {
        [hit.chunk.title, hit.chunk.sectionPath, String(hit.chunk.content.prefix(6_000))]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private struct CohereRerankRequest: Encodable {
        let model: String
        let query: String
        let documents: [String]
        let topN: Int
        enum CodingKeys: String, CodingKey { case model, query, documents; case topN = "top_n" }
    }

    private struct CohereRerankResponse: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let index: Int
            let relevanceScore: Double
            enum CodingKeys: String, CodingKey { case index; case relevanceScore = "relevance_score" }
        }
    }
}

/// 用户可控制的 RAG 分片筛选边界。
///
/// 这些参数只决定“哪些本地分片进入本轮上下文”，不会改变索引、embedding 模型或融合权重。
/// 保留 keyword 召回独立于向量阈值，确保仓库名、API 名和错误码等精确匹配不会被语义分数误杀。
struct RAGRetrievalSettings: Codable, Equatable, Sendable {
    var minimumVectorSimilarity: Double
    var finalEvidenceChunkLimit: Int
    var perRepositoryEvidenceLimit: Int
    var evidenceTokenBudget: Int
    var enabledSources: Set<RAGChunkSource>

    static let balanced = RAGRetrievalSettings(
        minimumVectorSimilarity: 0.65,
        finalEvidenceChunkLimit: 8,
        perRepositoryEvidenceLimit: 3,
        evidenceTokenBudget: 8_000,
        enabledSources: Set(RAGChunkSource.allCases)
    )

    static let strict = RAGRetrievalSettings(
        minimumVectorSimilarity: 0.75,
        finalEvidenceChunkLimit: 5,
        perRepositoryEvidenceLimit: 2,
        evidenceTokenBudget: 6_000,
        enabledSources: Set(RAGChunkSource.allCases)
    )

    static let broad = RAGRetrievalSettings(
        minimumVectorSimilarity: 0.55,
        finalEvidenceChunkLimit: 10,
        perRepositoryEvidenceLimit: 4,
        evidenceTokenBudget: 12_000,
        enabledSources: Set(RAGChunkSource.allCases)
    )

    /// 让手工输入和旧 JSON 都落在安全范围内，避免一次配置把上下文撑爆。
    /// 分片上限 UI / 持久化统一钳在 1…50；Token 预算钳在 2000…1_024_000。
    func normalized() -> RAGRetrievalSettings {
        var settings = self
        settings.minimumVectorSimilarity = min(max(settings.minimumVectorSimilarity, 0), 1)
        settings.finalEvidenceChunkLimit = min(max(settings.finalEvidenceChunkLimit, 1), 50)
        settings.perRepositoryEvidenceLimit = min(max(settings.perRepositoryEvidenceLimit, 1), 50)
        settings.evidenceTokenBudget = min(max(settings.evidenceTokenBudget, 2_000), 1_024_000)
        return settings
    }
}

struct RAGHybridFusionEngine: Sendable {
    var configuration = RAGHybridFusionConfiguration()

    func fuse(
        keywordHits: [RAGChildHit],
        vectorHits: [RAGChildHit],
        preferredRepoIDs: Set<Int64> = []
    ) -> [RAGChildHit] {
        fuseWithDiagnostics(
            keywordHits: keywordHits,
            vectorHits: vectorHits,
            preferredRepoIDs: preferredRepoIDs
        ).hits
    }

    func fuseWithDiagnostics(
        keywordHits: [RAGChildHit],
        vectorHits: [RAGChildHit],
        preferredRepoIDs: Set<Int64> = [],
        appliesLimits: Bool = true
    ) -> RAGHybridFusionResult {
        struct Accumulator {
            var chunk: RAGChunk
            var score: Double = 0
            var keyword = false
            var vector = false
            var keywordRank: Int?
            var keywordScore: Double?
            var vectorRank: Int?
            var vectorSimilarity: Double?
        }

        var values: [Int64: Accumulator] = [:]
        for (index, hit) in keywordHits.enumerated() {
            guard let id = hit.chunk.id else { continue }
            var value = values[id] ?? Accumulator(chunk: hit.chunk)
            value.score += configuration.keywordWeight / (configuration.rrfConstant + Double(index + 1))
            // Keyword provider 把严格字面命中的相对排名归一化为 1/rank。只使用 RRF 项时
            // 首名约 0.016，会被 Retriever 的综合检索分阈值误判为无分片；保留该信号才能让
            // repo 名、API、错误码等精确查询独立成立。
            value.score += max(hit.score, 0) * configuration.keywordScoreWeight
            value.keyword = true
            value.keywordRank = index + 1
            value.keywordScore = hit.score
            values[id] = value
        }
        for (index, hit) in vectorHits.enumerated() {
            guard let id = hit.chunk.id else { continue }
            var value = values[id] ?? Accumulator(chunk: hit.chunk)
            value.score += configuration.vectorWeight / (configuration.rrfConstant + Double(index + 1))
            value.score += max(hit.score, 0) * configuration.vectorScoreWeight
            value.vector = true
            value.vectorRank = index + 1
            // 原始向量分与融合分用途不同：前者给用户解释语义相似度，后者只负责排序。
            value.vectorSimilarity = hit.vectorSimilarity ?? hit.score
            values[id] = value
        }

        var ranked = values.values.map { value -> RAGChildHit in
            let kind: RAGHitKind = value.keyword && value.vector ? .hybrid : (value.keyword ? .keyword : .vector)
            let sourceWeight = sourceWeight(value.chunk.source)
            let preferredRepoBoost = preferredRepoIDs.contains(value.chunk.repoId)
                ? configuration.preferRepoBoost
                : 0
            let score = value.score * sourceWeight + preferredRepoBoost
            // 在候选仍带有真实排名时冻结所有输入；后续裁剪、排序和会话恢复都不再改变这份审计快照。
            let scoreBreakdown = RAGScoreBreakdown(
                hitKind: kind,
                rrfConstant: configuration.rrfConstant,
                keywordRank: value.keywordRank,
                keywordScore: value.keywordScore,
                keywordWeight: configuration.keywordWeight,
                keywordScoreWeight: configuration.keywordScoreWeight,
                vectorRank: value.vectorRank,
                vectorSimilarity: value.vectorSimilarity,
                vectorWeight: configuration.vectorWeight,
                vectorScoreWeight: configuration.vectorScoreWeight,
                sourceWeight: sourceWeight,
                preferredRepoBoost: preferredRepoBoost,
                finalScore: score
            )
            return RAGChildHit(
                chunk: value.chunk,
                score: score,
                kind: kind,
                vectorSimilarity: value.vectorSimilarity,
                scoreBreakdown: scoreBreakdown
            )
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.chunk.chunkIndex < rhs.chunk.chunkIndex }
            return lhs.score > rhs.score
        }

        guard appliesLimits else {
            return RAGHybridFusionResult(
                hits: ranked,
                diagnostics: RAGHybridFusionDiagnostics(uniqueCount: ranked.count)
            )
        }
        return applyLimits(to: ranked)
    }

    /// Rerank 必须发生在多样性/总数裁剪前；否则只能重排已被截成少数的候选，收益很低。
    func applyLimits(to ranked: [RAGChildHit]) -> RAGHybridFusionResult {
        var repoCounts: [Int64: Int] = [:]
        var perRepositoryAccepted: [RAGChildHit] = []
        var perRepositoryLimitFilteredCount = 0
        for hit in ranked {
            let count = repoCounts[hit.chunk.repoId, default: 0]
            guard count < configuration.perRepoLimit else {
                perRepositoryLimitFilteredCount += 1
                continue
            }
            repoCounts[hit.chunk.repoId] = count + 1
            perRepositoryAccepted.append(hit)
        }
        let totalLimitFilteredCount = max(perRepositoryAccepted.count - configuration.totalLimit, 0)
        return RAGHybridFusionResult(
            hits: Array(perRepositoryAccepted.prefix(configuration.totalLimit)),
            diagnostics: RAGHybridFusionDiagnostics(
                uniqueCount: ranked.count,
                perRepositoryLimitFilteredCount: perRepositoryLimitFilteredCount,
                totalLimitFilteredCount: totalLimitFilteredCount
            )
        )
    }

    private func sourceWeight(_ source: RAGChunkSource) -> Double {
        switch source {
        case .notes: return 1.18
        case .summary: return 1.12
        case .readme: return 1.0
        case .metadata: return 0.85
        }
    }
}
