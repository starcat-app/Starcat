//
//  SearchCenterViewModel.swift
//  Starcat
//
//  全局搜索中心的界面状态与提交边界。
//
//  关键约束：输入草稿不会逐字符访问数据库或网络；只有用户提交、切换 scope 后的
//  已提交查询重跑、或显式加载更多时才调用 Coordinator，避免远端搜索消耗失控。
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
    private(set) var history: [String]
    private(set) var currentGitHubPage: Int = 1

    let coordinator: SearchCoordinator
    private let historyStore: SearchHistoryStore
    private let includeWebInAll: () -> Bool

    init(
        coordinator: SearchCoordinator,
        historyStore: SearchHistoryStore? = nil,
        includeWebInAll: @escaping () -> Bool = { false }
    ) {
        self.coordinator = coordinator
        let resolvedHistoryStore = historyStore ?? SearchHistoryStore()
        self.historyStore = resolvedHistoryStore
        self.includeWebInAll = includeWebInAll
        self.history = resolvedHistoryStore.items
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
        historyStore.record(request.query)
        history = historyStore.items
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

    func useHistory(_ entry: String) async {
        query = entry
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
    func removeHistory(_ entry: String) {
        historyStore.remove(entry)
        history = historyStore.items
    }

    /// 清空全部历史。视图层负责二次确认（confirmationDialog），
    /// 此处只是执行删除并刷新本地 `history` 快照。
    func clearHistory() {
        guard !history.isEmpty else { return }
        historyStore.clear()
        history = historyStore.items
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
}
