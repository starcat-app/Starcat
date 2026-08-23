//
//  DataContributionRepository.swift
//  Starcat
//
//  公开 Star 数据贡献的账户级授权与单槽 Outbox 仓储。
//
//  数据库本身已经按 GitHub 用户隔离，但所有写操作仍校验 account_id：异步任务可能
//  恰好跨过账户切换边界，双重校验可以拒绝把旧账号快照写进新账号数据库。
//

import Foundation
import GRDB

struct DataContributionPreferences: Equatable, Sendable {
    let accountID: Int64
    let isEnabled: Bool
    let participantID: String?
}

enum DataContributionOutboxState: String, Sendable {
    case pending
    case retryWait = "retry_wait"
}

struct DataContributionOutboxTask: Equatable, Sendable {
    let id: String
    let accountID: Int64
    let participantID: String
    let schemaVersion: Int
    let payload: Data
    let contentHash: String
    let state: DataContributionOutboxState
    let attemptCount: Int
    let nextAttemptAt: Date?
}

enum DataContributionRepositoryError: Error, Equatable {
    case accountScopeChanged
    case contributionDisabled
    case invalidStoredTask
}

/// Repository 不保存网络状态；上传 actor 只通过这里原子领取、延后或删除单条任务。
struct DataContributionRepository: Sendable {
    private let database: any DatabaseManaging
    private let participantIDProvider: @Sendable () -> String

    init(
        database: any DatabaseManaging,
        participantIDProvider: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.database = database
        self.participantIDProvider = participantIDProvider
    }

