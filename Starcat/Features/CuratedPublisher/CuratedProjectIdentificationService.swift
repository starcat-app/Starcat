//
//  CuratedProjectIdentificationService.swift
//  Starcat
//
//  复刻 starcat-weekly-import Skill 的 AI 项目甄别流程：自然语言拆分、联网搜索、
//  证据判断与 GitHub canonical 核验。
//
//  为什么不是“把整段文字交给 GitHub Search”：新闻标题、产品名和网页链接不是仓库名，
//  必须先由模型理解发布主体，再用外部证据定位候选。GitHub 在本流程中是事实校验器，
//  不是自然语言理解器；Weekly API 完全不参与识别。
//

import Foundation

struct CuratedProjectAICompletion: Equatable, Sendable {
    let content: String
    let modelName: String
}

/// 把具体 AI Provider/Keychain 配置隔离在推理适配器内，核心识别服务只消费 JSON completion。
@MainActor
protocol CuratedProjectAIReasoning {
    func completeJSON(
        systemPrompt: String,
        userPrompt: String,
        phase: String,
        selectedModelID: String?
    ) async throws -> CuratedProjectAICompletion
}

/// 生产环境 AI 适配器：复用 Starcat 已配置的 Chat 任务或发布台显式选择的模型。
@MainActor
struct DefaultCuratedProjectAIReasoner: CuratedProjectAIReasoning {
    let settings: AppSettings
    var keychain: any KeychainManaging = KeychainManager.shared

    func completeJSON(
        systemPrompt: String,
        userPrompt: String,
        phase: String,
        selectedModelID: String?
    ) async throws -> CuratedProjectAICompletion {
        let selection = try resolveSelection(selectedModelID: selectedModelID)
        let apiKey = try keychain.loadAIKey(forProvider: selection.profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || selection.profile.provider.allowsEmptyAPIKey else {
            throw AgentLoopModelError.missingAPIKey
        }

        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: selection.profile.id,
            provider: selection.profile.provider,
            apiKey: apiKey,
            baseURL: selection.profile.baseURL,
            chatModel: selection.modelName,
            embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
            timeoutInterval: selection.parameters.timeoutSeconds
        ))
        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: selection.modelName,
            parameters: selection.parameters,
            responseFormat: .jsonObject,
            includeUsage: true,
            usageContext: AIUsageContext(feature: .agent, phase: phase)
        ))
        return CuratedProjectAICompletion(content: response.content, modelName: response.model)
    }

    private func resolveSelection(selectedModelID: String?) throws -> Selection {
        if let selectedModelID {
            for profile in settings.aiProviderProfiles where profile.isEnabled {
                if let model = profile.models.first(where: {
                    $0.id == selectedModelID && $0.isEnabled && $0.capability != .embedding
                }) {
                    return Selection(
                        profile: profile,
                        modelName: model.name,
                        parameters: model.parameters ?? AIModelParameters.defaults(for: model.capability)
                    )
                }
            }
        }

        let task = settings.aiChatTask
        guard let profile = settings.aiProviderProfiles.first(where: {
            $0.id == task.providerID && $0.isEnabled
        }) else {
            throw AgentLoopModelError.missingProvider
        }
        let modelName = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { throw AgentLoopModelError.missingProvider }
        return Selection(
            profile: profile,
            modelName: modelName,
            parameters: settings.effectiveParameters(for: task)
        )
    }

    private struct Selection {
        let profile: AIProviderProfile
        let modelName: String
        let parameters: AIModelParameters
    }
}

/// GitHub 事实读取边界。测试可用轻量 stub 覆盖，不必实现完整 GitHubAPIClientProtocol。
protocol CuratedRepositoryEvidenceProviding: Sendable {
    func search(query: String) async throws -> [RepositoryCandidate]
    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate
    func readmeExcerpt(address: GitHubRepositoryAddress) async -> String?
}

struct DefaultCuratedRepositoryEvidenceProvider: CuratedRepositoryEvidenceProviding {
    private let searchProvider: any SearchProvider
    private let githubClient: any GitHubAPIClientProtocol

    init(searchProvider: any SearchProvider, githubClient: any GitHubAPIClientProtocol) {
        self.searchProvider = searchProvider
        self.githubClient = githubClient
    }

    func search(query: String) async throws -> [RepositoryCandidate] {
        try await searchProvider.search(
            SearchRequest(query: query, scope: .github, page: 1, perPage: 8)
        ).repositories
    }

    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate {
        let candidates = try await search(query: "repo:\(address.owner)/\(address.repo)")
        guard let exact = candidates.first(where: {
            $0.identity.normalizedFullName == address.normalizedFullName
        }) else {
            throw CuratedProjectResolverError.repositoryNotFound("\(address.owner)/\(address.repo)")
        }
        return exact
    }

