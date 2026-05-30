//
//  RepoNoteRepository.swift
//  Starcat
//
//  RepoNote 持久化 Repository（GRDB 实现，承载笔记 + 状态）。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct `GRDBRepoNoteRepository`
//  - 协议 `RepoNoteRepositoryProtocol`（同目录）
//
//  schema 对照（DatabaseMigrationsV1.createRepoNotes）：
//    repo_id INTEGER PRIMARY KEY → repos.id ON DELETE CASCADE
//    content TEXT
//    status  TEXT NOT NULL DEFAULT 'unread'
//    is_ai_generated BOOLEAN NOT NULL DEFAULT 0
//    edited_at TEXT
//
//  幂等性 / 自动创建逻辑：
//  - `updateContent` / `updateStatus` 在 repo_notes 行缺失时，会先插入一行
//    （另一字段保持默认/nil），再 UPDATE 真正要改的字段。
//  - 这样 UI 端不必先 `find` 再决定 insert/update，调用更顺。
//

import Foundation
import GRDB

struct GRDBRepoNoteRepository {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - 查询

    func find(repoId: Int64) async throws -> RepoNote? {
        try await writer.read { db in
            try RepoNote.fetchOne(db, key: repoId)
        }
    }

    func fetchStatusMap(repoIds: [Int64]) async throws -> [Int64: RepoStatus] {
        guard !repoIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: repoIds.count).joined(separator: ",")
        let args = repoIds.map { $0 as DatabaseValueConvertible }
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT repo_id, status FROM repo_notes WHERE repo_id IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
            var map: [Int64: RepoStatus] = [:]
            for row in rows {
                let id: Int64 = row["repo_id"]
                let raw: String = row["status"]
                if let status = RepoStatus(rawValue: raw) {
                    map[id] = status
                }
            }
            return map
        }
    }

    func fetchRepos(byStatus status: RepoStatus) async throws -> [Repo] {
        try await writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                JOIN repo_notes n ON n.repo_id = r.id
                WHERE n.status = ? AND r.is_starred = 1
                ORDER BY r.starred_at DESC
                """, arguments: [status.rawValue])
        }
    }

    func statusCounts() async throws -> [RepoStatus: Int] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.status AS status, COUNT(*) AS cnt
                FROM repo_notes n
                JOIN repos r ON r.id = n.repo_id
                WHERE r.is_starred = 1
                GROUP BY n.status
                """)
            var result: [RepoStatus: Int] = [:]
            for row in rows {
                let raw: String = row["status"]
                let count: Int = row["cnt"]
                if let status = RepoStatus(rawValue: raw) {
                    result[status] = count
                }
            }
            return result
        }
    }

    // MARK: - 写入

    func upsert(_ note: RepoNote) async throws {
        try await writer.write { db in
            var copy = note
            try copy.upsert(db)
        }
    }

    /// 仅更新 content；行不存在则创建一行（status="unread"，is_ai_generated=0）。
    /// content 传 nil 表示清空。editedAt 自动设为 now。
    func updateContent(repoId: Int64, content: String?) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            // 用 UPSERT 语义：先 INSERT（如不存在），ON CONFLICT 时 UPDATE content + edited_at
            try db.execute(
                sql: """
                INSERT INTO repo_notes (repo_id, content, status, is_ai_generated, edited_at)
                VALUES (?, ?, 'unread', 0, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    content = excluded.content,
                    edited_at = excluded.edited_at
                """,
                arguments: [repoId, content, nowISO]
            )
        }
    }

    /// 仅更新 status；行不存在则创建一行（content=NULL）。editedAt 自动设为 now。
    func updateStatus(repoId: Int64, status: RepoStatus) async throws {
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (repo_id, content, status, is_ai_generated, edited_at)
                VALUES (?, NULL, ?, 0, ?)
                ON CONFLICT(repo_id) DO UPDATE SET
                    status = excluded.status,
                    edited_at = excluded.edited_at
                """,
                arguments: [repoId, status.rawValue, nowISO]
            )
        }
    }
}
