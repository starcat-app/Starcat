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

    @Test("后台加载不弹来源选择，用户点击才弹出且完成后停止弹出")
    @MainActor
    func firstSetupOnlyCompletesFromDoneAction() async throws {
        let repository = AwesomeStoreRepositoryFake(sources: [Self.source()])
        let service = AwesomeCustomSourceService(
            github: AwesomeStoreGitHubFake(),
            repository: repository
        )
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.loadAwesome()
        #expect(!store.isSourceManagerPresented)

        await store.enterAwesomeFromUserSelection()
        #expect(store.isSourceManagerPresented)

        store.dismissSourceManager()
        await store.enterAwesomeFromUserSelection()
        #expect(store.isSourceManagerPresented)

        try await store.completeSourceSelection([])
        #expect(!store.isSourceManagerPresented)
        #expect(store.hasCompletedSourceSetup)

        await store.enterAwesomeFromUserSelection()
        #expect(!store.isSourceManagerPresented)
    }

    @Test("页面自动加载与分类点击并发时不会吞掉首次来源选择")
    @MainActor
    func concurrentLifecycleLoadKeepsUserPresentationIntent() async throws {
        let repository = AwesomeStoreRepositoryFake(
            sources: [Self.source()],
            setupDelayNanoseconds: 50_000_000
        )
        let service = AwesomeCustomSourceService(
            github: AwesomeStoreGitHubFake(),
            repository: repository
        )
        let store = AwesomeStore(repository: repository, customSourceService: service)

        let userSelection = Task { await store.enterAwesomeFromUserSelection() }
        try await Task.sleep(for: .milliseconds(5))
        await store.loadAwesome()
        await userSelection.value

        #expect(store.isSourceManagerPresented)
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

        await store.loadAwesome()
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

    @Test("进入页面遵守缓存策略而手动刷新强制绕过 TTL")
    @MainActor
    func manualRefreshForcesRepositoryPolicy() async {
        let repository = AwesomeStoreRepositoryFake(sources: [Self.source()])
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.loadAwesome()
        await store.refresh()

        #expect(await repository.catalogRefreshPolicies() == [.ifStale, .force])
        #expect(await repository.entryRefreshPolicies() == [.ifStale, .force])
    }

    @Test("自定义来源保存后立即启用并进入来源列表")
    @MainActor
    func customSourceIsImmediatelyEnabledAfterSave() async throws {
        let repository = AwesomeStoreRepositoryFake(sources: [])
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)
        let custom = Self.source(id: "custom:example/awesome-one", kind: .custom, isEnabled: true)
        let preview = AwesomeCustomSourcePreview(source: custom, entries: [])

        try await store.addCustomSource(preview)

        #expect(store.sources.map(\.id) == [custom.id])
        #expect(store.enabledSources.map(\.id) == [custom.id])
    }

    private static func source(
        id: String = "one",
        kind: AwesomeSourceKind = .managed,
        isEnabled: Bool = false
    ) -> AwesomeSource {
        AwesomeSource(
            id: id,
            kind: kind,
            displayName: "Awesome One",
            repoFullName: "example/awesome-one",
            repoURL: URL(string: "https://github.com/example/awesome-one")!,
            repoDescription: "GitHub source description",
            imageURL: nil,
            summaryZH: "测试来源",
            summaryEN: "Test source",
            featured: true,
            sortOrder: 1,
            sourceStars: 9_012,
            githubRepoCount: 1,
            externalEntryCount: 0,
            isAvailable: true,
            isEnabled: isEnabled,
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
    private let setupDelayNanoseconds: UInt64
    private var setupCompleted = false
    private var catalogPolicies: [AwesomeRefreshPolicy] = []
    private var entryPolicies: [AwesomeRefreshPolicy] = []

    init(
        sources: [AwesomeSource],
        repositoriesBySource: [String: [AwesomeRepositoryItem]] = [:],
        delaysBySource: [String: UInt64] = [:],
        setupDelayNanoseconds: UInt64 = 0
    ) {
        sourceValues = sources
        self.repositoriesBySource = repositoriesBySource
        self.delaysBySource = delaysBySource
        self.setupDelayNanoseconds = setupDelayNanoseconds
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
    func hasCompletedSourceSetup() async -> Bool {
        if setupDelayNanoseconds > 0 {
            // 模拟不响应父任务取消的数据库读取，稳定覆盖并发加载时序。
            await Task.detached {
                try? await Task.sleep(nanoseconds: self.setupDelayNanoseconds)
            }.value
        }
        return setupCompleted
    }
    func refreshCatalog(policy: AwesomeRefreshPolicy) async throws -> [AwesomeSource] {
        catalogPolicies.append(policy)
        return sourceValues
    }
    func refreshEnabledEntries(policy: AwesomeRefreshPolicy) async -> [String: String] {
        entryPolicies.append(policy)
        return [:]
    }
    func catalogRefreshPolicies() -> [AwesomeRefreshPolicy] { catalogPolicies }
    func entryRefreshPolicies() -> [AwesomeRefreshPolicy] { entryPolicies }

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
                repoDescription: source.repoDescription,
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