    func readmeExcerpt(address: GitHubRepositoryAddress) async -> String? {
        guard let response = try? await githubClient.readmeMarkdown(
            owner: address.owner,
            repo: address.repo,
            ifNoneMatch: nil,
            ifModifiedSince: nil
        ), let markdown = String(data: response.data, encoding: .utf8)
        else { return nil }
        let compact = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        // README 只作为归属证据，限制体积可避免多个候选把模型上下文迅速撑满。
        return String(compact.prefix(2_000))
    }
}

@MainActor
protocol CuratedProjectIdentifying {
    func identify(
        input: String,
        externalSearchProvider: ExternalSearchProviderID,
        selectedModelID: String?,
        onProgress: @escaping @MainActor (CuratedProjectIdentificationPhase) -> Void
    ) async throws -> CuratedProjectIdentification
    func verify(repositoryURL: String) async throws -> RepositoryCandidate
}

enum CuratedProjectIdentificationError: Error, LocalizedError {
    case emptyInput
    case invalidAIResponse
    case noItems

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String.l10n("curatedPublisher.error.emptyClue")
        case .invalidAIResponse:
            return String.l10n("curatedPublisher.error.aiInvalidResponse")
        case .noItems:
            return String.l10n("curatedPublisher.error.noCandidates")
        }
    }
}

/// 专用的三阶段 AI 甄别服务。
///
/// 模型不会直接获得 Weekly 写能力；服务也不持有 CuratedPublisherAPIProtocol，从类型层面
/// 保证“识别项目”按钮无法访问管理员导入接口。
@MainActor
final class CuratedProjectIdentificationService: CuratedProjectIdentifying {
    private let reasoner: any CuratedProjectAIReasoning
    private let webProvider: any SearchProvider
    private let repositories: any CuratedRepositoryEvidenceProviding

    init(
        reasoner: any CuratedProjectAIReasoning,
        webProvider: any SearchProvider,
        repositories: any CuratedRepositoryEvidenceProviding
    ) {
        self.reasoner = reasoner
        self.webProvider = webProvider
        self.repositories = repositories
    }

    func identify(
        input: String,
        externalSearchProvider: ExternalSearchProviderID,
        selectedModelID: String?,
        onProgress: @escaping @MainActor (CuratedProjectIdentificationPhase) -> Void = { _ in }
    ) async throws -> CuratedProjectIdentification {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CuratedProjectIdentificationError.emptyInput }

        onProgress(.understanding)
        let parsedCompletion = try await reasoner.completeJSON(
            systemPrompt: Self.decompositionSystemPrompt,
            userPrompt: trimmed,
            phase: "curated_identification_parse",
            selectedModelID: selectedModelID
        )
        let items = try decode(ParsedBatch.self, from: parsedCompletion.content).items
        guard !items.isEmpty else { throw CuratedProjectIdentificationError.noItems }

        var evidenceBundles: [EvidenceBundle] = []
        for (offset, item) in items.prefix(200).enumerated() {
            onProgress(.searching(completed: offset, total: min(items.count, 200)))
            evidenceBundles.append(try await collectEvidence(
                for: item.normalized(index: offset),
                externalSearchProvider: externalSearchProvider
            ))
        }

