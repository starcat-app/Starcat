//
//  RepositorySearchMerger.swift
//  Starcat
//
//  仓库搜索候选的纯函数合并器。
//
//  Search Center、MCP 和外部启动器必须共享同一套去重与本地优先规则，
//  否则同一个查询会因入口不同而出现来源标识和打开行为漂移。
//

import Foundation

enum RepositorySearchMerger {
    /// 合并同一仓库的来源和本地状态，同时保持 `existing` 的原始顺序。
    ///
    /// GitHub 数字 ID 是稳定身份；任一来源缺少 ID 时才退化为规范化的
    /// `owner/name`。本地候选应由调用方放在 `existing`，以落实本地优先排序。
    static func merge(
        existing: [RepositoryCandidate],
        incoming: [RepositoryCandidate]
    ) -> [RepositoryCandidate] {
        var merged = existing

        for candidate in incoming {
            let matchIndex = merged.firstIndex { current in
                isSameRepository(current.identity, candidate.identity)
            }

            guard let matchIndex else {
                merged.append(candidate)
                continue
            }

            var current = merged[matchIndex]
            current.sources.formUnion(candidate.sources)
            if current.localRepo == nil, let localRepo = candidate.localRepo {
                current.localRepo = localRepo
                current.card = candidate.card
            }
            if current.remoteRepo == nil {
                current.remoteRepo = candidate.remoteRepo
            }
            if current.semanticScore == nil {
                current.semanticScore = candidate.semanticScore
            }
            merged[matchIndex] = current
        }
        return merged
    }

    static func isSameRepository(_ lhs: RepoIdentity, _ rhs: RepoIdentity) -> Bool {
        if let lhsID = lhs.ghRepoID, let rhsID = rhs.ghRepoID, lhsID == rhsID {
            return true
        }
        return lhs.normalizedFullName == rhs.normalizedFullName
    }
}
