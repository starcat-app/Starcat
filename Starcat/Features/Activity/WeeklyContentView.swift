//
//  WeeklyContentView.swift
//  Starcat
//
//  Explore 页 `weekly` 分类的中栏视图 + ViewModel。
//
//  数据源：三源聚合周刊（ruanyf/weekly + ZRead + Hacker News）通过独立 Go 后端服务
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
//    切到 `.local`；命中且 12h TTL 内 → 不再发请求；命中但 TTL 过期 → 后台触发
//    bulkSync 静默刷新（不阻塞 UI）；③ 未命中 → fallback 老分页 `fetchRepos(page=1)`
//    立刻出图（200ms 级体感），同时后台启动 bulkSync 把 4000 条落盘；下次入场切 `.local`。
//  - **切 source / sort / lang / 高级筛选**：`.local` 模式纯本地 filter + sort +
//    客户端分页（瞬时无网络）；`.remote` 模式下高级筛选会先拉 bulk，再本地过滤，
//    避免对远端分页第一页做不完整过滤导致 total 不准。
//  - **主动刷新**：toolbar 刷新按钮 / pull-to-refresh 永远调 bulkSync（不论 dataSource），
//    完成后强制切到 `.local`，让 12h TTL 重新计时。
//  - **客户端 12h TTL**：判断在 ViewModel 层，Repository 不掺和；与 trending 24h TTL
//    分层一致。weekly 数据更新慢（周一 00:00 UTC 周更）但聚合源多（zread + discovery
//    天级），12h 是体感与新鲜度的平衡点。
//

import SwiftUI
import AppKit

// MARK: - View

