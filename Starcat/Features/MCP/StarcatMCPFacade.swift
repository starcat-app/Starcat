//
//  StarcatMCPFacade.swift
//  Starcat
//
//  MCP 工具层访问 Starcat 数据的窄门面。
//
//  设计约束：
//  - MCP handler 不直接碰多个 Repository，统一走本 facade，方便以后加 audit / 权限审批；
//  - 当前 P0 只开放只读能力，写入类工具（改笔记 / 打标签）后续必须先补用户确认机制；
//  - 私有笔记默认不暴露，必须用户在设置中显式开启。
//

import Foundation

@MainActor
final class StarcatMCPFacade {
    private let repoRepository: any RepoRepositoryProtocol
    private let readmeRepository: ReadmeRepository
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let repoNoteRepository: any RepoNoteRepositoryProtocol
    private let semanticSearchService: SemanticSearchService
    private let repoAIInsightService: RepoAIInsightService
    private let entitlementGate: EntitlementGate
    private let settings: AppSettings

    init(
        repoRepository: any RepoRepositoryProtocol,
        readmeRepository: ReadmeRepository,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        semanticSearchService: SemanticSearchService,
        repoAIInsightService: RepoAIInsightService,
        entitlementGate: EntitlementGate,
        settings: AppSettings
    ) {
        self.repoRepository = repoRepository
        self.readmeRepository = readmeRepository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.repoNoteRepository = repoNoteRepository
        self.semanticSearchService = semanticSearchService
        self.repoAIInsightService = repoAIInsightService
        self.entitlementGate = entitlementGate
        self.settings = settings
    }

    /// 返回 Agent 可据此选择安全工作流的能力快照。
    ///
    /// MCP Service 本身是 Pro-only，但仍显式返回摘要门控状态，避免未来服务权限拆分后
    /// Skill 依赖“能连接就一定能生成摘要”这一隐式假设。
    func getCapabilities() -> MCPCapabilitiesDTO {
        MCPCapabilitiesDTO(
            server_version: "0.2.0",
            loopback_only: !settings.mcpAllowRemoteConnections,
            private_notes_read: settings.mcpExposePrivateNotes,
            local_writes: settings.mcpAllowLocalWrites,
            batch_writes: settings.mcpAllowLocalWrites && settings.mcpAllowBatchWrites,
            destructive_writes: settings.mcpAllowLocalWrites && settings.mcpAllowDestructiveWrites,
            ai_summary_generation: entitlementGate.isProUser
        )
    }

    func searchRepos(query: String?, limit: Int, scope: SemanticIndexScope = .starred) async throws -> MCPRepoSearchResult {
        let sanitizedLimit = Self.sanitizeLimit(limit, defaultValue: 20, maxValue: 100)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let repos = trimmed.isEmpty
            ? try await fetchRepos(scope: scope)
            : try await searchFTS(query: trimmed, scope: scope)
        let clipped = Array(repos.prefix(sanitizedLimit)).map(MCPRepoDTO.init(repo:))
        return MCPRepoSearchResult(
            query: trimmed.isEmpty ? nil : trimmed,
            total: repos.count,
            limit: sanitizedLimit,
            repos: clipped
        )
    }

    func semanticSearch(query: String, limit: Int, scope: SemanticIndexScope = .starred) async throws -> MCPSemanticSearchResult {
        let sanitizedLimit = Self.sanitizeLimit(limit, defaultValue: 20, maxValue: 80)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = try await fetchRepos(scope: scope)
        let ftsHits = try await searchFTS(query: trimmed, scope: scope)
        let hits = try await semanticSearchService.search(
            query: trimmed,
            candidates: candidates,
            ftsHitIDs: Set(ftsHits.map(\.id)),
            limit: sanitizedLimit,
            usageContext: AIUsageContext(feature: .mcp, phase: "semantic_search")
        )
        return MCPSemanticSearchResult(
            query: trimmed,
            total: hits.count,
            limit: sanitizedLimit,
            hits: hits.map(MCPSemanticSearchResult.Hit.init(hit:))
        )
    }

    func getRepo(repoID: Int64?, owner: String?, name: String?) async throws -> MCPRepoDTO {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return MCPRepoDTO(repo: repo)
    }

