//
//  ActivityAnnouncementRepository.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：announcement 双源公告聚合 GRDB 持久化 Repository。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct `GRDBActivityAnnouncementRepository`
//  - 协议 `ActivityAnnouncementRepositoryProtocol`（同目录）
//
//  关键设计：
//  - `upsertMany` 走 `INSERT ... ON CONFLICT(id) DO UPDATE`：同一 announcement 重复拉到时
//    刷新 title / body 等字段，但**保留 is_read**（与 ActivityEventRepository 同款）
//  - 30 天清理与 ActivityEventRepository 同款：用 SQLite `datetime('now', '-N days')` 比较
//

import Foundation
import GRDB

struct GRDBActivityAnnouncementRepository: ActivityAnnouncementRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    func fetchAll(limit: Int) async throws -> [ActivityAnnouncementRecord] {
        try await database.writer.read { db in
            try ActivityAnnouncementRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM activity_announcements
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    func fetch(source: AnnouncementSource, limit: Int) async throws -> [ActivityAnnouncementRecord] {
        try await database.writer.read { db in
            try ActivityAnnouncementRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM activity_announcements
                WHERE source = ?
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [source.rawValue, limit]
            )
        }
    }

    func unreadCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM activity_announcements WHERE is_read = 0"
            ) ?? 0
        }
    }

    // MARK: - 写入

    func upsertMany(_ records: [ActivityAnnouncementRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO activity_announcements (
                        id, source, title, body_markdown, author,
                        url, repo_name, categories,
                        is_read, created_at, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        source = excluded.source,
                        title = excluded.title,
                        body_markdown = excluded.body_markdown,
                        author = excluded.author,
                        url = excluded.url,
                        repo_name = excluded.repo_name,
                        categories = excluded.categories,
                        fetched_at = excluded.fetched_at
                    """,
                    arguments: [
                        record.id, record.source, record.title, record.bodyMarkdown, record.author,
                        record.url, record.repoName, record.categories,
                        record.isRead ? 1 : 0, record.createdAt, record.fetchedAt
                    ]
                )
            }
        }
    }

    func markRead(announcementId: String, isRead: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE activity_announcements SET is_read = ? WHERE id = ?",
                arguments: [isRead ? 1 : 0, announcementId]
            )
        }
    }

    func markAllRead() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE activity_announcements SET is_read = 1")
        }
    }

    @discardableResult
    func deleteOlderThan(days: Int) async throws -> Int {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM activity_announcements WHERE created_at < datetime('now', ?)",
                arguments: ["-\(days) days"]
            )
            return db.changesCount
        }
    }

    func clearAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM activity_announcements")
        }
    }
}
