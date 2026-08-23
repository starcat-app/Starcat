//
//  AwesomeRepositoryTests.swift
//  StarcatTests
//
//  验证 Awesome 本地优先仓储的关键数据边界：账户设置状态、ETag、订阅和跨来源去重。
//

import Foundation
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
        let sources = try await repository.refreshCatalog()

        #expect(sources.map(\.id) == ["one"])
        #expect(await api.catalogETags() == [nil, "catalog-1"])
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

    private static func source(id: String, order: Int) -> AwesomeSourceDTO {
        AwesomeSourceDTO(
            id: id,
            displayName: "Awesome \(id)",
            repoFullName: "example/awesome-\(id)",
            repoURL: "https://github.com/example/awesome-\(id)",
            imageURL: nil,
            summaryZH: "中文简介",
            summaryEN: "Summary",
            featured: order == 1,
            sortOrder: order,
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
}

private actor FakeAwesomeAPI: AwesomeAPIProtocol {
    private var catalog = AwesomeCatalogResult(sources: [], etag: nil, generatedAt: nil, notModified: false)
    private var entriesBySource: [String: AwesomeEntriesResult] = [:]
    private var receivedCatalogETags: [String?] = []

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

    func catalogETags() -> [String?] {
        receivedCatalogETags
    }

    func fetchAwesomeSources(ifNoneMatch: String?) async throws -> AwesomeCatalogResult {
        receivedCatalogETags.append(ifNoneMatch)
        return catalog
    }

    func fetchAwesomeEntries(sourceID: String, ifNoneMatch: String?) async throws -> AwesomeEntriesResult {
        entriesBySource[sourceID]
            ?? AwesomeEntriesResult(snapshot: nil, etag: ifNoneMatch, generatedAt: nil, notModified: true)
    }
}
