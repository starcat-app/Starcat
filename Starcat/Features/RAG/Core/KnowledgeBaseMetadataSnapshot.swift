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
    /// Generator 使用的可独立引用事实段。`id` 会持久化到 citation，不能随 UI 文案变化。
    struct CitationSection: Equatable, Sendable {
        let id: String
        let promptTitle: String
        let content: String
    }

    struct NamedCount: Equatable, Sendable {
        let name: String
        let count: Int
    }

    struct TopRepository: Equatable, Sendable {
        let repoID: Int64
        let fullName: String
        let stars: Int
    }

    /// “我的洞察”与 RAG 共用的知识库事实。这里不携带任何 UI 文案，避免展示模型反向污染 Prompt。
    struct InsightsFacts: Equatable, Sendable {
        struct PriorityRepository: Equatable, Sendable {
            let repoID: Int64
            let fullName: String
            let stars: Int
            let isUnread: Bool
            let isUntagged: Bool
        }

        struct WeeklyCount: Equatable, Sendable {
            let weekStart: Date
            let count: Int
        }

        let organizedProjectCount: Int
        let normalizedStatusCounts: [NamedCount]
        /// 保留完整分布，由 UI 决定 Top N 与“其他”；Prompt 只读取受限前缀。
        let languageCounts: [NamedCount]
        let topicCounts: [NamedCount]
        let licenseCounts: [NamedCount]
        let dormantProjectCount: Int
        let archivedProjectCount: Int
        let unavailableProjectCount: Int
        let healthCompletedProjectCount: Int
        let openSSFCompletedProjectCount: Int
        let maintenanceRiskProjectCount: Int
        let securityRiskProjectCount: Int
        let readmeSourceProjectCount: Int
        let indexableSourceProjectCount: Int
        let embeddingReadyProjectCount: Int
        let indexIssueProjectCount: Int
        let priorityRepositories: [PriorityRepository]
        let weeklyAdditions: [WeeklyCount]
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
    /// 供“我的洞察”、RAG Prompt 与 Inspector 投影的单一知识库聚合事实。
    let insights: InsightsFacts

    /// 保持英文、键值式表达，避免受显示语言或自定义 Prompt 影响而改变数据库事实的含义。
    func promptContext() -> String {
        let sections = citationSections().map {
            "\($0.promptTitle):\n\($0.content)"
        }.joined(separator: "\n")
        return """
        Authoritative local knowledge-base metadata snapshot (generated now; not vector-search evidence):
        \(sections)
        Use these values as database facts for applicable count, distribution, activity, index-health, and star-ranking questions. Do not fabricate chunk citations for this snapshot. If a requested exact value is not present here, say the snapshot does not contain it.
        """
    }

    /// 将大快照拆成事实口径稳定的小段，Generator 才能只引用真正用于回答的部分。
    /// 这里仍保持英文数据库语义；Inspector 通过稳定 id 映射当前 App 语言的标题。
    func citationSections(includeInventoryLeaders: Bool = true) -> [CitationSection] {
        let status = rendered(insights.normalizedStatusCounts)
        let languages = rendered(topLanguages)
        let tags = rendered(topTags)
        let topics = rendered(Array(insights.topicCounts.prefix(8)))
        let licenses = rendered(
            Array(insights.licenseCounts.prefix(8)).map {
                KnowledgeBaseMetadataSnapshot.NamedCount(
                    name: $0.name == "__unknown__" ? "Unknown" : $0.name,
                    count: $0.count
                )
            }
        )
        let topRepositories = topStarredRepositories.map { "\($0.fullName) (\($0.stars) stars)" }
            .joined(separator: "; ")
        let sourceCoverage = sourceIndexCoverage.map {
            "\($0.source.rawValue): \($0.repositoryCount) repositories with content, \($0.readyChunkCount) ready, \($0.failedChunkCount) failed, \($0.staleChunkCount) stale, \($0.chunkCount) active chunks"
        }.joined(separator: "; ")
        var sections = [
            CitationSection(
                id: "scope",
                promptTitle: "Scope",
                content: "- \(projectCount) in-library repositories; \(starredProjectCount) still starred; \(retainedAfterUnstarCount) retained after unstar."
            ),
            CitationSection(
                id: "organization",
                promptTitle: "Organization",
                content: includeInventoryLeaders
                    ? "- Status counts [\(status)]; \(taggedProjectCount) tagged; \(untaggedProjectCount) untagged; \(tagCount) distinct tags.\n- Top tags: [\(tags)]."
                    : "- Status counts [\(status)]; \(taggedProjectCount) tagged; \(untaggedProjectCount) untagged; \(tagCount) distinct tags."
            ),
            CitationSection(
                id: "technology",
                promptTitle: "Technology",
                content: "- \(knownLanguageProjectCount) repositories have a language; \(unknownLanguageProjectCount) unknown; top languages [\(languages)].\n- GitHub topics: [\(topics)]; licenses: [\(licenses)]."
            ),
            CitationSection(
                id: "activity_quality",
                promptTitle: "Activity and quality",
                content: "- \(addedInLast30DaysCount) added to the library in the last 30 days; \(pushedInLast30DaysCount) repositories pushed in the last 30 days.\n- \(insights.organizedProjectCount) organized; \(insights.dormantProjectCount) dormant for over 1 year; \(insights.archivedProjectCount) archived; \(insights.unavailableProjectCount) unavailable.\n- \(insights.healthCompletedProjectCount) have health snapshots; \(insights.openSSFCompletedProjectCount) have OpenSSF scores; \(insights.maintenanceRiskProjectCount) have maintenance risk; \(insights.securityRiskProjectCount) have security risk."
            ),
            CitationSection(
                id: "knowledge_artifacts",
                promptTitle: "Knowledge artifacts",
                content: "- \(aiSummaryProjectCount) repositories have an AI summary; \(privateNoteProjectCount) have private notes (\(aiGeneratedNoteProjectCount) AI-generated).\n- \(privateNotesEditedInLast30DaysProjectCount) repositories had private notes edited in the last 30 days; \(aiSummariesGeneratedInLast30DaysProjectCount) had AI summaries generated in the last 30 days. Older summaries are not automatically invalid."
            ),
            CitationSection(
                id: "index_coverage",
                promptTitle: "Index coverage",
                content: "- Indexed source coverage: [\(sourceCoverage)].\n- \(excludedChunkCount) chunks are excluded; \(withoutReadmeSourceProjectCount) repositories have no README source; \(withoutIndexableSourceProjectCount) have no active indexable source.\n- \(insights.readmeSourceProjectCount) have README content; \(insights.indexableSourceProjectCount) have an active source; \(insights.embeddingReadyProjectCount) have a current-model vector-ready chunk; \(insights.indexIssueProjectCount) have failed or stale chunks."
            )
        ]
        if includeInventoryLeaders {
            sections.append(CitationSection(
                id: "star_leaders",
                promptTitle: "Star leaders",
                content: "- Top \(topStarredRepositories.count): [\(topRepositories)]."
            ))
        }
        sections.append(CitationSection(
            id: "index_health",
            promptTitle: "RAG index health",
            content: "- Model \(indexHealth.embeddingModel.isEmpty ? "not configured (keyword-only mode)" : indexHealth.embeddingModel): \(indexHealth.totalChunks) active chunks; vector-ready \(indexHealth.readyChunks), keyword-ready \(indexHealth.keywordOnlyChunks), pending \(indexHealth.pendingChunks), failed \(indexHealth.failedChunks), stale \(indexHealth.staleChunks)."
        ))
        return sections
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
        - Curation and risk: \(insights.organizedProjectCount) organized; \(insights.dormantProjectCount) dormant; \(insights.archivedProjectCount) archived; \(insights.unavailableProjectCount) unavailable; \(insights.maintenanceRiskProjectCount) maintenance risk; \(insights.securityRiskProjectCount) security risk.
        - Indexed source coverage: [\(sourceCoverage)].
        - Index availability: \(excludedChunkCount) excluded chunks; \(withoutReadmeSourceProjectCount) repositories without a README source; \(withoutIndexableSourceProjectCount) without an active indexable source.
        Use this only to choose a supported local inventory analytics metric when the user asks for these counts. Do not invent an unsupported metric or treat these aggregates as vector-search evidence.
        """
    }

    private func rendered(_ counts: [NamedCount]) -> String {
        counts.map { "\($0.name): \($0.count)" }.joined(separator: ", ")
    }
}

/// 进程内按数据库修订号复用元数据快照，并合并同一版本的并发读取。
///
/// 缓存不自行猜测 TTL：30 天窗口、索引状态和用户数据都由 SQLite 触发器推进修订号；
/// embedding model 仍是 key 的一部分，因为同一份 chunk 对不同模型的 ready/stale 口径不同。
actor KnowledgeBaseMetadataSnapshotCache {
    /// 快照包含“近 30 天”滚动窗口；即使数据库没有写入，时间边界也会自然变化。
    /// 因此修订号命中仍只复用一分钟，避免把版本缓存误做成无限期缓存。
    private static let maximumAge: TimeInterval = 60

    struct Revision: Equatable, Sendable {
        let userID: Int64?
        let metadataRevision: Int64
        let healthCount: Int
        let latestHealthAt: String?
        let openSSFCount: Int
        let latestOpenSSFAt: String?
    }

    private struct Entry {
        let revision: Revision
        let snapshot: KnowledgeBaseMetadataSnapshot
    }

    private struct InFlightLoad {
        let revision: Revision
        let task: Task<KnowledgeBaseMetadataSnapshot, Error>
    }

    private var entries: [String: Entry] = [:]
    private var inFlightLoads: [String: InFlightLoad] = [:]

    func value(
        embeddingModel: String,
        revision: Revision,
        now: Date,
        load: @escaping @Sendable () async throws -> KnowledgeBaseMetadataSnapshot
    ) async throws -> KnowledgeBaseMetadataSnapshot {
        if let entry = entries[embeddingModel],
           entry.revision == revision,
           now.timeIntervalSince(entry.snapshot.generatedAt) < Self.maximumAge {
            return entry.snapshot
        }
        if let inFlight = inFlightLoads[embeddingModel], inFlight.revision == revision {
            return try await inFlight.task.value
        }

        let task = Task { try await load() }
        inFlightLoads[embeddingModel] = InFlightLoad(revision: revision, task: task)
        do {
            let snapshot = try await task.value
            if inFlightLoads[embeddingModel]?.revision == revision {
                entries[embeddingModel] = Entry(revision: revision, snapshot: snapshot)
                inFlightLoads[embeddingModel] = nil
            }
            return snapshot
        } catch {
            if inFlightLoads[embeddingModel]?.revision == revision {
                inFlightLoads[embeddingModel] = nil
            }
            throw error
        }
    }

    /// 多账号切库可能恰好拥有相同 revision；切换前必须清空，不能跨用户复用聚合事实。
    func removeAll() {
        for load in inFlightLoads.values {
            load.task.cancel()
        }
        entries.removeAll(keepingCapacity: true)
        inFlightLoads.removeAll(keepingCapacity: true)
    }
}

/// 只读构建快照；所有 SQL 结构固定，模型和用户输入都不会进入 SQL。
struct KnowledgeBaseMetadataSnapshotProvider: Sendable {
    private static let distributionLimit = 8
    private static let topStarredLimit = 10

    private let database: any DatabaseManaging
    private let embeddingModel: String
    private let cache: KnowledgeBaseMetadataSnapshotCache?
    private let now: @Sendable () -> Date

    init(
        database: any DatabaseManaging,
        embeddingModel: String,
        cache: KnowledgeBaseMetadataSnapshotCache? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.embeddingModel = embeddingModel
        self.cache = cache
        self.now = now
    }

    func fetch() async throws -> KnowledgeBaseMetadataSnapshot {
        let generatedAt = now()
        guard let cache, let revision = try await fetchRevision() else {
            return try await fetchUncached(generatedAt: generatedAt)
        }
        return try await cache.value(
            embeddingModel: embeddingModel,
            revision: revision,
            now: generatedAt
        ) {
            try await self.fetchUncached(generatedAt: generatedAt)
        }
    }

    /// 老测试草稿库或尚未迁移到 v12 的数据库没有修订表时直接读取，不能为了缓存让 RAG 失效。
    private func fetchRevision() async throws -> KnowledgeBaseMetadataSnapshotCache.Revision? {
        let userID = database.currentUserId
        return try await database.writer.read { db in
            guard try db.tableExists("rag_metadata_revision") else { return nil }
            let metadataRevision = try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM rag_metadata_revision WHERE id = 1"
            ) ?? 0
            let health = try Self.tableRevision(
                db,
                table: "repo_health_snapshots",
                timestampColumn: "computed_at"
            )
            let openSSF = try Self.tableRevision(
                db,
                table: "open_ssf_scores",
                timestampColumn: "fetched_at"
            )
            return KnowledgeBaseMetadataSnapshotCache.Revision(
                userID: userID,
                metadataRevision: metadataRevision,
                healthCount: health.count,
                latestHealthAt: health.latest,
                openSSFCount: openSSF.count,
                latestOpenSSFAt: openSSF.latest
            )
        }
    }

    private func fetchUncached(generatedAt: Date) async throws -> KnowledgeBaseMetadataSnapshot {
        let recentCutoff = ISO8601DateFormatter.shared.string(
            from: generatedAt.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        let dormantCutoff = ISO8601DateFormatter.shared.string(
            from: generatedAt.addingTimeInterval(-365 * 24 * 60 * 60)
        )
        return try await database.writer.read { db in
            let overview = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS project_count,
                    COALESCE(SUM(CASE WHEN r.is_starred = 1 THEN 1 ELSE 0 END), 0) AS starred_count,
                    COALESCE(SUM(CASE WHEN r.is_starred = 0 THEN 1 ELSE 0 END), 0) AS retained_count,
                    COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id) THEN 1 ELSE 0 END), 0) AS tagged_count,
                    COALESCE(SUM(CASE WHEN r.language IS NOT NULL AND TRIM(r.language) != '' THEN 1 ELSE 0 END), 0) AS known_language_count,
                    COALESCE(SUM(CASE WHEN datetime(n.library_updated_at) >= datetime(?) THEN 1 ELSE 0 END), 0) AS added_recently_count,
                    COALESCE(SUM(CASE WHEN datetime(r.pushed_at) >= datetime(?) THEN 1 ELSE 0 END), 0) AS pushed_recently_count,
                    COALESCE(SUM(CASE WHEN n.status = 'using' THEN 1 ELSE 0 END), 0) AS using_count,
                    COALESCE(SUM(CASE WHEN
                        EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id)
                        OR NULLIF(TRIM(n.content), '') IS NOT NULL
                        OR n.status IN ('read', 'using')
                    THEN 1 ELSE 0 END), 0) AS organized_count,
                    COALESCE(SUM(CASE WHEN r.pushed_at IS NOT NULL AND datetime(r.pushed_at) < datetime(?) THEN 1 ELSE 0 END), 0) AS dormant_count,
                    COALESCE(SUM(CASE WHEN r.is_archived = 1 THEN 1 ELSE 0 END), 0) AS archived_count,
                    COALESCE(SUM(CASE WHEN r.access_state = 'unavailable' THEN 1 ELSE 0 END), 0) AS unavailable_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL THEN 1 ELSE 0 END), 0) AS private_note_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND n.is_ai_generated = 1 THEN 1 ELSE 0 END), 0) AS ai_generated_note_count,
                    COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM ai_summaries s WHERE s.repo_id = r.id) THEN 1 ELSE 0 END), 0) AS ai_summary_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL AND datetime(n.edited_at) >= datetime(?) THEN 1 ELSE 0 END), 0) AS notes_edited_recently_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM ai_summaries s
                        WHERE s.repo_id = r.id AND datetime(s.generated_at) >= datetime(?)
                    ) THEN 1 ELSE 0 END), 0) AS summaries_generated_recently_count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                """, arguments: [
                    recentCutoff,
                    recentCutoff,
                    dormantCutoff,
                    recentCutoff,
                    recentCutoff
                ])!
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
            let normalizedStatusCounts = try Self.namedCounts(db, sql: """
                SELECT
                    CASE
                        WHEN n.status = 'unread' THEN 'unread'
                        WHEN n.status = 'using' THEN 'using'
                        ELSE 'read'
                    END AS name,
                    COUNT(*) AS count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                GROUP BY 1
                ORDER BY count DESC, name ASC
                """)
            let languageCounts = try Self.namedCounts(db, sql: """
                SELECT COALESCE(NULLIF(TRIM(r.language), ''), '__unknown__') AS name, COUNT(*) AS count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                GROUP BY COALESCE(NULLIF(TRIM(r.language), ''), '__unknown__')
                ORDER BY count DESC, name ASC
                """)
            let topicCounts = try Self.namedCounts(db, sql: """
                SELECT LOWER(TRIM(topic.value)) AS name, COUNT(DISTINCT r.id) AS count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                JOIN json_each(CASE WHEN json_valid(r.topics) THEN r.topics ELSE '[]' END) topic
                WHERE n.library_state = 'in_library'
                  AND topic.type = 'text'
                  AND NULLIF(TRIM(topic.value), '') IS NOT NULL
                GROUP BY LOWER(TRIM(topic.value))
                ORDER BY count DESC, name COLLATE NOCASE ASC
                """)
            let licenseCounts = try Self.namedCounts(db, sql: """
                SELECT COALESCE(NULLIF(TRIM(r.license), ''), '__unknown__') AS name, COUNT(*) AS count
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                GROUP BY COALESCE(NULLIF(TRIM(r.license), ''), '__unknown__')
                ORDER BY count DESC, name COLLATE NOCASE ASC
                """)
            let topLanguages = Array(languageCounts.prefix(Self.distributionLimit)).map {
                KnowledgeBaseMetadataSnapshot.NamedCount(
                    name: $0.name == "__unknown__" ? "Unknown" : $0.name,
                    count: $0.count
                )
            }
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
            let priorityRepositories = try Row.fetchAll(db, sql: """
                SELECT
                    r.id,
                    r.full_name,
                    r.stars_count,
                    CASE WHEN n.status = 'unread' THEN 1 ELSE 0 END AS is_unread,
                    CASE WHEN NOT EXISTS (
                        SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id
                    ) THEN 1 ELSE 0 END AS is_untagged
                FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.library_state = 'in_library'
                  AND (
                    n.status = 'unread'
                    OR NOT EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id)
                  )
                ORDER BY r.stars_count DESC, COALESCE(n.library_updated_at, r.cached_at) DESC, r.id DESC
                LIMIT 5
                """).map { row in
                    KnowledgeBaseMetadataSnapshot.InsightsFacts.PriorityRepository(
                        repoID: row["id"],
                        fullName: row["full_name"],
                        stars: row["stars_count"],
                        isUnread: row["is_unread"],
                        isUntagged: row["is_untagged"]
                    )
                }
            let weeklyAdditions = try Self.weeklyAdditions(
                db,
                generatedAt: generatedAt
            )
            let quality = try Self.qualityCounts(db)
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
                    ,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id AND c.source = 'readme'
                    ) THEN 1 ELSE 0 END), 0) AS readme_source_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id
                          AND NOT EXISTS (
                              SELECT 1 FROM rag_chunk_overrides o
                              WHERE o.chunk_id = c.id AND o.is_excluded = 1
                          )
                    ) THEN 1 ELSE 0 END), 0) AS indexable_source_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id
                          AND c.embedding_status = 'ready'
                          AND c.embedding_model = ?
                          AND NOT EXISTS (
                              SELECT 1 FROM rag_chunk_overrides o
                              WHERE o.chunk_id = c.id AND o.is_excluded = 1
                          )
                    ) THEN 1 ELSE 0 END), 0) AS embedding_ready_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM rag_chunks c
                        WHERE c.repo_id = n.repo_id
                          AND NOT EXISTS (
                              SELECT 1 FROM rag_chunk_overrides o
                              WHERE o.chunk_id = c.id AND o.is_excluded = 1
                          )
                          AND (
                              c.embedding_status IN ('failed', 'stale')
                              OR (
                                  c.embedding_status = 'ready'
                                  AND c.embedding_model IS NOT NULL
                                  AND c.embedding_model != ?
                              )
                          )
                    ) THEN 1 ELSE 0 END), 0) AS index_issue_count
                FROM repo_notes n
                WHERE n.library_state = 'in_library'
                """, arguments: [embeddingModel, embeddingModel])!

            return KnowledgeBaseMetadataSnapshot(
                generatedAt: generatedAt,
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
                ),
                insights: .init(
                    organizedProjectCount: overview["organized_count"],
                    normalizedStatusCounts: normalizedStatusCounts,
                    languageCounts: languageCounts,
                    topicCounts: topicCounts,
                    licenseCounts: licenseCounts,
                    dormantProjectCount: overview["dormant_count"],
                    archivedProjectCount: overview["archived_count"],
                    unavailableProjectCount: overview["unavailable_count"],
                    healthCompletedProjectCount: quality.healthCompleted,
                    openSSFCompletedProjectCount: quality.openSSFCompleted,
                    maintenanceRiskProjectCount: quality.maintenanceRisk,
                    securityRiskProjectCount: quality.securityRisk,
                    readmeSourceProjectCount: availability["readme_source_count"],
                    indexableSourceProjectCount: availability["indexable_source_count"],
                    embeddingReadyProjectCount: availability["embedding_ready_count"],
                    indexIssueProjectCount: availability["index_issue_count"],
                    priorityRepositories: priorityRepositories,
                    weeklyAdditions: weeklyAdditions
                )
            )
        }
    }

    private static func namedCounts(_ db: Database, sql: String) throws -> [KnowledgeBaseMetadataSnapshot.NamedCount] {
        try Row.fetchAll(db, sql: sql).map { row in
            .init(name: row["name"], count: row["count"])
        }
    }

    /// 健康度与 OpenSSF 在旧测试草稿库中可能尚未建表，缺表按未计算处理。
    private static func qualityCounts(
        _ db: Database
    ) throws -> (healthCompleted: Int, openSSFCompleted: Int, maintenanceRisk: Int, securityRisk: Int) {
        let hasHealth = try db.tableExists("repo_health_snapshots")
        let hasOpenSSF = try db.tableExists("open_ssf_scores")
        let healthJoin = hasHealth ? "LEFT JOIN repo_health_snapshots h ON h.repo_id = r.id" : ""
        let openSSFJoin = hasOpenSSF ? "LEFT JOIN open_ssf_scores os ON os.repo_id = r.id" : ""
        let healthCompleted = hasHealth
            ? "COALESCE(SUM(CASE WHEN h.repo_id IS NOT NULL AND h.fetch_status != 'failed' THEN 1 ELSE 0 END), 0)"
            : "0"
        let maintenanceRisk = hasHealth
            ? "COALESCE(SUM(CASE WHEN h.repo_id IS NOT NULL AND h.fetch_status != 'failed' AND h.maintenance_score < 50 THEN 1 ELSE 0 END), 0)"
            : "0"
        let openSSFCompleted = hasOpenSSF
            ? "COALESCE(SUM(CASE WHEN os.fetch_status = 'success' AND os.aggregate_score IS NOT NULL THEN 1 ELSE 0 END), 0)"
            : "0"
        let securityRisk = hasOpenSSF
            ? "COALESCE(SUM(CASE WHEN os.fetch_status = 'success' AND os.aggregate_score IS NOT NULL AND os.aggregate_score < 5 THEN 1 ELSE 0 END), 0)"
            : "0"
        // SQL 结构只由上面的本地布尔值选择固定片段，永不接收模型或用户输入。
        let row = try Row.fetchOne(db, sql: """
            SELECT
                \(healthCompleted) AS health_completed,
                \(openSSFCompleted) AS openssf_completed,
                \(maintenanceRisk) AS maintenance_risk,
                \(securityRisk) AS security_risk
            FROM repos r
            JOIN repo_notes n ON n.repo_id = r.id
            \(healthJoin)
            \(openSSFJoin)
            WHERE n.library_state = 'in_library'
            """)!
        return (
            healthCompleted: row["health_completed"],
            openSSFCompleted: row["openssf_completed"],
            maintenanceRisk: row["maintenance_risk"],
            securityRisk: row["security_risk"]
        )
    }

    /// 与“我的洞察”保持 ISO 周一口径，并显式补齐空周，避免快照消费者各自补零。
    private static func weeklyAdditions(
        _ db: Database,
        generatedAt: Date
    ) throws -> [KnowledgeBaseMetadataSnapshot.InsightsFacts.WeeklyCount] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: generatedAt)?.start,
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeek)
        else {
            return []
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                date(
                    n.library_updated_at,
                    printf(
                        '-%d days',
                        (CAST(strftime('%w', n.library_updated_at) AS INTEGER) + 6) % 7
                    )
                ) AS week_start,
                COUNT(*) AS count
            FROM repo_notes n
            WHERE n.library_state = 'in_library'
              AND n.library_updated_at IS NOT NULL
              AND datetime(n.library_updated_at) >= datetime(?)
            GROUP BY week_start
            ORDER BY week_start ASC
            """, arguments: [ISO8601DateFormatter.shared.string(from: firstWeek)])
        let counts = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["week_start"] as String, $0["count"] as Int)
        })
        return (0..<12).compactMap { offset in
            guard let week = calendar.date(byAdding: .weekOfYear, value: offset, to: firstWeek) else {
                return nil
            }
            let key = String(ISO8601DateFormatter.shared.string(from: week).prefix(10))
            return .init(weekStart: week, count: counts[key] ?? 0)
        }
    }

    private static func tableRevision(
        _ db: Database,
        table: String,
        timestampColumn: String
    ) throws -> (count: Int, latest: String?) {
        // table / column 只来自本文件固定字面量，禁止接收用户输入。
        guard try db.tableExists(table) else { return (0, nil) }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS row_count, MAX(\(timestampColumn)) AS latest FROM \(table)"
        )
        return (row?["row_count"] ?? 0, row?["latest"])
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
