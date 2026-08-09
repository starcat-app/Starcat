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
    private let metadataCapability: any RepositoryMetadataCapabilityExecuting
    private let tagCapability: any RepositoryTagMutationCapabilityExecuting
    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let auditLog: StarcatMCPAuditLog

    init(
        repoRepository: any RepoRepositoryProtocol,
        metadataCapability: any RepositoryMetadataCapabilityExecuting,
        tagCapability: any RepositoryTagMutationCapabilityExecuting,
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        auditLog: StarcatMCPAuditLog = .shared
    ) {
        self.repoRepository = repoRepository
        self.metadataCapability = metadataCapability
        self.tagCapability = tagCapability
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.auditLog = auditLog
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
            let mutation = try await metadataCapability.upsertNote(
                repoID: repo.id,
                content: content,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .localWrite,
                action: "upsert_repo_note",
                repo: mutation.repository,
                note: mutation.note
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
            let mutation = try await metadataCapability.setStatus(
                repoID: repo.id,
                status: status,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .localWrite,
                action: "set_repo_status",
                repo: mutation.repository,
                note: mutation.note
            )
        }
    }

    func createTag(
        name: String,
        color: String?,
        icon: String?,
        dryRun: Bool
    ) async throws -> MCPWriteResult {
        return try await perform(
            tool: "starcat.create_tag",
            permission: .localWrite,
            dryRun: dryRun,
            repo: nil,
            affectedTags: [name]
        ) {
            let mutation = try await tagCapability.createTag(
                name: name,
                color: color,
                icon: icon,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .localWrite,
                action: "create_tag",
                tags: mutation.tags,
                warnings: mutation.warnings
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
            let mutation = try await tagCapability.addTags(
                repoID: repo.id,
                tagNames: tagNames,
                createMissing: createMissing,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .localWrite,
                action: "add_repo_tags",
                repo: mutation.repository,
                tags: mutation.tags,
                warnings: mutation.warnings
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
            let mutation = try await tagCapability.removeTags(
                repoID: repo.id,
                tagNames: tagNames,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .localWrite,
                action: "remove_repo_tags",
                repo: mutation.repository,
                tags: mutation.tags,
                warnings: mutation.warnings
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
            let mutation = try await tagCapability.replaceTags(
                repoID: repo.id,
                tagNames: tagNames,
                createMissing: createMissing,
                dryRun: dryRun
            )
            return MCPWriteResult(
                dryRun: dryRun,
                changed: mutation.changed,
                permission: .destructiveWrite,
                action: "set_repo_tags",
                repo: mutation.repository,
                tags: mutation.tags,
                warnings: mutation.warnings
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
            let outwardError = Self.mapCapabilityError(error)
            await auditLog.record(
                tool: tool,
                permission: permission,
                dryRun: dryRun,
                success: false,
                repo: repo,
                affectedTags: affectedTags,
                warnings: [],
                error: outwardError.localizedDescription
            )
            throw outwardError
        }
    }

    /// 共享 Capability 保持与传输层无关；MCP adapter 在唯一出口恢复已发布的错误分类。
    private static func mapCapabilityError(_ error: Error) -> Error {
        switch error {
        case RepositoryMetadataCapabilityError.repositoryNotLocal(let repoID),
             RepositoryTagMutationCapabilityError.repositoryNotLocal(let repoID):
            return StarcatMCPError.notFound("Repo not found: \(repoID)")
        case RepositoryTagMutationCapabilityError.tagNotFound(let name):
            return StarcatMCPError.notFound("Tag not found: \(name)")
        case RepositoryTagMutationCapabilityError.emptyTagName:
            return StarcatMCPError.invalidArguments("Tag name cannot be empty.")
        case RepositoryTagMutationCapabilityError.emptyTagNames:
            return StarcatMCPError.invalidArguments("Provide at least one tag name.")
        default:
            return error
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

}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
