//
//  DailyRecommendationTests.swift
//  StarcatTests
//
//  验证每日批次稳定性、完整本地排除与账号隔离。
//  使用临时文件与可控网络闭包，不访问真实服务或用户数据。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("每日推荐批次")
@MainActor
struct DailyRecommendationTests {
    @Test("推荐详情先补父行，README 可落库且不创建 Star 或知识库关系")
    func detailReadmeHasParentRepo() async throws {
        let database = try InMemoryDatabaseManager()
        let repository: any RepoRepositoryProtocol = GRDBRepoRepository(database: database)
        let readmes = ReadmeRepository(database: database)
        let candidate = item(9001).dailyRecommendationRepo
        let readme = Readme(
            repoId: candidate.id, renderedHtml: "<h1>Recommended</h1>", etag: nil,
            lastModified: nil, cachedAt: "2026-11-05T00:00:00Z", size: 20
        )
        // 保留真实外键约束，先证明旧入口的临时快照不能承载 Manage README 缓存。
        do {
            try await readmes.upsert(readme)
            Issue.record("缺少 repos 父行时应触发外键错误")
        } catch let error as GRDB.DatabaseError {
            #expect(error.resultCode == .SQLITE_CONSTRAINT)
        }
        var snapshot = candidate
        snapshot.isStarred = true
        snapshot.starredAt = "2026-11-04T00:00:00Z"
        let saved = try await repository.upsertRepoMetadataForLibrary(
            repo: snapshot, syncedAt: Date(), preservingExisting: true
        )
        try await readmes.upsert(readme)
        #expect(try await readmes.find(repoId: candidate.id)?.renderedHtml == readme.renderedHtml)
        #expect(!saved.isStarred)
        #expect(saved.starredAt == nil)
        #expect(try await repository.starredCount() == 0)
        #expect(try await repository.knowledgeCount() == 0)
        try await database.writer.read { db in
            let starRelations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM starred_repos")
            let notes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repo_notes")
            #expect(starRelations == 0)
            #expect(notes == 0)
        }
    }

    @Test("精简推荐快照不覆盖已有完整元数据与 Star 状态", arguments: [false, true])
    func detailPreservesExistingMetadata(isStarred: Bool) async throws {
        let database = try InMemoryDatabaseManager()
        let repository: any RepoRepositoryProtocol = GRDBRepoRepository(database: database)
        var existing = item(9002).dailyRecommendationRepo
        existing.license = "MIT"
        existing.defaultBranch = "main"
        existing.topics = "[\"swift\",\"database\"]"
        existing.cachedAt = "2026-11-04T00:00:00Z"
        existing.isStarred = isStarred
        existing.starredAt = isStarred ? "2026-11-03T00:00:00Z" : nil
        let original = existing
        try await database.writer.write { db in
            var row = original
            try row.save(db)
        }
        let saved = try await repository.upsertRepoMetadataForLibrary(
            repo: item(9002).dailyRecommendationRepo, syncedAt: Date(), preservingExisting: true
        )
        #expect(saved == original)
        #expect(try await repository.findById(original.id) == original)
    }

    @Test("超过 500 个 Stars 仍完整排除，同时去重无效候选")
    func completeExclusion() {
        let excluded = Set((1...1800).map(Int64.init))
        let items = [item(1700), item(1801), item(1801), item(1802)]
        let result = DailyRecommendationState.candidates(items, excluding: excluded)
        #expect(result.map(\.repoID) == [1801, 1802])
    }

    @Test("种子稳定、最多 20 个且不含私有仓库")
    func seedPrivacyAndStability() {
        var repos = (1...60).map { repo(Int64($0)) }
        repos[0].isPrivate = true
        repos[1].isArchived = true
        let seeds = DailyRecommendationState.seeds(from: repos)
        #expect(seeds.count == 20)
        #expect(Set(seeds).count == 20)
        #expect(!seeds.contains(1))
        #expect(!seeds.contains(2))
        #expect(seeds == DailyRecommendationState.seeds(from: repos.reversed()))
    }

