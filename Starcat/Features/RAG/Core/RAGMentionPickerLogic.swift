//
//  RAGMentionPickerLogic.swift
//  Starcat
//
//  `@` 多选仓库弹窗的纯筛选 / 排序逻辑。
//  关键约束：筛选源仍是输入框里的 `@token`（方案 A），弹窗只展示结果；
//  已选项始终置顶，即使当前关键词不匹配，方便取消勾选。
//  列表截断只影响「未选命中」的展示条数；关键词仍对整个知识库匹配。
//

import Foundation
import GRDB

/// `@repo` 只需要展示和检索字段；完整 `Repo` 在用户真正选中时才按 ID 回读。
struct RAGMentionCandidate: Identifiable, Equatable, Sendable {
    var id: Int64
    var owner: String
    var name: String
    var fullName: String
    var language: String?
    var starsCount: Int
    var ownerAvatar: String?
    /// 知识库分片总数；0 表示未索引，行内不展示胶囊。
    var chunkCount: Int
    /// 是否存在 `ai_summaries` 记录。
    var hasAISummary: Bool
    /// 是否存在非空私有笔记（`repo_notes.content`）。
    var hasPrivateNote: Bool
    /// 小库内存过滤复用一次归一化结果，避免每个键入字符重复解析 topics 和拼接标签。
    var normalizedSearchText: String

    init(row: Row) {
        id = row["id"]
        owner = row["owner"]
        name = row["name"]
        fullName = row["full_name"]
        language = row["language"]
        starsCount = row["stars_count"]
        ownerAvatar = row["owner_avatar"]
        chunkCount = row["chunk_count"] ?? 0
        // EXISTS / CASE 在 SQLite 里是 0/1；GRDB 可能解成 Int64 或 Bool。
        hasAISummary = Self.databaseFlag(row["has_ai_summary"])
        hasPrivateNote = Self.databaseFlag(row["has_private_note"])
        let topics: String = row["topics"] ?? ""
        let tags: String = row["tag_names"] ?? ""
        let description: String = row["description"] ?? ""
        let status: String = row["status"] ?? ""
        normalizedSearchText = Self.normalize([
            fullName, description, language ?? "", topics, tags, status
        ].joined(separator: " "))
    }

    init(repo: Repo) {
        id = repo.id
        owner = repo.owner
        name = repo.name
        fullName = repo.fullName
        language = repo.language
        starsCount = repo.starsCount
        ownerAvatar = repo.ownerAvatar
        // 仅有完整 Repo 时没有索引侧投影；徽章留空，避免展示假数据。
        chunkCount = 0
        hasAISummary = false
        hasPrivateNote = false
        normalizedSearchText = Self.normalize([
            repo.fullName, repo.description ?? "", repo.language ?? "", repo.topicsArray.joined(separator: " ")
        ].joined(separator: " "))
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func databaseFlag(_ value: DatabaseValue?) -> Bool {
        guard let value, !value.isNull else { return false }
        if let bool = Bool.fromDatabaseValue(value) { return bool }
        if let int = Int64.fromDatabaseValue(value) { return int != 0 }
        return false
    }
}

/// `@` mention 候选列表的不可变快照，供 ViewModel / 单测共用。
struct RAGMentionPickerSnapshot: Equatable, Sendable {
    /// 实际渲染的仓库列表（已选置顶 + 未选命中）。
    var suggestions: [RAGMentionCandidate]
    /// 关键词命中总数（含已选且命中的），用于 footer。
    var matchCount: Int
    /// 知识库仓库总数。
    var knowledgeCount: Int
    /// 当前已选数量。
    var selectedCount: Int
    /// 当前列表实际展示条数（= suggestions.count）。
    var displayedCount: Int
    /// 未选命中是否因 displayLimit 被截断。
    var isTruncated: Bool
}

enum RAGMentionPickerLogic {
    /// 列表默认展示上限：已选全部保留，未选命中最多再塞这么多。
    static let unselectedDisplayLimit = 80
    /// Composer 明确上下文仓库上限。知识库可达数千，禁止「全选」一次塞满。
    static let maxSelectedRepoContexts = 20

    /// 按 `@` 后关键词过滤知识库候选，并把已选仓库固定置顶。
    static func build(
        candidates: [RAGMentionCandidate],
        selected: [Repo],
        query: String,
        knowledgeCount: Int? = nil,
        knownMatchCount: Int? = nil,
        pageHasMore: Bool = false
    ) -> RAGMentionPickerSnapshot {
        let knowledgeIDs = Set(candidates.map(\.id))
        let selectedInKnowledge = selected.filter { knowledgeIDs.contains($0.id) || knowledgeCount != nil }
        // 已选置顶优先复用当前页投影（含分片/摘要/笔记），避免 `Repo` 回填把徽章抹掉。
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let selectedCandidates = selectedInKnowledge.map { repo in
            candidateByID[repo.id] ?? RAGMentionCandidate(repo: repo)
        }
        let selectedIDs = Set(selectedCandidates.map(\.id))
        let normalizedQuery = RAGMentionCandidate.normalize(query)

        let matched = candidates.filter { candidate in
            normalizedQuery.isEmpty || candidate.normalizedSearchText.contains(normalizedQuery)
        }
        let matchCount = knownMatchCount ?? matched.count

        let unselectedMatched = matched
            .filter { !selectedIDs.contains($0.id) }
        let visibleUnselected = Array(unselectedMatched.prefix(unselectedDisplayLimit))
        let isTruncated = pageHasMore || unselectedMatched.count > visibleUnselected.count
        let suggestions = selectedCandidates + visibleUnselected

        return RAGMentionPickerSnapshot(
            suggestions: suggestions,
            matchCount: matchCount,
            knowledgeCount: knowledgeCount ?? candidates.count,
            selectedCount: selectedCandidates.count,
            displayedCount: suggestions.count,
            isTruncated: isTruncated
        )
    }

    /// 纯文本副行：语言 · stars；入库 Sheet 等仍复用。
    static func subtitle(for candidate: RAGMentionCandidate) -> String {
        let stars = "★ \(candidate.starsCount)"
        if let language = candidate.language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            return "\(language) · \(stars)"
        }
        return stars
    }
}
