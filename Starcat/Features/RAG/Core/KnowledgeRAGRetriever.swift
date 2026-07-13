//
//  KnowledgeRAGRetriever.swift
//  Starcat
//
//  Repo-aware parent-child 检索编排。
//
//  child chunk 用于找准证据，命中后按 parent_key 扩展章节，再按 repo 聚合为
//  RepoContextBundle。Generator 因而拿到的是“repo + 完整相关章节”，不是失去归属的碎片。
//

import Foundation

struct KnowledgeRAGRetriever: Sendable {
    private let chunkRepository: any RAGChunkRepositoryProtocol
    private let keywordProvider: any RAGKeywordSearchProvider
    private let vectorProvider: any RAGVectorSearchProvider
    private let privateRepoKeywordProvider: any RAGKeywordSearchProvider
    private let privateRepoVectorProvider: any RAGVectorSearchProvider
    private let fusion: RAGHybridFusionEngine
    private let parentPacker: RAGParentContextPacker
    private let embeddingClient: any AIClientProtocol
    private let embeddingModel: String
    private let childLimit: Int
    private let repoLimit: Int
    private let parentTokenLimit: Int
    private let minimumEvidenceScore: Double

    init(
        chunkRepository: any RAGChunkRepositoryProtocol,
        keywordProvider: any RAGKeywordSearchProvider,
        vectorProvider: any RAGVectorSearchProvider,
        privateRepoKeywordProvider: (any RAGKeywordSearchProvider)? = nil,
        privateRepoVectorProvider: (any RAGVectorSearchProvider)? = nil,
        fusion: RAGHybridFusionEngine = .init(),
        parentPacker: RAGParentContextPacker = .init(),
        embeddingClient: any AIClientProtocol,
        embeddingModel: String,
        childLimit: Int = 60,
        repoLimit: Int = 5,
        parentTokenLimit: Int = 1_600,
        minimumEvidenceScore: Double = 0.08
    ) {
        self.chunkRepository = chunkRepository
        self.keywordProvider = keywordProvider
        self.vectorProvider = vectorProvider
        self.privateRepoKeywordProvider = privateRepoKeywordProvider ?? keywordProvider
        self.privateRepoVectorProvider = privateRepoVectorProvider ?? vectorProvider
        self.fusion = fusion
        self.parentPacker = parentPacker
        self.embeddingClient = embeddingClient
        self.embeddingModel = embeddingModel
        self.childLimit = childLimit
        self.repoLimit = repoLimit
        self.parentTokenLimit = parentTokenLimit
        self.minimumEvidenceScore = minimumEvidenceScore
    }

    func hasReadyChunks(repoIDs: [Int64]) async throws -> Bool {
        guard !repoIDs.isEmpty else { return false }
        return !(try await chunkRepository.fetchReadyChunks(model: embeddingModel, repoIDs: repoIDs)).isEmpty
    }

