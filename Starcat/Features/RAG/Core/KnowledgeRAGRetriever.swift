//
//  KnowledgeRAGRetriever.swift
//  Starcat
//
//  Repo-aware parent-child 检索编排。
//
//  child chunk 用于找准分片，命中后按 parent_key 扩展章节，再按 repo 聚合为
//  RepoContextBundle。Generator 因而拿到的是“repo + 完整相关章节”，不是失去归属的碎片。
//

import Foundation

/// Parent 扩展与命中裁剪需要同时回传；正文仍只存在 bundle，不写入会话轨迹。
private struct RAGBundleBuildResult {
    var bundles: [RepoContextBundle]
    var parentTokenLimitedChunkIDs: Set<Int64>
}

struct KnowledgeRAGRetriever: Sendable {
    private let chunkRepository: any RAGChunkRepositoryProtocol
    private let keywordProvider: any RAGKeywordSearchProvider
    private let vectorProvider: any RAGVectorSearchProvider
    private let reranker: (any RAGReranking)?
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
    private let retrievalSettings: RAGRetrievalSettings

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
        retrievalSettings: RAGRetrievalSettings = .balanced,
        reranker: (any RAGReranking)? = nil
    ) {
        let retrievalSettings = retrievalSettings.normalized()
        var fusionConfiguration = fusion.configuration
        fusionConfiguration.perRepoLimit = retrievalSettings.perRepositoryEvidenceLimit
        fusionConfiguration.totalLimit = retrievalSettings.finalEvidenceChunkLimit
        self.chunkRepository = chunkRepository
        self.keywordProvider = keywordProvider
        self.vectorProvider = vectorProvider
        self.reranker = reranker
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
        self.retrievalSettings = retrievalSettings
    }

    func hasReadyChunks(repoIDs: [Int64]) async throws -> Bool {
        guard !repoIDs.isEmpty else { return false }
        return try await chunkRepository.hasReadyChunks(model: embeddingModel, repoIDs: repoIDs)
    }

    var hasEnabledSources: Bool { !enabledSources.isEmpty }

    /// Service 在 Retriever 尚未运行（例如没有 ready chunk）时，也要能导出本轮生效设置与终止原因。
    func diagnostics(
        candidateRepoCount: Int,
        outcome: RAGRetrievalDiagnostics.Outcome
    ) -> RAGRetrievalDiagnostics {
        RAGRetrievalDiagnostics(
            settings: retrievalSettings,
            candidateRepoCount: candidateRepoCount,
            outcome: outcome
        )
    }

    func retrieve(
        semanticQuery: String,
        keywordQueries: [String] = [],
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64],
        progress: @Sendable (RAGRetrievalProgress) -> Void = { _ in }
    ) async throws -> RAGRetrievalResult {
        let query = semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !candidates.isEmpty else {
            return RAGRetrievalResult(
                candidates: candidates,
                bundles: [],
                childHits: [],
                diagnostics: diagnostics(candidateRepoCount: candidates.count, outcome: .noCandidates),
                trace: RAGRetrievalTrace(candidates: candidateTrace(candidates))
            )
        }
        guard !enabledSources.isEmpty else {
            return RAGRetrievalResult(
                candidates: candidates,
                bundles: [],
                childHits: [],
                diagnostics: diagnostics(candidateRepoCount: candidates.count, outcome: .sourcesDisabled),
                trace: RAGRetrievalTrace(candidates: candidateTrace(candidates))
            )
        }

        let publicRepoIDs = candidates.filter { !$0.repo.isPrivate }.map(\.repo.id)
        let privateRepoIDs = candidates.filter(\.repo.isPrivate).map(\.repo.id)
        let keywordQuery = RAGKeywordQueryBuilder.build(
            keywordQueries: keywordQueries,
            semanticQuery: query
        )
        // keyword 与 query embedding/vector 没有数据依赖。先同时启动两路，既保留原来的
        // 独立降级语义，也避免网络 embedding 的等待时间串行叠加到 FTS 查询之后。
        progress(.keywordSearchStarted)
        progress(.semanticSearchStarted)
        async let keywordResult = keywordRetrieval(
            query: keywordQuery,
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
        let sourceEligibleVectorHits = vector.hits.filter { enabledSources.contains($0.chunk.source) }
        let eligibleVectorHits = sourceEligibleVectorHits.filter {
            ($0.vectorSimilarity ?? $0.score) >= minimumVectorSimilarity
        }
        progress(.keywordSearchCompleted(eligibleKeywordHits.count))
        progress(.semanticSearchCompleted(eligibleVectorHits.count))
        if failures.count == 2, let error = failures.first { throw error }
        let preferred = explicitMode == .prefer ? Set(explicitRepoIDs) : []
        let fusedCandidates = fusion.fuseWithDiagnostics(
            keywordHits: eligibleKeywordHits,
            vectorHits: eligibleVectorHits,
            preferredRepoIDs: preferred,
            appliesLimits: false
        )
        let repositoryNames = Dictionary(uniqueKeysWithValues: candidates.map { ($0.repo.id, $0.repo.fullName) })
        let rerankResult = await rerankCandidates(
            fusedCandidates.hits,
            query: query,
            repositoryNames: repositoryNames
        )
        let fusionResult = fusion.applyLimits(to: rerankResult.hits)
        let hits = fusionResult.hits.filter { $0.score >= minimumEvidenceScore }
        let bundleBuild = try await buildBundles(hits: hits, candidates: candidates)
        let bundles = bundleBuild.bundles
        let trace = RAGRetrievalTrace(
            keywordQuery: RAGKeywordQueryTrace(query: keywordQuery),
            candidates: candidateTrace(candidates),
            keywordHits: hitTrace(
                keyword.hits,
                repositoryNames: repositoryNames,
                disposition: { enabledSources.contains($0.chunk.source) ? .retained : .sourceDisabled }
            ),
            semanticHits: hitTrace(
                vector.hits,
                repositoryNames: repositoryNames,
                disposition: { hit in
                    guard enabledSources.contains(hit.chunk.source) else { return .sourceDisabled }
                    return (hit.vectorSimilarity ?? hit.score) >= minimumVectorSimilarity
                        ? .retained
                        : .belowVectorSimilarity
                }
            ),
            fusionHits: fusionTrace(
                rerankResult.hits,
                repositoryNames: repositoryNames
            ),
            finalEvidence: hitTrace(
                hits,
                repositoryNames: repositoryNames,
                disposition: { hit in
                    guard let chunkID = hit.chunk.id,
                          bundleBuild.parentTokenLimitedChunkIDs.contains(chunkID) else { return .retained }
                    return .parentContextTokenLimit
                }
            ),
            rerank: rerankResult.diagnostics.trace
        )
        let diagnostics = RAGRetrievalDiagnostics(
            settings: retrievalSettings,
            candidateRepoCount: candidates.count,
            keywordQuery: RAGKeywordQueryTrace(query: keywordQuery),
            keywordRawCount: keyword.hits.count,
            keywordSourceFilteredCount: keyword.hits.count - eligibleKeywordHits.count,
            keywordErrorDescription: keyword.error?.localizedDescription,
            vectorRawCount: vector.hits.count,
            vectorSourceFilteredCount: vector.hits.count - sourceEligibleVectorHits.count,
            vectorSimilarityFilteredCount: sourceEligibleVectorHits.count - eligibleVectorHits.count,
            vectorErrorDescription: vector.error?.localizedDescription,
            fusion: fusionResult.diagnostics,
            minimumEvidenceScoreFilteredCount: fusionResult.hits.count - hits.count,
            rerank: rerankResult.diagnostics,
            finalChildHitCount: hits.count,
            bundleCount: bundles.count,
            outcome: bundles.isEmpty ? .noEvidence : .completed
        )
        progress(.evidencePacked(hitCount: hits.count, bundleCount: bundles.count))
        return RAGRetrievalResult(
            candidates: candidates,
            bundles: bundles,
            childHits: hits,
            diagnostics: diagnostics,
            trace: trace
        )
    }

    /// 把当前轮内存命中收成可持久化的最小审计数据；分片正文不可进入会话轨迹，避免历史库成为知识库副本。
    private func hitTrace(
        _ hits: [RAGChildHit],
        repositoryNames: [Int64: String],
        disposition: (RAGChildHit) -> RAGRetrievalTraceDisposition
    ) -> [RAGRetrievalHitTrace] {
        hits.enumerated().map { index, hit in
            RAGRetrievalHitTrace(
                chunkID: hit.chunk.id,
                repoID: hit.chunk.repoId,
                repositoryName: repositoryNames[hit.chunk.repoId] ?? "#\(hit.chunk.repoId)",
                source: hit.chunk.source,
                sectionTitle: hit.chunk.sectionPath.isEmpty ? hit.chunk.title : hit.chunk.sectionPath,
                rank: index + 1,
                score: hit.score,
                hitKind: hit.kind,
                vectorSimilarity: hit.vectorSimilarity,
                scoreBreakdown: hit.scoreBreakdown,
                disposition: disposition(hit)
            )
        }
    }

    /// 裁剪顺序必须与 `RAGHybridFusionEngine.applyLimits` 完全一致；否则 UI 会把“为何过滤”解释错。
    private func fusionTrace(
        _ hits: [RAGChildHit],
        repositoryNames: [Int64: String]
    ) -> [RAGRetrievalHitTrace] {
        var acceptedByRepository: [Int64: Int] = [:]
        var acceptedAfterRepositoryLimit = 0
        return hitTrace(hits, repositoryNames: repositoryNames) { hit in
            let repositoryCount = acceptedByRepository[hit.chunk.repoId, default: 0]
            guard repositoryCount < retrievalSettings.perRepositoryEvidenceLimit else {
                return .perRepositoryLimit
            }
            acceptedByRepository[hit.chunk.repoId] = repositoryCount + 1
            guard acceptedAfterRepositoryLimit < retrievalSettings.finalEvidenceChunkLimit else {
                return .totalLimit
            }
            acceptedAfterRepositoryLimit += 1
            return hit.score >= minimumEvidenceScore ? .retained : .belowEvidenceScore
        }
    }

    private func candidateTrace(_ candidates: [RAGRepoCandidate]) -> [RAGRetrievalCandidateTrace] {
        candidates.map {
            RAGRetrievalCandidateTrace(
                repoID: $0.repo.id,
                fullName: $0.repo.fullName,
                language: $0.repo.language,
                stars: $0.repo.starsCount
            )
        }
    }

    private func rerankCandidates(
        _ candidates: [RAGChildHit],
        query: String,
        repositoryNames: [Int64: String]
    ) async -> (hits: [RAGChildHit], diagnostics: RAGRerankDiagnostics) {
        guard let reranker else {
            return (candidates, RAGRerankDiagnostics(state: .disabled))
        }
        guard !candidates.isEmpty else {
            return (candidates, RAGRerankDiagnostics(state: .skipped, provider: reranker.provider))
        }
        // 内置 provider 会在发送前按 candidateLimit 截断。Trace 也使用同一份候选快照，
        // 才能让 inputIndex 与服务端响应 index 一一对应。
        let requestCandidates = reranker.debugCandidateLimit.map { Array(candidates.prefix($0)) } ?? candidates
        let inputCandidates = requestCandidates.enumerated().map { index, hit in
            RAGRerankTrace.InputCandidate(
                inputIndex: index,
                repositoryName: repositoryNames[hit.chunk.repoId] ?? "#\(hit.chunk.repoId)",
                source: hit.chunk.source,
                section: hit.chunk.sectionPath,
                preRerankScore: hit.score
            )
        }
        let startedAt = Date()
        do {
            let reranked = try await reranker.rerank(query: query, candidates: candidates)
            // 服务端漏掉个别 index 时，保留未返回候选的原融合顺序，避免 Rerank 响应不完整导致分片丢失。
            let rerankedIDs = Set(reranked.compactMap { $0.hit.chunk.id })
            let trailing = candidates.filter { hit in
                guard let id = hit.chunk.id else { return true }
                return !rerankedIDs.contains(id)
            }
            let appliedHits = reranked.map(\.hit) + trailing
            let responseResults = reranked.compactMap { item -> RAGRerankTrace.ResponseResult? in
                guard let inputIndex = requestCandidates.firstIndex(of: item.hit) else { return nil }
                return .init(inputIndex: inputIndex, rerankScore: item.score)
            }
            // 异常服务可能重复返回相同 index；诊断不能因远端坏数据崩溃，最后一个结果即可
            // 覆盖前一个同 index 分数，实际排序仍沿用 provider 已解析出的返回顺序。
            var scoreByInputIndex: [Int: Double] = [:]
            for result in responseResults {
                scoreByInputIndex[result.inputIndex] = result.rerankScore
            }
            let appliedOrder = appliedHits.enumerated().map { index, hit in
                let inputIndex = requestCandidates.firstIndex(of: hit)
                return RAGRerankTrace.AppliedItem(
                    rank: index + 1,
                    inputIndex: inputIndex,
                    rerankScore: inputIndex.flatMap { scoreByInputIndex[$0] }
                )
            }
            let trace = RAGRerankTrace(
                query: query,
                model: reranker.debugModel,
                candidateLimit: reranker.debugCandidateLimit,
                inputCandidates: inputCandidates,
                responseResults: responseResults,
                appliedOrder: appliedOrder
            )
            return (appliedHits, RAGRerankDiagnostics(
                state: .completed,
                provider: reranker.provider,
                candidateCount: requestCandidates.count,
                rerankedCount: reranked.count,
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                trace: trace
            ))
        } catch {
            AppLog.ai.warning("RAG rerank degraded: \(error.localizedDescription, privacy: .public)")
            return (candidates, RAGRerankDiagnostics(
                state: .failedFallback,
                provider: reranker.provider,
                candidateCount: requestCandidates.count,
                elapsedSeconds: Date().timeIntervalSince(startedAt),
                errorDescription: error.localizedDescription,
                trace: RAGRerankTrace(
                    query: query,
                    model: reranker.debugModel,
                    candidateLimit: reranker.debugCandidateLimit,
                    inputCandidates: inputCandidates,
                    responseResults: [],
                    appliedOrder: candidates.enumerated().map { index, hit in
                        .init(
                            rank: index + 1,
                            inputIndex: requestCandidates.firstIndex(of: hit),
                            rerankScore: nil
                        )
                    }
                )
            ))
        }
    }

    private func buildBundles(hits: [RAGChildHit], candidates: [RAGRepoCandidate]) async throws -> RAGBundleBuildResult {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.repo.id, $0) })
        let grouped = Dictionary(grouping: hits, by: { $0.chunk.repoId })
        // Metadata 不是普通 parent：它以 keyword_only 形式由专用批量查询附加到最终 repo bundle，
        // 不能走只接受 ready+model 的 parent 扩展，否则 Metadata 命中会得到空正文。
        let parentKeys = Set(hits.compactMap { hit -> RAGChunkParentKey? in
            guard hit.chunk.source != .metadata else { return nil }
            return RAGChunkParentKey(repoID: hit.chunk.repoId, parentKey: hit.chunk.parentKey)
        })
        // 命中的 parent 一次性加载，避免每个 child hit 都触发一次 SQLite read。
        // 随后按完整 parent 身份分组，维持原有 repo/section 隔离和 chunk 顺序。
        let siblingsByParent = Dictionary(grouping: try await chunkRepository.fetchChunks(
            parents: Array(parentKeys),
            model: embeddingModel
        )) { RAGChunkParentKey(repoID: $0.repoId, parentKey: $0.parentKey) }
        var bundles: [RepoContextBundle] = []
        var parentTokenLimitedChunkIDs = Set<Int64>()

        for (repoID, repoHits) in grouped {
            guard let candidate = candidateByID[repoID] else { continue }
            var parents: [RAGSectionParent] = []
            var seenParents = Set<String>()
            for hit in repoHits where hit.chunk.source != .metadata && seenParents.insert(hit.chunk.parentKey).inserted {
                let siblings = siblingsByParent[
                    RAGChunkParentKey(repoID: repoID, parentKey: hit.chunk.parentKey)
                ] ?? []
                let selected = parentPacker.select(
                    chunks: siblings,
                    anchorChunkID: hit.chunk.id,
                    tokenLimit: parentTokenLimit
                )
                // 同一 parent 内的其它命中若未能随 anchor 进入展开上下文，原因只能是
                // 父段落 token 上限；保留 chunk id 即可在 UI 与历史中解释，无需复制正文。
                let selectedChunkIDs = Set(selected.compactMap(\.id))
                let matchedChunkIDs = repoHits
                    .filter { $0.chunk.parentKey == hit.chunk.parentKey }
                    .compactMap { $0.chunk.id }
                parentTokenLimitedChunkIDs.formUnion(matchedChunkIDs.filter { !selectedChunkIDs.contains($0) })
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
        var limitedBundles = bundles.sorted { $0.score > $1.score }.prefix(repoLimit).map { $0 }
        let metadataByRepoID = Dictionary(
            uniqueKeysWithValues: try await chunkRepository.fetchActiveMetadata(
                repoIDs: limitedBundles.map { $0.candidate.repo.id }
            ).map { ($0.repoId, $0.content) }
        )
        for index in limitedBundles.indices {
            limitedBundles[index].metadataContent = metadataByRepoID[limitedBundles[index].candidate.repo.id]
        }
        return RAGBundleBuildResult(
            bundles: limitedBundles,
            parentTokenLimitedChunkIDs: parentTokenLimitedChunkIDs
        )
    }

    private func keywordHits(
        query: RAGKeywordSearchQuery,
        publicRepoIDs: [Int64],
        privateRepoIDs: [Int64]
    ) async throws -> [RAGChildHit] {
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
        query: RAGKeywordSearchQuery,
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
/// README 中后段命中会生成“citation 指向后段、prompt 却只含开头”的错误分片关系。
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
