//
//  RepositoryMetadataCapability.swift
//  Starcat
//
//  仓库私有笔记与阅读状态的统一写能力。
//
//  Agent、MCP 与后续 CLI adapter 只负责各自的权限和协议转换；本文件统一执行本地仓库
//  解析、dry-run、真实写入、写后回读以及语义索引刷新。这样任一入口都不会绕过同一套
//  用户数据约束。
//

import Foundation

enum RepositoryMetadataCapabilities {
    static let upsertNote = StarcatCapabilityDefinition(
        id: "repository.note.upsert",
        summary: "Create, update, or clear one repository private note.",
        permission: .requiresConfirmation
    )

    static let setStatus = StarcatCapabilityDefinition(
        id: "repository.status.set",
        summary: "Set one repository reading status.",
        permission: .requiresConfirmation
    )
}

enum RepositoryMetadataMutation: Sendable {
    case note
    case status(RepoStatus)
}

struct RepositoryMetadataMutationResult: Sendable {
    var repository: Repo
    var note: RepoNote?
    var changed: Bool
}

protocol RepositoryMetadataCapabilityExecuting: Sendable {
    func upsertNote(repoID: Int64, content: String?, dryRun: Bool) async throws -> RepositoryMetadataMutationResult
    func setStatus(repoID: Int64, status: RepoStatus, dryRun: Bool) async throws -> RepositoryMetadataMutationResult
}

protocol RepositoryMetadataCapabilitySource: Sendable {
    func findRepository(id: Int64) async throws -> Repo?
    func findNote(repoID: Int64) async throws -> RepoNote?
    func updateNote(repoID: Int64, content: String?) async throws
    func updateStatus(repoID: Int64, status: RepoStatus) async throws
    func didMutateRepository(_ repository: Repo, mutation: RepositoryMetadataMutation) async
}

struct DatabaseRepositoryMetadataCapabilitySource: RepositoryMetadataCapabilitySource {
    let repoRepository: any RepoRepositoryProtocol
    let repoNoteRepository: any RepoNoteRepositoryProtocol
    let onRepositoryMutation: @MainActor @Sendable (Repo, RepositoryMetadataMutation) async -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        onRepositoryMutation: @escaping @MainActor @Sendable (Repo, RepositoryMetadataMutation) async -> Void = { _, _ in }
    ) {
        self.repoRepository = repoRepository
        self.repoNoteRepository = repoNoteRepository
        self.onRepositoryMutation = onRepositoryMutation
    }

    func findRepository(id: Int64) async throws -> Repo? {
        try await repoRepository.findById(id)
    }

    func findNote(repoID: Int64) async throws -> RepoNote? {
        try await repoNoteRepository.find(repoId: repoID)
    }

    func updateNote(repoID: Int64, content: String?) async throws {
        try await repoNoteRepository.updateContent(repoId: repoID, content: content)
    }

    func updateStatus(repoID: Int64, status: RepoStatus) async throws {
        try await repoNoteRepository.updateStatus(repoId: repoID, status: status)
    }

    func didMutateRepository(_ repository: Repo, mutation: RepositoryMetadataMutation) async {
        await onRepositoryMutation(repository, mutation)
    }
}

/// 笔记与状态写入的唯一领域执行器。
///
/// dry-run 不构造尚未持久化的 `RepoNote` 假记录，而是返回当前数据库快照；这是已发布 MCP
/// 协议的既有语义。真实写入完成后必须回读，确保 adapter 返回的是最终持久化状态。
struct RepositoryMetadataCapabilityExecutor<Source: RepositoryMetadataCapabilitySource>: RepositoryMetadataCapabilityExecuting, Sendable {
    let source: Source

    func upsertNote(
        repoID: Int64,
        content: String?,
        dryRun: Bool
    ) async throws -> RepositoryMetadataMutationResult {
        let repository = try await requireRepository(repoID)
        let trimmed = content?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed?.isEmpty == true ? nil : content
        if !dryRun {
            try await source.updateNote(repoID: repoID, content: normalized)
            await source.didMutateRepository(repository, mutation: .note)
        }
        return RepositoryMetadataMutationResult(
            repository: repository,
            note: try await source.findNote(repoID: repoID),
            changed: !dryRun
        )
    }

    func setStatus(
        repoID: Int64,
        status: RepoStatus,
        dryRun: Bool
    ) async throws -> RepositoryMetadataMutationResult {
        let repository = try await requireRepository(repoID)
        if !dryRun {
            try await source.updateStatus(repoID: repoID, status: status)
            await source.didMutateRepository(repository, mutation: .status(status))
        }
        return RepositoryMetadataMutationResult(
            repository: repository,
            note: try await source.findNote(repoID: repoID),
            changed: !dryRun
        )
    }

    private func requireRepository(_ repoID: Int64) async throws -> Repo {
        guard let repository = try await source.findRepository(id: repoID) else {
            throw RepositoryMetadataCapabilityError.repositoryNotLocal(repoID)
        }
        return repository
    }
}

enum RepositoryMetadataCapabilityError: LocalizedError, Equatable, Sendable {
    case repositoryNotLocal(Int64)

    var errorDescription: String? {
        switch self {
        case .repositoryNotLocal(let repoID): return "Repository not found: \(repoID)"
        }
    }
}
