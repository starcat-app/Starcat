//
//  RepoIssuesViewModel.swift
//  Starcat
//
//  详情页 Issues 浮层的数据层：列表分页、状态筛选、搜索（客户端过滤 + Search API 兜底）、
//  精确计数、新建 Issue。
//
//  关键约束：
//  - VM 放在 `RepoDetailScaffold` 的 @State 上，跨浮层开关保活；切换仓库走
//    `prepare(owner:repo:)` 复位（key 未变时 no-op，避免重复清状态）。
//  - 首屏 / 计数走 `RepoIssuesSharedStore` 进程内缓存（stale-while-revalidate，TTL 15
//    分钟）：命中即渲染（含过期），过期后台校准；未命中才全量拉取。App 侧注入
//    `.shared` 让角标与多次打开浮层共享；测试默认注入独立实例，互不污染。
//  - 搜索策略（2026-11-01 与 dong4j 确认）：先对已加载页做客户端过滤（标题包含 /
//    编号精确匹配）；过滤为空且有关键词时，debounce 后走 `/search/issues` 兜底一次。
//    兜底结果单独存放（`remoteSearchResults`），不与分页列表混写，也不进共享缓存。
//  - 未解决/已关闭计数走 `/search/issues` per_page=1 取 `total_count`（不含 PR，
//    比本地 `open_issues_count` 准）；失败时保持 nil，UI 不显示数字。
//  - `/search/issues` 限流独立（约 30 次/分钟），所以计数每仓库只拉一次并进共享缓存。
//

import Foundation
import Observation

@MainActor
@Observable
final class RepoIssuesViewModel {

    // MARK: - 列表状态

    private(set) var issues: [GitHubRepoIssue] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    /// 仅在首屏 / 换筛选失败时非 nil；加载更多失败不打断已展示内容，只记日志。
    private(set) var errorMessage: String?

    /// 展示列表 = 远程兜底结果（若有）> 客户端过滤 > 全量已加载页。
    var displayedIssues: [GitHubRepoIssue] {
        if let remoteSearchResults {
            return remoteSearchResults
        }
        let query = normalizedSearchText
        guard !query.isEmpty else { return issues }
        return issues.filter { Self.matches($0, query: query) }
    }

    /// 客户端过滤后是否为空（决定是否触发 / 展示远程兜底）。
    var clientFilteredIsEmpty: Bool {
        let query = normalizedSearchText
        guard !query.isEmpty else { return false }
        return !issues.contains { Self.matches($0, query: query) }
    }

    // MARK: - 筛选 / 搜索

    var stateFilter: GitHubRepoIssueState = .open
    var searchText: String = ""

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 远程搜索兜底

    private(set) var remoteSearchResults: [GitHubRepoIssue]?
    private(set) var remoteSearchTotalCount = 0
    private(set) var isRemoteSearching = false
    /// 兜底搜索失败时的提示；仅在客户端过滤也为空时展示。
    private(set) var remoteSearchErrorMessage: String?

    // MARK: - 精确计数（Search API，不含 PR）

    private(set) var openCount: Int?
    private(set) var closedCount: Int?
    private(set) var isCountLoading = false

    // MARK: - 新建 Issue 回填

    /// 提交成功后记录编号，浮层重载后高亮该行（sort=updated 时新 issue 排第一）。
    var highlightIssueNumber: Int?

    // MARK: - 私有

    private var owner = ""
    private var repoName = ""
    private let client: any GitHubAPIClientProtocol
    /// 首屏 / 计数的 SWR 缓存。默认独立实例（测试隔离）；App 侧显式注入 `.shared`。
    private let store: RepoIssuesSharedStore
    private let perPage = 30
    private var currentPage = 0
    private var nextPage: Int?
    private var listTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var highlightClearTask: Task<Void, Never>?

    init(
        client: any GitHubAPIClientProtocol,
        store: RepoIssuesSharedStore = RepoIssuesSharedStore()
    ) {
        self.client = client
        self.store = store
    }

