//
//  SearchCenterViewModelTests.swift
//  StarcatTests
//
//  覆盖搜索浮层关闭/重开时的会话恢复契约。关闭只是隐藏 UI，不能清空已产生的
//  本地或远端结果，也不能让用户因为误点遮罩而重复消耗搜索请求。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Center ViewModel")
@MainActor
struct SearchCenterViewModelTests {
    @Test("发现专属卡片的知识库状态同步刷新当前结果、重开及缓存")
    func discoveryLibraryChangesUpdateSnapshotsAndCache() async throws {
        let candidate = Self.makeCandidate(id: 9, owner: "web", name: "tool")
        let discovery = SearchCenterStubDiscoveryService(results: [Self.makeDiscoveryResult(candidate: candidate)])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        let persisted = Repo(
            id: 9, owner: "web", name: "tool", fullName: "web/tool", description: nil, language: nil,
            starsCount: 10, forksCount: 1, watchersCount: 1, topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/web/tool", cloneUrl: nil, sshUrl: nil, isPrivate: false, isFork: false, isArchived: false,
            isStarred: false, pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
        viewModel.query = "find a project"
        await viewModel.submit()
        viewModel.updateRepositoryLibraryState(identity: candidate.identity, state: .inLibrary, persistedRepo: persisted)
        viewModel.dismiss()
        viewModel.present()
        #expect(try Self.firstRepository(in: viewModel).card.isInLibrary == true)
        await viewModel.submit()
        #expect(try Self.firstRepository(in: viewModel).card.isInLibrary == true)
        #expect(try Self.firstRepository(in: viewModel).localRepo?.id == 9)

        viewModel.updateRepositoryLibraryState(identity: candidate.identity, state: .outsideLibrary, persistedRepo: nil)
        #expect(try Self.firstRepository(in: viewModel).card.isInLibrary == false)
        await viewModel.submit()
        #expect(try Self.firstRepository(in: viewModel).card.isInLibrary == false)
        #expect(try Self.firstRepository(in: viewModel).localRepo?.id == 9)
        #expect(discovery.requests.count == 1)
    }

    @Test("知识库操作后迟到的发现卡片不能覆盖已确认状态")
    func lateDiscoveryResultKeepsConfirmedLibraryState() async throws {
        let candidate = Self.makeCandidate(id: 9, owner: "web", name: "tool")
        let discovery = SearchCenterStubDiscoveryService(results: [Self.makeDiscoveryResult(candidate: candidate)])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        discovery.onDiscover = {
            viewModel.updateRepositoryLibraryState(identity: candidate.identity, state: .inLibrary, persistedRepo: nil)
        }
        viewModel.query = "find a project"
        await viewModel.submit()
        #expect(try Self.firstRepository(in: viewModel).card.isInLibrary == true)
    }

    @Test("发现网页资料卡遵守展示开关，仓库证据与缓存仍保留", arguments: [false, true])
    func discoveryReferencesRespectDisplaySetting(includeWeb: Bool) async throws {
        let initial = Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "web", name: "tool"))
        let url = URL(string: "https://example.org/article")!
        let result = RepositoryDiscoveryResult(
            session: initial.session, repositories: initial.repositories,
            references: [ReferenceCandidate(
                normalizedURL: url, originalURL: url, title: "Project introduction",
                snippet: "Public project evidence", domain: "example.org", source: .web
            )],
            diagnostics: []
        )
        let discovery = SearchCenterStubDiscoveryService(results: [result])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            includeWebInAll: { includeWeb },
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        viewModel.query = "find a project"
        await viewModel.submit()
        #expect(viewModel.candidates.count == (includeWeb ? 2 : 1))
        if case .repository(let candidate) = viewModel.candidates.first {
            #expect(viewModel.evidence(for: candidate).map(\.id) == ["web-0-0"])
        } else {
            Issue.record("Expected the discovered repository and its evidence")
        }
        await viewModel.submit()
        #expect(viewModel.candidates.count == (includeWeb ? 2 : 1))
        #expect(discovery.requests.count == 1)
    }

    @Test("底部来源筛选保留重叠命中且与计数一致", arguments: [
        SearchSource.localKeyword, .localSemantic, .github, .web
    ])
    func resultSourceFilterMatchesCount(_ source: SearchSource) async throws {
        let viewModel = try await makeSourceFilterViewModel()
        let expectedIDs: Set<String>
        switch source {
        case .localKeyword: expectedIDs = ["repo:apple/keyword", "repo:apple/shared"]
        case .localSemantic: expectedIDs = ["repo:apple/shared"]
        case .github: expectedIDs = ["repo:apple/shared", "repo:apple/remote"]
        case .web: expectedIDs = ["reference:https://example.com/swift"]
        }
        viewModel.toggleResultFilter(.source(source))

        #expect(Set(viewModel.candidates.map(\.id)) == expectedIDs)
        #expect(viewModel.resultCount(for: source) == expectedIDs.count)
        #expect(viewModel.processChips.map(\.phase) == [.loaded(2), .loaded(1), .loaded(2), .loaded(1)])
        #expect(viewModel.discoveryResultCount == 2)
    }

    @Test("智能发现筛选独立于普通 GitHub，切换和取消保留完整快照")
    func discoveryFilterDoesNotInflateGitHubCount() async throws {
        let viewModel = try await makeSourceFilterViewModel()
        let allIDs = viewModel.candidates.map(\.id)
        let initialEpoch = viewModel.resultListEpoch
        viewModel.moveSelection(by: 0)
        #expect(viewModel.selectedCandidate != nil)

        viewModel.toggleResultFilter(.discovery)
        #expect(Set(viewModel.candidates.map(\.id)) == ["repo:apple/shared", "repo:apple/discovered"])
        #expect(viewModel.discoveryResultCount == 2)
        #expect(viewModel.resultCount(for: .github) == 2)
        #expect(viewModel.selectedIndex == nil)
        #expect(viewModel.selectedCandidate == nil)
        #expect(viewModel.resultListEpoch == initialEpoch + 1)

        viewModel.toggleResultFilter(.source(.localSemantic))
        #expect(viewModel.candidates.map(\.id) == ["repo:apple/shared"])
        viewModel.moveSelection(by: 3)
        #expect(viewModel.selectedCandidate?.id == "repo:apple/shared")
        viewModel.toggleResultFilter(.source(.localSemantic))
        #expect(viewModel.resultFilter == nil)
        #expect(viewModel.candidates.map(\.id) == allIDs)
        #expect(viewModel.selectedIndex == nil)
    }

    @Test("零命中来源仍可筛选和取消")
    func emptySourceFilterRemainsSelectable() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterImmediateStubProvider(source: .localKeyword, page: .empty),
                SearchCenterSessionStubProvider(candidate: Self.makeCandidate())
            ]),
            historyRepository: history
        )
        viewModel.query = "swift"
        await viewModel.submit()
        viewModel.toggleResultFilter(.source(.localKeyword))

        #expect(viewModel.resultFilter == .source(.localKeyword))
        #expect(viewModel.candidates.isEmpty)
        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(!viewModel.isResultFilterSearching)
        #expect(viewModel.processChips.first?.phase == .loaded(0))
        viewModel.toggleResultFilter(.source(.localKeyword))
        #expect(viewModel.candidates.count == 1)
    }

    @Test("顶部范围切换清空来源筛选且保留发现快照")
    func changingScopeResetsResultFilter() async throws {
        let viewModel = try await makeSourceFilterViewModel()
        viewModel.toggleResultFilter(.discovery)
        await viewModel.changeScope(.local)
        #expect(viewModel.resultFilter == nil)
        #expect(Set(viewModel.candidates.map(\.id)) == ["repo:apple/keyword", "repo:apple/shared"])
        await viewModel.changeScope(.all)
        #expect(viewModel.resultFilter == nil)
        #expect(viewModel.candidates.count == 5)
        #expect(viewModel.discoveryResultCount == 2)

        viewModel.toggleResultFilter(.discovery)
        await viewModel.changeScope(.all)
        #expect(viewModel.resultFilter == nil)
        #expect(viewModel.candidates.count == 5)
    }

    @Test("关闭重开保留来源筛选，重新提交与清空重置筛选")
    func resultFilterFollowsSessionLifetime() async throws {
        let viewModel = try await makeSourceFilterViewModel()
        viewModel.toggleResultFilter(.source(.github))
        viewModel.dismiss()
        viewModel.present()
        #expect(viewModel.resultFilter == .source(.github))
        #expect(viewModel.candidates.count == 2)

        await viewModel.submit()
        #expect(viewModel.resultFilter == nil)
        #expect(viewModel.candidates.count == 5)
        viewModel.toggleResultFilter(.discovery)
        viewModel.clear()
        #expect(viewModel.resultFilter == nil)
        #expect(viewModel.candidates.isEmpty)
    }

    @Test("来源筛选不重复请求 Provider、Router 或智能发现")
    func resultFilteringDoesNotRepeatSearch() async throws {
        let providers = [SearchSource.localKeyword, .localSemantic, .github].map {
            SearchCenterCountingStubProvider(source: $0, candidate: Self.makeCandidate())
        }
        let web = WebLoadMoreStubProvider()
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [
            Self.makeDiscoveryResult(candidate: Self.makeCandidate())
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: providers.map { $0 as any SearchProvider } + [web]),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            includeWebInAll: { true }, intentRouter: router, discoveryService: discovery
        )
        viewModel.query = "swift"
        await viewModel.submit()
        for source in [SearchSource.localKeyword, .localSemantic, .github, .web] {
            viewModel.toggleResultFilter(.source(source))
        }
        viewModel.toggleResultFilter(.discovery)
        viewModel.toggleResultFilter(.discovery)

        #expect(providers.allSatisfy { $0.callCount == 1 })
        #expect(web.maxResultsRequests == [10])
        #expect(router.routeQueries.count == 1)
        #expect(discovery.requests.count == 1)
    }

    @Test("选中来源失败后仍保留可取消的胶囊")
    func failedSourceFilterRemainsCancellable() async throws {
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterSemanticFailureStubProvider(),
                SearchCenterSessionStubProvider(candidate: Self.makeCandidate())
            ]),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        )
        viewModel.query = "swift"
        await viewModel.submit()
        viewModel.toggleResultFilter(.source(.localSemantic))
        #expect(viewModel.candidates.isEmpty)
        #expect(!viewModel.isResultFilterSearching)
        #expect(viewModel.processChips.first?.phase == .failed(String.l10n("search.footer.error.semantic")))
        viewModel.toggleResultFilter(.source(.localSemantic))
        #expect(viewModel.candidates.count == 1)
    }

    @Test("加载中切换来源后保留筛选，迟到结果不重置列表身份")
    func pendingSourceCompletionPreservesFilterAndListIdentity() async throws {
        let gate = SearchHoldGate()
        var keyword = Self.makeCandidate(id: 1, name: "keyword")
        keyword.sources = [.localKeyword]
        var semantic = Self.makeCandidate(id: 2, name: "semantic")
        semantic.sources = [.localSemantic]
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterImmediateStubProvider(
                    source: .localKeyword,
                    page: SearchProviderPage(
                        repositories: [keyword], references: [], totalCount: 1, hasNextPage: false
                    )
                ),
                SearchCenterGatedStubProvider(
                    source: .localSemantic, gate: gate,
                    page: SearchProviderPage(
                        repositories: [semantic], references: [], totalCount: 1, hasNextPage: false
                    )
                )
            ]),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        )
        viewModel.scope = .local
        viewModel.query = "swift"
        let searchTask = Task { await viewModel.submit() }
        await gate.waitUntilBlocked()
        try await waitUntil { viewModel.resultCount(for: .localKeyword) == 1 }
        let originalEpoch = viewModel.resultListEpoch

        viewModel.toggleResultFilter(.source(.localSemantic))
        let filteredEpoch = viewModel.resultListEpoch
        #expect(filteredEpoch == originalEpoch + 1)
        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.isResultFilterSearching)

        await gate.resume()
        await searchTask.value
        #expect(viewModel.resultFilter == .source(.localSemantic))
        #expect(viewModel.candidates.map(\.id) == ["repo:apple/semantic"])
        #expect(viewModel.resultCount(for: .localKeyword) == 1)
        #expect(viewModel.resultCount(for: .localSemantic) == 1)
        #expect(!viewModel.isResultFilterSearching)
        #expect(viewModel.resultListEpoch == filteredEpoch)
    }

    @Test("分页追加保留来源筛选和列表身份")
    func paginationPreservesResultFilterAndListIdentity() async throws {
        let provider = SearchCenterRecordingPagingProvider(candidates: [
            Self.makeCandidate(id: 1, name: "first"),
            Self.makeCandidate(id: 2, name: "second")
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        )
        viewModel.scope = .github
        viewModel.query = "swift"
        await viewModel.submit()
        viewModel.toggleResultFilter(.source(.github))
        let filteredEpoch = viewModel.resultListEpoch
        viewModel.moveSelection(by: 0)

        await viewModel.loadMoreGitHub()
        #expect(viewModel.resultFilter == .source(.github))
        #expect(viewModel.candidates.count == 2)
        #expect(viewModel.resultCount(for: .github) == 2)
        #expect(viewModel.selectedCandidate?.id == "repo:apple/first")
        #expect(viewModel.resultListEpoch == filteredEpoch)
        #expect(await provider.requests.map(\.page) == [1, 2])
    }

    /// 固定来源交叉关系用于验收：发现与普通搜索交叠一项，并另增一项 GitHub 来源仓库。
    private func makeSourceFilterViewModel() async throws -> SearchCenterViewModel {
        var keyword = Self.makeCandidate(id: 1, name: "keyword")
        keyword.sources = [.localKeyword]
        var shared = Self.makeCandidate(id: 2, name: "shared")
        shared.sources = [.localKeyword, .localSemantic, .github]
        shared.semanticScore = 0.95
        let remote = Self.makeCandidate(id: 3, name: "remote")
        let discovered = Self.makeCandidate(id: 4, name: "discovered")
        let sharedResult = Self.makeDiscoveryResult(candidate: shared)
        let discoveredResult = Self.makeDiscoveryResult(candidate: discovered)
        let reference = ReferenceCandidate(
            normalizedURL: URL(string: "https://example.com/swift")!,
            originalURL: URL(string: "https://example.com/swift")!,
            title: "Swift documentation", snippet: nil, domain: "example.com", source: .web
        )
        let discovery = SearchCenterStubDiscoveryService(results: [
            RepositoryDiscoveryResult(
                session: sharedResult.session,
                repositories: sharedResult.repositories + discoveredResult.repositories,
                references: [], diagnostics: []
            )
        ])
        let providers: [any SearchProvider] = [
            SearchCenterImmediateStubProvider(
                source: .localKeyword,
                page: SearchProviderPage(repositories: [keyword, shared], references: [], totalCount: 2, hasNextPage: false)
            ),
            SearchCenterImmediateStubProvider(
                source: .localSemantic,
                page: SearchProviderPage(repositories: [shared], references: [], totalCount: 1, hasNextPage: false)
            ),
            SearchCenterImmediateStubProvider(
                source: .github,
                page: SearchProviderPage(repositories: [shared, remote], references: [], totalCount: 2, hasNextPage: false)
            ),
            SearchCenterImmediateStubProvider(
                source: .web,
                page: SearchProviderPage(repositories: [], references: [reference], totalCount: 1, hasNextPage: false)
            )
        ]
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: providers),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            includeWebInAll: { true },
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        viewModel.query = "swift"
        await viewModel.submit()
        return viewModel
    }

    @Test("禁止查询不进入 Router、历史或显式智能查找")
    func blockedQueryStopsBeforeRoutingAndHistory() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []), historyRepository: history,
            intentRouter: router, discoveryService: discovery
        )
        viewModel.query = "购买枪支"
        await viewModel.submit()
        await viewModel.startSmartDiscovery()
        #expect(router.routeQueries.isEmpty)
        #expect(discovery.requests.isEmpty)
        #expect(try await history.fetchAll().isEmpty)
        #expect(viewModel.coordinator.blockedQuery != nil)
        #expect(!viewModel.canStartSmartDiscovery)
        #expect(!viewModel.hasDiscoveryFailures)
    }

    @Test("普通搜索的筛选详情可见，隐藏结果不算智能发现失败")
    func ordinarySearchExposesFilteringDetailsWithoutFailure() async throws {
        let blocked = Self.makeCandidate(id: 900, owner: "cirosantilli", name: "china-dictatorship")
        let provider = SearchCenterSessionStubProvider(candidate: blocked)
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]), historyRepository: history
        )
        viewModel.query = "linux distributions"
        await viewModel.submit()

        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.discoverySession == nil)
        #expect(viewModel.hasDiscoveryDetails)
        #expect(!viewModel.hasDiscoveryFailures)
        #expect(viewModel.contentSummary.checkedCount == 1)
        #expect(viewModel.contentSummary.hiddenCount == 1)
        #expect(viewModel.contentSummary.retainedCount == 0)
        #expect(!viewModel.contentSummaryText.contains("search.content.summaryFormat"))
        #expect(!viewModel.contentSummaryText.contains("%1$lld"))
    }

    @Test("发现返回、缓存回读与继续查找均不能恢复隐藏候选")
    func discoveryCacheAndContinuationRespectContentPolicy() async throws {
        let blocked = Self.makeCandidate(id: 900, owner: "cirosantilli", name: "china-dictatorship")
        let result = Self.makeDiscoveryResult(candidate: blocked)
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [result, result])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []), historyRepository: history,
            intentRouter: router, discoveryService: discovery
        )
        viewModel.query = "find linux distributions"
        await viewModel.submit()
        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.discoverySession?.evidence.isEmpty == true)
        #expect(viewModel.contentSummary.hiddenCount == 1)
        await viewModel.submit()
        #expect(discovery.requests.count == 1)
        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.contentSummary.hiddenCount == 1)
        await viewModel.continueDiscovery()
        #expect(discovery.requests.count == 2)
        #expect(viewModel.candidates.isEmpty)
        #expect(!viewModel.hasDiscoveryFailures)
    }

    @Test("关闭并重新打开时保留完整搜索会话")
    func dismissAndPresentPreservesSession() async throws {
        // 2026-06-14：历史从 UserDefaults 升级到 GRDB SQLite。测试用内存 DB +
        // GRDB Repository 装配 ViewModel，行为不变。
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let candidate = Self.makeCandidate()
        let provider = SearchCenterSessionStubProvider(candidate: candidate)
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .github
        viewModel.githubFilters.language = "Swift"
        viewModel.githubFilters.minimumStars = 100
        viewModel.isGitHubFiltersExpanded = true
        await viewModel.submit()
        viewModel.moveSelection(by: 0)

        let selectedBeforeDismiss = viewModel.selectedIndex
        viewModel.dismiss()

        #expect(!viewModel.isPresented)
        #expect(viewModel.query == "swift")
        #expect(viewModel.lastSubmittedQuery == "swift")
        #expect(viewModel.scope == .github)
        #expect(viewModel.githubFilters.language == "Swift")
        #expect(viewModel.githubFilters.minimumStars == 100)
        #expect(viewModel.isGitHubFiltersExpanded)
        #expect(viewModel.candidates.count == 1)

        viewModel.present()

        #expect(viewModel.isPresented)
        #expect(viewModel.selectedIndex == selectedBeforeDismiss)
        #expect(viewModel.candidates.first?.id == SearchCandidate.repository(candidate).id)
    }

    @Test("GitHub 查看更多追加下一页结果")
    func loadMoreGitHubAppendsNextPage() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = SearchCenterPagingStubProvider(
            firstPageCandidate: Self.makeCandidate(id: 1, owner: "apple", name: "swift"),
            secondPageCandidate: Self.makeCandidate(id: 2, owner: "swiftlang", name: "swift-format")
        )
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .github
        await viewModel.submit()

        #expect(viewModel.currentGitHubPage == 1)
        #expect(viewModel.canLoadMoreGitHub)
        #expect(viewModel.candidates.count == 1)

        await viewModel.loadMoreGitHub()

        #expect(viewModel.currentGitHubPage == 2)
        #expect(!viewModel.canLoadMoreGitHub)
        #expect(viewModel.candidates.count == 2)
    }

    @Test("翻页后提交新词从首页开始，下一次继续第二页")
    func newQueryResetsGitHubRequestPage() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let provider = SearchCenterRecordingPagingProvider(candidates: [
            Self.makeCandidate(id: 1, name: "one"),
            Self.makeCandidate(id: 2, name: "two"),
            Self.makeCandidate(id: 3, name: "three")
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]),
            historyRepository: history
        )
        viewModel.scope = .github
        viewModel.query = "swift"
        await viewModel.submit()
        await viewModel.loadMoreGitHub()
        viewModel.query = "rust"
        await viewModel.submit()
        #expect(viewModel.currentGitHubPage == 1)
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1])
        await viewModel.loadMoreGitHub()

        let requests = await provider.requests
        #expect(requests.map(\.query) == ["swift", "swift", "rust", "rust"])
        #expect(requests.map(\.page) == [1, 2, 1, 2])
    }

    @Test("范围往返保留已加载页并继续加载第三页")
    func scopeRoundTripPreservesPagination() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let provider = SearchCenterRecordingPagingProvider(candidates: [
            Self.makeCandidate(id: 1, name: "one"),
            Self.makeCandidate(id: 2, name: "two"),
            Self.makeCandidate(id: 3, name: "three")
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]),
            historyRepository: history
        )
        viewModel.scope = .github
        viewModel.query = "swift"
        await viewModel.submit()
        await viewModel.loadMoreGitHub()
        await viewModel.changeScope(.local)
        #expect(viewModel.candidates.isEmpty)
        await viewModel.changeScope(.github)
        #expect(viewModel.currentGitHubPage == 2)
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1, 2])
        await viewModel.loadMoreGitHub()
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1, 2, 3])
        #expect(await provider.requests.map(\.page) == [1, 2, 3])
    }

    @Test("分页失败保留成功页码，重试仍请求失败的那一页")
    func failedPaginationCanRetrySamePage() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let provider = SearchCenterRecordingPagingProvider(
            candidates: [Self.makeCandidate(id: 1, name: "one"), Self.makeCandidate(id: 2, name: "two")],
            failSecondPageOnce: true
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]),
            historyRepository: history
        )
        viewModel.scope = .github
        viewModel.query = "swift"
        await viewModel.submit()
        await viewModel.loadMoreGitHub()
        #expect(viewModel.currentGitHubPage == 1)
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1])
        #expect(viewModel.canLoadMoreGitHub)
        await viewModel.loadMoreGitHub()
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1, 2])
        #expect(await provider.requests.map(\.page) == [1, 2, 2])
    }

    @Test("独立远端范围在请求结束前保持加载态", arguments: [SearchScope.github, .web])
    func remoteScopeLoadingState(scope: SearchScope) async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let gate = SearchHoldGate()
        let provider = SearchCenterGatedStubProvider(
            source: scope == .github ? .github : .web,
            gate: gate,
            page: .empty
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]),
            historyRepository: history
        )
        viewModel.scope = scope
        viewModel.query = "swift"
        let task = Task { await viewModel.submit() }
        await gate.waitUntilBlocked()
        #expect(viewModel.isSearching)
        #expect(viewModel.shouldShowSearchSkeleton)
        #expect(!viewModel.hasSettledSearchProvider)
        #expect(viewModel.processChips.isEmpty)
        await gate.resume()
        await task.value
        #expect(!viewModel.isSearching)
        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(viewModel.hasSettledSearchProvider)
    }

    @Test("新查询取消旧 Router 链路且旧响应不启动发现")
    func replacingQueryCancelsOldRoutingChain() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        router.delays = ["linux distribution": 0.15]
        let discovery = SearchCenterStubDiscoveryService(results: [
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 2, name: "rust"))
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "linux distribution"
        let oldTask = Task { await viewModel.submit() }
        try await Self.waitUntil {
            router.routeQueries == ["linux distribution"]
        }
        viewModel.query = "rust"
        await viewModel.submit()
        await oldTask.value

        #expect(router.routeQueries == ["linux distribution", "rust"])
        #expect(discovery.requests.map(\.query) == ["rust"])
        #expect(viewModel.lastSubmittedQuery == "rust")
        #expect(viewModel.candidates.contains { $0.id == "repo:apple/rust" })
    }

    @Test("清空查询时取消智能链路且不留下失败")
    func clearingQueryCancelsDiscoverySilently() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        router.delays = ["linux distribution": 0.15]
        let discovery = SearchCenterStubDiscoveryService(results: [])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "linux distribution"
        let task = Task { await viewModel.submit() }
        try await Self.waitUntil {
            router.routeQueries == ["linux distribution"]
        }
        viewModel.clear()
        await task.value

        #expect(discovery.requests.isEmpty)
        #expect(viewModel.discoverySession == nil)
        #expect(viewModel.discoveryDiagnostics.isEmpty)
        #expect(!viewModel.isDiscoveryRunning)
        #expect(viewModel.lastSubmittedQuery.isEmpty)
    }

    @Test("应用 GitHub 筛选重置首页并保留兼容的本地快照")
    func applyingGitHubFiltersPreservesLocalSnapshot() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword, candidate: Self.makeCandidate(id: 10, name: "local")
        )
        let github = SearchCenterRecordingPagingProvider(candidates: [
            Self.makeCandidate(id: 1, name: "one"), Self.makeCandidate(id: 2, name: "two")
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local, github]), historyRepository: history
        )
        viewModel.query = "swift"
        await viewModel.submit()
        await viewModel.changeScope(.github)
        await viewModel.loadMoreGitHub()
        viewModel.githubFilters.language = "Rust"
        await viewModel.applyGitHubFilters()
        #expect(viewModel.currentGitHubPage == 1)
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [1])
        await viewModel.changeScope(.all)
        #expect(local.callCount == 1)
        #expect(viewModel.coordinator.repositories.map(\.card.ghRepoId) == [10, 1])
        let requests = await github.requests
        #expect(requests.map(\.page) == [1, 2, 1])
        #expect(requests.last?.githubFilters.language == "Rust")
    }

    @Test("网页加载更多后切换范围保留累计结果与请求上限")
    func webScopeRoundTripPreservesExpandedResults() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let provider = WebLoadMoreStubProvider()
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [provider]), historyRepository: history
        )
        viewModel.scope = .web
        viewModel.query = "swift"
        await viewModel.submit()
        await viewModel.loadMoreWeb()
        await viewModel.changeScope(.local)
        await viewModel.changeScope(.web)
        #expect(viewModel.candidates.count == 2)
        #expect(viewModel.externalSearchFilters.maxResults == 20)
        #expect(provider.maxResultsRequests == [10, 20])
    }

    @Test("切换到 GitHub 范围后不展示隐藏语义来源的错误")
    func remoteScopeExcludesHiddenSourceErrors() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterSemanticFailureStubProvider(),
                SearchCenterSessionStubProvider(candidate: Self.makeCandidate())
            ]),
            historyRepository: history
        )
        viewModel.query = "swift"
        await viewModel.submit()
        #expect(viewModel.footerErrors.count == 1)
        await viewModel.changeScope(.github)
        #expect(viewModel.footerErrors.isEmpty)
        #expect(!viewModel.isSearching)
    }

    @Test("submit: 非空搜索会完成开始使用清单的搜索步骤")
    func submitPostsGettingStartedSearchNotification() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = SearchCenterSessionStubProvider(candidate: Self.makeCandidate())
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)
        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .gettingStartedDidUseSearch,
            object: nil,
            queue: nil
        ) { _ in
            recorder.record()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        viewModel.query = "swift"
        await viewModel.submit()

        #expect(recorder.count == 1)
    }

    @Test("Web tab 使用会话级 External Search Provider")
    func webScopeUsesSessionExternalSearchProvider() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = CapturingWebSearchProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .web
        viewModel.webSearchProvider = .exa
        await viewModel.submit()

        #expect(provider.lastRequest?.externalSearchProvider == .exa)
    }

    @Test("Web tab 传递会话级 External Search 公共 filters")
    func webScopePassesExternalSearchFilters() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = CapturingWebSearchProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .web
        viewModel.externalSearchFilters.maxResults = 7
        viewModel.externalSearchFilters.freshness = .week
        viewModel.externalSearchFilters.includeDomains = ["docs.swift.org"]
        viewModel.externalSearchFilters.excludeDomains = ["example.com"]
        await viewModel.submit()

        #expect(provider.lastRequest?.externalSearchFilters.maxResults == 7)
        #expect(provider.lastRequest?.externalSearchFilters.freshness == .week)
        #expect(provider.lastRequest?.externalSearchFilters.includeDomains == ["docs.swift.org"])
        #expect(provider.lastRequest?.externalSearchFilters.excludeDomains == ["example.com"])
    }

    @Test("Web tab 加载更多会增大 maxResults 并重跑 web source")
    func loadMoreWebIncreasesMaxResults() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = WebLoadMoreStubProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .web
        await viewModel.submit()

        #expect(viewModel.externalSearchFilters.maxResults == 10)
        #expect(viewModel.canLoadMoreWeb)
        #expect(provider.maxResultsRequests == [10])

        await viewModel.loadMoreWeb()

        #expect(viewModel.externalSearchFilters.maxResults == 20)
        #expect(provider.maxResultsRequests == [10, 20])
        #expect(viewModel.candidates.count == 2)
    }

    @Test("All scope 使用设置页默认 External Search Provider")
    func allScopeUsesDefaultExternalSearchProvider() async throws {
        let oldDefault = AppSettings.shared.externalSearchDefaultProvider
        AppSettings.shared.externalSearchDefaultProvider = .braveLLMContext
        defer { AppSettings.shared.externalSearchDefaultProvider = oldDefault }

        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let provider = CapturingWebSearchProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(
            coordinator: coordinator,
            historyRepository: history,
            includeWebInAll: { true }
        )

        viewModel.query = "swift"
        viewModel.scope = .all
        viewModel.webSearchProvider = .exa
        await viewModel.submit()

        #expect(provider.lastRequest?.externalSearchProvider == .braveLLMContext)
    }

    @Test("语义 Provider 失败时保留其它结果并展示本地化来源名")
    func semanticFailureKeepsResultsAndUsesLocalizedSourceName() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let candidate = Self.makeCandidate()
        let coordinator = SearchCoordinator(providers: [
            SearchCenterSessionStubProvider(candidate: candidate),
            SearchCenterSemanticFailureStubProvider()
        ])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .all
        await viewModel.submit()

        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.errorMessages == [
            "\(String.l10n("search.mode.semantic")): 向量服务不可用"
        ])
        #expect(viewModel.footerErrors.map(\.shortLabel) == [
            String.l10n("search.footer.error.semantic")
        ])
        #expect(viewModel.footerErrors.map(\.fullMessage) == viewModel.errorMessages)
    }

    @Test("全部 scope 底栏按关键词、语义、GitHub 分别计数")
    func allScopeProcessChipsSplitKeywordAndSemantic() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let keywordCandidate = Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        var keyword = keywordCandidate
        keyword.sources = [.localKeyword]
        var semantic = Self.makeCandidate(id: 2, owner: "swiftlang", name: "swift-evolution")
        semantic.sources = [.localSemantic]
        semantic.semanticScore = 0.91
        semantic.semanticReason = "vector"
        let coordinator = SearchCoordinator(providers: [
            SearchCenterImmediateStubProvider(
                source: .localKeyword,
                page: SearchProviderPage(
                    repositories: [keyword],
                    references: [],
                    totalCount: 1,
                    hasNextPage: false
                )
            ),
            SearchCenterImmediateStubProvider(
                source: .localSemantic,
                page: SearchProviderPage(
                    repositories: [semantic],
                    references: [],
                    totalCount: 1,
                    hasNextPage: false
                )
            ),
            SearchCenterImmediateStubProvider(
                source: .github,
                page: SearchProviderPage(
                    repositories: [],
                    references: [],
                    totalCount: 0,
                    hasNextPage: false
                )
            )
        ])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)

        viewModel.query = "swift"
        viewModel.scope = .all
        await viewModel.submit()

        #expect(viewModel.processChips.map(\.source) == [.localKeyword, .localSemantic, .github])
        #expect(viewModel.processChips.map(\.phase) == [
            .loaded(1),
            .loaded(1),
            .loaded(0)
        ])
        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(viewModel.candidates.count == 2)

        viewModel.scope = .local
        #expect(viewModel.processChips.map(\.source) == [.localKeyword, .localSemantic])
    }

    @Test("changeScope 全部切本地不重跑已加载 Provider")
    func changeScopeAllToLocalDoesNotRerunProviders() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let keyword = SearchCenterCountingStubProvider(source: .localKeyword, candidate: Self.makeCandidate(id: 1, owner: "apple", name: "swift"))
        let semantic = SearchCenterCountingStubProvider(
            source: .localSemantic,
            candidate: {
                var item = Self.makeCandidate(id: 1, owner: "apple", name: "swift")
                item.sources = [.localSemantic]
                item.semanticScore = 0.9
                return item
            }()
        )
        let github = SearchCenterCountingStubProvider(
            source: .github,
            candidate: Self.makeCandidate(id: 2, owner: "torvalds", name: "linux")
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic, github])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)
        viewModel.query = "swift"
        viewModel.scope = .all
        await viewModel.submit()
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)

        #expect(viewModel.resultListEpoch == 0)
        await viewModel.changeScope(.local)
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(viewModel.resultListEpoch == 1)
        #expect(viewModel.candidates.map(\.id) == ["repo:apple/swift"])
    }

    @Test("关键词先返回 0 时不显示骨架，底栏展示语义搜索中")
    func keywordZeroKeepsFooterWhileSemanticLoads() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let semanticGate = SearchHoldGate()
        var semanticCandidate = Self.makeCandidate(id: 99, owner: "starcat-app", name: "starcat-docs")
        semanticCandidate.sources = [.localSemantic]
        semanticCandidate.semanticScore = 0.88
        let coordinator = SearchCoordinator(providers: [
            SearchCenterImmediateStubProvider(
                source: .localKeyword,
                page: SearchProviderPage(
                    repositories: [],
                    references: [],
                    totalCount: 0,
                    hasNextPage: false
                )
            ),
            SearchCenterGatedStubProvider(
                source: .localSemantic,
                gate: semanticGate,
                page: SearchProviderPage(
                    repositories: [semanticCandidate],
                    references: [],
                    totalCount: 1,
                    hasNextPage: false
                )
            ),
            SearchCenterImmediateStubProvider(
                source: .github,
                page: SearchProviderPage(
                    repositories: [],
                    references: [],
                    totalCount: 0,
                    hasNextPage: false
                )
            )
        ])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)
        viewModel.query = "把 GitHub star 做成知识库"
        viewModel.scope = .all

        let searchTask = Task { await viewModel.submit() }
        await semanticGate.waitUntilBlocked()
        // 两个来源独立完成；语义搜索保持阻塞时，等待本次要断言的两个空结果均已返回。
        try await waitUntil {
            viewModel.processChips.contains { $0.source == .localKeyword && $0.phase == .loaded(0) }
                && viewModel.processChips.contains { $0.source == .github && $0.phase == .loaded(0) }
        }

        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(viewModel.hasSettledSearchProvider)
        #expect(viewModel.candidates.isEmpty)
        #expect(viewModel.processChips.contains { $0.source == .localKeyword && $0.phase == .loaded(0) })
        #expect(viewModel.processChips.contains { $0.source == .localSemantic && $0.phase == .loading })
        #expect(viewModel.processChips.contains { $0.source == .github && $0.phase == .loaded(0) })

        await semanticGate.resume()
        await searchTask.value

        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.processChips.contains { $0.source == .localSemantic && $0.phase == .loaded(1) })
        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(!viewModel.isSearching)
    }

    @Test("关键词先出结果时立刻展示，不等语义")
    func keywordHitsAppearBeforeSemanticFinishes() async throws {
        let db = try InMemoryDatabaseManager()
        let history = GRDBSearchHistoryRepository(database: db)
        let semanticGate = SearchHoldGate()
        var keyword = Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        keyword.sources = [.localKeyword]
        let coordinator = SearchCoordinator(providers: [
            SearchCenterImmediateStubProvider(
                source: .localKeyword,
                page: SearchProviderPage(
                    repositories: [keyword],
                    references: [],
                    totalCount: 1,
                    hasNextPage: false
                )
            ),
            SearchCenterGatedStubProvider(
                source: .localSemantic,
                gate: semanticGate,
                page: .empty
            )
        ])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyRepository: history)
        viewModel.query = "swift"
        viewModel.scope = .local

        let searchTask = Task { await viewModel.submit() }
        await semanticGate.waitUntilBlocked()
        try await waitUntil { viewModel.candidates.count == 1 }

        #expect(viewModel.candidates.count == 1)
        #expect(!viewModel.shouldShowSearchSkeleton)
        #expect(viewModel.processChips.contains { $0.source == .localKeyword && $0.phase == .loaded(1) })
        #expect(viewModel.processChips.contains { $0.source == .localSemantic && $0.phase == .loading })

        await semanticGate.resume()
        await searchTask.value
        #expect(viewModel.candidates.count == 1)
        #expect(!viewModel.isSearching)
    }

    @Test("All 范围按智能相关性合并，外部高相关项目可领先收藏")
    func allScopeRoutesNaturalLanguageToDiscovery() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword,
            candidate: Self.makeCandidate(id: 1, owner: "apple", name: "swift", isInLibrary: true)
        )
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(
            results: [Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy"))]
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local]),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        viewModel.scope = .all
        await viewModel.submit()

        #expect(router.routeQueries == ["github 最近比较火的 linux 发行版"])
        #expect(viewModel.candidates.map(\.id) == ["repo:omarchy/omarchy", "repo:apple/swift"])
        #expect(discovery.seedRepositorySnapshots.first?.first?.card.fullName == "apple/swift")
        #expect(discovery.seedRepositorySnapshots.first?.first?.card.isInLibrary == true)
        #expect(viewModel.discoverySession?.phase == .completed)
        #expect(viewModel.discoveryResultCount == 1)
        #expect(viewModel.canContinueDiscovery)
        #expect(viewModel.discoveryDiagnostics.isEmpty)
        #expect(viewModel.discoverySteps.map(\.stage) == [
            .planning, .githubSearch, .verification, .ranking, .merging
        ])
        #expect(viewModel.hasDiscoveryDetails)
    }

    @Test("成功的智能发现详情展示真实步骤而非伪造过程")
    func successfulDiscoveryExposesRealSteps() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let candidate = Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy")
        let result = RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: UUID(),
                round: 1,
                phase: .completed,
                plan: Self.makeSmartOutcome().plan,
                evidence: [],
                usedLLMCalls: 2,
                steps: [
                    SearchDiscoveryStep(id: "planning", stage: .planning, state: .completed),
                    SearchDiscoveryStep(id: "ranking", stage: .ranking, state: .completed)
                ]
            ),
            repositories: [candidate],
            references: [],
            diagnostics: []
        )
        let upstreamSteps = [
            SearchDiscoveryStep(id: "routing", stage: .routing, state: .skipped),
            SearchDiscoveryStep(
                id: "planning",
                stage: .planning,
                state: .completed,
                detail: "Find trending Linux distributions",
                durationSeconds: 0.4,
                model: "planner-model"
            )
        ]
        let smartOutcome = Self.makeSmartOutcome()
        let router = SearchCenterStubIntentRouter(outcome: SearchIntentRoutingOutcome(
            route: smartOutcome.route,
            decisionStatus: smartOutcome.decisionStatus,
            plannerStatus: smartOutcome.plannerStatus,
            plan: smartOutcome.plan,
            steps: upstreamSteps
        ))
        let discovery = SearchCenterStubDiscoveryService(results: [result])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        await viewModel.submit()

        #expect(viewModel.discoverySession?.phase == .completed)
        #expect(viewModel.discoveryDiagnostics.isEmpty)
        #expect(viewModel.hasDiscoveryDetails)
        #expect(viewModel.discoverySteps.map(\.id) == ["routing", "planning", "ranking", "merging"])
        #expect(viewModel.discoverySteps.first(where: { $0.stage == .planning }) == upstreamSteps.last)
        #expect(viewModel.discoverySteps.last?.state == .completed)
        #expect(viewModel.discoverySession?.steps == viewModel.discoverySteps)

        let completedSteps = viewModel.discoverySteps
        await viewModel.submit()

        #expect(discovery.requests.count == 1)
        #expect(viewModel.discoverySteps == completedSteps)
    }

    @Test("发现结果与基础结果重复时保留单行、匹配理由和去重计数")
    func discoveryCountMergesOverlappingRepositories() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let candidate = Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy")
        let firstResult = Self.makeDiscoveryResult(candidate: candidate)
        let result = RepositoryDiscoveryResult(
            session: firstResult.session,
            repositories: firstResult.repositories + firstResult.repositories,
            references: [],
            diagnostics: []
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterCountingStubProvider(source: .localKeyword, candidate: candidate)
            ]),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: SearchCenterStubDiscoveryService(results: [result])
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        await viewModel.submit()

        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.discoveryResultCount == 1)
        guard case .repository(let displayed) = viewModel.candidates.first else {
            Issue.record("Expected a repository candidate")
            return
        }
        #expect(displayed.discovery?.reason == "Web evidence points to this repository")
        #expect(viewModel.coordinator.repositories.first?.discovery == nil)
    }

    @Test("发现没有仓库时计数为零，不把普通结果或网页资料计入")
    func emptyDiscoveryCountExcludesBaseResults() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let candidate = Self.makeCandidate()
        let result = RepositoryDiscoveryResult(
            session: Self.makeDiscoveryResult(candidate: candidate).session,
            repositories: [],
            references: [],
            diagnostics: []
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [
                SearchCenterCountingStubProvider(source: .localKeyword, candidate: candidate)
            ]),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: SearchCenterStubDiscoveryService(results: [result])
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        await viewModel.submit()

        #expect(viewModel.discoverySession?.phase == .completed)
        #expect(viewModel.candidates.count == 1)
        #expect(viewModel.discoveryResultCount == 0)
    }

    @Test("Planner 失败保留基础结果并显示智能发现失败")
    func plannerFailureKeepsBaseResultsAndDiscoveryState() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        var baseCandidate = Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        baseCandidate.sources = [.localKeyword]
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword,
            candidate: baseCandidate
        )
        let router = SearchCenterStubIntentRouter(outcome: SearchIntentRoutingOutcome(
            route: .fastPath,
            decisionStatus: .skipped,
            plannerStatus: .failed("AI 服务商要求付费或账户余额不足"),
            plan: nil
        ))
        let discovery = SearchCenterStubDiscoveryService(results: [])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local]),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        viewModel.scope = .all
        await viewModel.submit()

        #expect(viewModel.candidates == [SearchCandidate.repository(local.candidate)])
        #expect(viewModel.discoverySession?.phase == .failed("AI 服务商要求付费或账户余额不足"))
        #expect(viewModel.discoveryDiagnostics.first?.message == "AI 服务商要求付费或账户余额不足")
        #expect(viewModel.hasDiscoveryFailures)
        #expect(discovery.requests.isEmpty)
        #expect(viewModel.canStartSmartDiscovery)
    }

    @Test("相同搜索请求直接复用完成的智能发现缓存")
    func identicalRequestReusesCompletedDiscovery() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword,
            candidate: Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        )
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(
            results: [Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy"))]
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local]),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        viewModel.scope = .all
        await viewModel.submit()
        await viewModel.submit()

        #expect(router.routeQueries.count == 1)
        #expect(discovery.requests.count == 1)
        #expect(viewModel.candidates.contains { $0.id == "repo:omarchy/omarchy" })
    }

    @Test("部分失败不缓存，恢复成功后同一请求可复用")
    func partialFailureIsNotCachedButRecoveredSuccessIsCached() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let baseResult = Self.makeDiscoveryResult(
            candidate: Self.makeCandidate(id: 9, owner: "apple", name: "partial")
        )
        let partialFailure = RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: baseResult.session.generation,
                round: 1,
                phase: .partialFailure,
                plan: baseResult.session.plan,
                evidence: baseResult.session.evidence,
                usedLLMCalls: baseResult.session.usedLLMCalls,
                steps: baseResult.steps
            ),
            repositories: baseResult.repositories,
            references: [],
            diagnostics: [.failure(stage: .webSearch, error: URLError(.timedOut))]
        )
        let success = Self.makeDiscoveryResult(
            candidate: Self.makeCandidate(id: 10, owner: "apple", name: "success")
        )
        let discovery = SearchCenterStubDiscoveryService(results: [partialFailure, success])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )

        viewModel.query = "github linux distribution"
        viewModel.scope = .all
        await viewModel.submit()
        await viewModel.submit()
        await viewModel.submit()

        #expect(discovery.requests.count == 2)
        #expect(viewModel.discoverySession?.phase == .completed)
        #expect(viewModel.candidates.contains { $0.id == "repo:apple/success" })
    }

    @Test("配置身份与缓存过期会重新执行智能发现")
    func cacheIdentityAndTTLInvalidateDiscoverySnapshot() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "apple", name: "old")),
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 10, owner: "apple", name: "new")),
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 11, owner: "apple", name: "restored")),
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 12, owner: "apple", name: "fresh"))
        ])
        var identity = SearchDiscoveryCacheIdentity.constant
        var now = Date()
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery,
            discoveryCacheIdentity: { identity },
            discoveryNow: { now }
        )

        viewModel.query = "github linux distribution"
        viewModel.scope = .all
        await viewModel.submit()
        identity = SearchDiscoveryCacheIdentity(
            chatConfiguration: "changed-chat",
            rerankConfiguration: identity.rerankConfiguration,
            externalSearchConfiguration: identity.externalSearchConfiguration,
            credentialFingerprint: identity.credentialFingerprint
        )
        await viewModel.submit()
        identity = .constant
        await viewModel.submit()
        now = now.addingTimeInterval(15 * 60)
        await viewModel.submit()

        #expect(router.routeQueries.count == 4)
        #expect(discovery.requests.count == 4)
        #expect(viewModel.candidates.contains { $0.id == "repo:apple/fresh" })
    }

    @Test("缓存命中不延长外部证据的有效期")
    func cacheHitDoesNotExtendTTL() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let result = Self.makeDiscoveryResult(candidate: Self.makeCandidate())
        let discovery = SearchCenterStubDiscoveryService(results: [result, result])
        var now = Date()
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery,
            discoveryNow: { now }
        )
        viewModel.query = "linux distribution"
        await viewModel.submit()
        now = now.addingTimeInterval(14 * 60)
        await viewModel.submit()
        #expect(discovery.requests.count == 1)
        now = now.addingTimeInterval(60)
        await viewModel.submit()
        #expect(discovery.requests.count == 2)
    }

    @Test("失败与取消快照不会阻止相同查询恢复", arguments: [
        SearchDiscoveryPhase.failed("Unavailable"), .cancelled, .completed
    ])
    func unsuccessfulSnapshotIsNotCached(phase: SearchDiscoveryPhase) async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let failure = RepositoryDiscoveryResult(
            session: SearchDiscoverySession(generation: UUID(), round: 1, phase: phase),
            repositories: [],
            references: [],
            diagnostics: phase == .cancelled
                ? [] : [.failure(stage: .githubSearch, error: URLError(.notConnectedToInternet))]
        )
        let success = Self.makeDiscoveryResult(candidate: Self.makeCandidate())
        let discovery = SearchCenterStubDiscoveryService(results: [failure, success])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        viewModel.query = "linux distribution"
        await viewModel.submit()
        await viewModel.submit()
        #expect(discovery.requests.count == 2)
        #expect(viewModel.discoverySession?.phase == .completed)
    }

    @Test("真实配置与凭据修改会改变缓存身份", arguments: [
        "chatModel", "chatProvider", "rerank", "webPermission",
        "webProvider", "chatKey", "githubAccount", "rerankKey", "webKey", "decisionKey"
    ])
    func liveCacheIdentityTracksConfigurationChanges(change: String) throws {
        let defaults = try #require(UserDefaults(suiteName: "SearchCache-\(UUID().uuidString)"))
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let previous = SearchDiscoveryCacheIdentity.live(settings: settings, keychain: keychain)
        switch change {
        case "chatModel":
            settings.aiChatTask.useCustomModel = true
            settings.aiChatTask.customModelName = "new-model"
        case "chatProvider": settings.aiChatTask.providerID = "new-provider"
        case "rerank": settings.ragRerankConfiguration.model = "new-reranker"
        case "webPermission": settings.externalContextEnabled.toggle()
        case "webProvider": settings.externalSearchDefaultProvider = .exa
        case "chatKey": try keychain.storeAIKey("secret-new-chat-key", forProvider: settings.aiChatTask.providerID)
        case "githubAccount": try keychain.storeGithubToken("secret-new-account-token")
        case "rerankKey": try keychain.storeAIKey("secret-rerank-key", forProvider: RAGRerankConfiguration.keychainID)
        case "webKey": try keychain.storeServiceAPIKey("secret-web-key", forService: ExternalSearchProviderID.exa.keychainServiceID)
        case "decisionKey": try keychain.storeServiceAPIKey("secret-decision-key", forService: JevDecisionEngine.keychainServiceID)
        default: Issue.record("Unexpected test case")
        }
        let current = SearchDiscoveryCacheIdentity.live(settings: settings, keychain: keychain)
        #expect(previous != current)
        #expect(!String(describing: current).contains("secret-"))
    }

    @Test("智能发现失败不清空基础搜索结果")
    func discoveryFailureKeepsBaseResults() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        var baseCandidate = Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        baseCandidate.sources = [.localKeyword]
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword,
            candidate: baseCandidate
        )
        let failedSession = SearchDiscoverySession(
            generation: UUID(),
            round: 1,
            phase: .failed("Search query planner failed")
        )
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [
            RepositoryDiscoveryResult(
                session: failedSession,
                repositories: [],
                references: [],
                diagnostics: [.failure(stage: .planning, error: AIClientError.emptyResponse)]
            )
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local]),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        viewModel.scope = .all
        await viewModel.submit()

        #expect(viewModel.candidates == [SearchCandidate.repository(local.candidate)])
        #expect(viewModel.discoverySession?.phase == .failed("Search query planner failed"))
        #expect(viewModel.discoveryDiagnostics.first?.stage == .planning)
        #expect(viewModel.hasDiscoveryFailures)
        #expect(!viewModel.canContinueDiscovery)
    }

    @Test("正常达到核验上限有详情但不显示失败告警")
    func verificationLimitIsNotAFailure() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let candidate = Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy")
        let baseResult = Self.makeDiscoveryResult(candidate: candidate)
        let result = RepositoryDiscoveryResult(
            session: baseResult.session,
            repositories: baseResult.repositories,
            references: [],
            diagnostics: [.limit(stage: .verification)]
        )
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: history,
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: SearchCenterStubDiscoveryService(results: [result])
        )
        viewModel.query = "github 最近比较火的 linux 发行版"
        await viewModel.submit()

        #expect(viewModel.discoveryResultCount == 1)
        #expect(viewModel.discoveryDiagnostics.count == 1)
        #expect(!viewModel.hasDiscoveryFailures)
        #expect(viewModel.canContinueDiscovery)
        viewModel.clear()
        #expect(viewModel.discoveryDiagnostics.isEmpty)
        #expect(viewModel.discoveryResultCount == 0)
    }

    @Test("继续查找执行下一轮并更新缓存结果")
    func continueDiscoveryRunsNextRound() async throws {
        let history = GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager())
        let local = SearchCenterCountingStubProvider(
            source: .localKeyword,
            candidate: Self.makeCandidate(id: 1, owner: "apple", name: "swift")
        )
        let router = SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome())
        let discovery = SearchCenterStubDiscoveryService(results: [
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy"), round: 1),
            Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 10, owner: "linux", name: "os"), round: 2)
        ])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: [local]),
            historyRepository: history,
            intentRouter: router,
            discoveryService: discovery
        )

        viewModel.query = "github 最近比较火的 linux 发行版"
        viewModel.scope = .all
        await viewModel.submit()
        await viewModel.continueDiscovery()

        #expect(discovery.requestRounds == [1, 2])
        #expect(router.routeQueries.count == 1)
        #expect(viewModel.candidates.contains { $0.id == "repo:linux/os" })
        #expect(viewModel.candidates.contains { $0.id == "repo:omarchy/omarchy" })
        #expect(discovery.previousResults.compactMap { $0 }.last?.repositories.count == 1)
        #expect(viewModel.discoverySession?.round == 2)
        #expect(viewModel.canContinueDiscovery)

        await viewModel.submit()
        #expect(viewModel.candidates.contains { $0.id == "repo:linux/os" })
        #expect(viewModel.candidates.contains { $0.id == "repo:omarchy/omarchy" })
    }

    @Test("续查等待、零命中或失败都保留前轮结果及证据", arguments: [false, true])
    func continuationKeepsPreviousResultsOnEmptyOrFailure(fails: Bool) async throws {
        let first = Self.makeDiscoveryResult(candidate: Self.makeCandidate(id: 9, owner: "omarchy", name: "omarchy"))
        let next = RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: UUID(), round: 2, phase: fails ? .failed("offline") : .noResults
            ),
            repositories: [], references: [],
            diagnostics: fails ? [.failure(stage: .githubSearch, error: URLError(.notConnectedToInternet))] : []
        )
        let discovery = SearchCenterStubDiscoveryService(results: [first, next])
        let viewModel = SearchCenterViewModel(
            coordinator: SearchCoordinator(providers: []),
            historyRepository: GRDBSearchHistoryRepository(database: try InMemoryDatabaseManager()),
            intentRouter: SearchCenterStubIntentRouter(outcome: Self.makeSmartOutcome()),
            discoveryService: discovery
        )
        viewModel.query = "find linux distribution"
        await viewModel.submit()
        discovery.onDiscover = {
            #expect(viewModel.candidates.map(\.id) == ["repo:omarchy/omarchy"])
        }
        await viewModel.continueDiscovery()
        #expect(viewModel.candidates.map(\.id) == ["repo:omarchy/omarchy"])
        #expect(viewModel.discoverySession?.evidence == first.session.evidence)
        #expect(viewModel.discoverySession?.phase == (fails ? .partialFailure : .completed))
        #expect(viewModel.canContinueDiscovery)
    }

    /// 每次读取当前列表快照，避免断言复用操作前捕获的卡片。
    private static func firstRepository(in viewModel: SearchCenterViewModel) throws -> RepositoryCandidate {
        try #require(viewModel.candidates.compactMap { candidate -> RepositoryCandidate? in
            if case .repository(let repository) = candidate { return repository }
            return nil
        }.first)
    }

    private nonisolated static func makeCandidate(
        id: Int64 = 1,
        owner: String = "apple",
        name: String = "swift",
        isInLibrary: Bool = false
    ) -> RepositoryCandidate {
        let fullName = "\(owner)/\(name)"
        let card = RepoCardViewData(
            ghRepoId: id,
            fullName: fullName,
            owner: owner,
            repo: name,
            avatarURL: nil,
            description: "Swift language",
            language: "C++",
            starsCount: 70_000,
            forksCount: 10_000,
            isArchived: false,
            isFork: false,
            isPrivate: false,
            isStarred: false,
            isInLibrary: isInLibrary,
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            footerMetadata: nil,
            readStatus: nil,
            openSSFScore: nil,
            healthBadge: nil
        )
        return RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: id, owner: owner, name: name),
            card: card,
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )
    }

    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard condition() else { throw URLError(.timedOut) }
    }

    private nonisolated static func makeSmartOutcome() -> SearchIntentRoutingOutcome {
        SearchIntentRoutingOutcome(
            route: .smartDiscovery,
            decisionStatus: .completed,
            plannerStatus: .completed,
            plan: SearchDiscoveryPlan(
                intentSummary: "Find trending Linux distributions",
                githubQueries: ["trending linux distribution"],
                webQueries: ["trending linux distribution GitHub"],
                prefersFreshEvidence: true,
                strictConstraints: [],
                githubFilters: .empty
            )
        )
    }

    private nonisolated static func makeDiscoveryResult(
        candidate: RepositoryCandidate,
        round: Int = 1
    ) -> RepositoryDiscoveryResult {
        let evidenceID = round > 1 ? "round-\(round)-web-0-0" : "web-0-0"
        var item = candidate
        item.discovery = SearchDiscoveryAnnotation(
            reason: "Web evidence points to this repository",
            evidenceIDs: [evidenceID],
            rank: 0
        )
        let session = SearchDiscoverySession(
            generation: UUID(),
            round: round,
            phase: .completed,
            plan: makeSmartOutcome().plan,
            evidence: [
                SearchEvidence(
                    id: evidenceID,
                    kind: .web,
                    title: "Trending Linux distribution",
                    url: URL(string: "https://github.com/\(candidate.card.fullName)")
                )
            ],
            usedLLMCalls: 2,
            steps: [
                SearchDiscoveryStep(id: "planning", stage: .planning, state: .completed),
                SearchDiscoveryStep(id: "githubSearch-0", stage: .githubSearch, state: .completed),
                SearchDiscoveryStep(id: "verification", stage: .verification, state: .skipped),
                SearchDiscoveryStep(id: "ranking", stage: .ranking, state: .completed)
            ]
        )
        return RepositoryDiscoveryResult(
            session: session,
            repositories: [item],
            references: [],
            diagnostics: []
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("waitUntil timed out")
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

private struct SearchCenterSessionStubProvider: SearchProvider {
    let source: SearchSource = .github
    let candidate: RepositoryCandidate

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        SearchProviderPage(
            repositories: [candidate],
            references: [],
            totalCount: 1,
            hasNextPage: false
        )
    }
}

private struct SearchCenterSemanticFailureStubProvider: SearchProvider {
    let source: SearchSource = .localSemantic

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        throw SearchCenterSemanticFailure.unavailable
    }
}

