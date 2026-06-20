//
//  StarcatMCPWriteFacade.swift
//  Starcat
//
//  MCP 写入工具的业务门面。
//
//  设计约束：
//  - 写入工具只能调用现有 Repository / Service，不直接拼 SQL，避免绕过 Tag Pro 限额、
//    repo_notes 自动创建语义和未来 CloudKit 脏标记；
//  - 权限检查、dry-run、审计、状态通知和语义索引刷新集中在这里，ToolRegistry 只负责
//    解析 MCP 参数；
//  - P0 只写本地用户数据，不触发 GitHub 远端 star/unstar。
//

import Foundation

@MainActor
final class StarcatMCPWriteFacade {
    private let repoRepository: any RepoRepositoryProtocol
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let repoNoteRepository: any RepoNoteRepositoryProtocol
    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let auditLog: StarcatMCPAuditLog
    private let refreshSemanticIndex: @MainActor (Repo) -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        auditLog: StarcatMCPAuditLog = .shared,
        refreshSemanticIndex: @escaping @MainActor (Repo) -> Void
    ) {
        self.repoRepository = repoRepository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.repoNoteRepository = repoNoteRepository
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.auditLog = auditLog
        self.refreshSemanticIndex = refreshSemanticIndex
    }

    func upsertRepoNote(
        repoID: Int64?,
        owner: String?,
        name: String?,
        content: String?,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await perform(
            tool: "starcat.upsert_repo_note",
            permission: .localWrite,
            dryRun: dryRun,
            repo: repo,
            affectedTags: []
        ) {
            let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed?.isEmpty == true ? nil : content
            if !dryRun {
                try await repoNoteRepository.updateContent(repoId: repo.id, content: normalized)
                refreshSemanticIndex(repo)
            }
            let note = try await repoNoteRepository.find(repoId: repo.id)
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun,
                permission: .localWrite,
                action: "upsert_repo_note",
                repo: repo,
                note: note
            )
        }
    }

    func setRepoStatus(
        repoID: Int64?,
        owner: String?,
        name: String?,
        status: RepoStatus,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await perform(
            tool: "starcat.set_repo_status",
            permission: .localWrite,
            dryRun: dryRun,
            repo: repo,
            affectedTags: []
        ) {
            if !dryRun {
                try await repoNoteRepository.updateStatus(repoId: repo.id, status: status)
                postStatusDidChange(repoId: repo.id, status: status)
                refreshSemanticIndex(repo)
            }
            let note = try await repoNoteRepository.find(repoId: repo.id)
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun,
                permission: .localWrite,
                action: "set_repo_status",
                repo: repo,
                note: note
            )
        }
    }

    func createTag(
        name: String,
        color: String?,
        icon: String?,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let normalized = try Self.normalizeTagName(name)
        if let existing = try await tagRepository.findByName(normalized) {
            return try await perform(
                tool: "starcat.create_tag",
                permission: .localWrite,
                dryRun: dryRun,
                repo: nil,
                affectedTags: [existing.name]
            ) {
                MCPWriteResult(
                    dryRun: dryRun,
                    changed: false,
                    permission: .localWrite,
                    action: "create_tag",
                    tags: [existing],
                    warnings: ["Tag already exists."]
                )
            }
        }

        return try await perform(
            tool: "starcat.create_tag",
            permission: .localWrite,
            dryRun: dryRun,
            repo: nil,
            affectedTags: [normalized]
        ) {
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tag = Tag(
                id: UUID().uuidString,
                name: normalized,
                color: color?.nilIfBlank,
                icon: icon?.nilIfBlank,
                sortOrder: 0,
                isPreset: false,
                parentId: nil,
                createdAt: now,
                updatedAt: now
            )
            if !dryRun {
                try await tagRepository.create(tag)
            }
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun,
                permission: .localWrite,
                action: "create_tag",
                tags: [tag]
            )
        }
    }

    func addRepoTags(
        repoID: Int64?,
        owner: String?,
        name: String?,
        tagNames: [String],
        createMissing: Bool,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await perform(
            tool: "starcat.add_repo_tags",
            permission: .localWrite,
            dryRun: dryRun,
            repo: repo,
            affectedTags: tagNames
        ) {
            let tags = try await resolveTags(names: tagNames, createMissing: createMissing, dryRun: dryRun)
            if !dryRun {
                for tag in tags {
                    try await repoTagRepository.addTag(repoId: repo.id, tagId: tag.id)
                }
                refreshSemanticIndex(repo)
            }
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun && !tags.isEmpty,
                permission: .localWrite,
                action: "add_repo_tags",
                repo: repo,
                tags: tags
            )
        }
    }

    func removeRepoTags(
        repoID: Int64?,
        owner: String?,
        name: String?,
        tagNames: [String],
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await perform(
            tool: "starcat.remove_repo_tags",
            permission: .localWrite,
            dryRun: dryRun,
            repo: repo,
            affectedTags: tagNames
        ) {
            let tags = try await existingTags(names: tagNames)
            if !dryRun {
                for tag in tags {
                    try await repoTagRepository.removeTag(repoId: repo.id, tagId: tag.id)
                }
                refreshSemanticIndex(repo)
            }
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun && !tags.isEmpty,
                permission: .localWrite,
                action: "remove_repo_tags",
                repo: repo,
                tags: tags
            )
        }
    }

    func setRepoTags(
        repoID: Int64?,
        owner: String?,
        name: String?,
        tagNames: [String],
        createMissing: Bool,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await perform(
            tool: "starcat.set_repo_tags",
            permission: .destructiveWrite,
            dryRun: dryRun,
            repo: repo,
            affectedTags: tagNames
        ) {
            let tags = try await resolveTags(names: tagNames, createMissing: createMissing, dryRun: dryRun)
            if !dryRun {
                try await repoTagRepository.setTags(repoId: repo.id, tagIds: tags.map(\.id))
                refreshSemanticIndex(repo)
            }
            return MCPWriteResult(
                dryRun: dryRun,
                changed: !dryRun,
                permission: .destructiveWrite,
                action: "set_repo_tags",
                repo: repo,
                tags: tags,
                warnings: ["This replaces all existing tags on the repository."]
            )
        }
    }

    private func perform(
        tool: String,
        permission: StarcatMCPWritePermission,
        dryRun: Bool,
        repo: Repo?,
        affectedTags: [String],
        operation: () async throws -> MCPWriteResult
    ) async throws -> MCPWriteResult {
        do {
            try validate(permission)
            let result = try await operation()
            await auditLog.record(
                tool: tool,
                permission: permission,
                dryRun: dryRun,
                success: true,
                repo: repo,
                affectedTags: affectedTags,
                warnings: result.warnings,
                error: nil
            )
            return result
        } catch {
            await auditLog.record(
                tool: tool,
                permission: permission,
                dryRun: dryRun,
                success: false,
                repo: repo,
                affectedTags: affectedTags,
                warnings: [],
                error: error.localizedDescription
            )
            throw error
        }
    }

    private func validate(_ permission: StarcatMCPWritePermission) throws {
        try entitlementGate.requirePro(.mcpService)
        switch permission {
        case .localWrite:
            guard settings.mcpAllowLocalWrites else {
                throw StarcatMCPError.invalidArguments("MCP local writes are disabled in Starcat Settings.")
            }
        case .batchWrite:
            guard settings.mcpAllowLocalWrites, settings.mcpAllowBatchWrites else {
                throw StarcatMCPError.invalidArguments("MCP batch writes are disabled in Starcat Settings.")
            }
        case .destructiveWrite:
            guard settings.mcpAllowLocalWrites, settings.mcpAllowDestructiveWrites else {
                throw StarcatMCPError.invalidArguments("MCP replace/delete writes are disabled in Starcat Settings.")
            }
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

    private func resolveTags(names: [String], createMissing: Bool, dryRun: Bool) async throws -> [Tag] {
        let normalized = try Self.normalizeTagNames(names)
        var out: [Tag] = []
        for name in normalized {
            if let tag = try await tagRepository.findByName(name) {
                out.append(tag)
                continue
            }
            guard createMissing else {
                throw StarcatMCPError.notFound("Tag not found: \(name)")
            }
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tag = Tag(
                id: UUID().uuidString,
                name: name,
                color: nil,
                icon: nil,
                sortOrder: 0,
                isPreset: false,
                parentId: nil,
                createdAt: now,
                updatedAt: now
            )
            if !dryRun {
                try await tagRepository.create(tag)
            }
            out.append(tag)
        }
        return out
    }

    private func existingTags(names: [String]) async throws -> [Tag] {
        let normalized = try Self.normalizeTagNames(names)
        var out: [Tag] = []
        for name in normalized {
            if let tag = try await tagRepository.findByName(name) {
                out.append(tag)
            }
        }
        return out
    }

    private func postStatusDidChange(repoId: Int64, status: RepoStatus) {
        NotificationCenter.default.post(
            name: .repoStatusDidChange,
            object: nil,
            userInfo: [
                "repoId": repoId,
                "status": status.rawValue
            ]
        )
    }

    private static func normalizeTagNames(_ names: [String]) throws -> [String] {
        let deduped = Array(Set(try names.map(normalizeTagName))).sorted()
        guard !deduped.isEmpty else {
            throw StarcatMCPError.invalidArguments("Provide at least one tag name.")
        }
        return deduped
    }

    private static func normalizeTagName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StarcatMCPError.invalidArguments("Tag name cannot be empty.")
        }
        return trimmed
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
