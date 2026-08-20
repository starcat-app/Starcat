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
                let notificationThreadID = record.notificationThreadId ?? record.id
                // 组织 Issue 可能先于 Notifications 抵达。把同 subject 的本地行改用真实
                // thread id，再走原 upsert，避免时间线出现两条并保留已经缓存的正文 / 评论。
                try db.execute(
                    sql: """
                        UPDATE github_notification_threads
                        SET id = ?
                        WHERE subject_api_url = ?
                          AND id != ?
                          AND notification_thread_id IS NULL
                        """,
                    arguments: [record.id, record.subjectApiUrl, record.id]
                )
                try db.execute(
                    sql: """
                    INSERT INTO github_notification_threads (
                        id, reason, unread, github_unread,
                        repository_id, repository_full_name,
                        subject_title, subject_type, subject_api_url, subject_number,
                        html_url, actor_login, subject_created_at, excerpt, comments_json, hydrated_at,
                        updated_at, first_seen_at, notified_at, mark_read_state, fetched_at,
                        notification_thread_id, source_kind, organization_login,
                        credential_source, issue_state
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        reason = excluded.reason,
                        notification_thread_id = excluded.notification_thread_id,
                        source_kind = 'notification',
                        notified_at = CASE
                            WHEN github_notification_threads.notification_thread_id IS NULL
                            THEN excluded.notified_at
                            ELSE github_notification_threads.notified_at
                        END,
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
                        END,
                        organization_login = COALESCE(
                            github_notification_threads.organization_login,
                            excluded.organization_login
                        ),
                        credential_source = COALESCE(
                            github_notification_threads.credential_source,
                            excluded.credential_source
                        ),
                        issue_state = COALESCE(
                            github_notification_threads.issue_state,
                            excluded.issue_state
                        )
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
                        record.fetchedAt,
                        notificationThreadID,
                        "notification",
                        record.organizationLogin,
                        record.credentialSource,
                        record.issueState
                    ]
                )
            }
        }
    }

    func upsertOrganizationIssues(
        _ issues: [GitHubOrganizationIssue],
        credentialSource: GitHubTimelineCredentialSource,
        fetchedAt: String
    ) async throws {
        guard !issues.isEmpty else { return }
        try await database.writer.write { db in
            let formatter = ISO8601DateFormatter.shared
            for issue in issues {
                let subjectAPIURL = issue.subjectAPIURL.isEmpty
                    ? "https://api.github.com/repos/\(issue.repositoryFullName)/issues/\(issue.number)"
                    : issue.subjectAPIURL
                let existingID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM github_notification_threads WHERE subject_api_url = ? LIMIT 1",
                    arguments: [subjectAPIURL]
                )
                let id = existingID ?? "organization-issue:\(issue.id)"
                let createdAt = issue.createdAt.map(formatter.string(from:))
                let updatedAt = formatter.string(from: issue.updatedAt ?? issue.createdAt ?? Date())
                try db.execute(
                    sql: """
                        INSERT INTO github_notification_threads (
                            id, reason, unread, github_unread,
                            repository_id, repository_full_name,
                            subject_title, subject_type, subject_api_url, subject_number,
                            html_url, actor_login, subject_created_at, excerpt, comments_json, hydrated_at,
                            updated_at, first_seen_at, notified_at, mark_read_state, fetched_at,
                            notification_thread_id, source_kind, organization_login,
                            credential_source, issue_state
                        ) VALUES (?, 'organization', 0, 0, NULL, ?, ?, 'Issue', ?, ?, ?, ?, ?, ?, NULL, NULL,
                                  ?, ?, ?, 'synced', ?, NULL, 'organization_issue', ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            repository_full_name = excluded.repository_full_name,
                            subject_title = excluded.subject_title,
                            subject_type = 'Issue',
                            subject_api_url = excluded.subject_api_url,
                            subject_number = excluded.subject_number,
                            html_url = excluded.html_url,
                            actor_login = COALESCE(excluded.actor_login, github_notification_threads.actor_login),
                            subject_created_at = COALESCE(
                                github_notification_threads.subject_created_at,
                                excluded.subject_created_at
                            ),
                            excerpt = excluded.excerpt,
                            comments_json = CASE
                                WHEN github_notification_threads.updated_at = excluded.updated_at
                                THEN github_notification_threads.comments_json
                                ELSE NULL
                            END,
                            hydrated_at = CASE
                                WHEN github_notification_threads.updated_at = excluded.updated_at
                                THEN github_notification_threads.hydrated_at
                                ELSE NULL
                            END,
                            updated_at = excluded.updated_at,
                            fetched_at = excluded.fetched_at,
                            organization_login = excluded.organization_login,
                            credential_source = CASE
                                WHEN github_notification_threads.credential_source = 'primary_oauth'
                                THEN github_notification_threads.credential_source
                                ELSE excluded.credential_source
                            END,
                            issue_state = excluded.issue_state,
                            source_kind = CASE
                                WHEN github_notification_threads.notification_thread_id IS NULL
                                THEN 'organization_issue'
                                ELSE github_notification_threads.source_kind
                            END
                        """,
                    arguments: [
                        id,
                        issue.repositoryFullName,
                        issue.title,
                        subjectAPIURL,
                        issue.number,
                        issue.htmlURL.absoluteString,
                        issue.authorLogin,
                        createdAt,
                        issue.body,
                        updatedAt,
                        fetchedAt,
                        fetchedAt,
                        fetchedAt,
                        issue.organization,
                        credentialSource.rawValue,
                        issue.state.rawValue
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
                WHERE mark_read_state = 'failed' AND notification_thread_id IS NOT NULL
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
                WHERE notified_at IS NULL AND notification_thread_id IS NOT NULL
                """
            )
        }
    }

    func maxUpdatedAt() async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT MAX(updated_at) FROM github_notification_threads WHERE notification_thread_id IS NOT NULL"
            )
        }
    }

    func organizationIssueSyncState(
        organization: String,
        credentialSource: GitHubTimelineCredentialSource
    ) async throws -> GitHubOrganizationIssueSyncStateRecord? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM github_organization_issue_sync_state
                    WHERE scope_key = ?
                    """,
                arguments: [Self.scopeKey(organization: organization, credentialSource: credentialSource)]
            ) else { return nil }
            return GitHubOrganizationIssueSyncStateRecord(
                organizationLogin: row["organization_login"],
                credentialSource: credentialSource,
                nextPage: row["next_page"],
                watermarkUpdatedAt: row["watermark_updated_at"],
                backfillCompletedAt: row["backfill_completed_at"],
                lastFetchedAt: row["last_fetched_at"],
                lastError: row["last_error"]
            )
        }
    }

    func updateOrganizationIssueSyncState(
        organization: String,
        credentialSource: GitHubTimelineCredentialSource,
        nextPage: Int?,
        watermarkUpdatedAt: String?,
        backfillCompletedAt: String?,
        lastFetchedAt: String?,
        lastError: String?
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO github_organization_issue_sync_state (
                        scope_key, organization_login, credential_source, next_page,
                        watermark_updated_at, backfill_completed_at, last_fetched_at, last_error
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(scope_key) DO UPDATE SET
                        next_page = excluded.next_page,
                        watermark_updated_at = excluded.watermark_updated_at,
                        backfill_completed_at = excluded.backfill_completed_at,
                        last_fetched_at = excluded.last_fetched_at,
                        last_error = excluded.last_error
                    """,
                arguments: [
                    Self.scopeKey(organization: organization, credentialSource: credentialSource),
                    organization,
                    credentialSource.rawValue,
                    nextPage,
                    watermarkUpdatedAt,
                    backfillCompletedAt,
                    lastFetchedAt,
                    lastError
                ]
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

    func removeNotificationThread(id: String) async throws {
        guard !id.isEmpty else { return }
        try await database.writer.write { db in
            let organization: String? = try String.fetchOne(
                db,
                sql: "SELECT organization_login FROM github_notification_threads WHERE id = ?",
                arguments: [id]
            )
            if organization != nil {
                try db.execute(
                    sql: """
                        UPDATE github_notification_threads
                        SET notification_thread_id = NULL,
                            source_kind = 'organization_issue',
                            reason = 'organization',
                            unread = 0,
                            github_unread = 0,
                            mark_read_state = 'synced'
                        WHERE id = ?
                        """,
                    arguments: [id]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM github_notification_threads WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    private static func scopeKey(
        organization: String,
        credentialSource: GitHubTimelineCredentialSource
    ) -> String {
        "\(credentialSource.rawValue):\(organization.lowercased())"
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
