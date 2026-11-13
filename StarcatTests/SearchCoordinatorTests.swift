//
//  SearchCoordinatorTests.swift
//  StarcatTests
//
//  覆盖多 Provider 编排、部分失败、去重与 generation 防迟到覆盖。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Coordinator")
@MainActor
struct SearchCoordinatorTests {
    @Test("四来源过滤同一仓库且统计不因跨来源重复")
    func contentFilteringAcrossSources() async {
        let blocked = Self.makeRepo(id: 900, owner: "cirosantilli", name: "china-dictatorship")
        let safe = Self.makeRepo(id: 901, owner: "basecamp", name: "omarchy")
        let providers = SearchSource.allCases.map { source in
            StubSearchProvider(source: source) { _ in
                SearchProviderPage(
                    repositories: [blocked, safe].map { Self.makeCandidate(repo: $0, source: source) },
                    references: [], totalCount: 5_000, hasNextPage: false
                )
            }
        }
        let coordinator = SearchCoordinator(providers: providers)
        await coordinator.search(SearchRequest(query: "linux", includeWebInAll: true))
        #expect(coordinator.repositories.map(\.card.fullName) == ["basecamp/omarchy"])
        #expect(coordinator.contentSummary.checkedCount == 2)
        #expect(coordinator.contentSummary.hiddenCount == 1)
        #expect(coordinator.visibleCount(for: .github) == 1)
        #expect(coordinator.loadedPage(for: .github)?.totalCount == 5_000)
    }

