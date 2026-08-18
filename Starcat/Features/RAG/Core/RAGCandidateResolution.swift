//
//  RAGCandidateResolution.swift
//  Starcat
//
//  候选窗口的本地执行层收口：Planner 的 candidateLimit 不可信，身份仓库必须能并进窗口。
//
//  关键约束：
//  - semantic_only 且没有筛选/排序时，设计约定是全库检索；执行层丢掉模型随手填的 50。
//  - 带 sort 的高星窗口仍合法（“在 star 最多的项目里找 …”），这时靠身份仓合并补洞。
//  - 合并只改变候选 repo 集合，不改 chunk 融合公式或 repoLimit。
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
