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

    private let candidateRepository: any RAGRepoCandidateRepositoryProtocol
    private let candidateLimit: Int

    init(
        candidateRepository: any RAGRepoCandidateRepositoryProtocol,
        candidateLimit: Int = 30
    ) {
        self.candidateRepository = candidateRepository
        self.candidateLimit = candidateLimit
    }

    func makeContext(
        definition: AgentDefinition,
        input: AgentRunInput
    ) async -> AgentRunContext {
        do {
            // 复用 RAG 的知识库候选层执行 only / prefer / exclude，禁止在 Agent 里再造一套
            // 范围 SQL。候选最多冻结 candidateLimit 条，README/笔记正文仍按需由工具读取。
            let repos = try await loadScopedRepos(input: input)
            let sourceDescription: String
            if repos.isEmpty {
                sourceDescription = String.l10n("agent.context.source.empty")
            } else {
                sourceDescription = String(format: String.l10n("agent.context.source.repoCountFormat"), repos.count)
            }
            return AgentRunContext(
                sourceDescription: sourceDescription,
                repos: repos.map(Self.snapshot(from:)),
                attachments: input.attachments,
                explicitRepos: input.explicitRepos,
                explicitRepoMode: input.explicitRepoMode,
                selectedModelID: input.selectedModelID,
                githubLinks: input.githubLinks,
                webSearchEnabled: input.webSearchEnabled
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

    private func loadScopedRepos(input: AgentRunInput) async throws -> [Repo] {
        let explicitIDs = input.explicitRepos.map(\.id)
        let explicitRepos = try await candidateRepository.fetchMentionRepos(ids: explicitIDs)
        guard explicitRepos.count == explicitIDs.count else {
            throw AgentRunContextProviderError.explicitRepositoryUnavailable
        }
        if input.explicitRepoMode == .only {
            return explicitRepos
        }

        let plan = RAGQueryPlan(
            mode: .semanticOnly,
            semanticQuery: input.goal,
            candidateLimit: candidateLimit
        )
        let candidates = try await candidateRepository.fetchCandidates(
            plan: plan,
            explicitRepoIDs: explicitIDs,
            explicitMode: input.explicitRepoMode.ragMode
        ).map(\.repo)

        guard input.explicitRepoMode == .prefer else { return candidates }
        var seen = Set(explicitRepos.map(\.id))
        // prefer 不能只依赖 SQL LIMIT 恰好包含显式仓库；显式项必须稳定置顶，再补全库候选。
        return Array((explicitRepos + candidates.filter { seen.insert($0.id).inserted }).prefix(candidateLimit))
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
}

private extension AIComposerExplicitRepoMode {
    var ragMode: RAGExplicitRepoMode {
        switch self {
        case .only: return .only
        case .prefer: return .prefer
        case .exclude: return .exclude
        }
    }
}