private enum SearchCenterSemanticFailure: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "向量服务不可用"
    }
}

private struct SearchCenterPagingStubProvider: SearchProvider {
    let source: SearchSource = .github
    let firstPageCandidate: RepositoryCandidate
    let secondPageCandidate: RepositoryCandidate

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        if request.page == 1 {
            return SearchProviderPage(
                repositories: [firstPageCandidate],
                references: [],
                totalCount: 2,
                hasNextPage: true
            )
        }
        return SearchProviderPage(
            repositories: [secondPageCandidate],
            references: [],
            totalCount: 2,
            hasNextPage: false
        )
    }
}

/// 记录真实页码序列，并用一次失败模拟网络恢复，避免只验证最终条数
private actor SearchCenterRecordingPagingProvider: SearchProvider {
    nonisolated let source: SearchSource = .github
    let candidates: [RepositoryCandidate]
    var failSecondPageOnce: Bool
    private(set) var requests: [SearchRequest] = []

    init(candidates: [RepositoryCandidate], failSecondPageOnce: Bool = false) {
        self.candidates = candidates
        self.failSecondPageOnce = failSecondPageOnce
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        requests.append(request)
        if request.page == 2, failSecondPageOnce {
            failSecondPageOnce = false
            throw SearchCenterSemanticFailure.unavailable
        }
        return SearchProviderPage(
            repositories: Array(candidates.dropFirst(request.page - 1).prefix(1)),
            references: [],
            totalCount: candidates.count,
            hasNextPage: request.page < candidates.count
        )
    }
}

