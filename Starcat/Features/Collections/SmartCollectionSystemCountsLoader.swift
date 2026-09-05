//
//  SmartCollectionSystemCountsLoader.swift
//  Starcat
//
//  Smart Collections 系统计数的一致性数据库快照加载器。
//

import Foundation
import GRDB

/// 在一次 GRDB read transaction 内取得系统集合计数需要的全部事实。
///
/// 旧实现并发执行多次独立 read；速度取决于连接池竞争，而且同步写入发生在中途时，
/// 各卡片可能来自不同数据库时刻。这里仍复用既有 Swift 规则计算，只收敛 IO 边界。
enum SmartCollectionSystemCountsLoader {
    struct Snapshot: Sendable {
        let starredRepos: [Repo]
        let healthByRepoID: [Int64: RepoHealthSnapshot]
        let statusByRepoID: [Int64: RepoStatus]
        let libraryStateByRepoID: [Int64: LibraryState]
        let knowledgeCount: Int
        let noTagsCount: Int
    }

    static func load(database: any DatabaseManaging) async throws -> Snapshot {
        try await database.writer.read { db in
            let starredRepos = try Repo
                .filter(Column("is_starred") == true)
                .order(Column("starred_at").desc)
                .fetchAll(db)

            let healthSnapshots = try RepoHealthSnapshot.fetchAll(
                db,
                sql: """
                    SELECT h.*
                    FROM repo_health_snapshots AS h
                    JOIN repos AS r ON r.id = h.repo_id
                    WHERE r.is_starred = 1
                    """
            )
            let healthByRepoID = Dictionary(
                uniqueKeysWithValues: healthSnapshots.map { ($0.repoId, $0) }
            )

            let noteRows = try Row.fetchAll(
                db,
                sql: "SELECT repo_id, status, library_state FROM repo_notes"
            )
            var statusByRepoID: [Int64: RepoStatus] = [:]
            var libraryStateByRepoID: [Int64: LibraryState] = [:]
            statusByRepoID.reserveCapacity(noteRows.count)
            libraryStateByRepoID.reserveCapacity(noteRows.count)
            for row in noteRows {
                let repoID: Int64 = row["repo_id"]
                let rawStatus: String = row["status"]
                let rawLibraryState: String? = row["library_state"]
                statusByRepoID[repoID] = RepoStatus.parse(rawStatus)
                libraryStateByRepoID[repoID] = LibraryState.parse(rawLibraryState)
            }

            let knowledgeCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM repos AS r
                    JOIN repo_notes AS n ON n.repo_id = r.id
                    WHERE n.library_state = 'in_library'
                    """
            ) ?? 0
            let noTagsCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM repos AS r
                    WHERE r.is_starred = 1
                      AND NOT EXISTS (
                          SELECT 1 FROM repo_tags AS rt WHERE rt.repo_id = r.id
                      )
                    """
            ) ?? 0

            return Snapshot(
                starredRepos: starredRepos,
                healthByRepoID: healthByRepoID,
                statusByRepoID: statusByRepoID,
                libraryStateByRepoID: libraryStateByRepoID,
                knowledgeCount: knowledgeCount,
                noTagsCount: noTagsCount
            )
        }
    }
}
