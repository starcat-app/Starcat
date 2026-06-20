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
    private let settings: AppSettings

    init(
        repoRepository: any RepoRepositoryProtocol,
        readmeRepository: ReadmeRepository,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        semanticSearchService: SemanticSearchService,
        settings: AppSettings
    ) {
        self.repoRepository = repoRepository
        self.readmeRepository = readmeRepository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.repoNoteRepository = repoNoteRepository
        self.semanticSearchService = semanticSearchService
        self.settings = settings
    }

    func searchRepos(query: String?, limit: Int) async throws -> MCPRepoSearchResult {
        let sanitizedLimit = Self.sanitizeLimit(limit, defaultValue: 20, maxValue: 100)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let repos = trimmed.isEmpty
            ? try await repoRepository.fetchAllStarred()
            : try await repoRepository.searchFTS(query: trimmed)
        let clipped = Array(repos.prefix(sanitizedLimit)).map(MCPRepoDTO.init(repo:))
        return MCPRepoSearchResult(
            query: trimmed.isEmpty ? nil : trimmed,
            total: repos.count,
            limit: sanitizedLimit,
            repos: clipped
        )
    }

    func semanticSearch(query: String, limit: Int) async throws -> MCPSemanticSearchResult {
        let sanitizedLimit = Self.sanitizeLimit(limit, defaultValue: 20, maxValue: 80)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = try await repoRepository.fetchAllStarred()
        let ftsHits = try await repoRepository.searchFTS(query: trimmed)
        let hits = try await semanticSearchService.search(
            query: trimmed,
            candidates: candidates,
            ftsHitIDs: Set(ftsHits.map(\.id)),
            limit: sanitizedLimit
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

    func resources() async throws -> [MCPResourceDescriptor] {
        let recent = try await repoRepository.fetchRecentStarred(limit: 20)
        var out = [
            MCPResourceDescriptor(
                uri: "starcat://tags",
                name: "Starcat Tags",
                description: "All user-defined Starcat tags",
                mimeType: "application/json"
            )
        ]
        out.append(contentsOf: recent.map { repo in
            MCPResourceDescriptor(
                uri: "starcat://repos/\(repo.owner)/\(repo.name)",
                name: repo.fullName,
                description: repo.description,
                mimeType: "application/json"
            )
        })
        return out
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
        let parts = components.path.split(separator: "/").map(String.init)
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
            return "Missing or invalid MCP Bearer token."
        case .invalidArguments(let message), .notFound(let message):
            return message
        case .privateNotesDisabled:
            return "Private notes are not exposed to MCP. Enable this in Starcat Settings first."
        }
    }
}
