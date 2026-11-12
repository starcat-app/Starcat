//
//  RepositoryDiscoveryService.swift
//  Starcat
//
//  全局搜索智能发现的一轮受控编排。
//
//  关键约束：
//  - Planner 生成的查询最多各执行两次，Web / GitHub 失败不互相清空；
//  - GitHub Search 返回的候选天然来自官方端点；从 Web 提取的 owner/name 必须再经
//    `/repos/{owner}/{repo}` 核验，核验失败不得进入 Repo 列表；
//  - Ranker 只能引用服务层提供的候选与证据 ID，输出不合法时降级为确定性排序，
//    不能让模型发明的仓库或证据进入 UI。
//

import Foundation

/// GitHub 单仓库核验的最小接口。
///
/// 不复用庞大的 `GitHubAPIClientProtocol`，避免服务测试为了一个方法补几十个
/// fatalError 实现；生产实现仍委托给真实客户端。
protocol RepositoryVerificationProviding: Sendable {
    func repository(owner: String, name: String) async throws -> GitHubRepoDTO
}

/// 生产环境 GitHub 核验适配器。
struct GitHubRepositoryVerifier: RepositoryVerificationProviding {
    private let client: any GitHubAPIClientProtocol

    init(client: any GitHubAPIClientProtocol) {
        self.client = client
    }

    func repository(owner: String, name: String) async throws -> GitHubRepoDTO {
        try await client.repo(owner: owner, repo: name)
    }
}

/// 给 Ranker 的候选摘要，不暴露本地用户数据，也不包含模型可写回的分数。
struct SearchDiscoveryRankingCandidate: Equatable, Hashable, Codable, Sendable {
    let id: String
    let fullName: String
    let description: String?
    let stars: Int?
    let evidenceIDs: [String]
}

/// Ranker 输出的最小结构；服务层负责封闭集合校验与最终排名。
struct SearchDiscoveryRankedItem: Equatable, Hashable, Codable, Sendable {
    let id: String
    let reason: String
    let evidenceIDs: [String]
}

@MainActor
protocol SearchDiscoveryRankerProviding: AnyObject {
    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem]
}

/// 搜索专属 LLM Ranker。
///
/// 模型只输出候选 ID、理由和证据引用；服务层负责校验并重写排名。这样模型无法
/// 发明仓库名、覆盖 GitHub 元数据或把未验证网页内容变成事实。
@MainActor
final class SearchLLMDiscoveryRanker: SearchDiscoveryRankerProviding {
    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(settings: AppSettings, keychain: any KeychainManaging) {
        self.settings = settings
        self.keychain = keychain
    }

    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem] {
        let task = settings.resolvedAITask(settings.aiChatTask)
        let selection = try settings.resolveChatSelection(for: task)
        let apiKey = try keychain.loadAIKey(forProvider: selection.profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || selection.profile.provider.allowsEmptyAPIKey else {
            throw RepositoryDiscoveryError.missingRankerCredential
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let candidateJSON = String(data: try encoder.encode(candidates), encoding: .utf8) ?? "[]"
        let evidenceJSON = String(data: try encoder.encode(evidence), encoding: .utf8) ?? "[]"
        let client = try AIClientFactory.make(configuration: AIClientConfiguration(
            providerID: selection.profile.id,
            provider: selection.profile.provider,
            apiKey: apiKey,
            baseURL: selection.profile.baseURL,
            chatModel: selection.modelName,
            embeddingModel: settings.resolvedAITask(
                settings.aiEmbeddingTask,
                type: .embedding
            ).resolvedModelName,
            timeoutInterval: min(task.parameters.timeoutSeconds, 15),
            usageContext: AIUsageContext(feature: .semanticSearch, phase: "discovery_ranking")
        ))
        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: """
            You rank GitHub repository candidates for a Starcat search.
            Return only a JSON array. Each item must use:
            {"id":"","reason":"","evidence_ids":[""]}
            Use only the supplied candidate ids and evidence ids. Never invent repositories.
            """,
            userPrompt: """
            User query: \(query)
            Intent: \(plan.intentSummary)
            Strict constraints: \(plan.strictConstraints.joined(separator: "; "))
            Fresh evidence preferred: \(plan.prefersFreshEvidence)
            Candidates: \(candidateJSON)
            Evidence: \(evidenceJSON)
            """,
            model: selection.modelName,
            parameters: AIModelParameters(
                temperature: min(task.parameters.temperature, 0.1),
                topP: task.parameters.topP,
                topK: task.parameters.topK,
                maxCompletionTokens: min(task.parameters.maxCompletionTokens, 1_024),
                timeoutSeconds: min(task.parameters.timeoutSeconds, maxSeconds),
                streamEnabled: false
            ),
            responseFormat: .jsonObject,
            disableThinking: true
        ))
        return try Self.decode(response.content)
    }

    private static func decode(_ raw: String) throws -> [SearchDiscoveryRankedItem] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = extractJSONArray(from: text).data(using: .utf8)
        else { throw RepositoryDiscoveryError.invalidRankerResponse }
        do {
            return try JSONDecoder().decode([RawRankedItem].self, from: data).map {
                SearchDiscoveryRankedItem(
                    id: $0.id,
                    reason: $0.reason,
                    evidenceIDs: $0.evidenceIDs
                )
            }
        } catch {
            throw RepositoryDiscoveryError.invalidRankerResponse
        }
    }

    private static func extractJSONArray(from value: String) -> String {
        guard let start = value.firstIndex(of: "["),
              let end = value.lastIndex(of: "]"),
              start < end
        else { return value }
        return String(value[start...end])
    }
}

