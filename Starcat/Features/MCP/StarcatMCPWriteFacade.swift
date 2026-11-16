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
//  - GitHub Star 写入必须复用 `StarActionService`，不能绕过本地缓存、Undo 历史和活动账本。
//

import Foundation

/// MCP 只依赖 Star 写入的最小边界，生产环境由 `StarActionService` 实现，测试无需访问网络。
@MainActor
protocol MCPStarMutationServicing: AnyObject {
    func star(owner: String, repo: String, displayedStarsCount: Int?) async throws -> Repo
    func unstar(repo: Repo) async throws
}

extension StarActionService: MCPStarMutationServicing {}

/// 批量请求完成全量 preflight 后的不可变执行计划。
private struct PreparedMCPBatchOrganizeItem {
    let index: Int
    let input: MCPBatchOrganizeItemInput
    let repo: Repo
    let tagNames: [String]
    let warnings: [String]
}

@MainActor
final class StarcatMCPWriteFacade {
    private let repoRepository: any RepoRepositoryProtocol
    private let metadataCapability: any RepositoryMetadataCapabilityExecuting
    private let tagCapability: any RepositoryTagMutationCapabilityExecuting
    private let starMutationService: any MCPStarMutationServicing
    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let auditLog: StarcatMCPAuditLog

    init(
        repoRepository: any RepoRepositoryProtocol,
        metadataCapability: any RepositoryMetadataCapabilityExecuting,
        tagCapability: any RepositoryTagMutationCapabilityExecuting,
        starMutationService: any MCPStarMutationServicing,
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        auditLog: StarcatMCPAuditLog = .shared
    ) {
        self.repoRepository = repoRepository
        self.metadataCapability = metadataCapability
        self.tagCapability = tagCapability
        self.starMutationService = starMutationService
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.auditLog = auditLog
    }

    /// Star 可以直接接收 GitHub 搜索结果中的 owner/name；仓库尚未入库时由
    /// `StarActionService` 在远端成功后拉取完整 metadata 并写入本地。
    func starRepo(
        repoID: Int64?,
        owner: String?,
        name: String?,
        dryRun: Bool
    ) async throws -> MCPStarWriteResult {
        let target = try await resolveStarTarget(repoID: repoID, owner: owner, name: name)
        return try await performGitHubStarWrite(
            tool: "starcat.star_repo",
            dryRun: dryRun,
            repoID: target.existing?.id,
            targetFullName: target.fullName
        ) {
            guard target.existing?.isStarred != true else {
                return MCPStarWriteResult(
                    dryRun: dryRun,
                    changed: false,
                    action: "star_repo",
                    targetFullName: target.fullName,
                    repo: target.existing
                )
            }
            guard !dryRun else {
                return MCPStarWriteResult(
                    dryRun: true,
                    changed: true,
                    action: "star_repo",
                    targetFullName: target.fullName,
                    repo: target.existing
                )
            }
            let starred = try await starMutationService.star(
                owner: target.owner,
                repo: target.name,
                displayedStarsCount: target.existing?.starsCount
            )
            return MCPStarWriteResult(
                dryRun: false,
                changed: true,
                action: "star_repo",
                targetFullName: target.fullName,
                repo: starred
            )
        }
    }

    /// Unstar 只接受 Starcat 已知仓库，确保远端成功后能沿用现有保留标签、笔记和摘要的语义。
    func unstarRepo(
        repoID: Int64?,
        owner: String?,
        name: String?,
        dryRun: Bool
    ) async throws -> MCPStarWriteResult {
        let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
        return try await performGitHubStarWrite(
            tool: "starcat.unstar_repo",
            dryRun: dryRun,
            repoID: repo.id,
            targetFullName: repo.fullName
        ) {
            guard repo.isStarred else {
                return MCPStarWriteResult(
                    dryRun: dryRun,
                    changed: false,
                    action: "unstar_repo",
                    targetFullName: repo.fullName,
                    repo: repo
                )
            }
            guard !dryRun else {
                return MCPStarWriteResult(
                    dryRun: true,
                    changed: true,
                    action: "unstar_repo",
                    targetFullName: repo.fullName,
                    repo: repo
                )
            }
            try await starMutationService.unstar(repo: repo)
            let updated = try await repoRepository.findById(repo.id) ?? repo
            return MCPStarWriteResult(
                dryRun: false,
                changed: true,
                action: "unstar_repo",
                targetFullName: repo.fullName,
                repo: updated
            )
        }
    }

