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
            if let cached = listCache[selection], !cached.isExpired {
                self.rawItems = cached.rawItems
                self.statusMap = cached.statusMap
                self.applyView()             // items / itemsRevision 同步就位
                if self.isLoading { self.isLoading = false }
                if self.isRefreshing { self.isRefreshing = false }    // 只用缓存瞬切；真实变更路径再显式 force refresh。
                if self.loadError != nil { self.loadError = nil }
                #if DEBUG
                AppLog.ui.notice("[switch-cat] T0' eager cache load done (items=\(self.items.count)) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                #endif
            } else {
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

    /// R-07（2026-06-15）：客户端分页 —— 当前已展示到第几页（1-based）。
    /// `items.count` ≈ `currentPage * pageSize`（最后一页可能不足）。
    private(set) var currentPage: Int = 1

    /// R-07：是否还有更多页可追加。
    /// `RepoListView` 根据这个值决定是否 attach `.onAppear` 触发 `loadMoreIfNeeded()`。
    private(set) var hasMore: Bool = false

    /// R-07：客户端分页页大小。与 Weekly `localPageSize` 同款 20，
    /// 经验值兼顾"首屏立即可见 + 滚动 1 屏才需要追加"。
    static let pageSize: Int = 20

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

    /// Languages 聚合（Sidebar Languages 组）。D-04：`private(set)` 收敛。
    private(set) var languageStats: [LanguageStat] = []

    /// W4 A6：用户自定义标签列表（Sidebar Tags 组）。
    private(set) var tags: [Tag] = []
    /// W4 A6：tagId → starred repo count（Sidebar Tags 行右侧计数）。
    private(set) var tagCounts: [String: Int] = [:]

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
            applyView()
        }
    }

    /// HOM-179：repo → 它拥有的 tagIds。
    /// `applyView()` 用这张表做 OR 过滤；`refreshSidebar()` 一次拉全量并刷新。
    /// 之所以走"全量内存映射 + 客户端过滤"而非"为每次切换查 IN/OR SQL"：
    /// - 总量 1801 repos × 平均 ~3 tags = 几千条映射，内存占用可忽略（<100KB）
    /// - 切 Languages / 勾 / 取消标签时不发起 DB 查询，UI 即时响应
    /// - 与现有 `statusMap` 走的"全表加载到字典 + applyView 过滤"路径完全一致
    private var repoTagsMap: [Int64: Set<String>] = [:]

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

    /// 详情页修改 status 后由 `NotificationCenter.repoStatusDidChange` 触发，
    /// 局部更新 statusMap 让 row 角标即时刷新。
    ///
    /// 单条 dict 写入是 O(1) 的；不调 `applyView()` 因为状态过滤未生效时（statusFilter == nil）
    /// 仅角标可见性变，List 的 items 序列不变；若 statusFilter == status，需要 applyView
    /// 让该 row 进入 / 退出过滤集合 —— 这里统一调 applyView，让逻辑更直观。
    fileprivate func applyStatusChange(repoId: Int64, status: RepoStatus) {
        guard statusMap[repoId] != status else { return }
        statusMap[repoId] = status
        // R-07：详情页改 status 不应抢用户滚动位置，传 resetPage: false。
        applyView(resetPage: false)
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

    /// 派生：当前是否有任何过滤器生效（toolbar 显示徽标用）。
    var hasActiveFilter: Bool { hideArchived || hideForks || statusFilter != nil }

    // MARK: - 依赖

    /// D-01：依赖协议而非具体 struct，便于单测注入 Mock。
    private let repository: any RepoRepositoryProtocol

    /// W4 A6：Sidebar Tags 段 + 按 tag 过滤需要这两个 repo。
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    /// W4-4 D3：按状态过滤需要 repoNoteRepository.fetchStatusMap。
    private let repoNoteRepository: any RepoNoteRepositoryProtocol

    /// Repo Health 快照用于 Smart Collections 的 Needs Review / High Value 等集合。
    /// 可选是为了不破坏既有单测构造；缺失时集合按 repo 元数据保守降级。
    private let repoHealthRepository: (any RepoHealthRepositoryProtocol)?

    /// W6 AI：语义搜索服务。测试可传 nil，生产由 AppDependencies 注入。
    private let semanticSearchService: SemanticSearchService?

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
        repoNoteRepository: any RepoNoteRepositoryProtocol,
        repoHealthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        semanticSearchService: SemanticSearchService? = nil
    ) {
        self.repository = repository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.repoNoteRepository = repoNoteRepository
        self.repoHealthRepository = repoHealthRepository
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
    /// `items` / Sidebar 计数 / `statusMap` / `tags` / `repoTagsMap` —— 仍然是
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
    /// - `sortOption` / `hideArchived` / `hideForks` / `statusFilter` / `smartSearchMode`
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
        prefetchTask?.cancel()
        prefetchTask = nil

        listCache.removeAll()
        rawItems = []
        statusMap = [:]
        repoTagsMap = [:]
        semanticHitMap = [:]
        selectedTagIds = []

        items = []
        // R-07：客户端分页全套字段也要复位，避免新账号沿用旧账号的页位置 / hasMore
        filteredSorted = []
        currentPage = 1
        hasMore = false
        itemsRevision &+= 1

        totalCount = 0
        untaggedCount = 0
        languageStats = []
        tags = []
        tagCounts = [:]

        selectedRepoID = nil
        shouldScrollSelectedRepoIntoView = false
        searchQuery = ""
        searchSubmissionID &+= 1

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

    /// 刷新 Sidebar 数据（counts + language stats）。
    /// 通常在 onAppear 或 sync 完成后调用。
    func refreshSidebar() async {
        do {
            async let total = repository.starredCount()
            async let untagged = repository.fetchUntagged().count
            async let langs = repository.languageStats()
            async let tagsResult = tagRepository.fetchAll()
            async let tagCountsResult = repoTagRepository.repoCountsByTag()
            // HOM-179：一并刷新 repo→tagIds 映射，让 selectedTagIds 多选过滤实时生效。
            // 与 sidebar 其他统计同步刷新，避免新增/删除 tag 后 wall 多选还按旧映射过滤。
            async let tagAssignmentsResult = repoTagRepository.fetchAllTagAssignments()

            self.totalCount = try await total
            self.untaggedCount = try await untagged
            self.languageStats = try await langs
            self.tags = try await tagsResult
            self.tagCounts = try await tagCountsResult
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
            case .untagged, .tag, .smartCollectionsHome, .smartCollection:
                selection = .allStars
            case .allStars, .language, .trending:
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

        if selection == .smartCollectionsHome, !isSearching {
            rawItems = []
            filteredSorted = []
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
        let shouldUseListCache = !isSearching
        let cached = shouldUseListCache ? listCache[selection] : nil
        let hasStaleCache = cached != nil

        if hasStaleCache {
            #if DEBUG
            AppLog.ui.notice("[switch-cat] T2 cache HIT, items=\(cached!.rawItems.count) +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
            #endif
            // 有缓存：立即用缓存数据填充 UI，同时后台刷新
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
                let fetchedTask: () async throws -> (repos: [Repo], semanticHitMap: [Int64: SemanticSearchHit]) = {
                    if self.isSearching {
                        if self.smartSearchMode == .semantic {
                            guard let semanticSearchService = self.semanticSearchService else {
                                throw SemanticSearchError.missingAPIKey
                            }
                            // 2026-06-14 dong4j：先 FTS 拿命中 ID 集合，再调语义搜索（思路 1，C 加权）。
                            // FTS5 是本地 SQLite 查询，毫秒级零成本；ftsHitIDs 仅作排序加权信号
                            // 不做硬过滤，保住"语义同义但字面没匹"的纯向量召回能力。
                            let candidates = try await self.repository.fetchAllStarred()
                            let ftsHits = try await self.repository.searchFTS(query: self.searchQuery)
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
                            return (repos: try await self.repository.searchFTS(query: self.searchQuery), semanticHitMap: [:])
                        }
                    } else {
                        var repos: [Repo]
                        switch self.selection {
                        case .trending:
                            repos = [] // Placeholder for W7 Trending
                        case .allStars:
                            repos = try await self.repository.fetchAllStarred()
                        case .untagged:
                            repos = try await self.repository.fetchUntagged()
                        case .smartCollectionsHome:
                            repos = []
                        case .smartCollection(let kind):
                            if kind == .noTags {
                                repos = try await self.repository.fetchUntagged()
                            } else {
                                let all = try await self.repository.fetchAllStarred()
                                let snapshots = try await self.repoHealthRepository?.snapshots(for: all.map(\.id)) ?? [:]
                                repos = all.filter { repo in
                                    Self.matchesSmartCollection(
                                        repo: repo,
                                        health: snapshots[repo.id],
                                        kind: kind
                                    )
                                }
                            }
                        case .language(let lang):
                            repos = try await self.repository.fetchByLanguage(lang)
                        case .tag(let tagId):
                            repos = try await self.repoTagRepository.fetchRepos(forTag: tagId)
                        }

                        return (repos: repos, semanticHitMap: [:])
                    }
                }

                async let fetchedAsync = fetchedTask()
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
            case .success(let result):
                let fetched = result.repos
                self.semanticHitMap = result.semanticHitMap
                // 更新缓存（无论 UI 是否需要重渲染，都用最新数据替换 cache entry，
                // 让下次切回这个分类时拿到 freshest 数据）
                if shouldUseListCache {
                    self.listCache[self.selection] = CacheEntry(
                        rawItems: fetched,
                        statusMap: fetchedStatusMap,
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

                if idsIdentical && statusIdentical {
                    // 静默更新底层引用（rawItems / statusMap 是 private 属性，不参与视图重建）。
                    // 不动 items / itemsRevision → 不触发 SwiftUI re-render，避免第二波动画。
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
                    #if DEBUG
                    AppLog.ui.notice("[switch-cat] T6' bg fetch identical, skipped applyView +\(Self.msSinceT0, format: .fixed(precision: 1))ms")
                    #endif
                } else {
                    // 数据真的变了（同步刚结束 / 用户操作改了 status / R-07 firstPageWrittenAt 触发等）
                    // → 走完整 applyView，但 resetPage: false 保留用户滚动位置
                    // （preserveScrollPosition：A 收尾的"100 → 1800"切换对用户透明的关键）。
                    self.rawItems = fetched
                    self.statusMap = fetchedStatusMap
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

    func semanticHit(for repoID: Int64) -> SemanticSearchHit? {
        semanticHitMap[repoID]
    }

    /// 手动刷新全部 starred repo 的语义索引。
    ///
    /// 入口放在列表 toolbar；适合用户刚切换 embedding model 或大量同步后主动更新。
    func refreshSemanticIndex() async {
        guard let semanticSearchService else {
            loadError = SemanticSearchError.missingAPIKey.localizedDescription
            return
        }
        isSemanticIndexing = true
        defer { isSemanticIndexing = false }
        do {
            let repos = try await repository.fetchAllStarred()
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
                    case .smartCollectionsHome:
                        return nil
                    case .smartCollection(let kind):
                        if kind == .noTags {
                            return try await self.repository.fetchUntagged()
                        }
                        let all = try await self.repository.fetchAllStarred()
                        let snapshots = try await self.repoHealthRepository?.snapshots(for: all.map(\.id)) ?? [:]
                        return all.filter { repo in
                            Self.matchesSmartCollection(repo: repo, health: snapshots[repo.id], kind: kind)
                        }
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
    /// - 仍然执行 selectedRepoID 清理（不依赖 items 是否变化）。
    /// - W12 toolbar PR-5：多选状态清理（formIntersection）已下移到 RepoListView
    ///   `.onChange(of: itemsRevision)` 调 `manageMultiSelectionStore.retain(visibleIDs:)`，
    ///   viewModel 不再持 store 引用（A2 路线 / 解耦保持）。
    /// **R-07（2026-06-15）**：算出 filteredSorted 后切片到 items；resetPage = true
    /// 把 currentPage 重置回 1（典型场景：切分类 / 排序 / 过滤），false 时保留
    /// （典型场景：SWR / forceRefresh 数据变化，preserveScrollPosition）。
    private func applyView(resetPage: Bool = true) {
        let newFilteredSorted = computeFilteredSorted()

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
        // HOM-179：标签墙多选 OR 过滤。
        // 用户口径：
        //   - 多个 tag 之间 OR：命中任意一个就保留
        //   - 与 selection（Languages 等）AND：因为 `view` 此时已是 selection 派生的 base set
        // 实现：用 repoTagsMap 查每个 repo 的 tagIds，看与 selectedTagIds 是否有交集。
        // 没有交集（即"没有任何已选 tag"）→ 移除。
        if !selectedTagIds.isEmpty {
            view.removeAll { repo in
                let tagsOfRepo = repoTagsMap[repo.id] ?? []
                return tagsOfRepo.isDisjoint(with: selectedTagIds)
            }
        }
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
        // 语义搜索结果的排序来自 cosine similarity；再套用户的 stars/name 排序会破坏 AI 排名。
        if !isSemanticSearching {
            view.sort(by: sortOption.comparator)
        }
        return view
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

    /// R-07：列表滚到底部（倒数第 3 行 `.onAppear`）触发；纯本地切片增长，不调网络 / DB。
    /// `loadMoreIfNeeded` 是同步方法 —— 不需要 race 防护（不像 reloadItems 走异步 DB / 网络）。
    /// 调用频率：每页 20 条 × 1800 条 ≈ 90 次/次完整滚动，开销可忽略。
    func loadMoreIfNeeded() {
        guard hasMore else { return }
        currentPage += 1
        sliceToCurrentPage(reason: .append)
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
        kind: SmartCollectionKind,
        now: Date = Date()
    ) -> Bool {
        switch kind {
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
            return [.untagged, .smartCollectionsHome]
        case .untagged:
            return [.allStars]
        case .smartCollectionsHome:
            return [.allStars, .untagged]
        case .smartCollection:
            return [.smartCollectionsHome, .allStars]
        case .language:
            return [.allStars, .untagged]
        case .tag:
            return [.allStars, .untagged]
        }
    }
}
