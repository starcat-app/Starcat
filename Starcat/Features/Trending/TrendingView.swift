//
//  TrendingView.swift
//  Starcat
//
//  GitHub Trending 页面视图。
//
//  功能：
//  - 日/周/月榜切换
//  - 按语言筛选（由左侧 Trending 语言列表驱动）
//  - 展示 Trending 仓库列表
//  - 显示 AI 评分
//  - 显示个性化推荐区块
//  - 点击星标直接订阅到 Stars
//
//  设计约束：
//  - 使用 SwiftUI
//  - 遵循项目 UI 规范（focus ring 等）
//

import SwiftUI

// MARK: - Environment Key

private struct TrendingViewModelKey: EnvironmentKey {
    static let defaultValue: TrendingViewModel? = nil
}

extension EnvironmentValues {
    var trendingViewModel: TrendingViewModel? {
        get { self[TrendingViewModelKey.self] }
        set { self[TrendingViewModelKey.self] = newValue }
    }
}

struct TrendingView: View {

    /// "为你推荐"卡片开关。暂时关闭（dong4j 2026-06-01），需要时改回 true 即可。
    private static let showsRecommendations = false

    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: TrendingViewModel
    @State private var showLoginSheet: Bool = false
    @State private var libraryStateMap: [Int64: LibraryState] = [:]
    @State private var wikiAvailabilityMap: [Int64: Bool] = [:]
    @Binding private var selectedLanguage: TrendingLanguage

    /// 当前选中的 Trending repo ID（驱动 README 加载）。
    @Binding private var selectedRepoID: String?

    /// 当前选中的 Trending repo 完整数据（用于右侧详情页元信息展示）。
    @Binding private var selectedTrendingRepo: TrendingRepo?

    /// 当前榜单数量上报给父视图，用于 macOS navigation subtitle。
    private let onRepoCountChange: (Int) -> Void