private struct RawRankedItem: Decodable {
    let id: String
    let reason: String
    let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case reason
        case evidenceIDs = "evidence_ids"
    }
}

enum RepositoryDiscoveryError: Error, Equatable {
    case missingPlannerCredential
    case invalidRankerResponse
    case missingRankerCredential
}

private struct RepositoryDiscoveryTimeout: Error {}

/// 一轮智能发现结果。warnings 只用于诊断和 UI 弱提示，失败不清空已成功证据。
struct RepositoryDiscoveryResult: Equatable, Sendable {
    let session: SearchDiscoverySession
    let repositories: [RepositoryCandidate]
    let references: [ReferenceCandidate]
    let warnings: [String]
}

@MainActor
final class RepositoryDiscoveryService {
    private let planner: (any SearchQueryPlannerProviding)?
    private let githubProvider: any SearchProvider
    private let webProvider: (any SearchProvider)?
    private let verifier: any RepositoryVerificationProviding
    private let ranker: (any SearchDiscoveryRankerProviding)?

    init(
        planner: (any SearchQueryPlannerProviding)?,
        githubProvider: any SearchProvider,
        webProvider: (any SearchProvider)? = nil,
        verifier: any RepositoryVerificationProviding,
        ranker: (any SearchDiscoveryRankerProviding)? = nil
    ) {
        self.planner = planner
        self.githubProvider = githubProvider
        self.webProvider = webProvider
        self.verifier = verifier
        self.ranker = ranker
    }

    /// 执行一轮发现。`initialPlan` 来自 Router 时要传 `initialLLMCalls = 1`；
    /// 缺省值保持这个语义，避免 C6 集成后少计量一次 Planner。
    func discover(
        query: String,
        request baseRequest: SearchRequest,
        initialPlan: SearchDiscoveryPlan? = nil,
        generation: UUID = UUID(),
        round: Int = 1,
        budget: SearchDiscoveryBudget = .firstRound,
        initialLLMCalls: Int = 1
    ) async -> RepositoryDiscoveryResult {
        var warnings: [String] = []
        var usedLLMCalls = max(0, initialLLMCalls)
        let deadline = Date().addingTimeInterval(budget.timeoutSeconds)

        var plan = initialPlan?.normalized
        if plan == nil {
            guard let planner else {
                let session = SearchDiscoverySession(
                    generation: generation,
                    round: round,
                    phase: .failed("Search query planner is unavailable"),
                    plan: nil,
                    usedLLMCalls: usedLLMCalls
                )
                return RepositoryDiscoveryResult(
                    session: session,
                    repositories: [],
                    references: [],
                    warnings: ["Search query planner is unavailable"]
                )
            }
            do {
                let generated = try await planner.plan(
                    query: query,
                    allowWebEvidence: baseRequest.includeWebInAll || baseRequest.scope == .web,
                    maxSeconds: Self.remainingSeconds(to: deadline)
                )
                plan = generated.normalized
                usedLLMCalls += 1
            } catch {
                let session = SearchDiscoverySession(
                    generation: generation,
                    round: round,
                    phase: .failed("Search query planner failed"),
                    plan: nil,
                    usedLLMCalls: usedLLMCalls
                )
                return RepositoryDiscoveryResult(
                    session: session,
                    repositories: [],
                    references: [],
                    warnings: ["Search query planner failed"]
                )
            }
        }

        guard let normalizedPlan = plan, normalizedPlan.isValid, budget.isValid else {
            let session = SearchDiscoverySession(
                generation: generation,
                round: round,
                phase: .failed("Invalid discovery plan or budget"),
                plan: plan,
                usedLLMCalls: usedLLMCalls
            )
            return RepositoryDiscoveryResult(
                session: session,
                repositories: [],
                references: [],
                warnings: ["Invalid discovery plan or budget"]
            )
        }

        var session = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .searching,
            plan: normalizedPlan,
            usedLLMCalls: usedLLMCalls
        )
        var repositories: [RepositoryCandidate] = []
        var references: [ReferenceCandidate] = []
        var evidence: [SearchEvidence] = []