        onProgress(.judging)
        var findings: [CuratedProjectFinding] = []
        for chunk in evidenceBundles.chunked(maxCount: 10) {
            let completion = try await reasoner.completeJSON(
                systemPrompt: Self.judgementSystemPrompt,
                userPrompt: evidencePrompt(for: chunk),
                phase: "curated_identification_judge",
                selectedModelID: selectedModelID
            )
            let judgements = try decode(JudgementBatch.self, from: completion.content).items
            findings.append(contentsOf: await materializeFindings(bundles: chunk, judgements: judgements))
        }
        onProgress(.idle)
        return CuratedProjectIdentification(
            findings: findings.sorted { $0.id < $1.id },
            modelName: parsedCompletion.modelName
        )
    }

    /// 人工修正只接受 GitHub canonical 核验成功的仓库，不能把自由文本直接升级为可发布项。
    func verify(repositoryURL: String) async throws -> RepositoryCandidate {
        guard let address = GitHubRepositoryAddress.parse(repositoryURL) else {
            throw CuratedPublisherSessionError.invalidFinalURL
        }
        return try await repositories.verify(address: address)
    }

    private func collectEvidence(
        for item: ParsedItem,
        externalSearchProvider: ExternalSearchProviderID
    ) async throws -> EvidenceBundle {
        var references: [ReferenceCandidate] = []
        var candidates: [RepositoryCandidate] = []
        var seenReferences: Set<String> = []
        var seenRepositories: Set<String> = []

        if let explicitAddress = item.explicitAddress,
           let exact = try? await repositories.verify(address: explicitAddress) {
            candidates.append(exact)
            seenRepositories.insert(explicitAddress.normalizedFullName)
        }

        // Skill 要求逐条搜索发布主体。每条最多使用三组由 AI 生成的检索式，避免长批次
        // 无边界放大网络请求；失败只损失该组证据，不阻断其他查询和 GitHub 候选。
        for query in item.effectiveSearchQueries.prefix(3) {
            if let page = try? await webProvider.search(
                SearchRequest(
                    query: query,
                    scope: .web,
                    externalSearchFilters: ExternalSearchFilters(
                        maxResults: 6,
                        freshness: .any,
                        includeDomains: [],
                        excludeDomains: []
                    ),
                    externalSearchProvider: externalSearchProvider,
                    perPage: 6
                )
            ) {
                for reference in page.references where seenReferences.insert(reference.id).inserted {
                    references.append(reference)
                }
            }

            if let githubCandidates = try? await repositories.search(query: query) {
                for candidate in githubCandidates where seenRepositories.insert(
                    candidate.identity.normalizedFullName
                ).inserted {
                    candidates.append(candidate)
                }
            }
        }

        // Web 结果中的 GitHub 地址也要逐一走 canonical 核验，不能把搜索摘要当作仓库事实。
        for reference in references.prefix(12) {
            guard let address = GitHubRepositoryAddress.parse(reference.normalizedURL.absoluteString),
                  seenRepositories.insert(address.normalizedFullName).inserted,
                  let candidate = try? await repositories.verify(address: address)
            else { continue }
            candidates.append(candidate)
        }

        var readmes: [String: String] = [:]
        for candidate in candidates.prefix(4) {
            let address = GitHubRepositoryAddress(owner: candidate.identity.owner, repo: candidate.identity.name)
            if let excerpt = await repositories.readmeExcerpt(address: address) {
                readmes[address.normalizedFullName] = excerpt
            }
        }
        return EvidenceBundle(item: item, references: references, candidates: candidates, readmes: readmes)
    }

    private func materializeFindings(
        bundles: [EvidenceBundle],
        judgements: [Judgement]
    ) async -> [CuratedProjectFinding] {
        let judgementsByID = Dictionary(judgements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var findings: [CuratedProjectFinding] = []

        for bundle in bundles {
            let judgement = judgementsByID[bundle.item.id]
            var status = judgement?.status ?? .needsReview
            var selected: RepositoryCandidate?
            if let fullName = judgement?.repository,
               let address = GitHubRepositoryAddress.parse(fullName),
               bundle.candidates.contains(where: {
                   $0.identity.normalizedFullName == address.normalizedFullName
               }),
               let verified = try? await repositories.verify(address: address) {
                selected = verified
            } else if status == .confirmed {
                // AI 声称已确认但地址不在已收集候选或无法再次核验时必须降级，禁止幻觉写入。
                status = .needsReview
            }

            let evidenceURLs = Set(judgement?.evidenceURLs ?? [])
            let evidence = bundle.references.compactMap { reference -> CuratedProjectEvidence? in
                if !evidenceURLs.isEmpty && !evidenceURLs.contains(reference.normalizedURL.absoluteString) {
                    return nil
                }
                return CuratedProjectEvidence(
                    title: reference.title,
                    url: reference.normalizedURL,
                    snippet: reference.snippet
                )
            }
            findings.append(CuratedProjectFinding(
                id: bundle.item.id,
                originalText: bundle.item.originalText,
                title: bundle.item.title,
                sourceURL: bundle.item.sourceURL.flatMap(URL.init(string:)),
                status: status,
                reason: judgement?.reason ?? String.l10n("curatedPublisher.error.aiInvalidResponse"),
                repository: selected,
                candidates: bundle.candidates,
                evidence: evidence.isEmpty
                    ? bundle.references.prefix(4).map {
                        CuratedProjectEvidence(title: $0.title, url: $0.normalizedURL, snippet: $0.snippet)
                    }
                    : evidence
            ))
        }
        return findings
    }

    private func evidencePrompt(for bundles: [EvidenceBundle]) -> String {
        bundles.map { bundle in
            let web = bundle.references.prefix(8).map {
                "- \($0.title) | \($0.normalizedURL.absoluteString) | \($0.snippet ?? "")"
            }.joined(separator: "\n")
            let repos = bundle.candidates.prefix(8).map { candidate in
                let fullName = candidate.identity.normalizedFullName
                return """
                - \(candidate.card.fullName)
                  url: https://github.com/\(candidate.identity.owner)/\(candidate.identity.name)
                  description: \(candidate.card.description ?? "")
                  fork: \(candidate.card.isFork)
                  archived: \(candidate.card.isArchived)
                  readme: \(bundle.readmes[fullName] ?? "")
                """
            }.joined(separator: "\n")
            return """
            ## item_id: \(bundle.item.id)
            original: \(bundle.item.originalText)
            title: \(bundle.item.title)
            entity_type: \(bundle.item.entityType)
            source_url: \(bundle.item.sourceURL ?? "")

            ### web evidence
            \(web.isEmpty ? "- none" : web)

            ### verified GitHub candidates
            \(repos.isEmpty ? "- none" : repos)
            """
        }.joined(separator: "\n\n")
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            candidate = String(trimmed[start...end])
        } else {
            throw CuratedProjectIdentificationError.invalidAIResponse
        }
        do {
            return try JSONDecoder().decode(type, from: Data(candidate.utf8))
        } catch {
            throw CuratedProjectIdentificationError.invalidAIResponse
        }
    }

    private static let decompositionSystemPrompt = """
    你是 Starcat 的项目线索解析器。把输入中的新闻、项目清单、网页链接和 GitHub 地址按原始顺序拆成独立条目。
    新闻标题不是仓库名。请判断每条线索的发布主体和 entity_type（open_source_project/product/service/paper/model/hardware/unknown），并生成最多三条联网检索式。
    不要猜测不存在的 GitHub 地址。只在原文明确出现 GitHub 仓库时填写 explicit_repository。
    只输出 JSON：
    {"items":[{"id":0,"original_text":"...","title":"...","entity_type":"...","source_url":null,"explicit_repository":null,"search_queries":["..."]}]}
    """

    private static let judgementSystemPrompt = """
    你是 Starcat Weekly 的项目真实性审查员。请严格复刻 starcat-weekly-import 的核验标准：
    1. 只确认与原始主体直接对应的官方 GitHub 仓库；
    2. 排除 fork、镜像、占位仓库、同名无关项目、第三方实现、上游项目和配套工具；
    3. 闭源产品、云服务、论文、模型权重或硬件没有官方仓库时返回 not_found；
    4. 证据不足或存在多个合理候选时返回 needs_review，不要猜测；
    5. repository 只能从 verified GitHub candidates 中选择。
    只输出 JSON：
    {"items":[{"id":0,"status":"confirmed|needs_review|not_found","repository":"owner/repo 或 null","reason":"简洁依据","evidence_urls":["https://..."]}]}
    """
}

