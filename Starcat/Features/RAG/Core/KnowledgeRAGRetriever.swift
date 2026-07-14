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
    private let minimumVectorSimilarity: Double
    private let enabledSources: Set<RAGChunkSource>

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
        minimumEvidenceScore: Double = 0.08,
        retrievalSettings: RAGRetrievalSettings = .balanced
    ) {
        let retrievalSettings = retrievalSettings.normalized()
        var fusionConfiguration = fusion.configuration
        fusionConfiguration.perRepoLimit = retrievalSettings.perRepositoryEvidenceLimit
        fusionConfiguration.totalLimit = retrievalSettings.finalEvidenceChunkLimit
        self.chunkRepository = chunkRepository
        self.keywordProvider = keywordProvider
        self.vectorProvider = vectorProvider
        self.privateRepoKeywordProvider = privateRepoKeywordProvider ?? keywordProvider
        self.privateRepoVectorProvider = privateRepoVectorProvider ?? vectorProvider
        self.fusion = RAGHybridFusionEngine(configuration: fusionConfiguration)
        self.parentPacker = parentPacker
        self.embeddingClient = embeddingClient
        self.embeddingModel = embeddingModel
        self.childLimit = childLimit
        self.repoLimit = repoLimit
        self.parentTokenLimit = parentTokenLimit
        self.minimumEvidenceScore = minimumEvidenceScore
        self.minimumVectorSimilarity = retrievalSettings.minimumVectorSimilarity
        self.enabledSources = retrievalSettings.enabledSources
    }

    func hasReadyChunks(repoIDs: [Int64]) async throws -> Bool {
        guard !repoIDs.isEmpty else { return false }
        return try await chunkRepository.hasReadyChunks(model: embeddingModel, repoIDs: repoIDs)
    }

    func retrieve(
        semanticQuery: String,
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64],
        progress: @Sendable (RAGRetrievalProgress) -> Void = { _ in }
    ) async throws -> RAGRetrievalResult {
        let query = semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty, !enabledSources.isEmpty else {
            return RAGRetrievalResult(candidates: candidates, bundles: [], childHits: [])
        }

        let publicRepoIDs = candidates.filter { !$0.repo.isPrivate }.map(\.repo.id)
        let privateRepoIDs = candidates.filter(\.repo.isPrivate).map(\.repo.id)
        // keyword 与 query embedding/vector 没有数据依赖。先同时启动两路，既保留原来的
        // 独立降级语义，也避免网络 embedding 的等待时间串行叠加到 FTS 查询之后。
        progress(.keywordSearchStarted)
        progress(.semanticSearchStarted)
        async let keywordResult = keywordRetrieval(
            query: query,
            publicRepoIDs: publicRepoIDs,
            privateRepoIDs: privateRepoIDs
        )
        async let vectorResult = vectorRetrieval(
            query: query,
            publicRepoIDs: publicRepoIDs,
            privateRepoIDs: privateRepoIDs
        )

        let keyword = await keywordResult
        let vector = await vectorResult
        let failures = [keyword.error, vector.error].compactMap { $0 }
        if let error = keyword.error {
            AppLog.ai.warning("RAG keyword retrieval degraded: \(error.localizedDescription, privacy: .public)")
        }
        if let error = vector.error {
            AppLog.ai.warning("RAG vector retrieval degraded: \(error.localizedDescription, privacy: .public)")
        }
        let eligibleKeywordHits = keyword.hits.filter { enabledSources.contains($0.chunk.source) }
        // 向量门槛只作用于 vector 分支；keyword 精确命中仍可独立进入融合，符合设置页的说明。
        let eligibleVectorHits = vector.hits.filter {
            enabledSources.contains($0.chunk.source)
                && ($0.vectorSimilarity ?? $0.score) >= minimumVectorSimilarity
        }
        progress(.keywordSearchCompleted(eligibleKeywordHits.count))
        progress(.semanticSearchCompleted(eligibleVectorHits.count))
        if failures.count == 2, let error = failures.first { throw error }
        let preferred = explicitMode == .prefer ? Set(explicitRepoIDs) : []
        let hits = fusion.fuse(
            keywordHits: eligibleKeywordHits,
            vectorHits: eligibleVectorHits,
            preferredRepoIDs: preferred
        ).filter { $0.score >= minimumEvidenceScore }
        let bundles = try await buildBundles(hits: hits, candidates: candidates)
        progress(.evidencePacked(hitCount: hits.count, bundleCount: bundles.count))
        return RAGRetrievalResult(candidates: candidates, bundles: bundles, childHits: hits)
    }

    private func buildBundles(hits: [RAGChildHit], candidates: [RAGRepoCandidate]) async throws -> [RepoContextBundle] {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.repo.id, $0) })
        let grouped = Dictionary(grouping: hits, by: { $0.chunk.repoId })
        let parentKeys = Set(hits.map { RAGChunkParentKey(repoID: $0.chunk.repoId, parentKey: $0.chunk.parentKey) })
        // 命中的 parent 一次性加载，避免每个 child hit 都触发一次 SQLite read。
        // 随后按完整 parent 身份分组，维持原有 repo/section 隔离和 chunk 顺序。
        let siblingsByParent = Dictionary(grouping: try await chunkRepository.fetchChunks(
            parents: Array(parentKeys),
            model: embeddingModel
        )) { RAGChunkParentKey(repoID: $0.repoId, parentKey: $0.parentKey) }
        var bundles: [RepoContextBundle] = []

        for (repoID, repoHits) in grouped {
            guard let candidate = candidateByID[repoID] else { continue }
            var parents: [RAGSectionParent] = []
            var seenParents = Set<String>()
            for hit in repoHits where seenParents.insert(hit.chunk.parentKey).inserted {
                let siblings = siblingsByParent[
                    RAGChunkParentKey(repoID: repoID, parentKey: hit.chunk.parentKey)
                ] ?? []
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

    private func keywordRetrieval(
        query: String,
        publicRepoIDs: [Int64],
        privateRepoIDs: [Int64]
    ) async -> RAGRetrievalBranchResult {
        do {
            return .init(hits: try await keywordHits(
                query: query,
                publicRepoIDs: publicRepoIDs,
                privateRepoIDs: privateRepoIDs
            ))
        } catch {
            return .init(hits: [], error: error)
        }
    }

    private func vectorRetrieval(
        query: String,
        publicRepoIDs: [Int64],
        privateRepoIDs: [Int64]
    ) async -> RAGRetrievalBranchResult {
        do {
            let queryVector = try await embeddingClient.embedding(input: query, model: embeddingModel)
            return .init(hits: try await vectorHits(
                queryVector: queryVector,
                publicRepoIDs: publicRepoIDs,
                privateRepoIDs: privateRepoIDs
            ))
        } catch {
            return .init(hits: [], error: error)
        }
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

/// 让并发分支把失败收敛回 Retriever，再按原规则决定是降级还是抛错。
/// `Error` 在 Swift Concurrency 中可跨任务传递；这里不保存它，也不让它越过本次检索边界。
private struct RAGRetrievalBranchResult: Sendable {
    var hits: [RAGChildHit]
    var error: (any Error)?
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
