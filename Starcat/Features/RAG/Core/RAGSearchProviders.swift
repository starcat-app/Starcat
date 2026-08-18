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

/// Provider 共用的关键词查询快照。SQLite 使用已转义的 FTS5 OR 表达式，外部后端只接收
/// 纯字面文本；两者都来自同一组有界 terms，避免把 FTS5 语法泄漏给 Meilisearch。
struct RAGKeywordSearchQuery: Equatable, Sendable {
    var terms: [String]
    var sqliteFTS5Expression: String
    var externalQuery: String
    var usedSemanticFallback: Bool

    /// 空 terms 没有可执行的字面意图。Provider 必须返回零命中，不能把空字符串交给
    /// SQLite MATCH 或外部搜索后端，以免语法错误或被解释成全量检索。
    var isExecutable: Bool {
        !terms.isEmpty && !sqliteFTS5Expression.isEmpty && !externalQuery.isEmpty
    }
}

/// RAG 专用 OR 查询构造器。普通搜索继续使用 `FTSQuery.sanitize` 的 AND 语义。
///
/// LLM 输出只能作为不可信字面文本：所有 term 都包入双引号并转义内部引号，模型返回的
/// `OR` / `NOT` / 括号等不会成为可执行操作符。旧 Prompt 缺少关键词时，语义查询只按
/// 空白拆成有界 OR token；这条降级追求“至少可召回”，不再复用精度优先的旧 AND。
enum RAGKeywordQueryBuilder {
    static let maximumTermCount = 8
    static let maximumTermLength = 80

    static func build(
        keywordQueries: [String],
        semanticQuery: String,
        anchorQuestion: String = "",
        extraIdentityTerms: [String] = []
    ) -> RAGKeywordSearchQuery {
        let plannedTerms = mergedKeywordQueries(
            planned: keywordQueries,
            anchorQuestion: anchorQuestion,
            extraIdentityTerms: extraIdentityTerms
        )
        let usedSemanticFallback = plannedTerms.isEmpty
        let terms = usedSemanticFallback
            ? normalizedTerms([semanticQuery], splitsWords: true)
            : plannedTerms
        return RAGKeywordSearchQuery(
            terms: terms,
            sqliteFTS5Expression: terms.map(fts5Clause).joined(separator: " OR "),
            externalQuery: terms.joined(separator: " "),
            usedSemanticFallback: usedSemanticFallback
        )
    }

    /// 从用户原句抽出仓库身份词（`owner/repo`、拉丁标识符），供候选 SQL 与 FTS 共用。
    ///
    /// 不抽取连续中文：整句 LIKE 对 `full_name` 无效。中文标签由仓库层按「问题包含已有 tag.name」补入。
    static func identityTerms(from question: String) -> [String] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // owner/repo 优先，再拆成 owner 与 name；其余至少 3 个字符的拉丁标识符。
        let pattern = #"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+|[A-Za-z][A-Za-z0-9._-]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        var raw: [String] = []
        for match in regex.matches(in: trimmed, range: range) {
            guard let swiftRange = Range(match.range, in: trimmed) else { continue }
            let token = String(trimmed[swiftRange])
            raw.append(token)
            if token.contains("/") {
                raw.append(contentsOf: token.split(separator: "/").map(String.init))
            }
        }
        return normalizedTerms(raw, splitsWords: false)
    }

    /// 中文标签名含 CJK，不能靠拉丁 regex；由「问题包含已有 tag.name」补进身份词。
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 身份词始终排在 Planner 关键词之前；超出 8 个时丢掉 Planner 词，避免实体被挤出 OR 列表。
    static func mergedKeywordQueries(
        planned: [String],
        anchorQuestion: String,
        extraIdentityTerms: [String] = []
    ) -> [String] {
        let identity = normalizedTerms(
            identityTerms(from: anchorQuestion) + extraIdentityTerms,
            splitsWords: false
        )
        let plannedTerms = normalizedTerms(planned, splitsWords: false)
        var seen = Set(identity.map { $0.lowercased() })
        var result = identity
        for term in plannedTerms {
            let identityKey = term.lowercased()
            guard seen.insert(identityKey).inserted else { continue }
            result.append(term)
            if result.count == maximumTermCount { break }
        }
        return result
    }

    private static func normalizedTerms(_ values: [String], splitsWords: Bool) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "about", "for", "in", "introduction", "of", "overview",
            "project", "repository", "the", "to"
        ]
        let candidates = splitsWords
            ? values.flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            : values
        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed.prefix(maximumTermLength))
            let identity = value.lowercased()
            guard !value.isEmpty,
                  !stopWords.contains(identity),
                  seen.insert(identity).inserted else { continue }
            result.append(value)
            if result.count == maximumTermCount { break }
        }
        return result
    }

    private static func fts5Clause(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
    }
}

protocol RAGKeywordSearchProvider: Sendable {
    var backendName: String { get }
    func search(query: RAGKeywordSearchQuery, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit]
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