    func retrieve(
        semanticQuery: String,
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64],
        progress: @Sendable (RAGRetrievalProgress) -> Void = { _ in }
    ) async throws -> RAGRetrievalResult {
        let query = semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty else {
            return RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
        }

        let publicRepoIDs = candidates.filter { !$0.repo.isPrivate }.map(\.repo.id)
        let privateRepoIDs = candidates.filter(\.repo.isPrivate).map(\.repo.id)
        var failures: [Error] = []
        let keyword: [RAGChildHit]
        progress(.keywordSearchStarted)
        do {
            keyword = try await keywordHits(
                query: query,
                publicRepoIDs: publicRepoIDs,
                privateRepoIDs: privateRepoIDs
            )
        } catch {
            keyword = []
            failures.append(error)
            AppLog.ai.warning("RAG keyword retrieval degraded: \(error.localizedDescription, privacy: .public)")
        }
        progress(.keywordSearchCompleted(keyword.count))

        let vector: [RAGChildHit]
        progress(.semanticSearchStarted)
        do {
            let queryVector = try await embeddingClient.embedding(input: query, model: embeddingModel)
            vector = try await vectorHits(
                queryVector: queryVector,
                publicRepoIDs: publicRepoIDs,
                privateRepoIDs: privateRepoIDs
            )
        } catch {
            vector = []
            failures.append(error)
            AppLog.ai.warning("RAG vector retrieval degraded: \(error.localizedDescription, privacy: .public)")
        }
        progress(.semanticSearchCompleted(vector.count))
        if failures.count == 2, let error = failures.first { throw error }
        let preferred = explicitMode == .prefer ? Set(explicitRepoIDs) : []
        let hits = fusion.fuse(
            keywordHits: keyword,
            vectorHits: vector,
            preferredRepoIDs: preferred
        ).filter { $0.score >= minimumEvidenceScore }
        let bundles = try await buildBundles(hits: hits, candidates: candidates)
        progress(.evidencePacked(hitCount: hits.count, bundleCount: bundles.count))
        return RAGRetrievalResult(candidates: candidates, bundles: bundles, childHits: hits)
    }

    private func buildBundles(hits: [RAGChildHit], candidates: [RAGRepoCandidate]) async throws -> [RepoContextBundle] {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.repo.id, $0) })
        let grouped = Dictionary(grouping: hits, by: { $0.chunk.repoId })
        var bundles: [RepoContextBundle] = []

        for (repoID, repoHits) in grouped {
            guard let candidate = candidateByID[repoID] else { continue }
            var parents: [RAGSectionParent] = []
            var seenParents = Set<String>()
            for hit in repoHits where seenParents.insert(hit.chunk.parentKey).inserted {
                let siblings = try await chunkRepository.fetchChunks(
                    repoId: repoID,
                    parentKey: hit.chunk.parentKey,
                    model: embeddingModel
                )
                let selected = parentPacker.select(
                    chunks: siblings,
                    anchorChunkID: hit.chunk.id,
                    tokenLimit: parentTokenLimit
                )
                parents.append(RAGSectionParent(
                    repoId: repoID,
                    parentKey: hit.chunk.parentKey,
                    title: hit.chunk.parentTitle,
                    content: selected.map(\.content).joined(separator: "\n\n"),
                    childChunkIDs: selected.compactMap(\.id)
                ))
            }
            let sortedHits = repoHits.sorted { $0.score > $1.score }
            let score = (sortedHits.first?.score ?? 0) + sortedHits.dropFirst().map(\.score).reduce(0, +) * 0.20
            bundles.append(RepoContextBundle(
                candidate: candidate,
                score: score,
                matchedChildren: sortedHits,
                sectionParents: parents
            ))
        }
        return bundles.sorted { $0.score > $1.score }.prefix(repoLimit).map { $0 }
    }

    private func keywordHits(query: String, publicRepoIDs: [Int64], privateRepoIDs: [Int64]) async throws -> [RAGChildHit] {
        var hits: [RAGChildHit] = []
        if !publicRepoIDs.isEmpty {
            hits += try await keywordProvider.search(
                query: query,
                model: embeddingModel,
                repoIDs: publicRepoIDs,
                limit: childLimit
            )
        }
        if !privateRepoIDs.isEmpty {
            hits += try await privateRepoKeywordProvider.search(
                query: query,
                model: embeddingModel,
                repoIDs: privateRepoIDs,
                limit: childLimit
            )
        }
        return hits.sorted { $0.score > $1.score }.prefix(childLimit).map { $0 }
    }

    private func vectorHits(queryVector: [Float], publicRepoIDs: [Int64], privateRepoIDs: [Int64]) async throws -> [RAGChildHit] {
        var hits: [RAGChildHit] = []
        if !publicRepoIDs.isEmpty {
            hits += try await vectorProvider.search(
                queryVector: queryVector,
                model: embeddingModel,
                repoIDs: publicRepoIDs,
                limit: childLimit
            )
        }
        if !privateRepoIDs.isEmpty {
            hits += try await privateRepoVectorProvider.search(
                queryVector: queryVector,
                model: embeddingModel,
                repoIDs: privateRepoIDs,
                limit: childLimit
            )
        }
        return hits.sorted { $0.score > $1.score }.prefix(childLimit).map { $0 }
    }
}

/// Section parent 必须围绕实际命中的 child 取上下文，而不是总从章节开头截取。否则超长
/// README 中后段命中会生成“citation 指向后段、prompt 却只含开头”的错误证据关系。
struct RAGParentContextPacker: Sendable {
    func select(chunks: [RAGChunk], anchorChunkID: Int64?, tokenLimit: Int) -> [RAGChunk] {
        guard !chunks.isEmpty else { return [] }
        let anchorIndex = anchorChunkID.flatMap { id in chunks.firstIndex { $0.id == id } } ?? 0
        var candidateIndices = [anchorIndex]
        for distance in 1..<chunks.count {
            let previous = anchorIndex - distance
            let next = anchorIndex + distance
            if previous >= 0 { candidateIndices.append(previous) }
            if next < chunks.count { candidateIndices.append(next) }
        }

        var used = 0
        var selectedIndices: [Int] = []
        for index in candidateIndices {
            let chunk = chunks[index]
            let tokens = max(chunk.tokenCount, TokenEstimator.estimate(text: chunk.content))
            guard selectedIndices.isEmpty || used + tokens <= tokenLimit else { continue }
            selectedIndices.append(index)
            used += tokens
        }
        return selectedIndices.sorted().map { chunks[$0] }
    }
}
