//
//  CompanionLibraryStateWriter.swift
//  Starcat
//
//  Browser Plugin 知识库状态写入服务。
//
//  插件只能提交 owner/repo 与目标 library state；Starcat App 负责确认 repo 是否已在
//  本地落库。知识库归属和阅读状态是独立状态：加入知识库不自动 GitHub star，移出
//  知识库也不修改 status。
//

import Foundation

enum CompanionLibraryStateWriteError: Error, Equatable {
    case repoNotFound
    case invalidState
}

struct CompanionLibraryStateWriter {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let updateLibraryState: @Sendable (Int64, LibraryState) async throws -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: any RepoNoteRepositoryProtocol
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            updateLibraryState: { repoID, state in
                try await noteRepository.updateLibraryState(repoId: repoID, state: state)
            }
        )
    }

    /// 测试专用注入点，避免为 route 单测搭完整 Repository。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        updateLibraryState: @escaping @Sendable (Int64, LibraryState) async throws -> Void
    ) {
        self.lookupRepo = lookupRepo
        self.updateLibraryState = updateLibraryState
    }

    func save(
        owner: String,
        repo name: String,
        state rawState: String
    ) async throws -> (repoID: Int64, state: LibraryState) {
        guard let target = LibraryState(rawValue: rawState) else {
            throw CompanionLibraryStateWriteError.invalidState
        }
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionLibraryStateWriteError.repoNotFound
        }

        try await updateLibraryState(repo.id, target)
        return (repo.id, target)
    }
}
