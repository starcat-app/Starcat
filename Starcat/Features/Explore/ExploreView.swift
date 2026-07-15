//
//  ExploreView.swift
//  Starcat
//
//  探索页中栏容器。
//
//  设计意图：
//  - 「发现 / 趋势 / 热门 / 新发布 / 周刊」是左侧探索入口下的子分类，中栏只渲染当前模式内容；
//  - 趋势继续复用现有 TrendingView，保证 GitHub Trending 缓存、README 和批量操作不回归；
//  - 发现 / 热门 / 新发布共用 Discovery 列表，筛选栏和分页逻辑保持一致。
//

import SwiftUI

struct ExploreView: View {

    var trendingRepository: (any TrendingRepositoryProtocol)?
    var githubAPIClient: (any GitHubAPIClientProtocol)?

    @Binding var selectedMode: ExploreMode
    @Binding var selectedTrendingLanguage: TrendingLanguage
    @Binding var selectedTrendingRepoID: String?
    @Binding var selectedTrendingRepo: TrendingRepo?
    @Binding var selectedDiscoveryLanguage: String?
    @Binding var selectedDiscoveryTopic: String?
    @Binding var selectedDiscoveryPlatform: String?
    @Binding var selectedDiscoveryRepoID: Int64?
    @Binding var selectedDiscoveryRepo: DiscoveryRepoDTO?
    @Binding var selectedWeeklyLanguage: String?

    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @State private var discoveryViewModel = ExploreDiscoveryViewModel()

    var body: some View {
        Group {
            switch selectedMode {
            case .trending:
                trendingContent
            case .weekly:
                WeeklyContentView(selectedLanguage: $selectedWeeklyLanguage)
            case .discover, .popular, .newReleases:
                ExploreDiscoveryListView(
                    viewModel: discoveryViewModel,
                    mode: selectedMode,
                    selectedLanguage: $selectedDiscoveryLanguage,
                    selectedTopic: $selectedDiscoveryTopic,
                    selectedPlatform: $selectedDiscoveryPlatform,
                    selectedRepoID: $selectedDiscoveryRepoID,
                    selectedRepo: $selectedDiscoveryRepo,
                    onRepoCountChange: onRepoCountChange
                )
            }
        }
        .onChange(of: selectedMode) { _, mode in
            switch mode {
            case .trending:
                clearDiscoverySelection()
            case .weekly:
                clearTrendingSelection()
                clearDiscoverySelection()
            case .discover, .popular, .newReleases:
                clearTrendingSelection()
            }
        }
    }

    @ViewBuilder
    private var trendingContent: some View {
        if let trendingRepository, let githubAPIClient {
            TrendingView(
                repository: trendingRepository,
                githubAPIClient: githubAPIClient,
                selectedLanguage: $selectedTrendingLanguage,
                selectedRepoID: $selectedTrendingRepoID,
                selectedTrendingRepo: $selectedTrendingRepo,
                onRepoCountChange: onRepoCountChange
            )
        } else {
            ExploreEmptyState(
                systemImage: "chart.line.uptrend.xyaxis",
                titleKey: "empty.trendingUnavailable",
                subtitleKey: "empty.trendingComingSoon"
            )
        }
    }

    private func clearTrendingSelection() {
        selectedTrendingRepoID = nil
        selectedTrendingRepo = nil
    }

    private func clearDiscoverySelection() {
        selectedDiscoveryRepoID = nil
        selectedDiscoveryRepo = nil
    }
}

private struct ExploreDiscoveryListView: View {

