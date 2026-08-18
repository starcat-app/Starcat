//
//  RAGCandidateResolution.swift
//  Starcat
//
//  候选窗口的本地执行层收口：Planner 的 candidateLimit 不可信，身份仓库必须能并进窗口。
//
//  关键约束：
//  - semantic_only 且没有筛选/排序时，设计约定是全库检索；执行层丢掉模型随手填的 50。
//  - 带 sort 的高星窗口仍合法（“在 star 最多的项目里找 …”），这时靠身份仓合并补洞。
//  - 列表类问题按身份仓数放宽 bundle 上限；深挖单仓仍走 Retriever 默认 5。
//

import Foundation

/// Planner 可能把 `semantic_only` 写成带 `candidateLimit` 的高星抽样。
/// 对齐设计文档：无筛选、无排序时执行层恢复全库。
enum RAGCandidateWindowGuard {
    static func resolve(_ initialPlan: RAGQueryPlan) -> RAGQueryPlan {
        var plan = initialPlan
        guard plan.mode == .semanticOnly,
              !plan.filters.hasEffectiveConditions,
              plan.sort == nil else { return plan }
        plan.candidateLimit = nil
        return plan
    }
}

enum RAGRetrievalTestMode: String, CaseIterable, Identifiable, Sendable {
    case indexOracle
    case followPlan

    var id: String { rawValue }
}

/// 计划窗口 + 身份仓合并后的可执行候选。`identityRepoIDs` 只含身份 SQL 命中，不含高星窗口。
struct RAGResolvedRetrievalCandidates: Equatable, Sendable {
    var candidates: [RAGRepoCandidate]
    var identityRepoIDs: [Int64]
    var identityTerms: [String]

    var hasIdentityAnchor: Bool { !identityTerms.isEmpty }
}

/// 实体列表要把多个同名仓展开成 bundle；深挖仍用 Retriever 默认 5。
enum RAGIdentityBundleLimit {
    static let `default` = 5
    static let maximum = 12

    static func repoLimit(identityCount: Int, defaultLimit: Int = `default`) -> Int {
        guard identityCount >= 2 else { return defaultLimit }
        return min(max(identityCount, defaultLimit), maximum)
    }

    /// 列表题至少给每个身份仓留 1 条分片，否则 `finalEvidenceChunkLimit=8` 会先吃高星噪音。
    static func evidenceChunkLimit(identityCount: Int, configured: Int) -> Int {
        guard identityCount >= 2 else { return configured }
        return max(configured, min(identityCount, maximum))
    }
}

/// `applyLimits` 按当前顺序从头截断。身份仓必须轮询排在噪音前面，才能占满列表额度。
enum RAGIdentityHitPrioritizer {
    static func order(_ hits: [RAGChildHit], identityRepoIDs: [Int64]) -> [RAGChildHit] {
        guard identityRepoIDs.count >= 2 else { return hits }
        let identitySet = Set(identityRepoIDs)
        let identityHits = hits.filter { identitySet.contains($0.chunk.repoId) }
        let otherHits = hits.filter { !identitySet.contains($0.chunk.repoId) }
        var grouped = Dictionary(grouping: identityHits, by: { $0.chunk.repoId })
        for repoID in grouped.keys {
            grouped[repoID]?.sort { lhs, rhs in
                if lhs.score == rhs.score { return lhs.chunk.chunkIndex < rhs.chunk.chunkIndex }
                return lhs.score > rhs.score
            }
        }
        var roundRobin: [RAGChildHit] = []
        var round = 0
        while true {
            var appended = false
            for repoID in identityRepoIDs {
                guard let bucket = grouped[repoID], round < bucket.count else { continue }
                roundRobin.append(bucket[round])
                appended = true
            }
            if !appended { break }
            round += 1
        }
        return roundRobin + otherHits
    }
}

/// 身份命中必须排在计划窗口前面，且不受 `candidateLimit` 截断。
enum RAGRepoCandidateMerger {
    static func merge(identity: [RAGRepoCandidate], window: [RAGRepoCandidate]) -> [RAGRepoCandidate] {
        var seen = Set<Int64>()
        var result: [RAGRepoCandidate] = []
        result.reserveCapacity(identity.count + window.count)
        for candidate in identity + window {
            guard seen.insert(candidate.repo.id).inserted else { continue }
            result.append(candidate)
        }
        return result
    }
}

/// 召回测试的两条产品路径。默认全库 oracle，避免再被当成问答预演。
enum RAGRetrievalTestScope: Equatable, Sendable {
    case indexOracle
    case followPlan(RAGQueryPlan)
}

/// 把测试框原句和当前问答计划收成可执行的候选计划；分片 query 仍用原句。
enum RAGRetrievalTestPlanning {
    static let identityCandidateLimit = 40

    static func resolve(query: String, scope: RAGRetrievalTestScope) -> RAGQueryPlan {
        switch scope {
        case .indexOracle:
            return RAGQueryPlan(mode: .semanticOnly, semanticQuery: query)
        case .followPlan(let displayed):
            var plan = displayed
            plan.semanticQuery = query
            // 召回测试要看分片，不能沿用 analytics 把候选整段跳过。
            plan.analytics = nil
            switch plan.mode {
            case .structuredOnly, .guidedDiscovery, .needsClarification:
                plan.mode = plan.filters.hasEffectiveConditions || plan.sort != nil
                    ? .filteredSemantic
                    : .semanticOnly
            case .semanticOnly, .filteredSemantic:
                break
            }
            return RAGCandidateWindowGuard.resolve(plan)
        }
    }
}