    @Test("禁止查询在所有 Provider 发出前终止")
    func blockedQueryDoesNotCallProviders() async {
        let provider = CountingSearchProvider(source: .github, page: .empty)
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "购买枪支"))
        #expect(provider.callCount == 0)
        #expect(coordinator.blockedQuery != nil)
        #expect(coordinator.statuses.isEmpty)
        #expect(coordinator.contentSummary.hiddenCount == 1)
    }

    @Test("全隐藏页最多补一页且保留后续页码")
    func filteredPagesPreservePagination() async {
        let bad = Self.makeCandidate(
            repo: Self.makeRepo(id: 900, owner: "cirosantilli", name: "china-dictatorship"), source: .github
        )
        let safe = Self.makeCandidate(
            repo: Self.makeRepo(id: 901, owner: "basecamp", name: "omarchy"), source: .github
        )
        let provider = ContentPagingSearchProvider(source: .github, blocked: bad, safe: safe)
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "linux", scope: .github))
        #expect(await provider.requests.map(\.page) == [1, 2])
        #expect(coordinator.repositories.isEmpty)
        #expect(coordinator.currentGitHubPage == 2)
        #expect(coordinator.loadedPage(for: .github)?.hasNextPage == true)
        #expect(coordinator.contentSummary.hiddenCount == 1)
        await coordinator.loadMore(SearchRequest(query: "linux", scope: .github, page: 3), source: .github)
        #expect(coordinator.repositories.map(\.card.fullName) == ["basecamp/omarchy"])
        #expect(coordinator.currentGitHubPage == 3)
        #expect(coordinator.contentSummary.checkedCount == 2)
    }

    @Test("补页失败保留成功游标并允许从失败页重试")
    func failedContentRefillKeepsCursor() async {
        let bad = Self.makeCandidate(
            repo: Self.makeRepo(id: 900, owner: "cirosantilli", name: "china-dictatorship"), source: .github
        )
        let safe = Self.makeCandidate(
            repo: Self.makeRepo(id: 901, owner: "basecamp", name: "omarchy"), source: .github
        )
        let provider = ContentPagingSearchProvider(source: .github, blocked: bad, safe: safe, failRefillOnce: true)
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "linux", scope: .github))
        #expect(coordinator.currentGitHubPage == 1)
        #expect(coordinator.loadedPage(for: .github)?.hasNextPage == true)
        await coordinator.loadMore(SearchRequest(query: "linux", scope: .github, page: 2), source: .github)
        #expect(await provider.requests.map(\.page) == [1, 2, 2, 3])
        #expect(coordinator.currentGitHubPage == 3)
        #expect(coordinator.repositories.count == 1)
    }

    @Test("网页补取沿用扩大窗口协议而不是虚构页码")
    func webContentRefillTracksWindow() async {
        let bad = Self.makeCandidate(
            repo: Self.makeRepo(id: 900, owner: "cirosantilli", name: "china-dictatorship"), source: .web
        )
        let safe = Self.makeCandidate(
            repo: Self.makeRepo(id: 901, owner: "basecamp", name: "omarchy"), source: .web
        )
        let provider = ContentPagingSearchProvider(source: .web, blocked: bad, safe: safe)
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "linux", scope: .web))
        #expect(await provider.requests.map(\.externalSearchFilters.maxResults) == [10, 20])
        #expect(coordinator.currentWebMaxResults == 20)
        #expect(coordinator.loadedPage(for: .web)?.hasNextPage == true)
    }

    @Test("后返回的危险元数据使相同仓库在切换范围后仍隐藏")
    func blockedMetadataCannotReturnOnScopeChange() async {
        let safeRepo = Self.makeRepo(id: 904, owner: "example", name: "project")
        var unsafeRepo = safeRepo
        unsafeRepo.description = "出售毒品"
        let safe = Self.makeCandidate(repo: safeRepo, source: .localKeyword)
        let unsafe = Self.makeCandidate(repo: unsafeRepo, source: .github)
        let coordinator = SearchCoordinator(providers: [
            StubSearchProvider(source: .localKeyword) { _ in
                SearchProviderPage(repositories: [safe], references: [], totalCount: 1, hasNextPage: false)
            },
            StubSearchProvider(source: .github) { _ in
                SearchProviderPage(repositories: [unsafe], references: [], totalCount: 1, hasNextPage: false)
            }
        ])
        await coordinator.search(SearchRequest(query: "tools"))
        #expect(coordinator.repositories.isEmpty)
        await coordinator.updateScope(SearchRequest(query: "tools", scope: .local))
        #expect(coordinator.repositories.isEmpty)
        #expect(coordinator.visibleCount(for: .localKeyword) == 0)
    }

    @Test("单个 Provider 失败不清空其它来源结果")
    func partialFailureKeepsSuccessfulResults() async {
        let repo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let success = StubSearchProvider(source: .localKeyword) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let failure = StubSearchProvider(source: .github) { _ in
            throw TestError.failed
        }
        let coordinator = SearchCoordinator(providers: [success, failure])

        await coordinator.search(SearchRequest(query: "swift"))

        #expect(coordinator.repositories.map { $0.card.fullName } == ["apple/swift"])
        if case .failed = coordinator.status(for: .github) {
            // expected
        } else {
            Issue.record("GitHub source should fail independently")
        }
    }

    @Test("All scope 合并关键词与语义结果并保持关键词优先")
    func allScopeMergesKeywordAndSemanticResults() async {
        let keywordRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let semanticOnlyRepo = Self.makeRepo(id: 2, owner: "swiftlang", name: "swift-evolution")
        let keyword = StubSearchProvider(source: .localKeyword) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: keywordRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let semantic = StubSearchProvider(source: .localSemantic) { _ in
            var exactCandidate = Self.makeCandidate(repo: keywordRepo, source: .localSemantic)
            exactCandidate.semanticScore = 0.95
            exactCandidate.semanticReason = "name match"
            var semanticCandidate = Self.makeCandidate(repo: semanticOnlyRepo, source: .localSemantic)
            semanticCandidate.semanticScore = 0.88
            return SearchProviderPage(
                repositories: [semanticCandidate, exactCandidate],
                references: [],
                totalCount: 2,
                hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [semantic, keyword])

        await coordinator.search(SearchRequest(query: "swift", scope: .all))

        #expect(coordinator.repositories.map { $0.card.fullName } == [
            "apple/swift",
            "swiftlang/swift-evolution"
        ])
        #expect(coordinator.repositories[0].sources == Set<SearchSource>([.localKeyword, .localSemantic]))
        #expect(coordinator.repositories[0].semanticScore == 0.95)
        #expect(coordinator.repositories[0].semanticReason == "name match")
    }

    @Test("跨来源同一 Repo 合并 sources 并优先保留本地状态")
    func mergeDeduplicatesRepositories() {
        let local = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let localCandidate = Self.makeCandidate(repo: local, source: .localKeyword)
        let remoteCard = RepoCardViewData(
            ghRepoId: 42,
            fullName: "openai/codex",
            owner: "openai",
            repo: "codex",
            avatarURL: nil,
            description: "remote",
            language: "Rust",
            starsCount: 100,
            forksCount: 10,
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
        let remote = RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 42, owner: "openai", name: "codex"),
            card: remoteCard,
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )

        let result = SearchCoordinator.mergeRepositories(existing: [remote], incoming: [localCandidate])

        #expect(result.count == 1)
        #expect(result[0].sources == Set<SearchSource>([.github, .localKeyword]))
        #expect(result[0].localRepo?.id == 42)
        #expect(result[0].card.description == "local")
    }

    @Test("原地更新 Repo 知识库状态")
    func updateRepositoryLibraryStateRefreshesLoadedCandidate() async {
        let repo = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let provider = StubSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])

        await coordinator.search(SearchRequest(query: "codex", scope: .github))
        coordinator.updateRepositoryLibraryState(
            identity: RepoIdentity(ghRepoID: 42, owner: "openai", name: "codex"),
            state: .inLibrary,
            persistedRepo: repo
        )

        #expect(coordinator.repositories.first?.card.isInLibrary == true)
        #expect(coordinator.repositories.first?.localRepo?.id == 42)
        await coordinator.updateScope(SearchRequest(query: "codex", scope: .local))
        await coordinator.updateScope(SearchRequest(query: "codex", scope: .github))
        #expect(coordinator.repositories.first?.card.isInLibrary == true)
        #expect(coordinator.repositories.first?.localRepo?.id == 42)
    }

    @Test("知识库操作不会被迟到 Provider 的旧快照覆盖", arguments: [LibraryState.inLibrary, .outsideLibrary])
    func libraryMutationSurvivesLateResponse(state: LibraryState) async {
        let repo = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let gate = SearchCoordinatorHoldGate()
        var staleCandidate = Self.makeCandidate(repo: repo, source: .github)
        staleCandidate.localRepo = nil
        staleCandidate.remoteRepo = repo
        staleCandidate.card = staleCandidate.card.withLibraryState(
            state == .inLibrary ? .outsideLibrary : .inLibrary
        )
        let provider = GatedCountingSearchProvider(
            source: .github,
            gate: gate,
            page: SearchProviderPage(
                repositories: [staleCandidate], references: [], totalCount: 1, hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [provider])
        let task = Task { await coordinator.search(SearchRequest(query: "codex", scope: .github)) }
        await gate.waitUntilBlocked()
        coordinator.updateRepositoryLibraryState(
            identity: staleCandidate.identity, state: state, persistedRepo: repo
        )
        await gate.resume()
        await task.value
        #expect(coordinator.repositories.first?.card.isInLibrary == (state == .inLibrary))
        #expect(coordinator.repositories.first?.localRepo?.id == repo.id)
    }

    @Test("同一远端预览连续加入再移出知识库仍保留已落库身份")
    func repeatedLibraryMutationRetainsPersistedRepository() async {
        let repo = Self.makeRepo(id: 42, owner: "OpenAI", name: "Codex")
        let provider = StubSearchProvider(source: .github) { _ in
            var candidate = Self.makeCandidate(repo: repo, source: .github)
            candidate.localRepo = nil
            candidate.remoteRepo = repo
            return SearchProviderPage(
                repositories: [candidate], references: [], totalCount: 1, hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])
        let identity = RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name)
        await coordinator.search(SearchRequest(query: "codex", scope: .github))
        coordinator.updateRepositoryLibraryState(identity: identity, state: .inLibrary, persistedRepo: repo)
        coordinator.updateRepositoryLibraryState(identity: identity, state: .outsideLibrary, persistedRepo: nil)
        await coordinator.updateScope(SearchRequest(query: "codex", scope: .local))
        await coordinator.updateScope(SearchRequest(query: "codex", scope: .github))
        #expect(coordinator.repositories.first?.card.isInLibrary == false)
        #expect(coordinator.repositories.first?.localRepo?.id == repo.id)
    }

    @Test("隐藏来源的旧筛选结果不会因切换其他范围而被误用")
    func hiddenProviderKeepsItsOwnRequestIdentity() async {
        let provider = StubSearchProvider(source: .github) { request in
            let repo = Self.makeRepo(
                id: request.githubFilters.language == "Rust" ? 2 : 1,
                owner: "example",
                name: request.githubFilters.language ?? "any"
            )
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [], totalCount: 1, hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(
            query: "language", scope: .github, githubFilters: GitHubSearchFilters(language: "Swift")
        ))
        await coordinator.updateScope(SearchRequest(
            query: "language", scope: .local, githubFilters: GitHubSearchFilters(language: "Rust")
        ))
        await coordinator.updateScope(SearchRequest(
            query: "language", scope: .github, githubFilters: GitHubSearchFilters(language: "Rust")
        ))
        #expect(coordinator.repositories.map(\.card.ghRepoId) == [2])
    }

    @Test("空 query 清空结果和状态")
    func emptyQueryResets() async {
        let provider = StubSearchProvider(source: .localKeyword) { _ in .empty }
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "swift"))
        await coordinator.search(SearchRequest(query: "   "))
        #expect(coordinator.repositories.isEmpty)
        #expect(coordinator.statuses.isEmpty)
    }

    @Test("切换 all → local 复用本地结果且不重跑 Provider")
    func updateScopeAllToLocalReusesLocalProviders() async {
        let localRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let githubRepo = Self.makeRepo(id: 2, owner: "torvalds", name: "linux")
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = CountingSearchProvider(
            source: .localSemantic,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let github = CountingSearchProvider(
            source: .github,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: githubRepo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic, github])

        await coordinator.search(SearchRequest(query: "swift", scope: .all))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(coordinator.repositories.map(\.card.fullName).contains("torvalds/linux"))

        await coordinator.updateScope(SearchRequest(query: "swift", scope: .local))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(!coordinator.repositories.map(\.card.fullName).contains("torvalds/linux"))
        #expect(coordinator.repositories.map(\.card.fullName) == ["apple/swift"])
    }

    @Test("切换 local → all 只补跑 GitHub")
    func updateScopeLocalToAllFetchesMissingGitHub() async {
        let localRepo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let githubRepo = Self.makeRepo(id: 2, owner: "torvalds", name: "linux")
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = CountingSearchProvider(
            source: .localSemantic,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: localRepo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let github = CountingSearchProvider(
            source: .github,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: githubRepo, source: .github)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic, github])

        await coordinator.search(SearchRequest(query: "swift", scope: .local))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 0)

        await coordinator.updateScope(SearchRequest(query: "swift", scope: .all))
        #expect(keyword.callCount == 1)
        #expect(semantic.callCount == 1)
        #expect(github.callCount == 1)
        #expect(coordinator.repositories.map(\.card.fullName) == ["apple/swift", "torvalds/linux"])
    }

    @Test("切换 scope 不取消仍在进行的语义搜索")
    func updateScopeDoesNotCancelInFlightSemantic() async {
        let repo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let gate = SearchCoordinatorHoldGate()
        let keyword = CountingSearchProvider(
            source: .localKeyword,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localKeyword)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let semantic = GatedCountingSearchProvider(
            source: .localSemantic,
            gate: gate,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localSemantic)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        )
        let coordinator = SearchCoordinator(providers: [keyword, semantic])
        let searchTask = Task {
            await coordinator.search(SearchRequest(query: "swift", scope: .all))
        }
        await gate.waitUntilBlocked()
        await coordinator.updateScope(SearchRequest(query: "swift", scope: .local))
        #expect(semantic.callCount == 1)
        await gate.resume()
        await searchTask.value
        #expect(semantic.callCount == 1)
        if case .loaded = coordinator.status(for: .localSemantic) {
            // expected
        } else {
            Issue.record("semantic results should still land after scope switch")
        }
    }

    @Test("GitHub 翻页不取消隐藏范围内仍在执行的语义搜索")
    func paginationPreservesOtherInFlightProviders() async {
        let repo = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let gate = SearchCoordinatorHoldGate()
        let semantic = GatedCountingSearchProvider(
            source: .localSemantic, gate: gate,
            page: SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .localSemantic)],
                references: [], totalCount: 1, hasNextPage: false
            )
        )
        let github = StubSearchProvider(source: .github) { request in
            let repo = Self.makeRepo(id: Int64(request.page + 1), owner: "example", name: "\(request.page)")
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [], totalCount: 3, hasNextPage: request.page < 3
            )
        }
        let coordinator = SearchCoordinator(providers: [semantic, github])
        let task = Task { await coordinator.search(SearchRequest(query: "swift", scope: .all)) }
        await gate.waitUntilBlocked()
        // 两个来源并发，等 GitHub 首页落地后才模拟用户点击下一页
        for _ in 0..<1_000 {
            if case .loaded = coordinator.status(for: .github) { break }
            await Task.yield()
        }
        await coordinator.updateScope(SearchRequest(query: "swift", scope: .github))
        await coordinator.loadMore(SearchRequest(query: "swift", scope: .github, page: 2), source: .github)
        await gate.resume()
        await task.value
        await coordinator.updateScope(SearchRequest(query: "swift", scope: .all))

        #expect(semantic.callCount == 1)
        #expect(coordinator.repositories.map(\.card.ghRepoId) == [1, 2, 3])
        #expect(coordinator.currentGitHubPage == 2)
    }

    @Test("忽略不响应取消的旧查询结果")
    func latePreviousQueryCannotReplaceCurrentResults() async {
        let gate = SearchCoordinatorHoldGate()
        let provider = StubSearchProvider(source: .github) { request in
            if request.query == "old" { await gate.wait() }
            let repo = Self.makeRepo(id: request.query == "old" ? 1 : 2, owner: "example", name: request.query)
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [], totalCount: 1, hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])
        let task = Task { await coordinator.search(SearchRequest(query: "old", scope: .github)) }
        await gate.waitUntilBlocked()
        await coordinator.search(SearchRequest(query: "new", scope: .github))
        await gate.resume()
        await task.value
        #expect(coordinator.repositories.map(\.card.ghRepoId) == [2])
    }

    @Test("在途来源筛选变化后丢弃迟到旧结果")
    func incompatibleInFlightSourceIsReplaced() async {
        let gate = SearchCoordinatorHoldGate()
        let provider = StubSearchProvider(source: .github) { request in
            let isOld = request.githubFilters.language == "Swift"
            if isOld { await gate.wait() }
            let repo = Self.makeRepo(id: isOld ? 1 : 2, owner: "example", name: isOld ? "old" : "new")
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: repo, source: .github)],
                references: [], totalCount: 1, hasNextPage: false
            )
        }
        let coordinator = SearchCoordinator(providers: [provider])
        let task = Task {
            await coordinator.search(SearchRequest(
                query: "language", scope: .github, githubFilters: GitHubSearchFilters(language: "Swift")
            ))
        }
        await gate.waitUntilBlocked()
        await coordinator.updateScope(SearchRequest(
            query: "language", scope: .github, githubFilters: GitHubSearchFilters(language: "Rust")
        ))
        await gate.resume()
        await task.value
        #expect(coordinator.repositories.map(\.card.ghRepoId) == [2])
    }

    nonisolated fileprivate static func makeRepo(id: Int64, owner: String, name: String) -> Repo {
        Repo(
            id: id,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: "local",
            language: "Swift",
            starsCount: 10,
            forksCount: 2,
            watchersCount: 10,
            topics: nil,
            license: "Apache-2.0",
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    nonisolated fileprivate static func makeCandidate(repo: Repo, source: SearchSource) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
            card: repo.asCardData(),
            sources: [source],
            localRepo: repo,
            remoteRepo: nil,
            semanticScore: nil
        )
    }
}

