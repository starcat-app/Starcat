//
//  DataContributionSettingsModelTests.swift
//  StarcatTests
//
//  验证 Settings 唯一隐私开关与账户级 SQLite 真值同步。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Data Contribution Settings")
struct DataContributionSettingsModelTests {
    @Test("开关默认关闭并能持久化账户级授权")
    func defaultsOffAndPersistsConsent() async throws {
        let accountID: Int64 = 42
        let database = try InMemoryDatabaseManager(userId: accountID)
        let repository = DataContributionRepository(
            database: database,
            participantIDProvider: { "63b7d101-88c0-4cee-859f-c61f64d8db96" }
        )
        let coordinator = DataContributionCoordinator(
            repository: repository,
            repoRepository: GRDBRepoRepository(database: database),
            uploader: SettingsNoopUploader(),
            automaticallyScheduleRetry: false
        )
        await coordinator.activate(accountID: accountID)
        let model = DataContributionSettingsModel(coordinator: coordinator)

        await model.reload(accountID: accountID)
        #expect(!model.isEnabled)

        await model.setEnabled(true, accountID: accountID)
        #expect(model.isEnabled)
        let stored = try await repository.preferences(accountID: accountID)
        #expect(stored.isEnabled)
        #expect(stored.participantID == "63b7d101-88c0-4cee-859f-c61f64d8db96")

        await model.setEnabled(false, accountID: accountID)
        #expect(!model.isEnabled)
        #expect(try await repository.preferences(accountID: accountID).participantID == stored.participantID)
    }

    @Test("匿名数据库只显示关闭且不创建授权")
    func anonymousDatabaseStaysOff() async throws {
        let database = try InMemoryDatabaseManager(userId: nil)
        let coordinator = DataContributionCoordinator(
            repository: DataContributionRepository(database: database),
            repoRepository: GRDBRepoRepository(database: database),
            uploader: SettingsNoopUploader(),
            automaticallyScheduleRetry: false
        )
        let model = DataContributionSettingsModel(coordinator: coordinator)

        await model.reload(accountID: nil)
        #expect(!model.isEnabled)
        #expect(model.accountID == nil)
    }
}

private actor SettingsNoopUploader: CollectionSnapshotUploading {
    func upload(task: DataContributionOutboxTask) async throws {}
}
