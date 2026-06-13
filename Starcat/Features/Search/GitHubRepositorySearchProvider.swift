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
    private let cache: SearchSessionCache<SearchProviderPage>

    init(
        client: any GitHubAPIClientProtocol,
        cache: SearchSessionCache<SearchProviderPage> = SearchSessionCache(ttl: 300)
    ) {
        self.client = client
        self.cache = cache
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .all || request.scope == .github else { return .empty }
        let query = GitHubRepositorySearchQuery(text: request.query, filters: request.githubFilters)
        let key = cacheKey(query: query, request: request)
        if let cached = await cache.value(for: key) { return cached }

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
            return RepositoryCandidate(
                identity: RepoIdentity(ghRepoID: dto.id, owner: dto.owner.login, name: dto.name),
                card: ephemeral.asCardData(),
                sources: [.github],
                localRepo: nil,
                remoteRepo: ephemeral,
                semanticScore: nil
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
        return page
    }

    private func cacheKey(query: GitHubRepositorySearchQuery, request: SearchRequest) -> String {
        "\(query.encodedQuery)|\(request.githubFilters.sort.rawValue)|\(request.githubFilters.order.rawValue)|\(request.page)|\(request.perPage)"
    }
}
