//
//  GitHubNotificationThreadRepository.swift
//  Starcat
//
//  通知 thread upsert 必须保留 first_seen_at / notified_at，并且 pending/synced
//  期间不能被 GitHub 仍 unread 的增量结果把蓝点打回去（方案 §5.1）。
//

import Foundation
import GRDB

struct GRDBGitHubNotificationThreadRepository: GitHubNotificationThreadRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func fetchAll(limit: Int) async throws -> [GitHubNotificationThreadRecord] {
        try await database.writer.read { db in
            try GitHubNotificationThreadRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM github_notification_threads
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    func fetch(id: String) async throws -> GitHubNotificationThreadRecord? {
        try await database.writer.read { db in
            try GitHubNotificationThreadRecord.fetchOne(db, key: id)
        }
    }

    func unreadCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM github_notification_threads WHERE unread = 1"
            ) ?? 0
        }
    }

    func totalCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM github_notification_threads"
            ) ?? 0
        }
    }

    func upsertMany(_ records: [GitHubNotificationThreadRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO github_notification_threads (
                        id, reason, unread, github_unread,
                        repository_id, repository_full_name,
                        subject_title, subject_type, subject_api_url, subject_number,
                        html_url, actor_login, subject_created_at, excerpt, comments_json, hydrated_at,
                        updated_at, first_seen_at, notified_at, mark_read_state, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        reason = excluded.reason,
                        github_unread = excluded.github_unread,
                        repository_id = excluded.repository_id,
                        repository_full_name = excluded.repository_full_name,
                        subject_title = excluded.subject_title,
                        subject_type = excluded.subject_type,
                        subject_api_url = excluded.subject_api_url,
                        subject_number = excluded.subject_number,
                        fetched_at = excluded.fetched_at,
                        updated_at = excluded.updated_at,
                        unread = CASE
                            WHEN excluded.github_unread = 0 THEN 0
                            WHEN excluded.updated_at != github_notification_threads.updated_at
                             AND github_notification_threads.mark_read_state IN ('synced', 'failed')
                                THEN excluded.github_unread
                            WHEN github_notification_threads.mark_read_state IN ('pending', 'synced', 'failed')
                                THEN github_notification_threads.unread
                            ELSE excluded.github_unread
                        END,
                        mark_read_state = CASE
                            WHEN excluded.github_unread = 0 THEN 'synced'
                            WHEN excluded.updated_at != github_notification_threads.updated_at
                             AND excluded.github_unread = 1
                             AND github_notification_threads.mark_read_state IN ('synced', 'failed')
                                THEN 'idle'
                            ELSE github_notification_threads.mark_read_state
                        END,
                        html_url = CASE
                            WHEN github_notification_threads.subject_api_url = excluded.subject_api_url
                             AND github_notification_threads.updated_at = excluded.updated_at
                            THEN github_notification_threads.html_url
                            ELSE excluded.html_url
                        END,
                        actor_login = CASE
                            WHEN github_notification_threads.subject_api_url = excluded.subject_api_url
                             AND github_notification_threads.updated_at = excluded.updated_at
                            THEN github_notification_threads.actor_login
                            ELSE NULL
                        END,
                        subject_created_at = COALESCE(
                            github_notification_threads.subject_created_at,
                            excluded.subject_created_at
                        ),
                        excerpt = CASE
                            WHEN github_notification_threads.subject_api_url = excluded.subject_api_url
                             AND github_notification_threads.updated_at = excluded.updated_at
                            THEN github_notification_threads.excerpt
                            ELSE NULL
                        END,
                        comments_json = CASE
                            WHEN github_notification_threads.subject_api_url = excluded.subject_api_url
                             AND github_notification_threads.updated_at = excluded.updated_at
                            THEN github_notification_threads.comments_json
                            ELSE NULL
                        END,
                        hydrated_at = CASE
                            WHEN github_notification_threads.subject_api_url = excluded.subject_api_url
                             AND github_notification_threads.updated_at = excluded.updated_at
                            THEN github_notification_threads.hydrated_at
                            ELSE NULL
                        END
                    """,
                    arguments: [
                        record.id,
                        record.reason,
                        record.unread ? 1 : 0,
                        record.githubUnread ? 1 : 0,
                        record.repositoryId,
                        record.repositoryFullName,
                        record.subjectTitle,
                        record.subjectType,
                        record.subjectApiUrl,
                        record.subjectNumber,
                        record.htmlUrl,
                        record.actorLogin,
                        record.subjectCreatedAt,
                        record.excerpt,
                        record.commentsJson,
                        record.hydratedAt,
                        record.updatedAt,
                        record.firstSeenAt,
                        record.notifiedAt,
                        record.markReadState,
                        record.fetchedAt
                    ]
                )
            }
        }
    }

    func updateLocalUnread(
        id: String,
        unread: Bool,
        markReadState: GitHubNotificationMarkReadState,
        githubUnread: Bool?
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE github_notification_threads
                SET unread = ?,
                    mark_read_state = ?,
                    github_unread = COALESCE(?, github_unread)
                WHERE id = ?
                """,
                arguments: [
                    unread ? 1 : 0,
                    markReadState.rawValue,
                    githubUnread.map { $0 ? 1 : 0 },
                    id
                ]
            )
        }
    }

    func updateHydration(
        id: String,
        actorLogin: String?,
        excerpt: String?,
        commentsJson: String?,
        htmlUrl: String?,
        subjectCreatedAt: String?,
        hydratedAt: String
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE github_notification_threads
                SET actor_login = ?, excerpt = ?, comments_json = ?, html_url = ?,
                    subject_created_at = ?, hydrated_at = ?
                WHERE id = ?
                """,
                arguments: [actorLogin, excerpt, commentsJson, htmlUrl, subjectCreatedAt, hydratedAt, id]
            )
        }
    }

    func markNotified(ids: [String], notifiedAt: String) async throws {
        guard !ids.isEmpty else { return }
        try await database.writer.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                    UPDATE github_notification_threads
                    SET notified_at = ?
                    WHERE id = ? AND notified_at IS NULL
                    """,
                    arguments: [notifiedAt, id]
                )
            }
        }
    }

    func fetchFailedMarkRead() async throws -> [GitHubNotificationThreadRecord] {
        try await database.writer.read { db in
            try GitHubNotificationThreadRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM github_notification_threads
                WHERE mark_read_state = 'failed'
                """
            )
        }
    }

    func fetchUnnotified() async throws -> [GitHubNotificationThreadRecord] {
        try await database.writer.read { db in
            try GitHubNotificationThreadRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM github_notification_threads
                WHERE notified_at IS NULL
                """
            )
        }
    }

    func maxUpdatedAt() async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT MAX(updated_at) FROM github_notification_threads"
            )
        }
    }

    func deleteIDs(withPrefix prefix: String) async throws {
        guard !prefix.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM github_notification_threads WHERE id LIKE ?",
                arguments: [prefix + "%"]
            )
        }
    }

    func delete(id: String) async throws {
        guard !id.isEmpty else { return }
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM github_notification_threads WHERE id = ?",
                arguments: [id]
            )
        }
    }
}

