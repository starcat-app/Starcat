//
//  DataContributionTests.swift
//  StarcatTests
//
//  验证公开仓隐私过滤、跨语言 canonical hash 与账户级单槽 Outbox。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Data Contribution")
struct DataContributionTests {
    private static let accountID: Int64 = 42
    private static let participantID = "63b7d101-88c0-4cee-859f-c61f64d8db96"
    private static let capturedAt = ISO8601DateFormatter.githubDate(
        from: "2026-08-23T08:30:00Z"
    )!

    @Test("跨语言 fixture 应产生固定 canonical hash")
    func canonicalHashFixture() throws {
        let snapshot = try RecommendationSnapshotBuilder.build(
            repositories: [
                makeRepo(id: 41_881_900, starredAt: "2023-06-11T13:20:10Z"),
                makeRepo(id: 1_342_004, starredAt: nil),
            ],
            participantID: Self.participantID,
            snapshotID: "0191f9e3-95d4-7f52-b4d3-28d628e3a02b",
            capturedAt: Self.capturedAt
        )

        #expect(snapshot.contentHash == "sha256:90925b14edd0151d98a73f460f5120e57e47af855b8ed6595de2191c99cadc0c")
        #expect(snapshot.repositories.map(\.repoID) == [1_342_004, 41_881_900])

        let payload = String(decoding: try snapshot.encodedPayload(), as: UTF8.self)
        #expect(payload.contains("\"starred_at\":null"))
        #expect(payload.contains("\"content_hash\":\"sha256:90925b14"))
    }

    @Test("快照构造前应过滤私有仓、非 Star 仓并去重")
    func filtersPrivateAndUnstarredRepositories() throws {
        let snapshot = try RecommendationSnapshotBuilder.build(
            repositories: [
                makeRepo(id: 3, starredAt: nil, isPrivate: true),
                makeRepo(id: 2, starredAt: nil, isStarred: false),
                makeRepo(id: 1, starredAt: nil),
                makeRepo(id: 1, starredAt: "2025-01-01T00:00:00Z"),
            ],
            participantID: Self.participantID,
            snapshotID: "7f90e6b8-d100-4d85-b84d-091e0966992f",
            capturedAt: Self.capturedAt
        )

        #expect(snapshot.repositories == [
            RecommendationSnapshotRepository(repoID: 1, starredAt: nil)
        ])
        let payload = String(decoding: try snapshot.encodedPayload(), as: UTF8.self)
        #expect(!payload.contains("\"repo_id\":2"))
        #expect(!payload.contains("\"repo_id\":3"))
    }

    @Test("关闭开关应清空 Outbox 但保留 participant ID")
    func disablingClearsOutboxAndPreservesParticipant() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        let repository = DataContributionRepository(
            database: database,
            participantIDProvider: { Self.participantID }
        )
        let participantID = try await repository.setEnabled(true, accountID: Self.accountID)
        #expect(participantID == Self.participantID)

        let snapshot = try makeSnapshot(id: "0b03874f-351e-416f-a2d4-acde99ab9ea2")
        try await repository.enqueue(snapshot: snapshot, accountID: Self.accountID)
        #expect(try await repository.dueTask(accountID: Self.accountID) != nil)

        _ = try await repository.setEnabled(false, accountID: Self.accountID)
        #expect(try await repository.dueTask(accountID: Self.accountID) == nil)
        let disabled = try await repository.preferences(accountID: Self.accountID)
        #expect(!disabled.isEnabled)
        #expect(disabled.participantID == Self.participantID)

        let reenabledID = try await repository.setEnabled(true, accountID: Self.accountID)
        #expect(reenabledID == Self.participantID)
    }

    @Test("新完整快照应覆盖旧任务且延后任务到期前不可领取")
    func replacesTaskAndHonorsRetryDate() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        let repository = DataContributionRepository(
            database: database,
            participantIDProvider: { Self.participantID }
        )
        _ = try await repository.setEnabled(true, accountID: Self.accountID, now: Self.capturedAt)

        try await repository.enqueue(
            snapshot: makeSnapshot(id: "54ce3124-acde-4b53-a59a-5cb8a436c735"),
            accountID: Self.accountID,
            now: Self.capturedAt
        )
        try await repository.enqueue(
            snapshot: makeSnapshot(id: "a6958bd5-c59c-4bd0-b2ab-2f8b605d5df7"),
            accountID: Self.accountID,
            now: Self.capturedAt
        )

        let task = try #require(try await repository.dueTask(
            accountID: Self.accountID,
            now: Self.capturedAt
        ))
        #expect(task.id == "a6958bd5-c59c-4bd0-b2ab-2f8b605d5df7")
        #expect(task.attemptCount == 0)

        let retryAt = Self.capturedAt.addingTimeInterval(60)
        try await repository.markRetry(
            taskID: task.id,
            accountID: Self.accountID,
            attemptCount: 1,
            nextAttemptAt: retryAt,
            now: Self.capturedAt
        )
        #expect(try await repository.dueTask(
            accountID: Self.accountID,
            now: Self.capturedAt.addingTimeInterval(59)
        ) == nil)
        #expect(try await repository.dueTask(accountID: Self.accountID, now: retryAt)?.attemptCount == 1)
    }

    @Test("切库后旧账户任务应被拒绝")
    @MainActor
    func rejectsStaleAccountScope() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        let repository = DataContributionRepository(database: database)
        try await database.reopen(userId: 43)

        await #expect(throws: DataContributionRepositoryError.accountScopeChanged) {
            _ = try await repository.preferences(accountID: Self.accountID)
        }
    }

    private func makeSnapshot(id: String) throws -> RecommendationSnapshot {
        try RecommendationSnapshotBuilder.build(
            repositories: [makeRepo(id: 1, starredAt: nil)],
            participantID: Self.participantID,
            snapshotID: id,
            capturedAt: Self.capturedAt
        )
    }

    private func makeRepo(
        id: Int64,
        starredAt: String?,
        isPrivate: Bool = false,
        isStarred: Bool = true
    ) -> Repo {
        var repo = Repo.makeMinimal(owner: "fixture", name: String(id))
        repo.id = id
        repo.isPrivate = isPrivate
        repo.isStarred = isStarred
        repo.starredAt = starredAt
        return repo
    }
}
