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

    @Test("未请求推荐也能保存自动展示偏好，重启与切换账号后各自恢复")
    func preferencesWithoutRecommendations() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await store.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(store.hasLoadedState)
        await store.setShowsOnLaunch(false)
        #expect(!store.state.showsOnLaunch)
        #expect(store.visibleItems.isEmpty)
        #expect(!store.isLoading)

        await switchHistoryAccount(99, root: root)
        await store.loadPreferences(accountID: 99, scopeRevision: 2)
        #expect(store.state.showsOnLaunch)
        await store.setShowsOnLaunch(true)
        await switchHistoryAccount(42, root: root)
        await store.loadPreferences(accountID: 42, scopeRevision: 3)
        #expect(!store.state.showsOnLaunch)

        let restored = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(!restored.state.showsOnLaunch)
        await switchHistoryAccount(99, root: root)
        await restored.loadPreferences(accountID: 99, scopeRevision: 2)
        #expect(restored.state.showsOnLaunch)
    }

    @Test("推荐请求等待或失败时仍能保存开关，不被请求完成覆盖")
    func preferencesWhileRequestIsPending() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var continuation: CheckedContinuation<DailyRecommendationResponse, Error>?
        let request = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test",
                fetchStars: { [repo(1)] },
                fetchCandidates: { _, _ in
                    try await withCheckedThrowingContinuation { continuation = $0 }
                }
            )
        }
        // 停在真实请求边界，验证开关可用性只取决于本地读盘，和网络加载状态无关
        while continuation == nil { await Task.yield() }
        #expect(store.isLoading)
        #expect(store.hasLoadedState)
        await store.setShowsOnLaunch(false)
        continuation?.resume(throwing: URLError(.notConnectedToInternet))
        _ = await request.value
        #expect(!store.state.showsOnLaunch)
        #expect(store.errorKey == "recommendations.daily.failed")

        let restored = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(!restored.state.showsOnLaunch)
    }

    @Test("重启恢复翻牌、屏蔽和自动展示记录，不重复请求当日候选")
    func restoreFrozenBatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let date = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] },
            fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        await store.reveal(100)
        await store.dismiss(101)
        await store.setShowsOnLaunch(false)
        #expect(!store.canAutomaticallyPresent(date: date))
        #expect(store.visibleItems.map(\.repoID) == [100])
        await store.setShowsOnLaunch(true)
        #expect(store.canAutomaticallyPresent(date: date))
        await store.markPresented(date: date)
        #expect(!store.canAutomaticallyPresent(date: date))
        await store.setShowsOnLaunch(false)
        let restored = makeStore(root: root)
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
        #expect(!restored.state.showsOnLaunch)
        #expect(!restored.canAutomaticallyPresent(date: date))
    }

    @Test("新的一天更新批次，屏蔽反馈继续保留")
    func nextDayKeepsFeedback() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
        let store = makeStore(root: root)
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
        let store = makeStore(root: root)
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
        await switchHistoryAccount(99, root: root)
        store.activate(accountID: 99, scopeRevision: 2)
        continuation?.resume(returning: response([item(100)]))
        _ = await task.value
        #expect(store.accountID == 99)
        #expect(store.visibleItems.isEmpty)
        #expect(!store.isLoading)
    }

    @Test("离线保留旧批次，但不能作为今日自动弹出")
    func offlineKeepsActualDay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
        #expect(!store.canAutomaticallyPresent())
    }

    @Test("损坏批次被隔离重建，SQLite 历史与负反馈完整保留")
    func corruptBatchDoesNotBlockHealthyHistory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var previous = DailyRecommendationState()
        previous.recommendedDays = ["100": "2026-11-4", "101": "2026-11-4"]
        previous.dismissedIDs = [101]
        try await saveHistoryFixture(previous, root: root)
        let file = root.appendingPathComponent("42.json")
        try Data("invalid".utf8).write(to: file)
        let store = makeStore(root: root)
        #expect(await store.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(store.historyEntries.count == 2)
        #expect(store.state.recommendedIDs == [100, 101])
        #expect(store.state.dismissedIDs == [101])
        #expect(try Data(contentsOf: root.appendingPathComponent("42.corrupt.json")) == Data("invalid".utf8))
        #expect(await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101), item(200)]) }
        ))
        #expect(store.errorKey == nil)
        #expect(store.visibleItems.map(\.repoID) == [200])
        await store.setShowsOnLaunch(false)
        let restarted = makeStore(root: root)
        #expect(await restarted.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(restarted.historyEntries.count == 2)
        #expect(restarted.state.dismissedIDs == [101])
        #expect(!restarted.state.showsOnLaunch)
    }

    @Test("固定种子和模型跨天展示新项目，当天重开和重启保留原批次")
    func historyKeepsDailyBatchesFresh() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
        let restored = makeStore(root: root)
        await restored.load(accountID: 42, scopeRevision: 2, date: tomorrow, serviceScope: "test",
                            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            Issue.record("重启后仍应恢复当天批次")
            return response([])
        })
        #expect(restored.visibleItems.map(\.repoID) == secondIDs)
        #expect(restored.state.recommendedDays.count == 20)
        await switchHistoryAccount(99, root: root)
        await restored.loadPreferences(accountID: 99, scopeRevision: 3)
        #expect(restored.state.recommendedDays.isEmpty)
    }

    @Test("未打开抽卡页不消耗历史，次日仍可推荐这批未展示项目")
    func prefetchDoesNotConsumeHistory() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
        try await saveHistoryFixture(saved, root: root)
        let store = makeStore(root: root, disk: disk)
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
        #expect(store.state.recommendedDays.count == 101)
    }

    @Test("补页预算耗尽后保存位置，重试继续后续页而不是回到第一页")
    func pageBudgetResumesCursor() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
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
        try await saveHistoryFixture(saved, root: root)
        let store = makeStore(root: root, disk: disk)
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
        try await saveHistoryFixture(saved, root: root)
        let store = makeStore(root: root, disk: disk)
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
        let store = makeStore(root: root)
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

    @Test("批次文件中的旧 ID-only 字段不能重新导入历史")
    func ignoresLegacyHistoryFields() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = DailyRecommendationState()
        saved.items = [item(100)]
        saved.revealedIDs = [100]
        saved.showsOnLaunch = false
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json["dismissedIDs"] = [101]
        json["recommendedDays"] = ["101": "2026-11-1"]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("42.json"))
        let store = makeStore(root: root)
        #expect(await store.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(!store.state.showsOnLaunch)
        #expect(store.state.revealedIDs == [100])
        #expect(store.historyEntries.isEmpty)
        #expect(store.state.dismissedIDs.isEmpty)
        #expect(store.state.recommendedDays.isEmpty)
    }

    @Test("主动换批使用未消费池，排除当前批次、完整 Stars 和反馈，成功才重置翻牌")
    func nextBatchUsesUnconsumedCandidates() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var legacy = DailyRecommendationState()
        legacy.dismissedIDs = [111]
        try await saveHistoryFixture(legacy, root: root)
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1), repo(110)] },
                         fetchCandidates: { _, _ in response((100...129).map { item(Int64($0)) }) })
        await store.reveal(100)
        await store.setShowsOnLaunch(false)
        // 不先登记历史，也必须排除当前整批，防止把重排当作换批。
        #expect(store.state.recommendedDays == ["111": ""])
        let replaced = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1), repo(110)] },
            fetchCandidates: { _, _ in
                Issue.record("未消费池足够时无需联网")
                return response([])
            }
        )
        #expect(replaced)
        #expect(store.visibleItems.map(\.repoID) == Array(112...121).map(Int64.init))
        #expect(store.state.revealedIDs.isEmpty)
        #expect(store.state.dismissedIDs == [111])
        #expect(!store.state.showsOnLaunch)
        #expect(store.state.recommendedDays == ["111": ""])
        await store.markPresented()
        #expect(store.state.recommendedIDs == Set(store.visibleItems.map(\.repoID)).union([111]))
    }

    @Test("换批沿 cursor 补取，历史和重复项目不回流，不足十张按实际数量展示")
    func nextBatchContinuesCursor() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var legacy = DailyRecommendationState()
        legacy.dismissedIDs = [901]
        try await saveHistoryFixture(legacy, root: root)
        let store = makeStore(root: root)
        var cursors: [String?] = []
        func page(_ seeds: [Int64], _ cursor: String?) async throws -> DailyRecommendationResponse {
            cursors.append(cursor)
            if cursor == nil {
                return DailyRecommendationResponse(
                    modelVersion: "v20", items: (100...109).map { item(Int64($0)) },
                    hasMore: true, nextCursor: "second"
                )
            }
            return response([item(100), item(1), item(901), item(110), item(110), item(111)])
        }
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: page)
        await store.markPresented()
        let replaced = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: page
        )
        #expect(replaced)
        #expect(cursors == [nil, "second"])
        #expect(store.visibleItems.map(\.repoID) == [110, 111])
        #expect(store.state.recommendedDays.count == 11)
    }

    @Test("整批都不感兴趣后仍能从未消费池换出新项目")
    func nextBatchAfterDismissingEveryCard() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] },
                         fetchCandidates: { _, _ in response((100...119).map { item(Int64($0)) }) })
        await store.markPresented()
        for id in 100...109 { await store.dismiss(Int64(id)) }
        #expect(store.visibleItems.isEmpty)
        let replaced = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                Issue.record("池中仍有未展示项目")
                return response([])
            }
        )
        #expect(replaced)
        #expect(store.visibleItems.map(\.repoID) == Array(110...119).map(Int64.init))
        #expect(store.state.dismissedIDs == Set((100...109).map(Int64.init)))
    }

    @Test("换批失败保留原卡与进度，重试仍从原 cursor 继续")
    func failedNextBatchPreservesProgress() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            DailyRecommendationResponse(
                modelVersion: "v20", items: (100...109).map { item(Int64($0)) },
                hasMore: true, nextCursor: "second"
            )
        })
        await store.reveal(100)
        await store.markPresented()
        let previousDate = store.state.generatedAt
        let replaced = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
                #expect(cursor == "second")
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(!replaced)
        #expect(store.visibleItems.map(\.repoID) == Array(100...109).map(Int64.init))
        #expect(store.state.revealedIDs == [100])
        #expect(store.state.generatedAt == previousDate)
        #expect(store.state.candidatePool?.nextCursor == "second")
        #expect(store.errorKey == "recommendations.daily.failed")
        #expect(store.retryReplacesCurrentBatch)
        let retried = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
                #expect(cursor == "second")
                return response([item(120)])
            }
        )
        #expect(retried)
        #expect(store.visibleItems.map(\.repoID) == [120])
        #expect(store.errorKey == nil)
    }

    @Test("换批耗尽保留原卡，重复操作不从第一页伪造新批次")
    func exhaustedNextBatchPreservesCards() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DailyRecommendationDiskStore(root: root)
        let store = makeStore(root: root, disk: disk)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) })
        await store.reveal(100)
        let previousDate = store.state.generatedAt
        for _ in 0..<2 {
            let replaced = await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                    Issue.record("已耗尽的池不能反复回到第一页")
                    return response([item(100)])
                }
            )
            #expect(!replaced)
            #expect(store.visibleItems.map(\.repoID) == [100])
            #expect(store.state.revealedIDs == [100])
            #expect(store.state.generatedAt == previousDate)
            #expect(store.batchMessageKey == "recommendations.daily.noNew")
        }
        let restored = makeStore(root: root, disk: disk)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(restored.visibleItems.map(\.repoID) == [100])
        #expect(restored.state.revealedIDs == [100])
    }

    @Test("换批补页预算耗尽保留旧批次，重试继续已保存的位置")
    func nextBatchPageBudgetResumes() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var cursors: [String?] = []
        func page(_ seeds: [Int64], _ cursor: String?) async throws -> DailyRecommendationResponse {
            cursors.append(cursor)
            if cursor == "page-5" { return response([item(120)]) }
            return DailyRecommendationResponse(
                modelVersion: "v20", items: (100...109).map { item(Int64($0)) },
                hasMore: true, nextCursor: "page-\(cursors.count + 1)"
            )
        }
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: page)
        await store.markPresented()
        await store.reveal(100)
        let replaced = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: page
        )
        #expect(!replaced)
        #expect(store.state.revealedIDs == [100])
        #expect(store.visibleItems.map(\.repoID) == Array(100...109).map(Int64.init))
        #expect(store.batchMessageKey == "recommendations.daily.continueSearch")
        #expect(store.state.candidatePool?.nextCursor == "page-5")
        let retried = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
            fetchStars: { [repo(1)] }, fetchCandidates: page
        )
        #expect(retried)
        #expect(cursors == [nil, "page-2", "page-3", "page-4", "page-5"])
        #expect(store.visibleItems.map(\.repoID) == [120])
        #expect(store.batchMessageKey == nil)
    }

    @Test("换批中切账号后丢弃旧响应")
    func nextBatchIgnoresPreviousAccount() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            DailyRecommendationResponse(modelVersion: "v20", items: (100...109).map { item(Int64($0)) },
                                        hasMore: true, nextCursor: "second")
        })
        // 当前池仅有已展示的一批，换批必须等待下一页的真实网络边界。
        var continuation: CheckedContinuation<DailyRecommendationResponse, Never>?
        let request = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                }
            )
        }
        while continuation == nil { await Task.yield() }
        await switchHistoryAccount(99, root: root)
        store.activate(accountID: 99, scopeRevision: 2)
        continuation?.resume(returning: response([item(120)]))
        #expect(await request.value == false)
        #expect(store.accountID == 99)
        #expect(store.visibleItems.isEmpty)
        #expect(!store.isLoading)
    }

    @Test("推荐依据只映射已知事实，不展示内部代码或伪造具体种子")
    func reasonPresentationUsesKnownEvidence() {
        let examples: [([String], DailyRecommendationReason)] = [
            (["基于公开 Star 共现关系"], .coStar),
            (["costar", "source_repo_id:42"], .coStar),
            (["基于仓库协同相似度"], .collaborative),
            (["基于公开 Star 热度"], .popularity),
            (["metadata_similarity"], .metadata),
            (["基于自研推荐模型"], .model),
            (["source_repo_id:42", "unknown-model:v2"], .unspecified),
            ([], .unspecified)
        ]
        for (reasons, expected) in examples {
            #expect(DailyRecommendationReason(reasons: reasons) == expected)
        }
    }

    @Test("整批都被 Star 后重开或重启仍是本批完成，不自动补换另一批", arguments: [false, true])
    func starredBatchRemainsFrozen(restarting: Bool) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let date = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                DailyRecommendationResponse(
                    modelVersion: "v20", items: [item(100)], hasMore: true, nextCursor: "second"
                )
            }
        )
        await store.excludeStarred([100])
        let reopened = restarting ? makeStore(root: root) : store
        await reopened.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1), repo(100)] }, fetchCandidates: { _, _ in
                Issue.record("当前批次已完成，重开不能自动生成新牌")
                return response([item(101)])
            }
        )
        #expect(reopened.visibleItems.isEmpty)
        #expect(reopened.state.hasGeneratedBatch)
        #expect(reopened.state.generatedAt == date)
        #expect(reopened.state.candidatePool?.nextCursor == "second")
    }

    @Test("次日请求失败也先移除旧缓存中已 Star 的项目")
    func failedRefreshFiltersOldBatch() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        await store.load(
            accountID: 42, scopeRevision: 1, date: yesterday, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1), repo(100)] }, fetchCandidates: { _, _ in
                throw URLError(.notConnectedToInternet)
            }
        )
        #expect(store.visibleItems.map(\.repoID) == [101])
        #expect(store.state.generatedAt == yesterday)
        #expect(store.errorKey == "recommendations.daily.failed")
        let restored = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(restored.visibleItems.map(\.repoID) == [101])
    }

    @Test("补页中途失败保存已取候选，重试从失败页继续")
    func partialFailurePreservesCursorAndCandidates() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var cursors: [String?] = []
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
                cursors.append(cursor)
                if cursor == nil {
                    return DailyRecommendationResponse(
                        modelVersion: "v20", items: (100...105).map { item(Int64($0)) },
                        hasMore: true, nextCursor: "second"
                    )
                }
                throw URLError(.networkConnectionLost)
            }
        )
        #expect(store.state.candidatePool?.nextCursor == "second")
        #expect(store.state.candidatePool?.items.count == 6)
        #expect(store.visibleItems.isEmpty)

        // 用新实例证明断点已落盘，而不是只保留在本次请求的局部变量里。
        let restored = makeStore(root: root)
        let retried = await restored.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, cursor in
                cursors.append(cursor)
                #expect(cursor == "second")
                return response((106...109).map { item(Int64($0)) })
            }
        )
        #expect(retried)
        #expect(cursors == [nil, "second", "second"])
        #expect(restored.visibleItems.map(\.repoID) == Array(100...109).map(Int64.init))
    }

    @Test("候选返回前刚 Star 的项目不能重新进入卡片")
    func starWhileLoadingIsExcluded() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var continuation: CheckedContinuation<DailyRecommendationResponse, Never>?
        let request = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test",
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                }
            )
        }
        while continuation == nil { await Task.yield() }
        await store.excludeStarred([1, 100])
        continuation?.resume(returning: response([item(100), item(101)]))
        _ = await request.value
        #expect(store.visibleItems.map(\.repoID) == [101])
    }

    @Test("手动看过今日批次后也不再自动展示，关闭开关不影响历史记录", arguments: [false, true])
    func manualPresentationConsumesDailyDisplay(autoShowEnabled: Bool) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let date = Date()
        await store.load(
            accountID: 42, scopeRevision: 1, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) }
        )
        await store.setShowsOnLaunch(autoShowEnabled)
        await store.markPresented(date: date)
        await store.setShowsOnLaunch(true)
        #expect(!store.canAutomaticallyPresent(date: date))
        #expect(store.state.recommendedIDs == [100])
        let restored = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(!restored.canAutomaticallyPresent(date: date))
    }

    @Test("保存失败后重试最新内存选择，恢复翻牌、屏蔽和偏好")
    func failedSaveCanRetryWithoutLosingChoices() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        await store.markPresented()
        // 仅在独立临时目录制造可复现写入失败，不依赖权限设置或真实账号文件。
        try FileManager.default.removeItem(at: root)
        try Data("blocked".utf8).write(to: root)
        await store.setShowsOnLaunch(false)
        await store.dismiss(101)
        await store.reveal(100)
        #expect(store.errorKey == "recommendations.daily.saveFailed")
        #expect(store.visibleItems.map(\.repoID) == [100])

        try FileManager.default.removeItem(at: root)
        await store.retrySaving()
        #expect(store.errorKey == nil)
        let restored = makeStore(root: root)
        await switchHistoryAccount(42, root: root)
        await restored.loadPreferences(accountID: 42, scopeRevision: 1)
        #expect(!restored.state.showsOnLaunch)
        #expect(restored.state.dismissedIDs == [101])
        #expect(restored.state.revealedIDs == [100])
        #expect(restored.state.recommendedIDs == [100, 101])
        #expect(restored.visibleItems.map(\.repoID) == [100])
    }

    @Test("请求期间新增 Star 的排除快照不跨账号泄漏")
    func liveExclusionIsAccountScoped() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var continuation: CheckedContinuation<DailyRecommendationResponse, Never>?
        let request = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test",
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                }
            )
        }
        while continuation == nil { await Task.yield() }
        await store.excludeStarred([1, 100])
        await switchHistoryAccount(99, root: root)
        store.activate(accountID: 99, scopeRevision: 2)
        await store.load(
            accountID: 99, scopeRevision: 2, serviceScope: "test",
            fetchStars: { [repo(2)] }, fetchCandidates: { _, _ in response([item(100)]) }
        )
        continuation?.resume(returning: response([item(101)]))
        _ = await request.value
        #expect(store.accountID == 99)
        #expect(store.visibleItems.map(\.repoID) == [100])
        #expect(store.errorKey == nil)
    }

    @Test("今日手动读昨日缓存不消费新批次的自动展示资格")
    func presentingOldCacheDoesNotConsumeToday() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        await store.load(
            accountID: 42, scopeRevision: 1, date: yesterday, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) }
        )
        await store.markPresented(date: today)
        #expect(store.state.autoPresentedDay.isEmpty)
        #expect(!store.canAutomaticallyPresent(date: today))
        await store.load(
            accountID: 42, scopeRevision: 1, date: today, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101)]) }
        )
        #expect(store.visibleItems.map(\.repoID) == [101])
        #expect(store.canAutomaticallyPresent(date: today))
    }

    @Test("无公开种子时不发请求，补 Star 后重试可以生成真实批次")
    func coldStartRecoversAfterStarring() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [] }, fetchCandidates: { _, _ in
                Issue.record("没有公开种子不应请求个性化推荐")
                return response([])
            }
        )
        #expect(store.emptyKey == "recommendations.daily.coldStart")
        #expect(!store.state.hasGeneratedBatch)
        #expect(!store.canAutomaticallyPresent())
        let prepared = await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { seeds, _ in
                #expect(seeds == [1])
                return response([item(100)])
            }
        )
        #expect(prepared)
        #expect(store.state.hasGeneratedBatch)
        #expect(store.visibleItems.map(\.repoID) == [100])
        #expect(store.canAutomaticallyPresent())
    }

    @Test("来源仅接受当前公开种子，并随历史保存而不依赖后续 Star")
    func persistsRealSourceEvidence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var candidate = item(100)
        let source = RecommendationSeed(repoID: 1, fullName: "wrong/name", description: nil,
                                        language: nil, reasons: ["costar"])
        candidate.matchedSeeds = [source, source,
            RecommendationSeed(repoID: 999, fullName: "unrelated/project", description: nil,
                               language: nil, reasons: nil)]
        let page = response([candidate])
        #expect(await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                                 fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in page }))
        let sources = try #require(store.visibleItems.first?.matchedSeeds)
        #expect(sources.count == 1)
        #expect(sources.first?.fullName == "owner/repo1")
        await store.markPresented()
        let restored = makeStore(root: root)
        #expect(await restored.loadPreferences(accountID: 42, scopeRevision: 1))
        #expect(restored.historyEntries.first?.item?.matchedSeeds == sources)
        #expect(restored.historyEntries.first?.item?.basicRecommendationReason.contains("owner/repo1") == true)
    }

    @Test("初始批次等待整批理由准备，预取不登记历史或消耗展示资格")
    func waitsForBatchPreparation() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var waiting: CheckedContinuation<Void, Never>?
        let preparation = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test",
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100), item(101)]) },
                prepareItems: { items in
                    #expect(items.map(\.repoID) == [100, 101])
                    await withCheckedContinuation { waiting = $0 }
                }
            )
        }
        while waiting == nil { await Task.yield() }
        #expect(store.isLoading)
        #expect(store.visibleItems.isEmpty)
        #expect(!store.canAutomaticallyPresent())
        #expect(store.historyEntries.isEmpty)
        waiting?.resume()
        #expect(await preparation.value)
        #expect(store.visibleItems.map(\.repoID) == [100, 101])
        #expect(store.canAutomaticallyPresent())
        #expect(store.state.autoPresentedDay.isEmpty)
        #expect(store.historyEntries.isEmpty)
    }

    @Test("换批准备期间保留旧卡，准备后再次过滤刚 Star 的项目")
    func keepsCurrentBatchUntilReasonsReady() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            response((100...119).map { item(Int64($0)) })
        })
        await store.markPresented()
        let oldIDs = store.visibleItems.map(\.repoID)
        var waiting: CheckedContinuation<Void, Never>?
        let preparation = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                    Issue.record("应直接使用尚未消费的候选")
                    return response([])
                },
                prepareItems: { items in
                    #expect(items.map(\.repoID) == (110...119).map(Int64.init))
                    await withCheckedContinuation { waiting = $0 }
                }
            )
        }
        while waiting == nil { await Task.yield() }
        #expect(store.visibleItems.map(\.repoID) == oldIDs)
        #expect(store.historyEntries.count == 10)
        await store.excludeStarred([1, 110])
        waiting?.resume()
        #expect(await preparation.value)
        #expect(store.visibleItems.map(\.repoID) == (111...119).map(Int64.init))
        #expect(store.historyEntries.count == 10)
        await store.markPresented()
        #expect(store.historyEntries.count == 19)
    }

    @Test("当天缓存批次仍经过理由恢复，不再次请求推荐")
    func cachedBatchStillPreparesReasons() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) })
        let restored = makeStore(root: root)
        var preparedIDs: [Int64] = []
        #expect(await restored.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
                Issue.record("当天缓存不能重复请求")
                return response([])
            }, prepareItems: { preparedIDs = $0.map(\.repoID) }
        ))
        #expect(preparedIDs == [100])
        #expect(restored.historyEntries.isEmpty)
    }

    @Test("理由准备期间取消或切账号不替换批次", arguments: [false, true])
    func cancelledPreparationDoesNotReplaceBatch(switchAccount: Bool) async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        var waiting: CheckedContinuation<Void, Never>?
        let preparation = Task {
            await store.load(
                accountID: 42, scopeRevision: 1, serviceScope: "test",
                fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(100)]) },
                prepareItems: { _ in await withCheckedContinuation { waiting = $0 } }
            )
        }
        while waiting == nil { await Task.yield() }
        if switchAccount {
            await switchHistoryAccount(99, root: root)
            store.activate(accountID: 99, scopeRevision: 2)
        } else {
            preparation.cancel()
        }
        waiting?.resume()
        #expect(!(await preparation.value))
        #expect(store.visibleItems.isEmpty)
        #expect(store.historyEntries.isEmpty)
    }

    @Test("宿主关闭传递取消至独立换批任务，不替换已展示批次")
    func hostCancellationReachesReplacement() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        await store.load(accountID: 42, scopeRevision: 1, serviceScope: "test",
                         fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in
            response((100...119).map { item(Int64($0)) })
        })
        await store.markPresented()
        let preparation = DailyRecommendationPreparation()
        var waiting: CheckedContinuation<Void, Never>?
        let caller = Task {
            await preparation.run(key: "replacement", origin: .user) {
                await store.load(
                    accountID: 42, scopeRevision: 1, serviceScope: "test", replacingCurrentBatch: true,
                    fetchStars: { [repo(1)] }, fetchCandidates: { _, _ in response([item(200)]) },
                    prepareItems: { _ in await withCheckedContinuation { waiting = $0 } }
                )
            }
        }
        while waiting == nil { await Task.yield() }
        // 与 Host 关闭分支相同；即使 Provider 暂不响应取消，迟到结果也不能替换当前批次。
        preparation.cancelUserPreparation()
        caller.cancel()
        waiting?.resume()
        #expect(!(await caller.value))
        #expect(store.visibleItems.map(\.repoID) == (100...109).map(Int64.init))
        #expect(Set(store.historyEntries.map(\.id)) == Set((100...109).map(Int64.init)))
        #expect(!preparation.isRunning)
    }

    @Test("手动关闭不取消已经共享的后台预取")
    func closingDoesNotCancelBackgroundPreparation() async {
        let preparation = DailyRecommendationPreparation()
        var waiting: CheckedContinuation<Void, Never>?
        var shared = false
        let background = Task {
            await preparation.run(key: "today", origin: .background) {
                await withCheckedContinuation { waiting = $0 }
                return !Task.isCancelled
            }
        }
        while waiting == nil { await Task.yield() }
        let manual = Task {
            shared = true
            return await preparation.run(key: "today", origin: .user) {
                Issue.record("同一批次不能重复准备")
                return false
            }
        }
        while !shared { await Task.yield() }
        preparation.cancelUserPreparation()
        manual.cancel()
        waiting?.resume()
        #expect(await background.value)
        _ = await manual.value
        #expect(!preparation.isRunning)
    }

    /// 同一测试重启 Store 时复用磁盘库；切账号显式模拟 AppDependencies 的数据库切换。
    private let historyDatabases = HistoryTestDatabases()

    private func makeStore(root: URL, disk: DailyRecommendationDiskStore? = nil) -> DailyRecommendationStore {
        let database: HistoryTestDatabase
        if let existing = historyDatabases.values[root] {
            database = existing
        } else {
            database = try! HistoryTestDatabase()
            historyDatabases.values[root] = database
        }
        return DailyRecommendationStore(disk: disk ?? DailyRecommendationDiskStore(root: root),
                                        history: RecommendationHistoryRepository(database: database))
    }

    private func switchHistoryAccount(_ id: Int64, root: URL) async {
        try! await historyDatabases.values[root]?.reopen(userId: id)
    }

    /// 历史测试直接写完整数据库快照，不能依赖已经移除的开发期 JSON 导入。
    private func saveHistoryFixture(_ state: DailyRecommendationState, root: URL) async throws {
        if historyDatabases.values[root] == nil { historyDatabases.values[root] = try HistoryTestDatabase() }
        let repository = RecommendationHistoryRepository(database: historyDatabases.values[root]!)
        for id in state.recommendedIDs.union(state.dismissedIDs) {
            try await repository.record([item(id)], day: state.recommendedDays[String(id)] ?? "",
                                        date: Date(timeIntervalSince1970: 0), batchID: "fixture", accountID: 42)
            if state.dismissedIDs.contains(id) { try await repository.setDismissed(true, id: id, accountID: 42) }
        }
        try await DailyRecommendationDiskStore(root: root).save(state, accountID: 42, revision: 1)
    }

    @MainActor
    private final class HistoryTestDatabases {
        var values: [URL: HistoryTestDatabase] = [:]
    }

    /// 各账号拥有独立队列，测试重新创建 Store 时保留同一数据库，避免删除仍打开的 WAL 文件。
    private final class HistoryTestDatabase: DatabaseManaging, @unchecked Sendable {
        private var current: InMemoryDatabaseManager
        private var accounts: [Int64?: InMemoryDatabaseManager]
        var currentUserId: Int64? { current.currentUserId }
        var databasePath: String? { nil }
        var writer: any DatabaseWriter { current.writer }
        init() throws {
            let initial = try InMemoryDatabaseManager(userId: 42)
            current = initial
            accounts = [42: initial]
        }
        @MainActor
        func reopen(userId: Int64?) async throws {
            if let existing = accounts[userId] { current = existing; return }
            let next = try InMemoryDatabaseManager(userId: userId)
            accounts[userId] = next
            current = next
        }
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
