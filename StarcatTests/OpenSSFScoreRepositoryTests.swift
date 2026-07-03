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
        starredAt: String? = "2026-06-16T00:00:00Z"
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

    private func markInLibrary(_ db: any DatabaseManaging, repoId: Int64, updatedAt: String = "2026-06-16T00:30:00Z") async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at)
                VALUES (?, NULL, 'unread', 'in_library', ?, 0, NULL)
                ON CONFLICT(repo_id) DO UPDATE SET
                    library_state = 'in_library',
                    library_updated_at = excluded.library_updated_at
                """,
                arguments: [repoId, updatedAt]
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

    @Test("coverageSummary: 统计已 star 或已入库且已有 OpenSSF 尝试记录的 repo")
    func coverageSummaryCountsCandidateRowsWithAnyFetchStatus() async throws {
        let (repository, db) = try makeRepository()
        try await seedRepo(db, id: 1, fullName: "a/success")
        try await seedRepo(db, id: 2, fullName: "a/not-indexed")
        try await seedRepo(db, id: 3, fullName: "a/missing")
        try await seedRepo(db, id: 4, fullName: "a/library-only", isStarred: false)
        try await seedRepo(db, id: 5, fullName: "a/external", isStarred: false)
        try await markInLibrary(db, repoId: 4)

        try await repository.upsert(.success(
            repoId: 1,
            payload: OpenSSFScorePayload(date: nil, score: 9.0, checks: []),
            rawData: Data(#"{"score":9.0}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        try await repository.upsert(.failure(
            repoId: 2,
            status: .notIndexed,
            message: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        try await repository.upsert(.failure(
            repoId: 4,
            status: .networkError,
            message: "timeout",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        let summary = try await repository.coverageSummary()

        #expect(summary.candidateTotal == 4)
        #expect(summary.fetchedTotal == 3)
    }

    @Test("staleRefreshCandidateRepos: 返回已 star 或已入库且已过 TTL 或无缓存的 repo")
    func staleRefreshCandidateReposRespectsTTLAndLibraryState() async throws {
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
        try await seedRepo(db, id: 6, fullName: "a/library-only", isStarred: false, starredAt: nil)
        try await seedRepo(db, id: 7, fullName: "a/external", isStarred: false, starredAt: nil)
        try await markInLibrary(db, repoId: 6, updatedAt: "2026-06-16T06:00:00Z")

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

        let repos = try await repository.staleRefreshCandidateRepos(now: now, limit: 10)
        let ids = repos.map(\.id)

        #expect(ids == [2, 3, 4, 6])
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

@Suite("Repo Health Repository")
struct RepoHealthRepositoryTests {
    private func makeRepository() throws -> (GRDBRepoHealthRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        return (GRDBRepoHealthRepository(database: db), db)
    }

    private func seedRepo(
        _ db: any DatabaseManaging,
        id: Int64,
        fullName: String,
        isStarred: Bool = true,
        starredAt: String? = "2026-06-16T00:00:00Z"
    ) async throws {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, is_starred, starred_at, cached_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, '2026-06-16T00:00:00Z')
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

    private func markInLibrary(_ db: any DatabaseManaging, repoId: Int64, updatedAt: String = "2026-06-16T00:30:00Z") async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repo_notes (repo_id, content, status, library_state, library_updated_at, is_ai_generated, edited_at)
                VALUES (?, NULL, 'unread', 'in_library', ?, 0, NULL)
                ON CONFLICT(repo_id) DO UPDATE SET
                    library_state = 'in_library',
                    library_updated_at = excluded.library_updated_at
                """,
                arguments: [repoId, updatedAt]
            )
        }
    }

    private func makeSnapshot(repoId: Int64, staleAfter: String = "2026-06-17T00:00:00Z") -> RepoHealthSnapshot {
        RepoHealthSnapshot(
            repoId: repoId,
            overallScore: 80,
            grade: "B",
            maintenanceScore: 80,
            popularityScore: 80,
            qualityScore: 80,
            securityScore: 80,
            payloadJSON: "{}",
            computedAt: "2026-06-16T00:00:00Z",
            staleAfter: staleAfter,
            fetchStatus: .success,
            lastError: nil
        )
    }

    @Test("coverageSummary: 统计已 star 或已入库且已有 Health 快照的 repo")
    func coverageSummaryCountsCandidateRowsWithSnapshots() async throws {
        let (repository, db) = try makeRepository()
        try await seedRepo(db, id: 1, fullName: "a/starred")
        try await seedRepo(db, id: 2, fullName: "a/library-only", isStarred: false)
        try await seedRepo(db, id: 3, fullName: "a/missing")
        try await seedRepo(db, id: 4, fullName: "a/external", isStarred: false)
        try await markInLibrary(db, repoId: 2)

        try await repository.upsert(makeSnapshot(repoId: 1))
        try await repository.upsert(makeSnapshot(repoId: 2))
        try await repository.upsert(makeSnapshot(repoId: 4))

        let summary = try await repository.coverageSummary()

        #expect(summary.candidateTotal == 3)
        #expect(summary.snapshotTotal == 2)
        #expect(summary.isAllCovered == false)
    }

    @Test("missingSnapshotCandidateRepos: 返回未建快照的已 star 或已入库 repo")
    func missingSnapshotCandidateReposUsesStarredOrLibraryState() async throws {
        let (repository, db) = try makeRepository()
        try await seedRepo(db, id: 1, fullName: "a/starred-ready", starredAt: "2026-06-16T04:00:00Z")
        try await seedRepo(db, id: 2, fullName: "a/starred-missing", starredAt: "2026-06-16T03:00:00Z")
        try await seedRepo(db, id: 3, fullName: "a/library-only", isStarred: false, starredAt: nil)
        try await seedRepo(db, id: 4, fullName: "a/external", isStarred: false, starredAt: nil)
        try await markInLibrary(db, repoId: 3, updatedAt: "2026-06-16T05:00:00Z")
        try await repository.upsert(makeSnapshot(repoId: 1))

        let repos = try await repository.missingSnapshotCandidateRepos(limit: 10)

        #expect(repos.map(\.id) == [2, 3])
    }

    @Test("staleRefreshCandidateRepos: 返回快照过期或缺失的已 star / 已入库 repo")
    func staleRefreshCandidateReposUsesStarredOrLibraryState() async throws {
        let (repository, db) = try makeRepository()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await seedRepo(db, id: 1, fullName: "a/fresh", starredAt: "2026-06-16T04:00:00Z")
        try await seedRepo(db, id: 2, fullName: "a/stale", starredAt: "2026-06-16T03:00:00Z")
        try await seedRepo(db, id: 3, fullName: "a/missing", starredAt: "2026-06-16T02:00:00Z")
        try await seedRepo(db, id: 4, fullName: "a/library-only", isStarred: false, starredAt: nil)
        try await seedRepo(db, id: 5, fullName: "a/external", isStarred: false, starredAt: nil)
        try await markInLibrary(db, repoId: 4, updatedAt: "2026-06-16T05:00:00Z")

        try await repository.upsert(makeSnapshot(repoId: 1, staleAfter: "2027-06-16T00:00:00Z"))
        try await repository.upsert(makeSnapshot(repoId: 2, staleAfter: "2026-06-16T00:00:00Z"))
        try await repository.upsert(makeSnapshot(repoId: 5, staleAfter: "2026-06-16T00:00:00Z"))

        let repos = try await repository.staleRefreshCandidateRepos(now: now, limit: 10)

        #expect(repos.map(\.id) == [2, 3, 4])
    }
}

