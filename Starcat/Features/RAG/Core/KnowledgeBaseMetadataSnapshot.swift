//
//  KnowledgeBaseMetadataSnapshot.swift
//  Starcat
//
//  知识库 RAG 的全局元数据快照。
//
//  这个快照只包含本地 SQLite 的聚合事实，不携带 README、笔记或分片正文。它让回答模型
//  能处理“知识库有多少项目”这类不适合向量检索的问题，同时避免每轮都发送完整项目清单。
//

import Foundation
import GRDB

/// 注入回答 Prompt 的知识库全局事实；数组已由仓储限制，防止统计维度挤占分片预算。
struct KnowledgeBaseMetadataSnapshot: Equatable, Sendable {
    struct NamedCount: Equatable, Sendable {
        let name: String
        let count: Int
    }

    struct TopRepository: Equatable, Sendable {
        let repoID: Int64
        let fullName: String
        let stars: Int
    }

    struct IndexHealth: Equatable, Sendable {
        let totalChunks: Int
        /// 使用当前 embedding model、可参与向量检索的分片。
        let readyChunks: Int
        /// Metadata 等无需 embedding、仅通过 FTS 参与关键词检索的可用分片。
        let keywordOnlyChunks: Int
        let pendingChunks: Int
        let failedChunks: Int
        let staleChunks: Int
        let embeddingModel: String
    }

    /// 每种 RAG 来源在当前知识库中的实际索引覆盖。这里只记录聚合数量，不携带来源正文或仓库名单。
    struct SourceIndexCoverage: Equatable, Sendable {
        let source: RAGChunkSource
        let repositoryCount: Int
        /// 未被用户排除的分片总数；repositoryCount 则保留“来源有内容”的原始覆盖口径。
        let chunkCount: Int
        /// 当前可检索分片，含当前 embedding model 的 ready 与无需向量化的 keyword-only 来源。
        let readyChunkCount: Int
        let failedChunkCount: Int
        /// stale 状态或 ready 但 embedding model 已过期的分片；不与 failed 重复计数。
        let staleChunkCount: Int
    }

    /// 快照的计算时刻（每次读取都刷新）。仅用于内部诊断，不直接展示为「更新时间」。
    let generatedAt: Date
    /// 知识库内容最后一次变化时间：在库仓库里最新的 `library_updated_at`。
    /// 代表数据本身的新鲜度；空库或历史数据缺失时为 nil。
    let contentUpdatedAt: Date?
    let projectCount: Int
    let starredProjectCount: Int
    let retainedAfterUnstarCount: Int
    /// 下钻到“全部仓库”时使用 Star 范围统计，不能复用知识库 Prompt 的整理口径。
    let starredStatusCounts: [NamedCount]
    let statusCounts: [NamedCount]
    let starredTaggedProjectCount: Int
    let starredUntaggedProjectCount: Int
    let taggedProjectCount: Int
    let untaggedProjectCount: Int
    let tagCount: Int
    let knownLanguageProjectCount: Int
    let unknownLanguageProjectCount: Int
    let topLanguages: [NamedCount]
    let topTags: [NamedCount]
    let addedInLast30DaysCount: Int
    let pushedInLast30DaysCount: Int
    /// 每个仓库最多计一次，避免用户切换模型后多条摘要缓存放大覆盖率。
    let aiSummaryProjectCount: Int
    /// 只统计正文非空的笔记；`repo_notes` 的状态行不应被误当作笔记内容。
    let privateNoteProjectCount: Int
    let aiGeneratedNoteProjectCount: Int
    /// 近 30 天编辑过正文非空私有笔记的仓库数；按仓库去重。
    let privateNotesEditedInLast30DaysProjectCount: Int
    /// 近 30 天生成过任一 AI 摘要的仓库数；旧摘要不因此被判定为失效。
    let aiSummariesGeneratedInLast30DaysProjectCount: Int
    let sourceIndexCoverage: [SourceIndexCoverage]
    let excludedChunkCount: Int
    /// 没有生成过 README 来源分片的仓库数；用户排除 README 不改变“有内容”事实。
    let withoutReadmeSourceProjectCount: Int
    /// 不存在任何未排除 RAG 来源分片的仓库数，用于解释为什么无法召回。
    let withoutIndexableSourceProjectCount: Int
    let topStarredRepositories: [TopRepository]
    let indexHealth: IndexHealth

