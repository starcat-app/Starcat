//
//  AgentRunContextProvider.swift
//  Starcat
//
//  Agent run 上下文构建器。
//
//  关键约束：
//  - 只读本地 repository，不从这里触发网络刷新或写入用户数据。
//  - run 开始时冻结快照，保证后续 UI 筛选变化不会影响本次 Agent 审计结果。
//

import Foundation

/// Agent Workspace 在启动 run 前调用的上下文提供者。
protocol AgentRunContextProviding: Sendable {
    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext
}

/// 无依赖 fallback，主要给测试和 Preview 使用。
struct EmptyAgentRunContextProvider: AgentRunContextProviding {
    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext {
        AgentRunContext(
            sourceDescription: input.source,
            attachments: input.attachments,
            explicitRepos: input.explicitRepos,
            explicitRepoMode: input.explicitRepoMode,
            selectedModelID: input.selectedModelID,
            runtimeBackend: input.runtimeBackend,
            runtimeModelName: input.runtimeModelName,
            runtimeReasoningEffort: input.runtimeReasoningEffort,
            githubLinks: input.githubLinks,
            webSearchEnabled: input.webSearchEnabled
        )
    }
}

/// 从 Starcat 本地仓库库表冻结 Agent 上下文。
struct RepositoryAgentRunContextProvider: AgentRunContextProviding {

    private let repoRepository: any RepoRepositoryProtocol
    private let repositoryCatalog: any AgentRepositoryCatalogProviding
    private let candidateLimit: Int
    private let now: @Sendable () -> Date

    init(
        repoRepository: any RepoRepositoryProtocol,
        repositoryCatalog: any AgentRepositoryCatalogProviding,
        candidateLimit: Int = 100,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repoRepository = repoRepository
        self.repositoryCatalog = repositoryCatalog
        self.candidateLimit = candidateLimit
        self.now = now
    }

    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext {
        do {
            let repos = try await loadBusinessRepos(definition: definition, input: input)
            let knowledgeEligibleRepoIDs = await loadKnowledgeEligibleRepoIDs(from: repos)
            let sourceDescription = sourceDescription(
                definition: definition,
                input: input,
                repositoryCount: repos.count
            )
            return AgentRunContext(
                sourceDescription: sourceDescription,
                repos: repos,
                attachments: input.attachments,
                explicitRepos: input.explicitRepos,
                explicitRepoMode: input.explicitRepoMode,
                selectedModelID: input.selectedModelID,
                runtimeBackend: input.runtimeBackend,
                runtimeModelName: input.runtimeModelName,
                runtimeReasoningEffort: input.runtimeReasoningEffort,
                githubLinks: input.githubLinks,
                webSearchEnabled: input.webSearchEnabled,
                knowledgeEligibleRepoIDs: knowledgeEligibleRepoIDs
            )
        } catch {
            // 详细数据库错误只进入本地日志；模型和 UI 只收到稳定的通用失败原因。
            AppLog.general.warning("Agent context snapshot failed: \(error.localizedDescription, privacy: .public)")
            return AgentRunContext(
                sourceDescription: String.l10n("agent.context.source.failure"),
                attachments: input.attachments,
                failureReason: String.l10n("agent.loop.error.contextUnavailable"),
                explicitRepos: input.explicitRepos,
                explicitRepoMode: input.explicitRepoMode,
                selectedModelID: input.selectedModelID,
                runtimeBackend: input.runtimeBackend,
                runtimeModelName: input.runtimeModelName,
                runtimeReasoningEffort: input.runtimeReasoningEffort,
                githubLinks: input.githubLinks,
                webSearchEnabled: input.webSearchEnabled
            )
        }
    }

