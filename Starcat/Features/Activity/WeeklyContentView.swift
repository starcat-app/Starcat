//
//  WeeklyContentView.swift
//  Starcat
//
//  Explore 页 `weekly` 分类的中栏视图 + ViewModel。
//
//  数据源：Weekly 固定目录中的多来源项目通过独立 Go 后端服务聚合
//  暴露的 REST API。
//  契约见 `WeeklyAPI.swift` / 后端仓库 README。
//
//  设计约束：
//  - 不复用 ActivityViewModel 的本地聚合逻辑：weekly 是远端分页 + 筛选 + 排序，
//    塞进 ActivityViewModel 会污染其"本地缓存聚合"语义。
//  - 列表点击 → 写入 `WeeklySelectionService.selectedProject`，由 HomeView 详情区
//    路由到 `WeeklyDetailView`（不再直接外链）。详情页内才提供"在 GitHub 打开"按钮。
//    这次改动前是 `NSWorkspace.open(project.url)` 直接跳浏览器，被反馈无法预览所以
//    重新接回 detail pane；新建 `WeeklyDetailView` 而非复用 `ActivityDetailView`，
//    因为 weekly 还要展示期号 / 周刊原文等专属字段。
//  - 分页是"无限滚动"：到达列表底部时自动加载下一页；不放手动"加载更多"按钮，
//    与 macOS 上 List 的自然滚动体验一致。
//  - 列表顶部 toolbar 保留"筛选 + 排序 + 刷新"；计数由 Explore sidebar 与中栏 subtitle
//    读取 `WeeklySelectionService.total`，避免 Activity 再承担 Weekly total 合并职责。
//
//  R-06.4（2026-06-15）渐进式 SWR 双轨制：
//  - **dataSource 双轨**：`.local`（缓存命中走本地 sort/filter/page）/ `.remote`
//    （缓存未命中走分页 API fallback）。两种模式 UI 完全无感知，只在 ViewModel 内做
//    分支调度。
//  - **入场策略**：① 先读 `WeeklyBulkRepository.cachedBulk()`；② 命中 → 立即上屏 +
//    切到 `.local`；命中且 6h TTL 内 → 不再发请求；命中但 TTL 过期 → 后台触发
//    bulkSync 静默刷新（不阻塞 UI）；③ 未命中 → fallback 老分页 `fetchRepos(page=1)`
//    立刻出图（200ms 级体感），同时后台启动 bulkSync 把 4000 条落盘；下次入场切 `.local`。
//  - **切 source / sort / lang / 高级筛选**：`.local` 模式纯本地 filter + sort +
//    客户端分页（瞬时无网络）；`.remote` 模式下高级筛选会先拉 bulk，再本地过滤，
//    避免对远端分页第一页做不完整过滤导致 total 不准。
//  - **主动刷新**：toolbar 刷新按钮 / pull-to-refresh 永远调 bulkSync（不论 dataSource），
//    完成后强制切到 `.local`，让 6h TTL 重新计时。
//  - **客户端 6h TTL**：判断在 ViewModel 层，Repository 不掺和；与后端 bulk 快照的
//    6h 新鲜度窗口保持一致，避免客户端跨过一轮服务端刷新后仍继续展示旧快照。
//

import SwiftUI
import AppKit

// MARK: - View

/// Explore Weekly 分类的内容视图。
struct WeeklyContentView: View {

    /// Weekly 筛选 popover 固定宽度。
    ///
    /// 这里不跟随系统 popover 内容自适应：筛选项都是短标签，过宽会在右侧留下大片空白。
    /// 220pt 能容纳当前中英文最长项，后续文案变长时由 row 内 `lineLimit` 兜底省略。
    private static let filterPopoverWidth: CGFloat = 220

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @Binding var selectedLanguage: String?

    @State private var viewModel: WeeklyContentViewModel?
    @State private var libraryStateMap: [Int64: LibraryState] = [:]
    @State private var wikiAvailabilityMap: [Int64: Bool] = [:]
    @State private var isFilterPopoverPresented = false

    init(
        viewModel: WeeklyContentViewModel? = nil,
        selectedLanguage: Binding<String?>
    ) {
        _viewModel = State(initialValue: viewModel)
        _selectedLanguage = selectedLanguage
    }

