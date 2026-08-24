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

    private static func source() -> AwesomeSource {
        AwesomeSource(
            id: "one",
            kind: .managed,
            displayName: "Awesome One",
            repoFullName: "example/awesome-one",
            repoURL: URL(string: "https://github.com/example/awesome-one")!,
            imageURL: nil,
            summaryZH: "测试来源",
            summaryEN: "Test source",
            featured: true,
            sortOrder: 1,
            githubRepoCount: 1,
            externalEntryCount: 0,
            isAvailable: true,
            isEnabled: false,
            addedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private actor AwesomeStoreRepositoryFake: AwesomeRepositoryProtocol {
    private var sourceValues: [AwesomeSource]
    private var setupCompleted = false

    init(sources: [AwesomeSource]) {
        sourceValues = sources
    }

    func sources() async -> [AwesomeSource] { sourceValues }
    func enabledSources() async -> [AwesomeSource] { sourceValues.filter(\.isEnabled) }
    func repositories(sourceID: String?) async -> [AwesomeRepositoryItem] { [] }
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
                githubRepoCount: source.githubRepoCount,
                externalEntryCount: source.externalEntryCount,
                isAvailable: source.isAvailable,
                isEnabled: enabledSourceIDs.contains(source.id),
                addedAt: source.addedAt,
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
