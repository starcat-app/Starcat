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
            // 知识库与 All Stars 共用 sortOption：进出知识库时在「默认/最近星标」与
            // 「最近加入知识库」之间对调，避免污染用户在知识库里主动选的其它排序。
            reconcileSortOptionForKnowledgeLibraryTransition(from: oldValue, to: selection)
            if case .userSmartCollection = selection {
                // 规则会在 reloadItems 里随 collection 重新读取。
            } else {
                activeUserSmartCollectionRule = nil
                smartCollectionFilterContext = nil
            }

            // ⚡ HOM-46 性能补丁 #2（2026-06-02）：急切缓存加载（eager cache load）
            //
            // 问题：原来 `reloadItems()` 由 `.task(id: vm.selection)` 异步派发，意味着
            //   click → SwiftUI 立即用「新 selection + 旧 items」渲染一次 contentBody（耗时 100~150ms 的 List View tree
            //   构建）→ .task body 才跑到 reloadItems → 又 applyView → items 改成新值 → 再渲一次。
            //   两次 List 重建 + 两次外层 transition，是用户感受到"卡卡"的核心来源。
            //
            // 修复：在 didSet 里**同步**完成 cache 命中路径。SwiftUI 看到的下一次 body 重算就直接拿到新 items，
            //   无需"先渲一遍旧数据再修正"。普通分类切换不再立刻做后台 DB 重查；
            //   同步完成 / 标签状态变更等真实数据变动路径会用 reloadItems(forceRefresh: true) 强制刷新。
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
            if selection.isGitHubStarListContext {
                skipListRowReveal = true
                DispatchQueue.main.async { [weak self] in
                    self?.skipListRowReveal = false
                }
            } else if isGitHubStarListSwitchLoading {
                isGitHubStarListSwitchLoading = false
            }

            if let cached = listCache[selection], !cached.isExpired {
                if isGitHubStarListSwitchLoading { isGitHubStarListSwitchLoading = false }
                self.rawItems = cached.rawItems
                self.statusMap = cached.statusMap
                self.libraryStateMap = cached.libraryStateMap
                self.applyView()             // items / itemsRevision 同步就位
                if self.isLoading { self.isLoading = false }
                if self.isRefreshing { self.isRefreshing = false }    // 只用缓存瞬切；真实变更路径再显式 force refresh。
                if self.loadError != nil { self.loadError = nil }
                #if DEBUG
                AppLog.ui.notice("[switch-cat] T0' eager cache load done (items=\(self.items.count)) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                #endif
            } else if isKnownEmptyGitHubStarListSelection {
                if isGitHubStarListSwitchLoading { isGitHubStarListSwitchLoading = false }
                // Sidebar 计数已经确认目标分组为空时，立即进入空态，避免先渲染上一组 repo。
                currentReloadTask?.cancel()
                currentReloadTask = nil
                rawItems = []
                filteredSorted = []
                visibleRepoTotalCount = 0
                currentPage = 1
                hasMore = false
                statusMap = [:]
                libraryStateMap = [:]
                if !items.isEmpty {
                    items = []
                    itemsRevision &+= 1
                }
                if self.isLoading { self.isLoading = false }
                if self.isRefreshing { self.isRefreshing = false }
                if self.loadError != nil { self.loadError = nil }
            } else {
                if selection.isGitHubStarListContext {
                    isGitHubStarListSwitchLoading = true
                }
                // 无缓存或过期 → 切到骨架屏，等 reloadItems 拉新数据。
                // 这里同步设 isLoading=true，避免「先渲列表壳一帧再渲骨架屏」的闪烁。
                if !self.isLoading { self.isLoading = true }
                if self.isRefreshing { self.isRefreshing = false }
                if self.loadError != nil { self.loadError = nil }
            }

            if selectedRepoID != nil { selectedRepoID = nil }
            if !searchQuery.isEmpty { searchQuery = "" }
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

    /// 当前 UI 实际渲染的"当前页切片"。
    ///
    /// **R-07（2026-06-15）语义变化**：从"filter + sort 后的全集"改为
    /// "filteredSorted 的前 `currentPage * pageSize` 条切片"。原因是 1800+ 全量
    /// 渲染会让 SwiftUI List view-tree 构建主线程时间数百 ms，与 Weekly 同款
    /// 20 条/页客户端分页对齐后滚动 / 切详情都不再卡。
    ///
    /// 数据流向：`rawItems` →（applyView 内 filter + sort）→ `filteredSorted` →
    /// （sliceToCurrentPage）→ `items` → UI。
    ///
    /// D-04：`private(set)` 收敛——只有 ViewModel 内部 `sliceToCurrentPage()`
    /// 能改，避免外部 View 直接覆写引发状态漂移。
    private(set) var items: [Repo] = []

    /// R-07（2026-06-15）：当前 filter + sort 后的"全集"。
    ///
    /// 两个关键消费者：
    /// - `sliceToCurrentPage()` 从这里取 prefix 填 `items`
    /// - `RepoListView` 的 **Cmd+A / multi-select retain** 必须读这个集合
    ///   而不是 `items`（避免"只能多选当前页"的反直觉），见 `RepoListView.swift`
    ///
    /// 不暴露给真正的 UI 渲染（不用于 ForEach），只作"理论可见集合"语义。
    private(set) var filteredSorted: [Repo] = []

    /// 当前查询条件下的真实 repo 总数。
    ///
    /// 普通 Manage 列表进入 DB 分页模式后，`items` / `filteredSorted` 只代表已加载前缀。
    /// 标题、副标题这类总量展示必须读这里，由 Repository 的轻量 `COUNT(*)` 填充。
    private(set) var visibleRepoTotalCount: Int = 0

    /// 当前列表快照版本。
    ///
    /// 为什么需要它：排序切换时 `items` 里是同一批 repo，只是顺序大幅变化。
    /// 如果直接让 SwiftUI `List` 用旧 identity 做 diff，macOS 会尝试把几千行逐个 move，
    /// 这部分差分 / 隐式动画发生在主线程，表现就是排序菜单点完后 UI 卡住数秒。
    ///
    /// `RepoListView` 把这个版本号挂到 `List.id(...)` 上；每次 sliceToCurrentPage
    /// 产出新切片时版本递增，List 会按"新快照"重建，而不是做大规模 row move diff。
    ///
    /// **R-07 例外**：`loadMoreIfNeeded()` 追加下一页时**故意不 bump** revision，
    /// 让 SwiftUI 走"增量插入新行"路径保持滚动位置，与切分类 / 切排序的"整栏重建"
    /// 路径区分开（详见 `sliceToCurrentPage()` 内注释）。
    private(set) var itemsRevision: Int = 0

    /// GitHub Stars List 分组切换时让行直接显示，跳过 `listRowReveal` 的 stagger 淡入。
    ///
    /// DB 分页通常几十毫秒内返回；如果此时整页 row 随 `itemsRevision` 重播 opacity reveal，
    /// 用户会看到明显闪烁。这个旁路只覆盖仓库分组切换，排序 / 过滤仍保留原快照动画。
    private(set) var skipListRowReveal = false

    /// GitHub Stars List 分组切换期间的短暂占位状态。
    ///
    /// 从 0 repo 分组切到有数据分组时，`items` 在 DB 返回前仍为空；若直接走通用 loading
    /// 分支会闪一下骨架屏 / 空态。这里让 View 层显示透明占位，等 rows 到位后直接显示列表。
    private(set) var isGitHubStarListSwitchLoading = false

    /// R-07（2026-06-15）：客户端分页 —— 当前已展示到第几页（1-based）。
    /// `items.count` ≈ `currentPage * pageSize`（最后一页可能不足）。
    private(set) var currentPage: Int = 1

    /// R-07：是否还有更多页可追加。
    /// `RepoListView` 根据这个值决定是否 attach `.onAppear` 触发 `loadMoreIfNeeded()`。
    private(set) var hasMore: Bool = false

    /// R-07：客户端分页页大小。
    ///
    /// R-07.5：Manage 已改成 DB `OFFSET + append` 后，单页查询和状态读取成本稳定；
    /// 把 pageSize 从 20 提到 40，可以把 1800+ 仓库滚到底的 append 次数近似减半。
    /// SwiftUI List 仍只渲染可见行，多保留 20 条模型数据属于明确的空间换时间。
    static let pageSize: Int = 40

    /// Manage 普通分类的数据库分页模式。
    ///
    /// 旧路径会保留 `rawItems -> filteredSorted -> items` 的全量数组派生；这对智能集合/
    /// 语义搜索仍有价值，但普通 Manage 切页不应该再为 10k+ stars 构造全集。进入本模式后：
    /// - `items` 是数据库按当前查询返回的累计页；
    /// - `filteredSorted` 仅镜像已加载 rows，避免现有详情/行渲染读到旧全集；
    /// - Cmd+A 这类全集语义改走轻量 projection（见 `selectionSnapshotsForCurrentQuery`）。
    private var isDatabasePagingActive = false

    /// DB 分页追加中的轻量互斥。
    ///
    /// 列表尾部 row 的 `.onAppear` 在快速滚动/布局回收时可能连续触发；这里避免同一个
    /// offset 被重复查询并追加两次。它不参与 UI 渲染，只保护加载管线。
    private var isDatabasePageAppendInFlight = false

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

    /// 外部传入的 Repo 对象（如 Undo Star 选中行），不在当前 Manage 列表中。
    /// 设置后 `selectedRepo` 优先返回此值。
    var externalSelectedRepo: Repo?

    /// 外部导航（SearchCenter / 命令面板）写入 `selectedRepoID` 前置 `true`，
    /// 让 `RepoListView` 只在该场景下 `scrollTo` 目标行。
    ///
    /// 用户点击列表行时保持 `false`——否则 `scrollTo(.center)` 会把视口硬顶到
    /// 下一行，体感像「点 A 却定位到 B」（dong4j 2026-06-17 Manage 回归）。
    var shouldScrollSelectedRepoIntoView = false

    /// 派生：当前详情选中的 Repo 值。
    /// 找不到（filteredSorted 已变，旧 selection 还在）时返回 nil；调用方可据此显示空态。
    ///
    /// **R-07 修订**：从 `items` 切到 `filteredSorted` 查找——`items` 现在只是
    /// 当前页切片，外部跳转 / SearchCenter 选中 page 5 的 repo 时它不在 items 内
    /// 但确实在用户可见集合（filteredSorted）里。详情页能正确渲染，列表那一边
    /// 由 `ensureRepoVisible(repoId:)` 负责把 currentPage 推到对应页。
    var selectedRepo: Repo? {
        if let external = externalSelectedRepo { return external }
        guard let id = selectedRepoID else { return nil }
        return filteredSorted.first { $0.id == id }
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

    /// 列表缓存条目：包含原始 repos + 用户私有状态映射 + 缓存时间。
    /// 用于 stale-while-revalidate：切换到已访问分类时先展示缓存，后台刷新新数据。
    private struct CacheEntry {
        let rawItems: [Repo]
        let statusMap: [Int64: RepoStatus]
        let libraryStateMap: [Int64: LibraryState]
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

    /// 当前选中的 GitHub Stars List 是否已由 Sidebar 计数确认为空。
    ///
    /// 这里要求 Sidebar 元数据已经加载，避免启动恢复早期把“计数还没回来”误判成空。
    var isKnownEmptyGitHubStarListSelection: Bool {
        switch selection {
        case .githubStarList(let id):
            return githubStarLists.contains { $0.id == id } && (githubStarListCounts[id] ?? 0) == 0
        case .githubStarListUngrouped:
            return totalCount > 0 && githubStarListUngroupedCount == 0
        default:
            return false
        }
    }

    // MARK: - 搜索

    /// 已提交的搜索词。
    ///
    /// `SmartSearchField` 内部保存实时输入草稿；只有用户按 Return 或点击清空时，才通过
    /// `submitSearch(_:)` 写入这里。这样普通 FTS5 和 AI 语义搜索都不会在每个字符输入时触发。
    var searchQuery: String = ""

    /// 搜索提交序号。
    ///
    /// 即便用户用同一个 query 切换搜索模式后再次按 Return，`searchQuery` 字符串本身可能没变。
    /// 用单调递增 id 作为 HomeView `.task(id:)` 的触发源，确保“提交动作”才是搜索的真实边界。
    var searchSubmissionID: Int = 0

    /// 是否当前正在搜索（非空 + 非全空白）。
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索模式由 AppSettings 持久化，HomeView 启动时同步进来。
    ///
    /// 放在 ViewModel 内部的原因：reloadItems 需要根据模式选择 FTS5 或 semantic 分支；
    /// Settings 仍是持久化事实源，ViewModel 只保存当前渲染会话的查询模式。
    var smartSearchMode: SmartSearchMode = .keyword

    /// 语义搜索范围。关键词搜索仍跟随当前列表上下文，避免改变既有 Manage 搜索习惯。
    var semanticSearchScope: SemanticIndexScope = .starred

    /// 是否正在构建 / 刷新语义索引。
    private(set) var isSemanticIndexing: Bool = false

    /// 最近一次语义搜索结果的 repo id → 命中信息。
    /// UI 行只通过 `semanticHit(for:)` 读取，不直接操作字典，避免把语义搜索状态扩散到 View。
    private var semanticHitMap: [Int64: SemanticSearchHit] = [:]

    var isSemanticSearching: Bool {
        isSearching && smartSearchMode == .semantic
    }

    // MARK: - Sidebar 数据

    /// 全部 stars 数（Sidebar "全部 Stars" 行计数）。D-04：`private(set)` 收敛。
    private(set) var totalCount: Int = 0

    /// 未打标签数（Sidebar "未分类" 行计数）。D-04：`private(set)` 收敛。
    private(set) var untaggedCount: Int = 0

    /// Starcat 私有知识库数量（Sidebar "知识库" 行计数）。
    ///
    /// 口径固定为当前账号下 `libraryState == .inLibrary` 的 repo 总数，不叠加中栏
    /// 搜索、标签、语言或状态过滤；这样它和 "全部仓库 / 未分类" 一样表达基础分类规模。
    private(set) var libraryCount: Int = 0

    /// Languages 聚合（Sidebar Languages 组）。D-04：`private(set)` 收敛。
    private(set) var languageStats: [LanguageStat] = []

    /// 知识库集合专用语言聚合。
    ///
    /// Sidebar 的 `languageStats` 必须继续保持 GitHub starred 口径；这里单独维护
    /// `library_state = in_library` 范围，避免未 star 但已入库的 repo 语言在筛选菜单里消失。
    private(set) var knowledgeLanguageStats: [LanguageStat] = []

    /// W4 A6：用户自定义标签列表（Sidebar Tags 组）。
    private(set) var tags: [Tag] = []
    /// W4 A6：tagId → starred repo count（Sidebar Tags 行右侧计数）。
    private(set) var tagCounts: [String: Int] = [:]
    /// GitHub Stars List 列表（Sidebar「仓库分组」）。
    private(set) var githubStarLists: [GitHubStarList] = []
    /// GitHub list id → starred repo count。
    private(set) var githubStarListCounts: [String: Int] = [:]
    /// 虚拟「未分组」计数。
    private(set) var githubStarListUngroupedCount: Int = 0
    /// 用户自定义智能集合。内置集合由 `SmartCollectionKind` 提供，不入库。
    private(set) var userSmartCollections: [UserSmartCollection] = []
    /// Release 时间线入口右侧计数：只统计当前激活订阅，已取消订阅的保留行不计入。
    private(set) var releaseSubscriptionCount: Int = 0

    // MARK: - HOM-179：标签墙多选过滤

    /// HOM-179：标签墙多选过滤（OR 逻辑）。
    ///
    /// 与 `selection` 的关系（用户口径，2026-06-07）：
    /// - **selectedTagIds 内部多个标签**：OR —— 命中任意一个即保留
    ///   （示例：选 tag1 + tag2 → 显示 tag1 或 tag2 的 repo）
    /// - **selectedTagIds 与 selection（Languages / All Stars / Untagged）**：AND
    ///   （示例：Java + tag1 + tag2 → 必须是 Java 且至少有 tag1 或 tag2）
    ///
    /// 实现方式：
    /// - 不入 `selection`，独立成 filter；selection 仍然只决定 base set
    /// - `applyView()` 在 base set 上做 OR 过滤（用 `repoTagsMap` 查 repo→tagIds）
    /// - 这样切 Languages 也保持已选 tags（AND 组合自然成立）
    /// - didSet 触发 `applyView()` 而非 `reloadItems()`，因为 base set 没变，只是过滤结果变了
    var selectedTagIds: Set<String> = [] {
        didSet {
            guard oldValue != selectedTagIds else { return }
            guard !isHydratingManageFilters else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// HOM-179：repo → 它拥有的 tagIds。
    /// `applyView()` 用这张表做 OR 过滤；`refreshSidebar()` 一次拉全量并刷新。
    /// 之所以走"全量内存映射 + 客户端过滤"而非"为每次切换查 IN/OR SQL"：
    /// - 总量 1801 repos × 平均 ~3 tags = 几千条映射，内存占用可忽略（<100KB）
    /// - 切 Languages / 勾 / 取消标签时不发起 DB 查询，UI 即时响应
    /// - 与现有 `statusMap` 走的"全表加载到字典 + applyView 过滤"路径完全一致
    private var repoTagsMap: [Int64: Set<String>] = [:]

    /// Health 排序 / 筛选用的本地快照缓存，只在用户启用相关控制时读取。
    /// 普通列表仍走既有路径，避免每次切分类都额外查 repo_health_snapshots。
    private var healthSortSnapshots: [Int64: RepoHealthSnapshot] = [:]

    /// OpenSSF 排序 / 筛选用的本地分数缓存，只在用户启用相关控制时读取。
    /// 与 Health 一样延迟加载，避免普通列表切换时额外查 open_ssf_scores。
    private var openSSFSortScores: [Int64: Double] = [:]

    // MARK: - 多选模式
    //
    // W12 toolbar PR-5（2026-06-12）：原 W4 A5 的 `isMultiSelectMode` / `multiSelectedRepoIDs`
    // / `enterMultiSelectMode` / `exitMultiSelectMode` / `toggleMultiSelectMode` 已全部迁移到
    // `AppDependencies.manageMultiSelectionStore`（与 trending/weekly/activity 同款 MultiSelectionStore）。
    //
    // 迁移动因：4 个分类多选交互完全统一（点击 toggle / Cmd+A 全选 / 退出 / 视觉），由 dong4j
    // grill-me 拍板 A 路线。原来在 viewModel 内的 `formIntersection(visibleIDs)` 清理逻辑也下移到
    // RepoListView 的 `.onChange(of: itemsRevision)` 调 `store.retain(visibleIDs:)`，view 层主导
    // store 生命周期（A2 路线），避免 viewModel 重新持 store 引用造成耦合。

    // MARK: - 排序（W4-4 D1）

    /// 列表排序选项。
    /// 由 RepoListView 通过 onChange 与 AppSettings.repoSortOption 双向同步,
    /// 持久化在 settings 层；ViewModel 这边只关心"用户选了 → items 立刻按新顺序展示"。
    /// didSet 触发 in-memory transformation，避免重复访问数据库。
    var sortOption: RepoSortOption = .starredAtDesc {
        didSet {
            guard oldValue != sortOption else { return }
            guard !isHydratingManageFilters else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    // MARK: - 过滤（W4-4 D2）

    /// 是否隐藏 Archived 仓库。与 AppSettings.hideArchived 双向同步。
    var hideArchived: Bool = false {
        didSet {
            guard oldValue != hideArchived else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// 是否隐藏 Fork 仓库。与 AppSettings.hideForks 双向同步。
    var hideForks: Bool = false {
        didSet {
            guard oldValue != hideForks else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    // MARK: - 状态过滤（W4-4 D3）

    /// 按状态过滤。`nil` 表示"全部"。
    /// 与 AppSettings.statusFilter 双向同步，持久化到 UserDefaults。
    var statusFilter: RepoStatus? = nil {
        didSet {
            guard oldValue != statusFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// toolbar 全局 Star 状态筛选。`.all` 表示不收窄范围。
    var starFilter: RepoStarFilter = .all {
        didSet {
            guard oldValue != starFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// 按 Starcat 私有知识库状态过滤。`.all` 表示不收窄范围。
    ///
    /// 这是 Manage/list 级别过滤器，不改变当前 Sidebar 选择；例如 All Stars + 已入库
    /// 只看已 star 且已入库的交集，Smart Collections -> 知识库 + 未入库自然为空。
    var libraryFilter: RepoLibraryFilter = .all {
        didSet {
            guard oldValue != libraryFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// Manage/Smart Collections 列表语言过滤。`.all` 表示不按语言收窄。
    var repoLanguageFilter: RepoLanguageFilter = .all {
        didSet {
            guard oldValue != repoLanguageFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// toolbar 全局语言筛选，多选为空表示不过滤。
    var globalFilterLanguages: [String] = [] {
        didSet {
            guard oldValue != globalFilterLanguages else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// toolbar 全局 Wiki 状态筛选。
    var wikiAvailabilityFilter: RepoSignalAvailabilityFilter = .unknown {
        didSet {
            guard oldValue != wikiAvailabilityFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// toolbar 全局 Health 分数状态筛选。
    var healthAvailabilityFilter: RepoSignalAvailabilityFilter = .unknown {
        didSet {
            guard oldValue != healthAvailabilityFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    /// toolbar 全局 OpenSSF 分数状态筛选。
    var openSSFAvailabilityFilter: RepoSignalAvailabilityFilter = .unknown {
        didSet {
            guard oldValue != openSSFAvailabilityFilter else { return }
            guard !isHydratingManageFilters, !isApplyingGlobalFilterState else { return }
            reloadOrApplyCurrentManageView()
        }
    }

    // MARK: - 语义搜索阈值（HOM-197，2026-06-13 dong4j）

    /// AI 语义搜索结果过滤阈值（cosine similarity 分数，0.0 - 1.0）。
    ///
    /// 与 `AppSettings.aiSemanticSearchScoreThreshold` 单向同步（settings → vm）：
    /// `HomeView` 在 `.task` 内初始化 + `.onChange(of: settings.…)` 监听更新，
    /// 与 `sortOption` / `hideArchived` / `hideForks` / `statusFilter` 同款机制。
    ///
    /// `nil` = 不启用过滤（兜底语义，理论上 HomeView 必然注入 settings 值，
    /// 留 nil 是为单测 / Preview 场景能直接 new HomeViewModel 而不依赖 AppSettings）。
    ///
    /// didSet 触发 applyView()：用户拖滑杆 → settings 写盘 → HomeView .onChange
    /// → 写入这里 → didSet → applyView → items 即时按新阈值重过滤。
    /// 整条路径**不调 embedding API**，详见 applyView() 内 HOM-197 分支注释。
    var semanticScoreThreshold: Double? = nil {
        didSet {
            guard oldValue != semanticScoreThreshold else { return }
            applyView()
        }
    }

    /// reloadItems 时一并拉的 repo→status 映射。
    /// 用 dict 而非每行查询避免 N+1;applyView 直接读取做过滤。
    ///
    /// **可见性策略**（v2，2026-06-12）：从 `private` 升为 `private(set)`，
    /// 让 `RepoListView` 在构造 `RepoCardViewData.readStatus` 时能读取本字段。
    /// `@Observable` 在 view body 里读 dict 会订阅整个 dict 的变更，详情页
    /// 改 status 后通过 `applyStatusChange(...)` 局部更新 dict → SwiftUI
    /// 触发 List 重渲染 → row 角标即时刷新。
    private(set) var statusMap: [Int64: RepoStatus] = [:]

    /// repoId -> 私有知识库状态。
    ///
    /// 列表筛选需要把“没有 repo_notes 行”视为未入库；因此字典只保存显式状态，
    /// 读取时统一用 `.outsideLibrary` 兜底，和数据库 `NOT EXISTS in_library` 语义一致。
    private(set) var libraryStateMap: [Int64: LibraryState] = [:]

    /// `RepoListView` 渲染 row 时读取本方法填充 `RepoCardViewData.readStatus`。
    ///
    /// 没在 statusMap 里的 repoId 返回 `.unread`（implicit unread）——
    /// 这与 `applyView()` 状态过滤的 `statusMap[id] ?? .unread` 默认行为一致：
    /// `repo_notes` 表没行 == 用户从没打开过详情页 == 未读。
    ///
    /// 该方法只在 Manage 列表 row 渲染时调用，4 场景中只有 Manage 在用，
    /// 因此可以安全返回非 nil（trending/weekly/activity 不走本路径）。
    func readStatus(for repoId: Int64) -> RepoStatus {
        statusMap[repoId] ?? .unread
    }

    func libraryState(for repoId: Int64) -> LibraryState {
        libraryStateMap[repoId] ?? .outsideLibrary
    }

    /// 知识库状态写入成功后的本地同步入口。
    ///
    /// Repository 成功后才调用这里，避免乐观更新。知识库列表有 SWR 缓存，任何
    /// libraryState 变化都必须先失效相关缓存；否则用户从其它页面加入知识库后再点
    /// Sidebar「知识库」，会命中旧缓存，必须手动刷新才看到新卡片。
    func applyLibraryStateChange(repoId: Int64, state: LibraryState) {
        invalidateLibraryDerivedCaches()
        let didChange = libraryStateMap[repoId] != state
        libraryStateMap[repoId] = state
        guard didChange || selectionNeedsReloadAfterLibraryStateChange else { return }
        guard selectionNeedsReloadAfterLibraryStateChange else { return }
        reloadOrApplyCurrentManageView()
    }

    /// 清理所有直接依赖 `libraryState == .inLibrary` 的列表缓存。
    ///
    /// `.library` 是 Sidebar 基础分类；`.smartCollection(.library)` 是原系统集合入口；
    /// `.smartCollection(.outsideLibraryStars)` 的结果与入库状态相反，也必须同步失效。
    private func invalidateLibraryDerivedCaches() {
        listCache.removeValue(forKey: .library)
        listCache.removeValue(forKey: .smartCollection(.library))
        listCache.removeValue(forKey: .smartCollection(.outsideLibraryStars))
    }

    private var selectionNeedsReloadAfterLibraryStateChange: Bool {
        if effectiveGlobalFilterState.libraryFilter != .all { return true }
        switch selection {
        case .library, .smartCollection(.library), .smartCollection(.outsideLibraryStars):
            return true
        default:
            return false
        }
    }

    /// 详情页修改 status 后由 `NotificationCenter.repoStatusDidChange` 触发，
    /// 局部更新 statusMap 让 row 角标即时刷新。
    ///
    /// 单条 dict 写入是 O(1) 的；不调 `applyView()` 因为状态过滤未生效时（statusFilter == nil）
    /// 仅角标可见性变，List 的 items 序列不变；若 statusFilter == status，需要 applyView
    /// 让该 row 进入 / 退出过滤集合 —— 这里统一调 applyView，让逻辑更直观。
    fileprivate func applyStatusChange(repoId: Int64, status: RepoStatus) {
        guard statusMap[repoId] != status else { return }
        statusMap[repoId] = status
        // 未启用状态过滤时，只需要让 row 角标刷新；重查分页列表反而可能把尚未落库的
        // 通知状态覆盖回旧值。只有状态过滤生效时，才需要重新计算该 repo 是否仍可见。
        guard effectiveGlobalFilterState.statusFilter != nil else { return }
        // R-07：详情页改 status 不应抢用户滚动位置，传 resetPage: false。
        if isDatabasePagingActive {
            Task { [weak self] in
                await self?.reloadItems(forceRefresh: true)
            }
        } else {
            applyView(resetPage: false)
        }
    }

    /// 订阅 `.repoStatusDidChange` 通知，让详情页改 status 后主列表角标即时刷新（v2，2026-06-12）。
    ///
    /// **调用方**：`RepoListView` 在 `.task` 里调用，与 view lifetime 绑定（view 退出 task cancel）。
    /// **关键约束**：
    /// - for-await-in 是 AsyncSequence 标准模式（与 `RepoNotesSection` 监听 `.readmeDidLoad` 同源）
    /// - Task.isCancelled 保证 view 退出后立即跳出循环
    /// - userInfo 解析失败（payload 不全）则忽略；不抛错（避免一次坏 post 中断整个 observer）
    /// - 用 `RepoStatus.parse(_:)` 保证 v1 旧值兼容（理论上发射方都用 v2 值，但守一手）
    func observeRepoStatusChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoStatusDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoId = note.userInfo?["repoId"] as? Int64,
                  let statusRaw = note.userInfo?["status"] as? String else { continue }
            let status = RepoStatus.parse(statusRaw)
            applyStatusChange(repoId: repoId, status: status)
        }
    }

    /// 订阅 `.repoLibraryStateDidChange`，把所有入口的知识库状态变化收口到同一条刷新链。
    ///
    /// 事件由 Repository 在写库成功后发出；这里负责更新本地 map、失效知识库相关缓存、
    /// 刷新 Sidebar 计数，并在当前列表受影响时重查当前页。
    ///
    /// **必须**在 `HomeView` 生命周期订阅，不能挂在中栏 `List` 上——空库时空态没有 List，
    /// RAG / Search Center 入库后 Sidebar「知识库」数量就永远停在 0。
    func observeRepoLibraryStateChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoId = note.userInfo?["repoId"] as? Int64,
                  let raw = note.userInfo?["libraryState"] as? String else { continue }
            applyLibraryStateChange(repoId: repoId, state: LibraryState.parse(raw))
            await refreshSidebar()
        }
    }

    /// 一次跨窗口跳转对应一份临时筛选；anchor 约束它只能活在发起跳转的 Sidebar 分类。
    struct TemporaryGlobalFilterSession: Equatable {
        let requestID: UUID
        let anchorSelection: SidebarItem
        let filters: GlobalRepoFilterState
    }

    private(set) var temporaryGlobalFilterSession: TemporaryGlobalFilterSession?

    /// 用户持久筛选的内存镜像。临时会话永远不改这里，因此既有 `.onChange` 不会误写设置。
    var persistentGlobalFilterState: GlobalRepoFilterState {
        GlobalRepoFilterState(
            hideArchived: hideArchived,
            hideForks: hideForks,
            statusFilter: statusFilter,
            starFilter: starFilter,
            libraryFilter: libraryFilter,
            repoLanguageFilter: repoLanguageFilter,
            globalFilterLanguages: globalFilterLanguages,
            wikiAvailabilityFilter: wikiAvailabilityFilter,
            healthAvailabilityFilter: healthAvailabilityFilter,
            openSSFAvailabilityFilter: openSSFAvailabilityFilter
        )
    }

    /// 列表查询和 Toolbar 统一读取本值，保证“临时筛选已生效”在数据与 UI 上没有双轨。
    var effectiveGlobalFilterState: GlobalRepoFilterState {
        temporaryGlobalFilterSession?.filters ?? persistentGlobalFilterState
    }

    /// 派生：当前是否有任何过滤器生效（toolbar 显示徽标用）。
    var hasActiveFilter: Bool {
        let filters = effectiveGlobalFilterState
        return filters.hideArchived
            || filters.hideForks
            || filters.statusFilter != nil
            || filters.starFilter != .all
            || filters.libraryFilter != .all
            || filters.repoLanguageFilter != .all
            || !filters.globalFilterLanguages.isEmpty
            || filters.wikiAvailabilityFilter != .unknown
            || filters.healthAvailabilityFilter != .unknown
            || filters.openSSFAvailabilityFilter != .unknown
    }

    /// 跨窗口钻取只替换“当前有效筛选”，不写持久字段；重复点击同一数字也用 requestID 更新会话身份。
    func applyTemporaryGlobalFilters(
        _ filters: GlobalRepoFilterState,
        requestID: UUID,
        anchorSelection: SidebarItem
    ) {
        let previous = effectiveGlobalFilterState
        temporaryGlobalFilterSession = TemporaryGlobalFilterSession(
            requestID: requestID,
            anchorSelection: anchorSelection,
            filters: filters
        )
        if effectiveGlobalFilterState != previous {
            reloadOrApplyCurrentManageView()
        }
    }

    /// Sidebar 离开临时会话的锚点后恢复用户持久筛选。
    func clearTemporaryGlobalFiltersIfNeeded(for selection: SidebarItem) {
        guard let session = temporaryGlobalFilterSession,
              session.anchorSelection != selection else { return }
        clearTemporaryGlobalFilters()
    }

    func clearTemporaryGlobalFilters() {
        guard temporaryGlobalFilterSession != nil else { return }
        let previous = effectiveGlobalFilterState
        temporaryGlobalFilterSession = nil
        if effectiveGlobalFilterState != previous {
            reloadOrApplyCurrentManageView()
        }
    }

    /// Toolbar 的任何主动选择都代表用户接管：先结束临时会话，再修改并持久化真实筛选。
    func setGlobalFilterFromUser<Value>(
        _ keyPath: WritableKeyPath<GlobalRepoFilterState, Value>,
        to value: Value
    ) {
        var filters = persistentGlobalFilterState
        filters[keyPath: keyPath] = value
        applyPersistentGlobalFilterState(filters)
    }

    /// 重置所有全局筛选条件到默认值。
    ///
    /// 全局筛选工具栏「重置」按钮走这里。设置侧也同步清对应偏好。
    func resetAllFilters() {
        applyPersistentGlobalFilterState(.neutral)
    }

    /// 批量写入真实筛选时只触发一次重查，避免十个 didSet 依次启动十份分页任务。
    private func applyPersistentGlobalFilterState(_ filters: GlobalRepoFilterState) {
        let previous = effectiveGlobalFilterState
        isApplyingGlobalFilterState = true
        temporaryGlobalFilterSession = nil
        hideArchived = filters.hideArchived
        hideForks = filters.hideForks
        statusFilter = filters.statusFilter
        starFilter = filters.starFilter
        libraryFilter = filters.libraryFilter
        repoLanguageFilter = filters.repoLanguageFilter
        globalFilterLanguages = filters.globalFilterLanguages
        wikiAvailabilityFilter = filters.wikiAvailabilityFilter
        healthAvailabilityFilter = filters.healthAvailabilityFilter
        openSSFAvailabilityFilter = filters.openSSFAvailabilityFilter
        isApplyingGlobalFilterState = false

        if effectiveGlobalFilterState != previous {
            reloadOrApplyCurrentManageView()
        }
    }

    // MARK: - 依赖

    /// D-01：依赖协议而非具体 struct，便于单测注入 Mock。
    private let repository: any RepoRepositoryProtocol

    /// W4 A6：Sidebar Tags 段 + 按 tag 过滤需要这两个 repo。
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let githubStarListRepository: (any GitHubStarListRepositoryProtocol)?

    /// W4-4 D3：按状态过滤需要 repoNoteRepository.fetchStatusMap。
    private let repoNoteRepository: any RepoNoteRepositoryProtocol

    /// Repo Health 快照用于 Smart Collections 的 Needs Review / High Value 等集合。
    /// 可选是为了不破坏既有单测构造；缺失时集合按 repo 元数据保守降级。
    private let repoHealthRepository: (any RepoHealthRepositoryProtocol)?
    private let releaseRepository: (any ReleaseRepositoryProtocol)?
    private let releaseSubscriptionRepository: (any ReleaseSubscriptionRepositoryProtocol)?
    private let openSSFScoreRepository: (any OpenSSFScoreRepositoryProtocol)?
    private let smartCollectionRepository: (any SmartCollectionRepositoryProtocol)?

    /// 当前用户智能集合的规则快照。进入非用户集合时清空，避免旧规则污染普通列表。
    private var activeUserSmartCollectionRule: SmartCollectionRule?

    /// hydrate 批量写入 toolbar 字段时抑制 filter didSet 触发的 applyView。
    private var isHydratingManageFilters = false

    /// 用户接管临时筛选时需要一次性回写完整持久快照；批处理期间抑制各字段重复重查。
    private var isApplyingGlobalFilterState = false

    /// 用户智能集合 filter 所需的 Health / 笔记上下文；进入集合时构建，离开时清空。
    private var smartCollectionFilterContext: SmartCollectionRuleFilterContext?

    /// W6 AI：语义搜索服务。测试可传 nil，生产由 AppDependencies 注入。
    private let semanticSearchService: SemanticSearchService?

    /// D-05：当前 in-flight 的 reloadItems 任务，新调用进来先 cancel 旧的，
    /// 防止"快速切 sidebar 时旧查询结果覆盖新结果"的 race。
    /// 参考 `ReadmeViewModel.currentTask` 的相同模式。
    private var currentReloadTask: Task<Void, Never>?

    /// 预取任务：hover 触发，提前加载相邻分类数据。
    private var prefetchTask: Task<Void, Never>?

    /// 从同步入口派发出的列表动作。
    ///
    /// `sortOption` / filter didSet 与 `loadMoreIfNeeded()` 都是同步方法，但数据库分页
    /// 必须异步执行。单独保存这层 Task，测试才能等待“动作本身已进入 reload”这段时间窗。
    private var currentListActionTask: Task<Void, Never>?

    init(
        repository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        githubStarListRepository: (any GitHubStarListRepositoryProtocol)? = nil,
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        repoHealthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        releaseRepository: (any ReleaseRepositoryProtocol)? = nil,
        releaseSubscriptionRepository: (any ReleaseSubscriptionRepositoryProtocol)? = nil,
        openSSFScoreRepository: (any OpenSSFScoreRepositoryProtocol)? = nil,
        smartCollectionRepository: (any SmartCollectionRepositoryProtocol)? = nil,
        semanticSearchService: SemanticSearchService? = nil
    ) {
        self.repository = repository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.githubStarListRepository = githubStarListRepository
        self.repoNoteRepository = repoNoteRepository
        self.repoHealthRepository = repoHealthRepository
        self.releaseRepository = releaseRepository
        self.releaseSubscriptionRepository = releaseSubscriptionRepository
        self.openSSFScoreRepository = openSSFScoreRepository
        self.smartCollectionRepository = smartCollectionRepository
        self.semanticSearchService = semanticSearchService
    }

    // MARK: - 公开 action

    /// D-30 配套（2026-06-13）：账号切换时清空所有与登录身份强绑定的 in-memory 状态。
    ///
    /// **为什么需要这个方法**：
    /// D-30 在 `AppDependencies.switchUserDatabase(to:)` 里把 `DatabaseManager.currentPool`
    /// 切到了新用户的 `users/<newId>/starcat.sqlite`，**DB 层物理隔离已经完成**。
    /// 但 `HomeViewModel` 是个 `@Observable` 长生命周期对象（由 `HomeView` 用 `@State`
    /// 持有，跨账号切换不重建），它持有的 in-memory 状态 —— `listCache` /
    /// `items` / Sidebar 计数 / `statusMap` / `libraryStateMap` / `tags` / `repoTagsMap` —— 仍然是
    /// **旧账号的快照**。
    ///
    /// 不主动清这些缓存 → 表现为「退出 A 用 B 登录，看到的还是 A 的列表」：
    /// 1. `listCache[.allStars]` 5min TTL 内 → `HomeView.task(id: viewModel.selection)`
    ///    内 `guard !viewModel.hasCachedItems else { return }` 直接 short-circuit；
    /// 2. 即便 selection 不在 listCache 里，`statusMap` / `repoTagsMap` 等映射
    ///    在 `applyView()` 时仍按旧账号数据染色；
    /// 3. Sidebar 行数（`totalCount` / `untaggedCount` / `languageStats` / `tags`）
    ///    全是旧账号的，新账号看到的导航全错。
    ///
    /// **调用时机**：`HomeView.handleAuthenticatedEntry` 在**真换账号**路径调用。
    /// 会话恢复（`oldUserID == nil`）不调用——进程内无旧账号内存快照。
    ///
    /// **清空的字段（与账号强绑定）**：列表与 Sidebar 全套数据 + 选择/搜索状态。
    ///
    /// **保留的字段（用户级偏好，跨账号共享）**：
    /// - `sortOption` / `hideArchived` / `hideForks` / `statusFilter` / `libraryFilter` / `smartSearchMode`
    ///   —— 这些 4 个偏好从 `AppSettings` 同步进来，**`AppSettings` 是跨账号全局的**
    ///   （NSUbiquitousKeyValueStore / UserDefaults），所以在 viewModel 这一层
    ///   也保留这些值，不需要重置。
    /// - `selection` —— 由 `HomeView` 在 onChange 内单独处理（登入恢复 saved
    ///   manage selection / 登出切到 trending），本方法**不动 selection**，
    ///   避免和 HomeView 的赋值打架。
    ///
    /// **关键约束**（已踩过的坑）：
    /// 1. 必须在 `HomeView` 切 `viewModel.selection` **之前**调，否则 selection 的
    ///    didSet 会先用旧 listCache 做 eager cache load（见上方 selection 字段
    ///    didSet line 66-75）→ 旧数据先闪一帧再被覆盖。
    /// 2. `currentReloadTask` / `prefetchTask` 必须 `.cancel()` —— 旧账号 DB pool
    ///    虽然已被 D-30 切走，但旧 task 内的 `try await database.writer.read` 在
    ///    切换瞬间可能正持有旧 pool 的 read transaction（GRDB 内部读连接池）。
    ///    cancel 后旧 task 的 `Repo` 结果即便回来也由 `applyView()` 的 race 防护
    ///    路径丢弃（reloadItems 实现内的 task 身份对比）。
    /// 3. `selectedTagIds = []` 必须放在 `repoTagsMap.removeAll()` **之后**，
    ///    避免 didSet 触发的 `applyView()` 用空 `repoTagsMap` 配旧 `rawItems` 渲一帧。
    ///    实际上整段 reset 跑完 SwiftUI 才会触发一次 body 重算（`@Observable` 合批），
    ///    但顺序仍按 "DB 上游 → UI 下游" 写，便于读代码的人理解。
    /// 4. `isLoading = true` 强制开骨架屏 —— 防止"selection 不变 + listCache 清空"
    ///    的 corner case 下 UI 闪现一帧空列表（详见 HomeView 那边的注释）。
    func resetAllStateForUserSwitch() {
        currentReloadTask?.cancel()
        currentReloadTask = nil
        currentListActionTask?.cancel()
        currentListActionTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil

        listCache.removeAll()
        rawItems = []
        statusMap = [:]
        libraryStateMap = [:]
        repoTagsMap = [:]
        semanticHitMap = [:]
        temporaryGlobalFilterSession = nil
        selectedTagIds = []
        repoLanguageFilter = .all

        items = []
        // R-07：客户端分页全套字段也要复位，避免新账号沿用旧账号的页位置 / hasMore
        filteredSorted = []
        visibleRepoTotalCount = 0
        currentPage = 1
        hasMore = false
        itemsRevision &+= 1

        totalCount = 0
        untaggedCount = 0
        libraryCount = 0
        languageStats = []
        tags = []
        tagCounts = [:]
        githubStarLists = []
        githubStarListCounts = [:]
        githubStarListUngroupedCount = 0
        userSmartCollections = []
        releaseSubscriptionCount = 0

        selectedRepoID = nil
        shouldScrollSelectedRepoIntoView = false
        searchQuery = ""
        searchSubmissionID &+= 1
        semanticSearchScope = .starred

        loadError = nil
        isRefreshing = false
        isSemanticIndexing = false
        isLoading = true
    }

    func submitSearch(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        semanticHitMap = [:]
        searchSubmissionID += 1
    }

    /// 测试专用：等待当前列表查询完成。
    ///
    /// 普通 Manage 分类的筛选/排序会异步走数据库分页；测试需要一个明确同步点，
    /// 避免在 didSet 刚派发 Task 后立即断言旧 items。
    func awaitPendingListReloadForTesting() async {
        await currentListActionTask?.value
        await currentReloadTask?.value
    }

    /// Manage 筛选/排序状态变化后的刷新入口。
    ///
    /// 普通列表走数据库分页后，继续调用 `applyView()` 只会重排当前已加载页，
    /// 不能得到“全量排序后的第一页”。因此这里按模式分流：普通列表重查第一页，
    /// 智能集合/语义搜索等复杂路径仍走旧的内存派生。
    private func reloadOrApplyCurrentManageView() {
        guard let scope = currentRepoListScopeForDatabasePaging(), !isSearching else {
            currentListActionTask?.cancel()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.refreshHealthSortSnapshotsIfNeeded(for: self.rawItems)
                await self.refreshOpenSSFSortScoresIfNeeded(for: self.rawItems)
                guard !Task.isCancelled else { return }
                self.applyView()
            }
            currentListActionTask = task
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.reloadDatabasePagedItems(scope: scope, reason: .reset)
        }
        currentListActionTask = task
    }

    /// 刷新 Sidebar 数据（counts + language stats）。
    /// 通常在 onAppear 或 sync 完成后调用。
    func refreshSidebar() async {
        do {
            async let total = repository.starredCount()
            async let untagged = repository.fetchUntagged().count
            async let library = repository.fetchListCount(scope: .library, filters: .empty)
            async let langs = repository.languageStats()
            async let knowledgeLangs = repository.knowledgeLanguageStats()
            async let tagsResult = tagRepository.fetchAll()
            async let tagCountsResult = repoTagRepository.repoCountsByTag()
            async let githubListsResult = fetchGitHubStarLists()
            async let githubListCountsResult = fetchGitHubStarListCounts()
            async let githubUngroupedCountResult = fetchGitHubStarListUngroupedCount()
            async let smartCollectionsResult = fetchUserSmartCollections()
            async let releaseSubscriptionCountResult = fetchReleaseSubscriptionCount()
            // HOM-179：一并刷新 repo→tagIds 映射，让 selectedTagIds 多选过滤实时生效。
            // 与 sidebar 其他统计同步刷新，避免新增/删除 tag 后 wall 多选还按旧映射过滤。
            async let tagAssignmentsResult = repoTagRepository.fetchAllTagAssignments()

            self.totalCount = try await total
            self.untaggedCount = try await untagged
            self.libraryCount = try await library
            self.languageStats = try await langs
            self.knowledgeLanguageStats = try await knowledgeLangs
            self.tags = try await tagsResult
            self.tagCounts = try await tagCountsResult
            self.githubStarLists = try await githubListsResult
            self.githubStarListCounts = try await githubListCountsResult
            self.githubStarListUngroupedCount = try await githubUngroupedCountResult
            self.userSmartCollections = try await smartCollectionsResult
            self.releaseSubscriptionCount = try await releaseSubscriptionCountResult
            let assignments = try await tagAssignmentsResult
            self.repoTagsMap = assignments.mapValues { Set($0.map(\.id)) }

            // 标签被删除后，如果还在 selectedTagIds 里，过滤会变空集；这里主动收敛。
            let validTagIds = Set(self.tags.map(\.id))
            let stale = self.selectedTagIds.subtracting(validTagIds)
            if !stale.isEmpty {
                self.selectedTagIds.subtract(stale) // didSet 会触发 applyView
            } else if !self.selectedTagIds.isEmpty {
                // 即使 id 没变，repoTagsMap 内容可能变（刚刚打/卸标签）→ 主动 applyView
                // R-07：refreshSidebar 是后台数据刷新（非用户主动 sort/filter），保用户滚动位置
                self.applyView(resetPage: false)
            }
        } catch {
            AppLog.database.error("refreshSidebar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 外部场景（Search / Explore / Activity）完成 Star/Unstar 后的统一刷新入口。
    ///
    /// Explore 会把 `selection` 切到 `.trending`，这时直接调用 `reloadItems()` 只会刷新
    /// Trending 占位列表，切回 Starred 时仍可能命中旧的 Manage 缓存。这里先清掉所有
    /// Star 派生列表缓存；如果当前 selection 仍是 Manage 范畴，再立即重拉当前列表。
    func refreshAfterExternalStarChange() async {
        listCache.removeAll()
        await refreshSidebar()

        guard !selection.isTrending else { return }
        await reloadItems(forceRefresh: true)
    }

    func userSmartCollection(id: String) -> UserSmartCollection? {
        userSmartCollections.first { $0.id == id }
    }

    /// 返回某个 repo 已绑定的用户标签，供 Smart Collections 右栏卡片做只读展示。
    ///
    /// 这里故意不暴露 `repoTagsMap` 本体：右栏只需要显示名称 / 颜色 / 图标，
    /// 不应该获得可变映射或依赖内部 tagId 集合结构，避免浏览面板反向污染筛选状态。
    func tags(for repoId: Int64) -> [Tag] {
        let ids = repoTagsMap[repoId] ?? []
        guard !ids.isEmpty else { return [] }
        return tags
            .filter { ids.contains($0.id) }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }

    /// 规则摘要格式化上下文（tag id → 显示名）。
    func smartCollectionSummaryContext() -> SmartCollectionRuleSummary.Context {
        SmartCollectionRuleSummary.Context.from(tags: tags)
    }

    /// 用户智能集合的完整生效规则：Manage toolbar 快照 + DB 存盘的高阶 predicate。
    ///
    /// **为什么必须 merge**：
    /// - toolbar 只覆盖 scope / 搜索 / Manage 基础筛选；
    /// - Health / OpenSSF / Release 等 advanced 字段只存在 DB `ruleJSON` 里。
    /// - `buildSmartCollectionFilterContext` 与 `SmartCollectionRuleFilter` 必须共用同一份
    ///   merged rule，否则会出现「总览 countRepos=60、列表 filter 后=0」：
    ///   context 按 toolbar（无 healthScoreMin）跳过 Health 加载，filter 却按 merged 规则
    ///   要求 health 分 → 空 snapshots 把全部 repo 滤掉。
    private func effectiveUserSmartCollectionRule() -> SmartCollectionRule? {
        guard let stored = activeUserSmartCollectionRule else { return nil }
        if let toolbar = makeRuleFromCurrentManageFilters() {
            return toolbar.mergingAdvanced(from: stored)
        }
        return stored
    }

    /// 进入用户智能集合后，把 DB 规则灌进 Manage toolbar，让列表与控件一致。
    ///
    /// 刻意不同步 AppSettings：离开集合时不应把 draft 写进全局默认筛选。
    func hydrateManageFilters(from rule: SmartCollectionRule) {
        isHydratingManageFilters = true
        defer { isHydratingManageFilters = false }

        hideArchived = rule.hideArchived
        hideForks = rule.hideForks
        statusFilter = rule.status
        repoLanguageFilter = .all
        selectedTagIds = Set(rule.selectedTagIDs)
        sortOption = rule.sortOption
        smartSearchMode = rule.searchMode
        searchQuery = rule.query ?? ""
    }

    /// 统计规则命中仓库数（scope 查询 + 完整 rule filter）。
    func countRepos(matching rule: SmartCollectionRule) async throws -> Int {
        let (repos, semanticHitMap) = try await fetchRepos(matching: rule)
        let context = try await buildSmartCollectionFilterContext(
            for: repos,
            rule: rule,
            semanticHitMap: semanticHitMap
        )
        return SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: context).count
    }

    func buildSmartCollectionFilterContext(
        for repos: [Repo],
        rule: SmartCollectionRule? = nil,
        semanticHitMap: [Int64: SemanticSearchHit] = [:]
    ) async throws -> SmartCollectionRuleFilterContext {
        async let statusMap = repoNoteRepository.fetchAllStatusMap()
        async let noteIDs = repoNoteRepository.fetchRepoIdsWithNonEmptyContent()
        let repoIds = repos.map(\.id)

        let shouldLoadHealth = rule == nil || rule?.needsHealthSnapshots == true
        let health: [Int64: RepoHealthSnapshot]
        if let repoHealthRepository, !repos.isEmpty, shouldLoadHealth {
            health = try await repoHealthRepository.snapshots(for: repoIds)
        } else {
            health = [:]
        }

        let openSSFScores: [Int64: Double]
        if rule?.needsOpenSSFContext == true, let openSSFScoreRepository, !repoIds.isEmpty {
            let records = try await openSSFScoreRepository.records(for: repoIds)
            openSSFScores = records.compactMapValues { record in
                guard record.fetchStatus == .success, let score = record.aggregateScore else { return nil }
                return score
            }
        } else {
            openSSFScores = [:]
        }

        let latestReleasePublishedAt: [Int64: String]
        if rule?.needsReleaseContext == true, let releaseRepository, !repoIds.isEmpty {
            latestReleasePublishedAt = try await releaseRepository.latestPublishedAtByRepoIds(repoIds)
        } else {
            latestReleasePublishedAt = [:]
        }

        return SmartCollectionRuleFilterContext(
            statusMap: try await statusMap,
            repoTagsMap: repoTagsMap,
            healthSnapshots: health,
            repoIdsWithNotes: try await noteIDs,
            openSSFScores: openSSFScores,
            latestReleasePublishedAt: latestReleasePublishedAt,
            semanticHitMap: semanticHitMap,
            now: Date()
        )
    }

    func renameUserSmartCollection(id: String, name: String) async throws {
        guard let smartCollectionRepository,
              var collection = try await smartCollectionRepository.find(id: id) else {
            throw DatabaseError.openFailed(underlying: NSError(
                domain: "SmartCollection",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: String.l10n("smartCollections.error.missingRule")]
            ))
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collection.name = trimmed
        collection.updatedAt = ISO8601DateFormatter.shared.string(from: Date())
        try await smartCollectionRepository.update(collection)
        await refreshSidebar()
    }

    func updateUserSmartCollectionRule(id: String, rule: SmartCollectionRule) async throws {
        guard let smartCollectionRepository,
              var collection = try await smartCollectionRepository.find(id: id) else {
            throw DatabaseError.openFailed(underlying: NSError(
                domain: "SmartCollection",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: String.l10n("smartCollections.error.missingRule")]
            ))
        }
        collection.ruleJSON = try SmartCollectionRule.encode(rule)
        collection.updatedAt = ISO8601DateFormatter.shared.string(from: Date())
        try await smartCollectionRepository.update(collection)
        activeUserSmartCollectionRule = rule
        await refreshSidebar()
        await reloadItems(forceRefresh: true)
    }

    /// 把当前 Manage 筛选快照转换成可保存的用户智能集合规则。
    ///
    /// 在用户智能集合内 scope 固定为已保存规则，toolbar 其余字段可编辑后更新。
    func makeRuleFromCurrentManageFilters() -> SmartCollectionRule? {
        let scope: SmartCollectionRule.Scope
        switch selection {
        case .allStars, .allLanguages:
            scope = .allStars
        case .untagged:
            scope = .untagged
        case .language(let language):
            scope = .language(language)
        case .tag(let id):
            scope = .tag(id)
        case .userSmartCollection:
            guard let activeScope = activeUserSmartCollectionRule?.scope else { return nil }
            scope = activeScope
        case .library, .trending, .smartCollectionsHome, .smartCollection, .githubStarList, .githubStarListUngrouped:
            return nil
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = effectiveGlobalFilterState
        return SmartCollectionRule(
            scope: scope,
            query: trimmedQuery.isEmpty ? nil : trimmedQuery,
            searchModeRaw: smartSearchMode.rawValue,
            statusRaw: filters.statusFilter?.rawValue,
            selectedTagIDs: selectedTagIds.sorted(),
            hideArchived: filters.hideArchived,
            hideForks: filters.hideForks,
            sortRaw: sortOption.rawValue
        )
    }

    private func fetchUserSmartCollections() async throws -> [UserSmartCollection] {
        guard let smartCollectionRepository else { return [] }
        return try await smartCollectionRepository.fetchAll()
    }

    private func fetchGitHubStarLists() async throws -> [GitHubStarList] {
        guard let githubStarListRepository else { return [] }
        return try await githubStarListRepository.fetchAllLists()
    }

    private func fetchGitHubStarListCounts() async throws -> [String: Int] {
        guard let githubStarListRepository else { return [:] }
        return try await githubStarListRepository.repoCountsByList()
    }

    private func fetchGitHubStarListUngroupedCount() async throws -> Int {
        guard let githubStarListRepository else { return 0 }
        return try await githubStarListRepository.ungroupedRepoCount()
    }

    private func fetchReleaseSubscriptionCount() async throws -> Int {
        guard let releaseSubscriptionRepository else { return 0 }
        return try await releaseSubscriptionRepository.fetchActive().count
    }

    private func fetchUserSmartCollectionRule(id: String) async throws -> SmartCollectionRule {
        guard let smartCollectionRepository,
              let collection = try await smartCollectionRepository.find(id: id),
              let rule = collection.rule else {
            throw DatabaseError.openFailed(underlying: NSError(
                domain: "SmartCollection",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: String.l10n("smartCollections.error.missingRule")]
            ))
        }
        return rule
    }

    /// 内置集合「未入库 Stars」：GitHub 已 star，但尚未加入 Starcat 知识库。
    ///
    /// `repo_notes` 没有行时按 `.outsideLibrary` 处理，和全局 library filter 的语义一致。
    private func fetchOutsideLibraryStars() async throws -> [Repo] {
        let repos = try await repository.fetchAllStarred()
        let libraryStateMap = try await repoNoteRepository.fetchAllLibraryStateMap()
        return repos.filter { repo in
            (libraryStateMap[repo.id] ?? .outsideLibrary) != .inLibrary
        }
    }

    /// 当前 selection 是否可走数据库分页主路径。
    ///
    /// 第一阶段只覆盖最常用且语义直接映射到 SQL 的 Manage 分类。用户智能集合、内置
    /// High Value/Needs Review 等仍依赖额外上下文，继续走旧的全量派生路径。
    private func currentRepoListScopeForDatabasePaging() -> RepoListScope? {
        // Wiki 状态目前来自磁盘 JSON 缓存，不在 SQLite repos 查询里。启用该筛选时先走
        // 内存路径，保证“有/无 Wiki”语义正确；后续若落库索引再恢复分页下推。
        guard effectiveGlobalFilterState.wikiAvailabilityFilter == .unknown else { return nil }

        switch selection {
        case .allStars, .allLanguages:
            return .allStars
        case .untagged:
            return .untagged
        case .library:
            return .library
        case .language(let language):
            return .language(language)
        case .tag(let tagID):
            return .tag(tagID)
        case .githubStarList(let listID):
            return .githubStarList(listID)
        case .githubStarListUngrouped:
            return .githubStarListUngrouped
        case .smartCollection(.library):
            return .library
        case .trending, .smartCollectionsHome, .smartCollection, .userSmartCollection:
            return nil
        }
    }

    private func currentRepoListFiltersForDatabasePaging() -> RepoListFilters {
        let filters = effectiveGlobalFilterState
        return RepoListFilters(
            hideArchived: filters.hideArchived,
            hideForks: filters.hideForks,
            status: filters.statusFilter,
            star: filters.starFilter,
            library: filters.libraryFilter,
            language: filters.repoLanguageFilter,
            selectedLanguages: Set(filters.globalFilterLanguages),
            wikiAvailability: filters.wikiAvailabilityFilter,
            healthAvailability: filters.healthAvailabilityFilter,
            openSSFAvailability: filters.openSSFAvailabilityFilter,
            selectedTagIDs: selectedTagIds
        )
    }

    /// Cmd+A 使用的全集快照。
    ///
    /// 数据库分页模式下不再持有 `filteredSorted` 全集，所以全选需要单独查轻量投影；
    /// 旧路径仍从 `filteredSorted` 构造，保持智能集合/语义搜索行为不变。
    func selectionSnapshotsForCurrentQuery() async -> [SelectionSnapshot] {
        guard let scope = currentRepoListScopeForDatabasePaging(), !isSearching else {
            return filteredSorted.map {
                SelectionSnapshot(ghRepoId: $0.id, owner: $0.owner, name: $0.name)
            }
        }
        let filters = currentRepoListFiltersForDatabasePaging()
        return (try? await repository.fetchListSelectionSnapshots(
            scope: scope,
            filters: filters,
            sort: sortOption
        )) ?? []
    }

    private func fetchRepos(matching rule: SmartCollectionRule) async throws -> (repos: [Repo], semanticHitMap: [Int64: SemanticSearchHit]) {
        let base: [Repo]
        switch rule.scope {
        case .allStars:
            base = try await repository.fetchAllStarred()
        case .untagged:
            base = try await repository.fetchUntagged()
        case .language(let language):
            base = try await repository.fetchByLanguage(language)
        case .tag(let tagID):
            base = try await repoTagRepository.fetchRepos(forTag: tagID)
        }

        guard let query = rule.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return (base, [:])
        }

        if rule.searchMode == .semantic {
            guard let semanticSearchService else {
                throw SemanticSearchError.missingAPIKey
            }
            let ftsHitIDs = Set((try await repository.searchFTS(query: query)).map(\.id))
            let hits = try await semanticSearchService.search(query: query, candidates: base, ftsHitIDs: ftsHitIDs)
            return (
                repos: hits.map(\.repo),
                semanticHitMap: Dictionary(uniqueKeysWithValues: hits.map { ($0.repo.id, $0) })
            )
        } else {
            let hitIDs = Set((try await repository.searchFTS(query: query)).map(\.id))
            return (base.filter { hitIDs.contains($0.id) }, [:])
        }
    }

    private func currentSemanticIndexScopeForSearch() -> SemanticIndexScope {
        if smartSearchMode == .semantic {
            return semanticSearchScope
        }
        if case .smartCollection(let kind) = selection, kind == .library {
            return .knowledge
        }
        if selection == .smartCollectionsHome {
            return .all
        }
        return .starred
    }

    private func fetchSearchCandidates(scope: SemanticIndexScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            let starred = try await repository.fetchAllStarred()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: [])
        case .knowledge:
            let knowledge = try await repository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: [], knowledge: knowledge)
        case .all:
            let starred = try await repository.fetchAllStarred()
            let knowledge = try await repository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: knowledge)
        }
    }

    private func searchFTS(query: String, scope: SemanticIndexScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            return try await repository.searchFTS(query: query)
        case .knowledge:
            return try await repository.searchKnowledgeFTS(query: query)
        case .all:
            let starred = try await repository.searchFTS(query: query)
            let knowledge = try await repository.searchKnowledgeFTS(query: query)
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: knowledge)
        }
    }

    // MARK: - HOM-179：标签墙多选 actions

    /// 切换某个 tag 在多选集合中的勾选状态。
    ///
    /// 实现顺序很关键：**先**修正 selection、**再**写 selectedTagIds，让最终
    /// 一次 applyView 同时拿到对的 base set 和对的 filter，避免 SwiftUI 短暂渲染
    /// "untagged + selectedTagIds={tag1}"这种永远空集的过渡态。
    /// 关键约束：`Set.insert/remove` 走值语义；写回 `selectedTagIds` 时整个 Set
    /// 被替换，didSet 一定触发。
    func toggleSelectedTag(_ tagId: String) {
        var next = selectedTagIds
        if next.contains(tagId) {
            next.remove(tagId)
        } else {
            next.insert(tagId)
        }

        // 选中至少一个 tag 时，强制把 selection 退回到 .allStars，避免和 .tag(legacy) /
        // .untagged 形成"自相矛盾"组合：
        // - .untagged + selectedTagIds 永远空集，UX 反直觉
        // - .tag(legacy) + selectedTagIds 语义重叠（旧的单标签等价于 selectedTagIds = {legacy}）
        // 用户后续可显式切到 .language(...) 形成 AND 组合。
        if !next.isEmpty {
            switch selection {
            case .untagged, .library, .tag, .smartCollectionsHome, .smartCollection, .userSmartCollection, .githubStarList, .githubStarListUngrouped:
                selection = .allStars
            case .allStars, .allLanguages, .language, .trending:
                break
            }
        }

        selectedTagIds = next
    }

    /// 一键清空所有已选 tag。
    /// `Set` 已为空时 didSet 会被自身 guard 阻断，不会触发不必要的 applyView。
    func clearSelectedTags() {
        guard !selectedTagIds.isEmpty else { return }
        selectedTagIds = []
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
    func reloadItems(forceRefresh: Bool = false) async {
        #if DEBUG
        AppLog.ui.notice("[switch-cat] T1 reloadItems entered  +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
        #endif
        currentReloadTask?.cancel()

        if let scope = currentRepoListScopeForDatabasePaging(), !isSearching {
            let reason: DatabasePageReloadReason = (forceRefresh && isDatabasePagingActive)
                ? .refreshPreservingPage
                : .reset
            await reloadDatabasePagedItems(scope: scope, reason: reason)
            return
        }

        isDatabasePagingActive = false

        if selection == .smartCollectionsHome, !isSearching {
            rawItems = []
            filteredSorted = []
            visibleRepoTotalCount = 0
            items = []
            hasMore = false
            isLoading = false
            isRefreshing = false
            loadError = nil
            return
        }

        // HOM-46：stale-while-revalidate 优化。
        // 先检查缓存：若有且未过期，立即展示缓存，后台刷新。
        // 若无缓存，先显示 isLoading=true 直到首次数据到达。
        let isUserSmartCollectionSelection: Bool = {
            if case .userSmartCollection = selection { return true }
            return false
        }()
        let shouldUseListCache = !isSearching && !isUserSmartCollectionSelection
        let cached = shouldUseListCache ? listCache[selection] : nil
        let hasStaleCache = cached != nil

        if hasStaleCache {
            #if DEBUG
            AppLog.ui.notice("[switch-cat] T2 cache HIT, items=\(cached!.rawItems.count) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
            #endif
            // 有缓存：立即用缓存数据填充 UI，同时后台刷新
            if sortOption == .healthScoreDesc {
                await refreshHealthSortSnapshotsIfNeeded(for: cached!.rawItems)
            } else if sortOption == .openSSFScoreDesc {
                await refreshOpenSSFSortScoresIfNeeded(for: cached!.rawItems)
            }
            loadFromCache(cached!)
            if !forceRefresh && !cached!.isExpired {
                // 普通 Manage 分类切换的事实源就是内存缓存。这里直接返回，避免马上再跑一次
                // 700ms 级别的 DB 重查，并在结束时因为 isRefreshing=false 触发第二次整栏 body 重算。
                // 过期缓存不走这个分支，仍按 SWR 继续后台刷新，保证 5 分钟 TTL 有效。
                // 数据真实变化路径（同步完成、标签/状态修改、取消 Star）统一传 forceRefresh=true。
                if isRefreshing { isRefreshing = false }
                if loadError != nil { loadError = nil }
                #if DEBUG
                AppLog.ui.notice("[switch-cat] T3 cache fresh, skip bg fetch +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                #endif
                return
            }
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

            let outcome: Result<(repos: [Repo], semanticHitMap: [Int64: SemanticSearchHit]), Error>
            let fetchedStatusMap: [Int64: RepoStatus]
            let fetchedLibraryStateMap: [Int64: LibraryState]

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
                // status map 使用 `async let` 而非 `Task { }`：
                //   - async let 是结构化并发，作用域结束自动等待 / 传播取消
                //   - 与现有 race 防护（外层 Task.isCancelled 检查）天然兼容
                //   - 不需要额外 cancel 管理
                let fetchedTask: () async throws -> (repos: [Repo], semanticHitMap: [Int64: SemanticSearchHit]) = {
                    if self.isSearching {
                        if case .userSmartCollection = self.selection,
                           let scopedRule = self.makeRuleFromCurrentManageFilters() {
                            return try await self.fetchRepos(matching: scopedRule)
                        }
                        if self.smartSearchMode == .semantic {
                            guard let semanticSearchService = self.semanticSearchService else {
                                throw SemanticSearchError.missingAPIKey
                            }
                            let searchScope = self.currentSemanticIndexScopeForSearch()
                            // 2026-06-14 dong4j：先 FTS 拿命中 ID 集合，再调语义搜索（思路 1，C 加权）。
                            // FTS5 是本地 SQLite 查询，毫秒级零成本；ftsHitIDs 仅作排序加权信号
                            // 不做硬过滤，保住"语义同义但字面没匹"的纯向量召回能力。
                            let candidates = try await self.fetchSearchCandidates(scope: searchScope)
                            let ftsHits = try await self.searchFTS(query: self.searchQuery, scope: searchScope)
                            let ftsHitIDs = Set(ftsHits.map(\.id))
                            let hits = try await semanticSearchService.search(
                                query: self.searchQuery,
                                candidates: candidates,
                                ftsHitIDs: ftsHitIDs
                            )
                            return (
                                repos: hits.map(\.repo),
                                semanticHitMap: Dictionary(uniqueKeysWithValues: hits.map { ($0.repo.id, $0) })
                            )
                        } else {
                            let searchScope = self.currentSemanticIndexScopeForSearch()
                            return (repos: try await self.searchFTS(query: self.searchQuery, scope: searchScope), semanticHitMap: [:])
                        }
                    } else {
                        var repos: [Repo]
                        switch self.selection {
                        case .trending:
                            repos = [] // Placeholder for W7 Trending
                        case .allStars, .allLanguages:
                            repos = try await self.repository.fetchAllStarred()
                        case .untagged:
                            repos = try await self.repository.fetchUntagged()
                        case .library:
                            repos = try await self.repository.fetchKnowledgeRepos()
                        case .smartCollectionsHome:
                            repos = []
                        case .smartCollection(let kind):
                            if kind == .library {
                                repos = try await self.repository.fetchKnowledgeRepos()
                            } else if kind == .outsideLibraryStars {
                                repos = try await self.fetchOutsideLibraryStars()
                            } else if kind == .noTags {
                                repos = try await self.repository.fetchUntagged()
                            } else if kind == .using {
                                repos = try await self.repoNoteRepository.fetchRepos(byStatus: .using)
                            } else {
                                let all = try await self.repository.fetchAllStarred()
                                let snapshots = try await self.repoHealthRepository?.snapshots(for: all.map(\.id)) ?? [:]
                                repos = all.filter { repo in
                                    Self.matchesSmartCollection(
                                        repo: repo,
                                        health: snapshots[repo.id],
                                        status: nil,
                                        kind: kind
                                    )
                                }
                            }
                        case .userSmartCollection(let id):
                            let storedRule = try await self.fetchUserSmartCollectionRule(id: id)
                            self.activeUserSmartCollectionRule = storedRule
                            self.hydrateManageFilters(from: storedRule)
                            let fullRule = self.effectiveUserSmartCollectionRule() ?? storedRule
                            let result = try await self.fetchRepos(matching: fullRule)
                            self.smartCollectionFilterContext = try await self.buildSmartCollectionFilterContext(
                                for: result.repos,
                                rule: fullRule,
                                semanticHitMap: result.semanticHitMap
                            )
                            return result
                        case .language(let lang):
                            repos = try await self.repository.fetchByLanguage(lang)
                        case .tag(let tagId):
                            repos = try await self.repoTagRepository.fetchRepos(forTag: tagId)
                        case .githubStarList(let listId):
                            repos = try await self.repository.fetchListPage(
                                scope: .githubStarList(listId),
                                filters: self.currentRepoListFiltersForDatabasePaging(),
                                sort: self.sortOption,
                                limit: 100_000,
                                offset: 0
                            )
                        case .githubStarListUngrouped:
                            repos = try await self.repository.fetchListPage(
                                scope: .githubStarListUngrouped,
                                filters: self.currentRepoListFiltersForDatabasePaging(),
                                sort: self.sortOption,
                                limit: 100_000,
                                offset: 0
                            )
                        }

                        return (repos: repos, semanticHitMap: [:])
                    }
                }

                async let statusMapAsync: [Int64: RepoStatus] = self.repoNoteRepository.fetchAllStatusMap()
                async let libraryStateMapAsync: [Int64: LibraryState] = self.repoNoteRepository.fetchAllLibraryStateMap()

                let fetched = try await fetchedTask()
                fetchedStatusMap = (try? await statusMapAsync) ?? [:]
                fetchedLibraryStateMap = (try? await libraryStateMapAsync) ?? [:]

                outcome = .success(fetched)
            } catch {
                fetchedStatusMap = [:]
                fetchedLibraryStateMap = [:]
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
            case .success(let result):
                let fetched = result.repos
                self.semanticHitMap = result.semanticHitMap
                await self.refreshHealthSortSnapshotsIfNeeded(for: fetched)
                await self.refreshOpenSSFSortScoresIfNeeded(for: fetched)
                // 更新缓存（无论 UI 是否需要重渲染，都用最新数据替换 cache entry，
                // 让下次切回这个分类时拿到 freshest 数据）
                if shouldUseListCache {
                    self.listCache[self.selection] = CacheEntry(
                        rawItems: fetched,
                        statusMap: fetchedStatusMap,
                        libraryStateMap: fetchedLibraryStateMap,
                        cachedAt: Date()
                    )
                }

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
                let libraryIdentical = fetchedLibraryStateMap == self.libraryStateMap
                // 用户智能集合：rawItems ID 序列可能与 All Stars 相同，但 filter context / 规则不同，
                // 不能走静默跳过，否则 items 仍停留在上一分类的 filteredSorted（常见表现：空列表）。
                let mustReapplyView = isUserSmartCollectionSelection

                if idsIdentical && statusIdentical && libraryIdentical && !mustReapplyView {
                    // 静默更新底层引用（rawItems / statusMap 是 private 属性，不参与视图重建）。
                    // 不动 items / itemsRevision → 不触发 SwiftUI re-render，避免第二波动画。
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
                    self.libraryStateMap = fetchedLibraryStateMap
                    #if DEBUG
                    AppLog.ui.notice("[switch-cat] T6' bg fetch identical, skipped applyView +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                    #endif
                } else {
                    // 数据真的变了（同步刚结束 / 用户操作改了 status / R-07 firstPageWrittenAt 触发等）
                    // → 走完整 applyView，但 resetPage: false 保留用户滚动位置
                    // （preserveScrollPosition：A 收尾的"100 → 1800"切换对用户透明的关键）。
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
                    self.libraryStateMap = fetchedLibraryStateMap
                    self.applyView(resetPage: false)
                    #if DEBUG
                    AppLog.ui.notice("[switch-cat] T6 applyView done after bg fetch +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                    #endif
                }
            case .failure(let error):
                self.semanticHitMap = [:]
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("diagnostics.operation.loadStars"),
                    service: "Starcat"
                )
                self.loadError = friendly.message
                // 缓存加载已展示过的数据，失败不清理
                if self.rawItems.isEmpty {
                    self.items = []
                }
                AppLog.database.error("reloadItems failed: \(error.localizedDescription, privacy: .public)")
                friendly.record(category: "home", operation: "reloadItems", service: "local-database")
            }
        }

        currentReloadTask = task
        #if DEBUG
        AppLog.ui.info("[switch-cat] T4 bg task started, await begins +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
        #endif
        await task.value
    }

    /// 数据库分页加载意图。
    ///
    /// 分开建模是为了避免“滚动追加”和“整栏刷新”共用同一套状态写入：
    /// - `.append` 只追加下一页，不 bump `itemsRevision`，让 List 保持滚动上下文；
    /// - `.reset` 用于筛选/排序/首次进入，允许重建快照；
    /// - `.refreshPreservingPage` 用于同步完成后的后台刷新，保留已加载页数。
    private enum DatabasePageReloadReason: Equatable {
        case reset
        case append
        case refreshPreservingPage
    }

    /// 普通 Manage 分类的数据库分页加载。
    ///
    /// 核心约束：触底追加必须是真正的 `OFFSET + LIMIT`，不能重新查询并替换
    /// “已加载累计前缀”。否则数据量越大，SwiftUI 每次滚到底要 diff 的数组越长，
    /// 1800+ 条时就会出现滚动不顺滑甚至跳回顶部。
    private func reloadDatabasePagedItems(scope: RepoListScope, reason: DatabasePageReloadReason) async {
        currentReloadTask?.cancel()
        isDatabasePagingActive = true

        if reason == .reset {
            currentPage = 1
        }

        let isAppend = reason == .append
        let requestedLimit: Int
        let queryLimit: Int
        let queryOffset: Int
        if isAppend {
            requestedLimit = Self.pageSize
            queryLimit = Self.pageSize + 1
            queryOffset = items.count
        } else {
            requestedLimit = max(Self.pageSize, reason == .refreshPreservingPage ? items.count : Self.pageSize)
            queryLimit = requestedLimit + 1
            queryOffset = 0
        }
        let filters = currentRepoListFiltersForDatabasePaging()

        if items.isEmpty {
            isLoading = true
        } else if !isAppend {
            isRefreshing = true
        }
        loadError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if isAppend {
                    self.isDatabasePageAppendInFlight = false
                }
            }
            let result: Result<([Repo], [Int64: RepoStatus], [Int64: LibraryState]), Error>
            let countResult: Result<Int, Error>
            do {
                async let reposTask = self.repository.fetchListPage(
                    scope: scope,
                    filters: filters,
                    sort: self.sortOption,
                    limit: queryLimit,
                    offset: queryOffset
                )
                async let countTask = self.repository.fetchListCount(scope: scope, filters: filters)
                let rowsWithSentinel = try await reposTask
                let pageRows = Array(rowsWithSentinel.prefix(requestedLimit))
                // R-07.4：DB 分页路径只读取当前落到 UI 的 rows 的状态。
                // `fetchAllStatusMap()` 曾适合“全量 repos 已在内存”的旧路径；真实分页后每次 append
                // 都全表扫 repo_notes 会把滚动成本重新绑回用户数据总量。
                let visibleStatusIDs = pageRows.map(\.id)
                let pageStatusMap = (try? await self.repoNoteRepository.fetchStatusMap(repoIds: visibleStatusIDs)) ?? [:]
                let pageLibraryStateMap = (try? await self.repoNoteRepository.fetchLibraryStateMap(repoIds: visibleStatusIDs)) ?? [:]
                result = .success((rowsWithSentinel, pageStatusMap, pageLibraryStateMap))
                countResult = .success((try? await countTask) ?? self.visibleRepoTotalCount)
            } catch {
                result = .failure(error)
                countResult = .success(self.visibleRepoTotalCount)
            }

            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.isRefreshing = false
            if self.isGitHubStarListSwitchLoading {
                self.isGitHubStarListSwitchLoading = false
            }

            switch result {
            case .success(let (rowsWithSentinel, pageStatusMap, pageLibraryStateMap)):
                let pageRows = Array(rowsWithSentinel.prefix(requestedLimit))
                let nextHasMore = rowsWithSentinel.count > requestedLimit
                let queryTotalCount = (try? countResult.get()) ?? self.visibleRepoTotalCount

                if isAppend {
                    guard !pageRows.isEmpty else {
                        self.hasMore = false
                        self.visibleRepoTotalCount = queryTotalCount
                        return
                    }
                    self.items.append(contentsOf: pageRows)
                    self.rawItems = self.items
                    self.filteredSorted = self.items
                    self.visibleRepoTotalCount = queryTotalCount
                    self.hasMore = nextHasMore
                    self.currentPage = max(1, Int(ceil(Double(self.items.count) / Double(Self.pageSize))))
                    self.statusMap.merge(pageStatusMap) { _, new in new }
                    self.libraryStateMap.merge(pageLibraryStateMap) { _, new in new }
                } else {
                    let visibleRows = pageRows
                    let idsIdentical = visibleRows.count == self.items.count &&
                                       zip(visibleRows, self.items).allSatisfy { $0.id == $1.id }
                    self.rawItems = visibleRows
                    self.filteredSorted = visibleRows
                    self.visibleRepoTotalCount = queryTotalCount
                    self.items = visibleRows
                    self.hasMore = nextHasMore
                    self.currentPage = max(1, Int(ceil(Double(visibleRows.count) / Double(Self.pageSize))))
                    if !idsIdentical {
                        self.itemsRevision &+= 1
                    }
                    self.statusMap = pageStatusMap
                    self.libraryStateMap = pageLibraryStateMap
                }
                self.listCache.removeValue(forKey: self.selection)

                if let id = self.selectedRepoID, !self.filteredSorted.contains(where: { $0.id == id }) {
                    self.selectedRepoID = nil
                }
            case .failure(let error):
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("diagnostics.operation.loadStars"),
                    service: "Starcat"
                )
                self.loadError = friendly.message
                if self.items.isEmpty {
                    self.rawItems = []
                    self.filteredSorted = []
                    self.visibleRepoTotalCount = 0
                    self.hasMore = false
                }
                AppLog.database.error("reloadDatabasePagedItems failed: \(error.localizedDescription, privacy: .public)")
                friendly.record(category: "home", operation: "reloadDatabasePagedItems", service: "local-database")
            }
        }

        currentReloadTask = task
        await task.value
    }

    func semanticHit(for repoID: Int64) -> SemanticSearchHit? {
        semanticHitMap[repoID]
    }

    /// 手动刷新 active repo 的语义索引。
    ///
    /// 入口放在列表 toolbar；适合用户刚切换 embedding model 或大量同步后主动更新。
    /// active scope 固定为 starred 与知识库并集，避免未 star 但已入库的 repo 永远没有 embedding。
    func refreshSemanticIndex() async {
        guard let semanticSearchService else {
            loadError = SemanticSearchError.missingAPIKey.localizedDescription
            return
        }
        isSemanticIndexing = true
        defer { isSemanticIndexing = false }
        do {
            let repos = try await fetchSearchCandidates(scope: .all)
            try await semanticSearchService.refreshIndex(for: repos)
            if isSemanticSearching {
                await reloadItems(forceRefresh: true)
            }
        } catch {
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.refreshSemanticIndex"),
                service: "Starcat"
            )
            loadError = friendly.message
            AppLog.database.error("refreshSemanticIndex failed: \(error.localizedDescription, privacy: .public)")
            friendly.record(category: "home", operation: "refreshSemanticIndex", service: "semantic-search")
        }
    }

    /// 从缓存条目加载数据到 UI（立即展示，无加载指示）。
    private func loadFromCache(_ entry: CacheEntry) {
        self.rawItems = entry.rawItems
        self.statusMap = entry.statusMap
        self.libraryStateMap = entry.libraryStateMap
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
                    case .allStars, .allLanguages:
                        return try await self.repository.fetchAllStarred()
                    case .untagged:
                        return try await self.repository.fetchUntagged()
                    case .library:
                        return try await self.repository.fetchKnowledgeRepos()
                    case .smartCollectionsHome:
                        return nil
                    case .smartCollection(let kind):
                        if kind == .library {
                            return try await self.repository.fetchKnowledgeRepos()
                        } else if kind == .outsideLibraryStars {
                            return try await self.fetchOutsideLibraryStars()
                        } else if kind == .noTags {
                            return try await self.repository.fetchUntagged()
                        } else if kind == .using {
                            return try await self.repoNoteRepository.fetchRepos(byStatus: .using)
                        }
                        let all = try await self.repository.fetchAllStarred()
                        let snapshots = try await self.repoHealthRepository?.snapshots(for: all.map(\.id)) ?? [:]
                        return all.filter { repo in
                            Self.matchesSmartCollection(repo: repo, health: snapshots[repo.id], status: nil, kind: kind)
                        }
                    case .userSmartCollection:
                        return nil
                    case .language(let lang):
                        return try await self.repository.fetchByLanguage(lang)
                    case .tag(let tagId):
                        return try await self.repoTagRepository.fetchRepos(forTag: tagId)
                    case .githubStarList(let listId):
                        return try await self.repository.fetchListPage(
                            scope: .githubStarList(listId),
                            filters: self.currentRepoListFiltersForDatabasePaging(),
                            sort: self.sortOption,
                            limit: 100_000,
                            offset: 0
                        )
                    case .githubStarListUngrouped:
                        return try await self.repository.fetchListPage(
                            scope: .githubStarListUngrouped,
                            filters: self.currentRepoListFiltersForDatabasePaging(),
                            sort: self.sortOption,
                            limit: 100_000,
                            offset: 0
                        )
                    }
                }

                async let statusMapAsync = self.repoNoteRepository.fetchAllStatusMap()
                async let libraryStateMapAsync = self.repoNoteRepository.fetchAllLibraryStateMap()

                guard let fetched = try await fetchedTask() else { return }

                guard !Task.isCancelled else { return }
                let statusMap = (try? await statusMapAsync) ?? [:]
                let libraryStateMap = (try? await libraryStateMapAsync) ?? [:]

                guard !Task.isCancelled else { return }
                self.listCache[selection] = CacheEntry(
                    rawItems: fetched,
                    statusMap: statusMap,
                    libraryStateMap: libraryStateMap,
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

    /// 主窗口知识库入口：侧栏「知识库」与系统集合 `.library`。
    private func isKnowledgeLibrarySelection(_ item: SidebarItem) -> Bool {
        switch item {
        case .library, .smartCollection(.library):
            return true
        default:
            return false
        }
    }

    /// 进出知识库时对调默认排序；用户在知识库里选的 stars/name 等保持不动。
    private func reconcileSortOptionForKnowledgeLibraryTransition(
        from oldSelection: SidebarItem,
        to newSelection: SidebarItem
    ) {
        let wasLibrary = isKnowledgeLibrarySelection(oldSelection)
        let isLibrary = isKnowledgeLibrarySelection(newSelection)
        guard wasLibrary != isLibrary else { return }
        if isLibrary, sortOption == .starredAtDesc {
            sortOption = .libraryUpdatedAtDesc
        } else if !isLibrary, sortOption == .libraryUpdatedAtDesc {
            sortOption = .starredAtDesc
        }
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
    /// - 仍然执行 selectedRepoID 清理（不依赖 items 是否变化）。
    /// - W12 toolbar PR-5：多选状态清理（formIntersection）已下移到 RepoListView
    ///   `.onChange(of: itemsRevision)` 调 `manageMultiSelectionStore.retain(visibleIDs:)`，
    ///   viewModel 不再持 store 引用（A2 路线 / 解耦保持）。
    /// **R-07（2026-06-15）**：算出 filteredSorted 后切片到 items；resetPage = true
    /// 把 currentPage 重置回 1（典型场景：切分类 / 排序 / 过滤），false 时保留
    /// （典型场景：SWR / forceRefresh 数据变化，preserveScrollPosition）。
    private func applyView(resetPage: Bool = true) {
        let newFilteredSorted = computeFilteredSorted()
        visibleRepoTotalCount = newFilteredSorted.count

        // no-op 短路：filteredSorted 完全一致 → 数据无任何变化
        let filteredIdentical = newFilteredSorted.count == filteredSorted.count &&
                                zip(newFilteredSorted, filteredSorted).allSatisfy { $0.id == $1.id }

        if filteredIdentical {
            // selection 清理仍要做：即使数据未变，selectedRepoID 可能已不在过滤集合内
            if let id = selectedRepoID, !newFilteredSorted.contains(where: { $0.id == id }) {
                selectedRepoID = nil
            }
            return
        }

        filteredSorted = newFilteredSorted

        if resetPage {
            currentPage = 1
        } else {
            // preserveScrollPosition：但要保证 currentPage 不超出新的最大页
            // 例：用户停在 page 5（100 行），unstar 后 filteredSorted 变 80 条 → 最大 page 4
            let maxPage = max(1, Int(ceil(Double(newFilteredSorted.count) / Double(Self.pageSize))))
            if currentPage > maxPage { currentPage = maxPage }
        }

        sliceToCurrentPage(reason: .recompute)

        // selection 清理始终要做：即便 items 没换，statusFilter / hideArchived 改了也可能让选中行隐身
        if let id = selectedRepoID, !filteredSorted.contains(where: { $0.id == id }) {
            selectedRepoID = nil
        }
        // 多选模式的 prune 已迁到 RepoListView.onChange(of: itemsRevision)（W12 toolbar PR-5）
    }

    /// R-07：把 filter + sort 计算从 applyView 拆出。
    /// 纯函数：只读 rawItems / statusMap / repoTagsMap / 各 filter 字段。
    private func computeFilteredSorted() -> [Repo] {
        var view = rawItems
        let filters = effectiveGlobalFilterState

        if let effective = effectiveUserSmartCollectionRule() {
            view = SmartCollectionRuleFilter.apply(
                repos: view,
                rule: effective,
                context: smartCollectionFilterContext ?? .empty
            )
        } else {
            if filters.hideArchived { view.removeAll { $0.isArchived } }
            if filters.hideForks    { view.removeAll { $0.isFork } }
            if let status = filters.statusFilter {
                view.removeAll { repo in
                    let actual = statusMap[repo.id] ?? .unread
                    return actual != status
                }
            }
            if let language = filters.repoLanguageFilter.queryLanguage {
                if let language {
                    view.removeAll { $0.language != language }
                } else {
                    view.removeAll { $0.language != nil }
                }
            }
            switch filters.libraryFilter {
            case .all:
                break
            case .inLibrary:
                view.removeAll { repo in
                    (libraryStateMap[repo.id] ?? .outsideLibrary) != .inLibrary
                }
            case .outsideLibrary:
                view.removeAll { repo in
                    (libraryStateMap[repo.id] ?? .outsideLibrary) == .inLibrary
                }
            }
            if !selectedTagIds.isEmpty {
                view.removeAll { repo in
                    let tagsOfRepo = repoTagsMap[repo.id] ?? []
                    return tagsOfRepo.isDisjoint(with: selectedTagIds)
                }
            }
        }
        applyGlobalRepoFilters(to: &view)
        // HOM-197（2026-06-13 dong4j）：AI 语义搜索结果按相似度阈值过滤。
        //
        // 仅 isSemanticSearching 时启用：FTS / 普通分类列表的 semanticHitMap 始终为空，
        // 不进这条分支（避免误把非搜索列表全部过滤掉）。
        //
        // 阈值即时生效：Settings 拖滑杆改阈值后，HomeView 监听该字段触发 refilter()
        // → 走到这里 → 重新过滤当前已缓存的 hits，**不调 embedding API**。
        // 这是把过滤放 view 层而非 service 层的核心收益（详见 AppSettings 文档）。
        //
        // **2026-06-14 阈值单位迁移**：dong4j 决策——过滤判定字段从原始 cosine `score`
        // 改成 A 重标定后的 `displayScore`，让"滑杆 75% = 列表 75%"单位一致。
        // 配合 SemanticSearchService 的 B 字面 boost / C FTS 加权，过滤命中相关性显著提升。
        if isSemanticSearching, let threshold = semanticScoreThreshold {
            view.removeAll { repo in
                let score = semanticHitMap[repo.id]?.displayScore ?? 0
                return score < threshold
            }
        }
        // 用户智能集合内嵌搜索 + 语义模式：排序保留 API 返回顺序。
        let userCollectionSemanticSearch = activeUserSmartCollectionRule != nil
            && smartSearchMode == .semantic
            && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isSemanticSearching && !userCollectionSemanticSearch {
            if sortOption == .healthScoreDesc {
                view.sort(by: healthScoreComparator)
            } else if sortOption == .openSSFScoreDesc {
                view.sort(by: openSSFScoreComparator)
            } else {
                view.sort(by: sortOption.comparator)
            }
        }
        return view
    }

    private func applyGlobalRepoFilters(to repos: inout [Repo]) {
        let filters = effectiveGlobalFilterState
        if filters.starFilter != .all {
            repos.removeAll { repo in
                !filters.starFilter.matches(isStarred: repo.isStarred)
            }
        }
        let selectedLanguages = Set(filters.globalFilterLanguages)
        if !selectedLanguages.isEmpty {
            repos.removeAll { repo in
                guard let language = repo.language else { return true }
                return !selectedLanguages.contains(language)
            }
        }
        applySignalAvailabilityFilters(to: &repos)
    }

    private func applySignalAvailabilityFilters(to repos: inout [Repo]) {
        let filters = effectiveGlobalFilterState
        if filters.wikiAvailabilityFilter != .unknown {
            repos.removeAll { repo in
                !matchesWikiAvailability(repo, filter: filters.wikiAvailabilityFilter)
            }
        }
        if filters.healthAvailabilityFilter != .unknown {
            repos.removeAll { repo in
                !matchesAvailability(
                    healthSortSnapshots[repo.id] != nil,
                    filter: filters.healthAvailabilityFilter
                )
            }
        }
        if filters.openSSFAvailabilityFilter != .unknown {
            repos.removeAll { repo in
                !matchesAvailability(
                    openSSFSortScores[repo.id] != nil,
                    filter: filters.openSSFAvailabilityFilter
                )
            }
        }
    }

    private func matchesWikiAvailability(_ repo: Repo, filter: RepoSignalAvailabilityFilter) -> Bool {
        guard let snapshot = DiskWikiCache.shared.load(owner: repo.owner, repo: repo.name) else {
            return filter == .unknown
        }
        return matchesAvailability(!snapshot.indexedLinks.isEmpty, filter: filter)
    }

    private func matchesAvailability(_ available: Bool, filter: RepoSignalAvailabilityFilter) -> Bool {
        switch filter {
        case .unknown:
            return true
        case .available:
            return available
        case .missing:
            return !available
        }
    }

    private func refreshHealthSortSnapshotsIfNeeded(for repos: [Repo]) async {
        let filters = effectiveGlobalFilterState
        guard sortOption == .healthScoreDesc || filters.healthAvailabilityFilter != .unknown else { return }
        guard let repoHealthRepository else {
            healthSortSnapshots = [:]
            return
        }
        let ids = repos.map(\.id)
        guard !ids.isEmpty else {
            healthSortSnapshots = [:]
            return
        }
        do {
            healthSortSnapshots = try await repoHealthRepository.snapshots(for: ids)
        } catch {
            AppLog.database.warning("Health sort snapshot load failed: \(error.localizedDescription, privacy: .public)")
            healthSortSnapshots = [:]
        }
    }

    private func refreshOpenSSFSortScoresIfNeeded(for repos: [Repo]) async {
        let filters = effectiveGlobalFilterState
        guard sortOption == .openSSFScoreDesc || filters.openSSFAvailabilityFilter != .unknown else { return }
        guard let openSSFScoreRepository else {
            openSSFSortScores = [:]
            return
        }
        let ids = repos.map(\.id)
        guard !ids.isEmpty else {
            openSSFSortScores = [:]
            return
        }
        do {
            let records = try await openSSFScoreRepository.records(for: ids)
            openSSFSortScores = records.compactMapValues { record in
                guard record.fetchStatus == .success else { return nil }
                return record.aggregateScore
            }
        } catch {
            AppLog.database.warning("OpenSSF sort score load failed: \(error.localizedDescription, privacy: .public)")
            openSSFSortScores = [:]
        }
    }

    private func healthScoreComparator(_ a: Repo, _ b: Repo) -> Bool {
        let av = healthSortSnapshots[a.id]?.overallScore
        let bv = healthSortSnapshots[b.id]?.overallScore
        switch (av, bv) {
        case let (aScore?, bScore?):
            if aScore != bScore { return aScore > bScore }
            return RepoSortOption.starredAtDesc.comparator(a, b)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return RepoSortOption.starredAtDesc.comparator(a, b)
        }
    }

    private func openSSFScoreComparator(_ a: Repo, _ b: Repo) -> Bool {
        let av = openSSFSortScores[a.id]
        let bv = openSSFSortScores[b.id]
        switch (av, bv) {
        case let (aScore?, bScore?):
            if aScore != bScore { return aScore > bScore }
            return RepoSortOption.starredAtDesc.comparator(a, b)
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return RepoSortOption.starredAtDesc.comparator(a, b)
        }
    }

    /// R-07：切片调用方意图，决定是否 bump itemsRevision。
    /// - `.recompute`：filter / sort / data 变化触发整栏重算 → bump（List 整栏重建）
    /// - `.append`：loadMoreIfNeeded 追加下一页 → 不 bump（SwiftUI 走增量插入路径保滚动位置）
    /// - `.jump`：ensureRepoVisible 外部跳转推进 currentPage → bump（视觉上需要立刻能看到目标行）
    private enum SliceReason { case recompute, append, jump }

    /// R-07：根据 currentPage 把 filteredSorted 切片到 items；hasMore 同步更新。
    ///
    /// **itemsRevision 策略**（决定流畅度的关键）：
    /// - `.recompute` / `.jump`：bump → List 重建（切分类 / 排序时整栏入场动画，符合直觉）
    /// - `.append`：不 bump → SwiftUI 看到 items.count 增加但 .id 不变，走增量插入路径
    ///   不重建已有行，新行追加不打断当前滚动；如果 bump 反而会触发 listRowReveal
    ///   stagger 动画把已经看了的 20 行重新淡入，体感极糟。
    private func sliceToCurrentPage(reason: SliceReason) {
        let endIndex = min(currentPage * Self.pageSize, filteredSorted.count)
        let newItems = Array(filteredSorted.prefix(endIndex))

        let itemsIdentical = newItems.count == items.count &&
                             zip(newItems, items).allSatisfy { $0.id == $1.id }

        if !itemsIdentical {
            items = newItems
            switch reason {
            case .recompute, .jump:
                itemsRevision += 1
            case .append:
                break  // 故意不 bump：让 SwiftUI 走增量插入路径，不重建已有行
            }
        }
        hasMore = filteredSorted.count > items.count
    }

    /// R-07：列表滚到底部附近 row `.onAppear` 触发。
    /// DB 分页路径会异步加载下一页；内存分页路径只做本地切片增长。
    /// 调用频率：每页 20 条 × 1800 条 ≈ 90 次/次完整滚动，开销可忽略。
    func loadMoreIfNeeded() {
        guard hasMore else { return }
        guard !isLoading, !isRefreshing else { return }
        if let scope = currentRepoListScopeForDatabasePaging(), isDatabasePagingActive, !isSearching {
            guard !isDatabasePageAppendInFlight else { return }
            isDatabasePageAppendInFlight = true
            let task = Task { [weak self] in
                guard let self else { return }
                await self.reloadDatabasePagedItems(scope: scope, reason: .append)
            }
            currentListActionTask = task
        } else {
            currentPage += 1
            sliceToCurrentPage(reason: .append)
        }
    }

    /// R-07：外部跳转（SearchCenter / 详情页"上一篇/下一篇" / unhandled 跳转）
    /// 要求某个 repo 出现在 items 切片内时调用。
    ///
    /// 行为：
    /// - 已在 items 内 → no-op
    /// - 不在 items 内但在 filteredSorted 内 → 把 currentPage 推到能包含目标 index 的页
    /// - 不在 filteredSorted 内（被 filter 过滤掉 / 不属于当前分类）→ no-op，不强行切
    ///   （强行切到该 repo 等于偷偷改 filter，违反用户预期；调用方应自己处理）
    func ensureRepoVisible(repoId: Int64) {
        guard !items.contains(where: { $0.id == repoId }) else { return }
        guard let index = filteredSorted.firstIndex(where: { $0.id == repoId }) else { return }
        let pageNeeded = (index / Self.pageSize) + 1
        if pageNeeded > currentPage {
            currentPage = pageNeeded
            sliceToCurrentPage(reason: .jump)
        }
    }

    // MARK: - Smart Collections

    /// Smart Collections 第一版的系统集合筛选规则。
    ///
    /// 规则刻意保持确定性和可解释：
    /// - 只使用本地 repo metadata + Repo Health 快照，不发网络。
    /// - Health 缺失时保守降级：不会把 repo 算进 High Value，但 archived / 元数据缺失
    ///   仍能进入 Needs Review。
    /// - 日期窗口使用固定天数，后续如需用户可调再提升到设置项。
    static func matchesSmartCollection(
        repo: Repo,
        health: RepoHealthSnapshot?,
        status: RepoStatus? = nil,
        kind: SmartCollectionKind,
        now: Date = Date()
    ) -> Bool {
        switch kind {
        case .library:
            return false
        case .outsideLibraryStars:
            return false
        case .needsReview:
            return repo.isArchived
                || health.map { $0.overallScore < 60 } == true
                || repo.license?.isEmpty != false
                || repo.topicsArray.isEmpty
        case .unmaintained:
            if repo.isArchived { return true }
            guard let pushedAt = repo.pushedAt.flatMap(ISO8601DateFormatter.shared.date(from:)) else {
                return false
            }
            return now.timeIntervalSince(pushedAt) > 365 * 24 * 60 * 60
        case .highValue:
            guard !repo.isArchived else { return false }
            if let health {
                return repo.starsCount >= 1_000 && health.overallScore >= 75
            }
            return repo.starsCount >= 5_000
        case .noTags:
            return false
        case .using:
            // `.using` 是用户显式标记的私有状态，不属于 repo metadata；
            // 调用方必须传入从 repo_notes 派生的 status，缺失时保守不命中。
            return status == .using
        case .recentlyActive:
            guard let pushedAt = repo.pushedAt.flatMap(ISO8601DateFormatter.shared.date(from:)) else {
                return false
            }
            return now.timeIntervalSince(pushedAt) <= 30 * 24 * 60 * 60
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
            return [.untagged, .library, .smartCollectionsHome]
        case .allLanguages:
            return [.allStars, .untagged, .library]
        case .untagged:
            return [.allStars, .library]
        case .library:
            return [.allStars, .untagged]
        case .smartCollectionsHome:
            return [.allStars, .untagged, .library]
        case .smartCollection:
            return [.smartCollectionsHome, .allStars, .library]
        case .userSmartCollection:
            return [.smartCollectionsHome, .allStars, .library]
        case .language:
            return [.allStars, .untagged, .library]
        case .tag:
            return [.allStars, .untagged, .library]
        case .githubStarList, .githubStarListUngrouped:
            return [.allStars, .untagged, .library]
        }
    }
}
