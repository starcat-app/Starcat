//
//  LocalKeywordSearchProvider.swift
//  Starcat
//
//  全局搜索中心的本地 FTS5 Provider。
//
//  只负责把 RepoRepository 查询结果转换为统一候选，不维护 UI 状态、不做缓存。
//  本地数据库本身就是事实源，再加缓存会制造同步失效问题。
//

import Foundation

struct LocalKeywordSearchProvider: SearchProvider {
    let source: SearchSource = .localKeyword

    private let repository: any RepoRepositoryProtocol
    private let noteRepository: (any RepoNoteRepositoryProtocol)?

    init(
        repository: any RepoRepositoryProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil
    ) {
        self.repository = repository
        self.noteRepository = noteRepository
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .all || request.scope == .local else {
            return .empty
        }

        let repos = try await repository.searchFTS(query: request.query)
        let libraryStateMap = try await noteRepository?.fetchLibraryStateMap(repoIds: repos.map(\.id)) ?? [:]
        let candidates = repos.map { repo in
            RepositoryCandidate(
                identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
                card: repo.asCardData(isInLibrary: libraryStateMap[repo.id] == .inLibrary),
                sources: [.localKeyword],
                localRepo: repo,
                remoteRepo: nil,
                semanticScore: nil
            )
        }
        return SearchProviderPage(
            repositories: candidates,
            references: [],
            totalCount: candidates.count,
            hasNextPage: false
        )
    }
}
