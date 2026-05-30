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
//  - 不直接持有 GRDB writer，依赖 RepoRepositoryProtocol（D-01）
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

    /// W4 A6：用户自定义标签列表（Sidebar Tags 组）。
    private(set) var tags: [Tag] = []
    /// W4 A6：tagId → starred repo count（Sidebar Tags 行右侧计数）。
    private(set) var tagCounts: [String: Int] = [:]

    // MARK: - 多选模式（W4 A5）

    /// 是否进入多选模式。开启后中栏 List 切换到多选 selection binding。
    /// D-04 风格：`private(set)`，UI 通过 `toggleMultiSelectMode()` 切换。
    private(set) var isMultiSelectMode: Bool = false

    /// 多选模式下选中的 repo id 集合。SwiftUI List(selection:) 双向绑定，
    /// 所以这里必须可写。退出多选模式时由 `exitMultiSelectMode()` 清空。
    var multiSelectedRepoIDs: Set<Int64> = []

    // MARK: - 排序（W4-4 D1）

    /// 列表排序选项。
    /// 由 RepoListView 通过 onChange 与 AppSettings.repoSortOption 双向同步,
    /// 持久化在 settings 层；ViewModel 这边只关心"用户选了 → items 立刻按新顺序展示"。
    /// didSet 触发 in-memory 排序，避免重复访问数据库。
    var sortOption: RepoSortOption = .starredAtDesc {
        didSet {
            guard oldValue != sortOption else { return }
            sortItems()
        }
    }

    /// 切换多选模式。
    /// 切入：清空单选 selectedRepoID（避免详情页显示残留）；
    /// 切出：清空 multiSelectedRepoIDs（避免下次切入时出现脏数据）。
    func toggleMultiSelectMode() {
        if isMultiSelectMode {
            exitMultiSelectMode()
        } else {
            enterMultiSelectMode()
        }
    }

    func enterMultiSelectMode() {
        isMultiSelectMode = true
        // 把当前单选自动作为多选首项，符合"先选一个再扩选"的直觉
        if let id = selectedRepoID {
            multiSelectedRepoIDs = [id]
        }
        selectedRepoID = nil
    }

    func exitMultiSelectMode() {
        isMultiSelectMode = false
        multiSelectedRepoIDs = []
    }

    // MARK: - 依赖

    /// D-01：依赖协议而非具体 struct，便于单测注入 Mock。
    private let repository: any RepoRepositoryProtocol

    /// W4 A6：Sidebar Tags 段 + 按 tag 过滤需要这两个 repo。
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    /// D-05：当前 in-flight 的 reloadItems 任务，新调用进来先 cancel 旧的，
    /// 防止"快速切 sidebar 时旧查询结果覆盖新结果"的 race。
    /// 参考 `ReadmeViewModel.currentTask` 的相同模式。
    private var currentReloadTask: Task<Void, Never>?

    init(
        repository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.repository = repository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    // MARK: - 公开 action

    /// 刷新 Sidebar 数据（counts + language stats）。
    /// 通常在 onAppear 或 sync 完成后调用。
    func refreshSidebar() async {
        do {
            async let total = repository.starredCount()
            async let untagged = repository.fetchUntagged().count
            async let langs = repository.languageStats()
            async let tagsResult = tagRepository.fetchAll()
            async let tagCountsResult = repoTagRepository.repoCountsByTag()

            self.totalCount = try await total
            self.untaggedCount = try await untagged
            self.languageStats = try await langs
            self.tags = try await tagsResult
            self.tagCounts = try await tagCountsResult
        } catch {
            AppLog.database.error("refreshSidebar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 重新加载中栏列表。
    ///
    /// 派发逻辑：
    /// - 若有非空 searchQuery → FTS5 搜索（忽略 selection，因为搜索是全局的）
    /// - 否则按 selection 派发到对应查询
    ///
    /// D-05：race 防护策略 ——
    /// 1. 入口先 `cancel()` 旧 task（旧 task 内部的 await 会被标记 isCancelled）
    /// 2. 启动新 Task 真正发起查询
    /// 3. 查询返回后 `guard !Task.isCancelled` → 旧 task 直接 return，**完全不动 state**
    ///    （否则 defer 形式的 `isLoading = false` 会覆盖新 task 刚写的 true，引发 UI 闪烁）
    /// 4. 用 `Result<[Repo], Error>` 局部变量延迟 throw 处理，让 cancel 检查在 catch 之前发生
    ///
    /// 为什么不靠 SwiftUI `.task(id:)` 自动取消？
    /// SwiftUI 的 task cancel 只能终止外层 await `reloadItems()`，无法穿透到 reloadItems
    /// 内部 await `repository.fetch...()`。已进入 GRDB 查询的旧调用仍会跑完并写入 state，
    /// 引发"先 A → 切 B → A 覆盖 B → B 再覆盖"的可见闪烁。本函数自管 currentReloadTask 才能根治。
    func reloadItems() async {
        currentReloadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }

            self.isLoading = true
            self.loadError = nil

            let outcome: Result<[Repo], Error>
            do {
                let fetched: [Repo]
                if self.isSearching {
                    fetched = try await self.repository.searchFTS(query: self.searchQuery)
                } else {
                    switch self.selection {
                    case .allStars:
                        fetched = try await self.repository.fetchAllStarred()
                    case .untagged:
                        fetched = try await self.repository.fetchUntagged()
                    case .language(let lang):
                        fetched = try await self.repository.fetchByLanguage(lang)
                    case .tag(let tagId):
                        // W4 A6：按 tag 过滤 — fetchRepos(forTag:) 已带 isStarred=true 过滤
                        fetched = try await self.repoTagRepository.fetchRepos(forTag: tagId)
                    }
                }
                outcome = .success(fetched)
            } catch {
                outcome = .failure(error)
            }

            // race 防护：被新一轮 reloadItems 取消的旧 task 直接丢弃结果，
            // 完全不动 state（否则会覆盖新 task 已写入的 isLoading / items）
            guard !Task.isCancelled else { return }

            self.isLoading = false

            switch outcome {
            case .success(let fetched):
                // W4-4 D1：fetch 完成后立刻按当前 sortOption 排序。
                self.items = self.sorted(fetched)
                // 选中行若已不在新列表，清空详情
                if let selectedID = self.selectedRepoID,
                   !fetched.contains(where: { $0.id == selectedID }) {
                    self.selectedRepoID = nil
                }
            case .failure(let error):
                self.loadError = error.localizedDescription
                self.items = []
                AppLog.database.error("reloadItems failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        currentReloadTask = task
        await task.value
    }

    /// 切换 Sidebar 选中项。
    /// 默认会清空搜索（"切到 Untagged 但保留搜索"语义混乱，干脆清掉）。
    func selectSidebar(_ item: SidebarItem) {
        guard selection != item else { return }
        selection = item
        searchQuery = ""
        selectedRepoID = nil
    }

    // MARK: - W4-4 D1：内部排序工具

    /// 对当前 items in-place 排序。供 `sortOption` didSet 触发，不重 fetch。
    private func sortItems() {
        items = sorted(items)
    }

    /// 按当前 sortOption 返回新数组（不动入参）。
    /// 抽成函数便于 reloadItems 一边接 fetched 一边排序，避免触发 sortOption didSet 误循环。
    private func sorted(_ source: [Repo]) -> [Repo] {
        source.sorted(by: sortOption.comparator)
    }
}
