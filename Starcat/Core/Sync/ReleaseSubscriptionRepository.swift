//
//  ReleaseSubscriptionRepository.swift
//  Starcat
//
//  Release 订阅 Repository GRDB 实现（HOM-47）。
//
//  schema 对照（DatabaseMigrationsV1.createReleaseSubscriptions）：
//    repo_id INTEGER PRIMARY KEY → repos.id ON DELETE CASCADE
//    is_subscribed BOOLEAN NOT NULL DEFAULT 1
//    notify_enabled BOOLEAN NOT NULL DEFAULT 1
//    last_known_release_id INTEGER
//    last_known_tag_name TEXT
//    last_polled_at TEXT
//    created_at TEXT NOT NULL
//    modified_at TEXT NOT NULL
//

import Foundation
import GRDB

struct GRDBReleaseSubscriptionRepository: ReleaseSubscriptionRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    func find(repoId: Int64) async throws -> ReleaseSubscription? {
        try await database.writer.read { db in
            try ReleaseSubscription.fetchOne(db, key: repoId)
        }
    }

    func fetchActive() async throws -> [ReleaseSubscription] {
        try await database.writer.read { db in
            try ReleaseSubscription.fetchAll(
                db,
                sql: "SELECT * FROM release_subscriptions WHERE is_subscribed = 1"
            )
        }
    }

    func fetchAll() async throws -> [ReleaseSubscription] {
        try await database.writer.read { db in
            try ReleaseSubscription.fetchAll(db)
        }
    }

    // MARK: - 写入

    /// 订阅 / 重新订阅。
    ///
    /// 三种情况，都用 UPSERT 一条 SQL 处理：
    /// 1. 行不存在：INSERT 一行，is_subscribed=1，写入 lastKnown 游标 + 双时间戳
    /// 2. 行存在但 is_subscribed=0（之前取消过）：仅 UPDATE is_subscribed=1 + modifiedAt，
    ///    保留原 lastKnownReleaseId（如调用方想"重新订阅时仍按上次见过的最新 release 计算新增"）；
    ///    若 primingReleaseId 非 nil 也会一并更新（调用方决定是否覆盖）
    /// 3. 行存在且 is_subscribed=1（重复订阅）：modifiedAt 推进，game-no-op
    ///
    /// primingReleaseId 设计：首次订阅必传 `nil` 之外的"当前最新 release id"，
    /// 否则下一次轮询会把仓库历史所有 Release 当成"新 Release"批量推通知给用户。
    func subscribe(repoId: Int64, primingReleaseId: Int64?, primingTagName: String?) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO release_subscriptions (
                    repo_id, is_subscribed, notify_enabled,
                    last_known_release_id, last_known_tag_name, last_polled_at,
                    created_at, modified_at
                ) VALUES (?, 1, 1, ?, ?, NULL, ?, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    is_subscribed = 1,
                    last_known_release_id = COALESCE(excluded.last_known_release_id, last_known_release_id),
                    last_known_tag_name = COALESCE(excluded.last_known_tag_name, last_known_tag_name),
                    modified_at = excluded.modified_at
                """,
                arguments: [repoId, primingReleaseId, primingTagName, nowISO, nowISO]
            )
        }
    }

    func unsubscribe(repoId: Int64) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE release_subscriptions
                SET is_subscribed = 0, modified_at = ?
                WHERE repo_id = ?
                """,
                arguments: [nowISO, repoId]
            )
        }
    }

    func setNotifyEnabled(repoId: Int64, enabled: Bool) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE release_subscriptions
                SET notify_enabled = ?, modified_at = ?
                WHERE repo_id = ?
                """,
                arguments: [enabled ? 1 : 0, nowISO, repoId]
            )
        }
    }

    func updatePollCursor(
        repoId: Int64,
        latestReleaseId: Int64?,
        latestTagName: String?,
        polledAt: Date
    ) async throws {
        let polledISO = ISO8601DateFormatter.shared.string(from: polledAt)
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE release_subscriptions
                SET last_known_release_id = ?,
                    last_known_tag_name = ?,
                    last_polled_at = ?,
                    modified_at = ?
                WHERE repo_id = ?
                """,
                arguments: [latestReleaseId, latestTagName, polledISO, nowISO, repoId]
            )
        }
    }
}
