//
//  ActivitySyncStateRepository.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：Activity 单行 meta 表 GRDB Repository。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct `GRDBActivitySyncStateRepository`
//  - 协议 `ActivitySyncStateRepositoryProtocol`（同目录）
//
//  实现要点：
//  - 单行表 PK 固定 `ActivitySyncStateRecord.singletonID`，所有写入用 `INSERT ...
//    ON CONFLICT(id) DO UPDATE` 单条 SQL 完成（避免 read-modify-write 竞态）
//  - partial update：每个 `update*` 方法只动自己负责的字段，其他字段在 INSERT 路径
//    显式写 NULL（首次入库），ON CONFLICT 路径不出现（保留原值）
//

import Foundation
import GRDB

struct GRDBActivitySyncStateRepository: ActivitySyncStateRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func current() async throws -> ActivitySyncStateRecord? {
        try await database.writer.read { db in
            try ActivitySyncStateRecord.fetchOne(db, key: ActivitySyncStateRecord.singletonID)
        }
    }

    func updateEvents(etag: String?, lastFetchedAt: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: lastFetchedAt)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO activity_sync_state (
                    id, events_etag, blog_rss_etag,
                    last_events_fetched_at, last_blog_fetched_at,
                    last_security_fetched_at, last_cleanup_at
                ) VALUES (?, ?, NULL, ?, NULL, NULL, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    events_etag = excluded.events_etag,
                    last_events_fetched_at = excluded.last_events_fetched_at
                """,
                arguments: [ActivitySyncStateRecord.singletonID, etag, iso]
            )
        }
    }

    func updateBlogRss(etag: String?, lastFetchedAt: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: lastFetchedAt)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO activity_sync_state (
                    id, events_etag, blog_rss_etag,
                    last_events_fetched_at, last_blog_fetched_at,
                    last_security_fetched_at, last_cleanup_at
                ) VALUES (?, NULL, ?, NULL, ?, NULL, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    blog_rss_etag = excluded.blog_rss_etag,
                    last_blog_fetched_at = excluded.last_blog_fetched_at
                """,
                arguments: [ActivitySyncStateRecord.singletonID, etag, iso]
            )
        }
    }

    func updateSecurity(lastFetchedAt: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: lastFetchedAt)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO activity_sync_state (
                    id, events_etag, blog_rss_etag,
                    last_events_fetched_at, last_blog_fetched_at,
                    last_security_fetched_at, last_cleanup_at
                ) VALUES (?, NULL, NULL, NULL, NULL, ?, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    last_security_fetched_at = excluded.last_security_fetched_at
                """,
                arguments: [ActivitySyncStateRecord.singletonID, iso]
            )
        }
    }

    func updateLastCleanupAt(_ date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO activity_sync_state (
                    id, events_etag, blog_rss_etag,
                    last_events_fetched_at, last_blog_fetched_at,
                    last_security_fetched_at, last_cleanup_at
                ) VALUES (?, NULL, NULL, NULL, NULL, NULL, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_cleanup_at = excluded.last_cleanup_at
                """,
                arguments: [ActivitySyncStateRecord.singletonID, iso]
            )
        }
    }

    func clear() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM activity_sync_state")
        }
    }
}
