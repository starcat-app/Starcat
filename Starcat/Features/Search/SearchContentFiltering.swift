//
//  SearchContentFiltering.swift
//  Starcat
//
//  将 Search Center 的公开候选映射为规则输入。Provider 保持通用，
//  接入时过滤并记录统计，展示合并时只查询身份集合，不反复扫描文字。
//

import Foundation

extension RepositoryCandidate {
    var contentKey: String { SearchContentPolicy.repositoryKey(identity.normalizedFullName) }

    var contentDocument: SearchContentDocument {
        let repos = [localRepo, remoteRepo].compactMap { $0 }
        return SearchContentDocument(
            id: contentKey,
            repositoryFullName: identity.normalizedFullName,
            repositoryID: identity.ghRepoID,
            urls: repos.flatMap { repo in
                [URL(string: repo.htmlUrl), repo.homepage.flatMap(URL.init(string:))].compactMap { $0 }
            },
            fields: [
                .title: Array(Set([identity.normalizedFullName, card.fullName])),
                .description: Array(Set(([card.description] + repos.map(\.description)).compactMap { $0 })),
                .topic: Array(Set(repos.flatMap(\.topicsArray)))
            ]
        )
    }
}

extension ReferenceCandidate {
    var contentKey: String { SearchContentPolicy.referenceKey(normalizedURL) }

    var contentDocument: SearchContentDocument {
        SearchContentDocument(
            id: contentKey,
            urls: [originalURL, normalizedURL],
            fields: [.title: [title], .description: snippet.map { [$0] } ?? []]
        )
    }
}

extension SearchEvidence {
    var contentDocument: SearchContentDocument {
        SearchContentDocument(
            id: url.map(SearchContentPolicy.referenceKey) ?? "evidence:" + id,
            urls: url.map { [$0] } ?? [],
            fields: [.title: [title], .description: snippet.map { [$0] } ?? []]
        )
    }
}

extension SearchContentPolicy {
    /// 先检查整批，再剔除；同一仓库的多个来源不能靠返回顺序绕过已知命中。
    func filtering(_ page: SearchProviderPage, summary: inout SearchContentSummary) -> SearchProviderPage {
        for candidate in page.repositories {
            let document = candidate.contentDocument
            summary.record(document, match: match(document))
        }
        for reference in page.references {
            let document = reference.contentDocument
            summary.record(document, match: match(document))
        }
        return page.hidingContent(summary.blockedIDs)
    }
}

extension SearchProviderPage {
    /// 保留上游总量、后续页与限流元数据；本地隐藏不等于远端分页结束。
    func hidingContent(_ blockedIDs: Set<String>) -> Self {
        Self(
            repositories: repositories.filter { !blockedIDs.contains($0.contentKey) },
            references: references.filter { !blockedIDs.contains($0.contentKey) },
            totalCount: totalCount,
            hasNextPage: hasNextPage,
            webMetadata: webMetadata
        )
    }

    var visibleCount: Int {
        Set(repositories.map(\.id)).count + Set(references.map(\.id)).count
    }
}

extension SearchRequest {
    /// GitHub 递增页码；Web 沿用既有扩大结果窗口的协议，并严格限制到 100 条。
    func advancingContentPage(for source: SearchSource) -> Self? {
        var webFilters = externalSearchFilters
        let nextPage: Int
        switch source {
        case .github:
            guard page * perPage < 1_000 else { return nil }
            nextPage = page + 1
        case .web:
            guard webFilters.maxResults < 100 else { return nil }
            webFilters.maxResults = min(webFilters.maxResults + 10, 100)
            nextPage = page
        case .localKeyword, .localSemantic:
            return nil
        }
        return Self(
            query: query, scope: scope, githubFilters: githubFilters,
            anySearchFilters: anySearchFilters, externalSearchFilters: webFilters,
            externalSearchProvider: externalSearchProvider, page: nextPage,
            perPage: perPage, includeWebInAll: includeWebInAll,
            minimumSemanticScore: minimumSemanticScore
        )
    }
}
