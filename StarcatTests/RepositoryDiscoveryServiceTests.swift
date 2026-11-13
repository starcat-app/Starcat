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
        #expect(result.diagnostics.contains { $0.stage == .webSearch && $0.isFailure })
        #expect(result.diagnostics.contains {
            $0.stage == .ranking
                && $0.isFailure
                && $0.technicalDetail?.contains("No ranked candidate passed validation") == true
        })
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
        #expect(result.diagnostics.contains { $0.stage == .verification && $0.kind == .limit })
        #expect(!result.diagnostics.contains { $0.isFailure })
        #expect(result.references.count == 6)
    }

    @Test("恰好核验完五个仓库时不误报上限")
    func completedVerificationAtLimitHasNoWarning() async {
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [],
                references: (0..<5).map { number in
                    Self.makeReference(url: "https://github.com/owner/repo-\(number)")
                },
                totalCount: 5,
                hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { owner, name in
            Self.makeRepoDTO(id: Int64(name.suffix(1)) ?? 1, owner: owner, name: name)
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: web,
            verifier: verifier,
            ranker: nil
        )

        let result = await service.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux", includeWebInAll: true),
            initialPlan: Self.makePlan()
        )

        #expect(verifier.calls.count == 5)
        #expect(result.repositories.count == 5)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("网页与 GitHub 重复身份不再核验，不占用核验上限")
    func githubSearchHitDoesNotConsumeVerificationBudget() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [],
                references: [Self.makeReference(url: "https://github.com/Apple/Swift")],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { _, _ in throw TestError.failed }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: web,
            verifier: verifier,
            ranker: nil
        )

        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift", includeWebInAll: true),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.count == 1)
        #expect(verifier.calls.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("仓库核验 404 保留仓库名和原因，其他已核验结果继续展示")
    func verificationFailureRetainsCauseAndSuccessfulRepositories() async {
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [],
                references: [
                    Self.makeReference(url: "https://github.com/owner/missing"),
                    Self.makeReference(url: "https://github.com/owner/existing")
                ],
                totalCount: 2,
                hasNextPage: false
            )
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: web,
            verifier: StubRepositoryVerifier { owner, name in
                if name == "missing" { throw NetworkError.notFound }
                return Self.makeRepoDTO(id: 1, owner: owner, name: name)
            },
            ranker: nil
        )

        let result = await service.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux", includeWebInAll: true),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.map(\.card.fullName) == ["owner/existing"])
        #expect(result.repositories.first?.discovery?.kind == .githubVerification)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.stage == .verification)
        #expect(result.diagnostics.first?.context == "owner/missing")
        #expect(result.diagnostics.first?.statusCode == 404)
        #expect(result.diagnostics.first?.technicalDetail?.isEmpty == false)
        #expect(result.diagnostics.first?.isFailure == true)
        #expect(result.diagnostics.first?.message.contains("search.discovery") == false)
    }

    @Test("重排超时保留检索候选并给出重排步骤的失败详情")
    func rankingTimeoutRetainsCandidatesAndDiagnostic() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker { _, _, _, _, _ in throw URLError(.timedOut) }
        )

        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.count == 1)
        #expect(result.repositories.first?.discovery?.kind == .githubSearch)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.stage == .ranking)
        #expect(result.diagnostics.first?.isFailure == true)
        #expect(result.diagnostics.first?.recovery?.isEmpty == false)
    }

    @Test("LLM 达到调用上限只给信息提示，候选仍可展示")
    func rankingBudgetIsInformational() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker { _, _, _, _, _ in throw TestError.failed }
        )

        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan(),
            initialLLMCalls: SearchDiscoveryBudget.firstRound.maxLLMCalls
        )

        #expect(result.repositories.count == 1)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.stage == .ranking)
        #expect(result.diagnostics.first?.kind == .limit)
        #expect(!result.diagnostics.contains { $0.isFailure })
    }

    @Test("专用 Rerank 不消耗 LLM 调用上限")
    func dedicatedRerankRunsAfterLLMBudgetIsExhausted() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker(kind: .dedicatedRerank) { _, _, candidates, _, _ in
                [SearchDiscoveryRankedItem(
                    id: candidates[0].id,
                    reason: "Relevant to the query",
                    evidenceIDs: []
                )]
            }
        )

        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan(),
            initialLLMCalls: SearchDiscoveryBudget.firstRound.maxLLMCalls
        )

        #expect(result.session.usedLLMCalls == SearchDiscoveryBudget.firstRound.maxLLMCalls)
        #expect(result.diagnostics.isEmpty)
        #expect(result.repositories.first?.discovery?.kind == .modelMatch)
        #expect(result.repositories.first?.discovery?.rank == 0)
    }

    @Test("发现步骤按实际执行顺序记录成功、跳过与失败")
    func discoveryRecordsRealExecutionSteps() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                references: [],
                totalCount: 1,
                hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, _, _, _ in
            [SearchDiscoveryRankedItem(
                id: "apple/swift",
                reason: "Relevant",
                evidenceIDs: []
            )]
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: ranker
        )

        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan()
        )

        #expect(result.steps.map(\.stage) == [.githubSearch, .verification, .ranking])
        #expect(result.steps.first(where: { $0.stage == .githubSearch })?.state == .completed)
        #expect(result.steps.first(where: { $0.stage == .verification })?.state == .skipped)
        #expect(result.steps.first(where: { $0.stage == .ranking })?.state == .completed)
        #expect(result.steps.first(where: { $0.stage == .ranking })?.model == nil)
        #expect(result.session.steps == result.steps)
    }

    @Test("Planner 成功与失败都会落到步骤详情")
    func plannerOutcomesAppearInSteps() async {
        let planner = StubQueryPlanner(plan: Self.makePlan())
        let service = RepositoryDiscoveryService(
            planner: planner,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }
        )

        let success = await service.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux"),
            initialPlan: nil,
            initialLLMCalls: 0
        )

        #expect(success.steps.first?.stage == .planning)
        #expect(success.steps.first?.state == .completed)
        #expect(success.steps.first?.detail?.isEmpty == false)

        let failingPlanner = StubQueryPlanner(plan: Self.makePlan())
        failingPlanner.error = TestError.failed
        let failingService = RepositoryDiscoveryService(
            planner: failingPlanner,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }
        )
        let failure = await failingService.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux"),
            initialPlan: nil,
            initialLLMCalls: 0
        )

        #expect(failure.steps.first?.stage == .planning)
        #expect(failure.steps.first?.state == .failed)
        #expect(failure.session.phase.isFailed)
    }

    @Test("重排使用剩余时限，超时保留已有候选")
    func rankingUsesSharedDeadline() async {
        let candidate = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [candidate], references: [], totalCount: 1, hasNextPage: false)
        }
        let ranker = StubDiscoveryRanker(kind: .dedicatedRerank) { _, _, _, _, seconds in
            #expect(seconds > 0 && seconds <= 0.05)
            try await Task.sleep(for: .seconds(0.4))
            return []
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: ranker
        )
        let start = Date()
        let result = await service.discover(
            query: "swift",
            request: SearchRequest(query: "swift"),
            initialPlan: Self.makePlan(),
            deadline: start.addingTimeInterval(0.05)
        )
        #expect(Date().timeIntervalSince(start) < 0.3)
        #expect(result.repositories.map(\.card.fullName) == ["apple/swift"])
        #expect(result.steps.contains { $0.stage == .ranking && $0.state == .failed })
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
    var error: Error?

    init(plan: SearchDiscoveryPlan) {
        self.planned = plan
    }

    func plan(
        query: String,
        allowWebEvidence: Bool,
        maxSeconds: TimeInterval
    ) async throws -> SearchDiscoveryPlan {
        calls += 1
        if let error { throw error }
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
    let kind: SearchDiscoveryRankerKind
    private let handler: @Sendable (
        String,
        SearchDiscoveryPlan,
        [SearchDiscoveryRankingCandidate],
        [SearchEvidence],
        TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem]

    init(
        kind: SearchDiscoveryRankerKind = .chat,
        handler: @escaping @Sendable (
            String,
            SearchDiscoveryPlan,
            [SearchDiscoveryRankingCandidate],
            [SearchEvidence],
            TimeInterval
        ) async throws -> [SearchDiscoveryRankedItem]
    ) {
        self.kind = kind
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
