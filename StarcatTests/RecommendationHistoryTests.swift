//
//  RecommendationHistoryTests.swift
//  StarcatTests
//
//  验证长期历史的迁移、离线快照与负反馈语义，不访问服务和真实账号数据。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("推荐历史")
@MainActor
struct RecommendationHistoryTests {
    @Test("已有 v25 数据库追加推荐历史迁移，不改原仓库数据")
    func migratesExistingDatabase() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)
        try migrator.migrate(queue, upTo: "v25-repository-skills")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, is_starred)
                VALUES (10, 'owner', 'repo10', 'owner/repo10', 'https://github.com/owner/repo10', 1)
                """)
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        try queue.read { db in
            let applied = try migrator.appliedIdentifiers(db)
            let isStarred = try Bool.fetchOne(db, sql: "SELECT is_starred FROM repos WHERE id = 10")
            let hasImportState = try db.tableExists("recommendation_history_state")
            let foreignKeys = try db.foreignKeys(on: "recommendation_history")
            #expect(applied.contains("v26-recommendation-history"))
            #expect(isStarred == true)
            #expect(!hasImportState)
            #expect(foreignKeys.isEmpty)
        }
    }

    @Test("首次展示去重并冻结推荐时间，仓库缓存清理不会删除历史")
    func recordSurvivesCacheCleanup() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let repository = RecommendationHistoryRepository(database: database)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.record([item(10)], day: "2026-11-9", date: first, batchID: "first", accountID: 42)
        try await repository.record([item(10), item(11)], day: "2026-11-10", date: first.addingTimeInterval(86_400), batchID: "second", accountID: 42)
        try await database.writer.write { db in try db.execute(sql: "DELETE FROM repos") }
        let entries = try await repository.fetchAll(accountID: 42)
        #expect(entries.map(\.id) == [11, 10])
        let old = try #require(entries.last)
        #expect(old.recommendedAt == first)
        #expect(old.recommendedDay == "2026-11-9")
        #expect(old.batchID == "first")
        #expect(old.item?.description == "Offline description")
        #expect(old.item?.reasons == ["costar"])
    }

    @Test("新历史表拒绝只有 ID 而没有快照的记录")
    func requiresSnapshot() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        await #expect(throws: (any Error).self) {
            try await database.writer.write { db in
                try db.execute(sql: "INSERT INTO recommendation_history (repo_id) VALUES (10)")
            }
        }
    }

    @Test("Store 按 Star 真值清除负反馈，Unstar 回未反馈且重启不复活旧反馈")
    func feedbackFollowsStarTruth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try InMemoryDatabaseManager(userId: 42)
        let repository = RecommendationHistoryRepository(database: database)
        try await repository.record([item(10)], day: "2026-11-15", date: Date(), batchID: "batch", accountID: 42)
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root), history: repository)
        #expect(await store.loadPreferences(accountID: 42, scopeRevision: 1))
        await store.dismiss(10)
        // Star 请求失败不会发布新的注册表真值；相同快照不能清除反馈。
        await store.excludeStarred([])
        let dismissed = try #require(store.historyEntries.first)
        #expect(dismissed.feedback(starredIDs: []) == .dismissed)
        #expect(dismissed.feedback(starredIDs: [10]) == .starred)
        await store.excludeStarred([10])
        await store.dismiss(10)
        let starred = try #require(try await repository.fetchAll(accountID: 42).first)
        #expect(starred.feedback(starredIDs: [10]) == .starred)
        #expect(starred.feedback(starredIDs: []) == .unanswered)
        #expect(starred.id == 10)
        await store.excludeStarred([])
        let restored = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root), history: repository)
        #expect(await restored.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(restored.historyEntries.first?.feedback(starredIDs: []) == .unanswered)
        #expect(restored.state.dismissedIDs.isEmpty)
    }

    @Test("只允许对真实历史负反馈，撤销保留历史并落库")
    func feedbackRequiresRecommendation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try InMemoryDatabaseManager(userId: 42)
        let repository = RecommendationHistoryRepository(database: database)
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root), history: repository)
        #expect(await store.loadPreferences(accountID: 42, scopeRevision: 1))
        await store.dismiss(999)
        #expect(store.state.dismissedIDs.isEmpty)
        #expect(try await repository.fetchAll(accountID: 42).isEmpty)

        try await repository.record([item(10)], day: "2026-11-15", date: Date(), batchID: "batch", accountID: 42)
        let restored = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root), history: repository)
        #expect(await restored.loadPreferences(accountID: 42, scopeRevision: 1))
        await restored.dismiss(10)
        #expect(restored.state.dismissedIDs == [10])
        await restored.restoreInterest(10)
        #expect(restored.state.dismissedIDs.isEmpty)
        #expect(restored.state.recommendedIDs == [10])
        let saved = try await repository.fetchAll(accountID: 42)
        #expect(saved.count == 1)
        #expect(saved.first?.isDismissed == false)
    }

    @Test("读取本地历史不消费今日展示资格，批次内顺序重启后不变")
    func readingHistoryDoesNotPresentCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try InMemoryDatabaseManager(userId: 42)
        let repository = RecommendationHistoryRepository(database: database)
        let disk = DailyRecommendationDiskStore(root: root)
        let date = Date()
        var state = DailyRecommendationState()
        state.day = DailyRecommendationState.dayKey(date)
        state.items = [item(12), item(10), item(11)]
        state.hasGeneratedBatch = true
        state.generatedAt = date
        try await disk.save(state, accountID: 42, revision: 1)
        let store = DailyRecommendationStore(disk: disk, history: repository)
        #expect(await store.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(store.historyEntries.isEmpty)
        #expect(store.state.autoPresentedDay.isEmpty)
        #expect(store.canAutomaticallyPresent(date: date))

        await store.markPresented(date: date)
        let ids = store.historyEntries.map(\.id)
        #expect(ids == [12, 11, 10])
        await store.markPresented(date: date.addingTimeInterval(30))
        #expect(store.historyEntries.allSatisfy { $0.recommendedAt == date })
        let restored = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root), history: repository)
        #expect(await restored.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(restored.historyEntries.map(\.id) == ids)
        #expect(!restored.canAutomaticallyPresent(date: date))
    }

    @Test("历史仓储随账号切换，不将旧账号动作写进新库")
    func accountIsolation() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let repository = RecommendationHistoryRepository(database: database)
        try await repository.record([item(10)], day: "2026-11-15", date: Date(), batchID: "batch", accountID: 42)
        try await database.reopen(userId: 99)
        #expect(try await repository.fetchAll(accountID: 99).isEmpty)
        do {
            try await repository.setDismissed(true, id: 10, accountID: 42)
            Issue.record("旧账号动作必须被拒绝")
        } catch is CancellationError {}
        #expect(try await repository.fetchAll(accountID: 99).isEmpty)
    }

    @Test("新 JSON 只保存批次、浏览进度和偏好，不双写历史或反馈")
    func newSnapshotOmitsHistory() throws {
        var state = DailyRecommendationState()
        state.recommendedDays = ["10": "2026-11-15"]
        state.dismissedIDs = [10]
        state.items = [item(11)]
        state.revealedIDs = [11]
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(json["recommendedDays"] == nil)
        #expect(json["dismissedIDs"] == nil)
        #expect(json["revealedIDs"] != nil)
        #expect(json["items"] != nil)
    }

    private func item(_ id: Int64) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: id, fullName: "owner/repo\(id)", description: "Offline description",
                               language: "Swift", stars: 10, forks: 1, archived: false,
                               score: 0.5, source: "starcat_trained", reasons: ["costar"])
    }
}
