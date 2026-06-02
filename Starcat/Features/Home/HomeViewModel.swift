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
    var selection: SidebarItem = .allStars {
        didSet {
            // 分类切换时清除 repo 选中状态，避免详情页显示残留数据。
            // 这覆盖了所有 selection 变化路径：
            // - 用户点击 Sidebar 行（language / tag / allStars / untagged）
            // - 代码调用 selectSidebar()
            // - Manage ↔ Trending 页面切换
            guard oldValue != selection else { return }
            #if DEBUG
            // ⏱️ 切分类性能诊断：标记 T0，后续步骤用 elapsed 测量。
            // 注意：用 .notice 而非 .info —— macOS os.Logger.info 默认只进 in-memory ring buffer，
            // Xcode console 实时输出会丢；.notice 是 always-on 级别，保证实时可见。
            Self.selectionChangeStartedAt = Date()
            AppLog.ui.notice("[switch-cat] T0 selection didSet \(String(describing: oldValue), privacy: .public) → \(String(describing: self.selection), privacy: .public)")
            #endif

            // ⚡ HOM-46 性能补丁 #2（2026-06-02）：急切缓存加载（eager cache load）
            //
            // 问题：原来 `reloadItems()` 由 `.task(id: vm.selection)` 异步派发，意味着
            //   click → SwiftUI 立即用「新 selection + 旧 items」渲染一次 contentBody（耗时 100~150ms 的 List View tree
            //   构建）→ .task body 才跑到 reloadItems → 又 applyView → items 改成新值 → 再渲一次。
            //   两次 List 重建 + 两次外层 transition，是用户感受到"卡卡"的核心来源。
            //
            // 修复：在 didSet 里**同步**完成 cache 命中路径。SwiftUI 看到的下一次 body 重算就直接拿到新 items，
            //   无需"先渲一遍旧数据再修正"。后台 SWR fetch 仍走 reloadItems 异步路径。
            //
            // 顺序要求：
            //   1) 先 cache 加载（applyView 设置 items / itemsRev），让数据先就位
            //   2) 再 selectedRepoID / searchQuery 清理（避免 onChange 副作用先于 items 更新跑）
            //
            // 关键约束：
            //   - didSet 内的所有 @Observable 写入会被 SwiftUI 合批到下一次 body 重算，
            //     所以多次写也只触发一次 render。
            //   - `reloadItems` 仍会被 .task 拉起，里面的 `loadFromCache` 会再调一次 applyView，
            //     此时数据完全相同，要靠 `applyView` 的 no-op 检测短路掉（见 applyView 实现）。
            if let cached = listCache[selection], !cached.isExpired {
                self.rawItems = cached.rawItems
                self.statusMap = cached.statusMap
                self.applyView()             // items / itemsRevision 同步就位
                self.isLoading = false
                self.isRefreshing = true     // 后台 fetch 即将开始，nav subtitle 显示"刷新中..."
                self.loadError = nil
                #if DEBUG
                AppLog.ui.notice("[switch-cat] T0' eager cache load done (items=\(self.items.count)) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                #endif
            } else {
                // 无缓存或过期 → 切到骨架屏，等 reloadItems 拉新数据。
                // 这里同步设 isLoading=true，避免「先渲列表壳一帧再渲骨架屏」的闪烁。
                self.isLoading = true
                self.isRefreshing = false
                self.loadError = nil
            }

            selectedRepoID = nil
            searchQuery = ""
        }
    }

    #if DEBUG
    /// ⏱️ 性能诊断：切分类起点时间戳。所有 [switch-cat] 日志的 elapsed 都以它为基准。
    nonisolated(unsafe) static var selectionChangeStartedAt: Date?

    /// 与 T0 的毫秒差；T0 未记录时返回 -1（理论上不该出现）。
    /// `internal`（默认访问级）让 `RepoListView.body` 也能读这个值打 elapsed。
    static var msSinceT0: Double {
        guard let t0 = selectionChangeStartedAt else { return -1 }
        return Date().timeIntervalSince(t0) * 1000
    }
    #endif

    /// 当前中栏列表（经过 filter + sort 后的可见数据）。
    /// 重新加载策略：每次 selection / searchQuery 变化都重算（rebuild 比 diff 简单）。
    /// D-04：`private(set)` 收敛——只有 ViewModel 内部 `applyView()` 能改，避免外部 View 直接覆写引发状态漂移。
    private(set) var items: [Repo] = []

    /// 当前列表快照版本。
    ///
    /// 为什么需要它：排序切换时 `items` 里是同一批 repo，只是顺序大幅变化。
    /// 如果直接让 SwiftUI `List` 用旧 identity 做 diff，macOS 会尝试把几千行逐个 move，
    /// 这部分差分 / 隐式动画发生在主线程，表现就是排序菜单点完后 UI 卡住数秒。
    ///
    /// `RepoListView` 把这个版本号挂到 `List.id(...)` 上；每次 applyView 产出新快照时
    /// 版本递增，List 会按"新快照"重建，而不是做大规模 row move diff。
    private(set) var itemsRevision: Int = 0

    /// W4-4 D2：原始 fetch 结果（未经 filter / sort）。
    /// `items` 是 rawItems 的派生 — sort / filter 改变时只需重跑 `applyView()` 而不必重 fetch。
    /// 私有：不暴露给 UI，保持单向流: rawItems → applyView → items → UI。
    private var rawItems: [Repo] = []

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

    /// 中栏列表加载中（首次加载，无缓存可用）。
    /// D-04：`private(set)` 收敛，UI 只读不写。
    private(set) var isLoading: Bool = false

    /// 列表加载错误信息（短文案）。D-04：`private(set)` 收敛，UI 只读不写。
    private(set) var loadError: String?

    /// 是否正在后台刷新（stale-while-revalidate 模式：缓存已展示，正在拉新数据）。
    /// 用于 UI 显示"刷新中"指示（如列表顶部 mini 进度条）。
    private(set) var isRefreshing: Bool = false

    // MARK: - 列表缓存（HOM-46 优化）

    /// 列表缓存条目：包含原始 repos + statusMap + 缓存时间。
    /// 用于 stale-while-revalidate：切换到已访问分类时先展示缓存，后台刷新新数据。
    private struct CacheEntry {
        let rawItems: [Repo]
        let statusMap: [Int64: RepoStatus]
        let cachedAt: Date

        /// 缓存是否过期（5 分钟 TTL）。
        var isExpired: Bool {
            Date().timeIntervalSince(cachedAt) > 300
        }
    }

    /// 分类列表缓存字典。key = SidebarItem（enum 本身 Hashable）。
    /// 缓存搜索结果（isSearching=true）单独处理，不进此缓存。
    private var listCache: [SidebarItem: CacheEntry] = [:]

    /// 派生：给定 selection 是否有可用（未过期）缓存。
    var hasCachedItems: Bool {
        guard !isSearching else { return false }
        return listCache[selection] != nil && !listCache[selection]!.isExpired
    }

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
    /// didSet 触发 in-memory transformation，避免重复访问数据库。
    var sortOption: RepoSortOption = .starredAtDesc {
        didSet {
            guard oldValue != sortOption else { return }
            applyView()
        }
    }

    // MARK: - 过滤（W4-4 D2）

    /// 是否隐藏 Archived 仓库。与 AppSettings.hideArchived 双向同步。
    var hideArchived: Bool = false {
        didSet {
            guard oldValue != hideArchived else { return }
            applyView()
        }
    }

    /// 是否隐藏 Fork 仓库。与 AppSettings.hideForks 双向同步。
    var hideForks: Bool = false {
        didSet {
            guard oldValue != hideForks else { return }
            applyView()
        }
    }

    // MARK: - 状态过滤（W4-4 D3）

    /// 按状态过滤。`nil` 表示"全部"。
    /// 与 AppSettings.statusFilter 双向同步，持久化到 UserDefaults。
    var statusFilter: RepoStatus? = nil {
        didSet {
            guard oldValue != statusFilter else { return }
            applyView()
        }
    }

    /// reloadItems 时一并拉的 repo→status 映射。
    /// 用 dict 而非每行查询避免 N+1;applyView 直接读取做过滤。
    private var statusMap: [Int64: RepoStatus] = [:]

    /// 派生：当前是否有任何过滤器生效（toolbar 显示徽标用）。
    var hasActiveFilter: Bool { hideArchived || hideForks || statusFilter != nil }

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

    /// W4-4 D3：按状态过滤需要 repoNoteRepository.fetchStatusMap。
    private let repoNoteRepository: any RepoNoteRepositoryProtocol

    /// D-05：当前 in-flight 的 reloadItems 任务，新调用进来先 cancel 旧的，
    /// 防止"快速切 sidebar 时旧查询结果覆盖新结果"的 race。
    /// 参考 `ReadmeViewModel.currentTask` 的相同模式。
    private var currentReloadTask: Task<Void, Never>?

    /// 预取任务：hover 触发，提前加载相邻分类数据。
    private var prefetchTask: Task<Void, Never>?

    init(
        repository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        repoNoteRepository: any RepoNoteRepositoryProtocol
    ) {
        self.repository = repository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.repoNoteRepository = repoNoteRepository
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
    /// HOM-46 优化（stale-while-revalidate）：
    /// - 切换到已有缓存的分类时，先立即展示缓存（isRefreshing=true 展示后台刷新指示）
    /// - 后台发起新请求，新数据到达后更新缓存并刷新视图
    /// - 无缓存时 isLoading=true 显示骨架屏，直到首次数据到达
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
        #if DEBUG
        AppLog.ui.notice("[switch-cat] T1 reloadItems entered  +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
        #endif
        currentReloadTask?.cancel()

        // HOM-46：stale-while-revalidate 优化。
        // 先检查缓存：若有且未过期，立即展示缓存，后台刷新。
        // 若无缓存，先显示 isLoading=true 直到首次数据到达。
        let cached = listCache[selection]
        let hasStaleCache = cached != nil

        if hasStaleCache {
            #if DEBUG
            AppLog.ui.notice("[switch-cat] T2 cache HIT, items=\(cached!.rawItems.count) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
            #endif
            // 有缓存：立即用缓存数据填充 UI，同时后台刷新
            loadFromCache(cached!)
            isRefreshing = true
        } else {
            #if DEBUG
            AppLog.ui.notice("[switch-cat] T2 cache MISS, will show skeleton +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
            #endif
            // 无缓存：显示加载状态
            isLoading = true
            isRefreshing = false
        }
        loadError = nil

        #if DEBUG
        AppLog.ui.notice("[switch-cat] T3 state updated (items=\(self.items.count), itemsRev=\(self.itemsRevision), isLoading=\(self.isLoading), isRefreshing=\(self.isRefreshing)) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
        #endif

        let task = Task { [weak self] in
            guard let self else { return }

            let outcome: Result<[Repo], Error>
            let fetchedStatusMap: [Int64: RepoStatus]

            do {
                // HOM-46 性能优化（2026-06-02）：把 repo fetch 和 status map fetch 真正并行。
                //
                // 改造前：fetched = await fetchAllStarred() ⇒ ids = fetched.map(\.id) ⇒ await fetchStatusMap(ids)
                //   两次 await 串行，且 fetchStatusMap 还要传 1810 个参数走 IN(...) SQL 解析。
                //   实测合计 ~600ms。
                //
                // 改造后：repo fetch 与 fetchAllStatusMap()（全表，无参数）用 async let 并行启动。
                //   理论上耗时取较慢者，最优情况能省掉 ~150ms。
                //
                // 并行使用 `async let` 而非 `Task { }`：
                //   - async let 是结构化并发，作用域结束自动等待 / 传播取消
                //   - 与现有 race 防护（外层 Task.isCancelled 检查）天然兼容
                //   - 不需要额外 cancel 管理
                let fetchedTask: () async throws -> [Repo] = {
                    if self.isSearching {
                        return try await self.repository.searchFTS(query: self.searchQuery)
                    } else {
                        switch self.selection {
                        case .trending:
                            return [] // Placeholder for W7 Trending
                        case .allStars:
                            return try await self.repository.fetchAllStarred()
                        case .untagged:
                            return try await self.repository.fetchUntagged()
                        case .language(let lang):
                            return try await self.repository.fetchByLanguage(lang)
                        case .tag(let tagId):
                            return try await self.repoTagRepository.fetchRepos(forTag: tagId)
                        }
                    }
                }

                async let fetchedAsync: [Repo] = fetchedTask()
                async let statusMapAsync: [Int64: RepoStatus] = self.repoNoteRepository.fetchAllStatusMap()

                let fetched = try await fetchedAsync
                fetchedStatusMap = (try? await statusMapAsync) ?? [:]

                outcome = .success(fetched)
            } catch {
                fetchedStatusMap = [:]
                outcome = .failure(error)
            }

            // race 防护：被新一轮 reloadItems 取消的旧 task 直接丢弃结果
            guard !Task.isCancelled else { return }

            #if DEBUG
            AppLog.ui.notice("[switch-cat] T5 bg fetch done +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
            #endif

            self.isLoading = false
            self.isRefreshing = false

            switch outcome {
            case .success(let fetched):
                // 更新缓存（无论 UI 是否需要重渲染，都用最新数据替换 cache entry，
                // 让下次切回这个分类时拿到 freshest 数据）
                self.listCache[self.selection] = CacheEntry(
                    rawItems: fetched,
                    statusMap: fetchedStatusMap,
                    cachedAt: Date()
                )

                // ⚡ HOM-46 性能补丁（2026-06-02）：
                // SWR 后台 fetch 完成后，如果拉到的数据与已显示数据**完全一致**（同一批 ID + 同一份
                // statusMap），则**只更新底层 rawItems / statusMap 引用，不调用 applyView**。
                //
                // 为什么这样做：
                // - applyView 会无条件 `itemsRevision += 1`，这会触发：
                //   ① `RepoListView.contentAnimationID` 变化 → 外层 `.transition` 重跑 0.22s 动画
                //   ② 内层 `List.id(itemsRevision)` → 完整重建 1800+ 行 View tree（~100ms）
                //   ③ 每行 `listRowReveal` 重新走 0.22s stagger 入场动画
                // - 用户感受：缓存命中分类后 ~140ms 看到数据，然后 ~735ms（bg fetch 完成）又跑一遍同样
                //   的动画，叠加感受 ~1s 卡顿，但其实数据没变。
                //
                // 比较策略（fail-fast）：先比 ID 序列长度，再 zip 比每个 ID。statusMap 字典等值用 ==。
                // 这两步对 1800+ 条数据测下来 < 5ms，远低于一次 applyView + UI 重建的代价。
                //
                // 严格遵循"任一字段差异都重建"——只跳过完全相同的情况。Repo.== 用 id 不是全字段，
                // 所以这里手动比 id 序列，未来如果 sync 真的拉到了"id 相同但 stars 变了"的更新，
                // 我们暂时会漏渲染——但这种情况下一次切回当前分类（cache 已经被这里更新了）就会
                // 触发完整 applyView 修正回来。可接受。
                let idsIdentical = fetched.count == self.rawItems.count &&
                                   zip(fetched, self.rawItems).allSatisfy { $0.id == $1.id }
                let statusIdentical = fetchedStatusMap == self.statusMap

                if idsIdentical && statusIdentical {
                    // 静默更新底层引用（rawItems / statusMap 是 private 属性，不参与视图重建）。
                    // 不动 items / itemsRevision → 不触发 SwiftUI re-render，避免第二波动画。
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
                    #if DEBUG
                    AppLog.ui.notice("[switch-cat] T6' bg fetch identical, skipped applyView +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                    #endif
                } else {
                    // 数据真的变了（同步刚结束 / 用户操作改了 status 等）→ 走完整 applyView
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
                    self.applyView()
                    #if DEBUG
                    AppLog.ui.notice("[switch-cat] T6 applyView done after bg fetch +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                    #endif
                }
            case .failure(let error):
                self.loadError = error.localizedDescription
                // 缓存加载已展示过的数据，失败不清理
                if self.rawItems.isEmpty {
                    self.items = []
                }
                AppLog.database.error("reloadItems failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        currentReloadTask = task
        #if DEBUG
        AppLog.ui.info("[switch-cat] T4 bg task started, await begins +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
        #endif
        await task.value
    }

    /// 从缓存条目加载数据到 UI（立即展示，无加载指示）。
    private func loadFromCache(_ entry: CacheEntry) {
        self.rawItems = entry.rawItems
        self.statusMap = entry.statusMap
        #if DEBUG
        let beforeApply = Date()
        self.applyView()
        let applyMs = Date().timeIntervalSince(beforeApply) * 1000
        AppLog.ui.notice("[switch-cat] loadFromCache applyView took \(applyMs, format: .fixed(precision: 1))ms (items=\(self.items.count))")
        #endif
        #if !DEBUG
        self.applyView()
        #endif
    }

    /// 预取指定分类的列表数据（hover 触发）。
    /// 仅在有缓存且缓存过期时真正发起请求；未过期直接忽略。
    func prefetch(selection: SidebarItem) {
        guard !selection.isTrending else { return } // Trending 无需预取

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }

            // 检查缓存是否已存在且未过期
            if let cached = self.listCache[selection], !cached.isExpired {
                return // 已缓存且未过期，无需预取
            }

            // 缓存不存在或已过期，发起预取（静默更新缓存）。
            // HOM-46：repo fetch 与 fetchAllStatusMap 并行，节省一次串行 round-trip。
            do {
                let fetchedTask: () async throws -> [Repo]? = {
                    switch selection {
                    case .trending:
                        return nil
                    case .allStars:
                        return try await self.repository.fetchAllStarred()
                    case .untagged:
                        return try await self.repository.fetchUntagged()
                    case .language(let lang):
                        return try await self.repository.fetchByLanguage(lang)
                    case .tag(let tagId):
                        return try await self.repoTagRepository.fetchRepos(forTag: tagId)
                    }
                }

                async let fetchedAsync = fetchedTask()
                async let statusMapAsync = self.repoNoteRepository.fetchAllStatusMap()

                guard let fetched = try await fetchedAsync else { return }

                guard !Task.isCancelled else { return }
                let statusMap = (try? await statusMapAsync) ?? [:]

                guard !Task.isCancelled else { return }
                self.listCache[selection] = CacheEntry(
                    rawItems: fetched,
                    statusMap: statusMap,
                    cachedAt: Date()
                )
            } catch {
                // 预取失败静默忽略，不影响 UI
            }
        }
    }

    /// 切换 Sidebar 选中项。
    /// 默认会清空搜索（"切到 Untagged 但保留搜索"语义混乱，干脆清掉）。
    func selectSidebar(_ item: SidebarItem) {
        guard selection != item else { return }
        selection = item  // didSet 会处理 selectedRepoID = nil 和 searchQuery = ""
    }

    // MARK: - W4-4 D2：filter + sort 透视层

    /// 把 rawItems 经 filter + sort 后写入 items。
    ///
    /// 调用时机：
    /// - reloadItems 拿到 fetched 数据后
    /// - sortOption / hideArchived / hideForks didSet 触发
    /// - selection didSet 急切缓存加载
    /// - reloadItems 内 loadFromCache（与急切加载重复，靠下面 no-op 检测短路）
    ///
    /// 顺序：先 filter 后 sort，避免 sort 在被过滤掉的元素上浪费比较；
    /// 1801 条规模下任意顺序都是几 ms，主要是逻辑清晰。
    /// 也负责"选中行被过滤掉了 → 清空 selectedRepoID"，避免详情页显示残影。
    ///
    /// HOM-46 性能补丁 #2（2026-06-02）：no-op 短路
    /// - 算出的 view 与当前 items 的 id 序列完全一致 → 不写 items / 不动 itemsRevision，
    ///   避免触发 SwiftUI 的 `List.id(itemsRevision)` 重建 + `listRowReveal` 入场动画。
    /// - 典型受益场景：selection didSet 已经急切加载过缓存，紧跟着 reloadItems 又调了一遍
    ///   loadFromCache → applyView，数据完全相同，本来是一次浪费的 list rebuild。
    /// - 仍然执行 selectedRepoID / multiSelectedRepoIDs 清理，因为这些不依赖 items 是否变化，
    ///   只依赖最新 view 的 ID 集合。
    private func applyView() {
        var view = rawItems
        if hideArchived { view.removeAll { $0.isArchived } }
        if hideForks    { view.removeAll { $0.isFork } }
        // W4-4 D3：状态过滤 — 未在 repo_notes 表登记的视为 implicit "unread"。
        // 这样新同步进来的 repo 默认被 unread 过滤命中,符合"未读 = 还没看过"的直觉。
        if let status = statusFilter {
            view.removeAll { repo in
                let actual = statusMap[repo.id] ?? .unread
                return actual != status
            }
        }
        view.sort(by: sortOption.comparator)

        // no-op 短路：id 序列完全一致就不动 items / itemsRevision
        let viewIdentical = view.count == items.count &&
                            zip(view, items).allSatisfy { $0.id == $1.id }
        if !viewIdentical {
            items = view
            itemsRevision += 1
        }

        // selection 清理始终要做：即便 items 没换，statusFilter / hideArchived 改了也可能让选中行隐身
        if let id = selectedRepoID, !view.contains(where: { $0.id == id }) {
            selectedRepoID = nil
        }
        if isMultiSelectMode {
            // 多选模式下被过滤掉的 id 也要从选中集合移除
            let visibleIDs = Set(view.map(\.id))
            multiSelectedRepoIDs.formIntersection(visibleIDs)
        }
    }
}

// MARK: - SidebarItem 扩展

extension SidebarItem {
    /// 是否为 Trending（预取时跳过）。
    var isTrending: Bool {
        if case .trending = self { return true }
        return false
    }

    /// 返回"相邻"分类列表，用于 hover 预取建议。
    /// 不包含当前 item 自身。
    var prefetchCandidates: [SidebarItem] {
        switch self {
        case .trending:
            return [.allStars, .untagged]
        case .allStars:
            return [.untagged]
        case .untagged:
            return [.allStars]
        case .language:
            return [.allStars, .untagged]
        case .tag:
            return [.allStars, .untagged]
        }
    }
}
