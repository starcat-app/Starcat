//
//  MyInsightsSnapshotProvider.swift
//  Starcat
//
//  “我的洞察”实时 SQLite 聚合入口。
//
//  关键约束：
//  - 一个快照的全部指标在同一次 GRDB read transaction 中读取，避免卡片之间口径漂移；
//  - 全部收藏与知识库只通过固定 SQL predicate 切换，禁止 View 自己拼统计；
//  - 缺失 repo_notes 行按 unread 处理，与 Manage 列表的默认状态保持一致；
//  - 只做最多 60 秒的进程内缓存，不建 summary 表、不启动后台统计任务；
//  - Repository 每次访问 DatabaseManaging.writer，账号切换后不会继续读取旧数据库。
//

import Foundation
import GRDB

/// “我的洞察”快照数据源。刷新入口先调用 `invalidate()`，再重新 `load(scope:)`。
protocol MyInsightsSnapshotProviding: Sendable {
    func load(scope: InsightsScope, embeddingModel: String) async throws -> MyInsightsSnapshot
    func invalidate() async
}

/// 按账号、范围和数据库修订信息缓存快照。
///
/// `rag_metadata_revision` 已覆盖 Repo、Note、Tag 和 RAG 表；Health / OpenSSF 是派生缓存，
/// 没有接入该 revision，因此额外把两张表的行数和最大更新时间加入 key。这样既能复用
/// RAG 已验证的版本化缓存策略，也不会让新写入的健康度在 60 秒内被旧快照遮蔽。
actor MyInsightsSnapshotCache {

    struct Revision: Equatable, Sendable {
        let userID: Int64?
        let embeddingModel: String
        let metadataRevision: Int64
        let healthCount: Int
        let latestHealthAt: String?
        let openSSFCount: Int
        let latestOpenSSFAt: String?
    }

    private struct Entry: Sendable {
        let revision: Revision
        let snapshot: MyInsightsSnapshot
    }

    static let maximumAge: TimeInterval = 60

    private var entries: [InsightsScope: Entry] = [:]

    /// 相同 revision 且未超过 60 秒时复用；否则执行调用方提供的一致读取。
    func value(
        scope: InsightsScope,
        revision: Revision,
        now: Date,
        load: @escaping @Sendable () async throws -> MyInsightsSnapshot
    ) async throws -> MyInsightsSnapshot {
        if let entry = entries[scope],
           entry.revision == revision,
           now.timeIntervalSince(entry.snapshot.generatedAt) < Self.maximumAge {
            return entry.snapshot
        }

        let snapshot = try await load()
        entries[scope] = Entry(revision: revision, snapshot: snapshot)
        return snapshot
    }

    func removeAll() {
        entries.removeAll()
    }
}

/// 基于当前用户 GRDB 数据库生成“我的洞察”快照。
struct GRDBMyInsightsSnapshotProvider: MyInsightsSnapshotProviding, Sendable {

    private struct NamedCount: Sendable {
        let name: String
        let count: Int
    }

    private static let distributionLimit = 8
    private static let distributionColors = [
        "orange", "blue", "yellow", "cyan", "red", "purple", "green", "pink"
    ]

    private let database: any DatabaseManaging
    private let cache: MyInsightsSnapshotCache
    private let knowledgeMetadataCache: KnowledgeBaseMetadataSnapshotCache
    private let now: @Sendable () -> Date

    init(
        database: any DatabaseManaging,
        cache: MyInsightsSnapshotCache = MyInsightsSnapshotCache(),
        knowledgeMetadataCache: KnowledgeBaseMetadataSnapshotCache = KnowledgeBaseMetadataSnapshotCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.cache = cache
        self.knowledgeMetadataCache = knowledgeMetadataCache
        self.now = now
    }

    func load(scope: InsightsScope, embeddingModel: String) async throws -> MyInsightsSnapshot {
        if scope == .knowledge {
            let facts = try await KnowledgeBaseMetadataSnapshotProvider(
                database: database,
                embeddingModel: embeddingModel,
                cache: knowledgeMetadataCache,
                now: now
            ).fetch()
            return Self.makeKnowledgeSnapshot(facts)
        }
        let generatedAt = now()
        let revision = try await fetchRevision(embeddingModel: embeddingModel)
        return try await cache.value(scope: scope, revision: revision, now: generatedAt) {
            try await loadUncached(
                generatedAt: generatedAt
            )
        }
    }