    @Test("本地日期按时区而不是 UTC 日切换")
    func localDay() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-04T17:00:00Z"))
        #expect(DailyRecommendationState.dayKey(date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2026-11-5")
        #expect(DailyRecommendationState.dayKey(date, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-11-4")
    }

    @Test("重启恢复翻牌、屏蔽和自动展示记录，不重复请求当日候选")
    func restoreFrozenBatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let date = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] },
            fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        await store.reveal(100)
        await store.dismiss(101)
        let firstClaim = await store.claimAutomaticPresentation(date: date)
        #expect(firstClaim)
        let secondClaim = await store.claimAutomaticPresentation(date: date)
        #expect(!secondClaim)
        let restored = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        await restored.load(
            accountID: 42, scopeRevision: 2, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] },
            fetchCandidates: { _, _ in
                Issue.record("当日批次应读盘恢复")
                return response([])
            }
        )
        #expect(restored.state.revealedIDs == [100])
        #expect(restored.visibleItems.map(\.repoID) == [100])
        #expect(restored.state.dismissedIDs == [101])
        let restoredClaim = await restored.claimAutomaticPresentation(date: date)
        #expect(!restoredClaim)
    }

    @Test("新的一天更新批次，屏蔽反馈继续保留")
    func nextDayKeepsFeedback() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let today = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: today, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) }
        )
        await store.dismiss(100)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        await store.load(
            accountID: 42, scopeRevision: 1, date: tomorrow, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        #expect(store.visibleItems.map(\.repoID) == [101])
        #expect(store.state.dismissedIDs.contains(100))
    }

    @Test("服务端当日无可用候选时冻结空批次，不重复请求")
    func emptyRemoteBatchIsFrozen() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let date = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([]) }
        )
        await store.load(
            accountID: 42, scopeRevision: 2, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] },
            fetchCandidates: { _, _ in
                Issue.record("空批次已冻结，同一天不应重复请求")
                return response([item(101)])
            }
        )
        #expect(store.visibleItems.isEmpty)
        #expect(store.state.day == DailyRecommendationState.dayKey(date))
        #expect(store.state.modelVersion == "v20")
    }

    @Test("切账号后忽略在途旧响应，不污染新账号")
    func staleResponse() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        var continuation: CheckedContinuation<DailyRecommendationResponse, Never>?
        let task = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test", fetchStars: { [repo(1)] },
                fetchCandidates: { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                }
            )
        }
        while continuation == nil { await Task.yield() }
        store.activate(accountID: 99, scopeRevision: 2)
        continuation?.resume(returning: response([item(100)]))
        await task.value
        #expect(store.accountID == 99)
        #expect(store.visibleItems.isEmpty)
        #expect(!store.isLoading)
    }

    @Test("离线保留旧批次，但不能作为今日自动弹出")
    func offlineKeepsActualDay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        await store.load(
            accountID: 42, scopeRevision: 1, date: yesterday, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) }
        )
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in throw URLError(.notConnectedToInternet) }
        )
        #expect(store.visibleItems.map(\.repoID) == [100])
        #expect(store.state.generatedAt == yesterday)
        #expect(store.errorKey == "recommendations.daily.failed")
        let claimed = await store.claimAutomaticPresentation()
        #expect(!claimed)
    }

    @Test("损坏状态文件不可用空反馈覆盖")
    func corruptFileIsNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("42.json")
        try Data("invalid".utf8).write(to: file)
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [] }, fetchCandidates: { _, _ in response([]) }
        )
        #expect(store.errorKey != nil)
        #expect(try Data(contentsOf: file) == Data("invalid".utf8))
    }

    @Test("固定种子和模型跨天展示新项目，当天重开和重启保留原批次")
    func historyKeepsDailyBatchesFresh() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let candidates = (100...199).map { item(Int64($0)) }
        await store.load(accountID: 42, scopeRevision: 1, date: today, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response(candidates) })
        #expect(store.state.recommendedDays.isEmpty)
        let firstIDs = store.visibleItems.map(\.repoID)
        #expect(firstIDs == Array(100...109).map(Int64.init))
        await store.markPresented(date: today)
        #expect(store.state.recommendedIDs == Set(firstIDs))
        await store.reveal(100)
        await store.load(accountID: 42, scopeRevision: 1, date: today, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            Issue.record("当天已展示批次必须直接复用")
            return response([])
        })
        #expect(store.visibleItems.map(\.repoID) == firstIDs)
        #expect(store.state.revealedIDs == [100])

        await store.load(accountID: 42, scopeRevision: 1, date: tomorrow, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
            #expect(cursor == nil)
            return response(candidates)
        })
        let secondIDs = store.visibleItems.map(\.repoID)
        #expect(secondIDs == Array(110...119).map(Int64.init))
        await store.markPresented(date: tomorrow)
        let restored = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        await restored.load(accountID: 42, scopeRevision: 2, date: tomorrow, serviceScope: "test",
                            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            Issue.record("重启后仍应恢复当天批次")
            return response([])
        })
        #expect(restored.visibleItems.map(\.repoID) == secondIDs)
        #expect(restored.state.recommendedDays.count == 20)
        await restored.loadPreferences(accountID: 99, scopeRevision: 3)
        #expect(restored.state.recommendedDays.isEmpty)
    }

    @Test("未打开抽卡页不消耗历史，次日仍可推荐这批未展示项目")
    func prefetchDoesNotConsumeHistory() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        for date in [today, tomorrow] {
            await store.load(accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
                             fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) })
            #expect(store.visibleItems.map(\.repoID) == [100])
            #expect(store.state.recommendedDays.isEmpty)
        }
    }

    @Test("整页被 Stars 或历史排除后继续补页，不受前 100 个候选限制")
    func fillsFromLaterPages() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DailyRecommendationDiskStore(root: root)
        var saved = DailyRecommendationState()
        for id in 101...200 { saved.recommendedDays[String(id)] = "2026-1-1" }
        saved.dismissedIDs = [201]
        try await disk.save(saved, accountID: 42, revision: 0)
        let store = DailyRecommendationStore(disk: disk)
        var cursors: [String?] = []
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { (1...100).map { repo(Int64($0)) } }, fetchCandidates: { _, cursor in
            cursors.append(cursor)
            switch cursor {
            case nil:
                return DailyRecommendationResponse(modelVersion: "v20", items: (1...100).map { item(Int64($0)) }, hasMore: true, nextCursor: "second")
            case "second":
                return DailyRecommendationResponse(modelVersion: "v20", items: (101...200).map { item(Int64($0)) }, hasMore: true, nextCursor: "third")
            default:
                return response((201...211).map { item(Int64($0)) })
            }
        })
        #expect(cursors == [nil, "second", "third"])
        #expect(store.visibleItems.map(\.repoID) == Array(202...211).map(Int64.init))
        #expect(store.state.recommendedDays.count == 100)
    }

    @Test("补页预算耗尽后保存位置，重试继续后续页而不是回到第一页")
    func pageBudgetResumesCursor() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        var cursors: [String?] = []
        func page(_ seeds: [Int64], _ cursor: String?) async throws -> DailyRecommendationResponse {
            cursors.append(cursor)
            if cursor == "page-4" { return response((501...510).map { item(Int64($0)) }) }
            return DailyRecommendationResponse(modelVersion: "v20", items: [item(2)], hasMore: true, nextCursor: "page-\(cursors.count + 1)")
        }
        for _ in 0..<2 {
            await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                             fetchStars: { (1...500).map { repo(Int64($0)) } }, fetchCandidates: page)
            if cursors.count == 3 {
                #expect(store.visibleItems.isEmpty)
                #expect(store.emptyKey == "recommendations.daily.continueSearch")
            }
        }
        #expect(cursors == [nil, "page-2", "page-3", "page-4"])
        #expect(store.visibleItems.map(\.repoID) == Array(501...510).map(Int64.init))
    }

    @Test("次日探测相同模型后保留已推进的游标，不重新遍历前几页")
    func nextDayPreservesCursorProgress() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DailyRecommendationDiskStore(root: root)
        var saved = DailyRecommendationState()
        for id in 100...399 { saved.recommendedDays[String(id)] = "2026-1-1" }
        try await disk.save(saved, accountID: 42, revision: 0)
        let store = DailyRecommendationStore(disk: disk)
        let today = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        var cursors: [String?] = []
        func page(_ seeds: [Int64], _ cursor: String?) async throws -> DailyRecommendationResponse {
            cursors.append(cursor)
            switch cursor {
            case nil:
                return DailyRecommendationResponse(modelVersion: "v20", items: (100...199).map { item(Int64($0)) }, hasMore: true, nextCursor: "second")
            case "second":
                return DailyRecommendationResponse(modelVersion: "v20", items: (200...299).map { item(Int64($0)) }, hasMore: true, nextCursor: "third")
            case "third":
                return DailyRecommendationResponse(modelVersion: "v20", items: (300...399).map { item(Int64($0)) }, hasMore: true, nextCursor: "fourth")
            default:
                return response([item(400)])
            }
        }
        for date in [today, tomorrow] {
            await store.load(accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
                             fetchStars: { [repo(1)] }, fetchCandidates: page)
        }
        #expect(cursors == [nil, "second", "third", nil, "fourth"])
        #expect(store.visibleItems.map(\.repoID) == [400])
    }

    @Test("模型切换使游标过期时重查第一页，保留账号推荐历史")
    func expiredCursorRestartsWithoutLosingHistory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DailyRecommendationDiskStore(root: root)
        var saved = DailyRecommendationState()
        let day = DailyRecommendationState.dayKey(Date())
        saved.day = day
        saved.serviceScope = "test"
        saved.modelVersion = "old"
        saved.recommendedDays = ["100": "2026-1-1"]
        saved.candidatePool = DailyRecommendationCandidatePool(
            seedIDs: [1], serviceScope: "test", modelVersion: "old", checkedDay: day,
            items: [], hasMore: true, nextCursor: "old-cursor"
        )
        try await disk.save(saved, accountID: 42, revision: 0)
        let store = DailyRecommendationStore(disk: disk)
        var cursors: [String?] = []
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
            cursors.append(cursor)
            if cursor != nil { throw StarcatEnvelopeNetworkError.serverError(status: 409, code: "CURSOR_EXPIRED", message: "changed") }
            return DailyRecommendationResponse(modelVersion: "new", items: [item(100), item(101)])
        })
        #expect(cursors == ["old-cursor", nil])
        #expect(store.state.modelVersion == "new")
        #expect(store.visibleItems.map(\.repoID) == [101])
        #expect(store.state.recommendedDays == ["100": "2026-1-1"])
    }

    @Test("新候选耗尽时不拿历史项目补满卡槽")
    func exhaustedPoolDoesNotRepeat() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        let today = Date()
        await store.load(accountID: 42, scopeRevision: 1, date: today, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) })
        await store.markPresented(date: today)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        await store.load(accountID: 42, scopeRevision: 1, date: tomorrow, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) })
        #expect(store.visibleItems.isEmpty)
        #expect(store.emptyKey == "recommendations.daily.noNew")
    }

    @Test("旧快照缺少历史和候选池时保留偏好、反馈和翻牌进度")
    func legacySnapshotPreservesUserChoices() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = DailyRecommendationState()
        saved.items = [item(100)]
        saved.revealedIDs = [100]
        saved.dismissedIDs = [101]
        saved.showsOnLaunch = false
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "recommendedDays")
        json.removeValue(forKey: "candidatePool")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("42.json"))
        let store = DailyRecommendationStore(disk: DailyRecommendationDiskStore(root: root))
        await store.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(store.hasLoadedState)
        #expect(!store.state.showsOnLaunch)
        #expect(store.state.revealedIDs == [100])
        #expect(store.state.dismissedIDs == [101])
        #expect(store.state.recommendedDays.isEmpty)
        #expect(store.state.candidatePool == nil)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("daily-cards-\(UUID())")
    }

    private func response(_ items: [RepoRecommendationItem]) -> DailyRecommendationResponse {
        DailyRecommendationResponse(modelVersion: "v20", items: items)
    }

    private func item(_ id: Int64) -> RepoRecommendationItem {
        RepoRecommendationItem(
            repoID: id, fullName: "owner/repo\(id)", description: "Description",
            language: "Swift", stars: 10, forks: 0, archived: false, score: 1,
            source: "starcat_trained", reasons: ["costar"]
        )
    }

    private func repo(_ id: Int64) -> Repo {
        var value = item(id).dailyRecommendationRepo
        value.isStarred = true
        value.language = id.isMultiple(of: 2) ? "Swift" : "Go"
        value.starredAt = "2026-11-04"
        return value
    }
}