    /// 保持英文、键值式表达，避免受显示语言或自定义 Prompt 影响而改变数据库事实的含义。
    func promptContext() -> String {
        let status = rendered(statusCounts)
        let languages = rendered(topLanguages)
        let tags = rendered(topTags)
        let topRepositories = topStarredRepositories.map { "\($0.fullName) (\($0.stars) stars)" }
            .joined(separator: "; ")
        let sourceCoverage = sourceIndexCoverage.map {
            "\($0.source.rawValue): \($0.repositoryCount) repositories with content, \($0.readyChunkCount) ready, \($0.failedChunkCount) failed, \($0.staleChunkCount) stale, \($0.chunkCount) active chunks"
        }.joined(separator: "; ")
        return """
        Authoritative local knowledge-base metadata snapshot (generated now; not vector-search evidence):
        - Scope: \(projectCount) in-library repositories; \(starredProjectCount) still starred; \(retainedAfterUnstarCount) retained after unstar.
        - Organization: status counts [\(status)]; \(taggedProjectCount) tagged; \(untaggedProjectCount) untagged; \(tagCount) distinct tags.
        - Technology: \(knownLanguageProjectCount) repositories have a language; \(unknownLanguageProjectCount) unknown; top languages [\(languages)].
        - Top tags: [\(tags)].
        - Activity: \(addedInLast30DaysCount) added to the library in the last 30 days; \(pushedInLast30DaysCount) repositories pushed in the last 30 days.
        - Knowledge artifacts: \(aiSummaryProjectCount) repositories have an AI summary; \(privateNoteProjectCount) have private notes (\(aiGeneratedNoteProjectCount) AI-generated).
        - Content freshness: \(privateNotesEditedInLast30DaysProjectCount) repositories had private notes edited in the last 30 days; \(aiSummariesGeneratedInLast30DaysProjectCount) had AI summaries generated in the last 30 days. Older summaries are not automatically invalid.
        - Indexed source coverage: [\(sourceCoverage)].
        - Index availability: \(excludedChunkCount) chunks are excluded; \(withoutReadmeSourceProjectCount) repositories have no README source; \(withoutIndexableSourceProjectCount) have no active indexable source.
        - Star leaders (top \(topStarredRepositories.count)): [\(topRepositories)].
        - RAG index for model \(indexHealth.embeddingModel): \(indexHealth.totalChunks) active chunks; vector-ready \(indexHealth.readyChunks), keyword-ready \(indexHealth.keywordOnlyChunks), pending \(indexHealth.pendingChunks), failed \(indexHealth.failedChunks), stale \(indexHealth.staleChunks).
        Use these values as database facts for applicable count, distribution, activity, index-health, and star-ranking questions. Do not fabricate chunk citations for this snapshot. If a requested exact value is not present here, say the snapshot does not contain it.
        """
    }

    /// 规划阶段只需知道有哪些可验证的库存事实，不应重复发送标签排行或 Star Top10 等生成阶段信息。
    func plannerPromptContext() -> String {
        let sourceCoverage = sourceIndexCoverage.map {
            "\($0.source.rawValue): \($0.repositoryCount) repositories / \($0.readyChunkCount) ready / \($0.failedChunkCount) failed / \($0.staleChunkCount) stale"
        }.joined(separator: "; ")
        return """
        Authoritative local knowledge-base inventory (aggregate counts only; no repository names or content):
        - Scope: \(projectCount) in-library repositories.
        - AI summaries: \(aiSummaryProjectCount) repositories; private notes: \(privateNoteProjectCount) repositories (\(aiGeneratedNoteProjectCount) AI-generated).
        - Last 30 days: \(privateNotesEditedInLast30DaysProjectCount) repositories with edited private notes; \(aiSummariesGeneratedInLast30DaysProjectCount) with generated AI summaries.
        - Indexed source coverage: [\(sourceCoverage)].
        - Index availability: \(excludedChunkCount) excluded chunks; \(withoutReadmeSourceProjectCount) repositories without a README source; \(withoutIndexableSourceProjectCount) without an active indexable source.
        Use this only to choose a supported local inventory analytics metric when the user asks for these counts. Do not invent an unsupported metric or treat these aggregates as vector-search evidence.
        """
    }

