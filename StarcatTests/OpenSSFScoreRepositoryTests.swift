//
//  OpenSSFScoreRepositoryTests.swift
//  StarcatTests
//
//  覆盖 OpenSSF Scorecard 本地缓存表的 GRDB 读写和 TTL 候选查询。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("OpenSSF Scorecard Repository")
struct OpenSSFScoreRepositoryTests {
    private func makeRepository() throws -> (GRDBOpenSSFScoreRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBOpenSSFScoreRepository(database: db), db)
    }

    private func seedRepo(
        _ db: any DatabaseManaging,
        id: Int64,
        fullName: String,
        isStarred: Bool = true,
        starredAt: String = "2026-06-16T00:00:00Z"
    ) async throws {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, is_starred, starred_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    parts[0],
                    parts[1],
                    fullName,
                    "https://github.com/\(fullName)",
                    isStarred,
                    starredAt
                ]
            )
        }
    }

    @Test("upsert + record: 成功记录完整往返")
    func upsertAndRecordRoundTrip() async throws {
        let (repository, db) = try makeRepository()
        try await seedRepo(db, id: 1, fullName: "ossf/scorecard")

        let raw = Data(#"{"score":8.4,"checks":[]}"#.utf8)
        let payload = OpenSSFScorePayload(date: "2026-06-16", score: 8.4, checks: [])
        let record = OpenSSFScoreRecord.success(
            repoId: 1,
            payload: payload,
            rawData: raw,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await repository.upsert(record)
        let stored = try #require(try await repository.record(for: 1))

        #expect(stored.repoId == 1)
        #expect(stored.fetchStatus == .success)
        #expect(stored.aggregateScore == 8.4)
        #expect(stored.checksJSON == raw)
        #expect(stored.badgeData?.formattedScore == "8.4")
    }

    @Test("records(for:) 批量返回 repoId 字典")
    func recordsReturnsDictionary() async throws {
        let (repository, db) = try makeRepository()
        try await seedRepo(db, id: 1, fullName: "a/one")
        try await seedRepo(db, id: 2, fullName: "a/two")

        try await repository.upsert(.failure(
            repoId: 1,
            status: .notIndexed,
            message: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        try await repository.upsert(.failure(
            repoId: 2,
            status: .networkError,
            message: "timeout",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        let records = try await repository.records(for: [1, 2, 3])

        #expect(records.count == 2)
        #expect(records[1]?.fetchStatus == .notIndexed)
        #expect(records[2]?.lastError == "timeout")
        #expect(records[3] == nil)
    }

    @Test("staleStarredRepos: 只返回 starred 且已过 TTL 或无缓存的 repo")
    func staleStarredReposRespectsTTLAndStarredFlag() async throws {
        let (repository, db) = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = now.addingTimeInterval(-60)
        let staleSuccess = now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.successTTL - 60)
        let staleFailure = now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.failureTTL - 60)

        try await seedRepo(db, id: 1, fullName: "a/fresh", starredAt: "2026-06-16T04:00:00Z")
        try await seedRepo(db, id: 2, fullName: "a/stale-success", starredAt: "2026-06-16T03:00:00Z")
        try await seedRepo(db, id: 3, fullName: "a/stale-failure", starredAt: "2026-06-16T02:00:00Z")
        try await seedRepo(db, id: 4, fullName: "a/missing-cache", starredAt: "2026-06-16T01:00:00Z")
        try await seedRepo(db, id: 5, fullName: "a/unstarred", isStarred: false, starredAt: "2026-06-16T05:00:00Z")

        try await repository.upsert(.success(
            repoId: 1,
            payload: OpenSSFScorePayload(date: nil, score: 9.0, checks: []),
            rawData: Data(#"{"score":9.0}"#.utf8),
            fetchedAt: fresh
        ))
        try await repository.upsert(.success(
            repoId: 2,
            payload: OpenSSFScorePayload(date: nil, score: 8.0, checks: []),
            rawData: Data(#"{"score":8.0}"#.utf8),
            fetchedAt: staleSuccess
        ))
        try await repository.upsert(.failure(
            repoId: 3,
            status: .networkError,
            message: "timeout",
            fetchedAt: staleFailure
        ))
        try await repository.upsert(.failure(
            repoId: 5,
            status: .networkError,
            message: "timeout",
            fetchedAt: staleFailure
        ))

        let repos = try await repository.staleStarredRepos(now: now, limit: 10)
        let ids = repos.map(\.id)

        #expect(ids == [2, 3, 4])
    }

    @Test("RefreshPolicy: 不同状态使用不同 TTL")
    func refreshPolicyUsesStatusSpecificTTL() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let freshSuccess = OpenSSFScoreRecord.success(
            repoId: 1,
            payload: OpenSSFScorePayload(date: nil, score: 9.0, checks: []),
            rawData: Data(),
            fetchedAt: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.successTTL + 60)
        )
        let staleNotIndexed = OpenSSFScoreRecord.failure(
            repoId: 2,
            status: .notIndexed,
            message: nil,
            fetchedAt: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.notIndexedTTL - 60)
        )
        let freshFailure = OpenSSFScoreRecord.failure(
            repoId: 3,
            status: .parseError,
            message: "bad json",
            fetchedAt: now.addingTimeInterval(-OpenSSFScoreRefreshPolicy.failureTTL + 60)
        )

        #expect(OpenSSFScoreRefreshPolicy.shouldRefresh(freshSuccess, now: now) == false)
        #expect(OpenSSFScoreRefreshPolicy.shouldRefresh(staleNotIndexed, now: now))
        #expect(OpenSSFScoreRefreshPolicy.shouldRefresh(freshFailure, now: now) == false)
        #expect(OpenSSFScoreRefreshPolicy.shouldRefresh(freshFailure, now: now, force: true))
    }
}
