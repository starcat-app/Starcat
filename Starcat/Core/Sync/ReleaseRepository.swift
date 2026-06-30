//
//  ReleaseRepository.swift
//  Starcat
//
//  Release 元数据缓存 Repository GRDB 实现（HOM-47）。
//
//  关键设计：
//  - upsertMany 走 INSERT ... ON CONFLICT(id) DO UPDATE：同一 release 重复拉到时
//    更新 body / assets，但**保留 is_read**（用户已读不能被刷新覆盖）
//  - fetchTimeline 一次 JOIN 出 release + repo + subscription 三表，避免 ViewModel 端 N+1
//

import Foundation
import GRDB

struct GRDBReleaseRepository: ReleaseRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    func latest(forRepo repoId: Int64) async throws -> ReleaseRecord? {
        try await database.writer.read { db in
            try ReleaseRecord.fetchOne(
                db,
                sql: """
                SELECT * FROM releases
                WHERE repo_id = ?
                ORDER BY COALESCE(published_at, created_at_remote, fetched_at) DESC
                LIMIT 1
                """,
                arguments: [repoId]
            )
        }
    }

    func latestPublishedAtByRepoIds(_ repoIds: [Int64]) async throws -> [Int64: String] {
        guard !repoIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: repoIds.count).joined(separator: ", ")
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT repo_id,
                       MAX(COALESCE(published_at, created_at_remote, fetched_at)) AS latest_at
                FROM releases
                WHERE repo_id IN (\(placeholders))
                GROUP BY repo_id
                """,
                arguments: StatementArguments(repoIds)
            )
            var result: [Int64: String] = [:]
            for row in rows {
                if let repoId: Int64 = row["repo_id"], let latest: String = row["latest_at"] {
                    result[repoId] = latest
                }
            }
            return result
        }
    }

    func fetch(forRepo repoId: Int64, limit: Int) async throws -> [ReleaseRecord] {
        try await database.writer.read { db in
            try ReleaseRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM releases
                WHERE repo_id = ?
                ORDER BY COALESCE(published_at, created_at_remote, fetched_at) DESC
                LIMIT ?
                """,
                arguments: [repoId, limit]
            )
        }
    }

    func fetchTimeline(limit: Int, offset: Int) async throws -> [ReleaseTimelineEntry] {
        try await database.writer.read { db in
            // 一次 JOIN 同时拿 release + repo，避免 N+1。
            // GRDB 不直接支持"一次 query 解码出两个 model"，这里用裸 SQL 拼成一行宽表，
            // 再用 Row 索引手工 split 出 ReleaseRecord 与 Repo。
            // 列顺序：先 releases.* 再 repos.*，由 SELECT 显式指定保证稳定。
            let releaseColumns = ReleaseRecord.databaseTableName + ".*"
            let repoColumns = Repo.databaseTableName + ".*"
            let sql = """
            SELECT \(releaseColumns), \(repoColumns)
            FROM releases
            INNER JOIN release_subscriptions ON release_subscriptions.repo_id = releases.repo_id
            INNER JOIN repos ON repos.id = releases.repo_id
            WHERE release_subscriptions.is_subscribed = 1
            ORDER BY COALESCE(releases.published_at, releases.created_at_remote, releases.fetched_at) DESC
            LIMIT ?
            OFFSET ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit, offset])
            return try rows.map { row -> ReleaseTimelineEntry in
                // 用 ReleaseRecord 的 KeyPath 解码：先把 release 字段抠出来，避开同名列冲突。
                // GRDB 的 Row[String] 会按列别名匹配；releases.id 与 repos.id 同名时
                // 后者覆盖前者，所以这里逐字段读取并用 release-specific column 命名。
                let release = ReleaseRecord(
                    id: row["id"],
                    repoId: row["repo_id"],
                    tagName: row["tag_name"],
                    name: row["name"],
                    bodyMarkdown: row["body_markdown"],
                    htmlUrl: row["html_url"],
                    isPrerelease: row["is_prerelease"],
                    isDraft: row["is_draft"],
                    publishedAt: row["published_at"],
                    createdAtRemote: row["created_at_remote"],
                    assetsJson: row["assets_json"],
                    isRead: row["is_read"],
                    fetchedAt: row["fetched_at"]
                )
                // repos.* 与 releases 共享几个同名列（id / html_url / created_at），
                // 直接用 Row 解码会撞列。改为再做一次单独的 fetch，N 不会很大（time line 默认 ≤ 100 行）。
                guard let repo = try Repo.fetchOne(db, key: release.repoId) else {
                    throw ReleaseRepositoryError.timelineRepoMissing(repoId: release.repoId)
                }
                return ReleaseTimelineEntry(release: release, repo: repo)
            }
        }
    }

    func unreadCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM releases r
                INNER JOIN release_subscriptions s ON s.repo_id = r.repo_id
                WHERE s.is_subscribed = 1 AND r.is_read = 0
                """) ?? 0
        }
    }

    // MARK: - 写入

    func upsertMany(_ records: [ReleaseRecord], isReadDefault: Bool) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO releases (
                        id, repo_id, tag_name, name, body_markdown, html_url,
                        is_prerelease, is_draft, published_at, created_at_remote,
                        assets_json, is_read, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        tag_name = excluded.tag_name,
                        name = excluded.name,
                        body_markdown = excluded.body_markdown,
                        html_url = excluded.html_url,
                        is_prerelease = excluded.is_prerelease,
                        is_draft = excluded.is_draft,
                        published_at = excluded.published_at,
                        created_at_remote = excluded.created_at_remote,
                        assets_json = excluded.assets_json,
                        fetched_at = excluded.fetched_at
                    """,
                    arguments: [
                        record.id, record.repoId, record.tagName, record.name,
                        record.bodyMarkdown, record.htmlUrl,
                        record.isPrerelease ? 1 : 0, record.isDraft ? 1 : 0,
                        record.publishedAt, record.createdAtRemote,
                        record.assetsJson, isReadDefault ? 1 : 0, record.fetchedAt
                    ]
                )
            }
        }
    }

    func markRead(releaseId: Int64, isRead: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE releases SET is_read = ? WHERE id = ?",
                arguments: [isRead ? 1 : 0, releaseId]
            )
        }
    }

    func markAllRead(forRepo repoId: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE releases SET is_read = 1 WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
    }

    func markAllRead() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE releases SET is_read = 1")
        }
    }
}

// MARK: - Errors

enum ReleaseRepositoryError: Error, LocalizedError {
    case timelineRepoMissing(repoId: Int64)

    var errorDescription: String? {
        switch self {
        case .timelineRepoMissing(let id):
            return "Release timeline missing repo \(id)"
        }
    }
}
