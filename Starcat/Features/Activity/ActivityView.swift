//
//  ActivityView.swift
//  Starcat
//
//  Activity 页中栏。
//
//  设计约束：
//  - 不复用 `RepoRowView`，因为 Activity 卡片的事实源不是单一 Repo；
//    但复用 RemoteAvatar / LanguageBadge / StarsBadge / MetaBadge / RelativeDateBadge。
//  - ViewModel 由本视图按 Environment 里的 AppDependencies 构造，避免把 Activity 专属依赖
//    继续透传进 RepoListView 的初始化参数。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.9 修订（2026-06-10, dong4j「四场景统一 row」遗留 bug）：repo-backed kind 切 UnifiedRepoRow
//  ────────────────────────────────────────────────────────────────────────────
//
//  R-01「四个场景统一 row」原本只统一了 3 个（Manage / Trending / Weekly），Activity 全
//  走独立的 `ActivityRowView` —— Activity 的 `star` / `repository` / `suggestion` 这三
//  种**纯仓库型**卡片视觉与其它场景割裂。
//
//  v1.9 把这三种 kind 切到 `UnifiedRepoRow`，复用 `Repo.asCardData(badge: .activityKind(...))`：
//    - 头像角自带 kind icon 圆角标（UnifiedRepoRow.avatarWithKindBadge 已有逻辑）；
//    - chip 行 Lang / Stars / Forks 与 Manage / Trending / Weekly 完全对齐。
//
//  v2.0（2026-06-11 dong4j 决策）：卡片右上角 RelativeDateBadge **已整列删除**。
//  原 `.activityKind(category, createdAt)` 第二参 Date 在 kind 间语义漂移
//  （starredAt / pushedAt），`.all` 视图同框无法辨识，整列删除是承认时戳
//  维度不够强一致。Date 参数已从 enum case 删除（详见 RepoCardViewData.swift 注释）。
//
//  保留 `ActivityRowView` 渲染的两类（dong4j 决策）：
//    - `release`：title = release name(主位)+ subtitle = repo.fullName + body = release notes
//      摘录 + 未读 chip。视觉上「以 release 为主体」，与 UnifiedRepoRow「以仓库为主体」
//      语义冲突，强行切会丢 release name 视觉权重 + 未读 chip 渲染槽。
//    - `announcement`：item.repo == nil，根本无法构造 `RepoCardViewData`（必填 fullName /
//      owner / repo / ghRepoId）。视觉差异本就该有 —— 让用户一眼看出这是 GitHub 公告。
//    - `following`：当前 ActivityViewModel 未生产此 kind；预留入口，行为同 announcement。
//
//  `showStarredCheckmark` 不传 → 默认 false，与 Manage 同策略 ——`ActivityViewModel.filter {
//  $0.isStarred }` 已过滤 100% starred，挂 ✓ 视觉冗余。
//

import SwiftUI

