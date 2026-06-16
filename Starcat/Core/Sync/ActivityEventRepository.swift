//
//  ActivityEventRepository.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：following 事件流 GRDB 持久化 Repository。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct `GRDBActivityEventRepository`
//  - 协议 `ActivityEventRepositoryProtocol`（同目录）
//
//  关键设计：
//  - `upsertMany` 走 `INSERT ... ON CONFLICT(id) DO UPDATE`：同一 event 重复拉到时
//    刷新 actor / payload，但**保留 is_read**（与 `GRDBReleaseRepository.upsertMany` 同款约束）
//  - `deleteOlderThan(days:)` 用 SQLite `datetime('now', '-N days')` 直接比对 ISO8601
//    字符串列——SQLite 的 datetime 函数能正确解析 ISO8601 文本日期（与
//    `DatabaseMigrationsV1` cleanup 示例一致）
//

import Foundation
import GRDB

struct GRDBActivityEventRepository: ActivityEventRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    func fetchAll(limit: Int) async throws -> [ActivityEventRecord] {
        try await database.writer.read { db in
            try ActivityEventRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM activity_events
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    func unreadCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM activity_events WHERE is_read = 0"
            ) ?? 0
        }
    }

    // MARK: - 写入

    func upsertMany(_ records: [ActivityEventRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO activity_events (
                        id, event_type, actor_login, actor_avatar_url,
                        repo_name, repo_id, payload_json,
                        is_read, created_at, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        event_type = excluded.event_type,
                        actor_login = excluded.actor_login,
                        actor_avatar_url = excluded.actor_avatar_url,
                        repo_name = excluded.repo_name,
                        repo_id = excluded.repo_id,
                        payload_json = excluded.payload_json,
                        fetched_at = excluded.fetched_at
                    """,
                    arguments: [
                        record.id, record.eventType, record.actorLogin, record.actorAvatarUrl,
                        record.repoName, record.repoId, record.payloadJson,
                        record.isRead ? 1 : 0, record.createdAt, record.fetchedAt
                    ]
                )
            }
        }
    }

    func markRead(eventId: String, isRead: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE activity_events SET is_read = ? WHERE id = ?",
                arguments: [isRead ? 1 : 0, eventId]
            )
        }
    }

    func markAllRead() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE activity_events SET is_read = 1")
        }
    }

    @discardableResult
    func deleteOlderThan(days: Int) async throws -> Int {
        try await database.writer.write { db in
            // SQLite datetime('now', '-N days') 与 ISO8601 文本列比较是合法的。
            // 拼字符串安全性：`days` 是调用方控制的 Int（非用户输入），不存在 SQL 注入风险，
            // 但仍走参数化保持一致性。
            try db.execute(
                sql: "DELETE FROM activity_events WHERE created_at < datetime('now', ?)",
                arguments: ["-\(days) days"]
            )
            return db.changesCount
        }
    }

    func clearAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM activity_events")
        }
    }
}