    /// 仓库变化时由 Scaffold 调用；key 未变 no-op，变了整体复位。
    func prepare(owner: String, repo: String) {
        guard self.owner != owner || self.repoName != repo else { return }
        self.owner = owner
        self.repoName = repo
        reset()
    }

    var repoIssuesPageURL: URL? {
        URL(string: "https://github.com/\(owner)/\(repoName)/issues")
    }

    // MARK: - 列表加载

    func loadFirstPageIfNeeded() async {
        guard issues.isEmpty, !isLoading, listTask == nil else { return }
        // SWR：共享缓存命中即渲染（含过期），过期后台校准；未命中才走网络首屏。
        if await applyCachedPageIfAvailable(for: stateFilter) { return }
        await loadFirstPage()
    }

    /// 首屏加载。`isRevalidation = true` 表示共享缓存已渲染、这次只是后台校准：
    /// 失败时保留缓存数据，不清空不报错（区别于首次加载的失败提示）。
    func loadFirstPage(isRevalidation: Bool = false) async {
        guard !owner.isEmpty, !repoName.isEmpty else { return }
        let requestedState = stateFilter
        listTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            listTask = nil
        }
        do {
            let response = try await client.repoIssues(
                owner: owner,
                repo: repoName,
                state: requestedState,
                page: 1,
                perPage: perPage
            )
            // 结果对请求时的状态永远有效，先回写共享缓存（即使用户已切走，别的窗口还能用）。
            await store.storePage(
                RepoIssuesPageSnapshot(
                    issues: response.value,
                    nextPage: response.linkHeader.nextPage,
                    fetchedAt: Date()
                ),
                owner: owner,
                repo: repoName,
                state: requestedState
            )
            // 等待期间用户可能已切到另一状态：过期响应只进缓存，不再覆盖当前 UI。
            guard stateFilter == requestedState else { return }
            issues = response.value
            currentPage = 1
            nextPage = response.linkHeader.nextPage
            hasMore = response.linkHeader.nextPage != nil
        } catch is CancellationError {
            return
        } catch {
            AppLog.network.error(
                "Repo issues: first page failed repo=\(self.owner)/\(self.repoName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            if isRevalidation {
                // SWR 后台校准失败：保留已展示的缓存数据，不打断浏览也不弹错误。
                return
            }
            errorMessage = Self.listErrorMessage(error)
            issues = []
            hasMore = false
        }
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isLoadingMore, let page = nextPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await client.repoIssues(
                owner: owner,
                repo: repoName,
                state: stateFilter,
                page: page,
                perPage: perPage
            )
            // 去重保护：GitHub 翻页期间 issue 被 update 会导致跨页重复。
            let knownIDs = Set(issues.map(\.id))
            issues.append(contentsOf: response.value.filter { !knownIDs.contains($0.id) })
            currentPage = page
            nextPage = response.linkHeader.nextPage
            hasMore = response.linkHeader.nextPage != nil
        } catch is CancellationError {
            return
        } catch {
            AppLog.network.error(
                "Repo issues: load more failed page=\(page) error=\(error.localizedDescription, privacy: .public)"
            )
            // 加载更多失败静默保留当前页；下次滚动到预取窗口会自动重试。
            hasMore = false
        }
    }

    // MARK: - 筛选 / 搜索入口（视图回调）

    func setStateFilter(_ newState: GitHubRepoIssueState) {
        guard stateFilter != newState else { return }
        stateFilter = newState
        remoteSearchResults = nil
        remoteSearchErrorMessage = nil
        Task { await loadFirstPageForNewState(newState) }
    }

    /// 切换筛选：命中共享缓存即时渲染；未命中才清空旧状态列表走网络，
    /// 避免上一状态的行串进新筛选（清空后由骨架接管）。
    private func loadFirstPageForNewState(_ newState: GitHubRepoIssueState) async {
        if await applyCachedPageIfAvailable(for: newState) { return }
        guard stateFilter == newState else { return }
        issues = []
        currentPage = 0
        nextPage = nil
        hasMore = false
        await loadFirstPage()
    }

    /// 用共享缓存快照立即渲染；已过期时顺带后台校准。返回是否命中。
    private func applyCachedPageIfAvailable(for state: GitHubRepoIssueState) async -> Bool {
        guard let cached = await store.page(owner: owner, repo: repoName, state: state) else {
            return false
        }
        issues = cached.value.issues
        currentPage = 1
        nextPage = cached.value.nextPage
        hasMore = cached.value.nextPage != nil
        if cached.isStale {
            await loadFirstPage(isRevalidation: true)
        }
        return true
    }

    /// 搜索框变化：客户端过滤即时生效；过滤为空且有关键词 → debounce 后远程兜底。
    func searchTextChanged() {
        searchDebounceTask?.cancel()
        let query = normalizedSearchText
        if query.isEmpty {
            remoteSearchResults = nil
            remoteSearchErrorMessage = nil
            isRemoteSearching = false
            return
        }
        // 已有兜底结果时，继续键入先用旧结果顶着，等 debounce 出新结果再替换。
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.runRemoteSearch(query: query)
        }
    }

    private func runRemoteSearch(query: String) async {
        guard !query.isEmpty else { return }
        isRemoteSearching = true
        remoteSearchErrorMessage = nil
        defer { isRemoteSearching = false }
        do {
            let response = try await client.searchIssues(
                query: Self.searchQuery(owner: owner, repo: repoName, state: stateFilter, keyword: query),
                page: 1,
                perPage: perPage
            )
            // 兜底结果可能已经过期（用户又改了关键词 / 换了筛选），只在仍匹配当前输入时落地。
            guard normalizedSearchText == query else { return }
            remoteSearchResults = response.value.items
            remoteSearchTotalCount = response.value.totalCount
        } catch is CancellationError {
            return
        } catch {
            AppLog.network.warning(
                "Repo issues: remote search failed repo=\(self.owner)/\(self.repoName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            guard normalizedSearchText == query else { return }
            remoteSearchResults = nil
            remoteSearchErrorMessage = Self.listErrorMessage(error)
        }
    }

    /// 打开浮层时刷新两个精确计数；共享缓存命中（含过期）先回填给角标，过期再校准。
    func refreshCountsIfNeeded() async {
        guard openCount == nil && closedCount == nil, !isCountLoading else { return }
        guard !owner.isEmpty, !repoName.isEmpty else { return }
        if let cached = await store.counts(owner: owner, repo: repoName) {
            openCount = cached.value.openCount
            closedCount = cached.value.closedCount
            guard cached.isStale else { return }
        }
        await fetchCounts()
    }

    /// Search API 拉双计数并回写共享缓存；失败保持 nil（UI 只显示文字），下次打开重试。
    private func fetchCounts() async {
        isCountLoading = true
        defer { isCountLoading = false }
        async let openResponse = try? client.searchIssues(
            query: Self.searchQuery(owner: owner, repo: repoName, state: .open, keyword: nil),
            page: 1,
            perPage: 1
        )
        async let closedResponse = try? client.searchIssues(
            query: Self.searchQuery(owner: owner, repo: repoName, state: .closed, keyword: nil),
            page: 1,
            perPage: 1
        )
        let (open, closed) = await (openResponse, closedResponse)
        openCount = open?.value.totalCount
        closedCount = closed?.value.totalCount
        if let openCount, let closedCount {
            await store.storeCounts(
                RepoIssuesCountSnapshot(
                    openCount: openCount,
                    closedCount: closedCount,
                    fetchedAt: Date()
                ),
                owner: owner,
                repo: repoName
            )
        }
    }

    // MARK: - 新建 Issue

    /// 提交成功 → 高亮编号 + 重载当前筛选的首屏（open 态下新 issue 按 updated 排第一）。
    func issueDidCreate(_ issue: GitHubRepoIssue) {
        highlightIssueNumber = issue.number
        highlightClearTask?.cancel()
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.highlightIssueNumber = nil
        }
        remoteSearchResults = nil
        remoteSearchErrorMessage = nil
        searchText = ""
        Task { await loadFirstPage() }
    }

    // MARK: - 私有工具

    private func reset() {
        listTask?.cancel()
        searchDebounceTask?.cancel()
        issues = []
        currentPage = 0
        nextPage = nil
        hasMore = false
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        searchText = ""
        stateFilter = .open
        remoteSearchResults = nil
        remoteSearchTotalCount = 0
        isRemoteSearching = false
        remoteSearchErrorMessage = nil
        openCount = nil
        closedCount = nil
        highlightIssueNumber = nil
    }

    /// 客户端过滤规则：标题包含（大小写不敏感）或编号精确匹配（输入纯数字时）。
    nonisolated private static func matches(_ issue: GitHubRepoIssue, query: String) -> Bool {
        if let number = Int(query), issue.number == number {
            return true
        }
        return issue.title.localizedCaseInsensitiveContains(query)
    }

    /// `/search/issues` 限定词。`is:issue` 必带（排除 PR）；关键词为空用于精确计数。
    nonisolated private static func searchQuery(
        owner: String,
        repo: String,
        state: GitHubRepoIssueState,
        keyword: String?
    ) -> String {
        var parts = ["repo:\(owner)/\(repo)", "is:issue", "is:\(state.rawValue)"]
        if let keyword, !keyword.isEmpty {
            parts.append(keyword)
        }
        return parts.joined(separator: " ")
    }

    /// 列表错误文案映射；403 / 404 多半是私仓或 Issues 被关闭，单独说明。
    nonisolated static func listErrorMessage(_ error: Error) -> String {
        if let networkError = error as? NetworkError {
            switch networkError {
            case .notFound:
                return String.l10n("repo.issues.error.notFound", defaultValue: "无法访问该仓库的 Issues（可能是私有仓库或已关闭 Issues）")
            case .clientError(let code, _) where code == 403 || code == 404:
                return String.l10n("repo.issues.error.forbidden", defaultValue: "无法访问该仓库的 Issues（可能是私有仓库或权限不足）")
            case .rateLimited:
                return String.l10n("repo.issues.error.rateLimited", defaultValue: "GitHub 请求频率受限，请稍后再试")
            case .unauthorized:
                return String.l10n("repo.issues.error.unauthorized", defaultValue: "登录状态已失效，请重新登录 GitHub")
            default:
                break
            }
        }
        return String.l10n("repo.issues.error.generic", defaultValue: "Issues 加载失败，请稍后再试")
    }

    // MARK: - 工作台联动

    /// 工作台详情页发表评论成功后（inbox 变更）同步左栏对应行的评论数。
    /// GitHubRepoIssue 是 let 结构，整行重建。
    func updateCommentsCount(issueID: Int64, count: Int) {
        guard let index = issues.firstIndex(where: { $0.id == issueID }) else { return }
        let old = issues[index]
        guard old.commentsCount != count else { return }
        issues[index] = GitHubRepoIssue(
            id: old.id,
            number: old.number,
            title: old.title,
            state: old.state,
            body: old.body,
            htmlURL: old.htmlURL,
            authorLogin: old.authorLogin,
            labels: old.labels,
            commentsCount: count,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt,
            closedAt: old.closedAt
        )
    }

#if DEBUG
    /// SwiftUI Preview 专用：跳过网络直接填充列表（不参与生产路径）。
    func seedPreviewIssues(_ previewIssues: [GitHubRepoIssue], openCount: Int? = nil, closedCount: Int? = nil) {
        issues = previewIssues
        currentPage = 1
        nextPage = nil
        hasMore = false
        isLoading = false
        self.openCount = openCount
        self.closedCount = closedCount
    }
#endif
}