private struct StubSearchProvider: SearchProvider {
    let source: SearchSource
    let handler: @Sendable (SearchRequest) async throws -> SearchProviderPage

    init(
        source: SearchSource,
        handler: @escaping @Sendable (SearchRequest) async throws -> SearchProviderPage
    ) {
        self.source = source
        self.handler = handler
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        try await handler(request)
    }
}

/// 记录自动补页边界，支持一次失败以验证重试游标不会提前推进。
private actor ContentPagingSearchProvider: SearchProvider {
    nonisolated let source: SearchSource
    let blocked: RepositoryCandidate
    let safe: RepositoryCandidate
    var failRefillOnce: Bool
    private(set) var requests: [SearchRequest] = []

    init(source: SearchSource, blocked: RepositoryCandidate, safe: RepositoryCandidate, failRefillOnce: Bool = false) {
        self.source = source
        self.blocked = blocked
        self.safe = safe
        self.failRefillOnce = failRefillOnce
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        requests.append(request)
        let number = source == .web ? request.externalSearchFilters.maxResults / 10 : request.page
        if number == 2, failRefillOnce {
            failRefillOnce = false
            throw URLError(.cannotConnectToHost)
        }
        return SearchProviderPage(
            repositories: [number < 3 ? blocked : safe],
            references: [], totalCount: 100, hasNextPage: number < 3
        )
    }
}

private final class CountingSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    let page: SearchProviderPage
    private let lock = NSLock()
    private var value = 0

    var callCount: Int {
        lock.withLock { value }
    }

    init(source: SearchSource, page: SearchProviderPage) {
        self.source = source
        self.page = page
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { value += 1 }
        return page
    }
}

private final class GatedCountingSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    let gate: SearchCoordinatorHoldGate
    let page: SearchProviderPage
    private let lock = NSLock()
    private var value = 0

    var callCount: Int {
        lock.withLock { value }
    }

    init(source: SearchSource, gate: SearchCoordinatorHoldGate, page: SearchProviderPage) {
        self.source = source
        self.gate = gate
        self.page = page
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { value += 1 }
        await gate.wait()
        return page
    }
}

/// 卡住单个 Provider，直到测试显式 resume。
private actor SearchCoordinatorHoldGate {
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
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum TestError: Error {
    case failed
}
