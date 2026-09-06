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

struct GRDBRepoTagRepository: RepoTagRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 单 repo

    func addTag(repoId: Int64, tagId: String) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at) VALUES (?, ?, ?)",
                arguments: [repoId, tagId, now]
            )
        }
        postTagsDidChange(repoId: repoId)
    }

    func removeTag(repoId: Int64, tagId: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM repo_tags WHERE repo_id = ? AND tag_id = ?",
                arguments: [repoId, tagId]
            )
        }
        postTagsDidChange(repoId: repoId)
    }

    /// 替换式更新（适合 picker 一次提交）。
    /// 实现：单事务内 delete + batch insert，
    /// 保证 UI 关掉 picker 时数据库状态与 picker 选中态完全一致。
    func setTags(repoId: Int64, tagIds: [String]) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
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
        postTagsDidChange(repoId: repoId)
    }

    // MARK: - 批量

    func batchAddTag(repoIds: [Int64], tagId: String) async throws {
        guard !repoIds.isEmpty else { return }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            for repoId in repoIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO repo_tags (repo_id, tag_id, created_at) VALUES (?, ?, ?)",
                    arguments: [repoId, tagId, now]
                )
            }
        }
        for repoId in repoIds {
            postTagsDidChange(repoId: repoId)
        }
    }

    // MARK: - 查询

    func fetchTagIds(forRepo repoId: Int64) async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT tag_id FROM repo_tags WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
    }

    /// JOIN tags 取完整标签，按 sort_order asc → name asc 排序。
    func fetchTags(forRepo repoId: Int64) async throws -> [Tag] {
        try await database.writer.read { db in
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
        try await database.writer.read { db in
            try Repo.fetchAll(db, sql: """
                SELECT r.* FROM repos r
                JOIN repo_tags rt ON rt.repo_id = r.id
                WHERE rt.tag_id = ? AND r.is_starred = 1
                ORDER BY r.starred_at DESC
                """, arguments: [tagId])
        }
    }

    /// 多标签 AND 查询：返回同时拥有所有指定标签的 repo。
    func fetchRepos(forTags tagIds: Set<String>) async throws -> [Repo] {
        guard !tagIds.isEmpty else { return [] }
        return try await database.writer.read { db in
            // 使用 HAVING COUNT 确保 repo 同时拥有所有指定标签
            let tagArray = Array(tagIds)
            let placeholders = tagArray.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT r.* FROM repos r
                JOIN repo_tags rt ON rt.repo_id = r.id
                WHERE rt.tag_id IN (\(placeholders)) AND r.is_starred = 1
                GROUP BY r.id
                HAVING COUNT(DISTINCT rt.tag_id) = ?
                ORDER BY r.starred_at DESC
                """
            // 构建参数：前 N 个是 tagId，最后一个是 tagIds.count
            var arguments: [DatabaseValueConvertible] = tagArray
            arguments.append(tagArray.count)
            return try Repo.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    func repoCount(forTag tagId: String) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM repo_tags rt
                JOIN repos r ON r.id = rt.repo_id
                WHERE rt.tag_id = ? AND r.is_starred = 1
                """, arguments: [tagId]) ?? 0
        }
    }

    /// 一次性返回所有 starred repo 的标签关联。
    ///
    /// JOIN repos 仅保留 `is_starred = 1` 的 repo，避免被 unstar 但保留标签的"幽灵关联"
    /// 出现在导出文件里；外排序按 `repo_id, tag.sort_order, tag.name` 让相同 repo 的标签连续，
    /// 应用层只需顺序 append 不必再排。
    func fetchAllTagAssignments() async throws -> [Int64: [Tag]] {
        try await database.writer.read { db in
            // 选出 t.* + rt.repo_id；Tag 自己只解码 `t.*` 那部分列，repo_id 单独取。
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.*, rt.repo_id AS repo_id_alias
                FROM repo_tags rt
                JOIN tags t  ON t.id = rt.tag_id
                JOIN repos r ON r.id = rt.repo_id
                WHERE r.is_starred = 1
                ORDER BY rt.repo_id, t.sort_order ASC, t.name ASC
                """)
            var result: [Int64: [Tag]] = [:]
            for row in rows {
                let repoId: Int64 = row["repo_id_alias"]
                // GRDB 8 起 `Tag(row:)` 标记为 throws（Codable 解码失败会抛），所以必须 try。
                let tag = try Tag(row: row)
                result[repoId, default: []].append(tag)
            }
            return result
        }
    }

    /// 一次 group by 拉全部标签的 starred-repo count。
    /// Sidebar Tags 渲染时只调一次，比 N 次 `repoCount` 高效。
    func repoCountsByTag() async throws -> [String: Int] {
        try await database.writer.read { db in
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

    /// Manage 内存筛选只需要 ID；与 Starred 导出分开，保留未 Star 的知识库 / 项目关联。
    func fetchAllTagIDsByRepo() async throws -> [Int64: Set<String>] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT repo_id, tag_id FROM repo_tags")
            var result: [Int64: Set<String>] = [:]
            for row in rows {
                result[row["repo_id"] as Int64, default: []].insert(row["tag_id"] as String)
            }
            return result
        }
    }

    private func postTagsDidChange(repoId: Int64) {
        NotificationCenter.default.post(
            name: .repoTagsDidChange,
            object: nil,
            userInfo: ["repoId": repoId]
        )
    }
}
