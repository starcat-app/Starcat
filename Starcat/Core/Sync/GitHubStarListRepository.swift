//
//  GitHubStarListRepository.swift
//  Starcat
//
//  GitHub Stars List 本地缓存的 GRDB 实现。
//
//  关键约束：
//  - 远端同步走快照覆盖，确保删除 / 重命名 / membership 变化都能被收敛。
//  - 本地颜色是 Starcat 私有字段，远端快照不能覆盖用户已经选择的颜色。
//  - membership 用本地 repo numeric id；远端 GraphQL repository id 只在 mutation 时临时查询。
//

import Foundation
import GRDB

struct GRDBGitHubStarListRepository: GitHubStarListRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 同步写入

    func replaceRemoteSnapshot(
        lists: [GitHubStarListRemoteRecord],
        memberships: [GitHubStarListRemoteMembership],
        syncedAt: Date
    ) async throws {
        let syncedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)
        try await database.writer.write { db in
            let existingRows = try GitHubStarList.fetchAll(db)
            let existingColors = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.id, $0.colorHex) })
            let remoteIDs = Set(lists.map(\.id))

            for remote in lists {
                var record = GitHubStarList(
                    id: remote.id,
                    name: remote.name,
                    description: remote.description,
                    isPrivate: remote.isPrivate,
                    colorHex: existingColors[remote.id] ?? GitHubStarListColor.defaultColorHex(forListID: remote.id),
                    position: remote.position,
                    createdAt: remote.createdAt,
                    updatedAt: remote.updatedAt,
                    syncedAt: syncedAtISO
                )
                try record.save(db)
            }

            if !remoteIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: remoteIDs.count).joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM github_star_lists WHERE id NOT IN (\(placeholders))",
                    arguments: StatementArguments(Array(remoteIDs).sorted())
                )
            } else {
                try db.execute(sql: "DELETE FROM github_star_lists")
            }

            // list 快照完整时，membership 也应完整重建。先删后插能正确收敛远端移出关系。
            try db.execute(sql: "DELETE FROM repo_github_star_lists")
            for membership in memberships {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO repo_github_star_lists (repo_id, list_id)
                    SELECT r.id, ?
                    FROM repos r
                    WHERE LOWER(r.full_name) = LOWER(?) AND r.is_starred = 1
                    """,
                    arguments: [membership.listId, membership.repoFullName]
                )
            }
        }
    }

    func upsertList(_ remote: GitHubStarListRemoteRecord, colorHex: String?, syncedAt: Date) async throws {
        let syncedAtISO = ISO8601DateFormatter.shared.string(from: syncedAt)
        try await database.writer.write { db in
            let existing = try GitHubStarList.fetchOne(db, key: remote.id)
            var record = GitHubStarList(
                id: remote.id,
                name: remote.name,
                description: remote.description,
                isPrivate: remote.isPrivate,
                colorHex: colorHex ?? existing?.colorHex ?? GitHubStarListColor.defaultColorHex(forListID: remote.id),
                position: remote.position,
                createdAt: remote.createdAt,
                updatedAt: remote.updatedAt,
                syncedAt: syncedAtISO
            )
            try record.save(db)
        }
    }

    func deleteList(id: String) async throws {
        try await database.writer.write { db in
            _ = try GitHubStarList.deleteOne(db, key: id)
        }
    }

    func setListIds(forRepo repoId: Int64, listIds: [String]) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM repo_github_star_lists WHERE repo_id = ?",
                arguments: [repoId]
            )
            for listId in Array(Set(listIds)).sorted() {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO repo_github_star_lists (repo_id, list_id) VALUES (?, ?)",
                    arguments: [repoId, listId]
                )
            }
        }
    }

    // MARK: - 查询

    func fetchAllLists() async throws -> [GitHubStarList] {
        try await database.writer.read { db in
            try GitHubStarList.fetchAll(db, sql: """
                SELECT * FROM github_star_lists
                ORDER BY position ASC, name COLLATE NOCASE ASC
                """)
        }
    }

    func findList(id: String) async throws -> GitHubStarList? {
        try await database.writer.read { db in
            try GitHubStarList.fetchOne(db, key: id)
        }
    }

    func listIds(forRepo repoId: Int64) async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT list_id FROM repo_github_star_lists WHERE repo_id = ? ORDER BY list_id ASC",
                arguments: [repoId]
            )
        }
    }

    func repoCountsByList() async throws -> [String: Int] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rgl.list_id AS list_id, COUNT(*) AS cnt
                FROM repo_github_star_lists rgl
                JOIN repos r ON r.id = rgl.repo_id
                WHERE r.is_starred = 1
                GROUP BY rgl.list_id
                """)
            var result: [String: Int] = [:]
            for row in rows {
                let listId: String = row["list_id"]
                let count: Int = row["cnt"]
                result[listId] = count
            }
            return result
        }
    }

    func ungroupedRepoCount() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM repos r
                WHERE r.is_starred = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM repo_github_star_lists rgl
                    WHERE rgl.repo_id = r.id
                  )
                """) ?? 0
        }
    }

    func fetchAllListAssignments() async throws -> [Int64: [GitHubStarList]] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.*, rgl.repo_id AS repo_id_alias
                FROM repo_github_star_lists rgl
                JOIN github_star_lists l ON l.id = rgl.list_id
                JOIN repos r ON r.id = rgl.repo_id
                WHERE r.is_starred = 1
                ORDER BY rgl.repo_id, l.position ASC, l.name COLLATE NOCASE ASC
                """)
            var result: [Int64: [GitHubStarList]] = [:]
            for row in rows {
                let repoId: Int64 = row["repo_id_alias"]
                let list = try GitHubStarList(row: row)
                result[repoId, default: []].append(list)
            }
            return result
        }
    }

    // MARK: - Starcat AI 分组规则

    func upsertAIRule(_ rule: GitHubStarListAIRule) async throws {
        try await database.writer.write { db in
            try rule.save(db)
        }
    }

    func findAIRule(listId: String) async throws -> GitHubStarListAIRule? {
        try await database.writer.read { db in
            try GitHubStarListAIRule.fetchOne(db, key: listId)
        }
    }

    func fetchAllAIRules() async throws -> [GitHubStarListAIRule] {
        try await database.writer.read { db in
            try GitHubStarListAIRule.fetchAll(
                db,
                sql: "SELECT * FROM github_star_list_ai_rules ORDER BY list_id ASC"
            )
        }
    }

    // MARK: - Starcat AI 自动忽略

    func fetchAIAutoIgnoredRepos() async throws -> [GitHubStarListAIAutoIgnoredRepo] {
        try await database.writer.read { db in
            try GitHubStarListAIAutoIgnoredRepo.fetchAll(db, sql: """
                SELECT ignored.*
                FROM github_star_list_ai_auto_ignored_repos ignored
                JOIN repos r ON r.id = ignored.repo_id
                WHERE r.is_starred = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM repo_github_star_lists membership
                    WHERE membership.repo_id = ignored.repo_id
                  )
                ORDER BY ignored.updated_at ASC, ignored.repo_id ASC
                """)
        }
    }

    func upsertAIAutoIgnoredRepo(_ record: GitHubStarListAIAutoIgnoredRepo) async throws {
        try await database.writer.write { db in
            try record.save(db)
        }
    }

    func deleteAIAutoIgnoredRepo(repoId: Int64) async throws {
        try await database.writer.write { db in
            _ = try GitHubStarListAIAutoIgnoredRepo.deleteOne(db, key: repoId)
        }
    }
}
