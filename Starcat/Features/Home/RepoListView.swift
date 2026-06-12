//
//  RepoListView.swift
//  Starcat
//
//  中栏：仓库列表视图。
//
//  职责：
//  - 渲染 HomeViewModel.items，每行调度到 RepoRowView
//  - 响应行选中 → 写入 HomeViewModel.selectedRepo
//  - 空 / 加载 / 错误状态友好展示
//
//  设计约束：
//  - 普通单选用 plain Button 手动写 selectedRepoID，避免系统蓝色选中底色压过自定义样式
//  - 多选模式仍用 SwiftUI List selection binding，保留 Cmd / Shift 原生多选体验
//  - 行密度由 AppSettings 注入，密度切换实时生效（@Observable 通知）
//

import SwiftUI
import AppKit

struct RepoListView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings
    /// HOM-52：批量 AI 整理入口横幅需要查询队列状态。
    @Environment(AppDependencies.self) private var dependencies
    /// W12 PR-4 followup：trending / weekly toolbar 多选按钮按登录态禁用——
    /// 批量 star/unstar 必须调 GitHub API 携带 token，未登录态点按钮无任何效果，
    /// 直接在源头 disable 比让用户点了报错友好。
    @Environment(AuthSession.self) private var authSession

    /// HOM-54：TrendingRepository，用于渲染 Trending 页面。
    var trendingRepository: (any TrendingRepositoryProtocol)?
    /// HOM-54：Trending 一键订阅复用 GitHub API 的 star 端点。
    var githubAPIClient: (any GitHubAPIClientProtocol)?

    let selectedPage: SidebarRootPage
    @Binding var selectedTrendingLanguage: TrendingLanguage
    /// 当前选中的 Trending repo ID（用于卡片高亮和 README 加载）。
    @Binding var selectedTrendingRepoID: String?
    /// 当前选中的 Trending repo 完整数据（用于右侧详情页元信息展示）。
    @Binding var selectedTrendingRepo: TrendingRepo?
    /// Activity 页当前分类。
    @Binding var selectedActivityCategory: ActivityCategory
    /// Activity 页当前选中项，驱动右侧详情。
    @Binding var selectedActivityItem: ActivityItem?

    /// HOM-52：Untagged 视图顶部 banner 的"启动整理 / 查看进度"回调。
    /// 这两个动作产生 sheet 由 HomeView 统一承载（避免 RepoListView 多持一个 @State）。
    var onStartBatchAI: (() -> Void)?
    var onShowBatchAIPanel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 顶部 clone 按钮现在属于中栏 toolbar；复制成功提示也跟着放在列表栏上。
    @State private var toastMessage: String?

    var body: some View {
        @Bindable var vm = viewModel

        #if DEBUG
        // ⏱️ 切分类性能诊断：body 重算是性能瓶颈的重灾区，记录每次重算的时机和距 T0 的 elapsed。
        // body 是 computed property，print 会在每次 SwiftUI 决定调用 body 时打一次。
        // 用 .notice 保证 Xcode console 实时可见（.debug / .info 在 macOS 上会被吞）。
        let _ = AppLog.ui.notice("[switch-cat] RepoListView.body recomputed (items=\(self.viewModel.items.count), itemsRev=\(self.viewModel.itemsRevision), animID=\(self.contentAnimationID, privacy: .public))  +\(HomeViewModel.msSinceT0, format: .fixed(precision: 1))ms")
        #endif

        contentBody
        .id(contentAnimationID)
        .transition(contentTransition)
        .animation(contentAnimation, value: contentAnimationID)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // W4 A5：多选模式底部浮动操作栏；W12 PR-4 扩展到 trending/weekly/activity。
        // Manage 使用 BatchActionBar（基于 HomeViewModel.multiSelectedRepoIDs），
        // 其它页面使用 RemoteBatchActionBar（基于对应 MultiSelectionStore）。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            currentBatchActionBar
        }
        .toolbar {
            // W12 toolbar 专项 PR-1：toolbar 内容按 selectedPage 派发到对应 spec builder。
            // 当前只有 manage 走完整 spec，trending / activity 返回 .empty —— 它们各自
            // 仍在中栏自绘 toolbar，PR-2/3/4 阶段再迁过来。
            let spec = currentToolbarSpec
            if let leading = spec.leadingPrimary {
                ToolbarItemGroup(placement: .primaryAction) {
                    leading
                }
            }
            if let trailing = spec.trailingPrimary {
                ToolbarItemGroup(placement: .primaryAction) {
                    trailing
                }
            }
            if let search = spec.searchField {
                ToolbarItem(placement: .primaryAction) {
                    search
                }
            }
        }
        .toast(message: $toastMessage, icon: "doc.on.clipboard")
        // W12 PR-4：切页面时主动 exit 非活跃 store，避免"切到 trending 时 weekly 还显示
        // 底部多选栏"的视觉穿帮。同一时刻只允许一份处于 isActive，由本视图集中保证。
        .onChange(of: selectedPage) { _, newPage in
            exitInactiveMultiSelectStores(for: newPage, activityCategory: selectedActivityCategory)
        }
        .onChange(of: selectedActivityCategory) { _, newCategory in
            // activity 内切换 weekly ↔ 其它子分类时，旧分类对应的 store 也要清空。
            if selectedPage == .activity {
                exitInactiveMultiSelectStores(for: .activity, activityCategory: newCategory)
            }
        }
        // PR-4 followup：登录态变化时（典型场景：登出 / token 失效），主动把所有远端 store
        // exit 掉。否则用户从「多选中」直接登出后，store.isActive 仍为 true，底部条会试图
        // 渲染但按钮全 disable，体验割裂。
        .onChange(of: authSession.state.isAuthenticated) { _, isAuthed in
            if !isAuthed {
                exitAllRemoteStores()
            }
        }
    }

    /// 把三个远端 store 全部 exit。登出 / token 失效场景调用。
    private func exitAllRemoteStores() {
        let trending = dependencies.trendingMultiSelectionStore
        let weekly = dependencies.weeklyMultiSelectionStore
        let activity = dependencies.activityMultiSelectionStore
        if trending.isActive { trending.exit() }
        if weekly.isActive { weekly.exit() }
        if activity.isActive { activity.exit() }
    }

    /// 把"非当前 page+分类"对应的多选 store 全部 exit。
    /// Manage 的多选状态由 HomeViewModel.isMultiSelectMode 自己管，这里只处理三个远端 store。
    private func exitInactiveMultiSelectStores(for page: SidebarRootPage, activityCategory: ActivityCategory) {
        let trending = dependencies.trendingMultiSelectionStore
        let weekly = dependencies.weeklyMultiSelectionStore
        let activity = dependencies.activityMultiSelectionStore

        switch page {
        case .manage:
            if trending.isActive { trending.exit() }
            if weekly.isActive { weekly.exit() }
            if activity.isActive { activity.exit() }
        case .trending:
            if weekly.isActive { weekly.exit() }
            if activity.isActive { activity.exit() }
        case .activity:
            if trending.isActive { trending.exit() }
            if activityCategory == .weekly {
                if activity.isActive { activity.exit() }
            } else {
                if weekly.isActive { weekly.exit() }
            }
        }
    }

    // MARK: - Toolbar spec 派发

    /// 按 `selectedPage` 派发当前 toolbar 内容。
    ///
    /// 设计参见 `PageToolbarSpec` 文件头：
    /// - PR-1：Manage 走完整 spec，其它页面 leading/trailing 仍为 nil（保留自绘 toolbar）；
    /// - PR-2：所有页面统一注入 `searchField` —— 非 Manage 页面以 `isDisabled = true`
    ///   显示，tooltip 提示"该搜索仅在 Manage 页面可用"，为未来 GitHub 搜索模式铺路。
    /// W12 PR-4：根据当前 page 选择对应的多选 BatchActionBar 实现。
    /// - Manage：基于 `HomeViewModel.multiSelectedRepoIDs`；
    /// - Trending/Weekly/Activity：基于对应的 `MultiSelectionStore`。
    @ViewBuilder
    private var currentBatchActionBar: some View {
        switch selectedPage {
        case .manage:
            if viewModel.isMultiSelectMode {
                BatchActionBar()
            }
        case .trending:
            let store = dependencies.trendingMultiSelectionStore
            if store.isActive {
                RemoteBatchActionBar(store: store)
            }
        case .activity:
            let store = (selectedActivityCategory == .weekly)
                ? dependencies.weeklyMultiSelectionStore
                : dependencies.activityMultiSelectionStore
            if store.isActive {
                RemoteBatchActionBar(store: store)
            }
        }
    }

    private var currentToolbarSpec: PageToolbarSpec {
        switch selectedPage {
        case .manage:    return makeManageToolbarSpec()
        case .trending:  return makeTrendingToolbarSpec()
        case .activity:  return makeActivityToolbarSpec()
        }
    }

    /// 非 Manage 页面共用的 SmartSearchField 注入（PR-2）。
    ///
    /// 禁用判定：当前 `mode` 是 `.keyword` / `.semantic` 时禁用——它们都依赖
    /// Manage 的本地 FTS5 / 向量索引。未来 `.github` 模式上线时，此处放开 `isDisabled`。
    @MainActor
    private func nonManageSearchField() -> AnyView {
        let mode = viewModel.smartSearchMode
        let needsManageData = (mode == .keyword || mode == .semantic)
        return AnyView(smartSearchField(isDisabled: needsManageData))
    }

    /// Trending 页面 toolbar spec（W12 PR-4）：
    /// - leading 暂无（period picker 仍在中栏自绘 toolbar，period 是数据切片维度而非排序）；
    /// - trailing 注入：[external / clone] +「多选按钮」。
    ///   external / clone 派发 `selectedTrendingRepo` 单选项；多选按钮驱动
    ///   `trendingMultiSelectionStore`，由 `TrendingView` 的行点击 toggle 选中状态。
    /// - PR-4 followup：未登录态多选按钮 disable。批量 star/unstar 都需要 token，
    ///   未登录直接 disable 比让用户点了再弹错误友好；如果 store 已经处于 active
    ///   （比如登录后切到 trending 又登出），同帧把 store exit 兜底清掉 stale selection。
    @MainActor
    private func makeTrendingToolbarSpec() -> PageToolbarSpec {
        let store = dependencies.trendingMultiSelectionStore
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let trailing: AnyView = {
            let selectionView: AnyView? = selectedTrendingRepo.map { repo in
                let sel = ToolbarRepoSelection.from(
                    trending: repo,
                    isStarred: registry.contains(ghRepoId: repo.ghRepoId)
                )
                return AnyView(
                    Group {
                        ExternalLinksMenu(selection: sel)
                        CloneMenu(selection: sel) { toastKey in
                            toastMessage = toastKey
                        }
                    }
                )
            }
            return AnyView(
                Group {
                    selectionView
                    MultiSelectButton(
                        isActive: store.isActive,
                        action: { store.toggle() },
                        isDisabled: !isAuthed
                    )
                }
            )
        }()

        return PageToolbarSpec(
            trailingPrimary: trailing,
            searchField: nonManageSearchField()
        )
    }

    /// Activity 页面 toolbar spec（W12 PR-4）：
    /// - leading 暂无（weekly 的 sort + language picker 仍在 WeeklyContentView 自绘）；
    /// - trailing 注入：[external / clone] +「多选按钮」。
    ///   - weekly 子分类：external/clone 派发 `weeklySelectionService.selectedItem`，多选用
    ///     `weeklyMultiSelectionStore`；
    ///   - 其它子分类：external/clone 派发 `selectedActivityItem?.repo`（announcement /
    ///     following 这种 repo == nil 时不显示菜单），多选用 `activityMultiSelectionStore`。
    /// - PR-4 followup：未登录态多选按钮 disable（同 trending 同款理由）。activity 其它子分类
    ///   理论上只有登录态才会有 starred 数据，加守卫是防御性编程，不会有副作用。
    @MainActor
    private func makeActivityToolbarSpec() -> PageToolbarSpec {
        let isWeekly = (selectedActivityCategory == .weekly)
        let store = isWeekly
            ? dependencies.weeklyMultiSelectionStore
            : dependencies.activityMultiSelectionStore
        let registry = dependencies.starredRegistry
        let isAuthed = authSession.state.isAuthenticated

        let selectionView: AnyView? = {
            if isWeekly {
                guard let item = dependencies.weeklySelectionService.selectedItem else { return nil }
                let sel = ToolbarRepoSelection.from(
                    weekly: item,
                    isStarred: registry.contains(ghRepoId: item.ghRepoId)
                )
                return AnyView(
                    Group {
                        ExternalLinksMenu(selection: sel)
                        CloneMenu(selection: sel) { toastKey in
                            toastMessage = toastKey
                        }
                    }
                )
            } else {
                guard let repo = selectedActivityItem?.repo else { return nil }
                let sel = ToolbarRepoSelection.from(
                    repo: repo,
                    isStarred: registry.contains(ghRepoId: repo.id)
                )
                return AnyView(
                    Group {
                        ExternalLinksMenu(selection: sel)
                        CloneMenu(selection: sel) { toastKey in
                            toastMessage = toastKey
                        }
                    }
                )
            }
        }()

        let trailing = AnyView(
            Group {
                selectionView
                MultiSelectButton(
                    isActive: store.isActive,
                    action: { store.toggle() },
                    isDisabled: !isAuthed
                )
            }
        )

        return PageToolbarSpec(
            trailingPrimary: trailing,
            searchField: nonManageSearchField()
        )
    }

    /// Manage 页面 toolbar：filter / sort / multiSelect / external / clone / search。
    ///
    /// W12 PR-1：把原 inline 实现拆到独立组件（ExternalLinksMenu / CloneMenu /
    /// MultiSelectButton / UnifiedSortMenu / UnifiedFilterMenu），本方法只做组装。
    @MainActor
    private func makeManageToolbarSpec() -> PageToolbarSpec {
        // @Bindable 让 `$vm.statusFilter` 等可派生 Binding，传给下游 picker / toggle。
        @Bindable var vm = viewModel

        let filterItems: [FilterMenuItem] = [
            .content(id: "status", view: AnyView(
                Picker("list.filter.status", selection: $vm.statusFilter) {
                    Text("general.all").tag(RepoStatus?.none)
                    ForEach(RepoStatus.allCases, id: \.self) { st in
                        Label(st.displayName, systemImage: statusIcon(for: st))
                            .tag(RepoStatus?.some(st))
                    }
                }
                .pickerStyle(.inline)
            )),
            .divider(id: "after-status"),
            .toggle(id: "hideArchived", label: "settings.general.hideArchived", icon: "archivebox", isOn: $vm.hideArchived),
            .toggle(id: "hideForks", label: "settings.general.hideForks", icon: "tuningfork", isOn: $vm.hideForks)
        ]

        let leading = AnyView(
            Group {
                UnifiedFilterMenu(
                    items: filterItems,
                    isAnyFilterActive: viewModel.hasActiveFilter,
                    accessibilityLabel: viewModel.statusFilter == nil
                        ? "list.filter.status"
                        : LocalizedStringKey(viewModel.statusFilter?.localizedDisplayName ?? "list.filter.status")
                )
                .onChange(of: viewModel.hideArchived) { _, newValue in
                    settings.hideArchived = newValue
                }
                .onChange(of: viewModel.hideForks) { _, newValue in
                    settings.hideForks = newValue
                }
                .onChange(of: viewModel.statusFilter) { _, newValue in
                    settings.statusFilter = newValue
                }

                UnifiedSortMenu(
                    selection: $vm.sortOption,
                    options: RepoSortOption.allCases,
                    displayName: { $0.displayName },
                    systemImage: { $0.systemImage }
                )
                .onAppear {
                    if viewModel.sortOption != settings.repoSortOption {
                        viewModel.sortOption = settings.repoSortOption
                    }
                }
                .onChange(of: viewModel.sortOption) { _, newValue in
                    settings.repoSortOption = newValue
                }

                MultiSelectButton(isActive: viewModel.isMultiSelectMode) {
                    viewModel.toggleMultiSelectMode()
                }
            }
        )

        let trailing: AnyView? = {
            guard let repo = viewModel.selectedRepo else { return nil }
            let selection = ToolbarRepoSelection.from(
                repo: repo,
                isStarred: dependencies.starredRegistry.contains(ghRepoId: repo.id)
            )
            return AnyView(
                Group {
                    ExternalLinksMenu(selection: selection)
                    CloneMenu(selection: selection) { toastKey in
                        toastMessage = toastKey
                    }
                }
            )
        }()

        return PageToolbarSpec(
            leadingPrimary: leading,
            trailingPrimary: trailing,
            searchField: AnyView(smartSearchField())
        )
    }

    /// 中栏主体内容。
    ///
    /// 单独抽出是为了让外层用 `contentAnimationID` 给整块内容做过渡动画；
    /// `List` 本身仍用 `itemsRevision` 重建快照，避免排序/过滤时几千行逐个 move；
    /// row 只做可视区域内的轻量 reveal。缓存命中分类不再跳过 row reveal：
    /// 外层 transition 已稳定，保留行级 0.22s 动画不会回到整栏卡顿，同时能恢复列表加载的生命感。
    @ViewBuilder
    private var contentBody: some View {
        @Bindable var vm = viewModel

        Group {
            if selectedPage == .trending {
                // HOM-54：Trending 页面
                if let repo = trendingRepository, let githubAPIClient {
                    TrendingView(
                        repository: repo,
                        githubAPIClient: githubAPIClient,
                        selectedLanguage: $selectedTrendingLanguage,
                        selectedRepoID: $selectedTrendingRepoID,
                        selectedTrendingRepo: $selectedTrendingRepo
                    )
                } else {
                    emptyState(systemImage: "chart.line.uptrend.xyaxis", title: "empty.trendingUnavailable", subtitle: "empty.trendingComingSoon")
                }
            } else if selectedPage == .activity {
                ActivityView(
                    selectedCategory: $selectedActivityCategory,
                    selectedItem: $selectedActivityItem
                )
            } else if viewModel.isLoading {
                // HOM-46：无缓存分类加载时直接切到骨架屏，避免旧分类列表停留在中栏造成"没反应"的错觉。
                RepoSkeletonListView(rowCount: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "error.loadFailed", subtitleText: error)
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
            } else if viewModel.isMultiSelectMode {
                // W4 A5：多选模式 List binding 类型不同，必须分开渲染
                listWithOptionalBanner { multiSelectList($vm.multiSelectedRepoIDs) }
            } else {
                listWithOptionalBanner { listContent($vm.selectedRepoID) }
            }
        }
    }

    /// HOM-52：仅在 Untagged 视图非空时，在列表顶部插入"批量 AI 整理"入口横幅。
    ///
    /// 之所以包成 ViewBuilder + closure 而不是把 banner 塞进每个 list view：
    /// listContent / multiSelectList 都是带泛型 selection 的 List，加 banner 会破坏 List 滚动语义；
    /// 在外层 VStack 拼接更稳，且 banner 也参与 contentAnimationID 触发的过渡动画。
    @ViewBuilder
    private func listWithOptionalBanner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if selectedPage == .manage, viewModel.selection == .untagged {
            VStack(spacing: 0) {
                BatchAIUntaggedBanner(
                    // 用 untaggedCount 而非 items.count：搜索过滤后 items 会少，
                    // 但 banner 反映的是"全部未分类仓库"总量，与"开始整理"动作语义一致。
                    untaggedCount: viewModel.untaggedCount,
                    service: dependencies.batchAIQueueService,
                    onStart: { onStartBatchAI?() },
                    onShowPanel: { onShowBatchAIPanel?() }
                )
                content()
            }
        } else {
            content()
        }
    }

    /// 给 `ForEach` 使用的带下标 repo。
    ///
    /// SwiftUI `List` 本身会按可视区域懒创建 row；这里补一个 index 只用于计算短暂
    /// stagger delay，让切分类后首屏 row 依次轻入场，滚动到新 row 时也能有渐进出现效果。
    private var indexedItems: [IndexedRepo] {
        viewModel.items.enumerated().map { IndexedRepo(index: $0.offset, repo: $0.element) }
    }

    /// 中栏内容切换动画的身份键。
    ///
    /// 外层 `.id(contentAnimationID)` 控制 contentBody 何时被销毁重建 + 何时跑外层 transition。
    /// 内层 `List.id(viewModel.itemsRevision)` 单独控制 List 快照重建（排序/过滤后避免几千行逐个 move diff）。
    ///
    /// **HOM-46 性能补丁 #2（2026-06-02）**：移除 has-data 稳定态里的 selection / itemsRevision。
    /// - 之前包含 itemsRevision 会让"数据刷新"也触发外层 transition：
    ///   切分类（cache HIT）→ 第一次 body 渲（items 仍是旧分类）→ applyView 跑完 → itemsRev++ → animID 又变
    ///   → 外层 transition **再启动一次**（同一次切换叠两次 0.22s 动画）。
    /// - 现在外层 transition 只在**视图状态层级**（loading / empty / error / has-data）切换时跑；
    ///   已有缓存的分类之间切换保持同一个 `"repos-\(mode)"` 身份，交给内层 List 快照更新。
    /// - 用户感受：缓存命中时没有外层 transition，配合 didSet 急切缓存加载，第一次 body 渲染就是新数据。
    private var contentAnimationID: String {
        if selectedPage == .trending {
            return "trending-\(selectedTrendingLanguage.id)"
        }
        if selectedPage == .activity {
            return "activity-\(selectedActivityCategory.id)"
        }
        let mode = viewModel.isMultiSelectMode ? "multi" : "single"
        if viewModel.isLoading {
            return "loading-\(viewModel.selection.id)-\(mode)"
        }
        if let error = viewModel.loadError, viewModel.items.isEmpty {
            return "error-\(viewModel.selection.id)-\(error)"
        }
        if viewModel.items.isEmpty {
            return "empty-\(viewModel.selection.id)-\(mode)"
        }
        return "repos-\(mode)"
    }

    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    // MARK: - 顶部操作栏组件

    /// 可折叠智能搜索框。
    ///
    /// 2026-06-04 修订：dong4j 确认新原型后，搜索入口不再使用系统 `.searchable`。
    /// 原因是当前交互需要“默认折叠 + 模式切换内嵌 + AI 光晕 + 索引刷新内嵌”，这些能力
    /// 超出了 `NSSearchField` / SwiftUI `.searchable` 的定制范围。
    ///
    /// W12 PR-2：增加 `isDisabled` 参数。Trending / Activity 页面也会渲染本组件
    /// 作为常驻入口，但 mode 为 keyword/semantic 时禁用并显示 tooltip。
    private func smartSearchField(isDisabled: Bool = false) -> some View {
        @Bindable var vm = viewModel
        return SmartSearchField(
            text: $vm.searchQuery,
            mode: $vm.smartSearchMode,
            isIndexing: viewModel.isSemanticIndexing,
            onSubmitSearch: { query in
                viewModel.submitSearch(query)
            },
            onRefreshSemanticIndex: {
                Task { await viewModel.refreshSemanticIndex() }
            },
            isDisabled: isDisabled
        )
        .onAppear {
            if viewModel.smartSearchMode != settings.smartSearchMode {
                viewModel.smartSearchMode = settings.smartSearchMode
            }
        }
        .onChange(of: viewModel.smartSearchMode) { _, newValue in
            settings.smartSearchMode = newValue
        }
    }

    // MARK: - 列表主体

    /// 单选列表使用手动 selection，而不是 `List(selection:)`。
    ///
    /// 原因：`List(selection:)` 会强制绘制 macOS 系统蓝色选中底色，和 UI 升级后的
    /// 自定义左侧 accent 条叠加后视觉过重。这里用 plain Button 写入 `selectedRepoID`，
    /// 仍触发 HomeView 的 `.onChange(of: selectedRepoID)` 加载详情，但选中外观完全交给
    /// `RepoRowView` 控制。
    private func listContent(_ selection: Binding<Int64?>) -> some View {
        List {
            ForEach(indexedItems) { item in
                let repo = item.repo
                // UI 视觉升级：单选态不再使用 `List(selection:)`。
                // macOS 会强制绘制系统蓝色选中底色，和自定义左侧色条叠加后过重；
                // 改为 plain Button 手动写 selectedRepoID，保留点击打开详情，但视觉只由 RepoRowView 控制。
                Button {
                    selection.wrappedValue = repo.id
                } label: {
                    UnifiedRepoRow(
                        card: repo.asCardData(),
                        isSelected: selection.wrappedValue == repo.id,
                        semanticHit: viewModel.semanticHit(for: repo.id)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: item.index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .id(viewModel.itemsRevision)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    /// W4 A5：多选 List。binding 类型 `Set<Int64>` → SwiftUI 自动启用多选行为。
    /// macOS 用户用 Cmd / Shift 加选，行级 checkbox 不必显式画。
    private func multiSelectList(_ selection: Binding<Set<Int64>>) -> some View {
        List(selection: selection) {
            ForEach(indexedItems) { item in
                let repo = item.repo
                UnifiedRepoRow(
                    card: repo.asCardData(),
                    isSelected: selection.wrappedValue.contains(repo.id),
                    semanticHit: viewModel.semanticHit(for: repo.id)
                )
                .listRowReveal(index: item.index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .id(viewModel.itemsRevision)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var navigationSubtitle: String {
        if selectedPage == .trending {
            return selectedTrendingLanguage.localizedDisplayName
        }
        if selectedPage == .activity {
            return selectedActivityCategory.localizedTitle
        }
        if viewModel.isMultiSelectMode {
            return String(
                format: String(localized: "list.selectedCountFormat"),
                viewModel.multiSelectedRepoIDs.count,
                viewModel.items.count
            )
        }
        if viewModel.isRefreshing {
            if viewModel.isSemanticSearching {
                return String(
                    format: String(localized: "search.semantic.refreshingFormat"),
                    viewModel.items.count
                )
            }
            return String(
                format: String(localized: "list.refreshingFormat"),
                viewModel.items.count
            )
        }
        if viewModel.isSemanticSearching {
            return String(
                format: String(localized: "search.semantic.resultCountFormat"),
                viewModel.items.count
            )
        }
        return String(
            format: String(localized: "list.repoCountFormat"),
            viewModel.items.count
        )
    }

    // MARK: - 标题派生

    private var navigationTitle: String {
        if selectedPage == .trending {
            return String(localized: "trending.title")
        }
        if selectedPage == .activity {
            return String(localized: "activity.title")
        }
        if viewModel.isSearching {
            return String(format: String(localized: "search.searching"), viewModel.searchQuery)
        }
        return localizedTitle(for: viewModel.selection)
    }

    /// Navigation title 需要 plain String；静态入口走 localization，用户标签/语言按原样显示。
    private func localizedTitle(for item: SidebarItem) -> String {
        switch item {
        case .trending:
            return String(localized: "trending.title")
        case .allStars:
            return String(localized: "sidebar.allRepos")
        case .untagged:
            return String(localized: "sidebar.untagged")
        case .language(let language):
            // Navigation title 同样走短名（详见 LanguageDisplayName）。
            return language.map(LanguageDisplayName.shortened(for:)) ?? String(localized: "sidebar.unknownLanguage")
        case .tag(let id):
            return viewModel.tags.first { $0.id == id }?.name ?? String(localized: "sidebar.tagFallback")
        }
    }

    // MARK: - 空状态

    private var emptyImage: String {
        if viewModel.isSearching { return "magnifyingglass" }
        switch viewModel.selection {
        case .trending:  return "chart.line.uptrend.xyaxis"
        case .allStars:  return "star"
        case .untagged:  return "tag.slash"
        case .language:  return "chevron.left.forwardslash.chevron.right"
        case .tag:       return "tag.slash"
        }
    }

    private var emptyTitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.noResults" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingUnavailable"
        case .allStars:        return "empty.noStars"
        case .untagged:        return "empty.allTagged"
        case .language:        return "empty.noReposInLanguage"
        case .tag:             return "empty.noReposInTag"
        }
    }

    private var emptySubtitle: LocalizedStringKey {
        if viewModel.isSearching { return "empty.tryAnother" }
        switch viewModel.selection {
        case .trending:        return "empty.trendingComingSoon"
        case .allStars:        return "empty.syncPrompt"
        case .untagged:        return "empty.untaggedHint"
        case .language:        return "empty.languageHint"
        case .tag:             return "empty.tagHint"
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitleText: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(verbatim: subtitleText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread:     return "envelope.badge"
        case .reading:    return "book"
        case .using:      return "checkmark.seal"
        case .deprecated: return "archivebox"
        }
    }
}

/// 带可见顺序的 repo 包装。
///
/// `id` 仍然来自 repo.id，保证 SwiftUI row identity 不受下标影响；index 只用于计算
/// 入场 delay，避免排序后因为下标变化破坏选中 / 复用语义。
private struct IndexedRepo: Identifiable {
    let index: Int
    let repo: Repo

    var id: Int64 { repo.id }
}
