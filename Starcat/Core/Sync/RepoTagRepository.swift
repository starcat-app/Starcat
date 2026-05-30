//
//  RepoTagRepository.swift
//  Starcat
//
//  Repo ↔ Tag 关联 Repository（GRDB 实现）。
//
//  ⚠️ 命名约定（与 D-01 一致）：
//  - 内部 struct 名 `GRDBRepoTagRepository`
//  - 协议 `RepoTagRepositoryProtocol`（见同目录）
//
//  schema 对照（DatabaseMigrationsV1.createRepoTags）：
//    repo_id INTEGER → repos.id ON DELETE CASCADE
//    tag_id  TEXT    → tags.id  ON DELETE CASCADE
//    created_at TEXT NOT NULL
//    PRIMARY KEY (repo_id, tag_id)  ← 复合 PK 保证幂等
//
//  幂等性策略：
//  - INSERT OR IGNORE 处理 (repo, tag) 已存在的情形，多次 add 同一对不抛错
//  - removeTag 通过 DELETE WHERE 匹配，不存在不抛错
//  - setTags 用 delete-then-insert，事务内保证原子
//

import Foundation
import GRDB

struct GRDBRepoTagRepository {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    // MARK: - 单 repo

    func addTag(repoId: Int64, tagId: String) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at) VALUES (?, ?, ?)",
                arguments: [repoId, tagId, now]
            )
        }
    }

    func removeTag(repoId: Int64, tagId: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM repo_tags WHERE repo_id = ? AND tag_id = ?",
                arguments: [repoId, tagId]
            )
        }
    }

    /// 替换式更新（适合 picker 一次提交）。
    /// 实现：单事务内 delete + batch insert，
    /// 保证 UI 关掉 picker 时数据库状态与 picker 选中态完全一致。
    func setTags(repoId: Int64, tagIds: [String]) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM repo_tags WHERE repo_id = ?",
                arguments: [repoId]
            )
            for tagId in tagIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at) VALUES (?, ?, ?)",
                    arguments: [repoId, tagId, now]
                )
            }
        }
    }

    // MARK: - 批量

    func batchAddTag(repoIds: [Int64], tagId: String) async throws {
        guard !repoIds.isEmpty else { return }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await writer.write { db in
            for repoId in repoIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at) VALUES (?, ?, ?)",
                    arguments: [repoId, tagId, now]
                )
            }
        }
    }

    // MARK: - 查询

    func fetchTagIds(forRepo repoId: Int64) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT tag_id FROM repo_tags WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
    }

    /// JOIN tags 取完整标签，按 sort_order asc → name asc 排序。
    func fetchTags(forRepo repoId: Int64) async throws -> [Tag] {
        try await writer.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT t.* FROM tags t
                JOIN repo_tags rt ON rt.tag_id = t.id
                WHERE rt.repo_id = ?
                ORDER BY t.sort_order ASC, t.name ASC
                """, arguments: [repoId])
        }
    }

    /// JOIN repos 取某标签下的 starred repo，按 starred_at desc。
    /// 已取消 star 的 repo（is_starred=0）不返回，避免 Tags 视图泄漏脏数据。
    func fetchRepos(forTag tagId: String) async throws -> [Repo] {
        try await writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                JOIN repo_tags rt ON rt.repo_id = r.id
                WHERE rt.tag_id = ? AND r.is_starred = 1
                ORDER BY r.starred_at DESC
                """, arguments: [tagId])
        }
    }

    func repoCount(forTag tagId: String) async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM repo_tags rt
                JOIN repos r ON r.id = rt.repo_id
                WHERE rt.tag_id = ? AND r.is_starred = 1
                """, arguments: [tagId]) ?? 0
        }
    }

    /// 一次 group by 拉全部标签的 starred-repo count。
    /// Sidebar Tags 渲染时只调一次，比 N 次 `repoCount` 高效。
    func repoCountsByTag() async throws -> [String: Int] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rt.tag_id AS tag_id, COUNT(*) AS cnt
                FROM repo_tags rt
                JOIN repos r ON r.id = rt.repo_id
                WHERE r.is_starred = 1
                GROUP BY rt.tag_id
                """)
            var result: [String: Int] = [:]
            for row in rows {
                let tagId: String = row["tag_id"]
                let count: Int = row["cnt"]
                result[tagId] = count
            }
            return result
        }
    }
}
