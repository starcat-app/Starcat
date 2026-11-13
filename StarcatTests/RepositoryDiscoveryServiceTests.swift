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
    @Test("只有介绍文章时提取原文项目名，并由 GitHub 结果建立仓库与证据")
    func articleNameResolvesToRealRepository() async {
        let extractor = StubArticleExtractor { evidence in
            #expect(evidence.map(\.id) == ["web-0-0"])
            return [SearchArticleCandidate(name: "Omarchy", evidenceIDs: ["web-0-0"])]
        }
        let github = RecordingSearchProvider(source: .github) { request in
            guard request.query == "Omarchy in:name" else { return .empty }
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "basecamp", name: "omarchy"))],
                references: [], totalCount: 1, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, _, _ in
            #expect(candidates.map(\.id) == ["basecamp/omarchy"])
            #expect(candidates.first?.evidenceIDs == ["web-0-0", "github-0-0"])
            return [SearchDiscoveryRankedItem(
                id: "basecamp/omarchy", reason: "Named in the introduction", evidenceIDs: ["web-0-0"]
            )]
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, articleExtractor: extractor, githubProvider: github,
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: ranker, webEvidenceAllowed: { _ in true }
        ).discover(query: "forgotten Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan())
        #expect(result.repositories.map(\.card.fullName) == ["basecamp/omarchy"])
        #expect(result.repositories.first?.discovery?.evidenceIDs == ["web-0-0"])
        #expect(result.session.usedLLMCalls == 3)
        #expect(github.requests.map(\.query) == ["Omarchy in:name", "linux distribution"])
        #expect(result.steps.contains { $0.stage == .extraction && $0.state == .completed })
    }

    @Test("虚构名称、无效引用及搜索语法不能产生文章仓库查询", arguments: [
        SearchArticleCandidate(name: "InventedProject", evidenceIDs: ["web-0-0"]),
        SearchArticleCandidate(name: "Omarchy", evidenceIDs: ["web-9-9"]),
        SearchArticleCandidate(name: "Omarchy", evidenceIDs: ["web-0-0", "unknown"]),
        SearchArticleCandidate(name: "Omarchy stars:>0", evidenceIDs: ["web-0-0"]),
        SearchArticleCandidate(name: "march", evidenceIDs: ["web-0-0"]),
        SearchArticleCandidate(name: "Omarchy", evidenceIDs: [])
    ])
    func ungroundedArticleNamesDoNotReachGitHub(_ candidate: SearchArticleCandidate) async {
        let github = RecordingSearchProvider(source: .github) { _ in .empty }
        let result = await RepositoryDiscoveryService(
            planner: nil, articleExtractor: StubArticleExtractor { _ in [candidate] }, githubProvider: github,
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, webEvidenceAllowed: { _ in true }
        ).discover(query: "Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan())
        #expect(github.requests.map(\.query) == ["linux distribution"])
        #expect(result.repositories.isEmpty)
    }

    @Test("GitHub 没有同名仓库时保留文章，不能把相似名字当成核验成功", arguments: [false, true])
    func articleNameRequiresGitHubMatch(returnsSimilarName: Bool) async {
        let result = await RepositoryDiscoveryService(
            planner: nil,
            articleExtractor: StubArticleExtractor { _ in [SearchArticleCandidate(name: "Omarchy", evidenceIDs: ["web-0-0"])] },
            githubProvider: RecordingSearchProvider(source: .github) { request in
                guard returnsSimilarName, request.query == "Omarchy in:name" else { return .empty }
                return SearchProviderPage(
                    repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "other", name: "omarchy-docs"))],
                    references: [], totalCount: 1, hasNextPage: false
                )
            },
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, webEvidenceAllowed: { _ in true }
        ).discover(query: "Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan())
        #expect(result.repositories.isEmpty)
        #expect(result.references.count == 1)
    }

    @Test("文章标题或片段中的明确 GitHub 链接直接核验，不额外调用模型", arguments: [false, true])
    func articleExplicitURLSkipsExtraction(inTitle: Bool) async {
        let extractor = StubArticleExtractor { _ in Issue.record("Explicit URLs must skip extraction"); return [] }
        let verifier = StubRepositoryVerifier { owner, name in
            #expect(owner == "basecamp" && name == "omarchy")
            return Self.makeRepoDTO(id: 1, owner: owner, name: name)
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, articleExtractor: extractor,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: RecordingSearchProvider(source: .web) { _ in
                Self.makeArticlePage(
                    title: inTitle ? "Introducing https://github.com/basecamp/omarchy" : "Linux introduction",
                    snippet: inTitle ? nil : "Source: https://github.com/basecamp/omarchy."
                )
            },
            verifier: verifier, webEvidenceAllowed: { _ in true }
        ).discover(query: "Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan())
        #expect(result.repositories.map(\.card.fullName) == ["basecamp/omarchy"])
        #expect(result.repositories.first?.discovery?.evidenceIDs == ["web-0-0"])
        #expect(verifier.calls.count == 1)
        #expect(extractor.calls == 0)
        #expect(result.session.usedLLMCalls == 1)
    }

    @Test("AI 联网关闭时网页展示开关不能授权文章提取")
    func disabledWebContextStopsArticleExtraction() async {
        let extractor = StubArticleExtractor { _ in Issue.record("Web context is disabled"); return [] }
        let web = RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() }
        _ = await RepositoryDiscoveryService(
            planner: nil, articleExtractor: extractor,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty }, webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, webEvidenceAllowed: { _ in false }
        ).discover(
            query: "Linux distribution", request: SearchRequest(query: "Linux", includeWebInAll: true),
            initialPlan: Self.makePlan()
        )
        #expect(web.requests.isEmpty)
        #expect(extractor.calls == 0)
    }

    @Test("文章提取不能占用 Chat 重排预留的最后一次调用")
    func articleExtractionReservesRankingBudget() async {
        let extractor = StubArticleExtractor { _ in Issue.record("No extraction budget remains"); return [] }
        let result = await RepositoryDiscoveryService(
            planner: nil, articleExtractor: extractor,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker { _, _, _, _, _ in [] }, webEvidenceAllowed: { _ in true }
        ).discover(
            query: "Linux distribution", request: SearchRequest(query: "Linux"),
            initialPlan: Self.makePlan(), initialLLMCalls: 2
        )
        #expect(extractor.calls == 0)
        #expect(result.session.usedLLMCalls == 2)
        #expect(result.diagnostics.contains { $0.stage == .extraction && $0.kind == .limit })
    }

    @Test("文章提取共享整轮截止时间，用户取消不记为失败", arguments: [false, true])
    func articleExtractionDeadlineAndCancellation(cancel: Bool) async throws {
        let extractor = StubArticleExtractor { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        let service = RepositoryDiscoveryService(
            planner: nil, articleExtractor: extractor,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, webEvidenceAllowed: { _ in true }
        )
        let task = Task {
            await service.discover(
                query: "Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan(),
                deadline: Date().addingTimeInterval(cancel ? 15 : 0.2)
            )
        }
        try await Self.waitUntil { extractor.calls == 1 }
        if cancel { task.cancel() }
        let result = await task.value
        if cancel {
            #expect(result.session.phase == .cancelled)
            #expect(result.diagnostics.isEmpty)
        } else {
            let expected = UserFacingError.map(
                URLError(.timedOut), operation: String.l10n("search.discovery.phase.extracting"), service: "AI"
            )
            #expect(result.diagnostics.first { $0.stage == .extraction }?.message == expected.message)
            #expect(result.session.usedLLMCalls == 2)
        }
    }

    @Test("文章定位到私仓后仍遵守远程重排隐私边界", arguments: [false, true])
    func articlePrivateRepositoriesKeepRankingBoundary(usesLocalOnly: Bool) async {
        let ranker = StubDiscoveryRanker(usesLocalOnly: usesLocalOnly) { _, _, candidates, evidence, _ in
            #expect(candidates.contains { $0.id == "team/omarchy" } == usesLocalOnly)
            #expect(evidence.contains { $0.repositoryFullName == "team/omarchy" } == usesLocalOnly)
            return candidates.map { SearchDiscoveryRankedItem(id: $0.id, reason: "Relevant", evidenceIDs: $0.evidenceIDs) }
        }
        _ = await RepositoryDiscoveryService(
            planner: nil,
            articleExtractor: StubArticleExtractor { _ in [SearchArticleCandidate(name: "Omarchy", evidenceIDs: ["web-0-0"])] },
            githubProvider: RecordingSearchProvider(source: .github) { request in
                guard request.query == "Omarchy in:name" else { return .empty }
                return SearchProviderPage(
                    repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "team", name: "omarchy", isPrivate: true))],
                    references: [], totalCount: 1, hasNextPage: false
                )
            },
            webProvider: RecordingSearchProvider(source: .web) { _ in Self.makeArticlePage() },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: ranker, webEvidenceAllowed: { _ in true }
        ).discover(
            query: "Linux distribution", request: SearchRequest(query: "Linux"), initialPlan: Self.makePlan(),
            seedRepositories: [Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "public", name: "safe"))]
        )
    }

    @Test("基础候选和新增发现共用重排池与证据，保留知识库事实")
    func baseAndDiscoveredRepositoriesShareRanking() async {
        let repo = Self.makeRepo(id: 1, owner: "local", name: "favorite")
        var favorite = Self.makeCandidate(repo: repo)
        favorite.card = repo.asCardData(isInLibrary: true)
        favorite.sources = [.localKeyword]
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [
                    Self.makeCandidate(repo: repo),
                    Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "external", name: "better"))
                ], references: [], totalCount: 2, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, _, _ in
            #expect(Set(candidates.map(\.id)) == ["local/favorite", "external/better"])
            #expect(candidates.first { $0.id == "local/favorite" }?.isInLibrary == true)
            #expect(candidates.first { $0.id == "local/favorite" }?.evidenceIDs.contains("base-0") == true)
            return [
                SearchDiscoveryRankedItem(id: "external/better", reason: "Best intent match", evidenceIDs: ["github-0-1"]),
                SearchDiscoveryRankedItem(id: "local/favorite", reason: "Related fallback", evidenceIDs: ["base-0"])
            ]
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(
            query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan(),
            seedRepositories: [favorite]
        )
        #expect(result.repositories.map(\.card.fullName) == ["external/better", "local/favorite"])
        #expect(result.repositories.last?.card.isInLibrary == true)
        #expect(result.repositories.last?.sources == [.localKeyword, .github])
    }

    @Test("统一重排预算内基础与新增来源均有名额")
    func sharedRankingPoolBalancesBaseAndNewCandidates() async {
        let base = (0..<20).map {
            Self.makeCandidate(repo: Self.makeRepo(id: Int64($0 + 1), owner: "base", name: "tool-\($0)"))
        }
        let discovered = (0..<20).map {
            Self.makeCandidate(repo: Self.makeRepo(id: Int64($0 + 100), owner: "new", name: "tool-\($0)"))
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, _, _ in
            #expect(candidates.count == 2)
            #expect(candidates.contains { $0.id.hasPrefix("base/") })
            #expect(candidates.contains { $0.id.hasPrefix("new/") })
            return candidates.map { SearchDiscoveryRankedItem(id: $0.id, reason: "Relevant", evidenceIDs: $0.evidenceIDs) }
        }
        _ = await RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                SearchProviderPage(repositories: discovered, references: [], totalCount: 20, hasNextPage: false)
            },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(
            query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan(),
            budget: SearchDiscoveryBudget(
                timeoutSeconds: 15, maxWebQueries: 0, maxGitHubQueries: 1, maxLLMCalls: 3,
                maxVerifiedRepositories: 5, maxRankedCandidates: 2
            ),
            seedRepositories: base
        )
    }

    @Test("专用重排只在同分时优先收藏，更相关的外部项目仍在前", arguments: [false, true])
    func dedicatedRankerUsesLibraryOnlyForTies(equalRelevance: Bool) throws {
        let candidates = [
            SearchDiscoveryRankingCandidate(
                id: "external/better", fullName: "external/better", description: nil, stars: 1, evidenceIDs: []
            ),
            SearchDiscoveryRankingCandidate(
                id: "local/favorite", fullName: "local/favorite", description: nil, stars: 1, evidenceIDs: [], isInLibrary: true
            )
        ]
        let ranked = try SearchDiscoveryRerankRanker.rankedItems(
            from: [
                ("external/better", 0.9),
                ("local/favorite", equalRelevance ? 0.9 : 0.8)
            ], candidates: candidates
        )
        #expect(ranked.first?.id == (equalRelevance ? "local/favorite" : "external/better"))
    }

    @Test("GitHub 候选满额时仍保留网页核验名额，重排降级也不丢失", arguments: [false, true], [1, 2])
    func verifiedWebCandidatesHaveReservedRankingSlots(rankerFails: Bool, limit: Int) async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: (0..<20).map {
                    Self.makeCandidate(repo: Self.makeRepo(id: Int64($0 + 1), owner: "github", name: "tool-\($0)"))
                }, references: [], totalCount: 20, hasNextPage: false
            )
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [], references: [Self.makeReference(url: "https://github.com/web/desired")],
                totalCount: 1, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, _, _ in
            #expect(candidates.count == limit)
            #expect(candidates.contains { $0.id == "web/desired" })
            if rankerFails { throw TestError.failed }
            return candidates.reversed().map {
                SearchDiscoveryRankedItem(id: $0.id, reason: "Relevant match", evidenceIDs: $0.evidenceIDs)
            }
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: web,
            verifier: StubRepositoryVerifier { owner, name in Self.makeRepoDTO(id: 99, owner: owner, name: name) },
            ranker: ranker, webEvidenceAllowed: { _ in true }
        ).discover(
            query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan(),
            budget: SearchDiscoveryBudget(
                timeoutSeconds: 15, maxWebQueries: 1, maxGitHubQueries: 1, maxLLMCalls: 3,
                maxVerifiedRepositories: 5, maxRankedCandidates: limit
            )
        )
        #expect(result.repositories.count == limit)
        #expect(result.repositories.contains { $0.card.fullName == "web/desired" })
    }

    @Test("续查复用计划和未核验线索，只取下一页 GitHub 结果")
    func continuationReusesPlanAndPendingVerification() async {
        let github = RecordingSearchProvider(source: .github) { request in
            let name = request.page == 1 ? "first" : "second"
            return SearchProviderPage(
                repositories: [Self.makeCandidate(repo: Self.makeRepo(id: Int64(request.page), owner: "owner", name: name))],
                references: [], totalCount: 2, hasNextPage: request.page == 1
            )
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [], references: (0..<7).map {
                    Self.makeReference(url: "https://github.com/web/repo-\($0)")
                }, totalCount: 7, hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { owner, name in
            Self.makeRepoDTO(id: 100 + (Int64(name.suffix(1)) ?? 0), owner: owner, name: name)
        }
        let planner = StubQueryPlanner(plan: Self.makePlan())
        let service = RepositoryDiscoveryService(
            planner: planner, githubProvider: github, webProvider: web,
            verifier: verifier, webEvidenceAllowed: { _ in true }
        )
        let first = await service.discover(
            query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan()
        )
        let second = await service.discover(
            query: "tool", request: SearchRequest(query: "tool"),
            round: 2, initialLLMCalls: 0, previousResult: first
        )
        #expect(planner.calls == 0)
        #expect(web.requests.count == 1)
        #expect(github.requests.map(\.page) == [1, 2])
        #expect(verifier.calls.count == 7)
        #expect(Set(second.repositories.map(\.card.fullName)) == ["owner/second", "web/repo-5", "web/repo-6"])
        #expect(second.session.usedLLMCalls == 0)
        #expect(second.session.evidence.contains { $0.id == "round-2-github-0-0" })
        #expect(Set(second.session.evidence.map(\.id)).count == second.session.evidence.count)
    }

    @Test("续查复用线索时仍排除前轮私仓的远程证据")
    func continuationFiltersPreviousPrivateEvidence() async {
        let privateRepo = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "internal", name: "secret", isPrivate: true))
        let previous = RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: UUID(), round: 1, phase: .completed, plan: Self.makePlan(),
                evidence: [SearchEvidence(
                    id: "private", kind: .github, title: "internal/secret",
                    snippet: "private details", repositoryFullName: "internal/secret"
                )]
            ),
            repositories: [privateRepo], references: [], diagnostics: []
        )
        let ranker = StubDiscoveryRanker { _, _, _, evidence, _ in
            #expect(evidence.allSatisfy { $0.repositoryFullName != "internal/secret" })
            return []
        }
        _ = await RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                SearchProviderPage(
                    repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "public", name: "tool"))],
                    references: [], totalCount: 1, hasNextPage: false
                )
            },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(
            query: "tool", request: SearchRequest(query: "tool"),
            round: 2, initialLLMCalls: 0, previousResult: previous
        )
    }

    @Test("规划与 Chat 重排共用 Pro 门控，本地模型免费", arguments: [false, true], [false, true])
    func chatEntitlementsAreCheckedBeforeClientCreation(isPro: Bool, usesLocalOnly: Bool) async {
        let settings = Self.entitlementSettings(usesLocalOnly: usesLocalOnly)
        let gate = EntitlementGate(
            entitlementProvider: SearchDiscoveryEntitlementProvider(isPro: isPro), userIDProvider: { nil }
        )
        let planner = SearchLLMQueryPlanner(settings: settings, keychain: InMemoryKeychain(), entitlementGate: gate)
        let ranker = SearchLLMDiscoveryRanker(settings: settings, keychain: InMemoryKeychain(), entitlementGate: gate)
        #expect(ranker.usesLocalOnly == usesLocalOnly)

        // 已获准的调用在零预算处停止，覆盖实际入口且不下载模型或发出网络请求。
        if !isPro && !usesLocalOnly {
            await #expect(throws: EntitlementGateError.requiresPro(feature: .semanticSearch)) {
                try await planner.plan(query: "tool", allowWebEvidence: false, maxSeconds: 0)
            }
            await #expect(throws: EntitlementGateError.requiresPro(feature: .semanticSearch)) {
                try await planner.extract(query: "tool", evidence: [], maxSeconds: 0)
            }
            await #expect(throws: EntitlementGateError.requiresPro(feature: .semanticSearch)) {
                try await ranker.rank(query: "tool", plan: Self.makePlan(), candidates: [], evidence: [], maxSeconds: 0)
            }
        } else {
            await #expect(throws: URLError(.timedOut)) {
                try await planner.plan(query: "tool", allowWebEvidence: false, maxSeconds: 0)
            }
            await #expect(throws: URLError(.timedOut)) {
                try await planner.extract(query: "tool", evidence: [], maxSeconds: 0)
            }
            await #expect(throws: URLError(.timedOut)) {
                try await ranker.rank(query: "tool", plan: Self.makePlan(), candidates: [], evidence: [], maxSeconds: 0)
            }
        }
    }

    @Test("专用 Rerank 的动态入口遵守远程 Pro 与本地免费规则", arguments: [false, true], [false, true])
    func dedicatedRerankEntitlementsAreEnforced(isPro: Bool, usesLocalOnly: Bool) async {
        let settings = Self.entitlementSettings(usesLocalOnly: false)
        settings.ragRerankConfiguration = RAGRerankConfiguration(
            isEnabled: true, provider: usesLocalOnly ? .localMLX : .huggingFaceTEI
        )
        let gate = EntitlementGate(
            entitlementProvider: SearchDiscoveryEntitlementProvider(isPro: isPro), userIDProvider: { nil }
        )
        let ranker = DynamicSearchDiscoveryRanker(settings: settings, keychain: InMemoryKeychain(), entitlementGate: gate)
        #expect(ranker.usesLocalOnly == usesLocalOnly)
        if !isPro && !usesLocalOnly {
            await #expect(throws: EntitlementGateError.requiresPro(feature: .semanticSearch)) {
                try await ranker.rank(query: "tool", plan: Self.makePlan(), candidates: [], evidence: [], maxSeconds: 0)
            }
        } else {
            await #expect(throws: URLError(.timedOut)) {
                try await ranker.rank(query: "tool", plan: Self.makePlan(), candidates: [], evidence: [], maxSeconds: 0)
            }
        }
    }

    @Test("远程重排被 Pro 门控阻止后仍保留基础候选")
    func deniedRemoteRankerKeepsSearchResults() async {
        let settings = Self.entitlementSettings(usesLocalOnly: false)
        let gate = EntitlementGate(
            entitlementProvider: SearchDiscoveryEntitlementProvider(isPro: false), userIDProvider: { nil }
        )
        let candidate = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let result = await RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                SearchProviderPage(repositories: [candidate], references: [], totalCount: 1, hasNextPage: false)
            },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: DynamicSearchDiscoveryRanker(settings: settings, keychain: InMemoryKeychain(), entitlementGate: gate)
        ).discover(query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan())
        #expect(result.repositories.map(\.card.fullName) == ["apple/swift"])
        #expect(result.repositories.first?.discovery?.kind == .githubSearch)
        #expect(result.diagnostics.contains { $0.stage == .ranking && $0.isFailure })
    }

    @Test("重排输入只携带当前仓库的 GitHub 和网页证据")
    func rankingEvidenceIsAssociatedWithRepository() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [
                    Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift")),
                    Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "other", name: "tool"))
                ], references: [], totalCount: 2, hasNextPage: false
            )
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [], references: [
                    Self.makeReference(url: "https://github.com/Apple/Swift/"),
                    Self.makeReference(url: "https://github.com/old/alias/?tab=readme"),
                    Self.makeReference(url: "https://example.org/unrelated")
                ], totalCount: 3, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, _, _ in
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            #expect(Set(byID["apple/swift"]?.evidenceIDs ?? []) == ["github-0-0", "web-0-0"])
            #expect(byID["other/tool"]?.evidenceIDs == ["github-0-1"])
            #expect(byID["new/renamed"]?.evidenceIDs == ["web-0-1"])
            return candidates.map {
                SearchDiscoveryRankedItem(id: $0.id, reason: "Repository-specific match", evidenceIDs: $0.evidenceIDs)
            }
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in Self.makeRepoDTO(id: 3, owner: "new", name: "renamed") },
            ranker: ranker, webEvidenceAllowed: { _ in true }
        ).discover(query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan())
        #expect(result.repositories.count == 3)
        #expect(result.repositories.allSatisfy { $0.discovery?.kind == .modelMatch })
    }

    @Test("模型引用其它仓库证据时拒绝该理由并保留原候选")
    func crossRepositoryEvidenceIsRejected() async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [
                    Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift")),
                    Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "other", name: "tool"))
                ], references: [], totalCount: 2, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, _, _, _ in
            [SearchDiscoveryRankedItem(id: "apple/swift", reason: "Unrelated project claim", evidenceIDs: ["github-0-1"])]
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan())
        #expect(result.repositories.count == 2)
        #expect(result.repositories.first?.discovery?.kind == .githubSearch)
        #expect(result.repositories.first?.discovery?.evidenceIDs == ["github-0-0"])
        #expect(result.repositories.first?.discovery?.reason.isEmpty == true)
    }

    @Test("远程重排同时排除私仓候选和证据，本地重排可使用私仓", arguments: [false, true])
    func privateRepositoriesRespectRankerBoundary(usesLocalOnly: Bool) async {
        let publicRepo = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "public", name: "tool"))
        let privateRepo = Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "internal", name: "secret", isPrivate: true))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [publicRepo, privateRepo], references: [], totalCount: 2, hasNextPage: false)
        }
        let ranker = StubDiscoveryRanker(usesLocalOnly: usesLocalOnly) { _, _, candidates, evidence, _ in
            #expect(candidates.contains { $0.fullName == "internal/secret" } == usesLocalOnly)
            #expect(evidence.contains { $0.repositoryFullName == "internal/secret" } == usesLocalOnly)
            #expect(evidence.contains { $0.snippet == "secret repository" } == usesLocalOnly)
            return [
                SearchDiscoveryRankedItem(id: "internal/secret", reason: "Private match", evidenceIDs: []),
                SearchDiscoveryRankedItem(id: " PUBLIC/TOOL ", reason: "Public match", evidenceIDs: [])
            ]
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan())
        #expect(result.repositories.count == 2)
        #expect(result.repositories.first { !$0.card.isPrivate }?.discovery?.kind == .modelMatch)
        let privateResult = result.repositories.first { $0.card.isPrivate }
        #expect(privateResult?.discovery?.kind == (usesLocalOnly ? .modelMatch : .githubSearch))
    }

    @Test("仅有私仓时保留卡片且不调用远程重排")
    func privateOnlyResultsSkipRemoteRanker() async {
        let candidate = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "internal", name: "secret", isPrivate: true))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [candidate], references: [], totalCount: 1, hasNextPage: false)
        }
        let ranker = StubDiscoveryRanker { _, _, _, _, _ in
            Issue.record("Private-only results must not invoke remote ranking")
            return []
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(query: "tool", request: SearchRequest(query: "tool"), initialPlan: Self.makePlan())
        #expect(result.repositories.map(\.card.fullName) == ["internal/secret"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("隐藏候选不进入网页身份提取、证据或重排输入")
    func filteredContentNeverReachesRanker() async {
        let safe = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let blocked = Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "cirosantilli", name: "china-dictatorship"))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [blocked, safe], references: [], totalCount: 2, hasNextPage: false)
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [],
                references: [
                    Self.makeReference(url: "https://github.com/cirosantilli/china-dictatorship"),
                    Self.makeReference(url: "https://github.com/basecamp/omarchy"),
                    ReferenceCandidate(
                        normalizedURL: URL(string: "https://example.org/blocked")!,
                        originalURL: URL(string: "https://example.org/blocked")!,
                        title: "出售毒品", snippet: nil, domain: "example.org", source: .web
                    )
                ], totalCount: 3, hasNextPage: false
            )
        }
        let verifier = StubRepositoryVerifier { owner, name in
            #expect(owner == "basecamp")
            #expect(name == "omarchy")
            return Self.makeRepoDTO(id: 3, owner: owner, name: name)
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, evidence, _ in
            #expect(Set(candidates.map(\.fullName)) == ["apple/swift", "basecamp/omarchy"])
            #expect(evidence.allSatisfy { !$0.title.contains("毒品") })
            #expect(evidence.allSatisfy { $0.url?.absoluteString.contains("china-dictatorship") != true })
            return candidates.map { candidate in
                SearchDiscoveryRankedItem(id: candidate.id, reason: "Allowed candidate", evidenceIDs: [])
            }
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: web, verifier: verifier, ranker: ranker,
            webEvidenceAllowed: { _ in true }
        ).discover(query: "Linux", request: SearchRequest(query: "Linux", includeWebInAll: true), initialPlan: Self.makePlan())
        #expect(result.repositories.count == 2)
        #expect(result.references.count == 1)
        #expect(result.contentSummary.hiddenCount == 2)
        #expect(verifier.calls.count == 1)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Planner 的禁止子查询和约束不发给 Provider 或 Ranker")
    func blockedGeneratedQueriesAreRemoved() async {
        let candidate = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [candidate], references: [], totalCount: 1, hasNextPage: false)
        }
        let web = RecordingSearchProvider(source: .web) { _ in .empty }
        let ranker = StubDiscoveryRanker { _, plan, _, _, _ in
            #expect(plan.githubQueries == ["swift"])
            #expect(plan.webQueries.isEmpty)
            #expect(plan.strictConstraints.isEmpty)
            #expect(plan.intentSummary == "Find software")
            return []
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }, ranker: ranker
        ).discover(
            query: "Find software", request: SearchRequest(query: "Find software"),
            initialPlan: SearchDiscoveryPlan(
                intentSummary: "法轮功", githubQueries: ["购买枪支", "swift"],
                webQueries: ["出售毒品"], prefersFreshEvidence: false,
                strictConstraints: ["人体器官出售"], githubFilters: .empty
            )
        )
        #expect(github.requests.map(\.query) == ["swift"])
        #expect(web.requests.isEmpty)
        #expect(result.session.usedGitHubQueries == 1)
        #expect(result.contentSummary.hiddenCount == 4)
    }

    @Test("核验重定向揭示禁止仓库时同步移除原网页证据")
    func verifiedBlockedIdentityRemovesAliasEvidence() async {
        let safe = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(repositories: [safe], references: [], totalCount: 1, hasNextPage: false)
        }
        let web = RecordingSearchProvider(source: .web) { _ in
            SearchProviderPage(
                repositories: [], references: [Self.makeReference(url: "https://github.com/old/alias")],
                totalCount: 1, hasNextPage: false
            )
        }
        let ranker = StubDiscoveryRanker { _, _, candidates, evidence, _ in
            #expect(candidates.map(\.fullName) == ["apple/swift"])
            #expect(evidence.allSatisfy { $0.url?.absoluteString.contains("old/alias") != true })
            return candidates.map { candidate in
                SearchDiscoveryRankedItem(id: candidate.id, reason: "Allowed candidate", evidenceIDs: [])
            }
        }
        let result = await RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in
                Self.makeRepoDTO(id: 2, owner: "cirosantilli", name: "china-dictatorship")
            }, ranker: ranker,
            webEvidenceAllowed: { _ in true }
        ).discover(query: "Linux", request: SearchRequest(query: "Linux", includeWebInAll: true), initialPlan: Self.makePlan())
        #expect(result.references.isEmpty)
        #expect(result.repositories.map(\.card.fullName) == ["apple/swift"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("发现服务直接调用也先检查查询，不调用 Planner")
    func blockedQuerySkipsPlanner() async {
        let planner = StubQueryPlanner(plan: Self.makePlan())
        let github = RecordingSearchProvider(source: .github) { _ in .empty }
        let result = await RepositoryDiscoveryService(
            planner: planner, githubProvider: github,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed }
        ).discover(query: "出售毒品", request: SearchRequest(query: "出售毒品"), initialLLMCalls: 0)
        #expect(planner.calls == 0)
        #expect(github.requests.isEmpty)
        #expect(result.contentSummary.hiddenCount == 1)
        #expect(result.session.usedLLMCalls == 0)
        #expect(result.diagnostics.isEmpty)
    }

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
            ranker: ranker,
            webEvidenceAllowed: { _ in true }
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
            ranker: ranker,
            webEvidenceAllowed: { _ in true }
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
        #expect(result.session.phase == .partialFailure)
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
            ranker: nil,
            webEvidenceAllowed: { _ in true }
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

    @Test("全部检索失败时返回失败而不是零命中")
    func allSearchFailuresProduceFailureTerminalState() async {
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                throw TestError.failed
            },
            webProvider: RecordingSearchProvider(source: .web) { _ in
                throw TestError.failed
            },
            verifier: StubRepositoryVerifier { _, _ in
                throw TestError.failed
            },
            ranker: nil,
            webEvidenceAllowed: { _ in true }
        )

        let result = await service.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux"),
            initialPlan: Self.makePlan()
        )

        #expect(result.repositories.isEmpty)
        #expect(result.session.phase.isFailed)
        #expect(result.diagnostics.contains { $0.stage == .webSearch && $0.isFailure })
        #expect(result.diagnostics.contains { $0.stage == .githubSearch && $0.isFailure })
    }

    @Test("检索成功且没有仓库时保留独立的零命中终态")
    func successfulEmptySearchHasNoResultsState() async {
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: RecordingSearchProvider(source: .web) { _ in .empty },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: nil,
            webEvidenceAllowed: { _ in true }
        )
        let result = await service.discover(
            query: "linux distribution",
            request: SearchRequest(query: "linux"),
            initialPlan: Self.makePlan()
        )
        #expect(result.session.phase == .noResults)
        #expect(result.diagnostics.isEmpty)
        #expect(result.repositories.isEmpty)
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
            ranker: nil,
            webEvidenceAllowed: { _ in true }
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
            ranker: nil,
            webEvidenceAllowed: { _ in true }
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
            ranker: nil,
            webEvidenceAllowed: { _ in true }
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

    @Test("空重排失败保留候选，部分评分仅标记实际模型匹配", arguments: [false, true])
    func rerankAnnotationsReflectActualScores(empty: Bool) async {
        let github = RecordingSearchProvider(source: .github) { _ in
            SearchProviderPage(
                repositories: [
                    Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift")),
                    Self.makeCandidate(repo: Self.makeRepo(id: 2, owner: "rust-lang", name: "rust"))
                ],
                references: [], totalCount: 2, hasNextPage: false
            )
        }
        let service = RepositoryDiscoveryService(
            planner: nil, githubProvider: github, webProvider: nil,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker(kind: .dedicatedRerank) { _, _, candidates, _, _ in
                try SearchDiscoveryRerankRanker.rankedItems(
                    from: empty ? [] : [(candidateID: "rust-lang/rust", score: 0.9)],
                    candidates: candidates
                )
            }
        )
        let result = await service.discover(
            query: "language", request: SearchRequest(query: "language"), initialPlan: Self.makePlan()
        )
        #expect(result.repositories.count == 2)
        #expect(result.steps.first { $0.stage == .ranking }?.state == (empty ? .failed : .completed))
        #expect(result.repositories.first { $0.card.fullName == "apple/swift" }?.discovery?.kind == .githubSearch)
        #expect(result.repositories.first { $0.card.fullName == "rust-lang/rust" }?.discovery?.kind
                == (empty ? .githubSearch : .modelMatch))
        #expect(result.session.phase == (empty ? .partialFailure : .completed))
        #expect(result.diagnostics.contains { $0.stage == .ranking && $0.isFailure } == empty)
        if !empty {
            #expect(result.repositories.map(\.card.fullName) == ["rust-lang/rust", "apple/swift"])
        }
    }

    @Test("Chat Ranker 空响应也不能标为重排成功")
    func emptyChatRankingIsInvalid() async {
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                SearchProviderPage(
                    repositories: [Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))],
                    references: [], totalCount: 1, hasNextPage: false
                )
            },
            webProvider: nil, verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker { _, _, _, _, _ in [] }
        )
        let result = await service.discover(
            query: "swift", request: SearchRequest(query: "swift"), initialPlan: Self.makePlan()
        )
        #expect(result.steps.first { $0.stage == .ranking }?.state == .failed)
        #expect(result.repositories.first?.discovery?.kind == .githubSearch)
        #expect(result.session.phase == .partialFailure)
    }

    @Test("重排适配器拒绝无关候选、重复评分和非有限评分",
          arguments: ["unknown", "duplicate", "nan", "infinity"])
    func rerankAdapterRejectsInvalidScores(kind: String) {
        let candidates = [SearchDiscoveryRankingCandidate(
            id: "apple/swift", fullName: "apple/swift", description: nil, stars: 1, evidenceIDs: []
        )]
        let scores: [(candidateID: String, score: Double)] = switch kind {
        case "unknown": [("unknown/repo", 0.9)]
        case "duplicate": [("apple/swift", 0.9), ("apple/swift", 0.8)]
        case "nan": [("apple/swift", .nan)]
        default: [("apple/swift", .infinity)]
        }
        #expect(throws: RepositoryDiscoveryError.self) {
            try SearchDiscoveryRerankRanker.rankedItems(from: scores, candidates: candidates)
        }
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

        #expect(result.steps.map(\.stage) == [.webSearch, .githubSearch, .verification, .ranking])
        #expect(result.steps.first(where: { $0.stage == .webSearch })?.state == .skipped)
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

    @Test("取消后不再启动后续 Web 或 GitHub 检索")
    func cancellationStopsSubsequentDiscoveryRequests() async throws {
        let web = RecordingSearchProvider(source: .web) { _ in
            try await Task.sleep(for: .seconds(0.2))
            return .empty
        }
        let github = RecordingSearchProvider(source: .github) { _ in .empty }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: github,
            webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: nil,
            webEvidenceAllowed: { _ in true }
        )
        let plan = SearchDiscoveryPlan(
            intentSummary: "Cancel discovery",
            githubQueries: ["github query"],
            webQueries: ["first web query", "second web query"],
            prefersFreshEvidence: true,
            strictConstraints: [],
            githubFilters: .empty
        )

        let task = Task {
            await service.discover(
                query: "cancelled query",
                request: SearchRequest(query: "cancelled query"),
                initialPlan: plan,
                deadline: Date().addingTimeInterval(5)
            )
        }
        try await Self.waitUntil {
            web.requests.count == 1
        }
        task.cancel()
        let result = await task.value

        #expect(web.requests.count == 1)
        #expect(github.requests.isEmpty)
        #expect(result.session.phase == .cancelled)
        #expect(!Task.isCancelled)
    }

    @Test("AI 联网与网页展示开关四种组合在首轮和继续轮次一致", arguments: [false, true], [false, true])
    func webPermissionIsIndependentOfPresentation(aiEnabled: Bool, includeWeb: Bool) async {
        let planner = StubQueryPlanner(plan: Self.makePlan())
        let web = RecordingSearchProvider(source: .web) { _ in .empty }
        let service = RepositoryDiscoveryService(
            planner: planner,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            webEvidenceAllowed: { _ in aiEnabled }
        )
        for round in 1...2 {
            let result = await service.discover(
                query: "linux", request: SearchRequest(query: "linux", includeWebInAll: includeWeb),
                round: round, initialLLMCalls: 0
            )
            #expect(result.session.usedWebQueries == (aiEnabled ? 1 : 0))
            #expect(result.diagnostics.isEmpty)
        }
        #expect(planner.webPermissions == [aiEnabled, aiEnabled])
        #expect(web.requests.count == (aiEnabled ? 2 : 0))
    }

    @Test("执行中关闭 AI 联网或服务商后不再请求下一条网页", arguments: [false, true])
    func permissionChangesStopLaterWebRequests(disableProvider: Bool) async {
        let permission = DiscoveryWebPermission()
        let web = RecordingSearchProvider(source: .web) { _ in
            await MainActor.run {
                if disableProvider { permission.providerAvailable = false } else { permission.aiEnabled = false }
            }
            return .empty
        }
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in .empty },
            webProvider: web,
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            webEvidenceAllowed: { _ in permission.aiEnabled && permission.providerAvailable }
        )
        let plan = SearchDiscoveryPlan(
            intentSummary: "Linux", githubQueries: ["linux"], webQueries: ["first", "second"],
            prefersFreshEvidence: false, strictConstraints: [], githubFilters: .empty
        )
        let result = await service.discover(
            query: "linux", request: SearchRequest(query: "linux"), initialPlan: plan
        )
        #expect(web.requests.map(\.query) == ["first"])
        #expect(result.steps.contains { $0.stage == .webSearch && $0.state == .skipped })
        #expect(result.diagnostics.isEmpty)
    }

    @Test("关闭的网页与重排能力正常跳过而不告警")
    func disabledOptionalCapabilitiesAreSkipped() async {
        let candidate = Self.makeCandidate(repo: Self.makeRepo(id: 1, owner: "apple", name: "swift"))
        let service = RepositoryDiscoveryService(
            planner: nil,
            githubProvider: RecordingSearchProvider(source: .github) { _ in
                SearchProviderPage(repositories: [candidate], references: [], totalCount: 1, hasNextPage: false)
            },
            webProvider: RecordingSearchProvider(source: .web) { _ in
                throw ExternalSearchError.disabled(provider: .exa)
            },
            verifier: StubRepositoryVerifier { _, _ in throw TestError.failed },
            ranker: StubDiscoveryRanker(kind: .dedicatedRerank) { _, _, _, _, _ in
                throw RepositoryDiscoveryError.dedicatedRerankDisabled
            },
            webEvidenceAllowed: { _ in true }
        )
        let result = await service.discover(
            query: "swift", request: SearchRequest(query: "swift"), initialPlan: Self.makePlan()
        )
        #expect(result.session.phase == .completed)
        #expect(result.diagnostics.isEmpty)
        #expect(result.steps.contains { $0.stage == .webSearch && $0.state == .skipped })
        #expect(result.steps.contains { $0.stage == .ranking && $0.state == .skipped })
        #expect(result.repositories.count == 1)
    }

    private static func entitlementSettings(usesLocalOnly: Bool) -> AppSettings {
        let defaults = UserDefaults(suiteName: "SearchDiscoveryEntitlements-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        let profile = AIProviderProfile(id: "search-test", provider: usesLocalOnly ? .localAI : .openAICompatible)
        settings.aiProviderProfiles = [profile]
        settings.aiChatTask.providerID = profile.id
        return settings
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

    private static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard condition() else { throw TestError.failed }
    }

    private nonisolated static func makeRepo(id: Int64, owner: String, name: String, isPrivate: Bool = false) -> Repo {
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
            isPrivate: isPrivate,
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

    /// 普通文章 URL 不包含仓库路径，迫使发现链路使用原文线索。
    private nonisolated static func makeArticlePage(
        title: String = "Introducing Omarchy",
        snippet: String? = "A Linux distribution for developers"
    ) -> SearchProviderPage {
        let url = URL(string: "https://news.example.org/linux-introduction")!
        return SearchProviderPage(
            repositories: [],
            references: [ReferenceCandidate(
                normalizedURL: url, originalURL: url, title: title, snippet: snippet,
                domain: "news.example.org", source: .web
            )],
            totalCount: 1, hasNextPage: false
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

/// 使用真实 EntitlementGate 的轻量权益快照，避免测试依赖 StoreKit 或全局调试开关。
@MainActor
private final class SearchDiscoveryEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        entitlement = isPro ? .testEnvironment : .inactive
    }
}

@MainActor
private final class DiscoveryWebPermission {
    var aiEnabled = true
    var providerAvailable = true
}

private enum TestError: Error {
    case failed
}

/// 注入提取响应或挂起操作，用于验证服务边界而非真实联网模型。
@MainActor
private final class StubArticleExtractor: SearchArticleCandidateExtracting {
    let modelDisplayName: String? = "Test extraction model"
    private(set) var calls = 0
    private let handler: ([SearchEvidence]) async throws -> [SearchArticleCandidate]

    init(handler: @escaping ([SearchEvidence]) async throws -> [SearchArticleCandidate]) {
        self.handler = handler
    }

    func extract(query: String, evidence: [SearchEvidence], maxSeconds: TimeInterval) async throws -> [SearchArticleCandidate] {
        calls += 1
        return try await handler(evidence)
    }
}

@MainActor
private final class StubQueryPlanner: SearchQueryPlannerProviding {
    var webPermissions: [Bool] = []
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
        webPermissions.append(allowWebEvidence)
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
    let usesLocalOnly: Bool
    private let handler: @Sendable (
        String,
        SearchDiscoveryPlan,
        [SearchDiscoveryRankingCandidate],
        [SearchEvidence],
        TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem]

    init(
        kind: SearchDiscoveryRankerKind = .chat,
        usesLocalOnly: Bool = false,
        handler: @escaping @Sendable (
            String,
            SearchDiscoveryPlan,
            [SearchDiscoveryRankingCandidate],
            [SearchEvidence],
            TimeInterval
        ) async throws -> [SearchDiscoveryRankedItem]
    ) {
        self.kind = kind
        self.usesLocalOnly = usesLocalOnly
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
