//
//  LocalSemanticSearchProvider.swift
//  Starcat
//
//  Search Center 的本地语义召回适配器。
//
//  为什么独立为 Provider：
//  - SearchCoordinator 已能并发执行来源并按仓库身份去重，语义检索只需接入现有协议；
//  - 关键词结果仍是稳定基线，语义结果负责补回“字面不同但含义接近”的仓库；
//  - 语义能力属于可选增强，未开通、未配置或临时失败时必须静默降级，不能拖垮 FTS5。
//

import Foundation

/// 将 `SemanticSearchService` 的命中转换为 Search Center 候选。
struct LocalSemanticSearchProvider: SearchProvider {
    let source: SearchSource = .localSemantic

    private let repository: any RepoRepositoryProtocol
    private let noteRepository: (any RepoNoteRepositoryProtocol)?
    private let semanticSearchService: SemanticSearchService

    init(
        repository: any RepoRepositoryProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil,
        semanticSearchService: SemanticSearchService
    ) {
        self.repository = repository
        self.noteRepository = noteRepository
        self.semanticSearchService = semanticSearchService
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        guard request.scope == .all || request.scope == .local else {
            return .empty
        }

        do {
            // FTS 命中 ID 只作为 SemanticSearchService 的排序 boost，不做硬过滤；
            // 因此既保留精确命中的稳定性，也不会丢掉真正的同义语义召回。
            async let allStarred = repository.fetchAllStarred()
            async let ftsMatches = repository.searchFTS(query: request.query)
            let (repos, keywordHits) = try await (allStarred, ftsMatches)
            let hits = try await semanticSearchService.search(
                query: request.query,
                candidates: repos,
                ftsHitIDs: Set(keywordHits.map(\.id))
            )
            let visibleHits = hits.filter { $0.displayScore >= request.minimumSemanticScore }
            let libraryStateMap = try await noteRepository?.fetchLibraryStateMap(
                repoIds: visibleHits.map(\.repo.id)
            ) ?? [:]
            let candidates = visibleHits.map { hit in
                let repo = hit.repo
                return RepositoryCandidate(
                    identity: RepoIdentity(ghRepoID: repo.id, owner: repo.owner, name: repo.name),
                    card: repo.asCardData(isInLibrary: libraryStateMap[repo.id] == .inLibrary),
                    sources: [.localSemantic],
                    localRepo: repo,
                    remoteRepo: nil,
                    semanticScore: hit.displayScore
                )
            }
            return SearchProviderPage(
                repositories: candidates,
                references: [],
                totalCount: candidates.count,
                hasNextPage: false
            )
        } catch EntitlementGateError.requiresPro {
            return .empty
        } catch let error as AIEmbeddingError where error.isConfigurationIssue {
            return .empty
        } catch SemanticSearchError.missingAPIKey, SemanticSearchError.noVectors {
            return .empty
        } catch {
            // 统一搜索中语义只是增强层。记录诊断但返回空页，让关键词结果继续可用。
            AppLog.ai.error("Search Center semantic enhancement failed: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }
}
