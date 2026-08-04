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
            githubLinks: input.githubLinks,
            webSearchEnabled: input.webSearchEnabled
        )
    }
}

/// 从 Starcat 本地仓库库表冻结 Agent 上下文。
struct RepositoryAgentRunContextProvider: AgentRunContextProviding {

    private let repoRepository: any RepoRepositoryProtocol
    private let candidateLimit: Int
    private let now: @Sendable () -> Date

    init(
        repoRepository: any RepoRepositoryProtocol,
        candidateLimit: Int = 100,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.repoRepository = repoRepository
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
                repos: repos.map(Self.snapshot(from:)),
                attachments: input.attachments,
                explicitRepos: input.explicitRepos,
                explicitRepoMode: input.explicitRepoMode,
                selectedModelID: input.selectedModelID,
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
                githubLinks: input.githubLinks,
                webSearchEnabled: input.webSearchEnabled
            )
        }
    }

    private func loadBusinessRepos(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async throws -> [Repo] {
        switch definition.workflow.repositoryContext {
        case .none:
            return []
        case .recentStars(let days):
            let cutoff = now().addingTimeInterval(-Double(max(1, days)) * 86_400)
            let recent = try await repoRepository.fetchStarred(since: cutoff, limit: candidateLimit)
            guard definition.workflow.allowsManualRepositoryOverride, !input.explicitRepos.isEmpty else {
                return recent
            }
            let explicit = try await loadExplicitRepos(input.explicitRepos)
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
            let explicit = try await loadExplicitRepos(input.explicitRepos)
            if explicit.count == 1 {
                return explicit
            }
            guard explicit.isEmpty,
                  input.githubLinks.count == 1,
                  let link = input.githubLinks.first,
                  let linkedRepo = try await repoRepository.findByOwnerName(
                    owner: link.owner,
                    name: link.repository
                  ),
                  linkedRepo.isStarred
            else {
                throw AgentRunContextProviderError.singleRepositoryRequired
            }
            return [linkedRepo]
        }
    }

    private func sourceDescription(
        definition: AgentDefinition,
        input: AgentRunInput,
        repositoryCount: Int
    ) -> String {
        switch definition.workflow.repositoryContext {
        case .recentStars(let days) where input.explicitRepos.isEmpty:
            return String(
                format: String.l10n("agent.context.source.recentStarsFormat"),
                days,
                repositoryCount
            )
        case .singleRepository where repositoryCount == 1:
            return String.l10n("agent.context.source.singleRepository")
        default:
            return repositoryCount == 0
                ? String.l10n("agent.context.source.empty")
                : String(format: String.l10n("agent.context.source.repoCountFormat"), repositoryCount)
        }
    }

    private func loadExplicitRepos(_ references: [AIComposerRepoReference]) async throws -> [Repo] {
        guard references.count <= candidateLimit else {
            throw AgentRunContextProviderError.tooManyExplicitRepositories
        }
        var repos: [Repo] = []
        for reference in references {
            guard let repo = try await repoRepository.findById(reference.id), repo.isStarred else {
                throw AgentRunContextProviderError.explicitRepositoryUnavailable
            }
            repos.append(repo)
        }
        return repos
    }

    /// Knowledge 是业务上下文上的可选证据层。普通 Star 不在知识库时只会让
    /// `knowledge_search` 缩小到可用子集，不能让 Weekly / Repo Insight 整次失败。
    private func loadKnowledgeEligibleRepoIDs(from repos: [Repo]) async -> [Int64] {
        guard !repos.isEmpty else { return [] }
        do {
            let knowledgeIDs = Set(try await repoRepository.fetchKnowledgeRepoIDs())
            return repos.map(\.id).filter(knowledgeIDs.contains)
        } catch {
            AppLog.general.warning("Agent knowledge eligibility snapshot failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func snapshot(from repo: Repo) -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: repo.id,
            owner: repo.owner,
            name: repo.name,
            fullName: repo.fullName,
            description: repo.description,
            language: repo.language,
            starsCount: repo.starsCount,
            topics: repo.topicsArray,
            isPrivate: repo.isPrivate,
            isStarred: repo.isStarred,
            starredAt: repo.starredAt,
            htmlUrl: repo.htmlUrl
        )
    }
}

private enum AgentRunContextProviderError: Error {
    case explicitRepositoryUnavailable
    case singleRepositoryRequired
    case tooManyExplicitRepositories
}
