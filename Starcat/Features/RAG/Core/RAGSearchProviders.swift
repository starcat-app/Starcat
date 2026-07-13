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
                    let score = SemanticSearchService.cosineSimilarity(queryVector, embedding.vector)
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

struct RAGHybridFusionEngine: Sendable {
    var configuration = RAGHybridFusionConfiguration()

    func fuse(
        keywordHits: [RAGChildHit],
        vectorHits: [RAGChildHit],
        preferredRepoIDs: Set<Int64> = []
    ) -> [RAGChildHit] {
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
            // 首名约 0.016，会被 Retriever 的证据阈值误判为无证据；保留该信号才能让
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

        var repoCounts: [Int64: Int] = [:]
        return ranked.filter { hit in
            let count = repoCounts[hit.chunk.repoId, default: 0]
            guard count < configuration.perRepoLimit else { return false }
            repoCounts[hit.chunk.repoId] = count + 1
            return true
        }
        .prefix(configuration.totalLimit)
        .map { $0 }
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
