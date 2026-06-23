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

/// 规则编辑器 Sheet 载荷（`sheet(item:)` 避免首帧空白 sheet）。
private struct SmartCollectionRuleEditorItem: Identifiable {
    let id = UUID()
    let mode: SmartCollectionRuleEditorSheet.Mode
}

struct RepoListView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings
    /// HOM-52：批量 AI 整理入口横幅需要查询队列状态。
    @Environment(AppDependencies.self) private var dependencies
    /// W12 PR-4 followup：trending / weekly toolbar 多选按钮按登录态禁用——
    /// 批量 star/unstar 必须调 GitHub API 携带 token，未登录态点按钮无任何效果，
    /// 直接在源头 disable 比让用户点了报错友好。
    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager
    /// `RelativeDateTimeFormatter` 须显式注入 locale（对齐 ActivityView）。
    @Environment(\.locale) private var locale

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
    /// 全局搜索中心由 HomeView 承载；列表 toolbar 只负责触发，不持有浮层状态。
    var onOpenSearchCenter: (() -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion

    // 顶部 clone 按钮现在属于中栏 toolbar；复制成功提示也跟着放在列表栏上。
    @State private var toastMessage: String?
    /// toolbar spec 会通过 `AnyView` 频繁重建，sheet 必须由稳定的页面根节点承载。
    /// 否则关闭 CodeFlow 时 presentation host 被替换，窗口会短暂再次出现。
    @State private var codeFlowSheetRepo: Repo?
    /// CodeFlow 为 Pro 功能；免费用户点入口时弹出统一付费墙，不打开执行面板。
    @State private var paywallContext: ProPaywallContext?
    @State private var ruleEditorSheetItem: SmartCollectionRuleEditorItem?
    /// 列表顶栏「同步于」文案；会话内跟 `SyncManager.state`，冷启动读 DB `last_sync_at`。
    @State private var lastSyncedAt: Date?

    var body: some View {
        @Bindable var vm = viewModel

        #if DEBUG
        // ⏱️ 切分类性能诊断：body 重算是性能瓶颈的重灾区，记录每次重算的时机和距 T0 的 elapsed。
        // body 是 computed property，print 会在每次 SwiftUI 决定调用 body 时打一次。
        // 用 .notice 保证 Xcode console 实时可见（.debug / .info 在 macOS 上会被吞）。
        let _ = AppLog.ui.notice("[switch-cat] RepoListView.body recomputed (items=\(self.viewModel.items.count), itemsRev=\(self.viewModel.itemsRevision), state=\(self.contentStateKey, privacy: .public))  +\(HomeViewModel.msSinceT0, format: .fixed(precision: 1))ms")
        #endif

        contentBody
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 与 Sidebar 头像区 / 右侧详情 hero 联动：透明 toolbar 下中栏顶部也绘制 accent 光晕。
        .detailHeroTintBackground(tint: listColumnTintColor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: listColumnTintColor)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // W4 A5：多选模式底部浮动操作栏；W12 PR-4 扩展到 trending/weekly/activity；
        // W12 PR-5：Manage 也走 MultiSelectionStore 但保留独立 BatchActionBar（业务语义差异：
        // 「打标签」+「Unstar」vs RemoteBatchActionBar 的「Star」+「Unstar」）。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            currentBatchActionBar
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 全局状态入口放在中栏 toolbar：它汇总同步、后台 AI 队列、MCP 与诊断问题，
                // 点击后打开 popover，不额外占用主界面纵向空间。
                // 顺序：W12 toolbar 专项 PR-5 followup，状态按钮提到搜索按钮之前（最左侧），
                // 让"应用健康度"成为用户进首页第一眼就能看到的状态指示。
                AppStatusToolbarButton(
                    lastSyncedAt: lastSyncedAt,
                    onShowBatchAIPanel: onShowBatchAIPanel
                )
            }
            ToolbarItem(placement: .primaryAction) {
                // 视觉对齐：与 UnifiedFilterMenu / UnifiedSortMenu / MultiSelectButton 等
                // 邻位控件一致，统一走 `Button { ToolbarIcon(...) }` 让 macOS toolbar
                // 自行渲染默认圆角矩形按钮，避免之前 `.buttonStyle(.bordered) + minWidth: 62`
                // 强制成的宽椭圆比其它按钮"高/宽一圈"造成的视觉失衡。
                // 图标语义：`sparkle.magnifyingglass` 同时表达「搜索 + 聚合/增强」——
                // 本入口聚合 Local Stars / GitHub / Web（详见 SearchCenterView 三 provider），
                // 比裸 `magnifyingglass`（普通字段搜索）更准确地传达「聚合搜索中心」。
                // ⌘K 快捷键由 HomeView 内隐藏按钮独立注册，这里不重复绑定避免冲突。
                Button {
                    onOpenSearchCenter?()
                } label: {
                    ToolbarIcon("sparkle.magnifyingglass")
                        .accessibilityLabel(Text("toolbar.globalSearch"))
                }
                .help("toolbar.globalSearchHelp")
            }
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
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .sheet(item: $ruleEditorSheetItem) { item in
            SmartCollectionRuleEditorSheet(
                mode: item.mode,
                onCancel: {
                    ruleEditorSheetItem = nil
                },
                onSaved: {
                    ruleEditorSheetItem = nil
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $codeFlowSheetRepo) { repo in
            CodeFlowPanel(repo: repo)
                .appSheetRootEnvironment(dependencies)
        }
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
        // W12 PR-5 A2 路线：Manage filter/sort 变化触发 reloadItems → itemsRevision 自增 →
        // 此处调 store.retain(visibleIDs) 清理被隐藏的孤儿选中项（替代原 viewModel.applyView
        // 内的 formIntersection 块）。view 层主导 store 生命周期，避免 viewModel 持 store 引用。
        .onChange(of: viewModel.itemsRevision) { _, _ in
            let store = dependencies.manageMultiSelectionStore
            guard store.isActive else { return }
            Task {
                let snapshots = await viewModel.selectionSnapshotsForCurrentQuery()
                let visibleIDs = Set(snapshots.map(\.ghRepoId))
                store.retain(visibleIDs: visibleIDs)
            }
        }
        // W12 PR-5：Cmd+A 全选 — 4 场景统一注入一个隐藏按钮承载快捷键。
        // 仅当**当前 page 对应的 store** 处于多选模式时生效（disabled 否则）。Shift 区间选不补。
        .background {
            selectAllShortcutButton
        }
    }

    /// W12 PR-5：Manage 的 Cmd+A 全选隐藏按钮。
    ///
    /// 实现细节：
    /// - 用 `Button { ... }.keyboardShortcut("a", modifiers: .command).hidden()` 是 SwiftUI 注册
    ///   全局键盘快捷键的常规手法（隐藏按钮不占布局，但快捷键由 SwiftUI 路由系统接管）；
    /// - 仅在 manage store 处于 active 时启用，否则 `.disabled(true)` 让 Cmd+A 不抢系统默认行为；
    /// - selectAll 的入参由 view 自己从 viewModel.filteredSorted 构造 SelectionSnapshot
    ///   （Repo.id == ghRepoId）。**R-07 修订**：从 `items` 改用 `filteredSorted` ——
    ///   原 `items` 是当前页切片（≤ 20 条），Cmd+A 只能"全选可见页"反直觉；用户口径
    ///   下 "Cmd+A 全选" 应该是"过滤后的全集"，与 R-07 之前 `items = 全集` 时的行为
    ///   语义对齐。
    /// - Trending / Weekly / Activity 的 Cmd+A 由各自的 view 在本 PR 同步注入（行为 4 场景统一）。
    ///   它们的 visible items 不暴露到 RepoListView 这一层，避免本视图反向依赖子 ViewModel。
    @ViewBuilder
    private var selectAllShortcutButton: some View {
        let store = dependencies.manageMultiSelectionStore
        Button {
            Task {
                let snapshots = await viewModel.selectionSnapshotsForCurrentQuery()
                store.selectAll(snapshots)
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("a", modifiers: .command)
        .disabled(!store.isActive || selectedPage != .manage)
        .hidden()
    }

    /// 把三个远端 store 全部 exit。登出 / token 失效场景调用。
    /// Manage 库内 100% 已 star，登出会触发会话清空但不主动 exit manage store（manage 多选不依赖
    /// GitHub API token，本地操作如打标签仍可执行；如果用户登出后打 unstar 会被 StarActionService 拦）。
    private func exitAllRemoteStores() {
        let trending = dependencies.trendingMultiSelectionStore
        let weekly = dependencies.weeklyMultiSelectionStore
        let activity = dependencies.activityMultiSelectionStore
        if trending.isActive { trending.exit() }
        if weekly.isActive { weekly.exit() }
        if activity.isActive { activity.exit() }
    }

    /// 把"非当前 page+分类"对应的多选 store 全部 exit。
    /// W12 PR-5：Manage 也走 store，切到 trending/activity 时把 manage store 一并 exit。
    private func exitInactiveMultiSelectStores(for page: SidebarRootPage, activityCategory: ActivityCategory) {
        let manage = dependencies.manageMultiSelectionStore
        let trending = dependencies.trendingMultiSelectionStore
        let weekly = dependencies.weeklyMultiSelectionStore
        let activity = dependencies.activityMultiSelectionStore

        switch page {
        case .manage:
            if trending.isActive { trending.exit() }
            if weekly.isActive { weekly.exit() }
            if activity.isActive { activity.exit() }
        case .trending:
            if manage.isActive { manage.exit() }
            if weekly.isActive { weekly.exit() }
            if activity.isActive { activity.exit() }
        case .activity:
            if manage.isActive { manage.exit() }
            if trending.isActive { trending.exit() }
            if activityCategory == .weekly {
                if activity.isActive { activity.exit() }
            } else {
                if weekly.isActive { weekly.exit() }
            }
        }
    }

    // MARK: - 中栏顶部 accent 光晕（与 Sidebar / 详情列联动）

    /// 中栏 tint 取色优先级与 `SidebarHeaderView.sidebarTintColor` 对齐。
    ///
    /// Activity weekly 走 `WeeklySelectionService` 真源（与 `HomeView.derivedActivityTintColor` 同款）。
    private var listColumnTintColor: Color {
        if selectedPage == .activity, selectedActivityCategory == .weekly,
           let project = dependencies.weeklySelectionService.selectedItem {
            return DetailHeroTintBackground.accentColor(
                language: project.language,
                fallback: ActivityCategory.weekly.iconColor
            )
        }
        if let language = viewModel.selectedRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let language = selectedTrendingRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let item = selectedActivityItem {
            return item.accentColor
        }
        return .accentColor
    }

    // MARK: - Toolbar spec 派发

    /// 按 `selectedPage` 派发当前 toolbar 内容。
    ///
    /// 设计参见 `PageToolbarSpec` 文件头：
    /// - Manage 走完整 spec，并显示本地关键词 / 语义搜索入口；
    /// - Trending / Activity 隐藏本地搜索入口，只保留主窗口级 `⌘K` 全局搜索。
    ///   这样避免用户在非 Manage 页面看到一个 disabled 搜索框，却误以为当前页支持
    ///   本地 FTS5 / 向量搜索。
    /// W12 PR-4：根据当前 page 选择对应的多选 BatchActionBar 实现。
    /// W12 PR-5：Manage 也走 MultiSelectionStore，但保留独立 BatchActionBar（暴露
    /// 「打标签」+「Unstar」业务语义按钮，与 RemoteBatchActionBar 的「Star」+「Unstar」不同）。
    @ViewBuilder
    private var currentBatchActionBar: some View {
        switch selectedPage {
        case .manage:
            let store = dependencies.manageMultiSelectionStore
            if store.isActive {
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
                // Trending 未 star 的仓库没有本地 Repo，复用详情页现有 ephemeral 转换，
                // 仅作为 CodeFlow 下载参数使用，不写入数据库。
                let codeFlowRepo = repo.makeEphemeralRepo()
                return AnyView(
                    Group {
                        ExternalLinksMenu(
                            selection: sel,
                            codeFlowRepo: codeFlowRepo.isPrivate ? nil : codeFlowRepo,
                            onOpenCodeFlow: openCodeFlow(for:)
                        )
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

        return PageToolbarSpec(trailingPrimary: trailing)
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
                // Weekly card 已包含生成临时 Repo 所需的 GitHub 元数据。不可访问的历史
                // 项目不展示 CodeFlow，避免用户进入后必然得到 zipball 404。
                let codeFlowRepo = item.card.toEphemeralRepo()
                return AnyView(
                    Group {
                        ExternalLinksMenu(
                            selection: sel,
                            codeFlowRepo: item.isAvailable && !codeFlowRepo.isPrivate ? codeFlowRepo : nil,
                            onOpenCodeFlow: openCodeFlow(for:)
                        )
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
                        ExternalLinksMenu(
                            selection: sel,
                            codeFlowRepo: repo.isPrivate ? nil : repo,
                            onOpenCodeFlow: openCodeFlow(for:)
                        )
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

        return PageToolbarSpec(trailingPrimary: trailing)
    }

    /// Manage 页面 toolbar：filter / multiSelect / external / clone / search。
    /// 排序与 Stars 同步已迁到列表顶栏 `manageFilterBar`（对齐 Weekly / Activity）。
    @MainActor
    private func makeManageToolbarSpec() -> PageToolbarSpec {
        // @Bindable 让 `$vm.statusFilter` 等可派生 Binding，传给下游 picker / toggle。
        @Bindable var vm = viewModel

        let filterItems: [FilterMenuItem] = [
            .content(id: "status", view: AnyView(
                Picker("list.filter.status", selection: $vm.statusFilter) {
                    // 「全部」也挂图标避免下拉里出现"3 个 Label + 1 个裸 Text"的不对齐视觉。
                    // `tray.full` 与下方 envelope.badge / envelope.open / checkmark.seal
                    // 同邮件视觉系统，语义"收件箱全在这"。
                    Label("general.all", systemImage: "tray.full").tag(RepoStatus?.none)
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
                // 智能集合：从右栏 repo 详情退回集合浏览面板，放在中栏 toolbar 不占右栏纵向空间。
                if viewModel.selection.isSmartCollectionDetailContext, viewModel.selectedRepo != nil {
                    Button {
                        viewModel.selectedRepoID = nil
                    } label: {
                        ToolbarIcon("chevron.left.circle")
                            .accessibilityLabel(Text("smartCollections.panel.backToCollection"))
                    }
                    .help("smartCollections.panel.backToCollection")
                }

                Button {
                    openSmartCollectionEditor()
                } label: {
                    ToolbarIcon("line.3.horizontal.decrease.circle")
                }
                .disabled(!canOpenSmartCollectionEditor)
                .help("smartCollections.editor.help")

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

                // W12 PR-5：Manage 多选按钮直接驱动 manageMultiSelectionStore（替代原
                // viewModel.toggleMultiSelectMode），与 trending/weekly/activity 同款机制。
                // Manage 已登录是隐含前提（库内 100% 已 star），不传 isDisabled。
                MultiSelectButton(
                    isActive: dependencies.manageMultiSelectionStore.isActive,
                    action: { dependencies.manageMultiSelectionStore.toggle() }
                )
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
                    ExternalLinksMenu(
                        selection: selection,
                        codeFlowRepo: repo.isPrivate ? nil : repo,
                        onOpenCodeFlow: openCodeFlow(for:)
                    )
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

    private var canOpenSmartCollectionEditor: Bool {
        if case .userSmartCollection(let id) = viewModel.selection {
            return viewModel.userSmartCollection(id: id) != nil
        }
        return viewModel.makeRuleFromCurrentManageFilters() != nil
    }

    private func openSmartCollectionEditor() {
        let mode: SmartCollectionRuleEditorSheet.Mode
        if case .userSmartCollection(let id) = viewModel.selection,
           let collection = viewModel.userSmartCollection(id: id) {
            mode = .edit(collection)
        } else if let rule = viewModel.makeRuleFromCurrentManageFilters() {
            mode = .create(defaultName: defaultSmartCollectionName, initialRule: rule)
        } else {
            return
        }
        ruleEditorSheetItem = SmartCollectionRuleEditorItem(mode: mode)
    }

    private var defaultSmartCollectionName: String {
        // 创建时不用 sidebar 分类名（如「全部仓库」）当集合名，避免标题与侧边栏入口混淆。
        String.l10n("smartCollections.new.defaultName")
    }

    /// 中栏主体内容。
    ///
    /// 单独抽出是为了让 root page 分支保持清晰；
    /// Manage 内部 `List` 仍用 `itemsRevision` 重建快照，避免排序/过滤时几千行逐个 move；
    /// row 只做可视区域内的轻量 reveal。缓存命中分类不再跳过 row reveal：
    /// 保留行级 0.22s 动画不会回到整栏卡顿，同时能恢复列表加载的生命感。
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
            } else {
                // Manage：顶栏（排序 + 同步）始终可见，排序作用于当前侧边栏分类子集。
                manageCategoryContent(vm)
            }
        }
    }

    /// Manage 全部分类共用：列表顶栏 + 下方内容（横幅 / 列表 / 骨架 / 空态）。
    @ViewBuilder
    private func manageCategoryContent(_ vm: HomeViewModel) -> some View {
        @Bindable var bindableVM = vm

        VStack(spacing: 0) {
            if viewModel.selection.isSmartCollectionsSurface {
                smartCollectionsSurfaceFilterBar
                Divider()
                SmartCollectionsOverviewView()
            } else {
                manageFilterBar(sortOption: $bindableVM.sortOption)
                Divider()

                if viewModel.isLoading && viewModel.items.isEmpty {
                RepoSkeletonListView(rowCount: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "error.loadFailed", subtitleText: error)
                } else if viewModel.items.isEmpty {
                emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
                } else {
                listWithOptionalBanner { unifiedListContent($bindableVM.selectedRepoID) }
                }
            }
        }
        .task(id: authSession.state) {
            await refreshLastSyncedAt()
        }
        .onChange(of: syncManager.state) { _, newState in
            if case .completed(let at) = newState {
                lastSyncedAt = at
            }
        }
    }

    /// Manage 列表顶栏：当前分类内排序 + 同步于 + Stars 同步按钮（对齐 Weekly / Activity）。
    private func manageFilterBar(sortOption: Binding<RepoSortOption>) -> some View {
        HStack(spacing: 10) {
            Picker(selection: sortOption) {
                ForEach(RepoSortOption.allCases) { option in
                    Text(verbatim: option.localizedTitle).tag(option)
                }
            } label: {
                Text("list.sort")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            if let lastSyncedAt {
                Text(String(format: String.l10n("list.lastSyncedFormat"), relativeDate(lastSyncedAt)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StarsSyncButton()
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
        .onAppear {
            if viewModel.sortOption != settings.repoSortOption {
                viewModel.sortOption = settings.repoSortOption
            }
        }
        .onChange(of: viewModel.sortOption) { _, newValue in
            settings.repoSortOption = newValue
        }
    }

    /// Smart Collections 总览顶栏：与 `manageFilterBar` 同高，保证中栏与「全部仓库」顶区对齐。
    private var smartCollectionsSurfaceFilterBar: some View {
        HStack(spacing: 10) {
            Text("smartCollections.builtIn.title")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    private func refreshLastSyncedAt() async {
        if case .completed(let at) = syncManager.state {
            lastSyncedAt = at
            return
        }
        guard case .authenticated(let user) = authSession.state else {
            lastSyncedAt = nil
            return
        }
        if let iso = try? await dependencies.repoRepository.fetchLastSyncAt(userID: user.id),
           let date = ISO8601DateFormatter.shared.date(from: iso) {
            lastSyncedAt = date
        }
    }

    private func relativeDate(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 1 {
            return String.l10n("relative.justNow")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// HOM-52：仅在 Untagged 视图非空时，在列表顶部插入"批量 AI 整理"入口横幅。
    ///
    /// 之所以包成 ViewBuilder + closure 而不是把 banner 塞进每个 list view：
    /// unifiedListContent 是带泛型 selection 的 List，加 banner 会破坏 List 滚动语义；
    /// 在外层 VStack 拼接更稳，避免破坏 List 自身滚动与 selection 语义。
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

    /// 中栏内容状态签名，仅用于调试日志。
    ///
    /// 2026-06-19：这里不再挂到外层 `.id(...)`。
    /// 原先用这个 key 强制销毁重建 `contentBody`，从 Trending / Activity 回 Manage 时
    /// 会把中栏外壳、toolbar、列表 task 一起重挂，和 Manage selection 恢复叠加后形成
    /// 明显卡顿。现在只保留内层 `List.id(viewModel.itemsRevision)` 控制真正需要的
    /// 列表快照重建（排序/过滤后避免几千行逐个 move diff）。
    ///
    /// **HOM-46 性能补丁 #2（2026-06-02）**：移除 has-data 稳定态里的 selection / itemsRevision。
    /// - 之前包含 itemsRevision 会让"数据刷新"也触发外层 transition：
    ///   切分类（cache HIT）→ 第一次 body 渲（items 仍是旧分类）→ applyView 跑完 → itemsRev++ → animID 又变
    ///   → 外层 transition **再启动一次**（同一次切换叠两次 0.22s 动画）。
    /// - 现在外层 transition 只在**视图状态层级**（loading / empty / error / has-data）切换时跑；
    ///   已有缓存的分类之间切换保持同一个 `"repos-\(mode)"` 身份，交给内层 List 快照更新。
    /// - 用户感受：缓存命中时没有外层 transition，配合 didSet 急切缓存加载，第一次 body 渲染就是新数据。
    /// **Activity P0（2026-06-17 dong4j 切分类卡顿）**：本地聚合分类（全部/公告/星标…）
    /// 共享 `"activity-local"` identity，**不**再按 `selectedActivityCategory.id` 分 id。
    /// 旧写法 `activity-\(category.id)` 会让每次切分类销毁重建整棵 `ActivityView` + 跑
    /// 0.22s 外层 transition（Manage HOM-46 已在 has-data 态规避同类问题）。
    /// 仅 weekly ↔ 其它 数据源/根视图不同，保留 `"activity-weekly"` / `"activity-local"` 二分。
    private var contentStateKey: String {
        if selectedPage == .trending {
            return "trending-\(selectedTrendingLanguage.id)"
        }
        if selectedPage == .activity {
            return selectedActivityCategory == .weekly ? "activity-weekly" : "activity-local"
        }
        // W12 PR-5：多选状态迁到 manageMultiSelectionStore；状态签名用 store.isActive 派生。
        let mode = dependencies.manageMultiSelectionStore.isActive ? "multi" : "single"
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

    /// 统一的 Manage 列表（W12 PR-5：替代原 `listContent(_:)` + `multiSelectList(_:)` 两条路径）。
    ///
    /// 单选 / 多选共用同一份 `List + ForEach + plain Button + UnifiedRepoRow` 结构，与
    /// TrendingView / WeeklyContentView / ActivityView 完全对齐：
    /// - 不用 `List(selection:)` —— 它会强制绘制 macOS 系统蓝色选中底色，把自定义 `RepoRowSurface`
    ///   的语言色 accent / 18% 底色 / 42% 描边完全压住，多选与 trending 视觉割裂的根因；
    /// - 单选模式（store.isActive == false）：Button action 写 `selectedRepoID`，HomeView 监听
    ///   该变化加载详情；
    /// - 多选模式（store.isActive == true）：Button action 调 `store.toggle(snapshot)` 切换选中态；
    ///   selectedRepoID 完全不动（对齐 Trending：退出多选后详情页保持），UnifiedRepoRow 的
    ///   isSelected 由 store.contains 派生；
    /// - 卡片视觉完全由 `UnifiedRepoRow.isSelected` 驱动（无 List 系统蓝），4 个分类长得一模一样。
    private func unifiedListContent(_ selection: Binding<Int64?>) -> some View {
        let store = dependencies.manageMultiSelectionStore
        // ScrollViewReader 包装的目的（dong4j 2026-06-13）：
        // 外部场景（命令面板 / SearchCenter 选中本地 repo，HomeView.openSearchCandidate
        // 写 viewModel.selectedRepoID）必须能让列表滚到目标行，否则用户只看到详情区切了过去，
        // 而列表里"被选中的那行"远在视口外，体感上像"啥也没发生"。
        // 用 ForEach 行的 `.id(repo.id)` 作为 scroll anchor —— Repo.id 是 GitHub repo id，
        // 全局唯一，不会与 trending / weekly / activity 的 id 域冲突。
        return ScrollViewReader { proxy in
            List {
                ForEach(indexedItems) { item in
                    let repo = item.repo
                    Button {
                        if store.isActive {
                            // 多选模式：toggle 该行选中态。Repo.id == ghRepoId == GitHub ID 同一 Int64 域。
                            store.toggle(SelectionSnapshot(
                                ghRepoId: repo.id,
                                owner: repo.owner,
                                name: repo.name
                            ))
                        } else {
                            selection.wrappedValue = repo.id
                        }
                    } label: {
                        // 读取 viewModel.statusMap（@Observable 字段）让 SwiftUI 订阅 dict 变更：
                        // 详情页改 status → NotificationCenter post → HomeViewModel 局部
                        // 更新 statusMap → 本 row 重新渲染（角标即时刷新），无需 reloadItems。
                        UnifiedRepoRow(
                            card: repo.asCardData(
                                readStatus: viewModel.readStatus(for: repo.id),
                                openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.id),
                                healthBadge: dependencies.repoHealthStore.badge(for: repo.id)
                            ),
                            isSelected: store.isActive
                                ? store.contains(ghRepoId: repo.id)
                                : (selection.wrappedValue == repo.id),
                            semanticHit: viewModel.semanticHit(for: repo.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .listRowReveal(index: item.index, snapshotID: viewModel.itemsRevision)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(repo.id)
                    // HOM-201 P1-1（2026-06-14）：hover 500ms 后预拉 README，
                    // softTtl 短路在 API 层做（命中 6h 内缓存不打 GitHub）。
                    .readmePrefetch { [readmeAPI = dependencies.readmeAPI] in
                        await readmeAPI.prefetch(for: repo)
                    }
                    // R-07：滚到倒数第 3 行 → 追加下一页（Weekly 同款范式）。
                    // 用 `viewModel.items.count` 实时读，配合 hasMore 守卫天然幂等：
                    // loadMoreIfNeeded 内部 guard hasMore 防止已加载完后继续追加。
                    // 用 item.index 比 indexOf(repo) 快（O(1)）。
                    .onAppear {
                        if viewModel.hasMore && item.index >= viewModel.items.count - 3 {
                            viewModel.loadMoreIfNeeded()
                        }
                    }
                }
            }
            .id(viewModel.itemsRevision)
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            // 阅读状态 v2（2026-06-12）：订阅 .repoStatusDidChange，详情页改 status 后
            // HomeViewModel.statusMap 局部更新 → UnifiedRepoRow.readStatus 重渲染 → 角标即时刷新。
            // task 与 view lifetime 绑定（view 退出自动 cancel），不会泄漏 NotificationCenter observer。
            .task {
                await viewModel.observeRepoStatusChanges()
            }
            .task(id: viewModel.itemsRevision) {
                await dependencies.openSSFScoreStore.loadCachedScores(for: viewModel.items.map(\.id))
            }
            // Repo Health 健康度缓存预加载(2026-06-21 接入,与 OpenSSF 对称):
            // 让 Manage 列表第一屏渲染前就拿到缓存,health badge 即时显示。
            .task(id: viewModel.itemsRevision) {
                await dependencies.repoHealthStore.loadCachedSnapshots(for: viewModel.items.map(\.id))
            }
            // 仅外部导航（SearchCenter / 命令面板）滚到目标行；列表行点击不写
            // `shouldScrollSelectedRepoIntoView`，避免 scrollTo(.center) 错位到下一卡片。
            .onChange(of: selection.wrappedValue) { _, newValue in
                guard let id = newValue else { return }
                guard viewModel.shouldScrollSelectedRepoIntoView else { return }
                viewModel.shouldScrollSelectedRepoIntoView = false
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            // R-07.1 follow-up（2026-06-16 dong4j）：hasMore false → true 时主动 push 一次 loadMoreIfNeeded。
            //
            // 场景（dong4j 真机回归发现）：sync 还在跑期间用户已手动滚动到 items 尾部触发 loadMoreIfNeeded × N,
            // items 从 20 一路涨到 currentPage * 20,hasMore 在抵达 filteredSorted.count 那一刻翻 false。
            // 等 sync 完成（state = .completed）,HomeView 调 reloadItems(forceRefresh: true)：
            //   - filteredSorted 从快照 100 → 1800
            //   - currentPage 保留（preserveScrollPosition,R-07 既有设计）
            //   - sliceToCurrentPage 算出 newItems 与现有 items 前 N 条同 ID 同序 → itemsIdentical
            //     short-circuit → items 不变 / itemsRevision 不 bump
            //   - 但 hasMore 被无条件设置为 true（1800 > items.count）
            //
            // 后果：列表 UI 看似数据未变,但 hasMore 状态翻转后,已显示行的 .onAppear **不会** 重触发
            // （SwiftUI 只在 row 首次进入视口时调 onAppear）；用户被困在原 items 尾部,往下滚是橡皮筋
            // 回弹,无法触发后续 loadMore,"卡在 100 条尾部"无法看到完整 1800 条列表。
            //
            // 修复：监听 hasMore 边沿 false → true,主动调一次 loadMoreIfNeeded 让 items 增长一页。
            // sliceToCurrentPage(reason: .append) 不 bump itemsRevision,滚动位置自然保留；用户继续
            // 向下滚动时,新行的倒数第 3 个 .onAppear 会触发后续 loadMore,自然推进到 filteredSorted.count。
            //
            // 用 Task { @MainActor in } 包一层：避免在 SwiftUI body 更新期间同步写 viewModel 状态
            // 触发"Modifying state during view update"警告。loadMoreIfNeeded 内部 guard hasMore
            // 天然幂等,多次触发不会引发 currentPage 失控。
            //
            // 副作用（可接受）：首屏 page 1 写入触发 firstPageWrittenAt → reloadItems 让 hasMore
            // 从 false → true 时也会命中本分支,首屏 items 从 20 → 40 条。首屏视口只显示 ~10 行,
            // 用户视觉无感；R-07 既有 .append 分支不重建已有行,亦无入场动画干扰。
            .onChange(of: viewModel.hasMore) { wasMore, hasMore in
                guard !wasMore, hasMore else { return }
                Task { @MainActor in
                    viewModel.loadMoreIfNeeded()
                }
            }
        }
    }

    private var navigationSubtitle: String {
        if selectedPage == .trending {
            return selectedTrendingLanguage.localizedDisplayName
        }
        if selectedPage == .activity {
            return selectedActivityCategory.localizedTitle
        }
        // W12 PR-5：多选数从 manageMultiSelectionStore 派生（替代原 viewModel.multiSelectedRepoIDs）。
        // **R-07.2 修订**：DB 分页模式下 filteredSorted 只镜像已加载前缀，标题数量
        // 必须读 ViewModel 的真实查询总数，避免 1800+ 仓库首屏只显示 20。
        let manageStore = dependencies.manageMultiSelectionStore
        let visibleTotal = viewModel.visibleRepoTotalCount
        if manageStore.isActive {
            return String(
                format: String.l10n("list.selectedCountFormat"),
                manageStore.count,
                visibleTotal
            )
        }
        if viewModel.isRefreshing {
            if viewModel.isSemanticSearching {
                return String(
                    format: String.l10n("search.semantic.refreshingFormat"),
                    visibleTotal
                )
            }
            return String(
                format: String.l10n("list.refreshingFormat"),
                visibleTotal
            )
        }
        if viewModel.isSemanticSearching {
            return String(
                format: String.l10n("search.semantic.resultCountFormat"),
                visibleTotal
            )
        }
        return String(
            format: String.l10n("list.repoCountFormat"),
            visibleTotal
        )
    }

    // MARK: - 标题派生

    private var navigationTitle: String {
        if selectedPage == .trending {
            return String.l10n("trending.title")
        }
        if selectedPage == .activity {
            return String.l10n("activity.title")
        }
        if viewModel.isSearching {
            return String(format: String.l10n("search.searching"), truncatedSearchQueryForTitle)
        }
        return localizedTitle(for: viewModel.selection)
    }

    /// 给 `.navigationTitle` 用的搜索词截断版本。
    ///
    /// **为什么必须在拼字符串时就截断**：`.navigationTitle(_:)` 接的是裸 `String`，
    /// 直接绑到 macOS 窗口 chrome / NavigationStack title 区，**SwiftUI 没有 modifier 能
    /// 在 view 层 truncate**（`.lineLimit` 对 system title 无效）。任由 query 过长会
    /// 把 toolbar 撑出列表栏右侧或挤掉计数副标题。
    ///
    /// **阈值 24 个 grapheme cluster**：经验值，覆盖典型搜索 90%+ 场景；中英混排在
    /// 280–400pt 列表栏宽度内不溢出。超长则后接 `…`（U+2026 HORIZONTAL ELLIPSIS
    /// 单字符省略号，符合 Apple HIG，不用三个 ASCII 点）。
    ///
    /// **不动 `viewModel.searchQuery` 本体**：截断仅作显示用，FTS / 语义搜索仍按完整
    /// query 跑；这里只防 title 视觉溢出。
    private var truncatedSearchQueryForTitle: String {
        let raw = viewModel.searchQuery
        let limit = 24
        return raw.count > limit ? "\(raw.prefix(limit))…" : raw
    }

    /// Navigation title 需要 plain String；静态入口走 localization，用户标签/语言按原样显示。
    private func localizedTitle(for item: SidebarItem) -> String {
        switch item {
        case .trending:
            return String.l10n("trending.title")
        case .allStars:
            return String.l10n("sidebar.allRepos")
        case .untagged:
            return String.l10n("sidebar.untagged")
        case .smartCollectionsHome:
            return String.l10n("smartCollections.title")
        case .smartCollection(let kind):
            return String.l10n("smartCollections.\(kind.rawValue).title")
        case .userSmartCollection(let id):
            return viewModel.userSmartCollection(id: id)?.name ?? String.l10n("smartCollections.mine.fallback")
        case .language(let language):
            // Navigation title 同样走短名（详见 LanguageDisplayName）。
            // 无主语言（nil）统一硬编码为 "Uncategorized"（dong4j 2026-06-16，不做 i18n）。
            return language.map(LanguageDisplayName.shortened(for:)) ?? "Uncategorized"
        case .tag(let id):
            return viewModel.tags.first { $0.id == id }?.name ?? String.l10n("sidebar.tagFallback")
        }
    }

    // MARK: - 空状态

    private var emptyImage: String {
        if viewModel.isSearching { return "magnifyingglass" }
        switch viewModel.selection {
        case .trending:  return "chart.line.uptrend.xyaxis"
        case .allStars:  return "star"
        case .untagged:  return "tag.slash"
        case .smartCollectionsHome: return "line.3.horizontal.decrease.circle"
        case .smartCollection: return "tray"
        case .userSmartCollection: return "line.3.horizontal.decrease.circle"
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
        case .smartCollectionsHome: return "smartCollections.empty.title"
        case .smartCollection: return "smartCollections.empty.collection"
        case .userSmartCollection: return "smartCollections.empty.collection"
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
        case .smartCollectionsHome: return "smartCollections.empty.subtitle"
        case .smartCollection: return "smartCollections.empty.collectionSubtitle"
        case .userSmartCollection: return "smartCollections.empty.collectionSubtitle"
        case .language:        return "empty.languageHint"
        case .tag:             return "empty.tagHint"
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            subtitle: subtitle,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitleText: String) -> some View {
        EmptyStateView(
            systemImage: systemImage,
            title: title,
            subtitleText: subtitleText,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread: return "envelope.badge"
        case .read:   return "envelope.open"
        case .using:  return "checkmark.seal"
        }
    }

    /// CodeFlow 为 Pro 能力：入口统一走权益门控，免费用户只看到付费墙。
    private func openCodeFlow(for repo: Repo) {
        do {
            try dependencies.entitlementGate.requirePro(.codeFlow)
            codeFlowSheetRepo = repo
        } catch {
            paywallContext = ProPaywallContext(feature: .codeFlow, message: error.localizedDescription)
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