    private func rendered(_ counts: [NamedCount]) -> String {
        counts.map { "\($0.name): \($0.count)" }.joined(separator: ", ")
    }
}

/// 只读构建快照；所有 SQL 结构固定，模型和用户输入都不会进入 SQL。
struct KnowledgeBaseMetadataSnapshotProvider: Sendable {
    private static let distributionLimit = 8
    private static let topStarredLimit = 10

    private let database: any DatabaseManaging
    private let embeddingModel: String

    init(database: any DatabaseManaging, embeddingModel: String) {
        self.database = database
        self.embeddingModel = embeddingModel
    }

    func fetch() async throws -> KnowledgeBaseMetadataSnapshot {
        try await database.writer.read { db in
            let overview = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS project_count,
                    COALESCE(SUM(CASE WHEN r.is_starred = 1 THEN 1 ELSE 0 END), 0) AS starred_count,
                    COALESCE(SUM(CASE WHEN r.is_starred = 0 THEN 1 ELSE 0 END), 0) AS retained_count,
                    COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id) THEN 1 ELSE 0 END), 0) AS tagged_count,
                    COALESCE(SUM(CASE WHEN r.language IS NOT NULL AND TRIM(r.language) != '' THEN 1 ELSE 0 END), 0) AS known_language_count,
                    COALESCE(SUM(CASE WHEN datetime(n.library_updated_at) >= datetime('now', '-30 days') THEN 1 ELSE 0 END), 0) AS added_recently_count,
                    COALESCE(SUM(CASE WHEN datetime(r.pushed_at) >= datetime('now', '-30 days') THEN 1 ELSE 0 END), 0) AS pushed_recently_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL THEN 1 ELSE 0 END), 0) AS private_note_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND n.is_ai_generated = 1 THEN 1 ELSE 0 END), 0) AS ai_generated_note_count,
                    COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM ai_summaries s WHERE s.repo_id = r.id) THEN 1 ELSE 0 END), 0) AS ai_summary_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND datetime(n.edited_at) >= datetime('now', '-30 days') THEN 1 ELSE 0 END), 0) AS notes_edited_recently_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM ai_summaries s
                        WHERE s.repo_id = r.id AND datetime(s.generated_at) >= datetime('now', '-30 days')
                    ) THEN 1 ELSE 0 END), 0) AS summaries_generated_recently_count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                """)!
            let projectCount: Int = overview["project_count"]
            let taggedProjectCount: Int = overview["tagged_count"]
            let knownLanguageProjectCount: Int = overview["known_language_count"]

            let starredOverview = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS project_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id
                    ) THEN 1 ELSE 0 END), 0) AS tagged_count
                FROM repos r
                WHERE r.is_starred = 1
                """)!
            let starredProjectScopeCount: Int = starredOverview["project_count"]
            let starredTaggedProjectCount: Int = starredOverview["tagged_count"]

            // 与主列表 `statusMap[id] ?? .unread` 及 RepoStatus.parse 保持一致：无笔记行是未读，
            // 除 unread / using 外的旧值、空值和未知值都归到已读，避免下钻数量漂移。
            let starredStatusCounts = try Self.namedCounts(db, sql: """
                SELECT
                    CASE
                        WHEN n.repo_id IS NULL THEN 'unread'
                        WHEN n.status = 'unread' THEN 'unread'
                        WHEN n.status = 'using' THEN 'using'
                        ELSE 'read'
                    END AS name,
                    COUNT(*) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE r.is_starred = 1
                GROUP BY name
                ORDER BY count DESC, name ASC
                """)

            let statusCounts = try Self.namedCounts(db, sql: """
                SELECT COALESCE(NULLIF(TRIM(n.status), ''), 'unclassified') AS name, COUNT(*) AS count
                FROM repo_notes n
                WHERE n.library_state = 'in_library'
                GROUP BY COALESCE(NULLIF(TRIM(n.status), ''), 'unclassified')
                ORDER BY count DESC, name ASC
                """)
            let topLanguages = try Self.namedCounts(db, sql: """
                SELECT COALESCE(NULLIF(TRIM(r.language), ''), 'Unknown') AS name, COUNT(*) AS count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                GROUP BY COALESCE(NULLIF(TRIM(r.language), ''), 'Unknown')
                ORDER BY count DESC, name ASC
                LIMIT \(Self.distributionLimit)
                """)
            let topTags = try Self.namedCounts(db, sql: """
                SELECT t.name AS name, COUNT(*) AS count
                FROM tags t
                JOIN repo_tags rt ON rt.tag_id = t.id
                JOIN repo_notes n ON n.repo_id = rt.repo_id
                WHERE n.library_state = 'in_library'
                GROUP BY t.id, t.name
                ORDER BY count DESC, name COLLATE NOCASE ASC
                LIMIT \(Self.distributionLimit)
                """)
            let tagCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT rt.tag_id)
                FROM repo_tags rt
                JOIN repo_notes n ON n.repo_id = rt.repo_id
                WHERE n.library_state = 'in_library'
                """) ?? 0
            let topStarredRepositories = try Row.fetchAll(db, sql: """
                SELECT r.id, r.full_name, r.stars_count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                ORDER BY r.stars_count DESC, r.full_name COLLATE NOCASE ASC
                LIMIT \(Self.topStarredLimit)
                """).map { row in
                    KnowledgeBaseMetadataSnapshot.TopRepository(
                        repoID: row["id"],
                        fullName: row["full_name"],
                        stars: row["stars_count"]
                    )
                }
            // 知识库内容最后变化时间：在库仓库里最大的 library_updated_at。存储为一致的
            // ISO8601 UTC 文本，字典序 MAX 即时间序 MAX；解析在 Swift 侧兼容有/无小数秒。
            let latestContentUpdatedRaw = try String.fetchOne(db, sql: """
                SELECT MAX(n.library_updated_at)
                FROM repo_notes n
                WHERE n.library_state = 'in_library' AND n.library_updated_at IS NOT NULL
                """)

            let index = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(c.id) AS total_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'ready' AND c.embedding_model = ? THEN 1 ELSE 0 END), 0) AS ready_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'keyword_only' THEN 1 ELSE 0 END), 0) AS keyword_only_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'pending' THEN 1 ELSE 0 END), 0) AS pending_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'failed' THEN 1 ELSE 0 END), 0) AS failed_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'stale' OR (
                        c.embedding_status = 'ready' AND c.embedding_model IS NOT NULL AND c.embedding_model != ?
                    ) THEN 1 ELSE 0 END), 0) AS stale_chunks
                FROM repo_notes n
                LEFT JOIN rag_chunks c ON c.repo_id = n.repo_id
                    AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                WHERE n.library_state = 'in_library'
                """, arguments: [embeddingModel, embeddingModel])!

            let sourceCoverageRows = try Row.fetchAll(db, sql: """
                SELECT
                    c.source AS source,
                    COUNT(DISTINCT c.repo_id) AS repository_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    ) THEN 1 ELSE 0 END), 0) AS chunk_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    ) AND ((c.embedding_status = 'ready' AND c.embedding_model = ?) OR c.embedding_status = 'keyword_only') THEN 1 ELSE 0 END), 0) AS ready_chunk_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    ) AND c.embedding_status = 'failed' THEN 1 ELSE 0 END), 0) AS failed_chunk_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1
                    ) AND (c.embedding_status = 'stale' OR (
                        c.embedding_status = 'ready' AND c.embedding_model IS NOT NULL AND c.embedding_model != ?
                    )) THEN 1 ELSE 0 END), 0) AS stale_chunk_count
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id
                WHERE n.library_state = 'in_library'
                GROUP BY c.source
                """, arguments: [embeddingModel, embeddingModel])
            let sourceCoverageByRawValue: [String: KnowledgeBaseMetadataSnapshot.SourceIndexCoverage] = Dictionary(
                uniqueKeysWithValues: sourceCoverageRows.compactMap { row -> (String, KnowledgeBaseMetadataSnapshot.SourceIndexCoverage)? in
                    let sourceRawValue: String = row["source"]
                    guard let source = RAGChunkSource(rawValue: sourceRawValue) else { return nil }
                    return (sourceRawValue, KnowledgeBaseMetadataSnapshot.SourceIndexCoverage(
                        source: source,
                        repositoryCount: row["repository_count"],
                        chunkCount: row["chunk_count"],
                        readyChunkCount: row["ready_chunk_count"],
                        failedChunkCount: row["failed_chunk_count"],
                        staleChunkCount: row["stale_chunk_count"]
                    ))
                }
            )
            let sourceIndexCoverage = RAGChunkSource.allCases.map {
                sourceCoverageByRawValue[$0.rawValue] ?? KnowledgeBaseMetadataSnapshot.SourceIndexCoverage(
                    source: $0,
                    repositoryCount: 0,
                    chunkCount: 0,
                    readyChunkCount: 0,
                    failedChunkCount: 0,
                    staleChunkCount: 0
                )
            }

            // README 缺失看“是否生成过来源分片”；用户主动排除不应改写来源内容事实。
            // “无可索引来源”则只看未排除分片，专门用于解释检索为什么完全无候选。
            let availability = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM rag_chunks c
                        JOIN rag_chunk_overrides o ON o.chunk_id = c.id AND o.is_excluded = 1
                        WHERE c.repo_id = n.repo_id
                    ) THEN (
                        SELECT COUNT(*) FROM rag_chunks c
                        JOIN rag_chunk_overrides o ON o.chunk_id = c.id AND o.is_excluded = 1
                        WHERE c.repo_id = n.repo_id
                    ) ELSE 0 END), 0) AS excluded_chunk_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id AND c.source = 'readme'
                    ) THEN 1 ELSE 0 END), 0) AS without_readme_count,
                    COALESCE(SUM(CASE WHEN NOT EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id
                          AND NOT EXISTS (
                              SELECT 1 FROM rag_chunk_overrides o
                              WHERE o.chunk_id = c.id AND o.is_excluded = 1
                          )
                    ) THEN 1 ELSE 0 END), 0) AS without_indexable_source_count
                FROM repo_notes n
                WHERE n.library_state = 'in_library'
                """)!

            return KnowledgeBaseMetadataSnapshot(
                generatedAt: Date(),
                contentUpdatedAt: Self.parseISO8601(latestContentUpdatedRaw),
                projectCount: projectCount,
                starredProjectCount: overview["starred_count"],
                retainedAfterUnstarCount: overview["retained_count"],
                starredStatusCounts: starredStatusCounts,
                statusCounts: statusCounts,
                starredTaggedProjectCount: starredTaggedProjectCount,
                starredUntaggedProjectCount: starredProjectScopeCount - starredTaggedProjectCount,
                taggedProjectCount: taggedProjectCount,
                untaggedProjectCount: projectCount - taggedProjectCount,
                tagCount: tagCount,
                knownLanguageProjectCount: knownLanguageProjectCount,
                unknownLanguageProjectCount: projectCount - knownLanguageProjectCount,
                topLanguages: topLanguages,
                topTags: topTags,
                addedInLast30DaysCount: overview["added_recently_count"],
                pushedInLast30DaysCount: overview["pushed_recently_count"],
                aiSummaryProjectCount: overview["ai_summary_count"],
                privateNoteProjectCount: overview["private_note_count"],
                aiGeneratedNoteProjectCount: overview["ai_generated_note_count"],
                privateNotesEditedInLast30DaysProjectCount: overview["notes_edited_recently_count"],
                aiSummariesGeneratedInLast30DaysProjectCount: overview["summaries_generated_recently_count"],
                sourceIndexCoverage: sourceIndexCoverage,
                excludedChunkCount: availability["excluded_chunk_count"],
                withoutReadmeSourceProjectCount: availability["without_readme_count"],
                withoutIndexableSourceProjectCount: availability["without_indexable_source_count"],
                topStarredRepositories: topStarredRepositories,
                indexHealth: .init(
                    totalChunks: index["total_chunks"],
                    readyChunks: index["ready_chunks"],
                    keywordOnlyChunks: index["keyword_only_chunks"],
                    pendingChunks: index["pending_chunks"],
                    failedChunks: index["failed_chunks"],
                    staleChunks: index["stale_chunks"],
                    embeddingModel: embeddingModel
                )
            )
        }
    }

    private static func namedCounts(_ db: Database, sql: String) throws -> [KnowledgeBaseMetadataSnapshot.NamedCount] {
        try Row.fetchAll(db, sql: sql).map { row in
            .init(name: row["name"], count: row["count"])
        }
    }

    /// 解析 library_updated_at 文本：写入端统一带小数秒，但对历史/异常数据兼容无小数秒格式。
    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