private final class CapturingWebSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource = .web
    var lastRequest: SearchRequest?

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lastRequest = request
        return .empty
    }
}

private final class WebLoadMoreStubProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource = .web
    private(set) var maxResultsRequests: [Int] = []

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        maxResultsRequests.append(request.externalSearchFilters.maxResults)
        let references = (0..<(request.externalSearchFilters.maxResults == 10 ? 1 : 2)).map { index in
            ReferenceCandidate(
                normalizedURL: URL(string: "https://example.com/\(index)")!,
                originalURL: URL(string: "https://example.com/\(index)")!,
                title: "Result \(index)",
                snippet: nil,
                domain: "example.com",
                source: .web,
                providerID: request.externalSearchProvider
            )
        }
        return SearchProviderPage(
            repositories: [],
            references: references,
            totalCount: 2,
            hasNextPage: request.externalSearchFilters.maxResults == 10
        )
    }
}

/// 立即返回指定 page，用于断言过程 chip 的终态。
private struct SearchCenterImmediateStubProvider: SearchProvider {
    let source: SearchSource
    let page: SearchProviderPage

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        page
    }
}

private final class SearchCenterCountingStubProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    let candidate: RepositoryCandidate
    private let lock = NSLock()
    private var value = 0

    var callCount: Int {
        lock.withLock { value }
    }

    init(source: SearchSource, candidate: RepositoryCandidate) {
        self.source = source
        self.candidate = candidate
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { value += 1 }
        var item = candidate
        item.sources = [source]
        return SearchProviderPage(
            repositories: [item],
            references: [],
            totalCount: 1,
            hasNextPage: false
        )
    }
}