/// Explore Weekly 分类的内容视图。
struct WeeklyContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings

    @Binding var selectedLanguage: String?

    @State private var viewModel: WeeklyContentViewModel?
    @State private var libraryStateMap: [Int64: LibraryState] = [:]

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
            await reloadLibraryStateMap()
            await model.loadInitialIfNeeded()
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

            if viewModel.isLoading && viewModel.items.isEmpty {
                RepoSkeletonListView(rowCount: 8)
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
        .task {
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
    }

    // MARK: - Filter Bar

    /// 顶部筛选栏：来源 / 收录强度 / 状态 / 热度 / 推送时间 / 排序。
    ///
    /// 期号筛选目前没有用 picker 暴露——后端 `/issues` 还在补，列表也不强需要；
    /// 后续要做时增加一个 Menu 即可，结构上已经在 ViewModel 留了 `selectedIssue`。
    private func filterBar(_ viewModel: WeeklyContentViewModel) -> some View {
        HStack(spacing: 10) {
            Menu {
                Section("weekly.filter.source") {
                    ForEach(WeeklySourceFilter.allCases) { source in
                        Button {
                            clearWeeklyDetailSelectionIfChanging(source != viewModel.selectedSource)
                            viewModel.changeSource(to: source)
                        } label: {
                            filterMenuRow(
                                title: source.localizedTitle,
                                isSelected: source == viewModel.selectedSource
                            )
                        }
                    }
                }

                Section("weekly.filter.coverage") {
                    ForEach(WeeklySourceCoverageFilter.allCases) { coverage in
                        Button {
                            clearWeeklyDetailSelectionIfChanging(coverage != viewModel.selectedCoverage)
                            viewModel.changeCoverage(to: coverage)
                        } label: {
                            filterMenuRow(
                                title: coverage.localizedTitle,
                                isSelected: coverage == viewModel.selectedCoverage
                            )
                        }
                    }
                }

                Section("weekly.filter.repoState") {
                    Button {
                        clearWeeklyDetailSelection()
                        viewModel.changeHideArchivedRepos(to: !viewModel.hideArchivedRepos)
                    } label: {
                        filterMenuRow(
                            title: String.l10n("weekly.filter.repoState.hideArchived"),
                            isSelected: viewModel.hideArchivedRepos
                        )
                    }
                    Button {
                        clearWeeklyDetailSelection()
                        viewModel.changeHideForkRepos(to: !viewModel.hideForkRepos)
                    } label: {
                        filterMenuRow(
                            title: String.l10n("weekly.filter.repoState.hideForks"),
                            isSelected: viewModel.hideForkRepos
                        )
                    }
                }

                Section("weekly.filter.stars") {
                    ForEach(WeeklyStarsFilter.allCases) { starsFilter in
                        Button {
                            clearWeeklyDetailSelectionIfChanging(starsFilter != viewModel.selectedStarsFilter)
                            viewModel.changeStarsFilter(to: starsFilter)
                        } label: {
                            filterMenuRow(
                                title: starsFilter.localizedTitle,
                                isSelected: starsFilter == viewModel.selectedStarsFilter
                            )
                        }
                    }
                }

                Section("weekly.filter.activity") {
                    ForEach(WeeklyPushedRecencyFilter.allCases) { pushedFilter in
                        Button {
                            clearWeeklyDetailSelectionIfChanging(pushedFilter != viewModel.selectedPushedRecency)
                            viewModel.changePushedRecency(to: pushedFilter)
                        } label: {
                            filterMenuRow(
                                title: pushedFilter.localizedTitle,
                                isSelected: pushedFilter == viewModel.selectedPushedRecency
                            )
                        }
                    }
                }

            } label: {
                HStack(spacing: 6) {
                    Text("weekly.filter.title")
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    Text(viewModel.filterSummaryTitle)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()

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

    @ViewBuilder
    private func filterMenuRow(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
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
            Task { await viewModel.reload() }
        }
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
                .listRowReveal(index: index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    // 到达接近底部时触发下一页：用倒数第 3 行作触发点，给网络一点提前量，
                    // 避免用户滚到最后一行才看到 ProgressView。
                    if viewModel.shouldTriggerLoadMore(at: index) {
                        Task { await viewModel.loadMoreIfNeeded() }
                    }
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
            let repoIDs = viewModel.items.map(\.ghRepoId)
            await dependencies.openSSFScoreStore.loadCachedScores(for: repoIDs)
            await dependencies.repoHealthStore.loadCachedSnapshots(for: repoIDs)
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
        if !matchesWikiFilter(owner: owner, name: name) { return false }
        if !matchesAvailability(dependencies.repoHealthStore.snapshot(for: repoId) != nil, filter: settings.healthAvailabilityFilter) {
            return false
        }
        if !matchesAvailability(dependencies.openSSFScoreStore.record(for: repoId)?.badgeData != nil, filter: settings.openSSFAvailabilityFilter) {
            return false
        }
        return true
    }

    private func matchesWikiFilter(owner: String, name: String) -> Bool {
        guard settings.wikiAvailabilityFilter != .unknown else { return true }
        guard let snapshot = DiskWikiCache.shared.load(owner: owner, repo: name) else {
            return false
        }
        return matchesAvailability(!snapshot.indexedLinks.isEmpty, filter: settings.wikiAvailabilityFilter)
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

    /// 客户端 bulk 缓存 TTL（与 trending 24h 配套，但 weekly 数据更新频率更高所以更短）。
    /// 与后端 60s TTL 配合形成两级缓存：客户端避免 12h 内重复打 server，server 避免
    /// 60s 内重复 rebuild。
    static let bulkTTL: TimeInterval = 12 * 60 * 60

    /// `.local` 模式下客户端分页 page size（与后端 default page=20 对齐，让"切到 local
    /// 后滚动"与"remote 模式滚动"视觉体验一致）。
    private static let localPageSize: Int = 20

    // MARK: - State

    /// UI 当前展示的 items（可能是 `.local` 全量本地分页切片，也可能是 `.remote` 累积分页结果）。
    private(set) var items: [WeeklyFeedItem] = []
    private(set) var total: Int = 0
    private(set) var page: Int = 1
    private(set) var hasMore: Bool = false

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadError: String?
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
        return set
    }

    // MARK: - Local cache state

    /// `.local` 模式下持有的当前 source + sort + lang 筛选结果**全量**（未分页切片前）。
    /// 切 source / sort / lang 时只需重排重过滤这个数组再切片，零网络。
    private var filteredLocalItems: [WeeklyFeedItem] = []
    /// bulk 缓存的"原始全量"——`filteredLocalItems` 是它的过滤+排序产物。
    private var bulkAllItems: [WeeklyFeedItem] = []
    /// 上次 bulk 拉取的客户端时间戳（用于判 12h TTL）。
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

        // Step 1: 尝试从本地缓存读
        if let cached = await bulkRepository.cachedBulk(), !cached.items.isEmpty {
            applyLocalSnapshot(cached, bumpRevision: false)
            // Step 2: TTL 判断
            if isCacheFresh(at: cached.lastFetchedAt) {
                return  // 12h 内，零网络上屏
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

        do {
            let result = try await bulkRepository.fetchBulk()
            guard myGen == generation else { return }
            let snapshot = WeeklyBulkCachedSnapshot(
                items: result.items,
                languages: result.languages,
                etag: result.etag,
                lastFetchedAt: Date(),
                generatedAt: result.generatedAt,
                total: result.total
            )
            applyLocalSnapshot(snapshot, bumpRevision: true)
        } catch {
            guard myGen == generation else { return }
            if usesLocalOnlyFilters {
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
                friendly.record(category: "network", operation: "weekly.reloadBulkForFilters", service: "weekly")
                if myGen == generation {
                    isLoading = false
                }
                return
            }
            // bulk 失败 → 退到分页 API 拿第一页（保证刷新按钮不空手而归）
            AppLog.network.warning("Weekly reload bulkSync failed, falling back to paginated API: \(error.localizedDescription, privacy: .public)")
            await loadRemotePage()
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
            advanceLocalPage()
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
            applyFiltersLocally(bumpRevision: true)
        } else {
            Task { await reload() }
        }
    }

    /// 给 List `.onAppear` 判断是否该触发下一页。
    /// 倒数第 3 行（或最后一行不足 3 时直接最后一行）触发，留一点网络余量。
    func shouldTriggerLoadMore(at index: Int) -> Bool {
        guard hasMore, !isLoading, !isLoadingMore else { return false }
        let threshold = max(items.count - 3, 0)
        return index >= threshold
    }

    // MARK: - Private: SWR

    /// 静默刷新：bulk 拉新 + 整批替换 + 切到 .local。失败时只记日志不打扰 UI。
    private func silentBulkSync() async {
        let myGen = generation
        do {
            let result = try await bulkRepository.fetchBulk()
            guard myGen == generation else { return }
            let snapshot = WeeklyBulkCachedSnapshot(
                items: result.items,
                languages: result.languages,
                etag: result.etag,
                lastFetchedAt: Date(),
                generatedAt: result.generatedAt,
                total: result.total
            )
            applyLocalSnapshot(snapshot, bumpRevision: true)
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
    private func applyLocalSnapshot(_ snapshot: WeeklyBulkCachedSnapshot, bumpRevision: Bool) {
        bulkAllItems = snapshot.items
        lastBulkFetchedAt = snapshot.lastFetchedAt
        dataSource = .local
        loadError = nil
        applyFiltersLocally(bumpRevision: bumpRevision)
    }

    /// 在 `bulkAllItems` 基础上按当前筛选条件重过滤重排序，切片到 page 1 上屏。
    private func applyFiltersLocally(bumpRevision: Bool) {
        var filtered = bulkAllItems.filter { selectedSource.matches($0) }
        filtered = filtered.filter { selectedCoverage.matches($0) }
        if hideArchivedRepos {
            filtered = filtered.filter { !$0.card.isArchived }
        }
        if hideForkRepos {
            filtered = filtered.filter { !$0.card.isFork }
        }
        filtered = filtered.filter { selectedStarsFilter.matches($0) }
        let now = Date()
        filtered = filtered.filter { selectedPushedRecency.matches($0, now: now) }
        if !selectedLanguage.isEmpty {
            filtered = filtered.filter { item in
                if selectedLanguage == TrendingLanguage.uncategorizedKey {
                    return (item.language ?? "").isEmpty
                }
                return item.language?.caseInsensitiveCompare(selectedLanguage) == .orderedSame
            }
        }
        filtered.sort(by: Self.makeLocalSorter(selectedSort))

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
        selectionService?.applyTotal(filtered.count)
    }

    private func advanceLocalPage() {
        let nextPage = page + 1
        let pageSize = Self.localPageSize
        let upper = min(nextPage * pageSize, filteredLocalItems.count)
        items = Array(filteredLocalItems.prefix(upper))
        page = nextPage
        hasMore = upper < filteredLocalItems.count
    }

    /// 12h TTL 判断；时间倒着算（lastFetchedAt 之后过了 < 12h 即新鲜）。
    private func isCacheFresh(at lastFetchedAt: Date) -> Bool {
        Date().timeIntervalSince(lastFetchedAt) < Self.bulkTTL
    }

    /// 排序函数：与后端 `WeeklyFeedSort` 对齐（详见后端 `internal/store/sqlite.go`
    /// `QueryRepos` 排序分支）。本地 sort 必须与 server-side 等价，否则用户切到 .local
    /// 后切 sort 的视觉结果会与 .remote 模式不一致。
    private static func makeLocalSorter(_ sort: WeeklyFeedSort) -> (WeeklyFeedItem, WeeklyFeedItem) -> Bool {
        switch sort {
        case .defaultOrder:
            return { lhs, rhs in
                if lhs.latestEventAt != rhs.latestEventAt {
                    return lhs.latestEventAt > rhs.latestEventAt
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .starsDesc:
            return { lhs, rhs in
                if lhs.stars != rhs.stars {
                    return lhs.stars > rhs.stars
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .starsAsc:
            return { lhs, rhs in
                if lhs.stars != rhs.stars {
                    return lhs.stars < rhs.stars
                }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .updatedDesc:
            return { lhs, rhs in
                let l = lhs.card.updatedAt ?? ""
                let r = rhs.card.updatedAt ?? ""
                if l != r { return l > r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .updatedAsc:
            return { lhs, rhs in
                let l = lhs.card.updatedAt ?? "\u{FFFD}"
                let r = rhs.card.updatedAt ?? "\u{FFFD}"
                if l != r { return l < r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .createdDesc:
            return { lhs, rhs in
                let l = lhs.card.createdAt ?? ""
                let r = rhs.card.createdAt ?? ""
                if l != r { return l > r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .createdAsc:
            return { lhs, rhs in
                let l = lhs.card.createdAt ?? "\u{FFFD}"
                let r = rhs.card.createdAt ?? "\u{FFFD}"
                if l != r { return l < r }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .nameAsc:
            return { lhs, rhs in
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedAscending }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        case .nameDesc:
            return { lhs, rhs in
                let compare = lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName)
                if compare != .orderedSame { return compare == .orderedDescending }
                return lhs.ghRepoId > rhs.ghRepoId
            }
        }
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
