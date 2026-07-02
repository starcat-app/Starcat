//
//  CompanionLibraryStateWriter.swift
//  Starcat
//
//  Browser Plugin 知识库状态写入服务。
//
//  插件只能提交 owner/repo 与目标 library state；Starcat App 负责确认 repo 是否已在
//  本地落库，并复用详情页的关键约束：加入知识库不自动 GitHub star，移出 using repo
//  必须由调用方显式确认，然后把 status 降级为 read。
//

import Foundation

enum CompanionLibraryStateWriteError: Error, Equatable {
    case repoNotFound
    case invalidState
    case usingRemovalRequiresConfirmation
}

struct CompanionLibraryStateWriter {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupNote: @Sendable (Int64) async throws -> RepoNote?
    private let updateLibraryState: @Sendable (Int64, LibraryState) async throws -> Void
    private let updateStatus: @Sendable (Int64, RepoStatus) async throws -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: any RepoNoteRepositoryProtocol
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            lookupNote: { repoID in
                try await noteRepository.find(repoId: repoID)
            },
            updateLibraryState: { repoID, state in
                try await noteRepository.updateLibraryState(repoId: repoID, state: state)
            },
            updateStatus: { repoID, status in
                try await noteRepository.updateStatus(repoId: repoID, status: status)
            }
        )
    }

    /// 测试专用注入点，避免为 route 单测搭完整 Repository。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        lookupNote: @escaping @Sendable (Int64) async throws -> RepoNote? = { _ in nil },
        updateLibraryState: @escaping @Sendable (Int64, LibraryState) async throws -> Void,
        updateStatus: @escaping @Sendable (Int64, RepoStatus) async throws -> Void = { _, _ in }
    ) {
        self.lookupRepo = lookupRepo
        self.lookupNote = lookupNote
        self.updateLibraryState = updateLibraryState
        self.updateStatus = updateStatus
    }

    func save(
        owner: String,
        repo name: String,
        state rawState: String,
        downgradeUsingStatus: Bool
    ) async throws -> (repoID: Int64, state: LibraryState) {
        guard let target = LibraryState(rawValue: rawState) else {
            throw CompanionLibraryStateWriteError.invalidState
        }
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionLibraryStateWriteError.repoNotFound
        }

        if target == .outsideLibrary {
            let note = try await lookupNote(repo.id)
            let status = note.map { RepoStatus.parse($0.status) }
            if status == .using && !downgradeUsingStatus {
                throw CompanionLibraryStateWriteError.usingRemovalRequiresConfirmation
            }
        }

        try await updateLibraryState(repo.id, target)
        if target == .outsideLibrary, downgradeUsingStatus {
            try await updateStatus(repo.id, .read)
        }
        return (repo.id, target)
    }
}