struct GRDBGitHubNotificationSyncStateRepository: GitHubNotificationSyncStateRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func current() async throws -> GitHubNotificationSyncStateRecord? {
        try await database.writer.read { db in
            try GitHubNotificationSyncStateRecord.fetchOne(
                db,
                key: GitHubNotificationSyncStateRecord.singletonID
            )
        }
    }

    func resetForBackfill() async throws {
        try await database.writer.write { db in
            // 组织授权变化后 GitHub 可能补回旧 thread。只删 singleton 游标，不能清通知表，
            // 否则会丢掉本地已读状态、详情 hydrate 缓存和仍需重试的 mark-read 状态。
            try db.execute(
                sql: "DELETE FROM github_notification_sync_state WHERE id = ?",
                arguments: [GitHubNotificationSyncStateRecord.singletonID]
            )
        }
    }

    func updateAfterFetch(
        lastModified: String?,
        watermarkUpdatedAt: String?,
        lastFetchedAt: Date,
        backfillCompleted: Bool,
        pollIntervalSeconds: Int?
    ) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: lastFetchedAt)
        try await database.writer.write { db in
            let existing = try GitHubNotificationSyncStateRecord.fetchOne(
                db,
                key: GitHubNotificationSyncStateRecord.singletonID
            )
            let backfill = backfillCompleted
                ? (existing?.backfillCompletedAt ?? iso)
                : existing?.backfillCompletedAt
            try db.execute(
                sql: """
                INSERT INTO github_notification_sync_state (
                    id, last_modified, watermark_updated_at,
                    last_fetched_at, backfill_completed_at, last_poll_interval_seconds
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_modified = excluded.last_modified,
                    watermark_updated_at = excluded.watermark_updated_at,
                    last_fetched_at = excluded.last_fetched_at,
                    backfill_completed_at = excluded.backfill_completed_at,
                    last_poll_interval_seconds = excluded.last_poll_interval_seconds
                """,
                arguments: [
                    GitHubNotificationSyncStateRecord.singletonID,
                    lastModified ?? existing?.lastModified,
                    watermarkUpdatedAt ?? existing?.watermarkUpdatedAt,
                    iso,
                    backfill,
                    pollIntervalSeconds ?? existing?.lastPollIntervalSeconds
                ]
            )
        }
    }
}