    func invalidate() async {
        await cache.removeAll()
        await knowledgeMetadataCache.removeAll()
    }

    /// 读取轻量 revision。旧测试草稿库缺少派生表时按空表处理，不能让洞察入口崩溃。
    private func fetchRevision(
        embeddingModel: String
    ) async throws -> MyInsightsSnapshotCache.Revision {
        let userID = database.currentUserId
        return try await database.writer.read { db in
            let metadataRevision: Int64
            if try db.tableExists("rag_metadata_revision") {
                metadataRevision = try Int64.fetchOne(
                    db,
                    sql: "SELECT revision FROM rag_metadata_revision WHERE id = 1"
                ) ?? 0
            } else {
                metadataRevision = 0
            }

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
            return MyInsightsSnapshotCache.Revision(
                userID: userID,
                embeddingModel: embeddingModel,
                metadataRevision: metadataRevision,
                healthCount: health.count,
                latestHealthAt: health.latest,
                openSSFCount: openSSF.count,
                latestOpenSSFAt: openSSF.latest
            )
        }
    }

    /// 真正的快照读取只进入一次 `writer.read`，该闭包内所有 SELECT 共享同一 SQLite 视图。
    private func loadUncached(
        generatedAt: Date
    ) async throws -> MyInsightsSnapshot {
        return try await database.writer.read { db in
            try Self.makeStarredSnapshot(
                db: db,
                generatedAt: generatedAt
            )
        }
    }

    /// 知识库页只负责把中立事实投影为 UI 模型，不再重复访问数据库计算聚合值。
    private static func makeKnowledgeSnapshot(
        _ snapshot: KnowledgeBaseMetadataSnapshot
    ) -> MyInsightsSnapshot {
        let total = snapshot.projectCount
        let statusByName = Dictionary(
            uniqueKeysWithValues: snapshot.insights.normalizedStatusCounts.map { ($0.name, $0.count) }
        )
        let knowledge = snapshot.insights
        return MyInsightsSnapshot(
            scope: .knowledge,
            generatedAt: snapshot.generatedAt,
            metrics: [
                metric("projects", value: total, detailKey: "insights.metric.knowledgeProjects.detail"),
                metric("new", value: snapshot.addedInLast30DaysCount, detailKey: "insights.metric.knowledgeRecent.detail"),
                metric("using", value: statusByName["using"] ?? 0, detailKey: "insights.metric.using.detail"),
                metric("organized", value: knowledge.organizedProjectCount, detailKey: "insights.metric.organized.detail")
            ],
            statusItems: [
                distribution("unread", "insights.status.unread", statusByName["unread"] ?? 0, total, "orange"),
                distribution("read", "insights.status.read", statusByName["read"] ?? 0, total, "blue"),
                distribution("using", "insights.status.using", statusByName["using"] ?? 0, total, "green")
            ],
            languageItems: rankedDistribution(
                knowledge.languageCounts.map { NamedCount(name: $0.name, count: $0.count) },
                total: total,
                unknownTitle: "insights.technology.license.unknown",
                otherTitle: "insights.technology.other"
            ),
            topicItems: rankedDistribution(
                knowledge.topicCounts.map { NamedCount(name: $0.name, count: $0.count) },
                total: total,
                unknownTitle: nil,
                otherTitle: "insights.technology.topic.other"
            ),
            licenseItems: rankedDistribution(
                knowledge.licenseCounts.map { NamedCount(name: $0.name, count: $0.count) },
                total: total,
                unknownTitle: "insights.technology.license.unknown",
                otherTitle: "insights.technology.license.other"
            ),
            actionItems: [
                action(.untagged, count: snapshot.untaggedProjectCount),
                action(.unread, count: statusByName["unread"] ?? 0),
                action(.missingReadme, count: snapshot.withoutReadmeSourceProjectCount),
                action(.missingIndexableContent, count: snapshot.withoutIndexableSourceProjectCount),
                action(.indexIssues, count: knowledge.indexIssueProjectCount),
                action(.healthPending, count: max(0, total - knowledge.healthCompletedProjectCount)),
                action(.openSSFPending, count: max(0, total - knowledge.openSSFCompletedProjectCount)),
                action(.maintenanceRisk, count: knowledge.maintenanceRiskProjectCount),
                action(.securityRisk, count: knowledge.securityRiskProjectCount)
            ],
            healthCoverage: .init(completed: knowledge.healthCompletedProjectCount, total: total),
            openSSFCoverage: .init(completed: knowledge.openSSFCompletedProjectCount, total: total),
            assetSummary: .init(
                dormantCount: knowledge.dormantProjectCount,
                archivedCount: knowledge.archivedProjectCount,
                unavailableCount: knowledge.unavailableProjectCount
            ),
            priorityRepositories: knowledge.priorityRepositories.map {
                .init(
                    id: $0.repoID,
                    fullName: $0.fullName,
                    starsCount: $0.stars,
                    isUnread: $0.isUnread,
                    isUntagged: $0.isUntagged
                )
            },
            rhythmPoints: knowledge.weeklyAdditions.map {
                .init(weekStart: $0.weekStart, count: $0.count)
            },
            knowledgeCoverageItems: [
                distribution(
                    "readme",
                    "insights.knowledgeCoverage.readme",
                    knowledge.readmeSourceProjectCount,
                    total,
                    "blue"
                ),
                distribution(
                    "indexable",
                    "insights.knowledgeCoverage.indexable",
                    knowledge.indexableSourceProjectCount,
                    total,
                    "purple"
                ),
                distribution(
                    "embeddingReady",
                    "insights.knowledgeCoverage.embeddingReady",
                    knowledge.embeddingReadyProjectCount,
                    total,
                    "green"
                )
            ]
        )
    }

