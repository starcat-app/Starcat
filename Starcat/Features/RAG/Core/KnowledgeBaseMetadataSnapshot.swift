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

/// 注入回答 Prompt 的知识库全局事实；数组已由仓储限制，防止统计维度挤占证据预算。
struct KnowledgeBaseMetadataSnapshot: Equatable, Sendable {
    struct NamedCount: Equatable, Sendable {
        let name: String
        let count: Int
    }

    struct TopRepository: Equatable, Sendable {
        let fullName: String
        let stars: Int
    }

    struct IndexHealth: Equatable, Sendable {
        let totalChunks: Int
        let readyChunks: Int
        let pendingChunks: Int
        let failedChunks: Int
        let staleChunks: Int
        let embeddingModel: String
    }

    let generatedAt: Date
    let projectCount: Int
    let starredProjectCount: Int
    let retainedAfterUnstarCount: Int
    let statusCounts: [NamedCount]
    let taggedProjectCount: Int
    let untaggedProjectCount: Int
    let tagCount: Int
    let knownLanguageProjectCount: Int
    let unknownLanguageProjectCount: Int
    let topLanguages: [NamedCount]
    let topTags: [NamedCount]
    let addedInLast30DaysCount: Int
    let pushedInLast30DaysCount: Int
    let topStarredRepositories: [TopRepository]
    let indexHealth: IndexHealth

    /// 保持英文、键值式表达，避免受显示语言或自定义 Prompt 影响而改变数据库事实的含义。
    func promptContext() -> String {
        let status = rendered(statusCounts)
        let languages = rendered(topLanguages)
        let tags = rendered(topTags)
        let topRepositories = topStarredRepositories.map { "\($0.fullName) (\($0.stars) stars)" }
            .joined(separator: "; ")
        return """
        Authoritative local knowledge-base metadata snapshot (generated now; not vector-search evidence):
        - Scope: \(projectCount) in-library repositories; \(starredProjectCount) still starred; \(retainedAfterUnstarCount) retained after unstar.
        - Organization: status counts [\(status)]; \(taggedProjectCount) tagged; \(untaggedProjectCount) untagged; \(tagCount) distinct tags.
        - Technology: \(knownLanguageProjectCount) repositories have a language; \(unknownLanguageProjectCount) unknown; top languages [\(languages)].
        - Top tags: [\(tags)].
        - Activity: \(addedInLast30DaysCount) added to the library in the last 30 days; \(pushedInLast30DaysCount) repositories pushed in the last 30 days.
        - Star leaders (top \(topStarredRepositories.count)): [\(topRepositories)].
        - RAG index for model \(indexHealth.embeddingModel): \(indexHealth.totalChunks) active chunks; ready \(indexHealth.readyChunks), pending \(indexHealth.pendingChunks), failed \(indexHealth.failedChunks), stale \(indexHealth.staleChunks).
        Use these values as database facts for applicable count, distribution, activity, index-health, and star-ranking questions. Do not fabricate chunk citations for this snapshot. If a requested exact value is not present here, say the snapshot does not contain it.
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
                    COALESCE(SUM(CASE WHEN datetime(r.pushed_at) >= datetime('now', '-30 days') THEN 1 ELSE 0 END), 0) AS pushed_recently_count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                """)!
            let projectCount: Int = overview["project_count"]
            let taggedProjectCount: Int = overview["tagged_count"]
            let knownLanguageProjectCount: Int = overview["known_language_count"]

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
                SELECT r.full_name, r.stars_count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                ORDER BY r.stars_count DESC, r.full_name COLLATE NOCASE ASC
                LIMIT \(Self.topStarredLimit)
                """).map { row in
                    KnowledgeBaseMetadataSnapshot.TopRepository(
                        fullName: row["full_name"],
                        stars: row["stars_count"]
                    )
                }
            let index = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(c.id) AS total_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'ready' AND c.embedding_model = ? THEN 1 ELSE 0 END), 0) AS ready_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'pending' THEN 1 ELSE 0 END), 0) AS pending_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'failed' THEN 1 ELSE 0 END), 0) AS failed_chunks,
                    COALESCE(SUM(CASE WHEN c.embedding_status = 'stale' OR (c.embedding_model IS NOT NULL AND c.embedding_model != ?) THEN 1 ELSE 0 END), 0) AS stale_chunks
                FROM repo_notes n
                LEFT JOIN rag_chunks c ON c.repo_id = n.repo_id
                    AND NOT EXISTS (SELECT 1 FROM rag_chunk_overrides o WHERE o.chunk_id = c.id AND o.is_excluded = 1)
                WHERE n.library_state = 'in_library'
                """, arguments: [embeddingModel, embeddingModel])!

            return KnowledgeBaseMetadataSnapshot(
                generatedAt: Date(),
                projectCount: projectCount,
                starredProjectCount: overview["starred_count"],
                retainedAfterUnstarCount: overview["retained_count"],
                statusCounts: statusCounts,
                taggedProjectCount: taggedProjectCount,
                untaggedProjectCount: projectCount - taggedProjectCount,
                tagCount: tagCount,
                knownLanguageProjectCount: knownLanguageProjectCount,
                unknownLanguageProjectCount: projectCount - knownLanguageProjectCount,
                topLanguages: topLanguages,
                topTags: topTags,
                addedInLast30DaysCount: overview["added_recently_count"],
                pushedInLast30DaysCount: overview["pushed_recently_count"],
                topStarredRepositories: topStarredRepositories,
                indexHealth: .init(
                    totalChunks: index["total_chunks"],
                    readyChunks: index["ready_chunks"],
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
}
