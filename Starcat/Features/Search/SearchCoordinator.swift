//
//  SearchCoordinator.swift
//  Starcat
//
//  全局搜索中心的 Provider 编排器。
//
//  关键约束：
//  - provider 独立成功/失败，任何单点故障都不能清空其它来源结果；
//  - 每次提交生成单调递增 generation，旧请求即使不响应 cancellation，返回后也会被丢弃；
//  - 切换 scope 不重跑已加载且参数仍兼容的来源：全部 ↔ 本地只改展示，缺失的 GitHub / Web 才补跑；
//  - Coordinator 只编排与合并，不执行 Star、分享、AI、浏览器等业务动作。
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchCoordinator {
    private(set) var statuses: [SearchSource: SearchProviderStatus] = [:]
    private(set) var repositories: [RepositoryCandidate] = []
    private(set) var references: [ReferenceCandidate] = []
    private(set) var contentSummary = SearchContentSummary()
    private(set) var blockedQuery: SearchContentMatch?

    private let providers: [any SearchProvider]
    let contentPolicy: SearchContentPolicy
    private var contentSummaries: [SearchSource: SearchContentSummary] = [:]
    /// 每个来源独立持有任务，翻页只影响该来源；否则 GitHub 翻页会取消仍在计算的语义结果
    private var activeTasks: [SearchSource: (request: SearchRequest, task: Task<Bool, Never>)] = [:]
    /// 成功快照与加载/失败状态分离，分页失败和范围切换都不能丢掉已成功返回的页
    private var loadedPages: [SearchSource: SearchProviderPage] = [:]
    /// 保存来源自己的查询身份，不能拿最后展示的范围请求冒充隐藏来源的缓存参数
    private var providerRequests: [SearchSource: SearchRequest] = [:]
    /// 用户已落库的操作覆盖会话快照，也覆盖操作之前发出、操作之后才返回的响应
    private var libraryUpdates: [LibraryUpdate] = []
    private var generation: UInt64 = 0
    /// 最近一次有效请求。切换 scope 时用来判断哪些来源还能直接展示。
    private var currentRequest: SearchRequest?

    init(providers: [any SearchProvider], contentPolicy: SearchContentPolicy = .bundled) {
        self.providers = providers
        self.contentPolicy = contentPolicy
    }

    func reset() {
        activeTasks.values.forEach { $0.task.cancel() }
        activeTasks = [:]
        generation &+= 1
        currentRequest = nil
        loadedPages = [:]
        providerRequests = [:]
        libraryUpdates = []
        statuses = [:]
        repositories = []
        references = []
        contentSummaries = [:]
        contentSummary = SearchContentSummary()
        blockedQuery = nil
    }

    /// ViewModel 在 Router/历史写入之前调用；Coordinator 自身也在各请求入口检查。
    @discardableResult
    func allowsQuery(_ query: String) -> Bool {
        guard let match = contentPolicy.match(query: query) else { return true }
        reset()
        blockedQuery = match
        contentSummary.record(SearchContentDocument(id: "query"), match: match)
        return false
    }

    /// 提交新搜索并等待当前 generation 的 Provider 全部结束。
    ///
    /// ViewModel 可以选择 await 以驱动测试，也可以包在自己的 Task 中调用。
    func search(_ request: SearchRequest) async {
        reset()
        currentRequest = request
        let selectedProviders = providers.filter { Self.shouldRun($0.source, for: request) }

        guard !request.query.isEmpty, allowsQuery(request.query) else { return }
        await runProviders(selectedProviders, request: request)
    }

    /// 切换 scope：同一句 query 下保留已加载来源，只补跑当前 scope 还没有的 Provider。
    ///
    /// 参数兼容时不取消在途任务、不递增 generation，避免「全部 → 本地」丢掉语义结果
    /// 显式应用筛选只刷新对应来源；query 变了或从未搜过则退回完整 `search`
    func updateScope(_ request: SearchRequest, refreshing refreshedSource: SearchSource? = nil) async {
        guard allowsQuery(request.query) else { return }
        if request.query.isEmpty {
            reset()
            return
        }
        guard currentRequest?.query == request.query else {
            await search(request)
            return
        }

        self.currentRequest = request
        let needed = providers.filter { Self.shouldRun($0.source, for: request) }
        let missing = needed.filter { provider in
            provider.source == refreshedSource || !canReuse(source: provider.source, for: request)
        }

        rebuildLoadedResults()
        guard !missing.isEmpty else { return }

        await runProviders(missing, request: request)
    }

    func status(for source: SearchSource) -> SearchProviderStatus {
        statuses[source] ?? .idle
    }

    /// 失败时仍可从最后成功页重试；提交新查询会清空快照，自然回到第一页
    func loadedPage(for source: SearchSource) -> SearchProviderPage? {
        loadedPages[source]
    }

    var currentGitHubPage: Int {
        guard loadedPages[.github] != nil else { return 1 }
        return providerRequests[.github]?.page ?? 1
    }

    var currentWebMaxResults: Int { providerRequests[.web]?.externalSearchFilters.maxResults ?? 0 }

    /// 数量来自实际可展示的已加载结果，远端总量仅作为页的原始元信息保留。
    func visibleCount(for source: SearchSource) -> Int {
        loadedPages[source]?.hidingContent(contentSummary.blockedIDs).visibleCount ?? 0
    }

    /// 用户在 Search Center 里直接修改知识库状态后，原地刷新已加载候选。
    ///
    /// Coordinator 仍只负责结果集合的内存合并；真正的数据库写入由 View 层经
    /// `AppDependencies` 完成。这里按 repo id / fullName 双路匹配，保持与
    /// `mergeRepositories` 一致，避免 GitHub 搜索结果和本地 FTS 结果身份来源不同
    /// 时刷新不到同一张卡。
    func updateRepositoryLibraryState(
        identity: RepoIdentity,
        state: LibraryState,
        persistedRepo: Repo?
    ) {
        // 远端预览持有打开时的候选；连续加入再移出时第二次回调可能仍没有 localRepo
        // 仓库元数据已经落库，移出知识库不能把此前确认的本地身份一并抹掉
        let knownRepo = persistedRepo ?? libraryUpdates.first {
            Self.isSameRepository($0.identity, identity)
        }?.persistedRepo
        libraryUpdates.removeAll { Self.isSameRepository($0.identity, identity) }
        libraryUpdates.append(LibraryUpdate(identity: identity, state: state, persistedRepo: knownRepo))
        rebuildLoadedResults()
    }

    /// 只追加单一来源的下一页。成功后才提交页码，失败时保留上一页和重试入口
    /// generation 属于整次查询，分页不能递增它，否则其他来源的在途结果会被误判为过期
    @discardableResult
    func loadMore(_ request: SearchRequest, source: SearchSource) async -> Bool {
        guard allowsQuery(request.query), currentRequest?.query == request.query,
              activeTasks[source] == nil,
              let provider = providers.first(where: { $0.source == source }) else { return false }
        currentRequest = request
        let task = startProvider(provider, request: request, append: true)
        return await task.value
    }

    /// Provider 并发完成顺序不稳定，不能直接决定最终列表顺序。每次有新页返回时都按
    /// “关键词 → 语义补召回 → GitHub → Web”重建，保证本地精确命中始终在前，同时
    /// 让同一仓库合并 `.localKeyword` / `.localSemantic` provenance 与 semanticScore。
    private func rebuildLoadedResults() {
        contentSummary = contentSummaries.values.reduce(into: SearchContentSummary()) {
            $0.formUnion($1)
        }
        let displayOrder: [SearchSource] = [.localKeyword, .localSemantic, .github, .web]
        var mergedRepositories: [RepositoryCandidate] = []
        var mergedReferences: [ReferenceCandidate] = []
        let request = currentRequest

        for source in displayOrder {
            if let request, !Self.shouldRun(source, for: request) { continue }
            guard let loaded = loadedPages[source] else { continue }
            let page = loaded.hidingContent(contentSummary.blockedIDs)
            mergedRepositories = Self.mergeRepositories(
                existing: mergedRepositories,
                incoming: page.repositories
            )
            mergedReferences = Self.mergeReferences(
                existing: mergedReferences,
                incoming: page.references
            )
        }

        repositories = applyingLibraryUpdates(to: mergedRepositories)
        references = mergedReferences
    }

    /// 基础结果与发现快照共用同一份已落库状态，迟到的网络卡片不能恢复旧心形。
    func applyingLibraryUpdates(to candidates: [RepositoryCandidate]) -> [RepositoryCandidate] {
        candidates.map { candidate in
            guard let update = libraryUpdates.first(where: {
                Self.isSameRepository($0.identity, candidate.identity)
            }) else { return candidate }
            var updated = candidate
            updated.card = candidate.card.withLibraryState(update.state)
            if let repo = update.persistedRepo {
                updated.localRepo = repo
                if updated.remoteRepo == nil {
                    updated.remoteRepo = repo
                }
            }
            return updated
        }
    }

    private func runProviders(
        _ selectedProviders: [any SearchProvider],
        request: SearchRequest
    ) async {
        // 先创建全部来源任务再等待，因此仍然并发执行；句柄按来源保留以支持独立取消
        let tasks = selectedProviders.map { startProvider($0, request: request, append: false) }
        for task in tasks {
            _ = await task.value
        }
    }

    /// 将来源的请求、快照和状态一起提交，防止旧任务清除替代任务的句柄或覆盖新查询
    private func startProvider(
        _ provider: any SearchProvider,
        request: SearchRequest,
        append: Bool
    ) -> Task<Bool, Never> {
        let source = provider.source
        activeTasks[source]?.task.cancel()
        let requestGeneration = generation
        if !append {
            loadedPages[source] = nil
            contentSummaries[source] = nil
            providerRequests[source] = request
        }
        statuses[source] = .loading
        rebuildLoadedResults()

        let task = Task {
            do {
                var pageRequest = request
                var appending = append
                // 一次用户操作最多自动补一页；先保存空页的真实游标，补取失败仍可重试。
                for attempt in 0..<2 {
                    let rawPage = try await provider.search(pageRequest)
                    guard !Task.isCancelled, requestGeneration == generation else { return false }
                    var summary = contentSummaries[source] ?? SearchContentSummary()
                    let page = contentPolicy.filtering(rawPage, summary: &summary)
                    let accumulated: SearchProviderPage
                    if appending, let previous = loadedPages[source] {
                        accumulated = SearchProviderPage(
                            repositories: Self.mergeRepositories(
                                existing: previous.repositories, incoming: page.repositories
                            ),
                            references: Self.mergeReferences(
                                existing: previous.references, incoming: page.references
                            ),
                            totalCount: page.totalCount,
                            hasNextPage: page.hasNextPage,
                            webMetadata: page.webMetadata
                        ).hidingContent(summary.blockedIDs)
                    } else {
                        accumulated = page
                    }
                    contentSummaries[source] = summary
                    loadedPages[source] = accumulated
                    providerRequests[source] = pageRequest
                    statuses[source] = .loaded(accumulated)
                    rebuildLoadedResults()
                    guard attempt == 0, page.visibleCount == 0,
                          rawPage.visibleCount > 0, page.hasNextPage,
                          let next = pageRequest.advancingContentPage(for: source) else { break }
                    pageRequest = next
                    appending = true
                    statuses[source] = .loading
                }
                activeTasks[source] = nil
                return true
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return false }
                statuses[source] = .failed(error.localizedDescription)
                activeTasks[source] = nil
                return false
            }
        }
        activeTasks[source] = (request, task)
        return task
    }

    /// 在途请求同样要校验参数；分页失败仍可展示成功快照，首次失败则在切回时重试
    private func canReuse(source: SearchSource, for request: SearchRequest) -> Bool {
        guard let previous = activeTasks[source]?.request ?? providerRequests[source],
              Self.isCompatible(source: source, from: previous, to: request) else { return false }
        return activeTasks[source] != nil || loadedPages[source] != nil
    }

    private static func isCompatible(source: SearchSource, from old: SearchRequest, to new: SearchRequest) -> Bool {
        guard old.query == new.query else { return false }
        switch source {
        case .localKeyword:
            return true
        case .localSemantic:
            return old.minimumSemanticScore == new.minimumSemanticScore
        case .github:
            return old.githubFilters == new.githubFilters
                && old.perPage == new.perPage
        case .web:
            return old.anySearchFilters == new.anySearchFilters
                && old.externalSearchFilters == new.externalSearchFilters
                && old.externalSearchProvider == new.externalSearchProvider
        }
    }

    private static func shouldRun(_ source: SearchSource, for request: SearchRequest) -> Bool {
        switch request.scope {
        case .all:
            if source == .web { return request.includeWebInAll }
            return true
        case .local:
            return source == .localKeyword || source == .localSemantic
        case .github:
            return source == .github
        case .web:
            return source == .web
        }
    }

    /// 合并同一 repo 的来源和本地状态。
    ///
    /// 同时维护 ID 与 fullName 两个索引，解决“一个来源有 ghRepoId、另一个来源只有
    /// owner/name”的情况；`RepoIdentity.Hashable` 本身保持严格合约，不承担模糊匹配。
    static func mergeRepositories(
        existing: [RepositoryCandidate],
        incoming: [RepositoryCandidate]
    ) -> [RepositoryCandidate] {
        RepositorySearchMerger.merge(existing: existing, incoming: incoming)
    }

    private static func isSameRepository(_ lhs: RepoIdentity, _ rhs: RepoIdentity) -> Bool {
        RepositorySearchMerger.isSameRepository(lhs, rhs)
    }

    static func mergeReferences(
        existing: [ReferenceCandidate],
        incoming: [ReferenceCandidate]
    ) -> [ReferenceCandidate] {
        var seen = Set(existing.map(\.id))
        var merged = existing
        for candidate in incoming where seen.insert(candidate.id).inserted {
            merged.append(candidate)
        }
        return merged
    }
}

/// 当前搜索会话内已成功落库的知识库操作，独立于网络返回的旧快照
private struct LibraryUpdate {
    let identity: RepoIdentity
    let state: LibraryState
    let persistedRepo: Repo?
}
