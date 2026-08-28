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
        #expect(sources.first?.repoDescription == "GitHub source description")
        #expect(sources.first?.sourceStars == 9_012)
        #expect(sources.first?.sourceForks == 812)
        #expect(sources.first?.sourceSubscribers == 73)
        #expect(sources.first?.languageBytes == ["Swift": 900, "Shell": 100])
        #expect(sources.first?.lastSyncedAt == ISO8601DateFormatter.githubDate(from: "2026-08-24T08:00:00Z"))
        #expect(await api.catalogETags() == [nil, "catalog-1"])
    }

    @Test("精选目录缺少语言字段仍能保存真实描述")
    func catalogMissingLanguageBytesPersistsDescription() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog(
            [Self.source(id: "one", order: 1, languageBytes: nil)],
            etag: "catalog-1"
        )
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        let sources = try await repository.refreshCatalog()

        #expect(sources.first?.repoDescription == "GitHub source description")
        #expect(sources.first?.languageBytes == [:])
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
        #expect(repos.first?.forks == 7)
        #expect(repos.first?.watchers == 80)
        #expect(repos.first?.subscribers == 9)
        #expect(repos.first?.openIssues == 3)
        #expect(repos.first?.topics == ["swift", "tooling"])
        #expect(repos.first?.createdAt == ISO8601DateFormatter.githubDate(from: "2020-01-02T03:04:05Z"))
        #expect(repos.first?.updatedAt == ISO8601DateFormatter.githubDate(from: "2026-08-23T12:34:56Z"))
        #expect(repos.first?.evidence.map(\.source.id) == ["one", "two"])
        #expect(await repository.repositories(sourceID: "one").first?.evidence.count == 1)
    }

    @Test("Awesome 仓库分页按去重结果返回真实总数与后续页")
    func repositoryPagesUseDistinctRepositoryIDs() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([
            Self.source(id: "one", order: 1, githubRepoCount: 55),
            Self.source(id: "two", order: 2, githubRepoCount: 2)
        ], etag: "catalog-1")
        await api.setEntries(
            sourceID: "one",
            entries: (1 ... 55).map { Self.entry(repoID: Int64($0), title: "Repo \($0)", order: $0) }
        )
        await api.setEntries(sourceID: "two", entries: [
            Self.entry(repoID: 1, title: "Duplicate", order: 1),
            Self.entry(repoID: 56, title: "Repo 56", order: 2)
        ])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one", "two"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        let first = await repository.repositoryPage(sourceID: nil, limit: 40, offset: 0)
        let second = await repository.repositoryPage(sourceID: nil, limit: 40, offset: 40)

        #expect(first.repositories.count == 40)
        #expect(first.totalCount == 56)
        #expect(first.hasMore)
        #expect(second.repositories.map(\.id) == Array(41 ... 56).map(Int64.init))
        #expect(second.totalCount == 56)
        #expect(!second.hasMore)
        #expect(first.repositories.first?.evidence.map(\.source.id) == ["one", "two"])
    }

    @Test("章节目录使用轻量查询返回完整顺序")
    func repositorySectionsDoNotDependOnLoadedPage() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1, githubRepoCount: 2)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [
            Self.entry(repoID: 1, title: "First", order: 1, sectionPath: ["Apps", "Editors"]),
            Self.entry(repoID: 2, title: "Second", order: 2, sectionPath: ["Tools"])
        ])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        #expect(await repository.repositorySections(sourceID: "one") == ["Apps / Editors", "Tools"])
        #expect(await repository.repositorySections(sourceID: nil).isEmpty)
    }

    @Test("远端资源条目不会进入只接纳 GitHub 仓库的本地缓存")
    func remoteResourcesAreDroppedAtPersistenceBoundary() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([
            Self.source(
                id: "resources",
                order: 1,
                githubRepoCount: 0,
                externalEntryCount: 1,
                resourceEntryCount: 1
            )
        ], etag: "catalog-1")
        await api.setEntries(sourceID: "resources", entries: [
            Self.resourceEntry(
                type: .externalResource,
                title: "Design resource",
                url: "https://getdesign.md/resource",
                order: 1
            ),
            Self.resourceEntry(
                type: .repositoryResource,
                title: "Cursor rule",
                url: "https://github.com/PatrickJS/awesome-cursorrules/blob/main/rules/swift.md",
                order: 2
            )
        ])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["resources"])
        #expect(await repository.refreshEnabledEntries().isEmpty)

        #expect(await repository.repositories(sourceID: "resources").isEmpty)
        #expect(await repository.resources(sourceID: "resources").isEmpty)
        #expect(await repository.sources().first?.totalEntryCount == 0)
    }

    @Test("远端下架内置来源会清理条目缓存但保留用户订阅状态")
    func unavailableManagedSourceClearsRebuildableEntries() async throws {
        let api = FakeAwesomeAPI()
        await api.setCatalog([Self.source(id: "one", order: 1)], etag: "catalog-1")
        await api.setEntries(sourceID: "one", entries: [
            Self.entry(repoID: 42, title: "Cached"),
            Self.resourceEntry(
                type: .externalResource,
                title: "Legacy resource",
                url: "https://example.com/resource",
                order: 2
            )
        ])
        let repository = AwesomeRepository(api: api, database: try InMemoryDatabaseManager())

        _ = try await repository.refreshCatalog()
        try await repository.completeSourceSetup(enabledSourceIDs: ["one"])
        #expect(await repository.refreshEnabledEntries().isEmpty)
        #expect(await repository.repositories(sourceID: "one").count == 1)

        await api.setCatalog([], etag: "catalog-2")
        _ = try await repository.refreshCatalog(policy: .force)

        let source = await repository.sources().first
        #expect(source?.isAvailable == false)
        #expect(source?.isEnabled == true)
        #expect(source?.totalEntryCount == 0)
        #expect(await repository.repositories(sourceID: "one").isEmpty)
        #expect(await repository.resources(sourceID: "one").isEmpty)
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

    @Test("自定义来源与初始解析状态在同一事务持久化")
    func customSourcePersistsInitialParseState() async throws {
        let repository = AwesomeRepository(api: FakeAwesomeAPI(), database: try InMemoryDatabaseManager())
        let custom = Self.customSource()
        let queued = AwesomeCustomSourceParseState(
            sourceID: custom.id,
            phase: .queued,
            processedCount: 0,
            totalCount: nil,
            errorMessage: nil,
            updatedAt: Date(timeIntervalSince1970: 123)
        )

        try await repository.saveCustomSource(custom, entries: [], parseState: queued)

        #expect(await repository.sources().map(\.id) == [custom.id])
        #expect(await repository.customSourceParseStates() == [queued])
    }

    @Test("自定义来源解析状态可独立更新")
    func customSourceParseStateCanUpdate() async throws {
        let repository = AwesomeRepository(api: FakeAwesomeAPI(), database: try InMemoryDatabaseManager())
        let custom = Self.customSource()
        try await repository.saveCustomSource(custom, entries: [])
        let failed = AwesomeCustomSourceParseState(
            sourceID: custom.id,
            phase: .failed,
            processedCount: 4,
            totalCount: 10,
            errorMessage: "rate limited",
            updatedAt: Date(timeIntervalSince1970: 456)
        )

        try await repository.updateCustomSourceParseState(failed)

        #expect(await repository.customSourceParseStates() == [failed])
    }

    @Test("自定义来源增量条目与完成状态原子更新")
    func customSourceIncrementalEntriesUpdateCounts() async throws {
        let completedAt = Date(timeIntervalSince1970: 789)
        let repository = AwesomeRepository(
            api: FakeAwesomeAPI(),
            database: try InMemoryDatabaseManager(),
            now: { completedAt }
        )
        let custom = Self.customSource(lastSyncedAt: nil)
        try await repository.saveCustomSource(custom, entries: [], parseState: AwesomeCustomSourceParseState(
            sourceID: custom.id,
            phase: .queued,
            processedCount: 0,
            totalCount: nil,
            errorMessage: nil,
            updatedAt: .distantPast
        ))
        #expect(await repository.sources().first?.lastSyncedAt == nil)
        let progress = AwesomeCustomSourceParseState(
            sourceID: custom.id,
            phase: .enrichingRepositories,
            processedCount: 1,
            totalCount: 2,
            errorMessage: nil,
            updatedAt: completedAt
        )

        try await repository.saveCustomSourceEntries(
            [Self.entry(repoID: 7, title: "Custom")],
            sourceID: custom.id,
            parseState: progress
        )
        #expect(await repository.sources().first?.githubRepoCount == 1)
        #expect(await repository.customSourceEntryFullNames(sourceID: custom.id) == ["owner/repo"])

        let completed = AwesomeCustomSourceParseState(
            sourceID: custom.id,
            phase: .completed,
            processedCount: 2,
            totalCount: 2,
            errorMessage: nil,
            updatedAt: completedAt
        )
        try await repository.completeCustomSourceParsing(
            sourceID: custom.id,
            externalEntryCount: 3,
            parseState: completed
        )

        #expect(await repository.sources().first?.externalEntryCount == 3)
        #expect(await repository.sources().first?.lastSyncedAt == completedAt)
        #expect(await repository.customSourceParseStates() == [completed])
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

    private static func source(
        id: String,
        order: Int,
        displayName: String? = nil,
        languageBytes: [String: Int]? = ["Swift": 900, "Shell": 100],
        githubRepoCount: Int = 1,
        externalEntryCount: Int = 0,
        resourceEntryCount: Int = 0
    ) -> AwesomeSourceDTO {
        AwesomeSourceDTO(
            id: id,
            displayName: displayName ?? "Awesome \(id)",
            repoFullName: "example/awesome-\(id)",
            repoURL: "https://github.com/example/awesome-\(id)",
            repoDescription: "GitHub source description",
            imageURL: nil,
            summaryZH: "中文简介",
            summaryEN: "Summary",
            featured: order == 1,
            sortOrder: order,
            sourceStars: 9_012,
            sourceForks: 812,
            sourceWatchers: 9_012,
            sourceSubscribers: 73,
            sourceOpenIssues: 28,
            sourceLanguage: "Swift",
            languageBytes: languageBytes,
            githubRepoCount: githubRepoCount,
            externalEntryCount: externalEntryCount,
            resourceEntryCount: resourceEntryCount,
            lastSyncedAt: "2026-08-24T08:00:00Z",
            updatedAt: "2026-08-24T08:00:00Z"
        )
    }

    private static func entry(
        repoID: Int64,
        title: String,
        order: Int = 1,
        sectionPath: [String] = ["Tools"]
    ) -> AwesomeEntryDTO {
        AwesomeEntryDTO(
            ghRepoID: repoID,
            owner: "owner",
            name: "repo",
            fullName: "owner/repo",
            description: "Official description",
            ownerAvatar: "https://avatars.githubusercontent.com/u/1?v=4",
            homepage: "https://example.com/repo",
            language: "Swift",
            stars: 100,
            forks: 7,
            watchers: 80,
            subscribers: 9,
            openIssues: 3,
            defaultBranch: "main",
            licenseSpdx: "MIT",
            topics: ["swift", "tooling"],
            isArchived: false,
            isFork: false,
            pushedAt: "2026-08-23T11:00:00Z",
            updatedAt: "2026-08-23T12:34:56Z",
            createdAt: "2020-01-02T03:04:05Z",
            entryTitle: title,
            entryDescription: "Source description",
            sectionPath: sectionPath,
            entryOrder: order,
            sourceAnchorURL: "https://github.com/example/list#tools"
        )
    }

    private static func resourceEntry(
        type: AwesomeEntryTargetType,
        title: String,
        url: String,
        order: Int
    ) -> AwesomeEntryDTO {
        AwesomeEntryDTO(
            ghRepoID: nil,
            owner: "",
            name: "",
            fullName: "",
            description: nil,
            ownerAvatar: nil,
            homepage: nil,
            language: nil,
            stars: 0,
            forks: 0,
            watchers: 0,
            subscribers: 0,
            openIssues: 0,
            defaultBranch: "",
            licenseSpdx: nil,
            topics: [],
            isArchived: false,
            isFork: false,
            pushedAt: nil,
            updatedAt: "",
            createdAt: "",
            entryTitle: title,
            entryDescription: "README evidence",
            sectionPath: ["Resources"],
            entryOrder: order,
            sourceAnchorURL: nil,
            targetType: type,
            rawURL: url
        )
    }

    private static func customSource(
        isEnabled: Bool = true,
        lastSyncedAt: Date? = Date(timeIntervalSince1970: 1)
    ) -> AwesomeSource {
        AwesomeSource(
            id: "custom:example/list",
            kind: .custom,
            displayName: "Custom List",
            repoFullName: "example/list",
            repoURL: URL(string: "https://github.com/example/list")!,
            repoDescription: "Custom GitHub description",
            imageURL: nil,
            summaryZH: nil,
            summaryEN: "Custom source",
            featured: false,
            sortOrder: .max,
            sourceStars: 321,
            sourceForks: 12,
            sourceWatchers: 321,
            sourceSubscribers: 5,
            sourceOpenIssues: 2,
            sourceLanguage: "Swift",
            languageBytes: ["Swift": 1],
            githubRepoCount: 1,
            externalEntryCount: 0,
            resourceEntryCount: 0,
            isAvailable: true,
            isEnabled: isEnabled,
            addedAt: Date(timeIntervalSince1970: 1),
            lastSyncedAt: lastSyncedAt,
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
