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
                    colorHex: existingColors[remote.id] ?? GitHubStarList.noColorHex,
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

            // list 快照完整时，远端 membership 也应完整重建。覆盖表独立保留，不能在这里清空。
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

            // 远端刷新可能已经包含之前的本地期望。只删除已经收敛的差异；仍不一致的行
            // 继续覆盖远端快照，保证授权尚未恢复时刷新不会让本地分组闪回。
            try db.execute(sql: """
                DELETE FROM repo_github_star_list_overrides
                WHERE (
                    repo_github_star_list_overrides.desired_present = 1
                    AND EXISTS (
                        SELECT 1 FROM repo_github_star_lists remote
                        WHERE remote.repo_id = repo_github_star_list_overrides.repo_id
                          AND remote.list_id = repo_github_star_list_overrides.list_id
                    )
                ) OR (
                    repo_github_star_list_overrides.desired_present = 0
                    AND NOT EXISTS (
                        SELECT 1 FROM repo_github_star_lists remote
                        WHERE remote.repo_id = repo_github_star_list_overrides.repo_id
                          AND remote.list_id = repo_github_star_list_overrides.list_id
                    )
                )
                """)
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
                colorHex: colorHex ?? existing?.colorHex ?? GitHubStarList.noColorHex,
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
            // GitHub mutation 已确认完整目标集合，所有本地差异都已经收敛。
            try db.execute(
                sql: "DELETE FROM repo_github_star_list_overrides WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
    }

    func setLocalListIds(
        forRepo repoId: Int64,
        listIds: [String],
        failureReason: String
    ) async throws {
        let desiredListIDs = Set(listIds)
        let updatedAt = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            let remoteListIDs = Set(try String.fetchAll(
                db,
                sql: "SELECT list_id FROM repo_github_star_lists WHERE repo_id = ?",
                arguments: [repoId]
            ))
            try db.execute(
                sql: "DELETE FROM repo_github_star_list_overrides WHERE repo_id = ?",
                arguments: [repoId]
            )

            let additions = desiredListIDs.subtracting(remoteListIDs)
            let removals = remoteListIDs.subtracting(desiredListIDs)
            for listID in additions.sorted() {
                let record = GitHubStarListLocalOverride(
                    repoId: repoId,
                    listId: listID,
                    desiredPresent: true,
                    syncState: .pendingAuthorization,
                    failureReason: failureReason,
                    updatedAt: updatedAt
                )
                try record.insert(db)
            }
            for listID in removals.sorted() {
                let record = GitHubStarListLocalOverride(
                    repoId: repoId,
                    listId: listID,
                    desiredPresent: false,
                    syncState: .pendingAuthorization,
                    failureReason: failureReason,
                    updatedAt: updatedAt
                )
                try record.insert(db)
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
                sql: "SELECT list_id FROM effective_repo_github_star_lists WHERE repo_id = ? ORDER BY list_id ASC",
                arguments: [repoId]
            )
        }
    }

    func remoteListIds(forRepo repoId: Int64) async throws -> [String] {
        try await database.writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT list_id FROM repo_github_star_lists WHERE repo_id = ? ORDER BY list_id ASC",
                arguments: [repoId]
            )
        }
    }

    func hasLocalListOverrides(forRepo repoId: Int64) async throws -> Bool {
        try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM repo_github_star_list_overrides WHERE repo_id = ? LIMIT 1",
                arguments: [repoId]
            ) != nil
        }
    }

    func fetchPendingLocalMembershipSyncs() async throws -> [GitHubStarListPendingMembershipSync] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.*, effective.list_id AS effective_list_id
                FROM repos r
                JOIN (
                    SELECT DISTINCT repo_id
                    FROM repo_github_star_list_overrides
                    WHERE sync_state = ?
                ) pending ON pending.repo_id = r.id
                LEFT JOIN effective_repo_github_star_lists effective ON effective.repo_id = r.id
                WHERE r.is_starred = 1
                ORDER BY r.id ASC, effective.list_id ASC
                """, arguments: [GitHubStarListLocalOverrideSyncState.pendingAuthorization.rawValue])

            var reposByID: [Int64: Repo] = [:]
            var listIDsByRepo: [Int64: Set<String>] = [:]
            for row in rows {
                let repo = try Repo(row: row)
                reposByID[repo.id] = repo
                if let listID: String = row["effective_list_id"] {
                    listIDsByRepo[repo.id, default: []].insert(listID)
                }
            }
            return reposByID.values.sorted { $0.id < $1.id }.map { repo in
                GitHubStarListPendingMembershipSync(
                    repo: repo,
                    desiredListIDs: listIDsByRepo[repo.id] ?? []
                )
            }
        }
    }

    func repoCountsByList() async throws -> [String: Int] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rgl.list_id AS list_id, COUNT(*) AS cnt
                FROM effective_repo_github_star_lists rgl
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
                    SELECT 1 FROM effective_repo_github_star_lists rgl
                    WHERE rgl.repo_id = r.id
                  )
                """) ?? 0
        }
    }

    func fetchAllListAssignments() async throws -> [Int64: [GitHubStarList]] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.*, rgl.repo_id AS repo_id_alias
                FROM effective_repo_github_star_lists rgl
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
                    SELECT 1 FROM effective_repo_github_star_lists membership
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
