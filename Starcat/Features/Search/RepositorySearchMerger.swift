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
    ///
    /// 性能口径：身份匹配集合 = 「数字 ID 命中 ∪ 规范化名称命中」，`firstIndex`
    /// 语义等价于取两键命中下标的更小者，因此用「ID 首次出现下标 + 名称首次
    /// 出现下标」两张字典查表，合并整体从最坏 O(n·m) 降为 O(n+m)。注意 `0`
    /// 是可匹配 ID，仅 `nil` 不参与 ID 匹配（与 `isSameRepository` 口径一致）。
    static func merge(
        existing: [RepositoryCandidate],
        incoming: [RepositoryCandidate]
    ) -> [RepositoryCandidate] {
        var merged = existing

        var idFirstIndex: [Int64: Int] = [:]
        var nameFirstIndex: [String: Int] = [:]
        for (index, candidate) in merged.enumerated() {
            registerIdentity(
                candidate.identity,
                at: index,
                idFirstIndex: &idFirstIndex,
                nameFirstIndex: &nameFirstIndex
            )
        }

        for candidate in incoming {
            let identity = candidate.identity
            let idIndex = identity.ghRepoID.flatMap { idFirstIndex[$0] }
            let nameIndex = nameFirstIndex[identity.normalizedFullName]
            let matchIndex = [idIndex, nameIndex].compactMap { $0 }.min()

            guard let matchIndex else {
                let appendedIndex = merged.count
                merged.append(candidate)
                registerIdentity(
                    identity,
                    at: appendedIndex,
                    idFirstIndex: &idFirstIndex,
                    nameFirstIndex: &nameFirstIndex
                )
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
            if current.semanticReason == nil {
                current.semanticReason = candidate.semanticReason
            }
            merged[matchIndex] = current
        }
        return merged
    }

    /// 记录身份键的首次出现下标；键已存在时保留更早下标（`firstIndex` 语义）。
    ///
    /// 合并只改来源与本地状态字段、不改 `identity` 本身，所以已登记的下标在
    /// 多轮合并后依然有效，无需重建字典。
    private static func registerIdentity(
        _ identity: RepoIdentity,
        at index: Int,
        idFirstIndex: inout [Int64: Int],
        nameFirstIndex: inout [String: Int]
    ) {
        if let id = identity.ghRepoID, idFirstIndex[id] == nil {
            idFirstIndex[id] = index
        }
        let name = identity.normalizedFullName
        if nameFirstIndex[name] == nil {
            nameFirstIndex[name] = index
        }
    }

    static func isSameRepository(_ lhs: RepoIdentity, _ rhs: RepoIdentity) -> Bool {
        if let lhsID = lhs.ghRepoID, let rhsID = rhs.ghRepoID, lhsID == rhsID {
            return true
        }
        return lhs.normalizedFullName == rhs.normalizedFullName
    }
}