    func getReadme(repoID: Int64?, owner: String?, name: String?) async throws -> MCPReadmeResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        let readme = try await readmeRepository.find(repoId: repo.id)
        let markdown = try await readmeRepository.findContent(repoId: repo.id)
        return MCPReadmeResult(
            repo: MCPRepoDTO(repo: repo),
            rendered_html: readme?.renderedHtml,
            markdown: markdown,
            cached_at: readme?.cachedAt,
            etag: readme?.etag,
            last_modified: readme?.lastModified
        )
    }

    func listTags() async throws -> [MCPTagDTO] {
        try await tagRepository.fetchAll().map(MCPTagDTO.init(tag:))
    }

    func getRepoNote(repoID: Int64?, owner: String?, name: String?) async throws -> MCPRepoNoteDTO? {
        guard settings.mcpExposePrivateNotes else {
            throw StarcatMCPError.privateNotesDisabled
        }
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await repoNoteRepository.find(repoId: repo.id).map(MCPRepoNoteDTO.init(note:))
    }

    /// 一次聚合 Agent 整理仓库最常用的本地上下文，避免多轮工具调用和中途状态漂移。
    func getRepoContext(repoID: Int64?, owner: String?, name: String?) async throws -> MCPRepoContextDTO {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        let tags = try await repoTagRepository.fetchTags(forRepo: repo.id).map(MCPTagDTO.init(tag:))
        let note = settings.mcpExposePrivateNotes
            ? try await repoNoteRepository.find(repoId: repo.id).map(MCPRepoNoteDTO.init(note:))
            : nil
        let summary = try await cachedSummary(for: repo)
        return MCPRepoContextDTO(
            repo: MCPRepoDTO(repo: repo),
            tags: tags,
            private_notes_exposed: settings.mcpExposePrivateNotes,
            note: note,
            summary: summary
        )
    }

    /// 读取最近一次可用摘要，不做 source hash 重算，确保 Agent 的只读调用不会触发
    /// RepoContext 下载、外部搜索或任何 AI 网络请求。
    func getRepoSummary(repoID: Int64?, owner: String?, name: String?) async throws -> MCPRepoSummaryDTO? {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await cachedSummary(for: repo)
    }

    /// 复用 Starcat 单仓 AI 摘要用例；所有 Provider、Pro、用量统计、缓存与索引刷新
    /// 仍由现有 service 负责，MCP 不复制业务逻辑。
    func generateRepoSummary(
        repoID: Int64?,
        owner: String?,
        name: String?,
        allowExternalContext: Bool
    ) async throws -> MCPRepoSummaryGenerationResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        let generation = try await repoAIInsightService.generateInsight(
            for: repo,
            includeSummary: true,
            includeTags: false,
            allowExternalContext: allowExternalContext
        )
        return MCPRepoSummaryGenerationResult(
            repo: MCPRepoDTO(repo: repo),
            summary: MCPRepoSummaryDTO(repoID: repo.id, insight: generation.insight),
            // 现有摘要仓储只持久化 starred repo；知识库中的未 Star 仓库仍返回本次结果，
            // 但明确告诉 Agent 没有写入缓存，避免把临时结果误当成持久数据。
            persisted: repo.isStarred
        )
    }

    func resources() async throws -> [MCPResourceDescriptor] {
        let starred = try await repoRepository.fetchRecentStarred(limit: 20)
        let knowledge = Array((try await repoRepository.fetchKnowledgeRepos()).prefix(20))
        let all = Array(SemanticIndexScope.selectCandidates(scope: .all, starred: starred, knowledge: knowledge).prefix(20))
        var out = [
            MCPResourceDescriptor(
                uri: "starcat://tags",
                name: "Starcat Tags",
                description: "All user-defined Starcat tags",
                mimeType: "application/json"
            )
        ]
        out.append(contentsOf: resourceDescriptors(scope: .starred, repos: starred))
        out.append(contentsOf: resourceDescriptors(scope: .knowledge, repos: knowledge))
        out.append(contentsOf: resourceDescriptors(scope: .all, repos: all))
        return out
    }

    private func resourceDescriptors(scope: SemanticIndexScope, repos: [Repo]) -> [MCPResourceDescriptor] {
        repos.map { repo in
            MCPResourceDescriptor(
                uri: "starcat://repos/\(scope.rawValue)/\(repo.owner)/\(repo.name)",
                name: repo.fullName,
                description: repo.description ?? "\(scope.rawValue) scope",
                mimeType: "application/json"
            )
        }
    }

    func readResource(uri: String) async throws -> (mimeType: String, text: String) {
        guard let components = URLComponents(string: uri), components.scheme == "starcat" else {
            throw StarcatMCPError.invalidArguments("Unknown resource URI: \(uri)")
        }

        if components.host == "tags" {
            let value = try await listTags()
            return ("application/json", try Self.prettyJSON(value))
        }

        guard components.host == "repos" else {
            throw StarcatMCPError.invalidArguments("Unknown resource URI: \(uri)")
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if let first = parts.first, SemanticIndexScope(rawValue: first) != nil {
            parts.removeFirst()
        }
        guard parts.count >= 2 else {
            throw StarcatMCPError.invalidArguments("Repo resource must be starcat://repos/{owner}/{repo}")
        }
        let owner = parts[0]
        let name = parts[1]
        if parts.count >= 3, parts[2] == "readme" {
            let value = try await getReadme(repoID: nil, owner: owner, name: name)
            return ("application/json", try Self.prettyJSON(value))
        }
        let value = try await getRepo(repoID: nil, owner: owner, name: name)
        return ("application/json", try Self.prettyJSON(value))
    }

    private func fetchRepos(scope: SemanticIndexScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            let starred = try await repoRepository.fetchAllStarred()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: [])
        case .knowledge:
            let knowledge = try await repoRepository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: [], knowledge: knowledge)
        case .all:
            let starred = try await repoRepository.fetchAllStarred()
            let knowledge = try await repoRepository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: knowledge)
        }
    }

    private func searchFTS(query: String, scope: SemanticIndexScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            return try await repoRepository.searchFTS(query: query)
        case .knowledge:
            return try await repoRepository.searchKnowledgeFTS(query: query)
        case .all:
            let starred = try await repoRepository.searchFTS(query: query)
            let knowledge = try await repoRepository.searchKnowledgeFTS(query: query)
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: knowledge)
        }
    }

    private func resolveRepo(repoID: Int64?, owner: String?, name: String?) async throws -> Repo {
        if let repoID {
            guard let repo = try await repoRepository.findById(repoID) else {
                throw StarcatMCPError.notFound("Repo not found: \(repoID)")
            }
            return repo
        }
        guard let owner, let name, !owner.isEmpty, !name.isEmpty else {
            throw StarcatMCPError.invalidArguments("Provide repo_id or owner + name")
        }
        guard let repo = try await repoRepository.findByOwnerName(owner: owner, name: name) else {
            throw StarcatMCPError.notFound("Repo not found: \(owner)/\(name)")
        }
        return repo
    }

    private func cachedSummary(for repo: Repo) async throws -> MCPRepoSummaryDTO? {
        try await repoAIInsightService.cachedInsightFast(for: repo).map {
            MCPRepoSummaryDTO(repoID: repo.id, insight: $0)
        }
    }

    private static func sanitizeLimit(_ value: Int, defaultValue: Int, maxValue: Int) -> Int {
        guard value > 0 else { return defaultValue }
        return min(value, maxValue)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

struct MCPResourceDescriptor: Sendable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String
}

enum StarcatMCPError: Error, LocalizedError, Equatable {
    case disabled
    case requiresPro
    case unauthorized
    case invalidArguments(String)
    case notFound(String)
    case privateNotesDisabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Starcat MCP Service is disabled."
        case .requiresPro:
            return "Starcat MCP Service requires Starcat Pro."
        case .unauthorized:
            return "Missing or invalid Starcat Local API Key."
        case .invalidArguments(let message), .notFound(let message):
            return message
        case .privateNotesDisabled:
            return "Private notes are not exposed to MCP. Enable this in Starcat Settings first."
        }
    }
}