    func preferences(accountID: Int64) async throws -> DataContributionPreferences {
        try validateScope(accountID: accountID)
        let accountKey = String(accountID)
        return try await database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT is_enabled, participant_id
                    FROM data_contribution_preferences
                    WHERE account_id = ?
                    """,
                arguments: [accountKey]
            ) else {
                return DataContributionPreferences(
                    accountID: accountID,
                    isEnabled: false,
                    participantID: nil
                )
            }
            return DataContributionPreferences(
                accountID: accountID,
                isEnabled: row["is_enabled"],
                participantID: row["participant_id"]
            )
        }
    }

    /// 开启时创建或复用随机 participant ID；关闭时只清空未发送任务，保留匿名主体。
    @discardableResult
    func setEnabled(_ isEnabled: Bool, accountID: Int64, now: Date = Date()) async throws -> String? {
        try validateScope(accountID: accountID)
        let accountKey = String(accountID)
        let generatedParticipantID = isEnabled ? participantIDProvider() : nil
        let nowValue = RecommendationSnapshotJSON.string(from: now)

        return try await database.writer.write { db in
            let existingID = try String.fetchOne(
                db,
                sql: "SELECT participant_id FROM data_contribution_preferences WHERE account_id = ?",
                arguments: [accountKey]
            )
            let participantID = existingID ?? generatedParticipantID

            try db.execute(
                sql: """
                    INSERT INTO data_contribution_preferences (
                        account_id, is_enabled, participant_id, updated_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        is_enabled = excluded.is_enabled,
                        participant_id = COALESCE(
                            data_contribution_preferences.participant_id,
                            excluded.participant_id
                        ),
                        updated_at = excluded.updated_at
                    """,
                arguments: [accountKey, isEnabled, participantID, nowValue]
            )

            if !isEnabled {
                try db.execute(
                    sql: "DELETE FROM data_contribution_outbox WHERE account_id = ?",
                    arguments: [accountKey]
                )
            }
            return participantID
        }
    }

    /// 新完整快照覆盖旧任务，防止长期离线时积累过时的用户画像。
    func enqueue(
        snapshot: RecommendationSnapshot,
        accountID: Int64,
        now: Date = Date()
    ) async throws {
        try validateScope(accountID: accountID)
        let accountKey = String(accountID)
        let payload = try snapshot.encodedPayload()
        let nowValue = RecommendationSnapshotJSON.string(from: now)

        try await database.writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT is_enabled, participant_id
                    FROM data_contribution_preferences
                    WHERE account_id = ?
                    """,
                arguments: [accountKey]
            ), row["is_enabled"] as Bool,
               let participantID: String = row["participant_id"],
               participantID == snapshot.participantID else {
                throw DataContributionRepositoryError.contributionDisabled
            }

            try db.execute(
                sql: """
                    INSERT INTO data_contribution_outbox (
                        id, account_id, participant_id, schema_version, payload,
                        content_hash, state, attempt_count, next_attempt_at,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
                    ON CONFLICT(account_id) DO UPDATE SET
                        id = excluded.id,
                        participant_id = excluded.participant_id,
                        schema_version = excluded.schema_version,
                        payload = excluded.payload,
                        content_hash = excluded.content_hash,
                        state = excluded.state,
                        attempt_count = 0,
                        next_attempt_at = NULL,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    snapshot.snapshotID,
                    accountKey,
                    snapshot.participantID,
                    snapshot.schemaVersion,
                    payload,
                    snapshot.contentHash,
                    DataContributionOutboxState.pending.rawValue,
                    nowValue,
                    nowValue,
                ]
            )
        }
    }

    func dueTask(accountID: Int64, now: Date = Date()) async throws -> DataContributionOutboxTask? {
        try validateScope(accountID: accountID)
        let accountKey = String(accountID)
        let nowValue = RecommendationSnapshotJSON.string(from: now)
        return try await database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM data_contribution_outbox
                    WHERE account_id = ?
                      AND state IN (?, ?)
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                    LIMIT 1
                    """,
                arguments: [
                    accountKey,
                    DataContributionOutboxState.pending.rawValue,
                    DataContributionOutboxState.retryWait.rawValue,
                    nowValue,
                ]
            ) else { return nil }
            return try Self.task(from: row)
        }
    }

    @discardableResult
    func markRetry(
        taskID: String,
        accountID: Int64,
        attemptCount: Int,
        nextAttemptAt: Date,
        now: Date = Date()
    ) async throws -> Bool {
        try validateScope(accountID: accountID)
        return try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE data_contribution_outbox
                    SET state = ?, attempt_count = ?, next_attempt_at = ?, updated_at = ?
                    WHERE id = ? AND account_id = ?
                    """,
                arguments: [
                    DataContributionOutboxState.retryWait.rawValue,
                    max(0, attemptCount),
                    RecommendationSnapshotJSON.string(from: nextAttemptAt),
                    RecommendationSnapshotJSON.string(from: now),
                    taskID,
                    String(accountID),
                ]
            )
            // 单槽 Outbox 允许新快照覆盖旧任务；调用者必须知道旧 task ID 是否仍然有效，
            // 才能决定是否为它安排重试定时器。
            return db.changesCount == 1
        }
    }

    /// 只删除仍与成功请求相同的任务；同步期间若新快照覆盖旧任务，不误删新任务。
    func remove(taskID: String, accountID: Int64) async throws {
        try validateScope(accountID: accountID)
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM data_contribution_outbox WHERE id = ? AND account_id = ?",
                arguments: [taskID, String(accountID)]
            )
        }
    }

    private func validateScope(accountID: Int64) throws {
        guard database.currentUserId == accountID else {
            throw DataContributionRepositoryError.accountScopeChanged
        }
    }

    private static func task(from row: Row) throws -> DataContributionOutboxTask {
        guard let state = DataContributionOutboxState(rawValue: row["state"]),
              let accountID = Int64(row["account_id"] as String) else {
            throw DataContributionRepositoryError.invalidStoredTask
        }
        let nextValue: String? = row["next_attempt_at"]
        let nextDate = nextValue.flatMap { ISO8601DateFormatter.githubDate(from: $0) }
        return DataContributionOutboxTask(
            id: row["id"],
            accountID: accountID,
            participantID: row["participant_id"],
            schemaVersion: row["schema_version"],
            payload: row["payload"],
            contentHash: row["content_hash"],
            state: state,
            attemptCount: row["attempt_count"],
            nextAttemptAt: nextDate
        )
    }
}