    /// 在一次 MCP 往返中为多个仓库添加标签和/或更新笔记。
    ///
    /// 所有项目先以 dry-run 走现有 Capability，任一确定性校验失败时整批不写入；正式执行
    /// 仍按仓库顺序处理，运行期错误逐项返回。不同 Capability 无法共享数据库事务，因此
    /// 失败项用 `partial_write_possible` 明确暴露重试边界。
    func batchOrganizeRepos(
        items: [MCPBatchOrganizeItemInput],
        createMissing: Bool,
        dryRun: Bool
    ) async throws -> MCPBatchOrganizeResult {
        let affectedTags = items.flatMap(\.tagNames)
        do {
            try validate(.write)
            guard !items.isEmpty else {
                throw StarcatMCPError.invalidArguments("items must contain at least one repository")
            }
            guard items.count <= 100 else {
                throw StarcatMCPError.invalidArguments("items must contain no more than 100 repositories")
            }

            var preparedItems: [PreparedMCPBatchOrganizeItem] = []
            preparedItems.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                guard !item.tagNames.isEmpty || item.note != nil else {
                    throw StarcatMCPError.invalidArguments(
                        "items[\(index)] must provide non-empty tags or a note"
                    )
                }
                let repo = try await resolveRepo(
                    repoID: item.repoID,
                    owner: item.owner,
                    name: item.name
                )

                var resolvedTagNames: [String] = []
                var warnings: [String] = []
                if !item.tagNames.isEmpty {
                    let preview = try await tagCapability.addTags(
                        repoID: repo.id,
                        tagNames: item.tagNames,
                        createMissing: createMissing,
                        dryRun: true
                    )
                    resolvedTagNames = preview.tags.map(\.name)
                    warnings.append(contentsOf: preview.warnings)
                }
                if let note = item.note {
                    _ = try await metadataCapability.upsertNote(
                        repoID: repo.id,
                        content: note,
                        dryRun: true
                    )
                }
                preparedItems.append(PreparedMCPBatchOrganizeItem(
                    index: index,
                    input: item,
                    repo: repo,
                    tagNames: resolvedTagNames,
                    warnings: warnings
                ))
            }

            if dryRun {
                let results = preparedItems.map { prepared in
                    MCPBatchOrganizeItemResult(
                        index: prepared.index,
                        ok: true,
                        changed: false,
                        partial_write_possible: false,
                        repo: MCPRepoDTO(repo: prepared.repo),
                        tag_names: prepared.tagNames,
                        note_requested: prepared.input.note != nil,
                        warnings: prepared.warnings,
                        error: nil
                    )
                }
                for (prepared, result) in zip(preparedItems, results) {
                    await auditLog.record(
                        tool: "starcat.batch_organize_repos",
                        permission: .write,
                        dryRun: true,
                        success: true,
                        repo: prepared.repo,
                        batchIndex: prepared.index,
                        affectedTags: prepared.input.tagNames,
                        warnings: result.warnings,
                        error: nil
                    )
                }
                return MCPBatchOrganizeResult(dryRun: true, results: results)
            }

            var results: [MCPBatchOrganizeItemResult] = []
            results.reserveCapacity(preparedItems.count)
            for prepared in preparedItems {
                var changed = false
                var operationStarted = false
                var resolvedTagNames = prepared.tagNames
                var warnings: [String] = []
                do {
                    if !prepared.input.tagNames.isEmpty {
                        operationStarted = true
                        let mutation = try await tagCapability.addTags(
                            repoID: prepared.repo.id,
                            tagNames: prepared.input.tagNames,
                            createMissing: createMissing,
                            dryRun: false
                        )
                        changed = changed || mutation.changed
                        resolvedTagNames = mutation.tags.map(\.name)
                        warnings.append(contentsOf: mutation.warnings)
                    }
                    if let note = prepared.input.note {
                        operationStarted = true
                        let mutation = try await metadataCapability.upsertNote(
                            repoID: prepared.repo.id,
                            content: note,
                            dryRun: false
                        )
                        changed = changed || mutation.changed
                    }

                    let result = MCPBatchOrganizeItemResult(
                        index: prepared.index,
                        ok: true,
                        changed: changed,
                        partial_write_possible: false,
                        repo: MCPRepoDTO(repo: prepared.repo),
                        tag_names: resolvedTagNames,
                        note_requested: prepared.input.note != nil,
                        warnings: warnings,
                        error: nil
                    )
                    results.append(result)
                    await auditLog.record(
                        tool: "starcat.batch_organize_repos",
                        permission: .write,
                        dryRun: false,
                        success: true,
                        repo: prepared.repo,
                        batchIndex: prepared.index,
                        affectedTags: prepared.input.tagNames,
                        warnings: warnings,
                        error: nil
                    )
                } catch {
                    let outwardError = Self.mapCapabilityError(error)
                    let result = MCPBatchOrganizeItemResult(
                        index: prepared.index,
                        ok: false,
                        changed: changed,
                        partial_write_possible: operationStarted,
                        repo: MCPRepoDTO(repo: prepared.repo),
                        tag_names: resolvedTagNames,
                        note_requested: prepared.input.note != nil,
                        warnings: warnings,
                        error: outwardError.localizedDescription
                    )
                    results.append(result)
                    await auditLog.record(
                        tool: "starcat.batch_organize_repos",
                        permission: .write,
                        dryRun: false,
                        success: false,
                        repo: prepared.repo,
                        batchIndex: prepared.index,
                        affectedTags: prepared.input.tagNames,
                        warnings: warnings,
                        error: outwardError.localizedDescription
                    )
                }
            }
            return MCPBatchOrganizeResult(dryRun: false, results: results)
        } catch {
            let outwardError = Self.mapCapabilityError(error)
            await auditLog.record(
                tool: "starcat.batch_organize_repos",
                permission: .write,
                dryRun: dryRun,
                success: false,
                repo: nil,
                affectedTags: affectedTags,
                warnings: [],
                error: outwardError.localizedDescription
            )
            throw outwardError
        }
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
            permission: .write,
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
                permission: .write,
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
            permission: .write,
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
                permission: .write,
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
            permission: .write,
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
                permission: .write,
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
            permission: .write,
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
                permission: .write,
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
            permission: .write,
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
                permission: .write,
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
            permission: .write,
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
                permission: .write,
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
        case StarActionError.notAuthenticated:
            return StarcatMCPError.invalidArguments(
                "Sign in to GitHub in Starcat before changing repository Stars."
            )
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
        try StarcatMCPAccess.requireWrite(settings)
    }

    private func resolveRepo(repoID: Int64?, owner: String?, name: String?) async throws -> Repo {
        let selector = RepositoryCapabilitySelector(repoID: repoID, owner: owner, name: name)
        let executor = RepositoryReadCapabilityExecutor(
            source: DatabaseRepositoryReadCapabilitySource(repository: repoRepository, scope: .all)
        )
        do {
            return try await executor.get(selector)
        } catch RepositoryReadCapabilityError.invalidSelector {
            throw StarcatMCPError.invalidArguments("Provide repo_id or owner + name")
        } catch RepositoryReadCapabilityError.notFound {
            throw StarcatMCPError.notFound("Repo not found: \(selector.displayValue)")
        }
    }

    /// `star_repo` 是唯一允许目标尚未存在于本地数据库的写入工具；repo_id 路径仍必须
    /// 命中本地仓库，owner/name 路径则可直接承接 `global_search_repos` 的 GitHub 结果。
    private func resolveStarTarget(
        repoID: Int64?,
        owner: String?,
        name: String?
    ) async throws -> (owner: String, name: String, fullName: String, existing: Repo?) {
        if repoID != nil {
            let repo = try await resolveRepo(repoID: repoID, owner: owner, name: name)
            return (repo.owner, repo.name, repo.fullName, repo)
        }

        let resolvedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedOwner.isEmpty, !resolvedName.isEmpty else {
            throw StarcatMCPError.invalidArguments("Provide repo_id or owner + name")
        }
        let existing = try await repoRepository.findByOwnerName(owner: resolvedOwner, name: resolvedName)
        return (resolvedOwner, resolvedName, "\(resolvedOwner)/\(resolvedName)", existing)
    }

    /// 远端写入与本地写入共享审计格式，但权限必须独立校验。成功时从结果回填 GitHub
    /// repo ID；失败或 dry-run 仍记录 full name，避免外部搜索目标没有本地行时丢失审计对象。
    private func performGitHubStarWrite(
        tool: String,
        dryRun: Bool,
        repoID: Int64?,
        targetFullName: String,
        operation: () async throws -> MCPStarWriteResult
    ) async throws -> MCPStarWriteResult {
        do {
            try validate(.write)
            let result = try await operation()
            await auditLog.record(
                tool: tool,
                permission: .write,
                dryRun: dryRun,
                success: true,
                repo: nil,
                repoID: result.repo?.id ?? repoID,
                repoFullName: targetFullName,
                affectedTags: [],
                warnings: result.warnings,
                error: nil
            )
            return result
        } catch {
            let outwardError = Self.mapCapabilityError(error)
            await auditLog.record(
                tool: tool,
                permission: .write,
                dryRun: dryRun,
                success: false,
                repo: nil,
                repoID: repoID,
                repoFullName: targetFullName,
                affectedTags: [],
                warnings: [],
                error: outwardError.localizedDescription
            )
            throw outwardError
        }
    }

}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
