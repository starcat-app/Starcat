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
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
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
