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

    /// Planner 生成的子查询也受策略约束，拒绝项不消耗远端请求预算。
    func filtering(
        _ plan: SearchDiscoveryPlan,
        originalQuery: String,
        summary: inout SearchContentSummary
    ) -> SearchDiscoveryPlan {
        func allows(_ value: String) -> Bool {
            guard let match = match(query: value) else { return true }
            summary.record(SearchContentDocument(id: "query:" + value), match: match)
            return false
        }
        let githubQueries = plan.githubQueries.filter(allows)
        let webQueries = plan.webQueries.filter(allows)
        return SearchDiscoveryPlan(
            intentSummary: allows(plan.intentSummary) ? plan.intentSummary : originalQuery,
            githubQueries: githubQueries,
            webQueries: webQueries,
            prefersFreshEvidence: plan.prefersFreshEvidence,
            strictConstraints: plan.strictConstraints.filter(allows),
            githubFilters: plan.githubFilters
        )
    }

    /// 已被后续核验判定隐藏的身份，其早先网页证据也不能继续进入重排。
    func filtering(_ evidence: [SearchEvidence], summary: inout SearchContentSummary) -> [SearchEvidence] {
        for item in evidence where item.isValid {
            let document = item.contentDocument
            summary.record(document, match: match(document))
        }
        return evidence.filter { $0.isValid && !summary.blockedIDs.contains($0.contentDocument.id) }
    }

    /// 缓存回读和可注入发现服务仍过当前规则，不信任旧快照的“已经过滤”标记。
    func filtering(_ result: RepositoryDiscoveryResult) -> RepositoryDiscoveryResult {
        var summary = result.contentSummary
        var page = filtering(SearchProviderPage(
            repositories: result.repositories, references: result.references,
            totalCount: nil, hasNextPage: false
        ), summary: &summary)
        let evidence = filtering(result.session.evidence, summary: &summary)
        page = page.hidingContent(summary.blockedIDs)
        let evidenceIDs = Set(evidence.map(\.id))
        let repositories = page.repositories.map { candidate in
            guard let annotation = candidate.discovery else { return candidate }
            let reasonDocument = SearchContentDocument(
                id: candidate.contentKey, fields: [.description: [annotation.reason]]
            )
            guard !Set(annotation.evidenceIDs).isSubset(of: evidenceIDs)
                    || match(reasonDocument) != nil else { return candidate }
            var sanitized = candidate
            sanitized.discovery = SearchDiscoveryAnnotation(
                reason: "", evidenceIDs: [], rank: annotation.rank, kind: .githubSearch
            )
            return sanitized
        }
        let session = SearchDiscoverySession(
            generation: result.session.generation, round: result.session.round,
            phase: result.session.phase, plan: result.session.plan,
            evidence: evidence, usedLLMCalls: result.session.usedLLMCalls,
            usedWebQueries: result.session.usedWebQueries,
            usedGitHubQueries: result.session.usedGitHubQueries, steps: result.steps
        )
        return RepositoryDiscoveryResult(
            session: session, repositories: repositories, references: page.references,
            diagnostics: result.diagnostics, contentSummary: summary
        )
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
