//
//  DataContributionCoordinatorTests.swift
//  StarcatTests
//
//  验证完整同步旁路编排、成功清队列与失败静默退避。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Data Contribution Coordinator")
struct DataContributionCoordinatorTests {
    private static let accountID: Int64 = 42
    private static let participantID = "63b7d101-88c0-4cee-859f-c61f64d8db96"

    @Test("开启后完整同步应上传公开快照并删除 Outbox")
    func fullSyncUploadsAndRemovesTask() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        try await database.insertRepoFixture(id: 100)
        let dataRepository = DataContributionRepository(
            database: database,
            participantIDProvider: { Self.participantID }
        )
        let uploader = RecordingCollectionUploader()
        let coordinator = DataContributionCoordinator(
            repository: dataRepository,
            repoRepository: GRDBRepoRepository(database: database),
            uploader: uploader,
            automaticallyScheduleRetry: false
        )
        await coordinator.activate(accountID: Self.accountID)
        _ = try await coordinator.setEnabled(true, accountID: Self.accountID)

        await coordinator.handleSuccessfulFullSync(accountID: Self.accountID, capturedAt: Date())
        try await waitUntil { await uploader.attemptCount == 1 }

        let uploaded = try #require(await uploader.lastSnapshot)
        #expect(uploaded.repositories.map(\.repoID) == [100])
        #expect(try await outboxCount(database) == 0)
    }

    @Test("关闭时完整同步不应生成或上传任务")
    func disabledDoesNothing() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        try await database.insertRepoFixture(id: 101)
        let uploader = RecordingCollectionUploader()
        let coordinator = DataContributionCoordinator(
            repository: DataContributionRepository(database: database),
            repoRepository: GRDBRepoRepository(database: database),
            uploader: uploader,
            automaticallyScheduleRetry: false
        )
        await coordinator.activate(accountID: Self.accountID)

        await coordinator.handleSuccessfulFullSync(accountID: Self.accountID, capturedAt: Date())
        try await Task.sleep(for: .milliseconds(50))

        #expect(await uploader.attemptCount == 0)
        #expect(try await outboxCount(database) == 0)
    }

    @Test("服务失败只应写 retry_wait，不应丢失快照")
    func failureMovesTaskToRetryWait() async throws {
        let database = try InMemoryDatabaseManager(userId: Self.accountID)
        try await database.insertRepoFixture(id: 102)
        let dataRepository = DataContributionRepository(
            database: database,
            participantIDProvider: { Self.participantID }
        )
        let uploader = RecordingCollectionUploader(error: CollectionAPIError.httpStatus(500))
        let coordinator = DataContributionCoordinator(
            repository: dataRepository,
            repoRepository: GRDBRepoRepository(database: database),
            uploader: uploader,
            retryBaseDelay: 30,
            jitterProvider: { 1 },
            automaticallyScheduleRetry: false
        )
        await coordinator.activate(accountID: Self.accountID)
        _ = try await coordinator.setEnabled(true, accountID: Self.accountID)

        await coordinator.handleSuccessfulFullSync(accountID: Self.accountID, capturedAt: Date())
        try await waitUntil { await uploader.attemptCount == 1 }
        try await waitUntil { try await self.outboxState(database) == "retry_wait" }

        #expect(try await outboxCount(database) == 1)
        #expect(try await outboxAttemptCount(database) == 1)
    }

    @Test("业务错误固定 24 小时，网络与 5xx 指数退避")
    func retryPolicy() {
        #expect(DataContributionCoordinator.retryDelay(
            for: CollectionAPIError.httpStatus(422), attemptCount: 1
        ) == 86_400)
        #expect(DataContributionCoordinator.retryDelay(
            for: CollectionAPIError.httpStatus(500), attemptCount: 1, baseDelay: 30, jitter: 1
        ) == 30)
        #expect(DataContributionCoordinator.retryDelay(
            for: CollectionAPIError.httpStatus(429), attemptCount: 3, baseDelay: 30, jitter: 1
        ) == 120)
        #expect(DataContributionCoordinator.retryDelay(
            for: URLError(.notConnectedToInternet), attemptCount: 20, baseDelay: 30, jitter: 1.5
        ) == 86_400)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待旁路状态超时")
    }

    private func outboxCount(_ database: any DatabaseManaging) async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM data_contribution_outbox") ?? 0
        }
    }

    private func outboxState(_ database: any DatabaseManaging) async throws -> String? {
        try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM data_contribution_outbox LIMIT 1")
        }
    }

    private func outboxAttemptCount(_ database: any DatabaseManaging) async throws -> Int? {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT attempt_count FROM data_contribution_outbox LIMIT 1")
        }
    }
}

private actor RecordingCollectionUploader: CollectionSnapshotUploading {
    private let error: Error?
    private(set) var attemptCount = 0
    private(set) var lastSnapshot: RecommendationSnapshot?

    init(error: Error? = nil) {
        self.error = error
    }

    func upload(task: DataContributionOutboxTask) async throws {
        attemptCount += 1
        lastSnapshot = try RecommendationSnapshotJSON.decoder.decode(
            RecommendationSnapshot.self,
            from: task.payload
        )
        if let error { throw error }
    }
}
