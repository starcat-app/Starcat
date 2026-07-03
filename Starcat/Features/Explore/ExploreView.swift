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

    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @State private var discoveryViewModel = ExploreDiscoveryViewModel()

    var body: some View {
        Group {
            switch selectedMode {
            case .trending:
                trendingContent
            case .weekly:
                WeeklyContentView()
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
            Menu {
                Section("explore.sort.title") {
                    ForEach(ExploreSortOption.options(for: mode)) { option in
                        Button {
                            sortBinding.wrappedValue = option
                        } label: {
                            filterMenuRow(
                                title: option.titleKey,
                                isSelected: option == currentSort
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    Text("explore.sort.title")
                    Text(currentSort.titleKey)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()

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

    @ViewBuilder
    private func filterMenuRow(title: LocalizedStringKey, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var sortBinding: Binding<ExploreSortOption> {
        Binding(
            get: { currentSort },
            set: { viewModel.sortOption = $0.normalized(for: mode) }
        )
    }

    private var currentSort: ExploreSortOption {
        viewModel.sortOption.normalized(for: mode)
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
            repoList
        }
    }

    private var repoList: some View {
        List {
            ForEach(indexedRepos) { item in
                let repo = item.repo
                Button {
                    selectedRepoID = repo.repoID
                    selectedRepo = repo
                } label: {
                    UnifiedRepoRow(
                        card: repo.asCardData(
                            registry: dependencies.starredRegistry,
                            isInLibrary: isInLibrary(repo.repoID),
                            openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.repoID)
                        ),
                        isSelected: selectedRepoID == repo.repoID,
                        showStarredCheckmark: true
                    )
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
        .task(id: viewModel.reposRevision) {
            await dependencies.openSSFScoreStore.loadCachedScores(for: viewModel.repos.map(\.repoID))
        }
    }

    private var indexedRepos: [IndexedDiscoveryRepo] {
        viewModel.repos.enumerated().map { IndexedDiscoveryRepo(index: $0.offset, repo: $0.element) }
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
