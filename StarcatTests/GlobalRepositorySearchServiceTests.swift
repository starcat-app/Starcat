//
//  GlobalRepositorySearchServiceTests.swift
//  StarcatTests
//
//  覆盖 Alfred/MCP 全局仓库搜索的合并顺序、部分失败和公共 DTO。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Global Repository Search")
@MainActor
struct GlobalRepositorySearchServiceTests {
    @Test("本地优先合并同仓库并保留双来源")
    func localResultWinsAndMergesSources() async throws {
        let localRepo = Self.makeRepo(
            id: 42,
            owner: "OpenAI",
            name: "Codex",
            description: "local description",
            isStarred: true
        )
        let remoteRepo = Self.makeRepo(
            id: 42,
            owner: "openai",
            name: "codex",
            description: "remote description",
            isStarred: false
        )
        let localPage = Self.page(candidate: Self.candidate(repo: localRepo, source: .localKeyword))
        let remotePage = Self.page(candidate: Self.candidate(repo: remoteRepo, source: .github))
        let service = GlobalRepositorySearchService(
            localProvider: StubGlobalSearchProvider(source: .localKeyword) { request in
                #expect(request.scope == .local)
                return localPage
            },
            githubProvider: StubGlobalSearchProvider(source: .github) { request in
                #expect(request.scope == .github)
                return remotePage
            }
        )

        let snapshot = try await service.search(
            query: "codex",
            limit: 30,
            sources: [.local, .github]
        )

        #expect(snapshot.repositories.count == 1)
        #expect(snapshot.repositories[0].displayRepo?.description == "local description")
        #expect(snapshot.repositories[0].sources == [.localKeyword, .github])

        let dto = MCPGlobalRepositorySearchResult(snapshot: snapshot)
        #expect(dto.items[0].primary_source == "local")
        #expect(dto.items[0].open_url == "starcat://repo/OpenAI/Codex?v=1&rid=42")
        #expect(dto.items[0].sources == ["local", "github"])
    }

    @Test("GitHub 失败时保留本地结果并返回归一化 warning")
    func githubFailureKeepsLocalResults() async throws {
        let localRepo = Self.makeRepo(
            id: 1,
            owner: "apple",
            name: "swift",
            description: nil,
            isStarred: true
        )
        let localPage = Self.page(candidate: Self.candidate(repo: localRepo, source: .localKeyword))
        let service = GlobalRepositorySearchService(
            localProvider: StubGlobalSearchProvider(source: .localKeyword) { _ in
                localPage
            },
            githubProvider: StubGlobalSearchProvider(source: .github) { _ in
                throw TestFailure.failed
            }
        )

        let snapshot = try await service.search(
            query: "swift",
            limit: 30,
            sources: [.local, .github]
        )

        #expect(snapshot.repositories.map(\.identity.normalizedFullName) == ["apple/swift"])
        #expect(snapshot.providers[.local]?.status == .success)
        #expect(snapshot.providers[.github]?.status == .failed)
        #expect(snapshot.warnings == ["GitHub repository search is currently unavailable."])
    }

    @Test("只请求 GitHub 时远端结果打开 GitHub")
    func githubOnlyUsesPublicURL() async throws {
        let remoteRepo = Self.makeRepo(
            id: 7,
            owner: "rust-lang",
            name: "rust",
            description: "Rust",
            isStarred: false
        )
        let remotePage = Self.page(candidate: Self.candidate(repo: remoteRepo, source: .github))
        let service = GlobalRepositorySearchService(
            localProvider: StubGlobalSearchProvider(source: .localKeyword) { _ in .empty },
            githubProvider: StubGlobalSearchProvider(source: .github) { _ in
                remotePage
            }
        )

        let snapshot = try await service.search(
            query: "rust",
            limit: 30,
            sources: [.github]
        )
        let item = MCPGlobalRepositorySearchResult(snapshot: snapshot).items[0]

        #expect(item.primary_source == "github")
        #expect(item.open_url == "https://github.com/rust-lang/rust")
        #expect(item.icon_url == "https://github.com/rust-lang.png?size=80")
    }

    private static func page(candidate: RepositoryCandidate) -> SearchProviderPage {
        SearchProviderPage(
            repositories: [candidate],
            references: [],
            totalCount: 1,
            hasNextPage: false
        )
    }

    private static func candidate(repo: Repo, source: SearchSource) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
            card: repo.asCardData(),
            sources: [source],
            localRepo: source == .localKeyword ? repo : nil,
            remoteRepo: source == .github ? repo : nil,
            semanticScore: nil
        )
    }

    private static func makeRepo(
        id: Int64,
        owner: String,
        name: String,
        description: String?,
        isStarred: Bool
    ) -> Repo {
        var repo = Repo.makeMinimal(owner: owner, name: name)
        repo.id = id
        repo.fullName = "\(owner)/\(name)"
        repo.description = description
        repo.language = "Swift"
        repo.starsCount = 1_234
        repo.isStarred = isStarred
        return repo
    }
}

private struct StubGlobalSearchProvider: SearchProvider {
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

private enum TestFailure: Error {
    case failed
}
