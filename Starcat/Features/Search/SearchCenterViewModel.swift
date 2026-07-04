//
//  SearchCenterViewModel.swift
//  Starcat
//
//  全局搜索中心的界面状态与提交边界。
//
//  关键约束：输入草稿不会逐字符访问数据库或网络；只有用户提交、切换 scope 后的
//  已提交查询重跑、或显式加载更多时才调用 Coordinator，避免远端搜索消耗失控。
//
//  历史记录：从 W4 (UserDefaults) 升级到 W5-ready GRDB SQLite + CloudKit-friendly
//  字段（id UUID / modifiedAt LWW / useCount + 半衰期衰减排序）。详见
//  `SearchHistoryRepositoryProtocol` 与 `docs/2-产品/需求讨论/正式方案/CloudKit数据同步设计.md` §2.x。
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchCenterViewModel {
    var query: String = ""
    var scope: SearchScope = .all
    /// 键盘选中态。`nil` 表示"用户尚未通过方向键显式选中任何一项"，
    /// 视图层据此跳过"深色 accent 高亮"，让 hover 成为唯一的高亮来源——
    /// 避免搜索结果一出来第一项就被强制选中，干扰鼠标用户的视觉焦点。
    var selectedIndex: Int?
    var isPresented: Bool = false
    /// 搜索浮层会在关闭时从 SwiftUI 视图树移除，因此可恢复的 UI 状态必须由
    /// 长生命周期 ViewModel 持有，不能放在 SearchCenterView 的临时 @State 中。
    var isGitHubFiltersExpanded: Bool = false
    var githubFilters: GitHubSearchFilters = .empty
    /// AnySearch 筛选条折叠状态。与 GitHub 筛选条对称（dong4j 2026-06-14 拍板：
    /// 持久化策略对齐 githubFilters —— 仅会话级，App 重启清零，不写 AppSettings）。
    var isAnySearchFiltersExpanded: Bool = false
    /// AnySearch 专属筛选条件（domain / contentTypes / zone）。
    /// 默认 `.empty` 表示「自动」，与未做本次改造前的行为完全一致。
    var anySearchFilters: AnySearchFilters = .empty
    /// External Search 公共筛选条件。会话级保存，不写 AppSettings。
    var externalSearchFilters: ExternalSearchFilters = .empty
    /// Web tab 当前 External Search Provider。会话级保存，App 重启回到设置页默认值。
    var webSearchProvider: ExternalSearchProviderID
    /// 当前搜索入口触发的 Pro 付费墙。只在用户明确进入网页搜索时弹出，避免 `.all`
    /// 搜索里本地/GitHub 结果也被一起挡住。
    var paywallContext: ProPaywallContext?

    private(set) var lastSubmittedQuery: String = ""
    /// 历史记录（按 `decayedScore` 降序排列；UI 直接遍历即可）。
    /// 持久化由 `historyRepository` 负责；本字段是异步加载后的最新内存快照。
    private(set) var history: [SearchHistory] = []
    private(set) var currentGitHubPage: Int = 1

    let coordinator: SearchCoordinator
    private let historyRepository: any SearchHistoryRepositoryProtocol
    private let includeWebInAll: () -> Bool
    private let entitlementGate: EntitlementGate?
    private let telemetryManager: TelemetryManager?

    init(
        coordinator: SearchCoordinator,
        historyRepository: any SearchHistoryRepositoryProtocol,
        includeWebInAll: @escaping () -> Bool = { false },
        entitlementGate: EntitlementGate? = nil,
        telemetryManager: TelemetryManager? = nil
    ) {
        self.coordinator = coordinator
        self.historyRepository = historyRepository
        self.includeWebInAll = includeWebInAll
        self.entitlementGate = entitlementGate
        self.telemetryManager = telemetryManager
        self.webSearchProvider = AppSettings.shared.externalSearchDefaultProvider

        // 历史加载放在 `present()` 触发，不在 init 做。
        //
        // HOM-199 修复（dong4j 2026-06-14）：原实现在 init 里 `Task { await reloadHistory() }`,
        // 但 HomeView.init 与 AppDependencies.init 同步发生在 `_anonymous` 占位 DB 阶段
        // （D-30 多账号 DB 隔离），此时 `historyRepository.fetchAll()` 命中的是空的占位库；
        // 之后 `AuthSession.restoreSessionIfAvailable` → `database.reopen(userId:)` 把 DB
        // pool 切到该 user 的真实 SQLite，但本 VM 没有任何路径再拉一次 → `history` 永远停留
        // 在空快照，用户必须先 submit 一次才能间接触发 `reloadHistory()`（见 `submit()`）
        // 把真实历史搬上来。
        //
        // 修法选型（dong4j 选择方案 2，与 AuthSession 解耦）：每次 `present()` 时按需 reload。
        // 代价：首次打开会多一次 SQLite 读（50 行表，<1ms）；收益：彻底回避 DB 切换时序窗口，
        // ViewModel 不需要订阅 AuthSession.state，分层依然干净。
    }

    var candidates: [SearchCandidate] {
        coordinator.repositories.map(SearchCandidate.repository)
            + coordinator.references.map(SearchCandidate.reference)
    }

    var selectedCandidate: SearchCandidate? {
        guard let selectedIndex, candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }

    var isSearching: Bool {
        coordinator.statuses.values.contains { status in
            if case .loading = status { return true }
            return false
        }
    }

    var errorMessages: [String] {
        coordinator.statuses.compactMap { source, status in
            guard case .failed(let message) = status else { return nil }
            return "\(source.rawValue): \(message)"
        }.sorted()
    }

    var canLoadMoreGitHub: Bool {
        guard case .loaded(let page) = coordinator.status(for: .github) else { return false }
        return page.hasNextPage
    }

    var isLoadingGitHub: Bool {
        guard case .loading = coordinator.status(for: .github) else { return false }
        return true
    }

    var canLoadMoreWeb: Bool {
        guard externalSearchFilters.maxResults < 100,
              case .loaded(let page) = coordinator.status(for: .web) else { return false }
        return page.hasNextPage
    }

    var isLoadingWeb: Bool {
        guard case .loading = coordinator.status(for: .web) else { return false }
        return true
    }

    var githubResultSummary: String? {
        guard case .loaded(let page) = coordinator.status(for: .github), let total = page.totalCount else { return nil }
        if total > 1_000 {
            return String(format: String.l10n("search.github.summary.cappedFormat"), total)
        }
        return String(format: String.l10n("search.github.summary.format"), total)
    }

    /// 网页搜索（AnySearch）成功响应后的页级元信息。
    ///
    /// 只在 web provider 处于 `.loaded` 状态时非 nil；用于驱动浮层底部 footer
    /// 的"X 条结果 · 用时 Y.Ys"摘要 chip 和"剩余 N/M"限流 chip。
    ///
    /// 关键约束：
    /// - 调用方（SearchCenterView）拿到非 nil 后应**进一步判空**`rateLimit` 字段，
    ///   因为 header 三字段缺一不全时 `rateLimit == nil` 但 metadata 仍可能有效。
    /// - status 在 `.idle` / `.loading` / `.failed` 时返回 nil，footer 不渲染。
    var webMetadata: WebSearchMetadata? {
        guard case .loaded(let page) = coordinator.status(for: .web) else { return nil }
        return page.webMetadata
    }

    /// 当前 scope 下、各 provider 已加载的命中数。
    ///
    /// 设计意图（dong4j 2026-06-13 反馈）：`.all` scope 下底部 footer 应该
    /// 反映"本地 + GitHub + 网页"三者聚合，而不是只展示网页的命中数和耗时。
    /// 此属性按 scope 选取需要展示的 provider 列表，过滤掉非 `.loaded` 的，
    /// 输出顺序固定（本地 → GitHub → 网页），保证 UI 不抖动。
    ///
    /// - `.all`：返回三段（本地 / GitHub / 网页），只包含已加载的来源。
    ///   - 本地复合 source 取 `.localKeyword`（FTS）—— 语义搜索算"补强"
    ///     不单独计列，否则容易让用户看到"本地 3 + 本地 2"两条对相同结果重复计数。
    /// - `.web`：返回单段（网页）。
    /// - `.local` / `.github`：返回空数组。
    ///   - `.local` 命中数瞬时无意义、与左上角已有的语义搜索 chip 信息重复，
    ///     不显示 footer 避免冗余。
    ///   - `.github` 命中数已通过 `githubResultSummary` 在 githubFilterBar 显示。
    var resultCounts: [ResultSourceCount] {
        let sources: [SearchSource]
        switch scope {
        case .all:
            sources = [.localKeyword, .github, .web]
        case .web:
            sources = [.web]
        case .local, .github:
            return []
        }
        return sources.compactMap { source in
            guard case .loaded(let page) = coordinator.status(for: source) else { return nil }
            // GitHub 的 totalCount 是 API 报告的"全站命中总数"（可能 1000+），
            // 与列表展示数（取首页 30 条）有差异；这里直接展示总数，与
            // githubResultSummary 同口径，避免两处口径不一致。
            // 本地 / web 的 totalCount 与实际返回数相同，无此问题。
            let total = page.totalCount ?? 0
            return ResultSourceCount(source: source, count: total)
        }
    }

    func present() {
        // 重新打开只恢复面板，不重置选中项或重新搜索。用户误点遮罩关闭后应回到
        // 原来的 query、scope、filters、结果和键盘位置。
        isPresented = true
        // HOM-199 修复：每次打开都 fire-and-forget 拉一次最新历史。
        // - 首次打开（init 后从未加载）→ 把历史从真实 user DB 填进来；
        // - 后续打开 → 顺便吸收上一次提交可能并发产生的写入（成本：单次 50 行表 SQLite read）。
        // 用 detached-on-MainActor 模式：本 VM 是 @MainActor，`Task { ... }` 继承 actor，
        // SwiftUI Button 调用 present() 时不需要 await，UI 已经显示后历史会异步填充。
        Task { await self.reloadHistory() }
    }

    func dismiss() {
        // dismiss 仅控制可见性。真正清空会话只允许走 clear() 或提交空 query，
        // 否则点击浮层外部 / Esc 会让用户被迫重复远端搜索。
        isPresented = false
    }

    func submit() async {
        let request = makeRequest(query: query)
        guard !request.query.isEmpty else {
            coordinator.reset()
            lastSubmittedQuery = ""
            selectedIndex = nil
            return
        }
        guard canRunExplicitWebSearch(request) else { return }

        lastSubmittedQuery = request.query
        // 历史记录持久化 + 重新加载：try? 静默吞错避免 SQLite 异常炸 UI；
        // 真实失败留到 W5 接 CloudKit 时一起观测。
        try? await historyRepository.record(request.query)
        await reloadHistory()
        selectedIndex = nil
        currentGitHubPage = 1
        telemetryManager?.track(
            .searchPerformed,
            properties: [.source: .string(request.scope.rawValue)]
        )
        // Getting Started 清单的“试用一次搜索”对应真实提交行为，而不是只打开搜索面板。
        NotificationCenter.default.post(name: .gettingStartedDidUseSearch, object: nil)
        await coordinator.search(request)
        clampSelection()
    }

    func changeScope(_ newScope: SearchScope) async {
        scope = newScope
        guard canRunExplicitWebSearch(makeRequest(query: query)) else { return }
        guard !lastSubmittedQuery.isEmpty else { return }
        query = lastSubmittedQuery
        selectedIndex = nil
        currentGitHubPage = 1
        await coordinator.search(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    func useHistory(_ entry: SearchHistory) async {
        query = entry.query
        await submit()
    }

    func clear() {
        query = ""
        lastSubmittedQuery = ""
        selectedIndex = nil
        coordinator.reset()
    }

    /// 删除单条历史。仅在用户主动点击 chip 上的 "x" 时调用，
    /// 不会重置当前的查询 / 结果 / 选中位置，保持手术式删除。
    func removeHistory(_ entry: SearchHistory) async {
        try? await historyRepository.remove(query: entry.queryLower)
        await reloadHistory()
    }

    /// 清空全部历史。视图层负责二次确认（confirmationDialog），
    /// 此处只是执行删除并刷新本地 `history` 快照。
    func clearHistory() async {
        guard !history.isEmpty else { return }
        try? await historyRepository.clearAll()
        await reloadHistory()
    }

    func applyGitHubFilters() async {
        guard !lastSubmittedQuery.isEmpty else { return }
        currentGitHubPage = 1
        selectedIndex = nil
        await coordinator.search(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    /// 应用 AnySearch 筛选条件。与 `applyGitHubFilters` 对称：触发 coordinator
    /// 重跑当前 query，ExternalSearchWebProvider 内的 cache key 已把 filters fingerprint
    /// 纳入，新筛选不会复用旧结果。
    func applyAnySearchFilters() async {
        guard !lastSubmittedQuery.isEmpty else { return }
        guard canRunExplicitWebSearch(makeRequest(query: lastSubmittedQuery)) else { return }
        currentGitHubPage = 1
        selectedIndex = nil
        await coordinator.search(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    func changeWebSearchProvider(_ provider: ExternalSearchProviderID) async {
        webSearchProvider = provider
        guard scope == .web, !lastSubmittedQuery.isEmpty else { return }
        selectedIndex = nil
        await coordinator.search(makeRequest(query: lastSubmittedQuery))
        clampSelection()
    }

    func loadMoreGitHub() async {
        guard canLoadMoreGitHub, !lastSubmittedQuery.isEmpty else { return }
        currentGitHubPage += 1
        let request = SearchRequest(
            query: lastSubmittedQuery,
            scope: scope,
            githubFilters: githubFilters,
            anySearchFilters: anySearchFilters,
            externalSearchFilters: externalSearchFilters,
            externalSearchProvider: scope == .web ? webSearchProvider : AppSettings.shared.externalSearchDefaultProvider,
            page: currentGitHubPage,
            perPage: 30,
            includeWebInAll: includeWebInAll()
        )
        await coordinator.loadMore(request, source: .github)
        clampSelection()
    }

    /// Web provider 普遍没有统一 cursor/page 协议；“加载更多”通过增大 maxResults
    /// 后重跑 web source 实现，Coordinator 会按 URL 去重合并，避免重复卡片。
    func loadMoreWeb() async {
        guard canLoadMoreWeb, scope == .web, !lastSubmittedQuery.isEmpty else { return }
        externalSearchFilters.maxResults = min(externalSearchFilters.maxResults + 10, 100)
        await coordinator.loadMore(makeRequest(query: lastSubmittedQuery), source: .web)
        clampSelection()
    }

    func updateRepositoryLibraryState(
        identity: RepoIdentity,
        state: LibraryState,
        persistedRepo: Repo?
    ) {
        coordinator.updateRepositoryLibraryState(
            identity: identity,
            state: state,
            persistedRepo: persistedRepo
        )
    }

    func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        // 首次按方向键时（selectedIndex == nil）一律跳到第 0 项，让用户的注意力
        // 从"完全没选"过渡到"键盘聚焦在第一项"。后续移动维持 clamp,不环绕。
        guard let current = selectedIndex else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, current + offset), candidates.count - 1)
    }

    /// 远端结果回来后修正选中索引：若 candidates 为空则回到"未选中"，
    /// 否则把可能越界的旧 index clamp 到合法范围；nil 状态保持不动。
    private func clampSelection() {
        guard !candidates.isEmpty else {
            selectedIndex = nil
            return
        }
        if let current = selectedIndex {
            selectedIndex = min(current, candidates.count - 1)
        }
    }

    private func makeRequest(query: String) -> SearchRequest {
        SearchRequest(
            query: query,
            scope: scope,
            githubFilters: githubFilters,
            anySearchFilters: anySearchFilters,
            externalSearchFilters: externalSearchFilters,
            externalSearchProvider: scope == .web ? webSearchProvider : AppSettings.shared.externalSearchDefaultProvider,
            page: currentGitHubPage,
            includeWebInAll: includeWebInAll()
        )
    }

    private func canRunExplicitWebSearch(_ request: SearchRequest) -> Bool {
        // 2026-06-21 dong4j 拍板放开 Pro 后的 stub 钩子。
        //
        // 历史行为：曾调用 `entitlementGate?.requirePro(.anySearchWeb)` 拦截非 Pro
        // 用户的 `.web` scope 搜索，失败时设 `paywallContext` 弹付费墙。
        //
        // 现在：网页搜索对所有用户开放 → body 退化为「.web scope 直接放行」。
        // 函数本身**保留**而非删除，理由：
        //  1. 调用点已经分布在 submit() / changeScope() 两条主路径，删函数要动
        //     两处调用 + 改 return 语义，diff 噪音大于收益
        //  2. 这是 free 用户「软限速」最自然的入口（每日 N 次 / 配额耗尽 → 付费墙
        //     或提示升级），未来加 AnySearch 免费配额时直接在这里补 return false 分支
        //     即可，无需重新引入函数
        //  3. 删除再复活会让 git blame 丢失"曾经放开过"的历史信号
        //
        // 未来接入示例（占位写法，**不要现在就实现**）：
        //   do {
        //       try entitlementGate?.requireFreeQuota(.anySearch, used: dailyCounter)
        //       return true
        //   } catch {
        //       paywallContext = ProPaywallContext(...)
        //       return false
        //   }
        guard request.scope == .web else { return true }
        return true
    }

    /// 从 repository 拉最新历史，按 `decayedScore` 降序写入 `history`。
    ///
    /// **为何在 ViewModel 里排序而不是 SQL**：SQLite 不内置 `pow()`，注册自定义函数
    /// 仅为这一个表的排序得不偿失；表上限 50 条，内存排序的 O(n log n) ≪ 1ms。
    private func reloadHistory() async {
        guard let entries = try? await historyRepository.fetchAll() else {
            history = []
            return
        }
        let now = Date()
        history = entries.sorted { lhs, rhs in
            lhs.decayedScore(now: now) > rhs.decayedScore(now: now)
        }
    }
}

/// 单个搜索来源的命中数据（命中数 + 来源标识）。
///
/// 用于驱动浮层底部 footer 的多段 chip 展示。`id` 直接取 source.rawValue，
/// SwiftUI ForEach 复用时不会出现"两个本地段"冲突（理论上不可能，但保险）。
struct ResultSourceCount: Identifiable, Equatable, Sendable {
    let source: SearchSource
    let count: Int

    var id: String { source.rawValue }

    /// chip 上显示的来源标签 i18n key。
    /// 与 `SearchScope.titleKey` 故意分离：scope 是"我想搜什么"，
    /// source 是"结果来自哪儿"，未来可独立翻译微调。
    var labelKey: String {
        switch source {
        case .localKeyword, .localSemantic:
            return "search.footer.source.local"
        case .github:
            return "search.footer.source.github"
        case .web:
            return "search.footer.source.web"
        }
    }
}
