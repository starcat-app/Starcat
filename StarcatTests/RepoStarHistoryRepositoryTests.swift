//
//  RepoStarHistoryRepositoryTests.swift
//  StarcatTests
//
//  验证本机 Star 精确快照的 UTC 日幂等、远端替换隔离和 repo 生命周期。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repo Star History Repository")
struct RepoStarHistoryRepositoryTests {

    @Test("同一 UTC 日期的本机快照应幂等更新")
    func localSnapshotIsIdempotentPerUTCDay() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "history")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let first = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T01:00:00.000Z"))
        let second = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T23:30:00.000Z"))

        try await repository.recordLocalSnapshot(
            repoId: 1,
            starsCount: 10,
            observedAt: first,
            fetchedAt: first
        )
        try await repository.recordLocalSnapshot(
            repoId: 1,
            starsCount: 12,
            observedAt: second,
            fetchedAt: second
        )

        let points = try await repository.points(repoId: 1)
        #expect(points.count == 1)
        #expect(points[0].count == 12)
        #expect(points[0].source == .localSnapshot)
        #expect(points[0].precision == .snapshot)
        #expect(StarHistoryDateCodec.dayString(from: points[0].date) == "2026-07-27")
        #expect(points[0].fetchedAt == second)
    }

    @Test("替换远端点不得删除本机精确快照")
    func remoteReplacementPreservesLocalSnapshot() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 2, owner: "octo", name: "merged")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let fetchedAt = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T08:00:00.000Z"))
        let localDate = try #require(StarHistoryDateCodec.date(from: "2026-07-27"))

        try await repository.recordLocalSnapshot(
            repoId: 2,
            starsCount: 100,
            observedAt: localDate,
            fetchedAt: fetchedAt
        )
        try await repository.replaceRemotePoints(repoId: 2, points: [
            point("2026-07-25", 80, .ghArchive, .estimated, fetchedAt),
            point("2026-07-26", 95, .discoverySnapshot, .snapshot, fetchedAt)
        ])
        try await repository.replaceRemotePoints(repoId: 2, points: [
            point("2026-07-26", 96, .ghArchive, .estimated, fetchedAt)
        ])

        let points = try await repository.points(repoId: 2)
        #expect(points.count == 2)
        #expect(points.contains { $0.source == .localSnapshot && $0.count == 100 })
        #expect(points.contains { $0.source == .ghArchive && $0.count == 96 })
        #expect(!points.contains { $0.source == .discoverySnapshot })
    }

    @Test("批量同步与单仓 metadata 更新应复用当天精确点")
    func repoMetadataWritesLocalSnapshotWithoutExtraFetch() async throws {
        let database = try InMemoryDatabaseManager()
        let repoRepository = GRDBRepoRepository(database: database)
        let historyRepository = GRDBRepoStarHistoryRepository(database: database)
        let observedAt = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let first = makeStarredDTO(id: 3, stars: 10)
        let updated = makeStarredDTO(id: 3, stars: 15)

        try await repoRepository.upsertStarred([first], userID: 100, syncedAt: observedAt)
        _ = try await repoRepository.upsertSingleStarred(
            repoDTO: updated.repo,
            starredAt: updated.starredAt,
            userID: 100,
            syncedAt: observedAt.addingTimeInterval(60)
        )

        let points = try await historyRepository.points(repoId: 3)
        #expect(points.count == 1)
        #expect(points[0].count == 15)
        #expect(points[0].source == .localSnapshot)
    }

    @Test("删除 repo 应由外键级联清理全部历史点")
    func deletingRepoCascadesHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 4, owner: "octo", name: "deleted")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        try await repository.recordLocalSnapshot(
            repoId: 4,
            starsCount: 5,
            observedAt: now,
            fetchedAt: now
        )

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE id = 4")
        }

        #expect(try await repository.points(repoId: 4).isEmpty)
    }

    private func point(
        _ day: String,
        _ count: Int,
        _ source: StarHistorySource,
        _ precision: StarHistoryPrecision,
        _ fetchedAt: Date
    ) -> StarHistoryPoint {
        StarHistoryPoint(
            date: StarHistoryDateCodec.date(from: day)!,
            count: count,
            source: source,
            precision: precision,
            fetchedAt: fetchedAt
        )
    }

    private func makeStarredDTO(id: Int64, stars: Int) -> StarredRepoDTO {
        let owner = GitHubUserDTO(
            id: 1,
            login: "octo",
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
        let repo = GitHubRepoDTO(
            id: id,
            name: "history",
            fullName: "octo/history",
            owner: owner,
            description: nil,
            language: "Swift",
            stargazersCount: stars,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/octo/history",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: "main",
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: "2026-07-27T11:00:00Z", repo: repo)
    }
}
