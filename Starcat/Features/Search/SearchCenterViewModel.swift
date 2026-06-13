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
    var selectedIndex: Int = 0
    var isPresented: Bool = false
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
        guard candidates.indices.contains(selectedIndex) else { return nil }
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
        isPresented = true
        selectedIndex = 0
    }

    func dismiss() {
        isPresented = false
        coordinator.reset()
    }

    func submit() async {
        let request = makeRequest(query: query)
        guard !request.query.isEmpty else {
            coordinator.reset()
            lastSubmittedQuery = ""
            selectedIndex = 0
            return
        }

        lastSubmittedQuery = request.query
        historyStore.record(request.query)
        history = historyStore.items
        selectedIndex = 0
        currentGitHubPage = 1
        await coordinator.search(request)
        clampSelection()
    }

    func changeScope(_ newScope: SearchScope) async {
        scope = newScope
        guard !lastSubmittedQuery.isEmpty else { return }
        query = lastSubmittedQuery
        selectedIndex = 0
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
        selectedIndex = 0
        coordinator.reset()
    }

    func applyGitHubFilters() async {
        guard !lastSubmittedQuery.isEmpty else { return }
        currentGitHubPage = 1
        selectedIndex = 0
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
        selectedIndex = min(max(0, selectedIndex + offset), candidates.count - 1)
    }

    private func clampSelection() {
        selectedIndex = min(selectedIndex, max(0, candidates.count - 1))
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
