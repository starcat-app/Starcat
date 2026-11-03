//
//  LinuxDoView.swift
//  Starcat
//
//  发现下的 Linux.do 独立目录；选择仍交给现有 Discovery 详情，不创建第二套 README 页面。
//

import SwiftUI

struct LinuxDoView: View {
    let store: LinuxDoStore
    @Binding var selectedRepoID: Int64?
    @Binding var selectedRepo: DiscoveryRepoDTO?
    let onRepoCountChange: (Int) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @State private var model = LinuxDoListModel()
    @State private var search = ""
    @State private var quickSearchDraft = ""
    @State private var isQuickSearchExpanded = false
    @State private var recentPromotionFirst = true
    @State private var libraryStates: [Int64: LibraryState] = [:]
    @State private var wikiAvailability: [Int64: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            catalogContent
        }
        .task {
            selectedRepoID = nil
            selectedRepo = nil
            libraryStates = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
            await store.refreshCatalog()
        }
        .preference(key: RepoLicenseOptionsPreferenceKey.self,
                    value: RepoLicenseFilter.options(store.repositories.map(\.licenseSpdx)))
        .task(id: queryIdentity) { rebuildList() }
        .onDisappear { resetQuickSearch() }
        .task(id: signalIdentity) {
            let repos = store.repositories
            let ids = repos.map(\.repoID)
            async let scores: Void = dependencies.openSSFScoreStore.loadCachedScores(for: ids)
            async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(for: ids)
            if settings.wikiAvailabilityFilter != .unknown {
                let snapshot = await WikiAvailabilitySnapshotLoader.load(requests: repos.map { WikiAvailabilityRequest(id: $0.repoID, owner: $0.owner, repo: $0.name) })
                guard !Task.isCancelled else { return }
                wikiAvailability = snapshot
            }
            _ = await (scores, health)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .repoLibraryStateDidChange) {
                guard !Task.isCancelled else { return }
                libraryStates = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
                rebuildList()
            }
        }
        .starcatRefreshCommand(pane: .list, identity: "linuxdo-\(queryIdentity)", title: String.l10n("commands.actions.refreshCurrentList"), isEnabled: !store.isRefreshingCatalog) {
            Task { await store.refreshCatalog(force: true) }
        }
    }

    private var catalogFreshnessDescription: String? {
        store.catalog.map { RelativeTimeText.pastEvent($0.checkedAt, locale: locale) }
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
                    get: { recentPromotionFirst ? .recommended : .stars },
                    set: { recentPromotionFirst = $0 == .recommended }
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
                Task { await store.refreshCatalog(force: true) }
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
        if store.catalog == nil && store.isRefreshingCatalog {
            RepoSkeletonListView(rowCount: 10)
        } else if store.catalog == nil && store.failed.contains(.catalog) {
            // 没有缓存时，加载失败就是当前页面的主状态；不要再叠加“空目录”，
            // 否则用户会误以为服务成功返回了 0 条数据。
            ContentUnavailableView {
                Label("error.loadFailed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("linuxdo.cache.unavailable")
            } actions: {
                Button("action.retry") {
                    Task { await store.refreshCatalog(force: true) }
                }
                .disabled(store.isRefreshingCatalog)
            }
        } else {
            // 有旧快照时保留可浏览内容，并把刷新失败降级为非阻断提示。
            if store.failed.contains(.catalog) {
                Text("linuxdo.cache.unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("linuxdo.catalog.empty", systemImage: "text.bubble")
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
        return List {
            ForEach(Array(model.rows.enumerated()), id: \.element.repoID) { index, repo in
                Button {
                    if selection.isActive { selection.toggle(SelectionSnapshot(ghRepoId: repo.repoID, owner: repo.owner, name: repo.name)) }
                    else { selectedRepoID = repo.repoID; selectedRepo = repo }
                } label: {
                    UnifiedRepoRow(card: repo.asCardData(registry: dependencies.starredRegistry, isInLibrary: libraryStates[repo.repoID] == .inLibrary), isSelected: selection.isActive ? selection.contains(ghRepoId: repo.repoID) : selectedRepoID == repo.repoID)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .automaticListPagination(appearingIndex: index, visibleItemCount: model.rows.count, loadedItemCount: model.rows.count, hasMore: model.hasMore, isLoading: false, identity: model.identity) { model.loadMore() }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .automaticListPaginationFill(visibleItemCount: model.rows.count, loadedItemCount: model.rows.count, hasMore: model.hasMore, isLoading: false, identity: model.identity) { model.loadMore() }
        .refreshable { await store.refreshCatalog(force: true) }
    }

    /// 全局基础筛选在本地完整快照上执行；分页边界使用筛选后集合，不会因隐藏尾行而断页。
    private var filteredRepositories: [DiscoveryRepoDTO] {
        store.repositories.filter { repo in
            guard settings.licenseFilter.matches(repo.licenseSpdx) else { return false }
            guard LinuxDoStore.matchesLanguage(repo.language, selection: store.selectedLanguage, interestedLanguages: settings.interestedLanguages) else { return false }
            guard settings.starFilter.matches(isStarred: dependencies.starredRegistry.contains(ghRepoId: repo.repoID)) else { return false }
            if settings.hideArchived && repo.isArchived || settings.hideForks && repo.isFork { return false }
            if !settings.globalFilterLanguages.isEmpty && !settings.globalFilterLanguages.contains(where: { $0.caseInsensitiveCompare(repo.language ?? "") == .orderedSame }) { return false }
            if !matchesAvailability(wikiAvailability[repo.repoID] ?? false, filter: settings.wikiAvailabilityFilter) { return false }
            if !matchesAvailability(dependencies.repoHealthStore.snapshot(for: repo.repoID) != nil, filter: settings.healthAvailabilityFilter) { return false }
            if !matchesAvailability(dependencies.openSSFScoreStore.record(for: repo.repoID)?.badgeData != nil, filter: settings.openSSFAvailabilityFilter) { return false }
            switch settings.libraryFilter {
            case .all: return true
            case .inLibrary: return libraryStates[repo.repoID] == .inLibrary
            case .outsideLibrary: return libraryStates[repo.repoID] != .inLibrary
            }
        }
    }

    private var queryIdentity: String {
        // 显式包含语言身份，两个空分类（或结果相同的分类）之间切换也必须重置分页。
        "\(store.providerID):\(store.catalog?.payload.revision ?? -1):\(store.selectedLanguage ?? ""):\(settings.licenseFilter.cacheKey):\(search):\(recentPromotionFirst):\(filteredRepositories.map(\.repoID))"
    }

    private var signalIdentity: String {
        "\(store.providerID):\(store.catalog?.payload.revision ?? -1):\(settings.wikiAvailabilityFilter.rawValue)"
    }

    private func matchesAvailability(_ available: Bool, filter: RepoSignalAvailabilityFilter) -> Bool {
        switch filter {
        case .unknown: return true
        case .available: return available
        case .missing: return !available
        }
    }

    private func rebuildList() {
        model.reset(repositories: filteredRepositories, promotionDates: store.catalog?.payload.promotionDates ?? [:], search: search, recentPromotionFirst: recentPromotionFirst, identity: queryIdentity)
        onRepoCountChange(model.total)
        if let id = selectedRepoID, let repo = model.rows.first(where: { $0.repoID == id }) { selectedRepo = repo; return }
        selectedRepo = settings.openFirstDetailOnCategoryChange ? model.rows.first : nil
        selectedRepoID = selectedRepo?.repoID
    }

    /// 离开 Linux.do 分类时清除搜索，下一次进入应恢复完整目录而不是沿用旧条件。
    private func resetQuickSearch() {
        isQuickSearchExpanded = false
        quickSearchDraft = ""
        search = ""
    }
}
