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

    @Test("空 query 清空结果和状态")
    func emptyQueryResets() async {
        let provider = StubSearchProvider(source: .localKeyword) { _ in .empty }
        let coordinator = SearchCoordinator(providers: [provider])
        await coordinator.search(SearchRequest(query: "swift"))
        await coordinator.search(SearchRequest(query: "   "))
        #expect(coordinator.repositories.isEmpty)
        #expect(coordinator.statuses.isEmpty)
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

private enum TestError: Error {
    case failed
}
