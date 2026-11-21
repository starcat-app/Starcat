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

    /// 从快照求值全部系统集合计数。
    ///
    /// 纯 CPU 循环（按 kind 过滤全量 starred repos + topics JSON 解码 + ISO8601 日期解析）
    /// 之前落在视图的 MainActor，大库时是智能集合首页进入卡顿的主因之一。
    /// 快照是 Sendable 值，`@concurrent` 让求值整体离开主线程执行，
    /// 结果回到调用方（MainActor）后再统一发布。
    @concurrent
    static func counts(from snapshot: Snapshot, now: Date = Date()) async -> [SmartCollectionKind: Int] {
        let repos = snapshot.starredRepos
        var nextCounts: [SmartCollectionKind: Int] = [:]
        nextCounts.reserveCapacity(SmartCollectionKind.allCases.count)
        for kind in SmartCollectionKind.allCases {
            switch kind {
            case .library:
                nextCounts[kind] = snapshot.knowledgeCount
            case .outsideLibraryStars:
                nextCounts[kind] = repos.filter { repo in
                    (snapshot.libraryStateByRepoID[repo.id] ?? .outsideLibrary) != .inLibrary
                }.count
            case .noTags:
                nextCounts[kind] = snapshot.noTagsCount
            case .using:
                nextCounts[kind] = repos.filter {
                    snapshot.statusByRepoID[$0.id] == .using
                }.count
            case .needsReview, .unmaintained, .highValue, .recentlyActive:
                nextCounts[kind] = repos.filter { repo in
                    HomeViewModel.matchesSmartCollection(
                        repo: repo,
                        health: snapshot.healthByRepoID[repo.id],
                        status: snapshot.statusByRepoID[repo.id],
                        kind: kind,
                        now: now
                    )
                }.count
            }
        }
        return nextCounts
    }
}
