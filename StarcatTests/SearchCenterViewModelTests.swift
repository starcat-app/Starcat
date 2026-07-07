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

    private nonisolated static func makeCandidate(
        id: Int64 = 1,
        owner: String = "apple",
        name: String = "swift"
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
            isInLibrary: false,
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
