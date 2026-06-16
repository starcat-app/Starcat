//
//  OpenSSFScoreRepository.swift
//  Starcat
//
//  OpenSSF Scorecard GRDB 仓库。
//
//  职责边界：
//  - 本层只做缓存读写与 TTL 候选查询，不发网络。
//  - TTL 判断统一基于 fetched_at（最近一次尝试时间），失败态也进入冷却期。
//

import Foundation
import GRDB

protocol OpenSSFScoreRepositoryProtocol: Sendable {
    func record(for repoId: Int64) async throws -> OpenSSFScoreRecord?
    func records(for repoIds: [Int64]) async throws -> [Int64: OpenSSFScoreRecord]
    func upsert(_ record: OpenSSFScoreRecord) async throws
    func staleStarredRepos(now: Date, limit: Int) async throws -> [Repo]
}

struct GRDBOpenSSFScoreRepository: OpenSSFScoreRepositoryProtocol, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func record(for repoId: Int64) async throws -> OpenSSFScoreRecord? {
        try await database.writer.read { db in
            try OpenSSFScoreRecord.fetchOne(db, key: repoId)
        }
    }

    func records(for repoIds: [Int64]) async throws -> [Int64: OpenSSFScoreRecord] {
        guard !repoIds.isEmpty else { return [:] }
        return try await database.writer.read { db in
            let records = try OpenSSFScoreRecord
                .filter(repoIds.contains(Column("repo_id")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.repoId, $0) })
        }
    }

    func upsert(_ record: OpenSSFScoreRecord) async throws {
        try await database.writer.write { db in
            var mutable = record
            try mutable.save(db)
        }
    }

    func staleStarredRepos(now: Date, limit: Int) async throws -> [Repo] {
        let successCutoff = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.successTTL))
        let notIndexedCutoff = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.notIndexedTTL))
        let failureCutoff = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.failureTTL))

        return try await database.writer.read { db in
            try Repo.fetchAll(
                db,
                sql: """
                SELECT repos.*
                FROM repos
                LEFT JOIN open_ssf_scores s ON s.repo_id = repos.id
                WHERE repos.is_starred = 1
                  AND (
                    s.repo_id IS NULL
                    OR (s.fetch_status = 'success' AND s.fetched_at <= ?)
                    OR (s.fetch_status = 'notIndexed' AND s.fetched_at <= ?)
                    OR (s.fetch_status IN ('networkError', 'parseError') AND s.fetched_at <= ?)
                  )
                ORDER BY repos.starred_at DESC
                LIMIT ?
                """,
                arguments: [successCutoff, notIndexedCutoff, failureCutoff, limit]
            )
        }
    }
}

enum OpenSSFScoreRefreshPolicy {
    static let successTTL: TimeInterval = 7 * 24 * 60 * 60
    static let notIndexedTTL: TimeInterval = 30 * 24 * 60 * 60
    static let failureTTL: TimeInterval = 24 * 60 * 60

    static func shouldRefresh(_ record: OpenSSFScoreRecord?, now: Date = Date(), force: Bool = false) -> Bool {
        guard !force else { return true }
        guard let record, let fetched = record.fetchedDate else { return true }

        let ttl: TimeInterval = switch record.fetchStatus {
        case .success: successTTL
        case .notIndexed: notIndexedTTL
        case .networkError, .parseError: failureTTL
        }
        return now.timeIntervalSince(fetched) >= ttl
    }
}