        for webQuery in normalizedPlan.webQueries where session.canRunWebQuery(in: budget) {
            guard Date() < deadline else {
                warnings.append("Discovery timeout before web search")
                break
            }
            guard let webProvider = webProvider else { continue }
            let request = SearchRequest(
                query: webQuery,
                scope: .web,
                githubFilters: .empty,
                anySearchFilters: baseRequest.anySearchFilters,
                externalSearchFilters: baseRequest.externalSearchFilters,
                externalSearchProvider: baseRequest.externalSearchProvider,
                page: 1,
                perPage: min(baseRequest.perPage, 10),
                includeWebInAll: true,
                minimumSemanticScore: baseRequest.minimumSemanticScore
            )
            do {
                let page = try await Self.withDeadline(to: deadline) {
                    try await webProvider.search(request)
                }
                references.append(contentsOf: page.references)
                evidence.append(contentsOf: page.references.enumerated().map { index, reference in
                    SearchEvidence(
                        id: "web-\(session.usedWebQueries)-\(index)",
                        kind: .web,
                        title: reference.title,
                        url: reference.originalURL,
                        snippet: reference.snippet
                    )
                })
                session = Self.incrementing(session, webQueries: 1)
            } catch {
                session = Self.incrementing(session, webQueries: 1)
                warnings.append("Web query failed: \(webQuery)")
            }
        }

        for githubQuery in normalizedPlan.githubQueries where session.canRunGitHubQuery(in: budget) {
            guard Date() < deadline else {
                warnings.append("Discovery timeout before GitHub search")
                break
            }
            var filters = baseRequest.githubFilters
            if filters == .empty {
                filters = normalizedPlan.githubFilters
            }
            let request = SearchRequest(
                query: githubQuery,
                scope: .github,
                githubFilters: filters,
                anySearchFilters: baseRequest.anySearchFilters,
                externalSearchFilters: baseRequest.externalSearchFilters,
                externalSearchProvider: baseRequest.externalSearchProvider,
                page: 1,
                perPage: min(baseRequest.perPage, budget.maxRankedCandidates),
                includeWebInAll: false,
                minimumSemanticScore: baseRequest.minimumSemanticScore
            )
            do {
                let githubProvider = githubProvider
                let page = try await Self.withDeadline(to: deadline) {
                    try await githubProvider.search(request)
                }
                repositories.append(contentsOf: page.repositories)
                evidence.append(contentsOf: page.repositories.enumerated().map { index, candidate in
                    SearchEvidence(
                        id: "github-\(session.usedGitHubQueries)-\(index)",
                        kind: .github,
                        title: candidate.card.fullName,
                        url: URL(string: candidate.card.fullName == "" ? "" : "https://github.com/\(candidate.card.fullName)"),
                        snippet: candidate.card.description
                    )
                }.filter(\.isValid))
                session = Self.incrementing(session, githubQueries: 1)
            } catch {
                session = Self.incrementing(session, githubQueries: 1)
                warnings.append("GitHub query failed: \(githubQuery)")
            }
        }

