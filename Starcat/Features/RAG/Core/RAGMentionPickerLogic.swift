//
//  RAGMentionPickerLogic.swift
//  Starcat
//
//  `@` 多选仓库弹窗的纯筛选 / 排序逻辑。
//  关键约束：筛选源仍是输入框里的 `@token`（方案 A），弹窗只展示结果；
//  已选项始终置顶，即使当前关键词不匹配，方便取消勾选。
//

import Foundation

/// `@` mention 候选列表的不可变快照，供 ViewModel / 单测共用。
struct RAGMentionPickerSnapshot: Equatable, Sendable {
    /// 实际渲染的仓库列表（已选置顶 + 未选命中）。
    var suggestions: [Repo]
    /// 关键词命中总数（含已选且命中的），用于 footer「继续缩小范围」。
    var matchCount: Int
    /// 知识库仓库总数。
    var knowledgeCount: Int
    /// 当前已选数量。
    var selectedCount: Int
    /// 未选命中是否因 displayLimit 被截断。
    var isTruncated: Bool
}

enum RAGMentionPickerLogic {
    /// 列表默认展示上限：已选全部保留，未选命中最多再塞这么多。
    static let unselectedDisplayLimit = 40

    /// 按 `@` 后关键词过滤知识库候选，并把已选仓库固定置顶。
    static func build(
        candidates: [RAGRepoCandidate],
        selected: [Repo],
        query: String
    ) -> RAGMentionPickerSnapshot {
        let knowledgeIDs = Set(candidates.map(\.repo.id))
        let selectedInKnowledge = selected.filter { knowledgeIDs.contains($0.id) }
        let selectedIDs = Set(selectedInKnowledge.map(\.id))

        let matched = candidates.filter { candidate in
            matches(candidate: candidate, query: query)
        }
        let matchCount = matched.count

        let unselectedMatched = matched
            .map(\.repo)
            .filter { !selectedIDs.contains($0.id) }
        let visibleUnselected = Array(unselectedMatched.prefix(unselectedDisplayLimit))
        let isTruncated = unselectedMatched.count > visibleUnselected.count

        return RAGMentionPickerSnapshot(
            suggestions: selectedInKnowledge + visibleUnselected,
            matchCount: matchCount,
            knowledgeCount: candidates.count,
            selectedCount: selectedInKnowledge.count,
            isTruncated: isTruncated
        )
    }

    /// 副标题：语言 · stars；无语言时只显示 stars，避免空行。
    static func subtitle(for repo: Repo) -> String {
        let stars = "★ \(repo.starsCount)"
        if let language = repo.language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            return "\(language) · \(stars)"
        }
        return stars
    }

    private static func matches(candidate: RAGRepoCandidate, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let repo = candidate.repo
        let searchable = [
            repo.fullName,
            repo.description ?? "",
            repo.language ?? "",
            repo.topicsArray.joined(separator: " "),
            candidate.tagNames.joined(separator: " "),
            candidate.status.rawValue
        ].joined(separator: " ")
        return searchable.localizedCaseInsensitiveContains(query)
    }
}