/// 卡住语义（或任意）provider，直到测试显式 resume。
private struct SearchCenterGatedStubProvider: SearchProvider {
    let source: SearchSource
    let gate: SearchHoldGate
    let page: SearchProviderPage

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        await gate.wait()
        return page
    }
}

/// 让测试能在「关键词已返回、语义仍在跑」的中间态断言骨架和 chip。
private actor SearchHoldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isBlocked = false
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isBlocked || isReleased { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SearchCenterStubIntentRouter: SearchIntentRoutingProviding {
    let outcome: SearchIntentRoutingOutcome
    var delays: [String: TimeInterval] = [:]
    private(set) var routeQueries: [String] = []

    init(outcome: SearchIntentRoutingOutcome) {
        self.outcome = outcome
    }

    func route(query: String, explicitSmartDiscovery: Bool, deadline: Date) async -> SearchIntentRoutingOutcome {
        routeQueries.append(query)
        if let delay = delays[query] {
            // 模拟慢 Router；Task.sleep 响应取消，能验证取消是否真的向下传导。
            try? await Task.sleep(for: .seconds(delay))
        }
        return outcome
    }
}

@MainActor
private final class SearchCenterStubDiscoveryService: RepositoryDiscoveryProviding {
    private var results: [RepositoryDiscoveryResult]
    private(set) var requests: [SearchRequest] = []
    private(set) var requestRounds: [Int] = []
    private(set) var previousResults: [RepositoryDiscoveryResult?] = []
    private(set) var seedRepositorySnapshots: [[RepositoryCandidate]] = []
    var onDiscover: (() -> Void)?

    init(results: [RepositoryDiscoveryResult]) {
        self.results = results
    }

    func discover(
        query: String,
        request baseRequest: SearchRequest,
        initialPlan: SearchDiscoveryPlan?,
        generation: UUID,
        round: Int,
        budget: SearchDiscoveryBudget,
        initialLLMCalls: Int,
        deadline: Date?,
        previousResult: RepositoryDiscoveryResult?,
        seedRepositories: [RepositoryCandidate]
    ) async -> RepositoryDiscoveryResult {
        requests.append(baseRequest)
        requestRounds.append(round)
        previousResults.append(previousResult)
        seedRepositorySnapshots.append(seedRepositories)
        onDiscover?()
        let result = results.isEmpty
            ? RepositoryDiscoveryResult(
                session: SearchDiscoverySession(
                    generation: generation,
                    round: round,
                    phase: .failed("No stub result")
                ),
                repositories: [],
                references: [],
                diagnostics: []
            )
            : results.removeFirst()
        let session = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: result.session.phase,
            plan: result.session.plan,
            evidence: result.session.evidence,
            usedLLMCalls: result.session.usedLLMCalls,
            usedWebQueries: result.session.usedWebQueries,
            usedGitHubQueries: result.session.usedGitHubQueries,
            steps: result.steps
        )
        return RepositoryDiscoveryResult(
            session: session,
            repositories: result.repositories,
            references: result.references,
            diagnostics: result.diagnostics,
            steps: result.steps
        )
    }
}
