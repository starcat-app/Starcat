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
        let chunks = try await repository.fetchReadyChunks(model: model, repoIDs: repoIDs)
        return chunks.compactMap { chunk -> RAGChildHit? in
            let score = SemanticSearchService.cosineSimilarity(queryVector, chunk.vector)
            guard score.isFinite else { return nil }
            return RAGChildHit(
                chunk: chunk,
                score: score,
                kind: .vector,
                vectorSimilarity: score
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
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
            values[id] = value
        }
        for (index, hit) in vectorHits.enumerated() {
            guard let id = hit.chunk.id else { continue }
            var value = values[id] ?? Accumulator(chunk: hit.chunk)
            value.score += configuration.vectorWeight / (configuration.rrfConstant + Double(index + 1))
            value.score += max(hit.score, 0) * configuration.vectorScoreWeight
            value.vector = true
            // 原始向量分与融合分用途不同：前者给用户解释语义相似度，后者只负责排序。
            value.vectorSimilarity = hit.vectorSimilarity ?? hit.score
            values[id] = value
        }

        var ranked = values.values.map { value -> RAGChildHit in
            let kind: RAGHitKind = value.keyword && value.vector ? .hybrid : (value.keyword ? .keyword : .vector)
            var score = value.score * sourceWeight(value.chunk.source)
            if preferredRepoIDs.contains(value.chunk.repoId) {
                score += configuration.preferRepoBoost
            }
            return RAGChildHit(
                chunk: value.chunk,
                score: score,
                kind: kind,
                vectorSimilarity: value.vectorSimilarity
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
