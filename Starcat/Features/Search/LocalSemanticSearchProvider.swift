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
            // 候选与关键词同源：本地已缓存的全部仓库（含未 Star 私仓），避免语义侧仍只扫 Stars。
            async let localCatalog = repository.searchAllLocalFTS(query: "")
            async let ftsMatches = repository.searchAllLocalFTS(query: request.query)
            let (repos, keywordHits) = try await (localCatalog, ftsMatches)
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
        } catch is CancellationError {
            // 用户继续输入、切换 scope 或关闭面板时，旧搜索任务被取消属于正常控制流。
            // 不把它升级成错误提示，避免新查询结果上叠一条已经过期的失败信息。
            return .empty
        } catch EntitlementGateError.requiresPro {
            // “全部”搜索对非 Pro 用户仍以关键词结果为基线；只有显式点击索引刷新时
            // 才由 Search Center 弹出付费墙，避免每次普通搜索都显示重复升级错误。
            return .empty
        } catch {
            // SearchCoordinator 天然支持部分成功：这里保留具体错误交给 Search Center
            // 展示，同时关键词 Provider 的结果仍可正常呈现，不能再静默伪装成“语义无命中”。
            AppLog.ai.error("Search Center semantic enhancement failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
