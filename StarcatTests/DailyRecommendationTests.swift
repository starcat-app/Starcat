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
            fetchCandidates: { _ in response([item(100), item(101)]) }
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
            fetchCandidates: { _ in
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
            fetchStars: { [repo(1)] }, fetchCandidates: { _ in response([item(100)]) }
        )
        await store.dismiss(100)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        await store.load(
            accountID: 42, scopeRevision: 1, date: tomorrow, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _ in response([item(100), item(101)]) }
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
            fetchStars: { [repo(1)] }, fetchCandidates: { _ in response([]) }
        )
        await store.load(
            accountID: 42, scopeRevision: 2, date: date, serviceScope: "test",
            fetchStars: { [repo(1)] },
            fetchCandidates: { _ in
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
                fetchCandidates: { _ in
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
            fetchStars: { [repo(1)] }, fetchCandidates: { _ in response([item(100)]) }
        )
        await store.load(
            accountID: 42, scopeRevision: 1, serviceScope: "test",
            fetchStars: { [repo(1)] }, fetchCandidates: { _ in throw URLError(.notConnectedToInternet) }
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
            fetchStars: { [] }, fetchCandidates: { _ in response([]) }
        )
        #expect(store.errorKey != nil)
        #expect(try Data(contentsOf: file) == Data("invalid".utf8))
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
