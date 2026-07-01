//
//  CompanionContextProvider.swift
//  Starcat
//
//  Chrome Companion repo-context 聚合入口。
//
//  当前先完成请求校验与 Repo 基础信息映射。推荐、Wiki、Notes、Health、OpenSSF
//  后续按分组增量接入, 但对外 DTO 契约从第一步就固定下来。
//

import Foundation

enum CompanionContextError: Error, Equatable {
    case invalidRepoPath
}

struct CompanionContextProvider {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupNote: @Sendable (Int64) async throws -> RepoNote?

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil
    ) {
        lookupRepo = { owner, name in
            try await repoRepository.findByOwnerName(owner: owner, name: name)
        }
        lookupNote = { repoID in
            try await noteRepository?.find(repoId: repoID)
        }
    }

    /// 测试专用注入点。用闭包替代假 Repository, 避免为了一个查询实现整套协议。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        lookupNote: @escaping @Sendable (Int64) async throws -> RepoNote? = { _ in nil }
    ) {
        self.lookupRepo = lookupRepo
        self.lookupNote = lookupNote
    }

    func context(owner rawOwner: String, repo rawRepo: String) async throws -> CompanionRepoContextResponse {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidGitHubPathComponent(owner), Self.isValidGitHubPathComponent(name) else {
            throw CompanionContextError.invalidRepoPath
        }

        let localRepo = try await lookupRepo(owner, name)
        let note = try await noteDTO(for: localRepo)
        return CompanionRepoContextResponse(
            schemaVersion: 1,
            repo: Self.repoDTO(owner: owner, name: name, localRepo: localRepo),
            recommendations: [],
            wikiLinks: [],
            note: note,
            health: nil,
            openssf: nil,
            actions: CompanionActionsDTO(
                openInStarcat: localRepo != nil,
                codeflow: localRepo != nil,
                codebase: localRepo != nil
            )
        )
    }

    private func noteDTO(for repo: Repo?) async throws -> CompanionNoteDTO? {
        guard let repo, repo.isStarred else { return nil }
        let note = try await lookupNote(repo.id)
        return CompanionNoteDTO(
            editable: true,
            content: note?.content ?? "",
            editedAt: note?.editedAt
        )
    }

    private static func repoDTO(owner: String, name: String, localRepo: Repo?) -> CompanionRepoDTO {
        if let localRepo {
            return CompanionRepoDTO(
                owner: localRepo.owner,
                name: localRepo.name,
                fullName: localRepo.fullName,
                repoID: localRepo.id,
                htmlURL: localRepo.htmlUrl,
                knownToStarcat: true,
                isStarred: localRepo.isStarred
            )
        }

        let fullName = "\(owner)/\(name)"
        return CompanionRepoDTO(
            owner: owner,
            name: name,
            fullName: fullName,
            repoID: nil,
            htmlURL: "https://github.com/\(fullName)",
            knownToStarcat: false,
            isStarred: false
        )
    }

    private static func isValidGitHubPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }
}