@Suite("Library state cache retention")
struct LibraryStateCacheRetentionTests {

    @Test("移出知识库不删除 README / Repo Health / OpenSSF 缓存")
    func removingFromLibraryKeepsLocalCaches() async throws {
        let db = try InMemoryDatabaseManager()
        try await seedRepo(db, id: 90, fullName: "alice/cache-retained")

        let noteRepository = GRDBRepoNoteRepository(database: db)
        let readmeRepository = ReadmeRepository(database: db)
        let healthRepository = GRDBRepoHealthRepository(database: db)
        let openSSFRepository = GRDBOpenSSFScoreRepository(database: db)

        try await noteRepository.updateLibraryState(repoId: 90, state: .inLibrary)
        try await readmeRepository.upsert(Readme(
            repoId: 90,
            renderedHtml: "<h1>cached</h1>",
            etag: "\"html\"",
            lastModified: nil,
            cachedAt: "2026-07-03T00:00:00Z",
            size: 15
        ))
        try await readmeRepository.upsertContent(repoId: 90, content: "# cached", at: Date(timeIntervalSince1970: 1_800_000_000))
        try await healthRepository.upsert(RepoHealthSnapshot(
            repoId: 90,
            overallScore: 82,
            grade: "B",
            maintenanceScore: 80,
            popularityScore: 75,
            qualityScore: 88,
            securityScore: 85,
            payloadJSON: "{}",
            computedAt: "2026-07-03T00:00:00Z",
            staleAfter: "2026-07-04T00:00:00Z",
            fetchStatus: .success,
            lastError: nil
        ))
        try await openSSFRepository.upsert(.success(
            repoId: 90,
            payload: OpenSSFScorePayload(date: "2026-07-03", score: 8.2, checks: []),
            rawData: Data(#"{"score":8.2}"#.utf8),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        try await noteRepository.updateLibraryState(repoId: 90, state: .outsideLibrary)

        #expect(try await readmeRepository.find(repoId: 90)?.renderedHtml == "<h1>cached</h1>")
        #expect(try await readmeRepository.findContent(repoId: 90) == "# cached")
        #expect(try await healthRepository.snapshot(for: 90)?.overallScore == 82)
        #expect(try await openSSFRepository.record(for: 90)?.aggregateScore == 8.2)
    }

    private func seedRepo(_ db: any DatabaseManaging, id: Int64, fullName: String) async throws {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, is_starred, starred_at, cached_at)
                VALUES (?, ?, ?, ?, ?, 0, NULL, '2026-07-03T00:00:00Z')
                """,
                arguments: [id, parts[0], parts[1], fullName, "https://github.com/\(fullName)"]
            )
        }
    }
}