private struct ParsedBatch: Decodable {
    let items: [ParsedItem]
}

private struct ParsedItem: Decodable {
    let id: Int
    let originalText: String
    let title: String
    let entityType: String
    let sourceURL: String?
    let explicitRepository: String?
    let searchQueries: [String]

    enum CodingKeys: String, CodingKey {
        case id, title
        case originalText = "original_text"
        case entityType = "entity_type"
        case sourceURL = "source_url"
        case explicitRepository = "explicit_repository"
        case searchQueries = "search_queries"
    }

    var explicitAddress: GitHubRepositoryAddress? {
        explicitRepository.flatMap(GitHubRepositoryAddress.parse)
    }

    var effectiveSearchQueries: [String] {
        var queries = searchQueries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if queries.isEmpty { queries = ["\(title) GitHub", "\(title) 官方 GitHub"] }
        return queries
    }

    func normalized(index: Int) -> ParsedItem {
        ParsedItem(
            id: index,
            originalText: originalText,
            title: title,
            entityType: entityType,
            sourceURL: sourceURL,
            explicitRepository: explicitRepository,
            searchQueries: searchQueries
        )
    }
}

private struct EvidenceBundle {
    let item: ParsedItem
    let references: [ReferenceCandidate]
    let candidates: [RepositoryCandidate]
    let readmes: [String: String]
}

private struct JudgementBatch: Decodable {
    let items: [Judgement]
}

private struct Judgement: Decodable {
    let id: Int
    let status: CuratedProjectIdentificationStatus
    let repository: String?
    let reason: String
    let evidenceURLs: [String]

    enum CodingKeys: String, CodingKey {
        case id, status, repository, reason
        case evidenceURLs = "evidence_urls"
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0 else { return [self] }
        return stride(from: 0, to: count, by: maxCount).map {
            Array(self[$0..<Swift.min($0 + maxCount, count)])
        }
    }
}