    init(
        repository: any TrendingRepositoryProtocol,
        githubAPIClient: any GitHubAPIClientProtocol,
        selectedLanguage: Binding<TrendingLanguage>,
        selectedRepoID: Binding<String?> = .constant(nil),
        selectedTrendingRepo: Binding<TrendingRepo?> = .constant(nil),
        onRepoCountChange: @escaping (Int) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: TrendingViewModel(
            repository: repository,
            githubAPIClient: githubAPIClient
        ))
        _selectedLanguage = selectedLanguage
        _selectedRepoID = selectedRepoID
        _selectedTrendingRepo = selectedTrendingRepo
        self.onRepoCountChange = onRepoCountChange
    }

    /// Explore 父容器持有 ViewModel 的入口，切换子分类时保留缓存、分页和请求代际。
    init(
        viewModel: TrendingViewModel,
        selectedLanguage: Binding<TrendingLanguage>,
        selectedRepoID: Binding<String?> = .constant(nil),
        selectedTrendingRepo: Binding<TrendingRepo?> = .constant(nil),
        onRepoCountChange: @escaping (Int) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        _selectedLanguage = selectedLanguage
        _selectedRepoID = selectedRepoID
        _selectedTrendingRepo = selectedTrendingRepo
        self.onRepoCountChange = onRepoCountChange
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbarView

            Divider()

            // List 宿主始终存在。切到未加载桶时只在中栏局部覆盖骨架，不销毁列表树，
            // 因而工具栏、侧栏、详情栏和其它 TimelineView 动画都不会跟随重建。
            VStack(spacing: 0) {
                cacheWarningBanner
                ZStack {
                    contentView
                        .opacity(viewModel.hasPublishedCurrentQuery ? 1 : 0)
                        .allowsHitTesting(viewModel.hasPublishedCurrentQuery)

                    if !viewModel.hasPublishedCurrentQuery {
                        if let error = viewModel.loadError, !viewModel.isLoading {
                            errorView(message: error)
                        } else {
                            RepoSkeletonListView(rowCount: 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .task {
            reportRepoCount()
            async let libraryLoad: Void = reloadLibraryStateMap()
            if settings.libraryFilter != .all {
                await libraryLoad
            }
            await viewModel.updateLanguagePreferences(from: homeViewModel.languageStats)
            viewModel.interestedLanguages = settings.interestedLanguages
            await viewModel.updateGlobalFilter(trendingFilterSnapshot)
            // 切换语言或页面时先清详情，避免新列表加载完成前右栏残留旧 repo。
            clearTrendingDetailSelection()
            // 首次进入页面：按 TTL 决定是否拉网络（R-06.1，2026-06-15）
            //   - 缓存命中且在当前周期 TTL 内 → 不走网络（避免"二次入场动画"）
            //   - 缓存命中但 TTL 过期 → 上屏旧缓存 + 后台静默刷新
            //   - 缓存空 → 必拉
            // 用户主动按刷新按钮 / pull-to-refresh / 错误重试时改用 `.forceNetwork` 绕过 TTL
            await viewModel.activate(
                language: selectedLanguage,
                sort: restoredSortPreference()
            )
            if settings.libraryFilter == .all {
                await libraryLoad
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            applyTrendingDetailSelectionPolicy()
            reportRepoCount()
        }
        .task {
            await observeLibraryStateChanges()
        }
        .task(id: settings.wikiAvailabilityFilter.rawValue) {
            await reloadWikiAvailabilityMap(for: viewModel.filterCandidateRepos)
        }
        .onChange(of: homeViewModel.languageStats) { _, stats in
            Task {
                await viewModel.updateLanguagePreferences(from: stats)
            }
        }
        .onChange(of: settings.interestedLanguages) { _, languages in
            viewModel.interestedLanguages = languages
        }
        .onChange(of: trendingFilterSnapshot) { _, filter in
            Task {
                await viewModel.updateGlobalFilter(filter)
            }
        }
        .onChange(of: selectedLanguage) { _, language in
            clearTrendingDetailSelection()
            Task {
                await viewModel.selectLanguage(language)
                reportRepoCount()
            }
        }
        .onChange(of: viewModel.selectedPeriod) { _, _ in
            clearTrendingDetailSelection()
        }
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
                .appLocaleEnvironment()
        }
        .onChange(of: authSession.state.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                showLoginSheet = false
            }
        }
        // 选中 repo 变化时，同步更新 selectedTrendingRepo 供右侧详情页使用
        .onChange(of: selectedRepoID) { _, newID in
            if let id = newID {
                let matchingRepo: TrendingRepo? = viewModel.displayedRepos.first { $0.id == id }
                selectedTrendingRepo = matchingRepo
            } else {
                selectedTrendingRepo = nil
            }
        }
        .onChange(of: viewModel.repos.count) { _, _ in
            reportRepoCount()
        }
        .onChange(of: viewModel.reposRevision) { _, _ in
            applyTrendingDetailSelectionPolicy()
        }
        .onChange(of: settings.openFirstDetailOnCategoryChange) { _, enabled in
            guard enabled else { return }
            applyTrendingDetailSelectionPolicy()
        }
        .environment(\.trendingViewModel, viewModel)
        .starcatRefreshCommand(
            pane: .list,
            identity: "trending-\(viewModel.selectedPeriod.rawValue)-\(viewModel.selectedSort.rawValue)-\(selectedLanguage.rawValue)-\(viewModel.isRefreshing)-\(viewModel.isLoading)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: !viewModel.isRefreshing && !viewModel.isLoading
        ) {
            refreshCurrentTrendingList()
        }
    }

    private func reportRepoCount() {
        onRepoCountChange(viewModel.displayedRepos.count)
    }

    /// 把 MainActor-only 的 Observable store 投影成可 Sendable 的值快照。
    ///
    /// 关闭某个筛选时不复制对应 store 的集合，避免 badge 缓存补载导致无意义的整榜重算；
    /// View 只做 O(已加载信号数) 的边界投影，逐 repo 判断由 TrendingListPipeline actor 承担。
    private var trendingFilterSnapshot: TrendingListFilter {
        let starFilter = settings.starFilter
        let libraryFilter = settings.libraryFilter
        let wikiFilter = settings.wikiAvailabilityFilter
        let healthFilter = settings.healthAvailabilityFilter
        let openSSFFilter = settings.openSSFAvailabilityFilter

        let wikiKnownRepoIDs = wikiFilter == .unknown ? [] : Set(wikiAvailabilityMap.keys)
        let wikiAvailableRepoIDs: Set<Int64> = wikiFilter == .unknown ? [] : Set(
            wikiAvailabilityMap.compactMap { repoID, available in available ? repoID : nil }
        )
        let openSSFAvailableRepoIDs: Set<Int64> = openSSFFilter == .unknown ? [] : Set(
            dependencies.openSSFScoreStore.records.compactMap { repoID, record in
                record.badgeData == nil ? nil : repoID
            }
        )

        return TrendingListFilter(
            star: starFilter,
            library: libraryFilter,
            hideArchived: settings.hideArchived,
            hideForks: settings.hideForks,
            languages: Set(settings.globalFilterLanguages.map { $0.lowercased() }),
            wikiAvailability: wikiFilter,
            healthAvailability: healthFilter,
            openSSFAvailability: openSSFFilter,
            starredRepoIDs: starFilter == .all ? [] : dependencies.starredRegistry.ids,
            inLibraryRepoIDs: libraryFilter == .all
                ? []
                : Set(libraryStateMap.compactMap { repoID, state in state == .inLibrary ? repoID : nil }),
            wikiKnownRepoIDs: wikiKnownRepoIDs,
            wikiAvailableRepoIDs: wikiAvailableRepoIDs,
            healthAvailableRepoIDs: healthFilter == .unknown
                ? []
                : Set(dependencies.repoHealthStore.snapshots.keys),
            openSSFAvailableRepoIDs: openSSFAvailableRepoIDs
        )
    }

    private func clearTrendingDetailSelection() {
        selectedRepoID = nil
        selectedTrendingRepo = nil
    }

    private func isInLibrary(_ repoId: Int64) -> Bool {
        libraryStateMap[repoId] == .inLibrary
    }

    private func reloadLibraryStateMap() async {
        libraryStateMap = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
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

    private func applyTrendingDetailSelectionPolicy() {
        let visibleRepos = viewModel.displayedRepos
        guard !visibleRepos.isEmpty else {
            clearTrendingDetailSelection()
            return
        }
        guard settings.openFirstDetailOnCategoryChange else {
            refreshSelectedTrendingRepoFromCurrentList()
            return
        }
        if let id = selectedRepoID,
           let repo = visibleRepos.first(where: { $0.id == id }) {
            selectedTrendingRepo = repo
            return
        }
        guard let first = visibleRepos.first else {
            clearTrendingDetailSelection()
            return
        }
        selectedRepoID = first.id
        selectedTrendingRepo = first
    }

    private func refreshSelectedTrendingRepoFromCurrentList() {
        guard let id = selectedRepoID else {
            selectedTrendingRepo = nil
            return
        }
        guard let repo = viewModel.displayedRepos.first(where: { $0.id == id }) else {
            clearTrendingDetailSelection()
            return
        }
        selectedTrendingRepo = repo
    }

    // MARK: - Toolbar

    /// 顶部控制栏：时间范围和排序拆开，避免把“今天 / 本周 / 本月”误归类为排序。
    ///
    /// 约束：周期仍然是趋势列表的数据范围，变化时要清空当前详情选择；排序只调整当前
    /// 范围内的展示顺序，二者保持独立文案，给后续全局筛选重构留出清晰边界。
    private var toolbarView: some View {
        HStack(spacing: 10) {
            trendingPeriodMenu
            trendingSortMenu

            Spacer()

            HStack(spacing: 8) {
                freshnessIndicator
                refreshButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var trendingPeriodMenu: some View {
        Menu {
            Section("trending.period.title") {
                ForEach(TrendingPeriod.allCases) { period in
                    Button {
                        clearTrendingDetailSelectionIfChanging(period != viewModel.selectedPeriod)
                        Task {
                            await viewModel.selectPeriod(period)
                            reportRepoCount()
                        }
                    } label: {
                        filterMenuRow(
                            title: period.localizedDisplayName,
                            isSelected: period == viewModel.selectedPeriod
                        )
                    }
                }
            }
        } label: {
            // 与 UnifiedSortMenu 一致：按钮只显示当前选中项（今日/本周/本月），
            // 不用「周期」作固定标题——否则菜单打开后仍看不出当前范围。
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(viewModel.selectedPeriod.displayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("trending.period.title")
            .accessibilityValue(viewModel.selectedPeriod.displayName)
        }
        .fixedSize()
    }

    private var trendingSortMenu: some View {
        UnifiedSortMenu(
            selection: trendingSortBinding,
            options: Array(TrendingSortOption.allCases),
            displayName: { $0.titleKey },
            systemImage: { $0.systemImage },
            dividerBefore: { $0 == TrendingSortOption.allCases.first(where: \.isTrendingSpecificSort) }
        )
    }

    private var trendingSortBinding: Binding<TrendingSortOption> {
        Binding(
            get: { viewModel.selectedSort },
            set: { sort in
                clearTrendingDetailSelectionIfChanging(sort != viewModel.selectedSort)
                settings.setListPreferenceValue(
                    sort.rawValue,
                    for: "trending.sort",
                    login: authSession.state.user?.login
                )
                Task {
                    await viewModel.selectSort(sort)
                    applyTrendingDetailSelectionPolicy()
                    reportRepoCount()
                }
            }
        )
    }

    private func restoredSortPreference() -> TrendingSortOption {
        guard let raw = settings.listPreferenceValue(for: "trending.sort", login: authSession.state.user?.login),
              let sort = TrendingSortOption(rawValue: raw)
        else { return viewModel.selectedSort }
        return sort
    }

    @ViewBuilder
    private func filterMenuRow(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func clearTrendingDetailSelectionIfChanging(_ isChanging: Bool) {
        guard isChanging else { return }
        clearTrendingDetailSelection()
    }

    /// "12 分钟前" 新鲜度提示。
    /// - 没有 lastRefreshedAt 时整组隐藏（`formattedFreshness == nil`）
    /// - 超过当前周期 TTL 的 80%（`isStale`）变橙色提示陈旧，但不强制刷新
    @ViewBuilder
    private var freshnessIndicator: some View {
        if let text = viewModel.formattedFreshness {
            Text(text)
                .font(.caption)
                .foregroundStyle(viewModel.isStale ? Color.orange : Color.secondary)
                .help(absoluteFreshnessHelpText)
        }
    }

    /// 刷新 icon Button：常驻显示，isRefreshing 时图标旋转。
    /// hover 时 tooltip 显示"刷新榜单"或"上次刷新于 X 月 Y 日 HH:MM"。
    /// 使用共享 `SyncIconButton`（与详情页 cacheFooter 同款图标 + 旋转动画）。
    ///
    /// 用户主动操作走 `.forceNetwork` 绕过当前周期 TTL（R-06.1）—— 哪怕缓存"刚 5 分钟前才拉过"
    /// 也尊重用户的"我现在就要新数据"意图，不在按钮里做 TTL 短路否则用户会以为按钮坏了。
    private var refreshButton: some View {
        SyncIconButton(
            isRefreshing: viewModel.isRefreshing,
            disabled: viewModel.isRefreshing || viewModel.isLoading,
            tooltip: refreshButtonHelpText
        ) {
            refreshCurrentTrendingList()
        }
    }

    /// 与探索发现一致：有缓存时网络失败只出横条，不拆列表。
    @ViewBuilder
    private var cacheWarningBanner: some View {
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

    /// Toolbar 与 `⌘R` 都只刷新当前周期 / 语言桶，避免误刷新其它 Explore 分类。
    private func refreshCurrentTrendingList() {
        Task {
            await viewModel.reload(cachePolicy: .forceNetwork)
            reportRepoCount()
        }
    }

    /// hover tooltip：精确显示"上次刷新于 X 月 Y 日 HH:MM"（绝对时间）。
    /// 没有 lastRefreshedAt 时显示"还未刷新过"。
    private var absoluteFreshnessHelpText: String {
        guard let date = viewModel.lastRefreshedAt else {
            return String.l10n("trending.freshness.neverRefreshed")
        }
        return String(
            format: String.l10n("trending.freshness.lastRefreshedAtFormat"),
            absoluteTimeFormatter.string(from: date)
        )
    }

    /// 刷新按钮 tooltip：根据状态切换文案。
    private var refreshButtonHelpText: String {
        if viewModel.isRefreshing {
            return String.l10n("trending.refresh.inProgress")
        }
        if let date = viewModel.lastRefreshedAt {
            return String(
                format: String.l10n("trending.refresh.tooltipWithLastFormat"),
                absoluteTimeFormatter.string(from: date)
            )
        }
        return String.l10n("trending.refresh.tooltip")
    }

    /// 绝对时间格式化器（"6 月 2 日 22:48" 简洁形式）。
    private var absoluteTimeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale.current
        return f
    }

    // MARK: - Content

    private func reloadWikiAvailabilityMap(for repos: [TrendingRepo]) async {
        guard settings.wikiAvailabilityFilter != .unknown else {
            wikiAvailabilityMap = [:]
            return
        }
        let requests = repos.map {
            WikiAvailabilityRequest(id: $0.ghRepoId, owner: $0.owner, repo: $0.name)
        }
        let snapshot = await WikiAvailabilitySnapshotLoader.load(requests: requests)
        guard !Task.isCancelled else { return }
        wikiAvailabilityMap = snapshot
    }

    /// 单选列表使用手动 selection，而不是 `List(selection:)`。
    ///
    /// 原因（与 Manage `RepoListView.listContent(_:)` 对齐）：`List(selection:)` 会强制
    /// 绘制 macOS 系统蓝色选中底色，把 `RepoRowSurface` 自定义的语言色 accent bar /
    /// 轻 accent 底 / 细 accent 边框完全压住，导致两个列表视觉割裂。改用 plain Button
    /// 写 `selectedRepoID`，仍触发 HomeView 的 `.onChange(of: selectedRepoID)` 加载详情，
    /// 选中外观完全交给 `UnifiedRepoRow.isSelected` 驱动。
    ///
    /// **R-01 v1.2 Phase B2（2026-06-10）**：row 视图从 `TrendingRepoRowView` 切到
    /// `UnifiedRepoRow(card:isSelected:)`，与 Manage / Weekly / Activity-repo-backed
    /// 共用同一份卡片骨架。`StarredRegistry.contains(ghRepoId:)` 自动驱动 row 上的 ✓
    /// 标记：用户在详情页 star / unstar 后无需手动 reload，registry 是 `@Observable`，
    /// SwiftUI 会重新调用 `repo.asCardData(registry:)` 让 row 同步刷新。
    private var contentView: some View {
        let filteredRepos = viewModel.displayedRepos
        let visibleRepos = filteredRepos
            .prefix(viewModel.visibleLimit)
            .enumerated()
            .map { IndexedTrendingRepo(index: $0.offset, repo: $0.element) }

        return List {
            // "为你推荐"卡片暂时隐藏（dong4j 2026-06-01）：当前推荐质量还不稳定，先关掉。
            // 重新启用：把 showsRecommendations 改回 true 即可，逻辑与 UI 均保留。
            if Self.showsRecommendations, !viewModel.recommendedRepos.isEmpty {
                personalizedSection
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // Trending 列表：plain Button 包裹 UnifiedRepoRow，点击写 selectedRepoID。
            // 不用 `.tag(repo.id)`，selection 完全由 isSelected 入参驱动。
            //
            // 关键：**不**给 List 加 `.id(viewModel.reposRevision)`！
            // 给 List 绑定 id 会强制销毁重建整个 List 视图树，
            // 让 stars/forks 等数值字段变化也触发"全量重建"，导致用户感知"列表又重新加载了一次"。
            // 现在让 SwiftUI 走 ForEach + Identifiable 的天然 diff：
            // - 同 fullName 的 row 留在原地，stars 数等字段 in-place 更新（无动画）
            // - 新增/删除/换序的 row 才有动画（由 row reveal 处理）
            ForEach(visibleRepos) { item in
                let repo = item.repo
                // W12 PR-4：多选模式下点击行 toggle 选中，否则进入详情页。
                // 多选 store 由 AppDependencies 注入；isActive 由 toolbar 多选按钮控制。
                let store = dependencies.trendingMultiSelectionStore
                Button {
                    if store.isActive {
                        store.toggle(SelectionSnapshot(
                            ghRepoId: repo.ghRepoId,
                            owner: repo.owner,
                            name: repo.name
                        ))
                    } else {
                        selectedRepoID = repo.id
                    }
                } label: {
                    UnifiedRepoRow(
                        card: repo.asCardData(
                            registry: dependencies.starredRegistry,
                            isInLibrary: isInLibrary(repo.ghRepoId),
                            openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.ghRepoId)
                        ),
                        isSelected: store.isActive
                            ? store.contains(ghRepoId: repo.ghRepoId)
                            : (selectedRepoID == repo.id),
                        showStarredCheckmark: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(
                    index: item.index,
                    snapshotID: viewModel.reposRevision,
                    skipAnimation: viewModel.skipListRowReveal
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    viewModel.loadMoreIfNeeded(
                        currentIndex: item.index,
                        totalAvailable: filteredRepos.count
                    )
                }
                // HOM-201 P1-1（2026-06-14）：hover 500ms 后预拉 trending README，
                // softTtl 短路在 API 层做（命中 6h 内 trending 缓存不打 GitHub；
                // P1-4 让详情页 loadTrending 也用 softTtl,整条路径闭环）。
                .readmePrefetch { [readmeAPI = dependencies.readmeAPI, owner = repo.owner, name = repo.name] in
                    await readmeAPI.prefetchTrending(owner: owner, repo: name)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .refreshable {
            // Pull-to-refresh = 用户主动要新数据，绕过当前周期 TTL（R-06.1）
            await viewModel.reload(cachePolicy: .forceNetwork)
            reportRepoCount()
        }
        .task(id: "\(viewModel.reposRevision):\(viewModel.visibleLimit)") {
            // 先让首屏 row 提交一帧，再加载当前页 badge；不可见页随滚动分页补齐。
            await Task.yield()
            // 可用性筛选可能让展示列表暂时为空；信号补载必须基于未筛选候选，
            // 否则“仅可用”会因没有 row 而永远没有机会加载缓存，形成自锁。
            let candidateRepoIDs = viewModel.filterCandidateRepos.map(\.ghRepoId)
            let visibleRepoIDs = visibleRepos.map { $0.repo.ghRepoId }
            let openSSFRepoIDs = settings.openSSFAvailabilityFilter == .unknown
                ? visibleRepoIDs
                : candidateRepoIDs
            let healthRepoIDs = settings.healthAvailabilityFilter == .unknown
                ? visibleRepoIDs
                : candidateRepoIDs
            async let wiki: Void = reloadWikiAvailabilityMap(for: viewModel.filterCandidateRepos)
            async let openSSF: Void = dependencies.openSSFScoreStore.loadCachedScores(for: openSSFRepoIDs)
            async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(for: healthRepoIDs)
            _ = await (openSSF, health, wiki)
            guard !Task.isCancelled else { return }
            applyTrendingDetailSelectionPolicy()
        }
        // W12 PR-5：Cmd+A 全选当前可见 trending repo（仅 multi-select active 时生效）。
        // 4 场景同款机制：隐藏按钮 + keyboardShortcut。
        .background {
            let store = dependencies.trendingMultiSelectionStore
            Button {
                let snapshots = filteredRepos.map {
                    SelectionSnapshot(ghRepoId: $0.ghRepoId, owner: $0.owner, name: $0.name)
                }
                store.selectAll(snapshots)
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!store.isActive)
            .hidden()
        }
    }
    //
    // 历史：原本这里有 `.listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))`
    // 配合 `private var padding`，多塞了一层 12pt 左右内边距，造成 Trending 卡片整体比 Manage
    // 列表的卡片多缩一圈（dong4j 2026-06-02 反馈）。已移除——现在 Trending 和 Manage 共用
    // 系统 `.inset` listStyle 的默认行距 / 边距，两边视觉宽度对齐。

    private var personalizedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("trending.recommendTitle")
                    .font(.headline)
                Spacer()
            }

            if viewModel.userLanguagePreferences.isEmpty {
                Text("trending.basedOnTrending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("trending.basedOnPrefs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(viewModel.recommendedRepos) { repo in
                    Text(repo.fullName)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("trending.loadFailed")
                .font(.headline)

            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("trending.retry") {
                Task {
                    // 错误重试 = 用户主动要新数据，绕过当前周期 TTL（R-06.1）
                    await viewModel.reload(cachePolicy: .forceNetwork)
                }
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 带可见顺序的 Trending repo 包装。
///
/// `id` 仍使用 repo.id，确保 `List(selection:)` 与 `.tag(repo.id)` 继续匹配；
/// index 只参与渐进式入场 delay 计算，不改变业务身份。
private struct IndexedTrendingRepo: Identifiable {
    let index: Int
    let repo: TrendingRepo

    var id: String { repo.id }
}

// MARK: - TrendingRepoCard 已删除（R-01 v1.2 Phase B2，2026-06-10）
//
// 该结构体作为 Trending 列表 row 的早期实现长期未被引用（grep 全项目零调用方），
// row 视图链路实际是 TrendingRepoRowView → R-01 切换到 UnifiedRepoRow。
// 删除以保持单一真源，避免后续协作者误读为「现行实现」。
// 历史代码仍可在 git blame / commit `TrendingRepoCard 死代码删除` 之前的版本里找回。