    private func loadBusinessRepos(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async throws -> [AgentRepoSnapshot] {
        let candidates = try await repositoryCatalog.candidates()
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        switch definition.workflow.repositoryContext {
        case .none:
            return []
        case .weeklyHotspots(let days):
            let cutoff = now().addingTimeInterval(-Double(max(1, days)) * 86_400)
            let cutoffISO = ISO8601DateFormatter.shared.string(from: cutoff)
            let recent = candidates
                .filter { candidate in
                    candidate.sources.contains(.weekly)
                        && (candidate.latestObservedAt ?? "") >= cutoffISO
                }
                .sorted { lhs, rhs in
                    let left = lhs.latestObservedAt ?? ""
                    let right = rhs.latestObservedAt ?? ""
                    return left == right ? lhs.starsCount > rhs.starsCount : left > right
                }
                .prefix(candidateLimit)
                .map(\.snapshot)
            guard definition.workflow.allowsManualRepositoryOverride, !input.explicitRepos.isEmpty else {
                return Array(recent)
            }
            let explicit = try loadExplicitRepos(input.explicitRepos, candidatesByID: candidatesByID)
            switch input.explicitRepoMode {
            case .only:
                return explicit
            case .prefer:
                var seen = Set(explicit.map(\.id))
                return Array((explicit + recent.filter { seen.insert($0.id).inserted }).prefix(candidateLimit))
            case .exclude:
                let excluded = Set(explicit.map(\.id))
                return recent.filter { !excluded.contains($0.id) }
            }
        case .singleRepository:
            let explicit = try loadExplicitRepos(input.explicitRepos, candidatesByID: candidatesByID)
            if explicit.count == 1 {
                return explicit
            }
            guard explicit.isEmpty,
                  input.githubLinks.count == 1,
                  let link = input.githubLinks.first,
                  let linkedRepo = candidates.first(where: {
                      $0.owner.caseInsensitiveCompare(link.owner) == .orderedSame
                          && $0.name.caseInsensitiveCompare(link.repository) == .orderedSame
                  })?.snapshot
            else {
                throw AgentRunContextProviderError.singleRepositoryRequired
            }
            return [linkedRepo]
        case .selectedRepositories:
            let explicit = try loadExplicitRepos(input.explicitRepos, candidatesByID: candidatesByID)
            guard explicit.count <= definition.workflow.maximumSelectedRepositories else {
                throw AgentRunContextProviderError.tooManyExplicitRepositories
            }
            guard definition.workflow.allowsEmptyRepositoryContext || !explicit.isEmpty else {
                throw AgentRunContextProviderError.explicitRepositoryUnavailable
            }
            return explicit
        }
    }

    private func sourceDescription(
        definition: AgentDefinition,
        input: AgentRunInput,
        repositoryCount: Int
    ) -> String {
        switch definition.workflow.repositoryContext {
        case .weeklyHotspots(let days) where input.explicitRepos.isEmpty:
            return String(
                format: String.l10n("agent.context.source.weeklyHotspotsFormat"),
                days,
                repositoryCount
            )
        case .singleRepository where repositoryCount == 1:
            return String.l10n("agent.context.source.singleRepository")
        case .selectedRepositories:
            return repositoryCount == 0
                ? String.l10n("agent.context.source.empty")
                : String(format: String.l10n("agent.context.source.repoCountFormat"), repositoryCount)
        default:
            return repositoryCount == 0
                ? String.l10n("agent.context.source.empty")
                : String(format: String.l10n("agent.context.source.repoCountFormat"), repositoryCount)
        }
    }

    private func loadExplicitRepos(
        _ references: [AIComposerRepoReference],
        candidatesByID: [Int64: AgentRepositoryCandidate]
    ) throws -> [AgentRepoSnapshot] {
        guard references.count <= candidateLimit else {
            throw AgentRunContextProviderError.tooManyExplicitRepositories
        }
        var repos: [AgentRepoSnapshot] = []
        for reference in references {
            guard let repo = candidatesByID[reference.id]?.snapshot else {
                throw AgentRunContextProviderError.explicitRepositoryUnavailable
            }
            repos.append(repo)
        }
        return repos
    }

    /// Knowledge 是业务上下文上的可选证据层。任何来源项目不在知识库时只会让
    /// `knowledge_search` 缩小到可用子集，不能让 Weekly / Repo Insight 整次失败。
    private func loadKnowledgeEligibleRepoIDs(from repos: [AgentRepoSnapshot]) async -> [Int64] {
        guard !repos.isEmpty else { return [] }
        do {
            let knowledgeIDs = Set(try await repoRepository.fetchKnowledgeRepoIDs())
            return repos.map(\.id).filter(knowledgeIDs.contains)
        } catch {
            AppLog.general.warning("Agent knowledge eligibility snapshot failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

private enum AgentRunContextProviderError: Error {
    case explicitRepositoryUnavailable
    case singleRepositoryRequired
    case tooManyExplicitRepositories
}