        session = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .verifyingRepositories,
            plan: normalizedPlan,
            evidence: evidence,
            usedLLMCalls: session.usedLLMCalls,
            usedWebQueries: session.usedWebQueries,
            usedGitHubQueries: session.usedGitHubQueries
        )

        var extractedIdentities = Self.githubIdentities(from: references)
        var verificationAttempts = 0
        while verificationAttempts < budget.maxVerifiedRepositories,
              !extractedIdentities.isEmpty,
              Date() < deadline {
            let identity = extractedIdentities.removeFirst()
            guard !repositories.contains(where: { $0.identity == identity }) else { continue }
            do {
                verificationAttempts += 1
                let verifier = verifier
                let dto = try await Self.withDeadline(to: deadline) {
                    try await verifier.repository(owner: identity.owner, name: identity.name)
                }
                let repo = GRDBRepoRepository.repoFromDTO(
                    dto,
                    starredAt: nil,
                    cachedAt: ISO8601DateFormatter().string(from: Date()),
                    isStarred: false
                )
                var candidate = RepositoryCandidate(
                    identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
                    card: repo.asCardData(),
                    sources: [.github],
                    localRepo: nil,
                    remoteRepo: repo,
                    semanticScore: nil
                )
                candidate.discovery = SearchDiscoveryAnnotation(
                    reason: "GitHub API verified repository",
                    evidenceIDs: evidence.filter { $0.url?.absoluteString.hasSuffix("/\(identity.owner)/\(identity.name)") == true }.map(\.id),
                    rank: nil
                )
                repositories.append(candidate)
            } catch {
                if error is RepositoryDiscoveryTimeout {
                    warnings.append("Discovery timeout during GitHub verification")
                    extractedIdentities.removeAll()
                    break
                }
                warnings.append("GitHub verification failed: \(identity.owner)/\(identity.name)")
            }
        }
        if !extractedIdentities.isEmpty || verificationAttempts == budget.maxVerifiedRepositories {
            warnings.append("GitHub verification budget reached")
        }

        repositories = Self.deduplicated(repositories)
        references = Self.deduplicatedReferences(references)
        evidence = evidence.filter(\.isValid)

        session = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .ranking,
            plan: normalizedPlan,
            evidence: evidence,
            usedLLMCalls: session.usedLLMCalls,
            usedWebQueries: session.usedWebQueries,
            usedGitHubQueries: session.usedGitHubQueries
        )

        let rankedRepositories: [RepositoryCandidate]
        if repositories.isEmpty || !session.canUseLLM(in: budget) || Date() >= deadline {
            if !repositories.isEmpty && Date() >= deadline {
                warnings.append("Discovery timeout before ranking")
            }
            rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
        } else if let ranker {
            let summaries = repositories.prefix(budget.maxRankedCandidates).map { candidate in
                SearchDiscoveryRankingCandidate(
                    id: candidate.identity.normalizedFullName,
                    fullName: candidate.card.fullName,
                    description: candidate.card.description,
                    stars: candidate.card.starsCount,
                    evidenceIDs: evidence.map(\.id)
                )
            }
            do {
                let rankedItems = try await ranker.rank(
                    query: query,
                    plan: normalizedPlan,
                    candidates: Array(summaries),
                    evidence: evidence,
                    maxSeconds: Self.remainingSeconds(to: deadline)
                )
                session = Self.incrementing(session, llmCalls: 1)
                rankedRepositories = Self.applying(
                    rankedItems,
                    to: repositories,
                    evidence: evidence,
                    budget: budget
                )
            } catch {
                session = Self.incrementing(session, llmCalls: 1)
                warnings.append("Discovery ranking failed")
                rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
            }
        } else {
            rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
        }

        let completed = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .completed,
            plan: normalizedPlan,
            evidence: evidence,
            usedLLMCalls: session.usedLLMCalls,
            usedWebQueries: session.usedWebQueries,
            usedGitHubQueries: session.usedGitHubQueries
        )
        return RepositoryDiscoveryResult(
            session: completed,
            repositories: rankedRepositories,
            references: references,
            warnings: warnings
        )
    }

    private static func incrementing(
        _ session: SearchDiscoverySession,
        llmCalls: Int = 0,
        webQueries: Int = 0,
        githubQueries: Int = 0
    ) -> SearchDiscoverySession {
        SearchDiscoverySession(
            generation: session.generation,
            round: session.round,
            phase: session.phase,
            plan: session.plan,
            evidence: session.evidence,
            usedLLMCalls: session.usedLLMCalls + llmCalls,
            usedWebQueries: session.usedWebQueries + webQueries,
            usedGitHubQueries: session.usedGitHubQueries + githubQueries
        )
    }

    private static func remainingSeconds(to deadline: Date) -> TimeInterval {
        max(0.05, deadline.timeIntervalSinceNow)
    }

    private enum DeadlineOutcome<Value: Sendable>: Sendable {
        case value(Value)
        case failure(String)
        case timedOut
    }

    private struct RepositoryDiscoveryOperationFailure: Error {}

    /// 对 Sendable 的远端调用施加同轮共享 deadline；LLM 客户端自身也收到剩余时间。
    private static func withDeadline<Value: Sendable>(
        to deadline: Date,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let outcome = await withTaskGroup(of: DeadlineOutcome<Value>.self) { group -> DeadlineOutcome<Value> in
            group.addTask { () -> DeadlineOutcome<Value> in
                do {
                    return .value(try await operation())
                } catch is CancellationError {
                    return .timedOut
                } catch {
                    return .failure("\(error)")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)), clock: .continuous)
                return .timedOut
            }
            guard let first = await group.next() else {
                return .timedOut
            }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .value(let value):
            return value
        case .failure:
            throw RepositoryDiscoveryOperationFailure()
        case .timedOut:
            throw RepositoryDiscoveryTimeout()
        }
    }

    /// 只从 Web URL 提取 GitHub 身份，不从标题猜测 owner/name。
    private static func githubIdentities(from references: [ReferenceCandidate]) -> [RepoIdentity] {
        var seen = Set<String>()
        var identities: [RepoIdentity] = []
        for reference in references {
            guard let host = reference.originalURL.host?.lowercased(),
                  host == "github.com" || host.hasSuffix(".github.com")
            else { continue }
            let components = reference.originalURL.pathComponents.filter { $0 != "/" }
            guard components.count >= 2 else { continue }
            let owner = components[0]
            let name = components[1]
            guard Self.isValidGitHubName(owner), Self.isValidGitHubName(name) else { continue }
            let identity = RepoIdentity(ghRepoID: nil, owner: owner, name: name)
            if seen.insert(identity.normalizedFullName).inserted {
                identities.append(identity)
            }
        }
        return identities
    }

    private static func isValidGitHubName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 100
            && value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
            && !value.hasPrefix(".")
            && !value.hasSuffix(".")
    }

    private static func deduplicated(_ candidates: [RepositoryCandidate]) -> [RepositoryCandidate] {
        var byIdentity: [RepoIdentity: RepositoryCandidate] = [:]
        var order: [RepoIdentity] = []
        for candidate in candidates {
            if byIdentity[candidate.identity] == nil {
                order.append(candidate.identity)
            }
            if let existing = byIdentity[candidate.identity] {
                var merged = existing
                merged.sources.formUnion(candidate.sources)
                if merged.remoteRepo == nil { merged.remoteRepo = candidate.remoteRepo }
                byIdentity[candidate.identity] = merged
            } else {
                byIdentity[candidate.identity] = candidate
            }
        }
        return order.compactMap { byIdentity[$0] }
    }

    private static func deduplicatedReferences(_ references: [ReferenceCandidate]) -> [ReferenceCandidate] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.id).inserted }
    }

    private static func deterministicallyRanked(
        _ candidates: [RepositoryCandidate],
        budget: SearchDiscoveryBudget
    ) -> [RepositoryCandidate] {
        candidates.prefix(budget.maxRankedCandidates).enumerated().map { index, candidate in
            var ranked = candidate
            ranked.discovery = SearchDiscoveryAnnotation(
                reason: candidate.discovery?.reason.isEmpty == false
                    ? candidate.discovery!.reason
                    : "GitHub repository search candidate",
                evidenceIDs: candidate.discovery?.evidenceIDs ?? [],
                rank: index
            )
            return ranked
        }
    }

    private static func applying(
        _ items: [SearchDiscoveryRankedItem],
        to candidates: [RepositoryCandidate],
        evidence: [SearchEvidence],
        budget: SearchDiscoveryBudget
    ) -> [RepositoryCandidate] {
        let availableEvidence = Set(evidence.map(\.id))
        var byID = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.identity.normalizedFullName, $0)
        })
        var ranked: [RepositoryCandidate] = []
        var usedIDs = Set<String>()

        for item in items.prefix(budget.maxRankedCandidates) {
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty,
                  !usedIDs.contains(id),
                  var candidate = byID[id],
                  !item.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(item.evidenceIDs).isSubset(of: availableEvidence)
            else { continue }
            candidate.discovery = SearchDiscoveryAnnotation(
                reason: item.reason,
                evidenceIDs: item.evidenceIDs,
                rank: ranked.count
            )
            ranked.append(candidate)
            usedIDs.insert(id)
            byID[id] = nil
        }

        for var candidate in byID.values where ranked.count < budget.maxRankedCandidates {
            candidate.discovery = SearchDiscoveryAnnotation(
                reason: "GitHub repository search candidate",
                evidenceIDs: [],
                rank: ranked.count
            )
            ranked.append(candidate)
        }
        return ranked
    }
}