    // R-01 §3.1.4 Step 7.3：refreshAngle / reduceMotion 已无外层用途，统一由 SyncIconButton 内部处理。
    // WeeklyProjectRow 内部仍保留自己的 reduceMotion env 处理 isSelected 动画。

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let model = ensureViewModel()
            restoreSortPreferenceIfNeeded(model)
            syncExternalLanguage(to: model)
            async let libraryLoad: Void = reloadLibraryStateMap()
            await model.loadInitialIfNeeded()
            await libraryLoad
            guard !Task.isCancelled else { return }
            await Task.yield()
            applyWeeklyDetailSelectionPolicy(from: model.items)
        }
        .task {
            await observeLibraryStateChanges()
        }
        .task(id: selectedLanguage ?? "") {
            guard let viewModel else { return }
            syncExternalLanguage(to: viewModel)
            applyWeeklyDetailSelectionPolicy(from: viewModel.items)
        }
    }

    @ViewBuilder
    private func content(_ viewModel: WeeklyContentViewModel) -> some View {
        VStack(spacing: 0) {
            filterBar(viewModel)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()

            // 与探索发现一致：横条挂在筛选栏下方、列表上方，避免埋进 List 滚动区。
            weeklyCacheWarningBanner(viewModel)

            weeklyContentBody(viewModel)
                .id(contentStateID(for: viewModel))
                .transition(contentTransition)
                .animation(contentAnimation, value: contentStateID(for: viewModel))
        }
        .task {
            viewModel.interestedLanguages = settings.interestedLanguages
            await viewModel.loadLanguagesIfNeeded()
            syncBindingLanguage(from: viewModel)
            applyWeeklyDetailSelectionPolicy(from: viewModel.items)
        }
        .onChange(of: viewModel.itemsRevision) { _, _ in
            applyWeeklyDetailSelectionPolicy(from: viewModel.items)
        }
        .onChange(of: settings.openFirstDetailOnCategoryChange) { _, enabled in
            guard enabled else { return }
            applyWeeklyDetailSelectionPolicy(from: viewModel.items)
        }
        .onChange(of: settings.interestedLanguages) { _, languages in
            viewModel.interestedLanguages = languages
        }
        .task(id: settings.wikiAvailabilityFilter.rawValue) {
            await reloadWikiAvailabilityMap(for: viewModel.items)
        }
        .starcatRefreshCommand(
            pane: .list,
            identity: "weekly-\(selectedLanguage ?? "")-\(viewModel.selectedSort.rawValue)-\(viewModel.filterSummaryTitle)-\(viewModel.isLoading)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: !viewModel.isLoading
        ) {
            refreshCurrentWeeklyList(viewModel)
        }
    }

    @ViewBuilder
    private func weeklyContentBody(_ viewModel: WeeklyContentViewModel) -> some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            RepoSkeletonListView(rowCount: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.loadError, viewModel.items.isEmpty {
            emptyState(systemImage: "exclamationmark.triangle", title: "activity.error.title", subtitleText: error) {
                Task { await viewModel.reload() }
            }
        } else if viewModel.items.isEmpty {
            emptyState(systemImage: "newspaper", title: "weekly.empty.title", subtitle: "weekly.empty.subtitle") {
                Task { await viewModel.reload() }
            }
        } else {
            projectList(viewModel)
        }
    }

    @ViewBuilder
    private func weeklyCacheWarningBanner(_ viewModel: WeeklyContentViewModel) -> some View {
        if let warning = viewModel.cacheWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private func contentStateID(for viewModel: WeeklyContentViewModel) -> String {
        if viewModel.isLoading && viewModel.items.isEmpty {
            return "weekly-loading"
        }
        if let error = viewModel.loadError, viewModel.items.isEmpty {
            return "weekly-error-\(error)"
        }
        if viewModel.items.isEmpty {
            return "weekly-empty"
        }
        return "weekly-content"
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

    // MARK: - Filter Bar

    /// 顶部筛选栏：来源 / 收录强度 / 状态 / 热度 / 推送时间 / 排序。
    ///
    /// 期号筛选目前没有用 picker 暴露——后端 `/issues` 还在补，列表也不强需要；
    /// 后续要做时增加一个 Menu 即可，结构上已经在 ViewModel 留了 `selectedIssue`。
    private func filterBar(_ viewModel: WeeklyContentViewModel) -> some View {
        HStack(spacing: 10) {
            filterPopoverButton(viewModel)

            UnifiedSortMenu(
                selection: weeklySortBinding(viewModel),
                options: Array(WeeklyFeedSort.allCases),
                displayName: weeklySortTitle,
                systemImage: weeklySortIcon
            )

            Spacer()

            refreshButton(viewModel)
        }
    }

    /// Weekly 筛选是多条件组合选择，不能用原生 Menu。
    ///
    /// `Menu` 在点击任意 `Button` 后会自动关闭，用户连续选择多个条件时会被迫反复打开。
    /// 这里改为 Popover：内部按钮只更新筛选状态，点击外部 / Esc / 失焦再交给系统关闭。
    private func filterPopoverButton(_ viewModel: WeeklyContentViewModel) -> some View {
        Button {
            isFilterPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text("weekly.filter.title")
                Text(viewModel.filterSummaryTitle)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("weekly.filter.title")
        .popover(isPresented: $isFilterPopoverPresented, arrowEdge: .bottom) {
            weeklyFilterPopover(viewModel)
                .appLocaleEnvironment()
        }
    }

    private func weeklyFilterPopover(_ viewModel: WeeklyContentViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                weeklyFilterSection("weekly.filter.source") {
                    ForEach(viewModel.availableSourceFilters) { source in
                        weeklyFilterRow(
                            title: source.localizedTitle,
                            trailingCount: source.count,
                            isSelected: source == viewModel.selectedSource
                        ) {
                            clearWeeklyDetailSelectionIfChanging(source != viewModel.selectedSource)
                            viewModel.changeSource(to: source)
                        }
                    }
                }

                weeklyFilterDivider

                weeklyFilterSection("weekly.filter.coverage") {
                    ForEach(WeeklySourceCoverageFilter.allCases) { coverage in
                        weeklyFilterRow(
                            title: coverage.localizedTitle,
                            isSelected: coverage == viewModel.selectedCoverage
                        ) {
                            clearWeeklyDetailSelectionIfChanging(coverage != viewModel.selectedCoverage)
                            viewModel.changeCoverage(to: coverage)
                        }
                    }
                }

                weeklyFilterDivider

                weeklyFilterSection("weekly.filter.repoState") {
                    weeklyFilterRow(
                        title: String.l10n("weekly.filter.repoState.hideArchived"),
                        isSelected: viewModel.hideArchivedRepos
                    ) {
                        clearWeeklyDetailSelection()
                        viewModel.changeHideArchivedRepos(to: !viewModel.hideArchivedRepos)
                    }
                    weeklyFilterRow(
                        title: String.l10n("weekly.filter.repoState.hideForks"),
                        isSelected: viewModel.hideForkRepos
                    ) {
                        clearWeeklyDetailSelection()
                        viewModel.changeHideForkRepos(to: !viewModel.hideForkRepos)
                    }
                }

                weeklyFilterDivider

                weeklyFilterSection("weekly.filter.stars") {
                    ForEach(WeeklyStarsFilter.allCases) { starsFilter in
                        weeklyFilterRow(
                            title: starsFilter.localizedTitle,
                            isSelected: starsFilter == viewModel.selectedStarsFilter
                        ) {
                            clearWeeklyDetailSelectionIfChanging(starsFilter != viewModel.selectedStarsFilter)
                            viewModel.changeStarsFilter(to: starsFilter)
                        }
                    }
                }

                weeklyFilterDivider

                weeklyFilterSection("weekly.filter.activity") {
                    ForEach(WeeklyPushedRecencyFilter.allCases) { pushedFilter in
                        weeklyFilterRow(
                            title: pushedFilter.localizedTitle,
                            isSelected: pushedFilter == viewModel.selectedPushedRecency
                        ) {
                            clearWeeklyDetailSelectionIfChanging(pushedFilter != viewModel.selectedPushedRecency)
                            viewModel.changePushedRecency(to: pushedFilter)
                        }
                    }
                }

                weeklyFilterDivider

                Button {
                    clearWeeklyDetailSelectionIfChanging(viewModel.hasActiveFilters)
                    viewModel.resetFilters()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 16)
                        Text("weekly.filter.reset")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .opacity(viewModel.hasActiveFilters ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!viewModel.hasActiveFilters)
            }
            .padding(.vertical, 10)
        }
        .frame(width: Self.filterPopoverWidth, alignment: .leading)
        .frame(maxHeight: 620)
    }

    private func weeklyFilterSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            content()
        }
    }

    private var weeklyFilterDivider: some View {
        Divider()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func weeklyFilterRow(
        title: String,
        trailingCount: Int? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let trailingCount {
                    Text(trailingCount, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func weeklySortBinding(_ viewModel: WeeklyContentViewModel) -> Binding<WeeklyFeedSort> {
        Binding(
            get: { viewModel.selectedSort },
            set: { sort in
                clearWeeklyDetailSelectionIfChanging(sort != viewModel.selectedSort)
                viewModel.changeSort(to: sort)
                settings.setListPreferenceValue(
                    sort.rawValue,
                    for: "explore.weekly.sort",
                    login: authSession.state.user?.login
                )
            }
        )
    }

    private func weeklySortTitle(_ sort: WeeklyFeedSort) -> LocalizedStringKey {
        switch sort {
        case .defaultOrder: return "weekly.sort.default"
        case .starsDesc: return "weekly.sort.starsDesc"
        case .starsAsc: return "weekly.sort.starsAsc"
        case .updatedDesc: return "weekly.sort.updatedDesc"
        case .updatedAsc: return "weekly.sort.updatedAsc"
        case .createdDesc: return "weekly.sort.createdDesc"
        case .createdAsc: return "weekly.sort.createdAsc"
        case .nameAsc: return "weekly.sort.nameAsc"
        case .nameDesc: return "weekly.sort.nameDesc"
        }
    }

    private func weeklySortIcon(_ sort: WeeklyFeedSort) -> String {
        switch sort {
        case .defaultOrder: return "sparkles"
        case .starsDesc: return "star.fill"
        case .starsAsc: return "star"
        case .updatedDesc, .updatedAsc: return "clock.arrow.circlepath"
        case .createdDesc: return "calendar.badge.plus"
        case .createdAsc: return "calendar"
        case .nameAsc: return "a.square"
        case .nameDesc: return "z.square"
        }
    }

    private func restoreSortPreferenceIfNeeded(_ viewModel: WeeklyContentViewModel) {
        guard let raw = settings.listPreferenceValue(
            for: "explore.weekly.sort",
            login: authSession.state.user?.login
        ),
              let sort = WeeklyFeedSort(rawValue: raw),
              sort != viewModel.selectedSort
        else { return }
        viewModel.changeSort(to: sort)
    }

    /// 顶部刷新按钮。
    ///
    /// R-01 §3.1.4 Step 7.3：自写 rotationEffect + 0.9s repeatForever 改用统一的
    /// SyncIconButton（图标 / 旋转动画 / hover / disabled / reduceMotion 全套统一）。
    /// 节奏从 0.9s 改为 1.0s（与 SidebarSyncButton / TrendingView toolbar / cacheFooter 对齐）。
    @ViewBuilder
    private func refreshButton(_ viewModel: WeeklyContentViewModel) -> some View {
        SyncIconButton(
            isRefreshing: viewModel.isLoading,
            disabled: viewModel.isLoading,
            tooltip: String.l10n("weekly.refresh")
        ) {
            refreshCurrentWeeklyList(viewModel)
        }
    }

    /// Weekly 底层会更新 bulk 快照，但发布到 UI 的始终是当前筛选结果。
    private func refreshCurrentWeeklyList(_ viewModel: WeeklyContentViewModel) {
        Task { await viewModel.reload() }
    }

    // MARK: - Project List

    private func projectList(_ viewModel: WeeklyContentViewModel) -> some View {
        let selection = dependencies.weeklySelectionService
        let registry = dependencies.starredRegistry
        // W12 PR-4：weekly 多选 store。多选模式下点击行 toggle 选中，否则进入详情。
        let multiStore = dependencies.weeklyMultiSelectionStore
        let visibleItems = globalFilteredItems(viewModel.items)
        return List {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, project in
                Button {
                    if multiStore.isActive {
                        multiStore.toggle(SelectionSnapshot(
                            ghRepoId: project.ghRepoId,
                            owner: project.owner,
                            name: project.name
                        ))
                    } else {
                        selection.select(project)
                    }
                } label: {
                    // R-01 v1.2 Phase B4（2026-06-10）：weekly row 切到 UnifiedRepoRow，
                    // 与 manage / trending 视觉同款；周刊期号通过 `CardBadge.weeklyIssue`
                    // 在 chip 行显示，星标 ✓ 由 `StarredRegistry` 驱动联动。
                    UnifiedRepoRow(
                        card: project.asCardData(
                            registry: registry,
                            isInLibrary: isInLibrary(project.ghRepoId),
                            openSSFScore: dependencies.openSSFScoreStore.badge(for: project.ghRepoId)
                        ),
                        isSelected: multiStore.isActive
                            ? multiStore.contains(ghRepoId: project.ghRepoId)
                            : (selection.selectedItem?.id == project.id),
                        showStarredCheckmark: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                // HOM-201 P1-1（2026-06-14）：weekly 行 hover 500ms 后预拉 trending README，
                // 与 trending 列表同款（weekly 详情走 loadTrending 命中 trending_readmes 表）。
                .readmePrefetch { [readmeAPI = dependencies.readmeAPI, owner = project.owner, name = project.name] in
                    await readmeAPI.prefetchTrending(owner: owner, repo: name)
                }
                .contextMenu {
                    Button(action: { open(project.url) }) {
                        Text("weekly.action.openRepo")
                    }
                    if let issueURL = project.weekly?.issueURL {
                        Button(action: { open(issueURL) }) {
                            Text("weekly.action.openIssue")
                        }
                    }
                    Button(action: { copy(project.url.absoluteString) }) {
                        Text("weekly.action.copyURL")
                    }
                }
                .listRowReveal(
                    index: index,
                    snapshotID: viewModel.itemsRevision
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .automaticListPagination(
                    appearingIndex: index,
                    visibleItemCount: visibleItems.count,
                    loadedItemCount: viewModel.items.count,
                    hasMore: viewModel.hasMore,
                    isLoading: viewModel.isLoading || viewModel.isLoadingMore,
                    identity: "weekly-\(viewModel.itemsRevision)"
                ) {
                    await viewModel.loadMoreIfNeeded()
                }
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .automaticListPaginationFill(
            visibleItemCount: visibleItems.count,
            loadedItemCount: viewModel.items.count,
            hasMore: viewModel.hasMore,
            isLoading: viewModel.isLoading || viewModel.isLoadingMore,
            identity: "weekly-\(viewModel.itemsRevision)"
        ) {
            await viewModel.loadMoreIfNeeded()
        }
        // W12 PR-5：Cmd+A 全选当前可见 weekly project（仅 multi-select active 时生效）。
        // 4 场景同款机制：隐藏按钮 + keyboardShortcut。
        .background {
            Button {
                let snapshots = viewModel.items.map {
                    SelectionSnapshot(ghRepoId: $0.ghRepoId, owner: $0.owner, name: $0.name)
                }
                multiStore.selectAll(snapshots)
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!multiStore.isActive)
            .hidden()
        }
        .task(id: viewModel.itemsRevision) {
            // Explore 分类切换时先让周刊首屏提交，再补 Wiki / OpenSSF / Health 信号。
            await Task.yield()
            let repoIDs = viewModel.items.map(\.ghRepoId)
            async let wiki: Void = reloadWikiAvailabilityMap(for: viewModel.items)
            async let openSSF: Void = dependencies.openSSFScoreStore.loadCachedScores(for: repoIDs)
            async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(for: repoIDs)
            _ = await (wiki, openSSF, health)
        }
    }

    // MARK: - Helpers

    private func ensureViewModel() -> WeeklyContentViewModel {
        if let viewModel { return viewModel }
        let model = WeeklyContentViewModel(
            api: dependencies.weeklyAPI,
            selectionService: dependencies.weeklySelectionService,
            languageStore: dependencies.weeklyLanguageStore,
            bulkRepository: dependencies.weeklyBulkRepository
        )
        viewModel = model
        return model
    }

    private func syncExternalLanguage(to viewModel: WeeklyContentViewModel) {
        let language = selectedLanguage ?? ""
        guard language != viewModel.selectedLanguage else { return }
        clearWeeklyDetailSelection()
        viewModel.changeLanguage(to: language)
    }

    private func syncBindingLanguage(from viewModel: WeeklyContentViewModel) {
        let normalized = viewModel.selectedLanguage.isEmpty ? nil : viewModel.selectedLanguage
        if selectedLanguage != normalized {
            selectedLanguage = normalized
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func clearWeeklyDetailSelection() {
        dependencies.weeklySelectionService.clearSelection()
    }

    private func clearWeeklyDetailSelectionIfChanging(_ isChanging: Bool) {
        guard isChanging else { return }
        clearWeeklyDetailSelection()
    }

    private func isInLibrary(_ repoId: Int64) -> Bool {
        libraryStateMap[repoId] == .inLibrary
    }

    private func globalFilteredItems(_ items: [WeeklyFeedItem]) -> [WeeklyFeedItem] {
        items.filter { item in
            matchesGlobalFilters(
                repoId: item.ghRepoId,
                owner: item.owner,
                name: item.name,
                language: item.language,
                isArchived: item.card.isArchived,
                isFork: item.card.isFork
            )
        }
    }

    private func matchesGlobalFilters(
        repoId: Int64,
        owner: String,
        name: String,
        language: String?,
        isArchived: Bool,
        isFork: Bool
    ) -> Bool {
        guard settings.starFilter.matches(
            isStarred: dependencies.starredRegistry.contains(ghRepoId: repoId)
        ) else { return false }
        if settings.hideArchived, isArchived { return false }
        if settings.hideForks, isFork { return false }
        if !settings.globalFilterLanguages.isEmpty {
            guard let language else { return false }
            let selected = settings.globalFilterLanguages.contains {
                $0.caseInsensitiveCompare(language) == .orderedSame
            }
            guard selected else { return false }
        }
        switch settings.libraryFilter {
        case .all:
            break
        case .inLibrary:
            guard libraryStateMap[repoId] == .inLibrary else { return false }
        case .outsideLibrary:
            guard libraryStateMap[repoId] != .inLibrary else { return false }
        }
        if !matchesWikiFilter(repoId: repoId) { return false }
        if !matchesAvailability(dependencies.repoHealthStore.snapshot(for: repoId) != nil, filter: settings.healthAvailabilityFilter) {
            return false
        }
        if !matchesAvailability(dependencies.openSSFScoreStore.record(for: repoId)?.badgeData != nil, filter: settings.openSSFAvailabilityFilter) {
            return false
        }
        return true
    }

    private func matchesWikiFilter(repoId: Int64) -> Bool {
        guard settings.wikiAvailabilityFilter != .unknown else { return true }
        guard let available = wikiAvailabilityMap[repoId] else { return false }
        return matchesAvailability(available, filter: settings.wikiAvailabilityFilter)
    }

    private func matchesAvailability(_ available: Bool, filter: RepoSignalAvailabilityFilter) -> Bool {
        switch filter {
        case .unknown: return true
        case .available: return available
        case .missing: return !available
        }
    }

    private func reloadLibraryStateMap() async {
        libraryStateMap = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
    }

    private func reloadWikiAvailabilityMap(for items: [WeeklyFeedItem]) async {
        guard settings.wikiAvailabilityFilter != .unknown else {
            wikiAvailabilityMap = [:]
            return
        }
        let requests = items.map {
            WikiAvailabilityRequest(id: $0.ghRepoId, owner: $0.owner, repo: $0.name)
        }
        let snapshot = await WikiAvailabilitySnapshotLoader.load(requests: requests)
        guard !Task.isCancelled else { return }
        wikiAvailabilityMap = snapshot
    }

    private func observeLibraryStateChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoId = note.userInfo?["repoId"] as? Int64,
                  let raw = note.userInfo?["libraryState"] as? String else { continue }
            libraryStateMap[repoId] = LibraryState.parse(raw)
        }
    }

    private func applyWeeklyDetailSelectionPolicy(from items: [WeeklyFeedItem]) {
        let selection = dependencies.weeklySelectionService
        guard !items.isEmpty else {
            selection.clearSelection()
            return
        }
        guard settings.openFirstDetailOnCategoryChange else {
            if let selected = selection.selectedItem,
               !items.contains(where: { $0.id == selected.id }) {
                selection.clearSelection()
            }
            return
        }
        if let selected = selection.selectedItem,
           items.contains(where: { $0.id == selected.id }) {
            return
        }
        selection.select(items.first)
    }

    /// 空 / 错误状态视图。
    /// retry 闭包给 Button 直接调用，错误态需要"重试"，空态默认只是再刷一次。
    @ViewBuilder
    private func emptyState(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleText: String? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        // 注：因为 EmptyStateView 是 generic on Accessory，retry 有无两种分支
        // 不能共用一个 if-else（generic 参数不一致编译期就分裂为两个类型），
        // 所以这里拆成两条独立的 EmptyStateView 调用。
        if let retry {
            EmptyStateView(
                systemImage: systemImage,
                title: title,
                subtitle: subtitle,
                subtitleText: subtitleText,
                spacing: 12
            ) {
                Button(action: retry) {
                    Text("weekly.action.retry")
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            EmptyStateView(
                systemImage: systemImage,
                title: title,
                subtitle: subtitle,
                subtitleText: subtitleText,
                spacing: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

}

// R-01 v1.2 Phase B4（2026-06-10）：原 `WeeklyProjectRow` 已删除，
// row 视觉统一由 `UnifiedRepoRow + project.asCardData(registry:)` 承接。
// 周刊期号徽章通过 `CardBadge.weeklyIssue` 在 chip 行展示，accent 颜色由
// `RepoCardViewData.accentColor` 计算（语言色优先 → 系统强调色，与列表统一）。

// MARK: - ViewModel

/// 当前数据源标识。
///
/// R-06.4 双轨制：UI 不关心走哪条路径，但 ViewModel 内部要靠这个 flag 决定
/// changeSource / changeSort / changeLanguage / loadMoreIfNeeded 走"本地纯计算"还是"远端分页"。
enum WeeklyDataSource: Sendable, Equatable {
    /// 本地缓存模式：所有筛选 / 排序 / 分页都在已经落盘的 4000 条上做。
    case local
    /// 远端分页模式：缓存未命中或首次入场 fallback;与 R-06.4 前的旧路径完全一致。
    case remote
}

/// Weekly 分类专用 ViewModel。
///
/// R-06.4 渐进式 SWR 双轨制（详见文件头 §渐进式 SWR 双轨制 注释）：
/// - `.local` 模式：source + coverage + repo state + stars + pushed + sort + lang
///   在本地全量集合上做，客户端分页只是切到当前 page * pageSize
/// - `.remote` 模式：保持旧分页 API 行为完全等同。
/// - `itemsRevision` 仍保持原语义：筛选切换 / 重新加载时 bump，分页追加 / 内部切片不 bump。
@MainActor
@Observable
final class WeeklyContentViewModel {

    // MARK: - Constants

    /// 客户端 bulk 缓存 TTL，与后端 bulk 快照的 6h TTL 保持一致。
    /// 两端采用相同新鲜度窗口，避免客户端继续展示已经跨过服务端刷新周期的旧快照。
    static let bulkTTL: TimeInterval = 6 * 60 * 60

    /// `.local` 模式下客户端分页 page size（与后端 default page=20 对齐，让"切到 local
    /// 后滚动"与"remote 模式滚动"视觉体验一致）。
    private static let localPageSize: Int = 20
    /// 常用 source / language / sort 组合只保留近期工作集，避免会话内无限增长。
    private static let preparedSnapshotCapacity: Int = 12

    // MARK: - State

    /// UI 当前展示的 items（可能是 `.local` 全量本地分页切片，也可能是 `.remote` 累积分页结果）。
    private(set) var items: [WeeklyFeedItem] = []
    private(set) var total: Int = 0
    private(set) var page: Int = 1
    private(set) var hasMore: Bool = false

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadError: String?
    /// 有可用列表时网络刷新失败的横条提示（与探索发现 / 趋势同语义）。
    private(set) var cacheWarning: String?
    /// 入场动画 / row-reveal 用的"身份快照"版本，仅在筛选切换 / 重新加载时 bump。
    private(set) var itemsRevision: Int = 0

    /// 当前数据源；UI 可读以便将来展示"本地"徽章（暂未做）。
    private(set) var dataSource: WeeklyDataSource = .remote

    /// 来源筛选当前值；setter 由 `changeSource(to:)` 控制以保证副作用统一。
    private(set) var selectedSource: WeeklySourceFilter = .all
    /// 收录强度筛选当前值。
    private(set) var selectedCoverage: WeeklySourceCoverageFilter = .all
    /// 是否隐藏 GitHub archived 仓库。默认不隐藏，保证初始列表和后端 feed 一致。
    private(set) var hideArchivedRepos = false
    /// 是否隐藏 fork 仓库。默认不隐藏，避免误伤优秀 fork 项目。
    private(set) var hideForkRepos = false
    /// Stars 阈值筛选当前值。
    private(set) var selectedStarsFilter: WeeklyStarsFilter = .all
    /// 最近 push 时间窗筛选当前值。
    private(set) var selectedPushedRecency: WeeklyPushedRecencyFilter = .all
    /// 排序当前值；setter 由 `changeSort(to:)` 控制以保证副作用统一。
    private(set) var selectedSort: WeeklyFeedSort = .defaultOrder
    private(set) var selectedLanguage: String = ""
    /// 设置页「感兴趣语言」镜像。「其他」分类的本地过滤依赖它，由 View onChange 同步。
    var interestedLanguages: [String] = [] {
        didSet {
            guard oldValue != interestedLanguages else { return }
            // 只有「其他」分类的过滤结果依赖感兴趣语言，变化时才重新筛选。
            guard selectedLanguage == TrendingLanguage.otherRawValue else { return }
            reapplyFilters()
        }
    }
    /// bulk v2 返回并持久化的固定来源目录；UI 筛选不再枚举硬编码渠道。
    private(set) var sourceDescriptors: [WeeklySourceDescriptor] = []

    var availableSourceFilters: [WeeklySourceFilter] {
        guard !sourceDescriptors.isEmpty else { return WeeklySourceFilter.defaultFilters }
        return [.all] + sourceDescriptors
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(WeeklySourceFilter.init(descriptor:))
    }

    var filterSummaryTitle: String {
        guard activeFilterCount > 0 else {
            return String.l10n("general.all")
        }
        let filters = String(format: String.l10n("weekly.filter.summary.activeFormat"), activeFilterCount)
        let resultCount = String(format: String.l10n("weekly.filter.summary.resultCountFormat"), total)
        return "\(filters) · \(resultCount)"
    }

    private var activeFilterCount: Int {
        var count = 0
        if selectedSource != .all { count += 1 }
        if selectedCoverage != .all { count += 1 }
        if hideArchivedRepos { count += 1 }
        if hideForkRepos { count += 1 }
        if selectedStarsFilter != .all { count += 1 }
        if selectedPushedRecency != .all { count += 1 }
        return count
    }

    var hasActiveFilters: Bool {
        activeFilterCount > 0
    }

    /// 这些筛选后端分页接口暂不支持，必须基于 bulk 全量数据过滤。
    private var usesLocalOnlyFilters: Bool {
        selectedCoverage != .all ||
        hideArchivedRepos ||
        hideForkRepos ||
        selectedStarsFilter != .all ||
        selectedPushedRecency != .all
    }

    /// 语言下拉数据源（含 count，供 `LanguagePickerMenu` 渲染图标 + 名称 + 数量）。
    ///
    /// 不在这里 prepend「全部」哨兵——`LanguagePickerMenu` 内部会自动加在最前，
    /// ViewModel 只关心后端聚合数据本身。
    var languageAggregates: [TrendingLanguageAggregateDTO] {
        languageStore.displayList
    }

    /// 仅用于 `loadLanguagesIfNeeded` 校验当前 selection 是否还在合法集合内。
    /// 避免后端语言列表刷新后落到一个已不存在的 key。
    private var validLanguageKeys: Set<String> {
        var set = Set<String>(languageStore.displayList.map(\.key))
        set.insert("")  // 「全部」哨兵
        set.insert(TrendingLanguage.otherRawValue)  // 「其他」哨兵（本地过滤，非后端语言）
        return set
    }

    // MARK: - Local cache state

    /// `.local` 模式下持有的当前 source + sort + lang 筛选结果**全量**（未分页切片前）。
    /// 切 source / sort / lang 时只需重排重过滤这个数组再切片，零网络。
    private var filteredLocalItems: [WeeklyFeedItem] = []
    /// bulk 缓存的"原始全量"——`filteredLocalItems` 是它的过滤+排序产物。
    private var bulkAllItems: [WeeklyFeedItem] = []
    /// bulk 事实源每次整体替换都会推进；旧派生结果不能跨 revision 命中。
    private var bulkSourceRevision: Int = 0
    private var preparedSnapshots: [WeeklyPreparedSnapshotKey: [WeeklyFeedItem]] = [:]
    private var preparedSnapshotLRU: [WeeklyPreparedSnapshotKey] = []
    /// 本地筛选任务使用独立代次，不与网络 generation 混用，避免两种取消语义互相干扰。
    private var localDerivationGeneration: Int = 0
    private var localFilterTask: Task<[WeeklyFeedItem], Never>?
    /// 定向测试确认 A-B-A 命中 prepared snapshot 时不重复进入全量筛选。
    private(set) var localDerivationCountForTesting: Int = 0
    /// true 表示当前 `.local` 来自 SQLite 分页查询，而不是内存全量切片。
    private var usesPagedCache = false
    /// 上次 bulk 拉取的客户端时间戳（用于判 6h TTL）。
    private(set) var lastBulkFetchedAt: Date?

    // MARK: - Dependencies

    private let api: WeeklyAPI
    /// 把 total 推到外部 sidebar 计数徽章 / detail pane 路由的共享状态。
    /// 解耦 sidebar 与列表 ViewModel：sidebar 不直接持有 ViewModel，避免双向依赖。
    private let selectionService: WeeklySelectionService?
    private let languageStore: WeeklyLanguageStore
    private let bulkRepository: WeeklyBulkRepository

    /// 标记当前 in-flight 请求的代次；切换筛选 / reload 时 bump，
    /// 旧请求即便回来也会因为代次不匹配而被丢弃,避免顺序错乱。
    private var generation: Int = 0

    /// Weekly 本地派生的完整查询身份。recencyDay 防止“最近 N 天”的快照跨日期复用。
    private struct WeeklyPreparedSnapshotKey: Hashable, Sendable {
        let source: String
        let coverage: String
        let hideArchived: Bool
        let hideForks: Bool
        let stars: Int
        let pushedRecency: Int
        let recencyDay: Int
        let language: String
        let sort: String
        let sourceRevision: Int
        /// 「其他」分类的排除集合（排序拼接）；非「其他」时为空串。
        let interestedLanguages: String
    }

    init(
        api: WeeklyAPI,
        selectionService: WeeklySelectionService? = nil,
        languageStore: WeeklyLanguageStore,
        bulkRepository: WeeklyBulkRepository
    ) {
        self.api = api
        self.selectionService = selectionService
        self.languageStore = languageStore
        self.bulkRepository = bulkRepository
    }

    // MARK: - Public

    /// 首次进入页面调用；如果已有数据就跳过，避免重新进入时把缓存丢掉。
    ///
    /// R-06.4 SWR 入场流程：
    /// 1. 先读 SQLite 缓存；命中 → 立即上屏切到 `.local`；
    /// 2. 命中 + TTL 内 → 不发任何请求；命中 + TTL 过期 → 后台静默 bulkSync；
    /// 3. 未命中 → fallback 走老分页 fetchRepos(page=1) 200ms 出图，并在后台 bulkSync 落盘。
    func loadInitialIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        // 创建 ViewModel 后首帧就会渲染 content；先进入 loading，避免远端周刊未返回前闪出空态。
        isLoading = true
        defer { isLoading = false }

        // Step 1: 尝试从本地缓存读
        if let cached = await bulkRepository.cachedPage(query: makeCacheQuery(page: 1)) {
            applyPagedCacheSnapshot(cached, page: 1, appending: false, bumpRevision: false)
            // Step 2: TTL 判断
            if isCacheFresh(at: cached.lastFetchedAt) {
                return  // 6h 内，零网络上屏
            }
            // 缓存过期 → 后台静默刷新（不阻塞）
            Task { await self.silentBulkSync() }
            return
        }

        // Step 3: 缓存未命中 → 老分页拉第一页立刻上屏 + 后台 bulkSync 落盘
        await loadRemotePage()
        Task { await self.silentBulkSync() }
    }

    func loadLanguagesIfNeeded() async {
        await languageStore.reloadIfNeeded()
        if !selectedLanguage.isEmpty, !validLanguageKeys.contains(selectedLanguage) {
            selectedLanguage = ""
            await reload()
        }
    }

    /// 主动刷新：toolbar 刷新按钮 / pull-to-refresh 走这里。
    ///
    /// R-06.4：永远走 bulkSync（forceNetwork 语义），完成后切到 `.local`；网络失败时
    /// fallback 到原分页 API（与旧版本保持一致的"刷新失败也能用"语义）。
    func reload() async {
        let myGen = bumpGeneration()
        isLoading = true
        isLoadingMore = false
        loadError = nil
        cacheWarning = nil

        do {
            let fetchResult = try await bulkRepository.fetchBulk()
            guard myGen == generation else { return }
            let bulk = fetchResult.bulk
            let lastFetchedAt: Date
            if case .cachedFallback = fetchResult.source {
                // 缓存回退不能把刷新时间推成「现在」，否则 TTL 会假新鲜。
                lastFetchedAt = await bulkRepository.lastRefreshedAt()
                    ?? lastBulkFetchedAt
                    ?? Date()
            } else {
                lastFetchedAt = Date()
            }
            let snapshot = WeeklyBulkCachedSnapshot(
                sources: bulk.sources,
                items: bulk.items,
                languages: bulk.languages,
                etag: bulk.etag,
                lastFetchedAt: lastFetchedAt,
                generatedAt: bulk.generatedAt,
                total: bulk.total
            )
            await applyLocalSnapshot(snapshot, bumpRevision: true)
            if case .cachedFallback = fetchResult.source {
                // applyLocalSnapshot 会清 cacheWarning；成功应用缓存后再挂横条。
                cacheWarning = Self.cacheFallbackWarning(fetchResult.fallbackErrorDescription)
            }
        } catch {
            guard myGen == generation else { return }
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadWeekly"),
                service: "Weekly"
            )
            if usesLocalOnlyFilters {
                if items.isEmpty {
                    loadError = friendly.message
                    total = 0
                    hasMore = false
                } else {
                    // 本地筛选依赖 bulk；失败时保留缓存列表并提示横条。
                    loadError = nil
                    cacheWarning = Self.cacheFallbackWarning(friendly.message)
                }
                friendly.record(category: "network", operation: "weekly.reloadBulkForFilters", service: "weekly")
                if myGen == generation {
                    isLoading = false
                }
                return
            }
            // bulk 彻底失败（无缓存可回退）→ 退到分页 API；若分页也失败且仍有列表，横条提示。
            AppLog.network.warning("Weekly reload bulkSync failed, falling back to paginated API: \(error.localizedDescription, privacy: .public)")
            await loadRemotePage()
            guard myGen == generation else { return }
            if !items.isEmpty, loadError != nil {
                cacheWarning = Self.cacheFallbackWarning(loadError)
                loadError = nil
            } else if items.isEmpty {
                loadError = loadError ?? friendly.message
            }
        }
        if myGen == generation {
            isLoading = false
        }
    }

    /// 滚到底部触发的"加载下一页"。
    ///
    /// `.local`：纯本地切片增长（瞬时）；`.remote`：保持旧分页行为。
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }

        if dataSource == .local {
            if usesPagedCache {
                await loadNextCachedPage()
            } else {
                advanceLocalPage()
            }
            return
        }

        let myGen = generation
        isLoadingMore = true
        defer {
            if myGen == generation {
                isLoadingMore = false
            }
        }

        let nextPage = page + 1
        do {
            let result = try await api.fetchRepos(
                query: WeeklyFeedQuery(
                    source: selectedSource,
                    language: selectedLanguage.isEmpty ? nil : selectedLanguage,
                    sort: selectedSort,
                    page: nextPage
                )
            )
            guard myGen == generation else { return }
            // 同 id 项目可能因为后端排序变动并发出现重复，去一次重保险。
            let existingIDs = Set(items.map(\.id))
            let appended = result.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: appended)
            page = result.page
            total = result.total
            hasMore = result.hasMore
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadWeekly"),
                service: "Weekly"
            )
            loadError = friendly.message
            friendly.record(category: "network", operation: "weekly.loadMore", service: "weekly")
            // 分页失败保留已有数据与 hasMore，用户滚动/刷新可继续重试。
        }
    }

    func changeSource(to newValue: WeeklySourceFilter) {
        guard newValue != selectedSource else { return }
        selectedSource = newValue
        reapplyFilters()
    }

    func changeCoverage(to newValue: WeeklySourceCoverageFilter) {
        guard newValue != selectedCoverage else { return }
        selectedCoverage = newValue
        reapplyFilters()
    }

    func changeHideArchivedRepos(to newValue: Bool) {
        guard newValue != hideArchivedRepos else { return }
        hideArchivedRepos = newValue
        reapplyFilters()
    }

    func changeHideForkRepos(to newValue: Bool) {
        guard newValue != hideForkRepos else { return }
        hideForkRepos = newValue
        reapplyFilters()
    }

    func changeStarsFilter(to newValue: WeeklyStarsFilter) {
        guard newValue != selectedStarsFilter else { return }
        selectedStarsFilter = newValue
        reapplyFilters()
    }

    func changePushedRecency(to newValue: WeeklyPushedRecencyFilter) {
        guard newValue != selectedPushedRecency else { return }
        selectedPushedRecency = newValue
        reapplyFilters()
    }

    /// 把 Weekly 筛选菜单内的条件恢复到默认值。
    ///
    /// 只重置当前菜单暴露的筛选项，不动排序和语言偏好：排序是相邻的独立控件，
    /// 语言来自 Sidebar/全局列表偏好，混在这里重置会让用户难以预期。
    func resetFilters() {
        guard hasActiveFilters else { return }
        selectedSource = .all
        selectedCoverage = .all
        hideArchivedRepos = false
        hideForkRepos = false
        selectedStarsFilter = .all
        selectedPushedRecency = .all
        reapplyFilters()
    }

    func changeSort(to newValue: WeeklyFeedSort) {
        guard newValue != selectedSort else { return }
        selectedSort = newValue
        reapplyFilters()
    }

    func changeLanguage(to newValue: String) {
        guard newValue != selectedLanguage else { return }
        selectedLanguage = newValue
        reapplyFilters()
    }

    private func reapplyFilters() {
        if dataSource == .local {
            if usesPagedCache {
                Task { await reloadCachedPage(bumpRevision: true) }
            } else {
                Task {
                    await applyFiltersLocally(
                        bumpRevision: true,
                        showSkeletonOnMiss: true
                    )
                }
            }
        } else {
            Task { await reload() }
        }
    }

    /// 给非 SwiftUI 调用方保留的统一预取判断；列表本身使用 `automaticListPagination`。
    func shouldTriggerLoadMore(at index: Int) -> Bool {
        !isLoading && !isLoadingMore && ListPaginationPolicy.shouldPrefetch(
            appearingIndex: index,
            itemCount: items.count,
            hasMore: hasMore
        )
    }

    // MARK: - Private: SWR

    /// 静默刷新：bulk 拉新 + 整批替换 + 切到 .local。失败时只记日志不打扰 UI。
    private func silentBulkSync() async {
        let myGen = generation
        do {
            let fetchResult = try await bulkRepository.fetchBulk()
            guard myGen == generation else { return }
            // 静默路径：缓存回退只记日志，不弹横条（用户没点刷新）。
            if case .cachedFallback = fetchResult.source {
                AppLog.network.warning(
                    "Weekly silent bulkSync cachedFallback: \(fetchResult.fallbackErrorDescription ?? "", privacy: .public)"
                )
                return
            }
            let bulk = fetchResult.bulk
            let snapshot = WeeklyBulkCachedSnapshot(
                sources: bulk.sources,
                items: bulk.items,
                languages: bulk.languages,
                etag: bulk.etag,
                lastFetchedAt: Date(),
                generatedAt: bulk.generatedAt,
                total: bulk.total
            )
            await applyLocalSnapshot(snapshot, bumpRevision: true)
        } catch {
            AppLog.network.warning("Weekly silent bulkSync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 远端分页 fallback：用于缓存未命中入场 / bulk 失败 fallback。
    /// 隐含语义"切回 `.remote`"——`bumpRevision` 在 reload 路径必为 true（让动画重播）。
    private func loadRemotePage() async {
        let myGen = generation  // 由调用方先 bumpGeneration（loadInitialIfNeeded 不需 bump）
        loadError = nil

        do {
            let result = try await api.fetchRepos(
                query: WeeklyFeedQuery(
                    source: selectedSource,
                    language: selectedLanguage.isEmpty ? nil : selectedLanguage,
                    sort: selectedSort,
                    page: 1
                )
            )
            guard myGen == generation else { return }
            dataSource = .remote
            items = result.items
            total = result.total
            page = result.page
            hasMore = result.hasMore
            itemsRevision += 1
            loadError = nil
            cacheWarning = nil
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadWeekly"),
                service: "Weekly"
            )
            loadError = friendly.message
            if items.isEmpty {
                total = 0
                hasMore = false
            }
            friendly.record(category: "network", operation: "weekly.loadRemotePage", service: "weekly")
        }
    }

    /// 把 bulk 缓存 snapshot 应用到当前状态，切到 `.local` 并应用全部筛选。
    /// `bumpRevision`：reload 路径要刷新入场动画；首次入场不刷（避免列表上来就抖一次）。
    private func applyLocalSnapshot(
        _ snapshot: WeeklyBulkCachedSnapshot,
        bumpRevision: Bool
    ) async {
        bulkAllItems = snapshot.items
        bulkSourceRevision &+= 1
        clearPreparedSnapshots()
        sourceDescriptors = snapshot.sources
        lastBulkFetchedAt = snapshot.lastFetchedAt
        dataSource = .local
        usesPagedCache = false
        loadError = nil
        cacheWarning = nil
        // 手动 / 静默刷新保留当前卡片，等新快照准备好后静默替换；首次进入本来就是空列表。
        await applyFiltersLocally(
            bumpRevision: bumpRevision,
            showSkeletonOnMiss: false
        )
    }

    private func applyPagedCacheSnapshot(
        _ snapshot: WeeklyBulkPageSnapshot,
        page: Int,
        appending: Bool,
        bumpRevision: Bool
    ) {
        lastBulkFetchedAt = snapshot.lastFetchedAt
        sourceDescriptors = snapshot.sources
        dataSource = .local
        usesPagedCache = true
        loadError = nil
        self.page = page
        total = snapshot.filteredTotal
        hasMore = page * Self.localPageSize < snapshot.filteredTotal
        if appending {
            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: snapshot.items.filter { !existingIDs.contains($0.id) })
        } else {
            items = snapshot.items
        }
        if bumpRevision {
            itemsRevision += 1
        }
        selectionService?.applyTotal(snapshot.catalogTotal)
    }

    private func reloadCachedPage(bumpRevision: Bool) async {
        let myGen = bumpGeneration()
        isLoading = true
        defer {
            if myGen == generation {
                isLoading = false
            }
        }
        guard let snapshot = await bulkRepository.cachedPage(query: makeCacheQuery(page: 1)),
              myGen == generation else { return }
        applyPagedCacheSnapshot(snapshot, page: 1, appending: false, bumpRevision: bumpRevision)
    }

    private func loadNextCachedPage() async {
        let myGen = generation
        isLoadingMore = true
        defer {
            if myGen == generation {
                isLoadingMore = false
            }
        }
        let nextPage = page + 1
        guard let snapshot = await bulkRepository.cachedPage(query: makeCacheQuery(page: nextPage)),
              myGen == generation else { return }
        applyPagedCacheSnapshot(snapshot, page: nextPage, appending: true, bumpRevision: false)
    }

    /// 在 `bulkAllItems` 基础上后台完成全量过滤与排序；MainActor 只发布首屏切片。
    ///
    /// 命中 prepared snapshot 时同步发布；miss 时取消上一派生任务，并在 await 后复核
    /// 完整查询身份与代次，快速切换筛选不会让旧结果覆盖新选择。
    private func applyFiltersLocally(
        bumpRevision: Bool,
        showSkeletonOnMiss: Bool
    ) async {
        let key = makePreparedSnapshotKey()
        if let filtered = preparedSnapshot(for: key) {
            publishPreparedLocalSnapshot(filtered, bumpRevision: bumpRevision)
            return
        }

        localDerivationGeneration &+= 1
        let derivationGeneration = localDerivationGeneration
        localFilterTask?.cancel()

        if showSkeletonOnMiss {
            isLoading = true
            items = []
            total = 0
            hasMore = false
        }

        let source = bulkAllItems
        let sourceFilter = selectedSource
        let coverageFilter = selectedCoverage
        let hideArchived = hideArchivedRepos
        let hideForks = hideForkRepos
        let starsFilter = selectedStarsFilter
        let pushedRecency = selectedPushedRecency
        let language = selectedLanguage
        let interestedLanguages = Set(self.interestedLanguages.map { $0.lowercased() })
        let sort = selectedSort
        let now = Date()
        localDerivationCountForTesting &+= 1
        let task = Task.detached(priority: .userInitiated) {
            Self.deriveLocalItems(
                source: source,
                sourceFilter: sourceFilter,
                coverageFilter: coverageFilter,
                hideArchived: hideArchived,
                hideForks: hideForks,
                starsFilter: starsFilter,
                pushedRecency: pushedRecency,
                language: language,
                interestedLanguages: interestedLanguages,
                sort: sort,
                now: now
            )
        }
        localFilterTask = task
        let filtered = await task.value

        guard derivationGeneration == localDerivationGeneration,
              key == makePreparedSnapshotKey(),
              !Task.isCancelled else { return }
        storePreparedSnapshot(filtered, for: key)
        publishPreparedLocalSnapshot(filtered, bumpRevision: bumpRevision)
        if showSkeletonOnMiss {
            isLoading = false
        }
    }

    private func publishPreparedLocalSnapshot(
        _ filtered: [WeeklyFeedItem],
        bumpRevision: Bool
    ) {
        filteredLocalItems = filtered
        total = filtered.count
        page = 1
        let pageSize = Self.localPageSize
        let slice = Array(filtered.prefix(pageSize))
        items = slice
        hasMore = filtered.count > slice.count
        if bumpRevision {
            itemsRevision += 1
        }
        // Sidebar 徽章始终展示 Weekly 全量，不受语言 / source / 其他筛选影响。
        // filtered.count = 当前筛选后的可见数量（如选中某语言可能只有 800），
        // bulkAllItems.count = 后端 bulk 全量（可能是 3000+）。
        selectionService?.applyTotal(bulkAllItems.count)
    }

    private func makePreparedSnapshotKey(now: Date = Date()) -> WeeklyPreparedSnapshotKey {
        let recencyDay = selectedPushedRecency == .all
            ? 0
            : Int(now.timeIntervalSince1970 / 86_400)
        // 「其他」分类的过滤结果依赖感兴趣语言，快照 key 必须纳入，否则改设置后命中脏快照。
        let interestedKey = selectedLanguage == TrendingLanguage.otherRawValue
            ? interestedLanguages.map { $0.lowercased() }.sorted().joined(separator: ",")
            : ""
        return WeeklyPreparedSnapshotKey(
            source: selectedSource.rawValue,
            coverage: selectedCoverage.rawValue,
            hideArchived: hideArchivedRepos,
            hideForks: hideForkRepos,
            stars: selectedStarsFilter.rawValue,
            pushedRecency: selectedPushedRecency.rawValue,
            recencyDay: recencyDay,
            language: selectedLanguage.lowercased(),
            sort: selectedSort.rawValue,
            sourceRevision: bulkSourceRevision,
            interestedLanguages: interestedKey
        )
    }

    private func preparedSnapshot(for key: WeeklyPreparedSnapshotKey) -> [WeeklyFeedItem]? {
        guard let snapshot = preparedSnapshots[key] else { return nil }
        preparedSnapshotLRU.removeAll { $0 == key }
        preparedSnapshotLRU.append(key)
        return snapshot
    }

    private func storePreparedSnapshot(
        _ snapshot: [WeeklyFeedItem],
        for key: WeeklyPreparedSnapshotKey
    ) {
        preparedSnapshots[key] = snapshot
        preparedSnapshotLRU.removeAll { $0 == key }
        preparedSnapshotLRU.append(key)
        while preparedSnapshotLRU.count > Self.preparedSnapshotCapacity {
            let evicted = preparedSnapshotLRU.removeFirst()
            preparedSnapshots.removeValue(forKey: evicted)
        }
    }

    private func clearPreparedSnapshots() {
        localDerivationGeneration &+= 1
        localFilterTask?.cancel()
        preparedSnapshots.removeAll(keepingCapacity: true)
        preparedSnapshotLRU.removeAll(keepingCapacity: true)
    }

    private nonisolated static func deriveLocalItems(
        source: [WeeklyFeedItem],
        sourceFilter: WeeklySourceFilter,
        coverageFilter: WeeklySourceCoverageFilter,
        hideArchived: Bool,
        hideForks: Bool,
        starsFilter: WeeklyStarsFilter,
        pushedRecency: WeeklyPushedRecencyFilter,
        language: String,
        interestedLanguages: Set<String>,
        sort: WeeklyFeedSort,
        now: Date
    ) -> [WeeklyFeedItem] {
        var filtered: [WeeklyFeedItem] = []
        filtered.reserveCapacity(source.count)

        for (index, item) in source.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            guard sourceFilter.matches(item), coverageFilter.matches(item) else { continue }
            if hideArchived, item.card.isArchived { continue }
            if hideForks, item.card.isFork { continue }
            guard starsFilter.matches(item), pushedRecency.matches(item, now: now) else { continue }
            if !language.isEmpty {
                if language == TrendingLanguage.uncategorizedKey {
                    guard (item.language ?? "").isEmpty else { continue }
                } else if language == TrendingLanguage.otherRawValue {
                    // 「其他」= 语言非空且不在「感兴趣语言」里。
                    guard let lang = item.language, !lang.isEmpty,
                          !interestedLanguages.contains(lang.lowercased()) else { continue }
                } else {
                    guard item.language?.caseInsensitiveCompare(language) == .orderedSame else { continue }
                }
            }
            filtered.append(item)
        }
        guard !Task.isCancelled else { return [] }
        filtered.sort(by: makeLocalSorter(sort))
        return filtered
    }

    private func advanceLocalPage() {
        let nextPage = page + 1
        let pageSize = Self.localPageSize
        let upper = min(nextPage * pageSize, filteredLocalItems.count)
        items = Array(filteredLocalItems.prefix(upper))
        page = nextPage
        hasMore = upper < filteredLocalItems.count
    }

    private func makeCacheQuery(page: Int) -> WeeklyBulkCacheQuery {
        WeeklyBulkCacheQuery(
            source: selectedSource,
            coverage: selectedCoverage,
            hideArchived: hideArchivedRepos,
            hideForks: hideForkRepos,
            starsFilter: selectedStarsFilter,
            pushedRecency: selectedPushedRecency,
            language: selectedLanguage,
            sort: selectedSort,
            page: page,
            pageSize: Self.localPageSize,
            now: Date()
        )
    }

    /// 6h TTL 判断；时间倒着算（lastFetchedAt 之后过了 < 6h 即新鲜）。
    private func isCacheFresh(at lastFetchedAt: Date) -> Bool {
        Date().timeIntervalSince(lastFetchedAt) < Self.bulkTTL
    }

    /// 与探索发现共用文案键：刷新失败但仍展示本地缓存。
    private static func cacheFallbackWarning(_ errorDescription: String?) -> String {
        // 底层 TLS / 网络细节只进日志；横条用固定用户文案。
        if let errorDescription, !errorDescription.isEmpty {
            AppLog.network.warning("Weekly cache fallback detail: \(errorDescription, privacy: .public)")
        }
        return String.l10n("explore.cacheFallback.warning")
    }

    /// 排序函数：与后端 `WeeklyFeedSort` 对齐（详见后端 `internal/store/sqlite.go`
    /// `QueryRepos` 排序分支）。本地 sort 必须与 server-side 等价，否则用户切到 .local
    /// 后切 sort 的视觉结果会与 .remote 模式不一致。
    private nonisolated static func makeLocalSorter(_ sort: WeeklyFeedSort) -> (WeeklyFeedItem, WeeklyFeedItem) -> Bool {
        switch sort {
        case .defaultOrder:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                if lhs.latestEventAt != rhs.latestEventAt {
                    return lhs.latestEventAt > rhs.latestEventAt
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .starsDesc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                if lhs.stars != rhs.stars {
                    return lhs.stars > rhs.stars
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .starsAsc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                if lhs.stars != rhs.stars {
                    return lhs.stars < rhs.stars
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .updatedDesc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let l = lhs.card.updatedAt ?? ""
                let r = rhs.card.updatedAt ?? ""
                if l != r { return l > r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .updatedAsc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let l = lhs.card.updatedAt ?? "\u{FFFD}"
                let r = rhs.card.updatedAt ?? "\u{FFFD}"
                if l != r { return l < r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .createdDesc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let l = lhs.card.createdAt ?? ""
                let r = rhs.card.createdAt ?? ""
                if l != r { return l > r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .createdAsc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let l = lhs.card.createdAt ?? "\u{FFFD}"
                let r = rhs.card.createdAt ?? "\u{FFFD}"
                if l != r { return l < r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .nameAsc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedAscending }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .nameDesc:
            return { lhs, rhs in
                if let pinned = comparePins(lhs, rhs) { return pinned }
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedDescending }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        }
    }

    /// 返回 nil 表示两项都未置顶，应继续执行用户选择的普通排序。
    /// 多个置顶项目严格按服务端 pin_position 排列，不受 Stars / 名称排序影响。
    private nonisolated static func comparePins(_ lhs: WeeklyFeedItem, _ rhs: WeeklyFeedItem) -> Bool? {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        guard lhs.isPinned, rhs.isPinned else { return nil }
        let leftPosition = lhs.pinPosition ?? Int.max
        let rightPosition = rhs.pinPosition ?? Int.max
        if leftPosition != rightPosition { return leftPosition < rightPosition }
        return lhs.ghRepoId > rhs.ghRepoId
    }

    // MARK: - Private

    private func bumpGeneration() -> Int {
        generation += 1
        return generation
    }
}

// MARK: - WeeklyFeedSort localized

extension WeeklyFeedSort {
    var localizedTitle: String {
        switch self {
        case .defaultOrder:
            return String.l10n("weekly.sort.default")
        case .starsDesc:
            return String.l10n("weekly.sort.starsDesc")
        case .starsAsc:
            return String.l10n("weekly.sort.starsAsc")
        case .updatedDesc:
            return String.l10n("weekly.sort.updatedDesc")
        case .updatedAsc:
            return String.l10n("weekly.sort.updatedAsc")
        case .createdDesc:
            return String.l10n("weekly.sort.createdDesc")
        case .createdAsc:
            return String.l10n("weekly.sort.createdAsc")
        case .nameAsc:
            return String.l10n("weekly.sort.nameAsc")
        case .nameDesc:
            return String.l10n("weekly.sort.nameDesc")
        }
    }
}
