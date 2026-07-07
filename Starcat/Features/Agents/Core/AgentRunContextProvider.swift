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
        prompt: String
    ) async -> AgentRunContext
}

/// 无依赖 fallback，主要给测试和 Preview 使用。
struct EmptyAgentRunContextProvider: AgentRunContextProviding {
    func makeContext(
        definition: AgentDefinition,
        prompt: String
    ) async -> AgentRunContext {
        AgentRunContext(sourceDescription: "Agent Workspace")
    }
}

/// 从 Starcat 本地仓库库表冻结 Agent 上下文。
struct RepositoryAgentRunContextProvider: AgentRunContextProviding {

    private let repository: any RepoRepositoryProtocol
    private let limit: Int

    init(
        repository: any RepoRepositoryProtocol,
        limit: Int = 30
    ) {
        self.repository = repository
        self.limit = limit
    }

    func makeContext(
        definition: AgentDefinition,
        prompt: String
    ) async -> AgentRunContext {
        let repos = await loadCandidateRepos()
        let sourceDescription: String
        if repos.isEmpty {
            sourceDescription = String.l10n("agent.context.source.empty")
        } else {
            sourceDescription = String(format: String.l10n("agent.context.source.repoCountFormat"), repos.count)
        }
        return AgentRunContext(
            sourceDescription: sourceDescription,
            repos: repos.map(Self.snapshot(from:))
        )
    }

    private func loadCandidateRepos() async -> [Repo] {
        do {
            let starred = try await repository.fetchRecentStarred(limit: limit)
            if starred.count >= limit {
                return Array(starred.prefix(limit))
            }

            let knowledge = try await repository.fetchKnowledgeRepos()
            var seenIDs = Set(starred.map(\.id))
            let merged = starred + knowledge.filter { seenIDs.insert($0.id).inserted }
            return Array(merged.prefix(limit))
        } catch {
            AppLog.general.warning("Agent context snapshot failed: \(error.localizedDescription, privacy: .public)")
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
            isStarred: repo.isStarred,
            starredAt: repo.starredAt,
            htmlUrl: repo.htmlUrl
        )
    }
}
