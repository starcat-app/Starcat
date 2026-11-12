//
//  RepositoryDiscoveryServiceTests.swift
//  StarcatTests
//
//  覆盖智能发现的预算、部分失败、Web 提取核验与 Ranker 输出封闭集合校验。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repository Discovery Service")
@MainActor
struct RepositoryDiscoveryServiceTests {
    @Test("Web 证据提取仓库后核验并按 LLM 理由排序")
    func webEvidenceVerifiesAndRanksRepository() async {
        let swift = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let github = RecordingSearchProvider(source: .github) { request in
            #expect(request.scope == .github)
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: swift)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let web = RecordingSearchProvider(source: .web) { request in
            #expect(request.scope == .web)
            return SearchProviderPage(
                repositories: [],
                references: [Self.makeReference(url: "https://github.com/omarchy/omarchy")],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { owner, name in
            #expect(owner == "omarchy")
            #expect(name == "omarchy")
            return Self.makeRepoDTO(id: 999, owner: owner, name: name)
        }
        let ranker = StubDiscoveryRanker { _, _, _, _, _ in
            [
                SearchDiscoveryRankedItem(
                    id: "omarchy/omarchy",
                    reason: "Web 结果直接指向该 Linux 发行版仓库",
                    evidenceIDs: ["web-0-0"]
                ),
                SearchDiscoveryRankedItem(
                    id: "apple/swift",
                    reason: "GitHub 检索候选",
                    evidenceIDs: []
                )
            ]
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: web,
            verifier: verifier,
            ranker: ranker
        )

        let result = await service.discover(
            query: "github 最近比较火的 linux 发行版",
            request: SearchRequest(query: "linux distribution", includeWebInAll: true),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.map(\.card.fullName) == ["omarchy/omarchy", "apple/swift"])
        #expect(result.repositories.first?.discovery?.rank == 0)
        #expect(result.repositories.first?.discovery?.evidenceIDs == ["web-0-0"])
        #expect(result.session.usedWebQueries == 1)
        #expect(result.session.usedGitHubQueries == 1)
        #expect(result.session.usedLLMCalls == 2)
        #expect(result.session.phase == .completed)
        #expect(verifier.calls.map { "\($0.0)/\($0.1)" } == ["omarchy/omarchy"])
    }

    @Test("Web 与 Ranker 失败不清空 GitHub 结果且过滤越权输出")
    func partialFailuresKeepGitHubResults() async {
        let swift = Self.makeRepo(id: 1, owner: "apple", name: "swift")
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: swift)],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            throw TestError.failed
        }
        let ranker = StubDiscoveryRanker { _, _, _, _, _ in
            [
                SearchDiscoveryRankedItem(
                    id: "invented/repository",
                    reason: "Invented repository",
                    evidenceIDs: []
                ),
                SearchDiscoveryRankedItem(
                    id: "apple/swift",
                    reason: "Uses evidence that was never supplied",
                    evidenceIDs: ["missing-evidence"]
                )
            ]
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in
                throw TestError.failed
            },
            ranker: ranker
        )

        let result = await service.discover(
            query: "swift language",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.map(\.card.fullName) == ["apple/swift"])
        #expect(result.repositories.first?.discovery?.kind == .githubSearch)
        #expect(result.repositories.first?.discovery?.reason.isEmpty == true)
        #expect(result.references.isEmpty)
        #expect(result.warnings.contains { $0.contains("Web query failed") })
        #expect(result.session.usedLLMCalls == 2)
        #expect(result.session.phase == .completed)
    }

    @Test("预算截断 Planner 查询与 Web 提取仓库核验")
    func budgetLimitsPlanQueriesAndVerification() async {
        let planner = StubQueryPlanner(
            plan: SearchDiscoveryPlan(
                intentSummary: "Find trending Linux distributions",
                githubQueries: ["linux one", "linux two", "linux three"],
                webQueries: ["trending one", "trending two", "trending three"],
                prefersFreshEvidence: true,
                strictConstraints: ["trending"],
                githubFilters: .empty
            )
        )
        let github = RecordingSearchProvider(source: .github) { _ in .empty }
        let web = RecordingSearchProvider(source: .web) { request in
            let number = request.query.hasSuffix("one") ? 1 : 2
            return SearchProviderPage(
                repositories: [],
                references: (0..<3).map { item in
                    Self.makeReference(url: "https://github.com/owner-\(number)-\(item)/repo-\(number)-\(item)")
                },
                totalCount: 3,
                hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { owner, name in
            Self.makeRepoDTO(id: Int64(abs(owner.hashValue % 1_000_000)), owner: owner, name: name)
        }
        let service = RepositoryDiscoveryService(
            planner: planner,
            githubProvider: github,
            webProvider: web,
            verifier: verifier,
            ranker: nil
        )

        let result = await service.discover(
            query: "trending linux distribution",
            request: SearchRequest(query: "linux distribution", includeWebInAll: true),
            initialPlan: nil,
            initialLLMCalls: 0
        )

        #expect(planner.calls == 1)
        #expect(result.session.plan?.githubQueries.count == 2)
        #expect(result.session.plan?.webQueries.count == 2)
        #expect(result.session.usedGitHubQueries == 2)
        #expect(result.session.usedWebQueries == 2)
        #expect(result.session.usedLLMCalls == 1)
        #expect(verifier.calls.count == 5)
        #expect(result.warnings.contains("GitHub verification budget reached"))
        #expect(result.references.count == 6)
    }

    private static func makePlan() -> SearchDiscoveryPlan {
        SearchDiscoveryPlan(
            intentSummary: "Find trending Linux distributions",
            githubQueries: ["linux distribution"],
            webQueries: ["trending Linux distribution GitHub"],
            prefersFreshEvidence: true,
            strictConstraints: ["trending"],
            githubFilters: .empty
        )
    }

    private nonisolated static func makeRepo(id: Int64, owner: String, name: String) -> Repo {
        Repo(
            id: id,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: "\(name) repository",
            language: "Shell",
            starsCount: 1_000,
            forksCount: 10,
            watchersCount: 20,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    private nonisolated static func makeCandidate(repo: Repo) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
            card: repo.asCardData(),
            sources: [.github],
            localRepo: nil,
            remoteRepo: repo,
            semanticScore: nil
        )
    }

    private nonisolated static func makeReference(url: String) -> ReferenceCandidate {
        let originalURL = URL(string: url)!
        return ReferenceCandidate(
            normalizedURL: originalURL,
            originalURL: originalURL,
            title: "GitHub result",
            snippet: "A GitHub repository",
            domain: "github.com",
            source: .web
        )
    }

    private nonisolated static func makeRepoDTO(id: Int64, owner: String, name: String) -> GitHubRepoDTO {
        GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "\(owner)/\(name)",
            owner: GitHubUserDTO(
                id: 1,
                login: owner,
                name: nil,
                avatarUrl: nil,
                publicRepos: nil,
                followers: nil,
                following: nil,
                bio: nil,
                company: nil,
                location: nil,
                email: nil,
                blog: nil,
                twitterUsername: nil,
                htmlUrl: nil
            ),
            description: "\(name) distribution",
            language: "Shell",
            stargazersCount: 2_000,
            forksCount: 10,
            watchersCount: 20,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
    }
}

private enum TestError: Error {
    case failed
}

@MainActor
private final class StubQueryPlanner: SearchQueryPlannerProviding {
    private(set) var calls = 0
    private let planned: SearchDiscoveryPlan

    init(plan: SearchDiscoveryPlan) {
        self.planned = plan
    }

    func plan(
        query: String,
        allowWebEvidence: Bool,
        maxSeconds: TimeInterval
    ) async throws -> SearchDiscoveryPlan {
        calls += 1
        return planned
    }
}

private final class RecordingSearchProvider: SearchProvider, @unchecked Sendable {
    let source: SearchSource
    private let lock = NSLock()
    private var recordedRequests: [SearchRequest] = []
    private let handler: @Sendable (SearchRequest) async throws -> SearchProviderPage

    init(
        source: SearchSource,
        handler: @escaping @Sendable (SearchRequest) async throws -> SearchProviderPage
    ) {
        self.source = source
        self.handler = handler
    }

    var requests: [SearchRequest] {
        lock.withLock { recordedRequests }
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { recordedRequests.append(request) }
        return try await handler(request)
    }
}

private final class StubRepositoryVerifier: RepositoryVerificationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [(String, String)] = []
    private let handler: @Sendable (String, String) async throws -> GitHubRepoDTO

    init(handler: @escaping @Sendable (String, String) async throws -> GitHubRepoDTO) {
        self.handler = handler
    }

    var calls: [(String, String)] {
        lock.withLock { recordedCalls }
    }

    func repository(owner: String, name: String) async throws -> GitHubRepoDTO {
        lock.withLock { recordedCalls.append((owner, name)) }
        return try await handler(owner, name)
    }
}

@MainActor
private final class StubDiscoveryRanker: SearchDiscoveryRankerProviding {
    private let handler: @Sendable (
        String,
        SearchDiscoveryPlan,
        [SearchDiscoveryRankingCandidate],
        [SearchEvidence],
        TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem]

    init(
        handler: @escaping @Sendable (
            String,
            SearchDiscoveryPlan,
            [SearchDiscoveryRankingCandidate],
            [SearchEvidence],
            TimeInterval
        ) async throws -> [SearchDiscoveryRankedItem]
    ) {
        self.handler = handler
    }

    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem] {
        try await handler(query, plan, candidates, evidence, maxSeconds)
    }
}
