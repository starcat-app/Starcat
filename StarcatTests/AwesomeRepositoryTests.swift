//
//  AwesomeRepositoryTests.swift
//  StarcatTests
//
//  验证 Awesome 本地优先仓储的关键数据边界：账户设置状态、ETag、订阅和跨来源去重。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Awesome Repository")
struct AwesomeRepositoryTests {

    @Test("完成来源选择允许零选中并持久化首次设置状态")
    func setupCanCompleteWithZeroSelection() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        #expect(await repository.hasCompletedSourceSetup() == false)

        try await repository.completeSourceSetup(enabledSourceIDs: [])

        #expect(await repository.hasCompletedSourceSetup())
        #expect(await repository.enabledSources().isEmpty)
    }

    @Test("精选目录 304 保留缓存并发送已有 ETag")
    func catalogNotModifiedRetainsCachedSources() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())
        _ = try await repository.refreshCatalog()

        await api.setCatalogNotModified(etag: "catalog-1")
        let sources = try await repository.refreshCatalog(policy: .force)

        #expect(sources.map(\.id) == ["one"])
        #expect(sources.first?.sourceStars == 9_012)
        #expect(sources.first?.lastSyncedAt == ISO8601DateFormatter.githubDate(from: "2026-08-24T08:00:00Z"))
        #expect(await api.catalogETags() == [nil, "catalog-1"])
    }

    @Test("六小时内自动刷新完全复用本地目录和条目")
    func freshCacheSkipsAutomaticNetworkRequests() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [Self.entry(repoID: 42, title: "Cached")])
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let repository = AwesomeRepository(
            api: api,
            database: try InMemoryDatabaseManager(),
            now: { now }
        )

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        _ = try await repository.refreshCatalog()
        #expect(await repository.refreshEnabledEntries().isEmpty)

        #expect(await api.catalogETags() == [nil])
        #expect(await api.entryETags(sourceID: "one") == [nil])
        #expect(await repository.repositories(sourceID: "one").map(\.id) == [42])
    }

    @Test("缓存过期后使用 ETag 后台校验并由 304 推进检查时间")
    func staleCacheUsesConditionalRequests() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [Self.entry(repoID: 42, title: "Cached")])
        let database = try InMemoryDatabaseManager()
        let initial = Date(timeIntervalSince1970: 1_777_000_000)
        let first = AwesomeRepository(api: api, database: database, now: { initial })

        _ = try await first.refreshCatalog()
        try await first.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await first.refreshEnabledEntries().isEmpty)

        await api.setCatalogNotModified(etag: "catalog-1")
        await api.setEntriesNotModified(sourceID: "one", etag: "entries-one")
        let expired = initial.addingTimeInterval(7 * 60 * 60)
        let second = AwesomeRepository(api: api, database: database, now: { expired })

        _ = try await second.refreshCatalog()
        #expect(await second.refreshEnabledEntries().isEmpty)
        #expect(await api.catalogETags() == [nil, "catalog-1"])
        #expect(await api.entryETags(sourceID: "one") == [nil, "entries-one"])

        #expect(await second.refreshEnabledEntries().isEmpty)
        #expect(await api.entryETags(sourceID: "one") == [nil, "entries-one"])
    }

    @Test("手动刷新绕过六小时新鲜缓存")
    func manualRefreshBypassesFreshCache() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [Self.entry(repoID: 42, title: "Cached")])
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let repository = AwesomeRepository(
            api: api,
            database: try InMemoryDatabaseManager(),
            now: { now }
        )

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        await api.setCatalogNotModified(etag: "catalog-1")
        await api.setEntriesNotModified(sourceID: "one", etag: "entries-one")
        _ = try await repository.refreshCatalog(policy: .force)
        #expect(await repository.refreshEnabledEntries(policy: .force).isEmpty)

        #expect(await api.catalogETags() == [nil, "catalog-1"])
        #expect(await api.entryETags(sourceID: "one") == [nil, "entries-one"])
    }

    @Test("同序精选来源按稳定 ID 排序")
    func managedSourcesUseStableIDAsTieBreaker() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([
            Self.source(id: "z-source", order: 1, displayName: "A source"),
            Self.source(id: "a-source", order: 1, displayName: "Z source")
        ], etag: "catalog-1")
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()

        #expect(await repository.sources().map(\.id) == ["a-source", "z-source"])
    }

    @Test("全部 Awesome 按 GitHub Repo ID 去重并保留多来源证据")
    func aggregateDeduplicatesAndPreservesEvidence() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([
            Self.source(id: "one", order: 1),
            Self.source(id: "two", order: 2)
        ], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [Self.entry(repoID: 42, title: "First")])
        await api.setEntries(sourceID: "two", entries: [Self.entry(repoID: 42, title: "Second")])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one", "two"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        let repos = await repository.repositories(sourceID: nil)
        #expect(repos.count == 1)
        #expect(repos.first?.id == 42)
        #expect(repos.first?.updatedAt == ISO8601DateFormatter.githubDate(from: "2026-08-23T12:34:56Z"))
        #expect(repos.first?.evidence.map(\.source.id) == ["one", "two"])
        #expect(await repository.repositories(sourceID: "one").first?.evidence.count == 1)
    }

    @Test("同序条目证据按来源 ID 稳定排序")
    func evidenceUsesSourceIDAsFinalTieBreaker() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([
            Self.source(id: "z-source", order: 1),
            Self.source(id: "a-source", order: 1)
        ], etag: "catalog-1")
        await api.setEntries(sourceID: "z-source", entries: [Self.entry(repoID: 42, title: "Z")])
        await api.setEntries(sourceID: "a-source", entries: [Self.entry(repoID: 42, title: "A")])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["z-source", "a-source"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        #expect(await repository.repositories(sourceID: nil).first?.evidence.map(\.source.id) == ["a-source", "z-source"])
    }

    @Test("单来源刷新失败保留上次成功条目")
    func failedEntryRefreshKeepsPreviousSnapshot() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [Self.entry(repoID: 42, title: "Cached")])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await repository.refreshEnabledEntries().isEmpty)
        await api.setEntryError(sourceID: "one")

        #expect(await repository.refreshEnabledEntries(policy: .force)["one"] != nil)
        #expect(await repository.repositories(sourceID: "one").first?.fullName == "owner/repo")
    }

    @Test("精选目录替换保留自定义来源和订阅")
    func catalogRefreshPreservesCustomSource() async throws {
        let api = FakeAwesomeAPI()
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())
        let custom = Self.customSource()
        try await repository.saveCustomSource(custom, entries: [Self.entry(repoID: 7, title: "Custom")])
        await api.setCatalog([Self.source(id: "managed", order: 1)], etag: "catalog-1")

        _ = try await repository.refreshCatalog()

        #expect(await repository.sources().map(\.id) == ["managed", custom.id])
        #expect(await repository.enabledSources().map(\.id) == [custom.id])
        #expect(await repository.repositories(sourceID: custom.id).first?.id == 7)
    }

    @Test("自定义来源确认保存后仍等待 Sheet 完成才启用")
    func customSourceWaitsForSubscriptionCommit() async throws {
        let repository = AwesomeRepository(api: FakeAwesomeAPI(), database: try InMemoryDatabaseManager())
        let custom = Self.customSource(isEnabled: false)

        try await repository.saveCustomSource(custom, entries: [Self.entry(repoID: 7, title: "Custom")])
        #expect(await repository.sources().map(\.id) == [custom.id])
        #expect(await repository.enabledSources().isEmpty)

        try await repository.updateSubscriptions(enabledSourceIDs: [custom.id])
        #expect(await repository.enabledSources().map(\.id) == [custom.id])
    }

    @Test("首次配置状态按账户数据库隔离")
    func setupStateIsIsolatedByAccountDatabase() async throws {
        let first = AwesomeRepository(api: FakeAwesomeAPI(), database: try InMemoryDatabaseManager())
        let second = AwesomeRepository(api: FakeAwesomeAPI(), database: try InMemoryDatabaseManager())

        try await first.completeSourceSetup(enabledSourceIDs: [])

        #expect(await first.hasCompletedSourceSetup())
        #expect(await second.hasCompletedSourceSetup() == false)
    }

    @Test("删除自定义来源不删除已 Star 仓库")
    func removingCustomSourceDoesNotDeleteStarredRepository() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO repos (id, owner, name, full_name, html_url) VALUES (?, ?, ?, ?, ?)",
                arguments: [7, "owner", "repo", "owner/repo", "https://github.com/owner/repo"]
            )
        }
        let repository = AwesomeRepository(api: FakeAwesomeAPI(), database: database)
        let custom = Self.customSource()
        try await repository.saveCustomSource(custom, entries: [Self.entry(repoID: 7, title: "Custom")])

        try await repository.removeCustomSource(id: custom.id)

        let starredCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repos WHERE id = 7") ?? 0
        }
        #expect(starredCount == 1)
        #expect(await repository.sources().isEmpty)
    }

    private static func source(id: String, order: Int, displayName: String? = nil) -> AwesomeSourceDTO {
        AwesomeSourceDTO(
            id: id,
            displayName: displayName ?? "Awesome \(id)",
            repoFullName: "example/awesome-\(id)",
            repoURL: "https://github.com/example/awesome-\(id)",
            imageURL: nil,
            summaryZH: "中文简介",
            summaryEN: "Summary",
            featured: order == 1,
            sortOrder: order,
            sourceStars: 9_012,
            githubRepoCount: 1,
            externalEntryCount: 0,
            lastSyncedAt: "2026-08-24T08:00:00Z",
            updatedAt: "2026-08-24T08:00:00Z"
        )
    }

    private static func entry(repoID: Int64, title: String) -> AwesomeEntryDTO {
        AwesomeEntryDTO(
            ghRepoID: repoID,
            owner: "owner",
            name: "repo",
            fullName: "owner/repo",
            description: "Official description",
            ownerAvatar: "https://avatars.githubusercontent.com/u/1?v=4",
            language: "Swift",
            stars: 100,
            isArchived: false,
            updatedAt: "2026-08-23T12:34:56Z",
            entryTitle: title,
            entryDescription: "Source description",
            sectionPath: ["Tools"],
            entryOrder: 1,
            sourceAnchorURL: "https://github.com/example/list#tools"
        )
    }

    private static func customSource(isEnabled: Bool = true) -> AwesomeSource {
        AwesomeSource(
            id: "custom:example/list",
            kind: .custom,
            displayName: "Custom List",
            repoFullName: "example/list",
            repoURL: URL(string: "https://github.com/example/list")!,
            imageURL: nil,
            summaryZH: nil,
            summaryEN: "Custom source",
            featured: false,
            sortOrder: .max,
            sourceStars: 321,
            githubRepoCount: 1,
            externalEntryCount: 0,
            isAvailable: true,
            isEnabled: isEnabled,
            addedAt: Date(timeIntervalSince1970: 1),
            lastSyncedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor FakeAwesomeAPI: AwesomeAPIProtocol {
    private var catalog = AwesomeCatalogResult(sources: [], etag: nil, generatedAt: nil, notModified: false)
    private var entriesBySource: [String: AwesomeEntriesResult] = [:]
    private var failingEntrySources: Set<String> = []
    private var receivedCatalogETags: [String?] = []
    private var receivedEntryETags: [String: [String?]] = [:]

    func setCatalog(_ sources: [AwesomeSourceDTO], etag: String) {
        catalog = AwesomeCatalogResult(
            sources: sources,
            etag: etag,
            generatedAt: "2026-08-24T08:00:00Z",
            notModified: false
        )
    }

    func setCatalogNotModified(etag: String) {
        catalog = AwesomeCatalogResult(sources: [], etag: etag, generatedAt: nil, notModified: true)
    }

    func setEntries(sourceID: String, entries: [AwesomeEntryDTO]) {
        entriesBySource[sourceID] = AwesomeEntriesResult(
            snapshot: AwesomeEntriesSnapshotDTO(
                source: AwesomeEntriesSourceDTO(
                    id: sourceID,
                    displayName: sourceID,
                    updatedAt: "2026-08-24T08:00:00Z"
                ),
                entries: entries
            ),
            etag: "entries-\(sourceID)",
            generatedAt: "2026-08-24T08:00:00Z",
            notModified: false
        )
    }

    func setEntryError(sourceID: String) {
        failingEntrySources.insert(sourceID)
    }

    func setEntriesNotModified(sourceID: String, etag: String) {
        entriesBySource[sourceID] = AwesomeEntriesResult(
            snapshot: nil,
            etag: etag,
            generatedAt: nil,
            notModified: true
        )
    }

    func catalogETags() -> [String?] {
        receivedCatalogETags
    }

    func entryETags(sourceID: String) -> [String?] {
        receivedEntryETags[sourceID] ?? []
    }

    func fetchAwesomeSources(ifNoneMatch: String?) async throws -> AwesomeCatalogResult {
        receivedCatalogETags.append(ifNoneMatch)
        return catalog
    }

    func fetchAwesomeEntries(sourceID: String, ifNoneMatch: String?) async throws -> AwesomeEntriesResult {
        receivedEntryETags[sourceID, default: []].append(ifNoneMatch)
        if failingEntrySources.contains(sourceID) {
            throw FakeAwesomeAPIError.unavailable
        }
        return entriesBySource[sourceID]
            ?? AwesomeEntriesResult(snapshot: nil, etag: ifNoneMatch, generatedAt: nil, notModified: true)
    }
}

private enum FakeAwesomeAPIError: Error {
    case unavailable
}
