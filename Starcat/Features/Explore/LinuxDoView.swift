//
//  LinuxDoView.swift
//  Starcat
//
//  发现下的 Linux.do 独立目录；选择仍交给现有 Discovery 详情，不创建第二套 README 页面。
//

import SwiftUI

struct LinuxDoView: View {
    @Namespace private var selectionSpace
    let store: LinuxDoStore
    let model: LinuxDoListModel
    @Binding var selectedRepoID: Int64?
    @Binding var selectedRepo: DiscoveryRepoDTO?
    let onRepoCountChange: (Int) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @State private var search = ""
    @State private var quickSearchDraft = ""
    @State private var isQuickSearchExpanded = false
    @State private var visibleRepoIDs: Set<Int64> = []
    @State private var tracksScroll = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            catalogContent
        }
        .task(id: store.providerID) { await store.refreshCatalog() }
        .preference(key: RepoLicenseOptionsPreferenceKey.self, value: store.catalog?.licenses ?? [])
        .task(id: pageRequest) {
            guard let request = pageRequest else { return }
            await updateList(request)
        }
        .onDisappear { resetQuickSearch() }
        .task(id: PageSignals(request: model.request, count: model.rows.count, libraryRevision: model.libraryRevision)) {
            await loadPageSignals()
        }
        .starcatRefreshCommand(pane: .list, identity: "linuxdo-\(pageRequest?.hashValue ?? 0)", title: String.l10n("commands.actions.refreshCurrentList"), isEnabled: !store.isRefreshingCatalog) {
            Task { await refresh() }
        }
    }

    private var catalogFreshnessDescription: String? {
        store.catalog.map { RelativeTimeText.pastEvent($0.metadata.checkedAt, locale: locale) }
    }

    /// 与普通发现共用控件和间距；Spacer 让搜索 / 排序靠左，更新状态 / 操作靠右。
    private var filterBar: some View {
        QuickSearchToolbarContent(
            isExpanded: $isQuickSearchExpanded,
            draft: $quickSearchDraft,
            committedQuery: search,
            placeholder: "list.quickSearch.placeholder",
            onSubmit: { query in
                let normalizedQuery = QuickSearchTextMatcher.normalized(query)
                search = normalizedQuery
                quickSearchDraft = normalizedQuery
            },
            onClear: { search = "" }
        ) {
            // 仅将原有两种排序适配到共享菜单，不改变 Linux.do 的本地排序规则。
            UnifiedSortMenu(
                selection: Binding<ExploreSortOption>(
                    get: { model.recentPromotionFirst ? .recommended : .stars },
                    set: { model.recentPromotionFirst = $0 == .recommended }
                ),
                options: [.recommended, .stars],
                displayName: { $0 == .recommended ? "linuxdo.catalog.recentPromotion" : $0.titleKey },
                iconSource: { $0 == .recommended ? .business(.recentUpdate) : $0.iconSource }
            )

            Spacer()
                .layoutPriority(AdaptiveToolbarStatusText.spacerPriority)

            if let text = catalogFreshnessDescription {
                AdaptiveToolbarStatusText(text: text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SyncIconButton(
                isRefreshing: store.isRefreshingCatalog,
                disabled: store.isRefreshingCatalog,
                tooltip: AdaptiveToolbarStatusText.refreshTooltip(action: String.l10n("explore.refresh.tooltip"), status: catalogFreshnessDescription)
            ) {
                Task { await refresh() }
            }
            MultiSelectButton(
                isActive: dependencies.exploreMultiSelectionStore.isActive,
                action: { dependencies.exploreMultiSelectionStore.toggle() },
                isDisabled: !authSession.state.isAuthenticated
            )
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    @ViewBuilder
    private var catalogContent: some View {
        MiddleListPresentation(showsSkeleton: showsSkeleton, rowCount: 10) {
            catalogResult
        }
    }

    private var showsSkeleton: Bool {
        if store.catalog == nil {
            return store.isRefreshingCatalog || !store.catalogFailed
        }
        return !hasCurrentPresentation && !listFailed
    }

    private var hasCurrentPresentation: Bool {
        guard let request = pageRequest else { return false }
        return model.request?.presentationID == request.presentationID
    }

    private var listFailed: Bool {
        guard let request = pageRequest else { return false }
        return model.failedRequest == request
    }

    @ViewBuilder
    private var catalogResult: some View {
        if store.catalog == nil && store.catalogFailed || !hasCurrentPresentation && listFailed {
            // 没有缓存时，加载失败就是当前页面的主状态；不要再叠加“空目录”，
            // 否则用户会误以为服务成功返回了 0 条数据。
            ContentUnavailableView {
                Label("error.loadFailed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("linuxdo.cache.unavailable")
            } actions: {
                Button("action.retry") {
                    Task { await refresh() }
                }
                .disabled(store.isRefreshingCatalog)
            }
        } else {
            // 有旧快照时保留可浏览内容，并把刷新失败降级为非阻断提示。
            if store.catalogFailed || listFailed {
                Text("linuxdo.cache.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("linuxdo.catalog.empty")
                    } icon: {
                        BusinessIcon(.linuxDo, pointSize: 16)
                    }
                } description: {
                    // 全自动目录复用已有刷新/筛选提示，不再把正常采集描述为等待审核。
                    Text("weekly.empty.subtitle")
                }
            } else {
                repoList
            }
        }
    }

    private var repoList: some View {
        let selection = dependencies.exploreMultiSelectionStore
        let rows = model.rows
        let request = model.request
        let snapshotID = request?.presentationID ?? 0
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(rows.enumerated()), id: \.element.repoID) { index, repo in
                    Button {
                        if selection.isActive { selection.toggle(SelectionSnapshot(ghRepoId: repo.repoID, owner: repo.owner, name: repo.name)) }
                        else { selectedRepoID = repo.repoID; selectedRepo = repo }
                    } label: {
                        UnifiedRepoRow(
                            card: repo.asCardData(
                                registry: dependencies.starredRegistry,
                                isInLibrary: model.libraryStates[repo.repoID] == .inLibrary,
                                openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.repoID),
                                healthBadge: dependencies.repoHealthStore.badge(for: repo.repoID)
                            ),
                            isSelected: selection.isActive ? selection.contains(ghRepoId: repo.repoID) : selectedRepoID == repo.repoID,
                            selectionNamespace: selection.isActive ? nil : selectionSpace,
                            linuxDoBadgeSource: LinuxDoListModel.badgeSource
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .listRowReveal(index: index, snapshotID: snapshotID, replayAfterSnapshotCommit: true)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .automaticListPagination(appearingIndex: index)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        recordVisibility(of: repo.repoID, visible: visible, presentationID: snapshotID)
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .scrollContentBackground(.hidden)
            .automaticListPagination(
                visibleItemCount: rows.count,
                loadedItemCount: rows.count,
                hasMore: model.hasMore && request == pageRequest && !listFailed,
                isLoading: model.isLoading || model.isAppending,
                identity: "linuxdo-\(request?.hashValue ?? 0)"
            ) {
                guard let request, request == pageRequest else { return }
                await model.loadMore(requested: request, store: store)
            }
            .task(id: snapshotID) {
                if let anchor = model.scrollAnchor, rows.contains(where: { $0.repoID == anchor }) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
                tracksScroll = true
            }
            .onDisappear {
                tracksScroll = false
                visibleRepoIDs.removeAll()
            }
            .refreshable { await refresh() }
        }
    }

    private func recordVisibility(of id: Int64, visible: Bool, presentationID: Int) {
        guard model.request?.presentationID == presentationID else { return }
        if visible { visibleRepoIDs.insert(id) } else { visibleRepoIDs.remove(id) }
        guard tracksScroll, let first = model.rows.first(where: { visibleRepoIDs.contains($0.repoID) }) else { return }
        model.scrollAnchor = first.repoID
    }

    private var pageRequest: LinuxDoListRequest? {
        guard let key = store.catalogKey else { return nil }
        let base = LinuxDoCatalogQuery(
            language: store.selectedLanguage,
            interestedLanguages: store.selectedLanguage == TrendingLanguage.otherRawValue ? settings.interestedLanguages : [],
            globalLanguages: settings.globalFilterLanguages.sorted(),
            license: settings.licenseFilter, hideArchived: settings.hideArchived, hideForks: settings.hideForks,
            search: search, recentPromotionFirst: model.recentPromotionFirst
        )
        let query = LinuxDoListQuery(base: base, star: settings.starFilter, library: settings.libraryFilter,
                                     wiki: settings.wikiAvailabilityFilter, health: settings.healthAvailabilityFilter,
                                     openSSF: settings.openSSFAvailabilityFilter, databaseScope: dependencies.databaseScopeRevision)
        // 未启用的信号不进入查询身份；当页胶囊变化不会重跑常规列表查询。
        let revisions = [
            query.star == .all ? 0 : dependencies.starredRegistry.ids.hashValue,
            query.library == .all ? 0 : model.libraryRevision,
            query.health == .unknown ? 0 : Set(dependencies.repoHealthStore.snapshots.keys).hashValue,
            query.openSSF == .unknown ? 0 : Set(dependencies.openSSFScoreStore.records.compactMap { $0.value.badgeData == nil ? nil : $0.key }).hashValue,
        ]
        return LinuxDoListRequest(key: key, query: query, filterRevision: revisions.hashValue)
    }

    /// 只有信号筛选需要目录范围的候选 ID。其余路径直接取页，不读 Wiki 文件或整库状态。
    private func prepareMemberships(for request: LinuxDoListRequest) async throws -> [LinuxDoRepoMembership] {
        let query = request.query
        var filters: [LinuxDoRepoMembership] = []
        if query.star != .all {
            filters.append(LinuxDoRepoMembership(ids: dependencies.starredRegistry.ids, includes: query.star == .starred))
        }
        guard query.needsSignalCandidates else { return filters }
        let candidates = try await store.signalCandidates(key: request.key, query: query.base)
        let ids = candidates.map(\.id)
        if query.library != .all {
            let states = try await dependencies.repoNoteRepository.fetchLibraryStateMap(repoIds: ids)
            filters.append(LinuxDoRepoMembership(ids: Set(states.compactMap { $0.value == .inLibrary ? $0.key : nil }),
                                                includes: query.library == .inLibrary))
        }
        if query.wiki != .unknown {
            let availability = await WikiAvailabilitySnapshotLoader.load(requests: candidates)
            filters.append(LinuxDoRepoMembership(ids: Set(availability.compactMap { $0.value ? $0.key : nil }), includes: query.wiki == .available))
        }
        if query.health != .unknown {
            let snapshots = try await dependencies.repoHealthRepository.snapshots(for: ids)
            filters.append(LinuxDoRepoMembership(ids: Set(snapshots.keys), includes: query.health == .available))
        }
        if query.openSSF != .unknown {
            let records = try await dependencies.openSSFScoreRepository.records(for: ids)
            filters.append(LinuxDoRepoMembership(ids: Set(records.compactMap { $0.value.badgeData == nil ? nil : $0.key }), includes: query.openSSF == .available))
        }
        return filters
    }

    private struct PageSignals: Hashable {
        let request: LinuxDoListRequest?
        let count: Int
        let libraryRevision: Int
    }

    private func loadPageSignals() async {
        let scope = dependencies.databaseScopeRevision
        guard model.request?.query.databaseScope == scope else { return }
        let libraryRevision = model.libraryRevision
        let ids = model.pendingSignalIDs()
        guard !ids.isEmpty else { return }
        async let library = dependencies.repoNoteRepository.fetchLibraryStateMap(repoIds: ids)
        async let scores: Void = dependencies.openSSFScoreStore.loadCachedScores(for: ids)
        async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(for: ids)
        _ = await (scores, health)
        if let states = try? await library, !Task.isCancelled,
           dependencies.databaseScopeRevision == scope, model.libraryRevision == libraryRevision {
            model.setLibraryStates(states, for: ids)
        }
    }

    private func updateList(_ request: LinuxDoListRequest) async {
        await model.update(request, store: store) { try await prepareMemberships(for: request) }
        guard !Task.isCancelled, model.request == request, pageRequest == request else { return }
        onRepoCountChange(model.total)
        if let id = selectedRepoID, let repo = model.rows.first(where: { $0.repoID == id }) { selectedRepo = repo; return }
        let preferred = model.rows.first(where: { $0.repoID == model.scrollAnchor }) ?? model.rows.first
        selectedRepo = settings.openFirstDetailOnCategoryChange ? preferred : nil
        selectedRepoID = selectedRepo?.repoID
    }

    private func refresh() async {
        await store.refreshCatalog(force: true)
        if let request = pageRequest { await updateList(request) }
    }

    /// 离开 Linux.do 分类时清除搜索，下一次进入应恢复完整目录而不是沿用旧条件。
    private func resetQuickSearch() {
        isQuickSearchExpanded = false
        quickSearchDraft = ""
        search = ""
    }
}