    let viewModel: ExploreDiscoveryViewModel
    let mode: ExploreMode
    @Binding var selectedLanguage: String?
    @Binding var selectedTopic: String?
    @Binding var selectedPlatform: String?
    @Binding var selectedRepoID: Int64?
    @Binding var selectedRepo: DiscoveryRepoDTO?
    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var libraryStateMap: [Int64: LibraryState] = [:]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
                .id(contentStateID)
                .transition(contentTransition)
                .animation(contentAnimation, value: contentStateID)
        }
        .task(id: queryIdentity) {
            restoreSortPreferenceIfNeeded()
            selectedRepoID = nil
            selectedRepo = nil
            await reloadLibraryStateMap()
            viewModel.sortOption = currentSort
            await viewModel.reload(
                repository: dependencies.discoveryRepository,
                mode: mode,
                language: mode == .discover ? nil : selectedLanguage,
                topic: mode == .discover ? selectedTopic : nil,
                platform: mode == .discover ? selectedPlatform : nil,
                sort: currentSort
            )
            applySelectionPolicy()
            reportRepoCount()
        }
        .task {
            await observeLibraryStateChanges()
        }
        .onChange(of: viewModel.reposRevision) { _, _ in
            applySelectionPolicy()
            reportRepoCount()
        }
        .onChange(of: settings.openFirstDetailOnCategoryChange) { _, enabled in
            guard enabled else { return }
            applySelectionPolicy()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            UnifiedSortMenu(
                selection: sortBinding,
                options: ExploreSortOption.options(for: mode),
                displayName: { $0.titleKey },
                systemImage: { $0.systemImage },
                dividerBefore: { option in
                    option == ExploreSortOption.options(for: mode).first(where: \.isModeSpecificSort)
                }
            )

            Spacer()

            if let text = formattedFreshness {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SyncIconButton(
                isRefreshing: viewModel.isRefreshing,
                disabled: viewModel.isRefreshing || viewModel.isLoading,
                tooltip: String.l10n("explore.refresh.tooltip")
            ) {
                Task {
                    await viewModel.reload(
                        repository: dependencies.discoveryRepository,
                        mode: mode,
                        language: mode == .discover ? nil : selectedLanguage,
                        topic: mode == .discover ? selectedTopic : nil,
                        platform: mode == .discover ? selectedPlatform : nil,
                        sort: currentSort,
                        showsRefreshIndicator: true
                    )
                    applySelectionPolicy()
                    reportRepoCount()
                }
            }
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    private var sortBinding: Binding<ExploreSortOption> {
        Binding(
            get: { currentSort },
            set: {
                let normalized = $0.normalized(for: mode)
                viewModel.sortOption = normalized
                persistSortPreference(normalized)
            }
        )
    }

    private var currentSort: ExploreSortOption {
        viewModel.sortOption.normalized(for: mode)
    }

    private var sortPreferenceKey: String {
        "explore.\(mode.rawValue).sort"
    }

    private var currentLogin: String? {
        authSession.state.user?.login
    }

    private func restoreSortPreferenceIfNeeded() {
        guard let raw = settings.listPreferenceValue(for: sortPreferenceKey, login: currentLogin),
              let saved = ExploreSortOption(rawValue: raw)
        else { return }
        let normalized = saved.normalized(for: mode)
        if viewModel.sortOption != normalized {
            viewModel.sortOption = normalized
        }
    }

    private func persistSortPreference(_ sort: ExploreSortOption) {
        settings.setListPreferenceValue(sort.rawValue, for: sortPreferenceKey, login: currentLogin)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.repos.isEmpty {
            RepoSkeletonListView(rowCount: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.loadError, viewModel.repos.isEmpty {
            ExploreEmptyState(
                systemImage: "exclamationmark.triangle",
                titleKey: "error.loadFailed",
                subtitleText: error
            )
        } else if viewModel.repos.isEmpty {
            ExploreEmptyState(
                systemImage: mode.systemImage,
                titleKey: "explore.empty.title",
                subtitleKey: "explore.empty.subtitle"
            )
        } else {
            VStack(spacing: 0) {
                cacheWarningBanner
                repoList
            }
        }
    }

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

    /// 探索模块全局多选 store（5 个子模式共享）。
    private var exploreStore: MultiSelectionStore {
        dependencies.exploreMultiSelectionStore
    }

    private var repoList: some View {
        let store = exploreStore
        return List {
            ForEach(indexedRepos) { item in
                let repo = item.repo
                Button {
                    if store.isActive {
                        store.toggle(SelectionSnapshot(
                            ghRepoId: repo.repoID,
                            owner: repo.owner,
                            name: repo.name
                        ))
                    } else {
                        selectedRepoID = repo.repoID
                        selectedRepo = repo
                    }
                } label: {
                    UnifiedRepoRow(
                        card: repo.asCardData(
                            registry: dependencies.starredRegistry,
                            isInLibrary: isInLibrary(repo.repoID),
                            footerMetadata: footerMetadata(for: repo),
                            openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.repoID)
                        ),
                        isSelected: store.isActive
                            ? store.contains(ghRepoId: repo.repoID)
                            : (selectedRepoID == repo.repoID),
                        showStarredCheckmark: true
                    )
                    .id(repoRowIdentity(for: repo))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: item.index, snapshotID: viewModel.reposRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    Task {
                        await viewModel.loadMoreIfNeeded(
                            repository: dependencies.discoveryRepository,
                            currentRepo: repo,
                            mode: mode,
                            language: mode == .discover ? nil : selectedLanguage,
                            topic: mode == .discover ? selectedTopic : nil,
                            platform: mode == .discover ? selectedPlatform : nil,
                            sort: currentSort
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.reload(
                repository: dependencies.discoveryRepository,
                mode: mode,
                language: mode == .discover ? nil : selectedLanguage,
                topic: mode == .discover ? selectedTopic : nil,
                platform: mode == .discover ? selectedPlatform : nil,
                sort: currentSort,
                showsRefreshIndicator: true
            )
            applySelectionPolicy()
            reportRepoCount()
        }
        .background {
            let store = exploreStore
            Button {
                let visibleRepos = globalFilteredRepos(viewModel.repos)
                let snapshots = visibleRepos.map {
                    SelectionSnapshot(ghRepoId: $0.repoID, owner: $0.owner, name: $0.name)
                }
                store.selectAll(snapshots)
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!store.isActive)
            .hidden()
        }
        .task(id: viewModel.reposRevision) {
            let repoIDs = viewModel.repos.map(\.repoID)
            await dependencies.openSSFScoreStore.loadCachedScores(for: repoIDs)
            await dependencies.repoHealthStore.loadCachedSnapshots(for: repoIDs)
        }
    }

    /// 新发布列表才展示 release 时间；发现 / 热门不展示，避免把仓库名右侧挤满。
    ///
    /// 后端给的是 ISO-8601 `latest_release_at`，列表里只保留短日期（如 `Jul 4` / `7月4日`）。
    /// 解析失败时直接隐藏，不能把原始时间戳重新暴露到卡片上。
    private func releaseFooterMetadata(for repo: DiscoveryRepoDTO) -> RepoCardInlineMetadata? {
        guard let date = ISO8601DateFormatter.githubDate(from: repo.latestReleaseAt)
        else { return nil }
        let text = date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .locale(LocaleStore.shared.selection.effectiveLocale)
        )
        return RepoCardInlineMetadata(systemImage: "shippingbox", text: text)
    }

    private func footerMetadata(for repo: DiscoveryRepoDTO) -> RepoCardInlineMetadata? {
        switch mode {
        case .popular:
            guard repo.releaseDownloadCount > 0 else { return nil }
            return RepoCardInlineMetadata(
                systemImage: "arrow.down.circle",
                text: repo.releaseDownloadCount.formattedShort,
                tint: .green
            )
        case .discover:
            return discoverySignalMetadata(for: repo)
        case .newReleases:
            return releaseFooterMetadata(for: repo)
        case .trending, .weekly:
            return nil
        }
    }

    private func discoverySignalMetadata(for repo: DiscoveryRepoDTO) -> RepoCardInlineMetadata? {
        let reasonCodes = repo.reasons.map { $0.lowercased() }
        if reasonCodes.contains("recent_release") {
            return RepoCardInlineMetadata(systemImage: "shippingbox", text: .l10n("explore.discoverySignal.recentRelease"))
        }
        if reasonCodes.contains("release_downloads") {
            return RepoCardInlineMetadata(systemImage: "arrow.down.circle", text: .l10n("explore.discoverySignal.downloads"))
        }
        if reasonCodes.contains("popular") {
            return RepoCardInlineMetadata(systemImage: "star", text: .l10n("explore.discoverySignal.popular"))
        }

        let signalCodes = repo.signals.map { $0.code.lowercased() }
        if signalCodes.contains("release") {
            return RepoCardInlineMetadata(systemImage: "shippingbox", text: .l10n("explore.discoverySignal.recentRelease"))
        }
        if signalCodes.contains("downloads") {
            return RepoCardInlineMetadata(systemImage: "arrow.down.circle", text: .l10n("explore.discoverySignal.downloads"))
        }
        if signalCodes.contains("stars") {
            return RepoCardInlineMetadata(systemImage: "star", text: .l10n("explore.discoverySignal.popular"))
        }
        return nil
    }

    private func repoRowIdentity(for repo: DiscoveryRepoDTO) -> String {
        // 同一个 repo 可能同时出现在发现 / 热门 / 新发布；把 mode 和 release 时间纳入
        // row identity，避免 SwiftUI List 复用旧卡片导致新发布的发布时间 chip 不刷新。
        "\(mode.id)-\(repo.repoID)-\(repo.latestReleaseAt ?? "__no_release__")"
    }

    private var indexedRepos: [IndexedDiscoveryRepo] {
        globalFilteredRepos(viewModel.repos)
            .enumerated()
            .map { IndexedDiscoveryRepo(index: $0.offset, repo: $0.element) }
    }

    private func globalFilteredRepos(_ repos: [DiscoveryRepoDTO]) -> [DiscoveryRepoDTO] {
        repos.filter { repo in
            matchesGlobalFilters(
                repoId: repo.repoID,
                owner: repo.owner,
                name: repo.name,
                language: repo.language,
                isArchived: repo.isArchived,
                isFork: repo.isFork
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

    private var queryIdentity: String {
        [
            mode.id,
            mode == .discover ? "__language_unused__" : (selectedLanguage ?? "__all__"),
            mode == .discover ? (selectedTopic ?? "__all__") : "__topic_unused__",
            mode == .discover ? (selectedPlatform ?? "__all__") : "__platform_unused__",
            currentSort.id
        ].joined(separator: "|")
    }

    private var contentStateID: String {
        if viewModel.isLoading && viewModel.repos.isEmpty {
            return "explore-loading"
        }
        if let error = viewModel.loadError, viewModel.repos.isEmpty {
            return "explore-error-\(error)"
        }
        return "explore-content-\(mode.id)"
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

    private var formattedFreshness: String? {
        guard let lastRefreshedAt = viewModel.lastRefreshedAt else { return nil }
        return RelativeTimeText.pastEvent(lastRefreshedAt, locale: locale)
    }

    private func applySelectionPolicy() {
        guard !viewModel.repos.isEmpty else {
            selectedRepoID = nil
            selectedRepo = nil
            return
        }
        if let id = selectedRepoID,
           let repo = viewModel.repos.first(where: { $0.repoID == id }) {
            selectedRepo = repo
            return
        }
        guard settings.openFirstDetailOnCategoryChange else {
            selectedRepo = nil
            return
        }
        guard let first = viewModel.repos.first else { return }
        selectedRepoID = first.repoID
        selectedRepo = first
    }

    private func reportRepoCount() {
        onRepoCountChange(viewModel.total)
    }
}

private struct IndexedDiscoveryRepo: Identifiable {
    let index: Int
    let repo: DiscoveryRepoDTO

    var id: Int64 { repo.repoID }
}

private struct ExploreEmptyState: View {
    let systemImage: String
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey?
    let subtitleText: String?

    init(
        systemImage: String,
        titleKey: LocalizedStringKey,
        subtitleKey: LocalizedStringKey? = nil,
        subtitleText: String? = nil
    ) {
        self.systemImage = systemImage
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.subtitleText = subtitleText
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(titleKey)
                .font(.headline)

            if let subtitleKey {
                Text(subtitleKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let subtitleText {
                Text(verbatim: subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
