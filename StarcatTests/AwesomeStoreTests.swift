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

    @Test("Awesome Store 首屏只加载四十条并在页尾预取下一页")
    @MainActor
    func repositoryListLoadsIncrementalPages() async {
        let source = Self.source(id: "large", isEnabled: true, githubRepoCount: 95)
        let items = (1 ... 95).map { Self.repositoryItem(id: Int64($0), source: source) }
        let repository = AwesomeStoreRepositoryFake(
            sources: [source],
            repositoriesBySource: [source.id: items]
        )
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        store.selectSource(source.id)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(store.repositories.count == 40)
        #expect(store.repositoryTotalCount == 95)
        #expect(store.hasMoreRepositories)

        await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: 20)
        #expect(store.repositories.count == 40)

        await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: 31)
        #expect(store.repositories.count == 80)
        #expect(store.hasMoreRepositories)

        await store.loadAllRepositoryPages()
        #expect(store.repositories.count == 95)
        #expect(!store.hasMoreRepositories)
    }

    @Test("选中来源只改变中栏计数而侧栏全量计数保持稳定")
    @MainActor
    func selectedSourceKeepsAllRepositoryCountStable() async throws {
        let selected = Self.source(id: "selected", isEnabled: true, githubRepoCount: 130)
        let other = Self.source(id: "other", isEnabled: true, githubRepoCount: 200)
        let repository = AwesomeStoreRepositoryFake(
            sources: [selected, other],
            repositoriesBySource: [
                selected.id: [
                    Self.repositoryItem(id: 1, source: selected),
                    Self.repositoryItem(id: 2, source: selected)
                ],
                other.id: [Self.repositoryItem(id: 3, source: other)]
            ]
        )
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.loadAwesome()
        store.selectSource(selected.id)
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.repositories.count == 2)
        #expect(store.allRepositoryCount == 330)
        #expect(store.currentRepositoryCount == 130)
    }

    @Test("来源总数与中栏同时包含 GitHub 仓库和资源条目")
    @MainActor
    func sourceCountsAndVisibleItemsIncludeResources() async throws {
        let source = Self.source(
            id: "resources",
            isEnabled: true,
            githubRepoCount: 1,
            externalEntryCount: 2,
            resourceEntryCount: 3
        )
        let repository = AwesomeStoreRepositoryFake(
            sources: [source],
            repositoriesBySource: [source.id: [Self.repositoryItem(id: 1, source: source)]],
            resourcesBySource: [source.id: [Self.resourceItem(source: source)]]
        )
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.loadAwesome()
        store.selectSource(source.id)
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.allRepositoryCount == 6)
        #expect(store.currentRepositoryCount == 6)
        #expect(store.repositories.count == 1)
        #expect(store.resources.map(\.title) == ["External resource"])
    }

    @Test("Awesome 多选只切换批量集合而单选才打开详情")
    @MainActor
    func awesomeSelectionPolicyUsesSharedMultiSelectionStore() {
        let source = Self.source()
        let repo = Self.repositoryItem(id: 42, source: source)
        let repository = AwesomeStoreRepositoryFake(sources: [source])
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)
        let multiStore = MultiSelectionStore()

        multiStore.enter()
        AwesomeListSelectionPolicy.select(repo, awesomeStore: store, multiSelectionStore: multiStore)
        #expect(multiStore.contains(ghRepoId: repo.id))
        #expect(store.selectedRepositoryID == nil)

        AwesomeListSelectionPolicy.select(repo, awesomeStore: store, multiSelectionStore: multiStore)
        #expect(!multiStore.contains(ghRepoId: repo.id))

        multiStore.exit()
        AwesomeListSelectionPolicy.select(repo, awesomeStore: store, multiSelectionStore: multiStore)
        #expect(store.selectedRepositoryID == repo.id)
    }

    @Test("Awesome 仓库遵守探索全局筛选")
    func awesomeRepositoriesUseGlobalFilters() {
        let repo = Self.repositoryItem(id: 42, source: Self.source(), language: "Swift")
        let neutralFacts = AwesomeGlobalFilterFacts(
            isStarred: true,
            isInLibrary: true,
            wikiAvailability: true,
            hasHealthData: true,
            hasOpenSSFData: true
        )
        let matchingOptions = AwesomeGlobalFilterOptions(
            hideArchived: true,
            hideForks: true,
            starFilter: .starred,
            libraryFilter: .inLibrary,
            languages: ["swift"],
            wikiFilter: .available,
            healthFilter: .available,
            openSSFFilter: .available
        )

        #expect(AwesomeGlobalFilterPolicy.matches(repo, options: matchingOptions, facts: neutralFacts))

        let languageMismatch = AwesomeGlobalFilterOptions(
            hideArchived: false,
            hideForks: false,
            starFilter: .all,
            libraryFilter: .all,
            languages: ["Rust"],
            wikiFilter: .unknown,
            healthFilter: .unknown,
            openSSFFilter: .unknown
        )
        #expect(!AwesomeGlobalFilterPolicy.matches(repo, options: languageMismatch, facts: neutralFacts))

        let missingWikiFacts = AwesomeGlobalFilterFacts(
            isStarred: true,
            isInLibrary: true,
            wikiAvailability: nil,
            hasHealthData: true,
            hasOpenSSFData: true
        )
        #expect(!AwesomeGlobalFilterPolicy.matches(repo, options: matchingOptions, facts: missingWikiFacts))
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

    @Test("来源管理刷新只强制更新目录")
    @MainActor
    func sourceManagerRefreshDoesNotRefreshEntries() async {
        let repository = AwesomeStoreRepositoryFake(sources: [Self.source()])
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        await store.refreshSourceCatalog()

        #expect(await repository.catalogRefreshPolicies() == [.force])
        #expect(await repository.entryRefreshPolicies().isEmpty)
        #expect(!store.isCatalogRefreshing)
        #expect(store.ogPrefetchGeneration == 1)
    }

    @Test("自定义来源核验后立即启用并进入来源列表")
    @MainActor
    func customSourceIsImmediatelyEnabledAfterValidation() async throws {
        let repository = AwesomeStoreRepositoryFake(sources: [])
        let service = AwesomeCustomSourceService(github: AwesomeStoreGitHubFake(), repository: repository)
        let store = AwesomeStore(repository: repository, customSourceService: service)

        let custom = try await store.addCustomSource(input: "example/awesome-one")

        #expect(store.sources.map(\.id) == [custom.id])
        #expect(store.enabledSources.map(\.id) == [custom.id])
        #expect(store.customSourceParseStates[custom.id] != nil)
    }

    @Test("来源选择列表不会展示零项目来源")
    @MainActor
    func sourcePickerHidesZeroRepositorySources() {
        let available = Self.source(id: "available", githubRepoCount: 12)
        let empty = Self.source(id: "empty", githubRepoCount: 0)

        let defaultResults = AwesomeSourceManagerSheet.filterSources(
            [empty, available],
            query: "",
            languageCode: "zh"
        )
        let searchResults = AwesomeSourceManagerSheet.filterSources(
            [empty, available],
            query: "awesome-one",
            languageCode: "zh"
        )

        #expect(defaultResults.map(\.id) == ["available"])
        #expect(searchResults.map(\.id) == ["available"])
    }

    private static func source(
        id: String = "one",
        kind: AwesomeSourceKind = .managed,
        isEnabled: Bool = false,
        githubRepoCount: Int = 1,
        externalEntryCount: Int = 0,
        resourceEntryCount: Int = 0
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
            sourceForks: 812,
            sourceWatchers: 9_012,
            sourceSubscribers: 73,
            sourceOpenIssues: 28,
            sourceLanguage: "Swift",
            languageBytes: ["Swift": 900, "Shell": 100],
            githubRepoCount: githubRepoCount,
            externalEntryCount: externalEntryCount,
            resourceEntryCount: resourceEntryCount,
            isAvailable: true,
            isEnabled: isEnabled,
            addedAt: Date(timeIntervalSince1970: 0),
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func repositoryItem(
        id: Int64,
        source: AwesomeSource,
        language: String? = "Swift"
    ) -> AwesomeRepositoryItem {
        AwesomeRepositoryItem(
            id: id,
            owner: "example",
            name: "repo-\(id)",
            fullName: "example/repo-\(id)",
            description: nil,
            ownerAvatarURL: nil,
            language: language,
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

    private static func resourceItem(source: AwesomeSource) -> AwesomeResourceItem {
        AwesomeResourceItem(
            id: "resource:one",
            targetType: .externalResource,
            title: "External resource",
            description: "README evidence",
            url: URL(string: "https://example.com/resource")!,
            evidence: AwesomeEntryEvidence(
                source: source,
                entryTitle: "External resource",
                entryDescription: "README evidence",
                sectionPath: ["Resources"],
                entryOrder: 1,
                sourceAnchorURL: nil
            )
        )
    }
}

private actor AwesomeStoreRepositoryFake: AwesomeRepositoryProtocol {
    private var sourceValues: [AwesomeSource]
    private let repositoriesBySource: [String: [AwesomeRepositoryItem]]
    private let resourcesBySource: [String: [AwesomeResourceItem]]
    private let delaysBySource: [String: UInt64]
    private let setupDelayNanoseconds: UInt64
    private var setupCompleted = false
    private var catalogPolicies: [AwesomeRefreshPolicy] = []
    private var entryPolicies: [AwesomeRefreshPolicy] = []

    init(
        sources: [AwesomeSource],
        repositoriesBySource: [String: [AwesomeRepositoryItem]] = [:],
        resourcesBySource: [String: [AwesomeResourceItem]] = [:],
        delaysBySource: [String: UInt64] = [:],
        setupDelayNanoseconds: UInt64 = 0
    ) {
        sourceValues = sources
        self.repositoriesBySource = repositoriesBySource
        self.resourcesBySource = resourcesBySource
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
    func repositoryPage(sourceID: String?, limit: Int, offset: Int) async -> AwesomeRepositoryPage {
        let all = await repositories(sourceID: sourceID)
        let page = Array(all.dropFirst(offset).prefix(limit))
        return AwesomeRepositoryPage(
            repositories: page,
            totalCount: all.count,
            hasMore: offset + page.count < all.count
        )
    }
    func resources(sourceID: String?) async -> [AwesomeResourceItem] {
        guard let sourceID else { return resourcesBySource.values.flatMap { $0 } }
        return resourcesBySource[sourceID] ?? []
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

    func saveCustomSource(
        _ source: AwesomeSource,
        entries: [AwesomeEntryDTO],
        parseState: AwesomeCustomSourceParseState
    ) async throws {
        sourceValues.append(source)
    }

    func customSourceParseStates() async -> [AwesomeCustomSourceParseState] { [] }
    func updateCustomSourceParseState(_ state: AwesomeCustomSourceParseState) async throws {}
    func customSourceEntryFullNames(sourceID: String) async -> Set<String> { [] }
    func customSourceEntryCount(sourceID: String) async -> Int { 0 }
    func saveCustomSourceEntries(
        _ entries: [AwesomeEntryDTO],
        sourceID: String,
        parseState: AwesomeCustomSourceParseState
    ) async throws {}
    func completeCustomSourceParsing(
        sourceID: String,
        externalEntryCount: Int,
        parseState: AwesomeCustomSourceParseState
    ) async throws {}

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
                sourceForks: source.sourceForks,
                sourceWatchers: source.sourceWatchers,
                sourceSubscribers: source.sourceSubscribers,
                sourceOpenIssues: source.sourceOpenIssues,
                sourceLanguage: source.sourceLanguage,
                languageBytes: source.languageBytes,
                githubRepoCount: source.githubRepoCount,
                externalEntryCount: source.externalEntryCount,
                resourceEntryCount: source.resourceEntryCount,
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
        GitHubRepoDTO(
            id: 1,
            name: repo,
            fullName: "\(owner)/\(repo)",
            owner: GitHubUserDTO(id: 1, login: owner, name: nil, avatarUrl: nil),
            description: "Description",
            language: "Swift",
            stargazersCount: 10,
            forksCount: 1,
            watchersCount: 10,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(repo)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: 0,
            defaultBranch: "main",
            disabled: false,
            isTemplate: false,
            score: nil
        )
    }

    func awesomeReadme(owner: String, repo: String) async throws -> Data {
        Data()
    }
}