    func search(query: RAGKeywordSearchQuery, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        guard query.isExecutable else { return [] }
        let hits = try await repository.keywordSearch(
            query: query.sqliteFTS5Expression,
            repoIDs: repoIDs,
            limit: limit
        )
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

/// Rerank Provider 共用的候选快照。
///
/// 服务端返回的是请求数组下标而不是 chunk id，因此候选截断、文档拼装和下标映射必须来自
/// 同一个不可变快照；否则两个 Provider 各自维护这段逻辑时，很容易出现请求顺序与回填顺序漂移。
private struct RAGRerankCandidateSnapshot: Sendable {
    let hits: [RAGChildHit]
    let documents: [String]

    init(candidates: [RAGChildHit], limit: Int) {
        hits = Array(candidates.prefix(limit))
        documents = hits.map { hit in
            [hit.chunk.title, hit.chunk.sectionPath, String(hit.chunk.content.prefix(6_000))]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    func applying(_ scores: [RAGRerankIndexedScore]) -> [(hit: RAGChildHit, score: Double)] {
        scores.compactMap { result in
            guard hits.indices.contains(result.index) else { return nil }
            return (hits[result.index], result.score)
        }.sorted { $0.score > $1.score }
    }
}

private struct RAGRerankIndexedScore: Sendable {
    let index: Int
    let score: Double
}

/// Rerank Provider 共用的 HTTP 传输层。
///
/// 这里只统一认证、JSON POST 与 HTTP 错误语义；协议 DTO 仍由各 Provider 持有，避免把 TEI
/// 和 Cohere 两套不可互换的 JSON 协议伪装成同一种模型。
private struct RAGRerankTransport: Sendable {
    private let apiKey: String?
    private let httpClient: any RAGHTTPClientProtocol

    init(apiKey: String?, httpClient: any RAGHTTPClientProtocol) {
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = normalizedAPIKey.isEmpty ? nil : normalizedAPIKey
        self.httpClient = httpClient
    }

    func post<Body: Encodable>(_ body: Body, to url: URL, backend: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await httpClient.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw RAGExternalBackendError.http(
                backend: backend,
                status: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

/// Hugging Face Text Embeddings Inference 的 `/rerank` 协议适配。
///
/// TEI 在容器启动时确定模型，因此不能发送 Cohere 的 `model` / `top_n` 字段；协议边界独立
/// 于召回流程，避免服务端字段差异渗透到 RAG 排序逻辑。
struct HuggingFaceTEIRAGReranker: RAGReranking {
    private let configuration: RAGRerankConfiguration
    private let transport: RAGRerankTransport

    let provider: RAGRerankProvider = .huggingFaceTEI
    var debugCandidateLimit: Int? { configuration.candidateLimit }
    var debugModel: String? { nil }

    init(
        configuration: RAGRerankConfiguration,
        apiKey: String? = nil,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration.normalized
        transport = RAGRerankTransport(apiKey: apiKey, httpClient: httpClient)
    }

    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)] {
        guard configuration.validationMessage == nil, let url = URL(string: configuration.endpoint) else {
            throw RAGExternalBackendError.invalidConfiguration(
                configuration.validationMessage ?? String.l10n("rag.core.backend.error.rerankEndpoint")
            )
        }
        let snapshot = RAGRerankCandidateSnapshot(candidates: candidates, limit: configuration.candidateLimit)
        guard !snapshot.hits.isEmpty else { return [] }
        let body = TEIRerankRequest(query: query, texts: snapshot.documents)
        let data = try await transport.post(body, to: url, backend: "Hugging Face TEI Rerank")
        let results = try JSONDecoder().decode([TEIRerankResult].self, from: data)
        guard !results.isEmpty else { throw RAGExternalBackendError.invalidResponse("Hugging Face TEI Rerank") }
        return snapshot.applying(results.map { RAGRerankIndexedScore(index: $0.index, score: $0.score) })
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
    private let transport: RAGRerankTransport

    let provider: RAGRerankProvider = .cohereCompatible
    var debugCandidateLimit: Int? { configuration.candidateLimit }
    var debugModel: String? { configuration.model }

    init(
        configuration: RAGRerankConfiguration,
        apiKey: String? = nil,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration.normalized
        transport = RAGRerankTransport(apiKey: apiKey, httpClient: httpClient)
    }

    func rerank(query: String, candidates: [RAGChildHit]) async throws -> [(hit: RAGChildHit, score: Double)] {
        guard configuration.validationMessage == nil, let url = URL(string: configuration.endpoint) else {
            throw RAGExternalBackendError.invalidConfiguration(
                configuration.validationMessage ?? String.l10n("rag.core.backend.error.rerankEndpoint")
            )
        }
        let snapshot = RAGRerankCandidateSnapshot(candidates: candidates, limit: configuration.candidateLimit)
        guard !snapshot.hits.isEmpty else { return [] }
        let body = CohereRerankRequest(
            model: configuration.model,
            query: query,
            documents: snapshot.documents,
            topN: snapshot.hits.count
        )
        let data = try await transport.post(body, to: url, backend: "Cohere-compatible Rerank")
        let decoded = try JSONDecoder().decode(CohereRerankResponse.self, from: data)
        guard !decoded.results.isEmpty else { throw RAGExternalBackendError.invalidResponse("Cohere-compatible Rerank") }
        return snapshot.applying(decoded.results.map {
            RAGRerankIndexedScore(index: $0.index, score: $0.relevanceScore)
        })
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
    func applyLimits(to ranked: [RAGChildHit], totalLimit: Int? = nil) -> RAGHybridFusionResult {
        let totalLimit = totalLimit ?? configuration.totalLimit
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
        let totalLimitFilteredCount = max(perRepositoryAccepted.count - totalLimit, 0)
        return RAGHybridFusionResult(
            hits: Array(perRepositoryAccepted.prefix(totalLimit)),
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
