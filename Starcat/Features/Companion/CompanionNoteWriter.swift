//
//  CompanionNoteWriter.swift
//  Starcat
//
//  Browser Plugin 私人笔记写入服务。
//
//  写入必须留在 Starcat App 内执行, Chrome 插件只提交 owner/repo/content。这里统一校验
//  repo 是否存在、是否仍被当前用户 star, 再调用 RepoNoteRepository.updateContent。该方法
//  只改 content + edited_at, 会保留既有 status, 符合 Companion v1 的保存语义。
//

import Foundation

enum CompanionNoteWriteError: Error, Equatable {
    case repoNotFound
    case repoNotStarred
    case contentTooLarge
}

struct CompanionNoteWriter {
    static let maximumContentLength = 20_000

    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let updateContent: @Sendable (Int64, String) async throws -> Void
    private let lookupNote: @Sendable (Int64) async throws -> RepoNote?

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: any RepoNoteRepositoryProtocol
    ) {
        lookupRepo = { owner, repo in
            try await repoRepository.findByOwnerName(owner: owner, name: repo)
        }
        updateContent = { repoID, content in
            try await noteRepository.updateContent(repoId: repoID, content: content)
        }
        lookupNote = { repoID in
            try await noteRepository.find(repoId: repoID)
        }
    }

    /// 测试专用注入点, 避免为了三次调用实现完整 Repository 协议。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        updateContent: @escaping @Sendable (Int64, String) async throws -> Void,
        lookupNote: @escaping @Sendable (Int64) async throws -> RepoNote?
    ) {
        self.lookupRepo = lookupRepo
        self.updateContent = updateContent
        self.lookupNote = lookupNote
    }

    func save(owner: String, repo name: String, content: String) async throws -> CompanionNoteDTO {
        guard content.count <= Self.maximumContentLength else {
            throw CompanionNoteWriteError.contentTooLarge
        }
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionNoteWriteError.repoNotFound
        }
        guard repo.isStarred else {
            throw CompanionNoteWriteError.repoNotStarred
        }

        try await updateContent(repo.id, content)
        let saved = try await lookupNote(repo.id)
        return CompanionNoteDTO(
            editable: true,
            content: saved?.content ?? content,
            editedAt: saved?.editedAt
        )
    }
}
