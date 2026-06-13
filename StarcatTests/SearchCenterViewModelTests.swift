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
        let defaults = try #require(UserDefaults(suiteName: "SearchCenterViewModelTests.\(UUID().uuidString)"))
        let history = SearchHistoryStore(defaults: defaults)
        let candidate = Self.makeCandidate()
        let provider = SearchCenterSessionStubProvider(candidate: candidate)
        let coordinator = SearchCoordinator(providers: [provider])
        let viewModel = SearchCenterViewModel(coordinator: coordinator, historyStore: history)

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

    private nonisolated static func makeCandidate() -> RepositoryCandidate {
        let card = RepoCardViewData(
            ghRepoId: 1,
            fullName: "apple/swift",
            owner: "apple",
            repo: "swift",
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
            readStatus: nil
        )
        return RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 1, owner: "apple", name: "swift"),
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
