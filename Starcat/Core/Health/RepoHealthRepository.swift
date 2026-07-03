//
//  RepoHealthRepository.swift
//  Starcat
//
//  Repo Health 缓存仓库。
//
//  职责边界：
//  - 只负责 repo_health_snapshots 的读写和 stale 候选查询。
//  - 不做评分、不发网络、不读取 OpenSSF / Release 业务仓库。
//

import Foundation
import GRDB

protocol RepoHealthRepositoryProtocol: Sendable {
    func snapshot(for repoId: Int64) async throws -> RepoHealthSnapshot?
    func snapshots(for repoIds: [Int64]) async throws -> [Int64: RepoHealthSnapshot]
    func upsert(_ snapshot: RepoHealthSnapshot) async throws
    func staleRefreshCandidateRepos(now: Date, limit: Int) async throws -> [Repo]
    func missingSnapshotCandidateRepos(limit: Int) async throws -> [Repo]
    func coverageSummary() async throws -> RepoHealthCoverageSummary
}

struct RepoHealthCoverageSummary: Equatable, Sendable {
    let candidateTotal: Int
    let snapshotTotal: Int

    var isAllCovered: Bool {
        candidateTotal > 0 && snapshotTotal >= candidateTotal
    }
}

struct GRDBRepoHealthRepository: RepoHealthRepositoryProtocol, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func snapshot(for repoId: Int64) async throws -> RepoHealthSnapshot? {
        try await database.writer.read { db in
            try RepoHealthSnapshot.fetchOne(db, key: repoId)
        }
    }

    func snapshots(for repoIds: [Int64]) async throws -> [Int64: RepoHealthSnapshot] {
        guard !repoIds.isEmpty else { return [:] }
        return try await database.writer.read { db in
            let rows = try RepoHealthSnapshot
                .filter(repoIds.contains(Column("repo_id")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.repoId, $0) })
        }
    }

    func upsert(_ snapshot: RepoHealthSnapshot) async throws {
        try await database.writer.write { db in
            var mutable = snapshot
            try mutable.save(db)
        }
    }

    func staleRefreshCandidateRepos(now: Date, limit: Int) async throws -> [Repo] {
        let nowString = ISO8601DateFormatter.shared.string(from: now)
        return try await database.writer.read { db in
            try Repo.fetchAll(
                db,
                sql: """
                SELECT repos.*
                FROM repos
                LEFT JOIN repo_health_snapshots h ON h.repo_id = repos.id
                LEFT JOIN repo_notes rn ON rn.repo_id = repos.id
                WHERE (repos.is_starred = 1 OR rn.library_state = 'in_library')
                  AND (h.repo_id IS NULL OR h.stale_after <= ?)
                ORDER BY
                    CASE WHEN repos.is_starred = 1 THEN 0 ELSE 1 END,
                    COALESCE(repos.starred_at, rn.library_updated_at, repos.cached_at) DESC
                LIMIT ?
                """,
                arguments: [nowString, limit]
            )
        }
    }

    func missingSnapshotCandidateRepos(limit: Int) async throws -> [Repo] {
        let safeLimit = max(1, limit)
        return try await database.writer.read { db in
            try Repo.fetchAll(
                db,
                sql: """
                SELECT repos.*
                FROM repos
                LEFT JOIN repo_health_snapshots h ON h.repo_id = repos.id
                LEFT JOIN repo_notes rn ON rn.repo_id = repos.id
                WHERE (repos.is_starred = 1 OR rn.library_state = 'in_library')
                  AND h.repo_id IS NULL
                ORDER BY
                    CASE WHEN repos.is_starred = 1 THEN 0 ELSE 1 END,
                    COALESCE(repos.starred_at, rn.library_updated_at, repos.cached_at) DESC
                LIMIT ?
                """,
                arguments: [safeLimit]
            )
        }
    }

    func coverageSummary() async throws -> RepoHealthCoverageSummary {
        try await database.writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    COUNT(*) AS candidate_total,
                    COALESCE(SUM(CASE WHEN h.repo_id IS NULL THEN 0 ELSE 1 END), 0) AS snapshot_total
                FROM repos
                LEFT JOIN repo_health_snapshots h ON h.repo_id = repos.id
                LEFT JOIN repo_notes rn ON rn.repo_id = repos.id
                WHERE repos.is_starred = 1 OR rn.library_state = 'in_library'
                """
            )

            return RepoHealthCoverageSummary(
                candidateTotal: row?["candidate_total"] ?? 0,
                snapshotTotal: row?["snapshot_total"] ?? 0
            )
        }
    }
}