    private static func makeStarredSnapshot(
        db: Database,
        generatedAt: Date
    ) throws -> MyInsightsSnapshot {
        let scopePredicate = "r.is_starred = 1"
        let recentColumn = "r.starred_at"
        let recentCutoff = ISO8601DateFormatter.shared.string(
            from: generatedAt.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        let dormantCutoff = ISO8601DateFormatter.shared.string(
            from: generatedAt.addingTimeInterval(-365 * 24 * 60 * 60)
        )

        let overview = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS total_count,
                    COALESCE(SUM(CASE
                        WHEN \(recentColumn) IS NOT NULL
                         AND datetime(\(recentColumn)) >= datetime(?)
                        THEN 1 ELSE 0
                    END), 0) AS recent_count,
                    COALESCE(SUM(CASE WHEN n.status = 'using' THEN 1 ELSE 0 END), 0) AS using_count,
                    COALESCE(SUM(CASE WHEN
                        EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id)
                        OR NULLIF(TRIM(n.content), '') IS NOT NULL
                        OR n.status IN ('read', 'using')
                    THEN 1 ELSE 0 END), 0) AS organized_count,
                    COALESCE(SUM(CASE WHEN
                        NOT EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id)
                    THEN 1 ELSE 0 END), 0) AS untagged_count,
                    COALESCE(SUM(CASE WHEN
                        n.repo_id IS NULL OR n.status = 'unread'
                    THEN 1 ELSE 0 END), 0) AS unread_count,
                    COALESCE(SUM(CASE WHEN n.library_state = 'in_library' THEN 1 ELSE 0 END), 0)
                        AS library_count,
                    COALESCE(SUM(CASE WHEN NULLIF(TRIM(n.content), '') IS NOT NULL THEN 1 ELSE 0 END), 0)
                        AS noted_count,
                    COALESCE(SUM(CASE WHEN EXISTS (
                        SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id
                    ) THEN 1 ELSE 0 END), 0) AS tagged_count,
                    COALESCE(SUM(CASE WHEN
                        r.pushed_at IS NOT NULL
                        AND datetime(r.pushed_at) < datetime(?)
                    THEN 1 ELSE 0 END), 0) AS dormant_count,
                    COALESCE(SUM(CASE WHEN r.is_archived = 1 THEN 1 ELSE 0 END), 0)
                        AS archived_count,
                    COALESCE(SUM(CASE WHEN r.access_state = 'unavailable' THEN 1 ELSE 0 END), 0)
                        AS unavailable_count,
                    COALESCE(SUM(CASE WHEN
                        h.repo_id IS NOT NULL AND h.fetch_status != 'failed'
                    THEN 1 ELSE 0 END), 0) AS health_completed_count,
                    COALESCE(SUM(CASE WHEN
                        os.fetch_status = 'success'
                        AND os.aggregate_score IS NOT NULL
                    THEN 1 ELSE 0 END), 0) AS openssf_completed_count,
                    COALESCE(SUM(CASE WHEN
                        h.repo_id IS NOT NULL
                        AND h.fetch_status != 'failed'
                        AND h.maintenance_score < 50
                    THEN 1 ELSE 0 END), 0) AS maintenance_risk_count,
                    COALESCE(SUM(CASE WHEN
                        os.fetch_status = 'success'
                        AND os.aggregate_score IS NOT NULL
                        AND os.aggregate_score < 5
                    THEN 1 ELSE 0 END), 0) AS security_risk_count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                LEFT JOIN repo_health_snapshots h ON h.repo_id = r.id
                LEFT JOIN open_ssf_scores os ON os.repo_id = r.id
                WHERE \(scopePredicate)
                """,
            arguments: [recentCutoff, dormantCutoff]
        )!

        let totalCount: Int = overview["total_count"]
        let healthCompleted: Int = overview["health_completed_count"]
        let openSSFCompleted: Int = overview["openssf_completed_count"]

        let statusCounts = try namedCounts(
            db,
            sql: """
                SELECT
                    CASE
                        WHEN n.repo_id IS NULL OR n.status = 'unread' THEN 'unread'
                        WHEN n.status = 'using' THEN 'using'
                        ELSE 'read'
                    END AS name,
                    COUNT(*) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(scopePredicate)
                -- `repos` 本身也有 name 列，不能写 `GROUP BY name`，否则 SQLite 会按仓库名分组，
                -- 同一状态产生重复字典 key；这里按 SELECT 的第一个派生列分组。
                GROUP BY 1
                """
        )
        let statusByName = Dictionary(uniqueKeysWithValues: statusCounts.map { ($0.name, $0.count) })

        let languages = try namedCounts(
            db,
            sql: """
                SELECT
                    COALESCE(NULLIF(TRIM(r.language), ''), '__unknown__') AS name,
                    COUNT(*) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(scopePredicate)
                GROUP BY COALESCE(NULLIF(TRIM(r.language), ''), '__unknown__')
                ORDER BY count DESC, name COLLATE NOCASE ASC
                """
        )
        let topics = try namedCounts(
            db,
            sql: """
                SELECT LOWER(TRIM(topic.value)) AS name, COUNT(DISTINCT r.id) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                JOIN json_each(
                    CASE WHEN json_valid(r.topics) THEN r.topics ELSE '[]' END
                ) topic
                WHERE \(scopePredicate)
                  AND topic.type = 'text'
                  AND NULLIF(TRIM(topic.value), '') IS NOT NULL
                GROUP BY LOWER(TRIM(topic.value))
                ORDER BY count DESC, name COLLATE NOCASE ASC
                """
        )
        let licenses = try namedCounts(
            db,
            sql: """
                SELECT
                    COALESCE(NULLIF(TRIM(r.license), ''), '__unknown__') AS name,
                    COUNT(*) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(scopePredicate)
                GROUP BY COALESCE(NULLIF(TRIM(r.license), ''), '__unknown__')
                ORDER BY count DESC, name COLLATE NOCASE ASC
                """
        )
        let rhythmPoints = try weeklyRhythm(
            db,
            scopePredicate: scopePredicate,
            dateColumn: recentColumn,
            generatedAt: generatedAt
        )
        let priorityRepositories = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    r.id,
                    r.full_name,
                    r.stars_count,
                    CASE WHEN n.repo_id IS NULL OR n.status = 'unread' THEN 1 ELSE 0 END
                        AS is_unread,
                    CASE WHEN NOT EXISTS (
                        SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id
                    ) THEN 1 ELSE 0 END AS is_untagged
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(scopePredicate)
                  AND (
                    n.repo_id IS NULL
                    OR n.status = 'unread'
                    OR NOT EXISTS (SELECT 1 FROM repo_tags rt WHERE rt.repo_id = r.id)
                  )
                ORDER BY r.stars_count DESC,
                         COALESCE(\(recentColumn), r.cached_at) DESC,
                         r.id DESC
                LIMIT 5
                """
        ).map { row in
            InsightsRepositoryHighlight(
                id: row["id"],
                fullName: row["full_name"],
                starsCount: row["stars_count"],
                isUnread: row["is_unread"],
                isUntagged: row["is_untagged"]
            )
        }

        var actionItems = [
            action(.untagged, count: overview["untagged_count"]),
            action(.unread, count: overview["unread_count"])
        ]
        actionItems.append(contentsOf: [
            action(.healthPending, count: max(0, totalCount - healthCompleted)),
            action(.openSSFPending, count: max(0, totalCount - openSSFCompleted)),
            action(.maintenanceRisk, count: overview["maintenance_risk_count"]),
            action(.securityRisk, count: overview["security_risk_count"])
        ])

        return MyInsightsSnapshot(
            scope: .starred,
            generatedAt: generatedAt,
            metrics: [
                metric(
                    "projects",
                    value: totalCount,
                    detailKey: "insights.metric.projects.detail"
                ),
                metric(
                    "new",
                    value: overview["recent_count"],
                    detailKey: "insights.metric.recent.detail"
                ),
                metric("using", value: overview["using_count"], detailKey: "insights.metric.using.detail"),
                metric("organized", value: overview["organized_count"], detailKey: "insights.metric.organized.detail")
            ],
            statusItems: [
                distribution("unread", "insights.status.unread", statusByName["unread"] ?? 0, totalCount, "orange"),
                distribution("read", "insights.status.read", statusByName["read"] ?? 0, totalCount, "blue"),
                distribution("using", "insights.status.using", statusByName["using"] ?? 0, totalCount, "green")
            ],
            languageItems: rankedDistribution(
                languages,
                total: totalCount,
                unknownTitle: "insights.technology.license.unknown",
                otherTitle: "insights.technology.other"
            ),
            topicItems: rankedDistribution(
                topics,
                total: totalCount,
                unknownTitle: nil,
                otherTitle: "insights.technology.topic.other"
            ),
            licenseItems: rankedDistribution(
                licenses,
                total: totalCount,
                unknownTitle: "insights.technology.license.unknown",
                otherTitle: "insights.technology.license.other"
            ),
            actionItems: actionItems,
            healthCoverage: InsightsCoverage(completed: healthCompleted, total: totalCount),
            openSSFCoverage: InsightsCoverage(completed: openSSFCompleted, total: totalCount),
            assetSummary: InsightsAssetSummary(
                dormantCount: overview["dormant_count"],
                archivedCount: overview["archived_count"],
                unavailableCount: overview["unavailable_count"]
            ),
            priorityRepositories: priorityRepositories,
            rhythmPoints: rhythmPoints,
            knowledgeCoverageItems: [
                distribution(
                    "library",
                    "insights.knowledgeCoverage.library",
                    overview["library_count"],
                    totalCount,
                    "blue"
                ),
                distribution(
                    "notes",
                    "insights.knowledgeCoverage.notes",
                    overview["noted_count"],
                    totalCount,
                    "purple"
                ),
                distribution(
                    "tags",
                    "insights.knowledgeCoverage.tags",
                    overview["tagged_count"],
                    totalCount,
                    "green"
                )
            ]
        )
    }

    /// SQLite 先按周一聚合，Swift 再补齐没有事件的周；这样柱形图不会因空周缩短或移位。
    private static func weeklyRhythm(
        _ db: Database,
        scopePredicate: String,
        dateColumn: String,
        generatedAt: Date
    ) throws -> [InsightsRhythmPoint] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: generatedAt)?.start,
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeek)
        else {
            return []
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    date(
                        \(dateColumn),
                        printf(
                            '-%d days',
                            (CAST(strftime('%w', \(dateColumn)) AS INTEGER) + 6) % 7
                        )
                    ) AS week_start,
                    COUNT(*) AS count
                FROM repos r
                LEFT JOIN repo_notes n ON n.repo_id = r.id
                WHERE \(scopePredicate)
                  AND \(dateColumn) IS NOT NULL
                  AND datetime(\(dateColumn)) >= datetime(?)
                GROUP BY week_start
                ORDER BY week_start ASC
                """,
            arguments: [ISO8601DateFormatter.shared.string(from: firstWeek)]
        )
        let counts = Dictionary(uniqueKeysWithValues: rows.map {
            ($0["week_start"] as String, $0["count"] as Int)
        })

        return (0..<12).compactMap { offset in
            guard let week = calendar.date(
                byAdding: .weekOfYear,
                value: offset,
                to: firstWeek
            ) else {
                return nil
            }
            let key = String(ISO8601DateFormatter.shared.string(from: week).prefix(10))
            return InsightsRhythmPoint(weekStart: week, count: counts[key] ?? 0)
        }
    }

    private static func namedCounts(_ db: Database, sql: String) throws -> [NamedCount] {
        try Row.fetchAll(db, sql: sql).map {
            NamedCount(name: $0["name"], count: $0["count"])
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

    private static func rankedDistribution(
        _ rows: [NamedCount],
        total: Int,
        unknownTitle: String?,
        otherTitle: String
    ) -> [InsightsDistributionItem] {
        let visible = Array(rows.prefix(distributionLimit))
        var items = visible.enumerated().map { index, row in
            distribution(
                stableID(row.name),
                row.name == "__unknown__" ? (unknownTitle ?? row.name) : row.name,
                row.count,
                total,
                distributionColors[index % distributionColors.count]
            )
        }
        let otherCount = rows.dropFirst(distributionLimit).reduce(0) { $0 + $1.count }
        if otherCount > 0 {
            items.append(distribution("other", otherTitle, otherCount, total, "secondary"))
        }
        return items
    }

    private static func stableID(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private static func distribution(
        _ id: String,
        _ title: String,
        _ count: Int,
        _ total: Int,
        _ color: String
    ) -> InsightsDistributionItem {
        InsightsDistributionItem(
            id: id,
            title: title,
            count: count,
            fraction: total > 0 ? min(max(Double(count) / Double(total), 0), 1) : 0,
            colorName: color
        )
    }

    private static func metric(
        _ id: String,
        value: Int,
        detailKey: String
    ) -> InsightsMetric {
        let metadata: (title: String, image: String, tint: String)
        switch id {
        case "projects":
            metadata = ("insights.metric.projects", "star.fill", "yellow")
        case "new":
            metadata = ("insights.metric.recent", "clock.arrow.circlepath", "blue")
        case "using":
            metadata = ("insights.metric.using", "hammer.fill", "green")
        default:
            metadata = ("insights.metric.organized", "checkmark.seal.fill", "purple")
        }
        return InsightsMetric(
            id: id,
            titleKey: metadata.title,
            value: value,
            detailKey: detailKey,
            systemImage: metadata.image,
            tintName: metadata.tint
        )
    }

    private static func action(_ selection: InsightsSelection, count: Int) -> InsightsActionItem {
        let metadata: (title: String, detail: String, image: String, tint: String)
        switch selection {
        case .untagged:
            metadata = (
                "insights.action.untagged",
                "insights.action.untagged.detail",
                "tag.slash.fill",
                "orange"
            )
        case .unread:
            metadata = (
                "insights.action.unread",
                "insights.action.unread.detail",
                "book.closed.fill",
                "blue"
            )
        case .missingReadme:
            metadata = (
                "insights.action.missingReadme",
                "insights.action.missingReadme.detail",
                "doc.questionmark.fill",
                "yellow"
            )
        case .missingIndexableContent:
            metadata = (
                "insights.action.missingIndexableContent",
                "insights.action.missingIndexableContent.detail",
                "doc.text.magnifyingglass",
                "yellow"
            )
        case .indexIssues:
            metadata = (
                "insights.action.indexIssues",
                "insights.action.indexIssues.detail",
                "exclamationmark.magnifyingglass",
                "red"
            )
        case .healthPending:
            metadata = (
                "insights.action.healthPending",
                "insights.action.healthPending.detail",
                "heart.text.square.fill",
                "pink"
            )
        case .openSSFPending:
            metadata = (
                "insights.action.openSSFPending",
                "insights.action.openSSFPending.detail",
                "shield.lefthalf.filled",
                "cyan"
            )
        case .maintenanceRisk:
            metadata = (
                "insights.action.maintenanceRisk",
                "insights.action.maintenanceRisk.detail",
                "wrench.and.screwdriver.fill",
                "orange"
            )
        case .securityRisk:
            metadata = (
                "insights.action.securityRisk",
                "insights.action.securityRisk.detail",
                "lock.trianglebadge.exclamationmark.fill",
                "red"
            )
        default:
            preconditionFailure("Only attention selections can become action items")
        }
        return InsightsActionItem(
            id: selection,
            titleKey: metadata.title,
            detailKey: metadata.detail,
            count: count,
            systemImage: metadata.image,
            tintName: metadata.tint
        )
    }
}
