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
//  `SearchHistoryRepositoryProtocol` 与 `docs/CloudKit数据同步设计.md` §2.x。
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

    private(set) var lastSubmittedQuery: String = ""
    /// 历史记录（按 `decayedScore` 降序排列；UI 直接遍历即可）。
    /// 持久化由 `historyRepository` 负责；本字段是异步加载后的最新内存快照。
    private(set) var history: [SearchHistory] = []
    private(set) var currentGitHubPage: Int = 1

    let coordinator: SearchCoordinator
    private let historyRepository: any SearchHistoryRepositoryProtocol
    private let includeWebInAll: () -> Bool

    init(
        coordinator: SearchCoordinator,
        historyRepository: any SearchHistoryRepositoryProtocol,
        includeWebInAll: @escaping () -> Bool = { false }
    ) {
        self.coordinator = coordinator
        self.historyRepository = historyRepository
        self.includeWebInAll = includeWebInAll

        // 首次构造异步拉一次历史；调用方不需要 await，UI 出现后逐渐填充即可。
        // 失败时静默置空（历史不可见好过把 UI 卡住）。
        Task { await self.reloadHistory() }
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

    var githubResultSummary: String? {
        guard case .loaded(let page) = coordinator.status(for: .github), let total = page.totalCount else { return nil }
        if total > 1_000 {
            return "GitHub 命中 \(total) 条，仅可浏览前 1000 条"
        }
        return "GitHub 命中 \(total) 条"
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

    func present() {
        // 重新打开只恢复面板，不重置选中项或重新搜索。用户误点遮罩关闭后应回到
        // 原来的 query、scope、filters、结果和键盘位置。
        isPresented = true
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

        lastSubmittedQuery = request.query
        // 历史记录持久化 + 重新加载：try? 静默吞错避免 SQLite 异常炸 UI；
        // 真实失败留到 W5 接 CloudKit 时一起观测。
        try? await historyRepository.record(request.query)
        await reloadHistory()
        selectedIndex = nil
        currentGitHubPage = 1
        await coordinator.search(request)
        clampSelection()
    }

    func changeScope(_ newScope: SearchScope) async {
        scope = newScope
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

    func loadMoreGitHub() async {
        guard canLoadMoreGitHub, !lastSubmittedQuery.isEmpty else { return }
        currentGitHubPage += 1
        let request = SearchRequest(
            query: lastSubmittedQuery,
            scope: scope,
            githubFilters: githubFilters,
            page: currentGitHubPage,
            perPage: 30,
            includeWebInAll: includeWebInAll()
        )
        await coordinator.loadMore(request, source: .github)
        clampSelection()
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
            page: currentGitHubPage,
            includeWebInAll: includeWebInAll()
        )
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