struct ActivityView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    /// 2026-06-16:`RelativeDateTimeFormatter` 默认走系统 locale,需显式注入跟随
    /// LocaleStore 切换。这里读 SwiftUI `\.locale`,父级已挂 `appLocaleEnvironment()`。
    @Environment(\.locale) private var locale
    // R-01 §3.1.4 Step 7.3：refreshRow 改用 SyncIconButton 后顶层 reduceMotion 已不需要。
    // ActivityRowView 内部仍保留自己的 reduceMotion env 处理 isSelected 动画。

    @Binding var selectedCategory: ActivityCategory
    @Binding var selectedItem: ActivityItem?
    /// Getting Started 的 Undo Star 教学跳转后，一次性请求打开第一条记录。
    let undoStarAutoSelectRequestID: Int

    /// 当前分类数量回传给父视图的 navigation subtitle。
    private let onItemCountChange: (Int) -> Void

    /// Undo Star → 右侧详情页
    @State private var selectedUndoStarRecord: UndoStarRecord?
    var onSelectUndoStarRepo: ((Repo?) -> Void)?

    @State private var viewModel: ActivityViewModel?
    @State private var showClearFollowingConfirmation = false
    @State private var showClearAnnouncementConfirmation = false
    @State private var libraryStateMap: [Int64: LibraryState] = [:]

    init(
        selectedCategory: Binding<ActivityCategory>,
        selectedItem: Binding<ActivityItem?>,
        undoStarAutoSelectRequestID: Int = 0,
        onItemCountChange: @escaping (Int) -> Void = { _ in },
        onSelectUndoStarRepo: ((Repo?) -> Void)? = nil
    ) {
        _selectedCategory = selectedCategory
        _selectedItem = selectedItem
        self.undoStarAutoSelectRequestID = undoStarAutoSelectRequestID
        self.onItemCountChange = onItemCountChange
        self.onSelectUndoStarRepo = onSelectUndoStarRepo
    }

    var body: some View {
        Group {
            if selectedCategory == .undoStar {
                UndoStarContentView(
                    repository: dependencies.undoStarHistoryRepository,
                    settings: dependencies.settings,
                    selectedRecord: $selectedUndoStarRecord,
                    autoSelectFirstRecordRequestID: undoStarAutoSelectRequestID,
                    onSelectRepo: onSelectUndoStarRepo
                )
            } else if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // 首次进入 Activity：全量 ensureLoaded。Weekly 已迁移到 Explore,Activity 只处理本地聚合分类。
            let model = ensureViewModel()
            await reloadLibraryStateMap()
            await model.ensureLoaded(category: selectedCategory)
            applySelectionPolicy(from: model.items)
            reportItemCount(model)
        }
        .task {
            await observeLibraryStateChanges()
        }
        .onChange(of: selectedCategory) { _, newCategory in
            if viewModel == nil {
                let model = ensureViewModel()
                Task {
                    await model.ensureLoaded(category: newCategory)
                    applySelectionPolicy(from: model.items)
                    reportItemCount(model)
                }
                return
            }
            guard let viewModel else { return }
            if !viewModel.isAggregateReady {
                Task {
                    await viewModel.ensureLoaded(category: newCategory)
                    applySelectionPolicy(from: viewModel.items)
                    reportItemCount(viewModel)
                }
                return
            }
            viewModel.selectCategory(newCategory)
            reportItemCount(viewModel)
            scheduleSelectionPolicy(for: newCategory, viewModel: viewModel)
        }
        .onChange(of: settings.openFirstDetailOnCategoryChange) { _, enabled in
            guard enabled, let viewModel else { return }
            applySelectionPolicy(from: viewModel.items)
        }
    }

    @ViewBuilder
    private func content(_ viewModel: ActivityViewModel) -> some View {
        // Activity 本地分类：顶栏（排序 + 刷新）始终可见，空列表时也能刷新。
        categoryToolbarContent(viewModel)
    }

    /// 本地聚合分类：顶栏固定 + 下方内容区（列表 / 骨架 / 空态）。
    @ViewBuilder
    private func categoryToolbarContent(_ viewModel: ActivityViewModel) -> some View {
        VStack(spacing: 0) {
            activityFilterBar(viewModel)
            Divider()

            if shouldShowActivitySkeleton(viewModel) {
                RepoSkeletonListView(rowCount: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "activity.error.title", subtitleText: error)
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: selectedCategory.systemImage, title: "activity.empty.title", subtitle: emptySubtitle)
            } else {
                activityItemList(viewModel)
            }
        }
        .alert(
            "activity.following.clear.confirm",
            isPresented: $showClearFollowingConfirmation
        ) {
            Button("general.cancel", role: .cancel) {}
            Button("activity.following.clear.action", role: .destructive) {
                Task {
                    await viewModel.clearFollowingFeed()
                    applySelectionPolicy(from: viewModel.items)
                    reportItemCount(viewModel)
                }
            }
        } message: {
            Text("activity.following.clear.message")
        }
        .alert(
            "activity.announcement.clear.confirm",
            isPresented: $showClearAnnouncementConfirmation
        ) {
            Button("general.cancel", role: .cancel) {}
            Button("activity.announcement.clear.action", role: .destructive) {
                Task {
                    await viewModel.clearAnnouncementFeed()
                    applySelectionPolicy(from: viewModel.items)
                    reportItemCount(viewModel)
                }
            }
        } message: {
            Text("activity.announcement.clear.message")
        }
        .onAppear {
            reportItemCount(viewModel)
        }
        .onChange(of: viewModel.filteredItemTotalCount) { _, count in
            onItemCountChange(count)
        }
    }

    /// 活动列表主体（刷新已挪到顶栏 `activityFilterBar`）。
    @ViewBuilder
    private func activityItemList(_ viewModel: ActivityViewModel) -> some View {
        let visibleItems = globalFilteredItems(viewModel.items)
        List {
            ForEach(visibleItems) { item in
                Button {
                    selectedItem = item
                } label: {
                    rowContent(for: item)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(
                    index: Self.listRevealStaggerIndex(for: item.id),
                    snapshotID: viewModel.itemsRevision,
                    skipAnimation: viewModel.skipListRowReveal
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    if viewModel.shouldTriggerLoadMore(for: item) {
                        viewModel.loadMoreIfNeeded()
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .task(id: viewModel.itemsRevision) {
            let repoIds = viewModel.items.compactMap { $0.repo?.id }
            await dependencies.openSSFScoreStore.loadCachedScores(for: repoIds)
            await dependencies.repoHealthStore.loadCachedSnapshots(for: repoIds)
        }
    }

    private func globalFilteredItems(_ items: [ActivityItem]) -> [ActivityItem] {
        items.filter { item in
            guard let repo = item.repo else {
                return !hasActiveGlobalRepoFilter
            }
            return matchesGlobalFilters(repo: repo)
        }
    }

    private var hasActiveGlobalRepoFilter: Bool {
        settings.hideArchived
            || settings.hideForks
            || settings.starFilter != .all
            || settings.libraryFilter != .all
            || !settings.globalFilterLanguages.isEmpty
            || settings.wikiAvailabilityFilter != .unknown
            || settings.healthAvailabilityFilter != .unknown
            || settings.openSSFAvailabilityFilter != .unknown
    }

    private func matchesGlobalFilters(repo: Repo) -> Bool {
        guard settings.starFilter.matches(
            isStarred: dependencies.starredRegistry.contains(ghRepoId: repo.id)
        ) else { return false }
        if settings.hideArchived, repo.isArchived { return false }
        if settings.hideForks, repo.isFork { return false }
        if !settings.globalFilterLanguages.isEmpty {
            guard let language = repo.language else { return false }
            let selected = settings.globalFilterLanguages.contains {
                $0.caseInsensitiveCompare(language) == .orderedSame
            }
            guard selected else { return false }
        }
        switch settings.libraryFilter {
        case .all:
            break
        case .inLibrary:
            guard libraryStateMap[repo.id] == .inLibrary else { return false }
        case .outsideLibrary:
            guard libraryStateMap[repo.id] != .inLibrary else { return false }
        }
        if !matchesWikiFilter(owner: repo.owner, name: repo.name) { return false }
        if !matchesAvailability(dependencies.repoHealthStore.snapshot(for: repo.id) != nil, filter: settings.healthAvailabilityFilter) {
            return false
        }
        if !matchesAvailability(dependencies.openSSFScoreStore.record(for: repo.id)?.badgeData != nil, filter: settings.openSSFAvailabilityFilter) {
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

    /// 本地聚合分类顶部栏：时间排序 + 刷新时间 + 刷新按钮（公告 / 关注额外清空）。
    private func activityFilterBar(_ viewModel: ActivityViewModel) -> some View {
        HStack(spacing: 10) {
            UnifiedSortMenu(
                selection: activitySortBinding(viewModel),
                options: Array(ActivityTimeSort.allCases),
                displayName: { $0.titleKey },
                systemImage: { $0.systemImage }
            )

            Spacer()

            if let last = viewModel.lastRefreshedAt {
                Text(String(format: String.l10n("activity.lastRefreshedFormat"), relativeDate(last)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            activityRefreshButton(viewModel)

            if selectedCategory == .announcement || selectedCategory == .following {
                clearActivityButton(
                    help: selectedCategory == .announcement
                        ? "activity.announcement.clear.help"
                        : "activity.following.clear.help"
                ) {
                    if selectedCategory == .announcement {
                        showClearAnnouncementConfirmation = true
                    } else {
                        showClearFollowingConfirmation = true
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onAppear {
            restoreTimeSortPreferenceIfNeeded(viewModel)
        }
        .onChange(of: selectedCategory) { _, _ in
            restoreTimeSortPreferenceIfNeeded(viewModel)
        }
    }

    private func clearActivityButton(help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        DestructiveIconButton(help: Text(help), action: action)
    }

    private var activitySortPreferenceKey: String {
        "activity.\(selectedCategory.persistedRawValue).sort"
    }

    private func activitySortBinding(_ viewModel: ActivityViewModel) -> Binding<ActivityTimeSort> {
        Binding(
            get: { viewModel.timeSort(for: selectedCategory) },
            set: { sort in
                viewModel.changeTimeSort(to: sort)
                settings.setListPreferenceValue(
                    sort.rawValue,
                    for: activitySortPreferenceKey,
                    login: authSession.state.user?.login
                )
            }
        )
    }

    private func restoreTimeSortPreferenceIfNeeded(_ viewModel: ActivityViewModel) {
        guard selectedCategory.showsActivityFilterBar,
              let raw = settings.listPreferenceValue(
                for: activitySortPreferenceKey,
                login: authSession.state.user?.login
              ),
              let sort = ActivityTimeSort(rawValue: raw),
              viewModel.timeSort(for: selectedCategory) != sort
        else { return }
        viewModel.changeTimeSort(to: sort)
    }

    /// 按 `item.kind` 派发到 `UnifiedRepoRow`（repo-backed kind）或 `ActivityRowView`
    /// （announcement / following）。
    ///
    /// **派发规则**（设计 §3.1.5 + v1.9 dong4j 拍板 / v2.0 删时戳）：
    /// - `star` / `repository` / `suggestion` → `UnifiedRepoRow` 与 Manage/Trending/Weekly
    ///   100% 视觉同构（badge 走 `.activityKind(category)`，
    ///   头像角 kind icon 由 UnifiedRepoRow 承担；v2.0 已删右上 RelativeDateBadge）；
    /// - 其它 kind（release 主体 = release name 而非 repo / announcement 无 repo）走老路径。
    ///
    /// `item.repo` 为 nil 的 corner case（announcement、未来的 following）一律退化到老视觉，
    /// 因为 `RepoCardViewData` 必填 fullName / owner / repo / ghRepoId。
    @ViewBuilder
    private func rowContent(for item: ActivityItem) -> some View {
        let isSelected = selectedItem?.id == item.id

        if let repo = item.repo, isUnifiedRowKind(item.kind) {
            // v1.9：纯仓库型 kind 走 UnifiedRepoRow。`showStarredCheckmark` 不传（默认 false）
            // —— ActivityViewModel.filter { $0.isStarred } 已过滤 100% starred，挂 ✓ 视觉冗余。
            UnifiedRepoRow(
                card: repo.asCardData(
                    badge: .activityKind(item.category),
                    inlineMetadata: inlineMetadata(for: item),
                    isInLibrary: isInLibrary(repo.id),
                    openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.id)
                ),
                isSelected: isSelected
            )
            // HOM-201 P1-1（2026-06-14）：activity 行 hover 500ms 后预拉 manage 表的 README，
            // active 详情走 loadInternal 同 manage 复用 `readmes` 表；softTtl 短路在 API 层做。
            .readmePrefetch { [readmeAPI = dependencies.readmeAPI] in
                await readmeAPI.prefetch(for: repo)
            }
        } else {
            ActivityRowView(
                item: item,
                isSelected: isSelected
            )
        }
    }

    /// 判定一个 kind 是否能用 UnifiedRepoRow 渲染（v1.9）。
    ///
    /// 出参为 false 的两类：
    /// - `release`：v2.1 起也按 repo 聚合展示，一 repo 一卡片；release-specific 时间
    ///   放在 fullName 同行的 inline metadata，不再走老的 release row。
    /// - `announcement` / `following`：无 `item.repo`，无法构造 `RepoCardViewData`。
    private func isUnifiedRowKind(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .release, .star, .repository, .suggestion:
            return true
        case .announcement, .following:
            return false
        }
    }

    private func inlineMetadata(for item: ActivityItem) -> RepoCardInlineMetadata? {
        guard item.kind == .release, let date = item.createdAt else { return nil }
        return RepoCardInlineMetadata(systemImage: "calendar", text: Self.absoluteDate(date))
    }

    private func activityRefreshButton(_ viewModel: ActivityViewModel) -> some View {
        SyncIconButton(
            isRefreshing: viewModel.isRefreshing,
            disabled: viewModel.isRefreshing,
            tooltip: String.l10n("activity.refresh")
        ) {
            Task {
                await viewModel.refresh(category: selectedCategory)
                applySelectionPolicy(from: viewModel.items)
                reportItemCount(viewModel)
            }
        }
    }

    private var emptySubtitle: LocalizedStringKey {
        switch selectedCategory {
        case .following:
            return "activity.empty.following"
        case .release:
            return "activity.empty.release"
        default:
            return "activity.empty.subtitle"
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

    private func ensureViewModel() -> ActivityViewModel {
        if let viewModel {
            return viewModel
        }
        // PR-2（2026-06-16）：装配 4 路 SWR 所需的额外依赖。
        // `currentLoginProvider` 闭包从 AuthSession 取当前 user.login —— 与
        // `StarActionService.userIDProvider` 同款注入 pattern，让 ViewModel 不
        // 直接持 AuthSession，便于测试用 stub `{ "octocat" }` 替换。
        let session = authSession
        let poller = dependencies.releasePoller
        let model = ActivityViewModel(
            repoRepository: dependencies.repoRepository,
            releaseRepository: dependencies.releaseRepository,
            releasePollerRunner: { _ = await poller.runNow() },
            activityEventRepository: dependencies.activityEventRepository,
            activityAnnouncementRepository: dependencies.activityAnnouncementRepository,
            activitySyncStateRepository: dependencies.activitySyncStateRepository,
            apiClient: dependencies.apiClient,
            blogRSSClient: dependencies.blogRSSClient,
            currentLoginProvider: { [weak session] in session?.state.user?.login },
            categoryCountService: dependencies.activityCategoryCountService
        )
        viewModel = model
        return model
    }

    private func clearSelectionIfMissing(from items: [ActivityItem]) {
        // 分类切换、刷新、清空 feed 只维护“旧详情是否仍属于当前列表”这个约束。
        // 不再默认选中第一条，避免列表加载后又触发详情页的额外加载。
        guard let selectedItem, !items.contains(where: { $0.id == selectedItem.id }) else {
            return
        }
        self.selectedItem = nil
    }

    private func applySelectionPolicy(from items: [ActivityItem]) {
        // 默认只清掉不属于当前分类的旧详情；用户开启偏好后，才在列表稳定后选第一条。
        guard settings.openFirstDetailOnCategoryChange else {
            clearSelectionIfMissing(from: items)
            return
        }
        if let selectedItem, items.contains(where: { $0.id == selectedItem.id }) {
            return
        }
        selectedItem = items.first
    }

    private func scheduleSelectionPolicy(for category: ActivityCategory, viewModel: ActivityViewModel) {
        // HomeView 也监听 selectedActivityCategory，并会先清空右侧旧详情。
        // ActivityViewModel 的切分类快路径为了性能不 bump itemsRevision，所以这里延后一拍：
        // 让父层清空动作先完成，再按用户偏好自动打开当前分类第一条。
        Task { @MainActor in
            await Task.yield()
            guard selectedCategory == category else { return }
            applySelectionPolicy(from: viewModel.items)
        }
    }

    private func reportItemCount(_ viewModel: ActivityViewModel) {
        onItemCountChange(viewModel.filteredItemTotalCount)
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeTimeText.pastEvent(date, locale: locale)
    }

    /// 加载中 / 后台 filter 中 / 聚合未就绪 → 骨架屏，避免误显示「暂无活动」空态。
    private func shouldShowActivitySkeleton(_ viewModel: ActivityViewModel) -> Bool {
        // 已有 prime 首屏时，后台 filter 继续跑但不回退到骨架屏，避免 Activity 全部类型
        // 首次进入出现“列表出现 → 骨架 → 列表”的二次刷新感。
        if viewModel.isApplyingCategoryFilter && !viewModel.hasVisibleItems { return true }
        if viewModel.items.isEmpty && (viewModel.isLoading || !viewModel.isAggregateReady) {
            return true
        }
        return false
    }

    static func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// `listRowReveal` stagger 用：由 item id 派生，避免 `Array(enumerated())` 每帧分配。
    private static func listRevealStaggerIndex(for itemID: String) -> Int {
        abs(itemID.hashValue % 14)
    }
}

// MARK: - Row

private struct ActivityRowView: View {
    let item: ActivityItem
    let isSelected: Bool

    var body: some View {
        // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 已删，直接渲染 card。
        ActivityRowSurface(item: item, isSelected: isSelected) {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon(size: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.kind == .release, item.isRead == false {
                        MetaBadge(systemImage: "circle.fill", text: String.l10n("activity.unread"), tint: .accentColor)
                    }
                }

                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let body = item.body, !body.isEmpty, item.kind != .following {
                    Text(verbatim: body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let repo = item.repo {
                        if let language = repo.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }
                        StarsBadge(count: repo.starsCount, style: .full)
                    }
                    MetaBadge(systemImage: item.category.systemImage, text: item.category.localizedTitle, tint: .secondary)
                    if let date = item.createdAt {
                        RelativeDateBadge(date: date)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func leadingIcon(size: CGFloat) -> some View {
        // following kind：优先用 actor avatar（语义 = 「关注的人在干啥」），
        // 比 repo owner avatar 更切题。PR-2 引入，2026-06-16。
        if item.kind == .following, let avatarURL = item.following?.actorAvatarURL {
            RemoteAvatar(urlString: avatarURL.absoluteString, size: size, showBorder: size > 24)
        } else if item.kind == .announcement, let announcement = item.announcement {
            announcementIcon(source: announcement.source, size: size)
        } else if let repo = item.repo {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: size, showBorder: size > 24)
        } else {
            ZStack {
                Circle()
                    .fill(item.accentColor.opacity(0.18))
                Image(systemName: item.category.systemImage)
                    .font(.system(size: size > 24 ? 17 : 11, weight: .semibold))
                    .foregroundStyle(item.accentColor)
            }
            .frame(width: size, height: size)
        }
    }

    /// announcement 行图标：blog = newspaper；security = shield（橙 tint）。
    @ViewBuilder
    private func announcementIcon(source: AnnouncementSource, size: CGFloat) -> some View {
        let tint: Color = source == .security ? Color.orange : item.accentColor
        let symbol = source == .security ? "shield.lefthalf.filled" : "newspaper"
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: size > 24 ? 17 : 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

private struct ActivityRowSurface<Content: View>: View {
    let item: ActivityItem
    let isSelected: Bool
    private let content: Content

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(item: ActivityItem, isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.item = item
        self.isSelected = isSelected
        self.content = content()
    }

    private var accentColor: Color {
        item.accentColor
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.18 }
        if isHovered { return 0.08 }
        // R-01 §3.1.1：RepoListDensity 已删，统一使用 card 密度的非 hover/selected 透明度。
        return 0.045
    }

    var body: some View {
        // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 已删，全部走 card 密度
        // 的视觉常量（vertical 8 / horizontal 10 / cornerRadius 10）。
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .padding(.leading, isSelected ? 5 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(backgroundOpacity))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accentColor)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(accentColor.opacity(isSelected ? 0.42 : (isHovered ? 0.18 : 0.10)), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                    isHovered = hovering
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }
}
