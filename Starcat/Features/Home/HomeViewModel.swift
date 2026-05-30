//
//  HomeViewModel.swift
//  Starcat
//
//  三栏主界面状态模型。
//
//  职责：
//  - 维护 Sidebar 当前选中项 + Languages 聚合
//  - 维护中栏当前的仓库列表（按 sidebar selection 或 search query 派发查询）
//  - 维护详情栏当前选中的 repo
//  - 维护搜索关键词，提供防抖触发（防抖逻辑在 View 层用 task(id:) 实现）
//
//  设计约束：
//  - @MainActor + @Observable，所有状态变更在主线程
//  - 不直接持有 GRDB writer，依赖 RepoRepository
//  - 不感知 SidebarView 的渲染细节；只暴露数据与 action
//  - 列表查询是"全量加载"模式，1801 条以内性能完全够；超过 10k 再考虑游标
//

import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {

    // MARK: - 数据状态

    /// 当前侧边栏选中项；默认 All Stars。
    var selection: SidebarItem = .allStars

    /// 当前中栏列表。
    /// 重新加载策略：每次 selection / searchQuery 变化都重算（rebuild 比 diff 简单）。
    /// D-04：`private(set)` 收敛——只有 ViewModel 内部 `reloadItems()` 能改，避免外部 View 直接覆写引发状态漂移。
    private(set) var items: [Repo] = []

    /// 当前详情选中的 repo **ID**（不是 Repo 值）。
    ///
    /// 设计：用 `Int64` 作为 SwiftUI `List(selection:)` 的 selection 类型，
    /// 而不是 `Repo` 本身。理由：
    /// - `Repo` 同时是 Identifiable + Hashable，hash 用 id；如果 Equatable 用全字段
    ///   会违反 Hashable 契约 → `List(selection:)` 写不进 binding（行点击没选中）；
    /// - 即便 == 也只用 id，用 `Int64` selection 仍然更直接：
    ///   ForEach 默认 id 即 `Repo.id`，selection 类型与 ForEach.id 完全匹配，
    ///   SwiftUI 不需要再做 tag 匹配，是最稳的写法。
    /// - selectedRepo（值）通过 computed property 从 items 派生即可。
    var selectedRepoID: Int64?

    /// 派生：当前详情选中的 Repo 值。
    /// 找不到（items 已变，旧 selection 还在）时返回 nil；调用方可据此显示空态。
    var selectedRepo: Repo? {
        guard let id = selectedRepoID else { return nil }
        return items.first { $0.id == id }
    }

    /// 中栏列表加载中。D-04：`private(set)` 收敛，UI 只读不写。
    private(set) var isLoading: Bool = false

    /// 列表加载错误信息（短文案）。D-04：`private(set)` 收敛，UI 只读不写。
    private(set) var loadError: String?

    // MARK: - 搜索

    /// 用户原始输入。
    /// 防抖逻辑在 View 层做（task(id:) + sleep 250ms），ViewModel 这边纯响应。
    var searchQuery: String = ""

    /// 是否当前正在搜索（非空 + 非全空白）。
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Sidebar 数据

    /// 全部 stars 数（Sidebar "全部 Stars" 行计数）。D-04：`private(set)` 收敛。
    private(set) var totalCount: Int = 0

    /// 未打标签数（Sidebar "未分类" 行计数）。D-04：`private(set)` 收敛。
    private(set) var untaggedCount: Int = 0

    /// Languages 聚合（Sidebar Languages 组）。D-04：`private(set)` 收敛。
    private(set) var languageStats: [LanguageStat] = []

    // MARK: - 依赖

    private let repository: RepoRepository

    init(repository: RepoRepository) {
        self.repository = repository
    }

    // MARK: - 公开 action

    /// 刷新 Sidebar 数据（counts + language stats）。
    /// 通常在 onAppear 或 sync 完成后调用。
    func refreshSidebar() async {
        do {
            async let total = repository.starredCount()
            async let untagged = repository.fetchUntagged().count
            async let langs = repository.languageStats()

            self.totalCount = try await total
            self.untaggedCount = try await untagged
            self.languageStats = try await langs
        } catch {
            AppLog.database.error("refreshSidebar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 重新加载中栏列表。
    /// 派发逻辑：
    /// - 若有非空 searchQuery → FTS5 搜索（忽略 selection，因为搜索是全局的）
    /// - 否则按 selection 派发到对应查询
    func reloadItems() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let fetched: [Repo]
            if isSearching {
                fetched = try await repository.searchFTS(query: searchQuery)
            } else {
                switch selection {
                case .allStars:
                    fetched = try await repository.fetchAllStarred()
                case .untagged:
                    fetched = try await repository.fetchUntagged()
                case .language(let lang):
                    fetched = try await repository.fetchByLanguage(lang)
                }
            }
            self.items = fetched

            // 选中行若已不在新列表，清空详情
            if let selectedID = selectedRepoID, !fetched.contains(where: { $0.id == selectedID }) {
                self.selectedRepoID = nil
            }
        } catch {
            self.loadError = error.localizedDescription
            self.items = []
            AppLog.database.error("reloadItems failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 切换 Sidebar 选中项。
    /// 默认会清空搜索（"切到 Untagged 但保留搜索"语义混乱，干脆清掉）。
    func selectSidebar(_ item: SidebarItem) {
        guard selection != item else { return }
        selection = item
        searchQuery = ""
        selectedRepoID = nil
    }
}
