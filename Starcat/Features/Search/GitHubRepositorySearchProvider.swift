//
//  GitHubRepositorySearchProvider.swift
//  Starcat
//
//  GitHub Repository Search Provider：调用官方端点、映射统一候选并做 5 分钟会话缓存。
//

import Foundation

struct GitHubRepositorySearchProvider: SearchProvider {
    let source: SearchSource = .github

    private let client: any GitHubAPIClientProtocol
    private let noteRepository: (any RepoNoteRepositoryProtocol)?
    private let cache: SearchSessionCache<SearchProviderPage>

    init(
        client: any GitHubAPIClientProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil,
        cache: SearchSessionCache<SearchProviderPage> = SearchSessionCache(ttl: 300)
    ) {
        self.client = client
        self.noteRepository = noteRepository
        self.cache = cache
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .all || request.scope == .github else { return .empty }
        let query = GitHubRepositorySearchQuery(text: request.query, filters: request.githubFilters)
        let key = cacheKey(query: query, request: request)
        if let cached = await cache.value(for: key) {
            return try await pageByApplyingLibraryState(cached)
        }

        let response = try await client.searchRepositories(
            query: query,
            page: request.page,
            perPage: request.perPage
        )
        let candidates = response.value.items.map { dto -> RepositoryCandidate in
            let ephemeral = GRDBRepoRepository.repoFromDTO(
                dto,
                starredAt: nil,
                cachedAt: ISO8601DateFormatter().string(from: Date()),
                isStarred: false
            )
            // SEARCH-RICH 2026-06-14：把 search 端点专属的 disabled / is_template /
            // score 旁挂到 `remoteExtras`。这三个字段不入 `Repo` 模型 / 不入库，
            // 仅供搜索弹窗渲染状态徽章 + 匹配度。
            let extras = RemoteRepoExtras(
                disabled: dto.disabled,
                isTemplate: dto.isTemplate,
                score: dto.score
            )
            return RepositoryCandidate(
                identity: RepoIdentity(ghRepoID: dto.id, owner: dto.owner.login, name: dto.name),
                card: ephemeral.asCardData(),
                sources: [.github],
                localRepo: nil,
                remoteRepo: ephemeral,
                semanticScore: nil,
                remoteExtras: extras
            )
        }
        let cappedTotal = min(response.value.totalCount, 1_000)
        let page = SearchProviderPage(
            repositories: candidates,
            references: [],
            totalCount: response.value.totalCount,
            hasNextPage: request.page * request.perPage < cappedTotal
        )
        await cache.insert(page, for: key)
        return try await pageByApplyingLibraryState(page)
    }

    private func cacheKey(query: GitHubRepositorySearchQuery, request: SearchRequest) -> String {
        "\(query.encodedQuery)|\(request.githubFilters.sort.rawValue)|\(request.githubFilters.order.rawValue)|\(request.page)|\(request.perPage)"
    }

    private func pageByApplyingLibraryState(_ page: SearchProviderPage) async throws -> SearchProviderPage {
        guard let noteRepository else { return page }
        let libraryStateMap = try await noteRepository.fetchLibraryStateMap(
            repoIds: page.repositories.compactMap(\.identity.ghRepoID)
        )
        let repositories = page.repositories.map { candidate in
            var updated = candidate
            updated.card = candidate.card.withLibraryState(
                libraryStateMap[candidate.card.ghRepoId] ?? .outsideLibrary
            )
            return updated
        }
        return SearchProviderPage(
            repositories: repositories,
            references: page.references,
            totalCount: page.totalCount,
            hasNextPage: page.hasNextPage,
            webMetadata: page.webMetadata
        )
    }
}
