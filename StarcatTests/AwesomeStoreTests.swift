//
//  AwesomeStoreTests.swift
//  StarcatTests
//
//  验证 Awesome 三栏共享状态的首次配置和账户切换边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Awesome Store")
struct AwesomeStoreTests {

    @Test("取消首次来源选择后再次进入仍自动弹出，完成零选择后停止弹出")
    @MainActor
    func firstSetupOnlyCompletesFromDoneAction() async throws {
        let repository = AwesomeStoreRepositoryFake(sources: [Self.source()])
        let service = AwesomeCustomSourceService(
            github: AwesomeStoreGitHubFake(),
            repository: repository
        )
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.enterAwesome()
        #expect(store.isSourceManagerPresented)

        store.dismissSourceManager()
        await store.enterAwesome()
        #expect(store.isSourceManagerPresented)

        try await store.completeSourceSelection([])
        #expect(!store.isSourceManagerPresented)
        #expect(store.hasCompletedSourceSetup)

        await store.enterAwesome()
        #expect(!store.isSourceManagerPresented)
    }

    @Test("账户数据库切换立即清除旧账户来源与选择")
    @MainActor
    func accountResetClearsVisibleSnapshot() async {
        let repository = AwesomeStoreRepositoryFake(sources: [Self.source()])
        let service = AwesomeCustomSourceService(
            github: AwesomeStoreGitHubFake(),
            repository: repository
        )
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.enterAwesome()
        store.selectedSourceID = "one"
        store.selectedRepositoryID = 42
        store.resetForAccountChange()

        #expect(store.sources.isEmpty)
        #expect(store.repositories.isEmpty)
        #expect(store.selectedSourceID == nil)
        #expect(store.selectedRepositoryID == nil)
        #expect(!store.hasCompletedSourceSetup)
    }

    @Test("快速切换来源时同步更新高亮且旧结果不能覆盖新来源")
    @MainActor
    func rapidSourceSelectionKeepsNewestResult() async throws {
        let first = Self.source(id: "one")
        let second = Self.source(id: "two")
        let repository = AwesomeStoreRepositoryFake(
            sources: [first, second],
            repositoriesBySource: [
                first.id: [Self.repositoryItem(id: 1, source: first)],
                second.id: [Self.repositoryItem(id: 2, source: second)]
            ],
            delaysBySource: [first.id: 150_000_000]
        )
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        store.selectSource(first.id)
        #expect(store.selectedSourceID == first.id)
        store.selectSource(second.id)
        #expect(store.selectedSourceID == second.id)
        try await Task.sleep(for: .milliseconds(250))

        #expect(store.selectedSourceID == second.id)
        #expect(store.repositories.map(\.id) == [2])
    }

    private static func source(id: String = "one") -> AwesomeSource {
        AwesomeSource(
            id: id,
            kind: .managed,
            displayName: "Awesome One",
            repoFullName: "example/awesome-one",
            repoURL: URL(string: "https://github.com/example/awesome-one")!,
            imageURL: nil,
            summaryZH: "测试来源",
            summaryEN: "Test source",
            featured: true,
            sortOrder: 1,
            sourceStars: 9_012,
            githubRepoCount: 1,
            externalEntryCount: 0,
            isAvailable: true,
            isEnabled: false,
            addedAt: Date(timeIntervalSince1970: 0),
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func repositoryItem(id: Int64, source: AwesomeSource) -> AwesomeRepositoryItem {
        AwesomeRepositoryItem(
            id: id,
            owner: "example",
            name: "repo-\(id)",
            fullName: "example/repo-\(id)",
            description: nil,
            ownerAvatarURL: nil,
            language: "Swift",
            stars: Int(id),
            isArchived: false,
            updatedAt: nil,
            evidence: [AwesomeEntryEvidence(
                source: source,
                entryTitle: "Repo \(id)",
                entryDescription: nil,
                sectionPath: [],
                entryOrder: 0,
                sourceAnchorURL: nil
            )]
        )
    }
}

private actor AwesomeStoreRepositoryFake: AwesomeRepositoryProtocol {
    private var sourceValues: [AwesomeSource]
    private let repositoriesBySource: [String: [AwesomeRepositoryItem]]
    private let delaysBySource: [String: UInt64]
    private var setupCompleted = false

    init(
        sources: [AwesomeSource],
        repositoriesBySource: [String: [AwesomeRepositoryItem]] = [:],
        delaysBySource: [String: UInt64] = [:]
    ) {
        sourceValues = sources
        self.repositoriesBySource = repositoriesBySource
        self.delaysBySource = delaysBySource
    }

    func sources() async -> [AwesomeSource] { sourceValues }
    func enabledSources() async -> [AwesomeSource] { sourceValues.filter(\.isEnabled) }
    func repositories(sourceID: String?) async -> [AwesomeRepositoryItem] {
        if let sourceID, let nanoseconds = delaysBySource[sourceID] {
            // 模拟不响应父任务取消的底层读取，验证 Store 自己的代际检查。
            await Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }.value
        }
        guard let sourceID else { return repositoriesBySource.values.flatMap { $0 } }
        return repositoriesBySource[sourceID] ?? []
    }
    func hasCompletedSourceSetup() async -> Bool { setupCompleted }
    func refreshCatalog() async throws -> [AwesomeSource] { sourceValues }
    func refreshEnabledEntries() async -> [String: String] { [:] }

    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws {
        setupCompleted = true
        applySubscriptions(enabledSourceIDs)
    }

    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws {
        applySubscriptions(enabledSourceIDs)
    }

    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws {
        sourceValues.append(source)
    }

    func removeCustomSource(id: String) async throws {
        sourceValues.removeAll { $0.id == id }
    }

    private func applySubscriptions(_ enabledSourceIDs: Set<String>) {
        sourceValues = sourceValues.map { source in
            AwesomeSource(
                id: source.id,
                kind: source.kind,
                displayName: source.displayName,
                repoFullName: source.repoFullName,
                repoURL: source.repoURL,
                imageURL: source.imageURL,
                summaryZH: source.summaryZH,
                summaryEN: source.summaryEN,
                featured: source.featured,
                sortOrder: source.sortOrder,
                sourceStars: source.sourceStars,
                githubRepoCount: source.githubRepoCount,
                externalEntryCount: source.externalEntryCount,
                isAvailable: source.isAvailable,
                isEnabled: enabledSourceIDs.contains(source.id),
                addedAt: source.addedAt,
                lastSyncedAt: source.lastSyncedAt,
                updatedAt: source.updatedAt
            )
        }
    }
}

private actor AwesomeStoreGitHubFake: AwesomeGitHubClientProtocol {
    func awesomeRepository(owner: String, repo: String) async throws -> GitHubRepoDTO {
        throw NetworkError.notFound
    }

    func awesomeReadme(owner: String, repo: String) async throws -> Data {
        throw NetworkError.notFound
    }
}
