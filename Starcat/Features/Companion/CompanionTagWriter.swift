//
//  CompanionTagWriter.swift
//  Starcat
//
//  Browser Plugin 标签关联写入。
//
//  设计约束:
//  - 插件只修改“当前 repo 关联哪些已有标签”，不创建/改名/改色标签本体；
//    标签本体仍由 Starcat App 的标签管理入口维护，避免两套管理 UI 产生规则分叉。
//  - 只允许已 starred repo 写入标签，未收藏项目不进入用户正式知识库。
//  - 写入成功后重新读取已关联标签并返回，确保插件展示的是数据库确认后的状态。
//

import Foundation

enum CompanionTagWriteError: Error, Equatable {
    case repoNotFound
    case repoNotStarred
    case unknownTagIDs([String])
}

struct CompanionTagWriter {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupAllTags: @Sendable () async throws -> [Tag]
    private let setTags: @Sendable (Int64, [String]) async throws -> Void
    private let lookupAssignedTags: @Sendable (Int64) async throws -> [Tag]

    init(
        repoRepository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            lookupAllTags: {
                try await tagRepository.fetchAll()
            },
            setTags: { repoID, tagIDs in
                try await repoTagRepository.setTags(repoId: repoID, tagIds: tagIDs)
            },
            lookupAssignedTags: { repoID in
                try await repoTagRepository.fetchTags(forRepo: repoID)
            }
        )
    }

    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        lookupAllTags: @escaping @Sendable () async throws -> [Tag],
        setTags: @escaping @Sendable (Int64, [String]) async throws -> Void,
        lookupAssignedTags: @escaping @Sendable (Int64) async throws -> [Tag]
    ) {
        self.lookupRepo = lookupRepo
        self.lookupAllTags = lookupAllTags
        self.setTags = setTags
        self.lookupAssignedTags = lookupAssignedTags
    }

    func save(owner: String, repo name: String, tagIDs: [String]) async throws -> (repoID: Int64, tags: [CompanionTagDTO]) {
        guard let repo = try await lookupRepo(owner, name) else {
            throw CompanionTagWriteError.repoNotFound
        }
        guard repo.isStarred else {
            throw CompanionTagWriteError.repoNotStarred
        }

        let knownIDs = Set(try await lookupAllTags().map(\.id))
        let requestedIDs = Array(Set(tagIDs))
        let unknown = requestedIDs.filter { !knownIDs.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CompanionTagWriteError.unknownTagIDs(unknown)
        }

        try await setTags(repo.id, requestedIDs)
        let assigned = try await lookupAssignedTags(repo.id)
        return (repo.id, assigned.map(CompanionContextProvider.tagDTO(_:)))
    }
}
