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
    var kind: SearchDiscoveryRankerKind { get }
    /// 用于详情面板展示的模型名称；本地/未解析时返回 nil，不影响排序执行。
    var modelDisplayName: String? { get }

    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem]
}

extension SearchDiscoveryRankerProviding {
    var modelDisplayName: String? { nil }
}

/// 搜索重排有两种资源口径：Chat 排序消耗 LLM 预算，专用 Rerank 只消耗独立模型调用。
enum SearchDiscoveryRankerKind: Equatable, Sendable {
    case chat
    case dedicatedRerank

    var consumesLLMBudget: Bool {
        self == .chat
    }
}

/// 搜索专属 LLM Ranker。
///
/// 模型只输出候选 ID、理由和证据引用；服务层负责校验并重写排名。这样模型无法
/// 发明仓库名、覆盖 GitHub 元数据或把未验证网页内容变成事实。
@MainActor
final class SearchLLMDiscoveryRanker: SearchDiscoveryRankerProviding {
    let kind: SearchDiscoveryRankerKind = .chat

    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(settings: AppSettings, keychain: any KeychainManaging) {
        self.settings = settings
        self.keychain = keychain
    }

    var modelDisplayName: String? {
        try? settings.resolveChatSelection(
            for: settings.resolvedAITask(settings.aiChatTask)
        ).modelName
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
                maxCompletionTokens: min(task.parameters.maxCompletionTokens, 2_048),
                timeoutSeconds: min(task.parameters.timeoutSeconds, maxSeconds),
                streamEnabled: false
            ),
            disableThinking: true
        ))
        return try Self.decode(response.content)
    }

    private static func decode(_ raw: String) throws -> [SearchDiscoveryRankedItem] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = extractJSONArray(from: text).data(using: .utf8)
        else { throw RepositoryDiscoveryError.invalidRankerResponse("No JSON array was found") }
        do {
            return try JSONDecoder().decode([RawRankedItem].self, from: data).map {
                SearchDiscoveryRankedItem(
                    id: $0.id,
                    reason: $0.reason,
                    evidenceIDs: $0.evidenceIDs
                )
            }
        } catch {
            throw RepositoryDiscoveryError.invalidRankerResponse(String(describing: error))
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

/// 使用用户在 RAG 设置中启用的专用 Rerank。
///
/// 这里复用现有 TEI / Cohere / Local MLX Provider，只把仓库候选映射成一次性内存
/// `RAGChildHit`；不会伪造可持久化的知识库分片，也不会改动 RAG 的检索行为。
@MainActor
final class SearchDiscoveryRerankRanker: SearchDiscoveryRankerProviding {
    let kind: SearchDiscoveryRankerKind = .dedicatedRerank

    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(settings: AppSettings, keychain: any KeychainManaging) {
        self.settings = settings
        self.keychain = keychain
    }

    var debugModel: String? {
        let configuration = settings.ragRerankConfiguration.normalized
        switch configuration.provider {
        case .localMLX:
            return settings.selectedLocalAIModel(for: .reranker).displayName
        case .cohereCompatible:
            return configuration.model
        case .huggingFaceTEI:
            return "Hugging Face TEI"
        }
    }

    var modelDisplayName: String? { debugModel }

    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem] {
        let configuration = settings.ragRerankConfiguration.normalized
        guard configuration.isEnabled else {
            throw RepositoryDiscoveryError.dedicatedRerankDisabled
        }
        guard maxSeconds > 0 else { throw URLError(.timedOut) }

        let apiKey = try keychain.loadAIKey(forProvider: RAGRerankConfiguration.keychainID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reranker: any RAGReranking
        switch configuration.provider {
        case .huggingFaceTEI:
            reranker = HuggingFaceTEIRAGReranker(
                configuration: configuration, apiKey: apiKey, timeoutSeconds: maxSeconds
            )
        case .cohereCompatible:
            reranker = CohereCompatibleRAGReranker(
                configuration: configuration, apiKey: apiKey, timeoutSeconds: maxSeconds
            )
        case .localMLX:
            reranker = LocalMLXRAGReranker(
                configuration: configuration,
                model: settings.selectedLocalAIModel(for: .reranker)
            )
        }

        let hits = candidates.enumerated().map { index, candidate in
            Self.hit(for: candidate, index: index, evidence: evidence)
        }
        let scored = try await reranker.rerank(query: query, candidates: hits)
        var usedKeys = Set<String>()
        var ranked: [SearchDiscoveryRankedItem] = []

        for result in scored {
            let key = result.hit.chunk.parentKey
            guard !key.isEmpty,
                  usedKeys.insert(key).inserted,
                  let candidate = candidates.first(where: { $0.id.lowercased() == key })
            else { continue }
            ranked.append(SearchDiscoveryRankedItem(
                id: candidate.id,
                reason: String.l10n("search.discovery.rerank.reason"),
                evidenceIDs: candidate.evidenceIDs
            ))
        }

        // Provider 允许过滤低分结果。未返回的候选保留原顺序，避免候选凭空消失。
        for candidate in candidates where !usedKeys.contains(candidate.id.lowercased()) {
            ranked.append(SearchDiscoveryRankedItem(
                id: candidate.id,
                reason: String.l10n("search.discovery.rerank.reason"),
                evidenceIDs: candidate.evidenceIDs
            ))
        }
        return ranked
    }

    /// `parentKey` 只存在于本轮函数调用内，用来把 Provider 结果映射回搜索候选 ID。
    private static func hit(
        for candidate: SearchDiscoveryRankingCandidate,
        index: Int,
        evidence: [SearchEvidence]
    ) -> RAGChildHit {
        let evidenceText = evidence
            .filter { candidate.evidenceIDs.contains($0.id) }
            .map { [$0.title, $0.snippet ?? ""].filter { !$0.isEmpty }.joined(separator: "\n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let description = candidate.description ?? ""
        let chunk = RAGChunk(
            id: Int64(index),
            repoId: Int64(index + 1),
            source: .metadata,
            sourceId: candidate.id,
            parentType: .readmeSection,
            parentKey: candidate.id.lowercased(),
            parentTitle: candidate.fullName,
            chunkKey: "search-discovery-\(index)",
            chunkIndex: index,
            sectionPath: "Repository",
            title: candidate.fullName,
            content: [description, evidenceText].filter { !$0.isEmpty }.joined(separator: "\n"),
            contentHash: RAGChunk.hash("\(candidate.id)|\(evidenceText)"),
            tokenCount: max(1, description.count / 4),
            isTruncated: false,
            embeddingModel: nil,
            embeddingDim: nil,
            embedding: nil,
            embeddingStatus: .pending,
            embeddingError: nil,
            indexedAt: timestamp,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return RAGChildHit(chunk: chunk, score: 0, kind: .structured)
    }
}

/// 按当前设置动态选择 Ranker，保证设置页切换启用状态后无需重建 AppDependencies。
@MainActor
final class DynamicSearchDiscoveryRanker: SearchDiscoveryRankerProviding {
    var kind: SearchDiscoveryRankerKind {
        settings.ragRerankConfiguration.normalized.isEnabled ? .dedicatedRerank : .chat
    }

    private let settings: AppSettings
    private let chatRanker: SearchLLMDiscoveryRanker
    private let rerankRanker: SearchDiscoveryRerankRanker

    var modelDisplayName: String? {
        settings.ragRerankConfiguration.normalized.isEnabled
            ? rerankRanker.modelDisplayName
            : chatRanker.modelDisplayName
    }

    init(settings: AppSettings, keychain: any KeychainManaging) {
        self.settings = settings
        self.chatRanker = SearchLLMDiscoveryRanker(settings: settings, keychain: keychain)
        self.rerankRanker = SearchDiscoveryRerankRanker(settings: settings, keychain: keychain)
    }

    func rank(
        query: String,
        plan: SearchDiscoveryPlan,
        candidates: [SearchDiscoveryRankingCandidate],
        evidence: [SearchEvidence],
        maxSeconds: TimeInterval
    ) async throws -> [SearchDiscoveryRankedItem] {
        if settings.ragRerankConfiguration.normalized.isEnabled {
            return try await rerankRanker.rank(
                query: query,
                plan: plan,
                candidates: candidates,
                evidence: evidence,
                maxSeconds: maxSeconds
            )
        }
        return try await chatRanker.rank(
            query: query,
            plan: plan,
            candidates: candidates,
            evidence: evidence,
            maxSeconds: maxSeconds
        )
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
    case invalidRankerResponse(String)
    case missingRankerCredential
    case dedicatedRerankDisabled
}

private struct RepositoryDiscoveryTimeout: Error {}

/// 一轮智能发现结果。诊断保留失败步骤与原因，局部失败不清空已成功证据。
struct RepositoryDiscoveryResult: Equatable, Sendable {
    let session: SearchDiscoverySession
    let repositories: [RepositoryCandidate]
    let references: [ReferenceCandidate]
    let diagnostics: [SearchDiscoveryDiagnostic]
    /// 本轮完整步骤快照。默认回落到 session.steps，便于只返回局部结果的调用方
    /// 无需重复维护两份一致的数据；发现服务成功完成时在这里写入最终顺序。
    let steps: [SearchDiscoveryStep]

    init(
        session: SearchDiscoverySession,
        repositories: [RepositoryCandidate],
        references: [ReferenceCandidate],
        diagnostics: [SearchDiscoveryDiagnostic],
        steps: [SearchDiscoveryStep]? = nil
    ) {
        self.session = session
        self.repositories = repositories
        self.references = references
        self.diagnostics = diagnostics
        self.steps = steps ?? session.steps
    }
}

@MainActor
protocol RepositoryDiscoveryProviding: AnyObject {
    func discover(
        query: String,
        request baseRequest: SearchRequest,
        initialPlan: SearchDiscoveryPlan?,
        generation: UUID,
        round: Int,
        budget: SearchDiscoveryBudget,
        initialLLMCalls: Int,
        deadline: Date?
    ) async -> RepositoryDiscoveryResult
}

extension RepositoryDiscoveryService: RepositoryDiscoveryProviding {}

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
        initialLLMCalls: Int = 1,
        deadline: Date? = nil
    ) async -> RepositoryDiscoveryResult {
        var diagnostics: [SearchDiscoveryDiagnostic] = []
        var steps: [SearchDiscoveryStep] = []
        var usedLLMCalls = max(0, initialLLMCalls)
        let deadline = deadline ?? Date().addingTimeInterval(budget.timeoutSeconds)
        guard !Task.isCancelled else {
            return Self.cancelledResult(generation: generation, round: round)
        }

        var plan = initialPlan?.normalized
        if plan == nil {
            guard let planner else {
                let session = SearchDiscoverySession(
                    generation: generation,
                    round: round,
                    phase: .failed("Search query planner is unavailable"),
                    plan: nil,
                    usedLLMCalls: usedLLMCalls,
                    steps: [SearchDiscoveryStep(id: "planning", stage: .planning, state: .failed)]
                )
                return RepositoryDiscoveryResult(
                    session: session,
                    repositories: [],
                    references: [],
                    diagnostics: [.unavailable(stage: .planning)]
                )
            }
            let planStart = Date()
            do {
                let generated = try await SearchDiscoveryDeadline.run(until: deadline) {
                    try await planner.plan(
                        query: query,
                        allowWebEvidence: baseRequest.includeWebInAll || baseRequest.scope == .web,
                        maxSeconds: Self.remainingSeconds(to: deadline)
                    )
                }
                plan = generated.normalized
                usedLLMCalls += 1
                steps.append(SearchDiscoveryStep(
                    id: "planning",
                    stage: .planning,
                    state: .completed,
                    detail: generated.intentSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                    durationSeconds: Self.duration(since: planStart),
                    model: planner.modelDisplayName
                ))
            } catch where DiagnosticFailure.isCancellation(error) {
                return Self.cancelledResult(generation: generation, round: round)
            } catch {
                let session = SearchDiscoverySession(
                    generation: generation,
                    round: round,
                    phase: .failed("Search query planner failed"),
                    plan: nil,
                    usedLLMCalls: usedLLMCalls,
                    steps: steps + [SearchDiscoveryStep(
                        id: "planning",
                        stage: .planning,
                        state: .failed,
                        durationSeconds: Self.duration(since: planStart),
                        model: planner.modelDisplayName
                    )]
                )
                return RepositoryDiscoveryResult(
                    session: session,
                    repositories: [],
                    references: [],
                    diagnostics: [.failure(stage: .planning, error: error)],
                    steps: session.steps
                )
            }
        }

        guard let normalizedPlan = plan, normalizedPlan.isValid, budget.isValid else {
            let session = SearchDiscoverySession(
                generation: generation,
                round: round,
                phase: .failed("Invalid discovery plan or budget"),
                plan: plan,
                usedLLMCalls: usedLLMCalls,
                steps: steps + [SearchDiscoveryStep(
                    id: "planning",
                    stage: .planning,
                    state: .failed
                )]
            )
            return RepositoryDiscoveryResult(
                session: session,
                repositories: [],
                references: [],
                diagnostics: [.failure(stage: .planning, error: SearchIntentRouterError.invalidPlan)],
                steps: session.steps
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

        for webQuery in normalizedPlan.webQueries
        where session.canRunWebQuery(in: budget) && !Task.isCancelled {
            guard Date() < deadline else {
                diagnostics.append(.failure(stage: .webSearch, error: URLError(.timedOut)))
                break
            }
            guard let webProvider = webProvider else { continue }
            let searchStart = Date()
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
                steps.append(SearchDiscoveryStep(
                    id: "webSearch-\(session.usedWebQueries - 1)",
                    stage: .webSearch,
                    state: .completed,
                    detail: Self.countDetail(page.references.count),
                    durationSeconds: Self.duration(since: searchStart)
                ))
            } catch where DiagnosticFailure.isCancellation(error) {
                return Self.cancelledResult(generation: generation, round: round)
            } catch {
                session = Self.incrementing(session, webQueries: 1)
                diagnostics.append(Self.failureDiagnostic(stage: .webSearch, error: error))
                steps.append(SearchDiscoveryStep(
                    id: "webSearch-\(session.usedWebQueries - 1)",
                    stage: .webSearch,
                    state: .failed,
                    durationSeconds: Self.duration(since: searchStart)
                ))
            }
        }

        for githubQuery in normalizedPlan.githubQueries
        where session.canRunGitHubQuery(in: budget) && !Task.isCancelled {
            guard Date() < deadline else {
                diagnostics.append(.failure(stage: .githubSearch, error: URLError(.timedOut)))
                break
            }
            let searchStart = Date()
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
                steps.append(SearchDiscoveryStep(
                    id: "githubSearch-\(session.usedGitHubQueries - 1)",
                    stage: .githubSearch,
                    state: .completed,
                    detail: Self.countDetail(page.repositories.count),
                    durationSeconds: Self.duration(since: searchStart)
                ))
            } catch where DiagnosticFailure.isCancellation(error) {
                return Self.cancelledResult(generation: generation, round: round)
            } catch {
                session = Self.incrementing(session, githubQueries: 1)
                diagnostics.append(Self.failureDiagnostic(stage: .githubSearch, error: error))
                steps.append(SearchDiscoveryStep(
                    id: "githubSearch-\(session.usedGitHubQueries - 1)",
                    stage: .githubSearch,
                    state: .failed,
                    durationSeconds: Self.duration(since: searchStart)
                ))
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
        let verificationStart = Date()
        let initialVerificationCount = extractedIdentities.count
        var verificationAttempts = 0
        var verificationSuccessCount = 0
        while verificationAttempts < budget.maxVerifiedRepositories,
              !extractedIdentities.isEmpty,
              Date() < deadline,
              !Task.isCancelled {
            let identity = extractedIdentities.removeFirst()
            // 网页身份没有 GitHub 数字 ID，不能与 API 结果直接比较 RepoIdentity；
            // 按完整仓库名识别已核验候选，避免重复请求耗尽本轮核验上限。
            guard !repositories.contains(where: {
                $0.identity.normalizedFullName == identity.normalizedFullName
            }) else { continue }
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
                    reason: "",
                    evidenceIDs: evidence.filter { $0.url?.absoluteString.hasSuffix("/\(identity.owner)/\(identity.name)") == true }.map(\.id),
                    rank: nil,
                    kind: .githubVerification
                )
                repositories.append(candidate)
                verificationSuccessCount += 1
            } catch where DiagnosticFailure.isCancellation(error) {
                return Self.cancelledResult(generation: generation, round: round)
            } catch {
                if error is RepositoryDiscoveryTimeout {
                    diagnostics.append(Self.failureDiagnostic(stage: .verification, error: error))
                    extractedIdentities.removeAll()
                    break
                }
                diagnostics.append(Self.failureDiagnostic(
                    stage: .verification,
                    error: error,
                    context: "\(identity.owner)/\(identity.name)"
                ))
            }
        }
        // 恰好核验完最后一个仓库不算达到上限；只有仍有未处理身份时才给信息提示。
        let pendingVerification = extractedIdentities.contains { identity in
            !repositories.contains { $0.identity.normalizedFullName == identity.normalizedFullName }
        }
        if pendingVerification {
            if Date() >= deadline {
                diagnostics.append(.failure(stage: .verification, error: URLError(.timedOut)))
            } else if verificationAttempts >= budget.maxVerifiedRepositories {
                diagnostics.append(.limit(stage: .verification))
            }
        }
        // 步骤状态与诊断同口径：预算上限只是信息提示，不算步骤失败；
        // 只有实际出现核验失败或一个仓库都没能核验时才标记失败。
        if initialVerificationCount > 0 {
            let verificationState: SearchDiscoveryStepState
            let verificationDetail: String?
            if verificationAttempts == 0 {
                // 提取到身份但全部与 GitHub 检索候选重复时，没有任何仓库需要核验；
                // 只有因 deadline 提前中断、仍剩身份未处理才是失败。
                if pendingVerification {
                    verificationState = .failed
                    verificationDetail = nil
                } else {
                    verificationState = .skipped
                    verificationDetail = nil
                }
            } else if verificationSuccessCount == verificationAttempts {
                verificationState = .completed
                verificationDetail = String(
                    format: String.l10n("search.discovery.step.verifiedFormat"),
                    verificationSuccessCount
                )
            } else {
                verificationState = .failed
                verificationDetail = String(
                    format: String.l10n("search.discovery.step.verifiedFailedFormat"),
                    verificationSuccessCount,
                    verificationAttempts - verificationSuccessCount
                )
            }
            steps.append(SearchDiscoveryStep(
                id: "verification",
                stage: .verification,
                state: verificationState,
                detail: verificationDetail,
                durationSeconds: Self.duration(since: verificationStart)
            ))
        } else {
            steps.append(SearchDiscoveryStep(
                id: "verification",
                stage: .verification,
                state: .skipped,
                durationSeconds: nil
            ))
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

        let rankerConsumesLLMBudget = ranker?.kind.consumesLLMBudget ?? false
        let rankedRepositories: [RepositoryCandidate]
        let rankingStart = Date()
        if repositories.isEmpty
            || (rankerConsumesLLMBudget && !session.canUseLLM(in: budget))
            || Date() >= deadline
            || Task.isCancelled {
            if !repositories.isEmpty && Date() >= deadline {
                diagnostics.append(.failure(stage: .ranking, error: URLError(.timedOut)))
            } else if !repositories.isEmpty
                && rankerConsumesLLMBudget
                && !session.canUseLLM(in: budget) {
                diagnostics.append(.limit(stage: .ranking))
            }
            rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
            steps.append(SearchDiscoveryStep(
                id: "ranking",
                stage: .ranking,
                state: !repositories.isEmpty && Date() >= deadline ? .failed : .skipped,
                durationSeconds: Self.duration(since: rankingStart),
                model: ranker?.modelDisplayName
            ))
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
                let rankingEvidence = evidence
                let rankedItems = try await SearchDiscoveryDeadline.run(until: deadline) {
                    try await ranker.rank(
                        query: query,
                        plan: normalizedPlan,
                        candidates: Array(summaries),
                        evidence: rankingEvidence,
                        maxSeconds: Self.remainingSeconds(to: deadline)
                    )
                }
                session = Self.incrementing(
                    session,
                    llmCalls: rankerConsumesLLMBudget ? 1 : 0
                )
                rankedRepositories = Self.applying(
                    rankedItems,
                    to: repositories,
                    evidence: evidence,
                    budget: budget
                )
                let rankerValidationFailed = !rankedItems.isEmpty
                    && !rankedRepositories.contains(where: { $0.discovery?.kind == .modelMatch })
                if rankerValidationFailed {
                    diagnostics.append(.failure(
                        stage: .ranking,
                        error: RepositoryDiscoveryError.invalidRankerResponse(
                            "No ranked candidate passed validation"
                        )
                    ))
                }
                steps.append(SearchDiscoveryStep(
                    id: "ranking",
                    stage: .ranking,
                    state: rankerValidationFailed ? .failed : .completed,
                    detail: Self.countDetail(rankedRepositories.count),
                    durationSeconds: Self.duration(since: rankingStart),
                    model: ranker.modelDisplayName
                ))
            } catch where DiagnosticFailure.isCancellation(error) {
                return Self.cancelledResult(generation: generation, round: round)
            } catch {
                session = Self.incrementing(
                    session,
                    llmCalls: rankerConsumesLLMBudget ? 1 : 0
                )
                diagnostics.append(Self.failureDiagnostic(stage: .ranking, error: error))
                rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
                steps.append(SearchDiscoveryStep(
                    id: "ranking",
                    stage: .ranking,
                    state: .failed,
                    durationSeconds: Self.duration(since: rankingStart),
                    model: ranker.modelDisplayName
                ))
            }
        } else {
            rankedRepositories = Self.deterministicallyRanked(repositories, budget: budget)
            steps.append(SearchDiscoveryStep(
                id: "ranking",
                stage: .ranking,
                state: .skipped,
                detail: Self.countDetail(rankedRepositories.count),
                durationSeconds: Self.duration(since: rankingStart)
            ))
        }

        let completed = SearchDiscoverySession(
            generation: generation,
            round: round,
            phase: .completed,
            plan: normalizedPlan,
            evidence: evidence,
            usedLLMCalls: session.usedLLMCalls,
            usedWebQueries: session.usedWebQueries,
            usedGitHubQueries: session.usedGitHubQueries,
            steps: steps
        )
        return RepositoryDiscoveryResult(
            session: completed,
            repositories: rankedRepositories,
            references: references,
            diagnostics: diagnostics
        )
    }

    /// 取消结果只用于调用方身份丢弃；普通失败诊断必须留在失败分支，不能把用户取消记为错误。
    private static func cancelledResult(generation: UUID, round: Int) -> RepositoryDiscoveryResult {
        RepositoryDiscoveryResult(
            session: SearchDiscoverySession(
                generation: generation,
                round: round,
                phase: .completed
            ),
            repositories: [],
            references: [],
            diagnostics: []
        )
    }

    /// 编排超时与网络超时统一映射，用户能看到原因，日志保留原阶段。
    private static func failureDiagnostic(
        stage: SearchDiscoveryDiagnostic.Stage,
        error: Error,
        context: String? = nil
    ) -> SearchDiscoveryDiagnostic {
        .failure(
            stage: stage,
            error: error is RepositoryDiscoveryTimeout ? URLError(.timedOut) : error,
            context: context
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
        max(0, deadline.timeIntervalSinceNow)
    }

    /// 步骤保留实际耗时，UI 决定显示精度；本地同步结果会得到接近 0 的值。
    private static func duration(since start: Date) -> TimeInterval {
        max(0, Date().timeIntervalSince(start))
    }

    /// 步骤详情里的命中数量，避免在多处重复拼接「N 条」这类字符串。
    private static func countDetail(_ count: Int) -> String {
        String(format: String.l10n("search.discovery.step.countFormat"), count)
    }

    /// 对 Sendable 的远端调用施加同轮共享 deadline；LLM 客户端自身也收到剩余时间。
    ///
    /// 超时竞争必须保留真实 Error。转成字符串再抛占位错误会丢失 401 / 404 等状态，
    /// 让统一错误映射只能给出“未知失败”，也无法解释为何某个候选被排除。
    private static func withDeadline<Value: Sendable>(
        to deadline: Date,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await SearchDiscoveryDeadline.run(until: deadline, operation: operation)
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
                reason: candidate.discovery?.reason ?? "",
                evidenceIDs: candidate.discovery?.evidenceIDs ?? [],
                rank: index,
                kind: candidate.discovery?.kind ?? .githubSearch
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
        let byID = Dictionary(uniqueKeysWithValues: candidates.map {
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
        }

        // 没有有效模型理由的候选保留原检索顺序，不能用字典遍历伪造相关性排序。
        for var candidate in candidates
        where !usedIDs.contains(candidate.identity.normalizedFullName)
            && ranked.count < budget.maxRankedCandidates {
            candidate.discovery = SearchDiscoveryAnnotation(
                reason: candidate.discovery?.reason ?? "",
                evidenceIDs: candidate.discovery?.evidenceIDs ?? [],
                rank: ranked.count,
                kind: candidate.discovery?.kind ?? .githubSearch
            )
            ranked.append(candidate)
        }
        return ranked
    }
}
