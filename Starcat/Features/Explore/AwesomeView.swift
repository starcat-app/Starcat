//
//  AwesomeView.swift
//  Starcat
//
//  探索 → Awesome 中栏：全部/单来源、章节筛选、搜索、排序和统一 Repo 行。
//
//  README 章节只在中栏筛选，不展开到 Sidebar。全部来源按 Repository 已聚合的 GitHub ID
//  去重结果展示；单来源沿 README 原始顺序分组，来源描述只作为 metadata，不覆盖官方描述。
//

import SwiftUI

struct AwesomeView: View {
    let store: AwesomeStore
    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @State private var searchText = ""
    @State private var selectedSection: String?
    @State private var sort: AwesomeSortOption = .original
    @State private var libraryStateMap: [Int64: LibraryState] = [:]
    @State private var wikiAvailabilityMap: [Int64: Bool] = [:]

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            filterBar
            Divider()
            errorBanner
            content
        }
        .task(id: authSession.state.isAuthenticated) {
            guard authSession.state.isAuthenticated else {
                onRepoCountChange(0)
                return
            }
            await store.loadAwesome()
            reportCount()
        }
        .task {
            await reloadLibraryStateMap()
            await observeLibraryStateChanges()
        }
        .task(id: wikiAvailabilityTaskIdentity) {
            await reloadWikiAvailabilityMap()
        }
        .onChange(of: store.selectedSourceID) { _, _ in
            selectedSection = nil
            sort = .original
            reportCount()
        }
        .onChange(of: filteredRepositoryIDs) { _, visibleIDs in
            reportCount()
            retainVisibleMultiSelection(visibleIDs)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("awesome.search.placeholder", text: $searchText)
                .textFieldStyle(.plain)

            if store.selectedSourceID != nil {
                Picker("awesome.section.title", selection: $selectedSection) {
                    Text("awesome.section.all").tag(String?.none)
                    ForEach(availableSections, id: \.self) { section in
                        Text(section).tag(String?.some(section))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            Picker("awesome.sort.title", selection: $sort) {
                ForEach(AwesomeSortOption.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)

            SyncIconButton(
                isRefreshing: store.isRefreshing,
                disabled: store.isRefreshing,
                tooltip: String.l10n("explore.refresh.tooltip")
            ) {
                Task { await store.refresh() }
            }
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                .padding(.vertical, 6)
                .background(.bar)
        } else if !store.sourceRefreshErrors.isEmpty {
            Text(String(format: String.l10n("awesome.error.partialRefreshFormat"), store.sourceRefreshErrors.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !authSession.state.isAuthenticated {
            ContentUnavailableView {
                Label("sidebar.loginPrompt", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        } else if store.isLoading, store.repositories.isEmpty {
            RepoSkeletonListView(rowCount: 10)
        } else if store.enabledSources.isEmpty {
            ContentUnavailableView {
                Label("awesome.empty.noSources.title", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text("awesome.empty.noSources.subtitle")
            } actions: {
                Button("awesome.sources.manage") {
                    Task { await store.presentSourceManager() }
                }
            }
        } else if filteredRepositories.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            repositoryList
        }
    }

    private var repositoryList: some View {
        let multiStore = dependencies.exploreMultiSelectionStore
        return List {
            ForEach(sectionGroups) { group in
                Section(group.title) {
                    ForEach(group.repositories) { repo in
                        repositoryRow(repo)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
        .background {
            // Cmd+A 的语义与其它列表一致：只选择当前搜索、章节与全局筛选后的可见仓库。
            Button {
                multiStore.selectAll(filteredRepositories.map { selectionSnapshot(for: $0) })
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!multiStore.isActive)
            .hidden()
        }
    }

    private func repositoryRow(_ repo: AwesomeRepositoryItem) -> some View {
        let multiStore = dependencies.exploreMultiSelectionStore
        return Button {
            AwesomeListSelectionPolicy.select(
                repo,
                awesomeStore: store,
                multiSelectionStore: multiStore
            )
        } label: {
            UnifiedRepoRow(
                card: repo.discoveryDTO.asCardData(
                    registry: dependencies.starredRegistry,
                    footerMetadata: footerMetadata(for: repo),
                    openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.id)
                ),
                isSelected: multiStore.isActive
                    ? multiStore.contains(ghRepoId: repo.id)
                    : (store.selectedRepositoryID == repo.id),
                showStarredCheckmark: true
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func footerMetadata(for repo: AwesomeRepositoryItem) -> RepoCardInlineMetadata? {
        if store.selectedSourceID == nil, repo.evidence.count > 1 {
            return RepoCardInlineMetadata(
                systemImage: "square.stack.3d.up",
                text: String(format: String.l10n("awesome.repo.sourceCountFormat"), repo.evidence.count)
            )
        }
        guard let evidence = repo.evidence.first else { return nil }
        let text = evidence.entryDescription ?? evidence.sectionPath.last
        return text.map { RepoCardInlineMetadata(systemImage: "text.quote", text: $0) }
    }

    private var availableSections: [String] {
        var seen: Set<String> = []
        return store.repositories.compactMap { repo in
            let section = repo.evidence.first?.sectionPath.joined(separator: " / ")
            guard let section, !section.isEmpty, seen.insert(section).inserted else { return nil }
            return section
        }
    }

    private var filteredRepositories: [AwesomeRepositoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = store.repositories.filter { repo in
            guard matchesGlobalFilters(repo) else { return false }
            let matchesSection = selectedSection == nil || repo.evidence.contains {
                $0.sectionPath.joined(separator: " / ") == selectedSection
            }
            guard matchesSection else { return false }
            guard !query.isEmpty else { return true }
            let fields: [String?] = [repo.fullName, repo.description]
                + repo.evidence.flatMap { [$0.entryTitle, $0.entryDescription, $0.source.displayName] }
            return fields.compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
        switch sort {
        case .original:
            return filtered
        case .stars:
            return filtered.sorted { $0.stars == $1.stars ? $0.id < $1.id : $0.stars > $1.stars }
        case .updated:
            return filtered.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                }
                return $0.id < $1.id
            }
        case .name:
            return filtered.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        }
    }

    private var sectionGroups: [AwesomeSectionGroup] {
        guard store.selectedSourceID != nil, sort == .original, selectedSection == nil else {
            return [AwesomeSectionGroup(title: String.l10n("awesome.section.results"), repositories: filteredRepositories)]
        }
        var order: [String] = []
        let grouped = Dictionary(grouping: filteredRepositories) { repo in
            repo.evidence.first?.sectionPath.joined(separator: " / ") ?? String.l10n("awesome.section.other")
        }
        for repo in filteredRepositories {
            let title = repo.evidence.first?.sectionPath.joined(separator: " / ") ?? String.l10n("awesome.section.other")
            if !order.contains(title) { order.append(title) }
        }
        return order.map { AwesomeSectionGroup(title: $0, repositories: grouped[$0] ?? []) }
    }

    private var filteredRepositoryIDs: [Int64] {
        filteredRepositories.map(\.id)
    }

    private func selectionSnapshot(for repo: AwesomeRepositoryItem) -> SelectionSnapshot {
        SelectionSnapshot(ghRepoId: repo.id, owner: repo.owner, name: repo.name)
    }

    private func retainVisibleMultiSelection(_ visibleIDs: [Int64]) {
        let multiStore = dependencies.exploreMultiSelectionStore
        guard multiStore.isActive else { return }
        multiStore.retain(visibleIDs: Set(visibleIDs))
    }

    private func matchesGlobalFilters(_ repo: AwesomeRepositoryItem) -> Bool {
        AwesomeGlobalFilterPolicy.matches(
            repo,
            options: AwesomeGlobalFilterOptions(
                hideArchived: settings.hideArchived,
                hideForks: settings.hideForks,
                starFilter: settings.starFilter,
                libraryFilter: settings.libraryFilter,
                languages: settings.globalFilterLanguages,
                wikiFilter: settings.wikiAvailabilityFilter,
                healthFilter: settings.healthAvailabilityFilter,
                openSSFFilter: settings.openSSFAvailabilityFilter
            ),
            facts: AwesomeGlobalFilterFacts(
                isStarred: dependencies.starredRegistry.contains(ghRepoId: repo.id),
                isInLibrary: libraryStateMap[repo.id] == .inLibrary,
                wikiAvailability: wikiAvailabilityMap[repo.id],
                hasHealthData: dependencies.repoHealthStore.snapshot(for: repo.id) != nil,
                hasOpenSSFData: dependencies.openSSFScoreStore.record(for: repo.id)?.badgeData != nil
            )
        )
    }

    private var wikiAvailabilityTaskIdentity: AwesomeWikiAvailabilityTaskIdentity {
        AwesomeWikiAvailabilityTaskIdentity(
            filter: settings.wikiAvailabilityFilter,
            repositoryIDs: store.repositories.map(\.id)
        )
    }

    private func reloadLibraryStateMap() async {
        libraryStateMap = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
    }

    private func reloadWikiAvailabilityMap() async {
        guard settings.wikiAvailabilityFilter != .unknown else {
            wikiAvailabilityMap = [:]
            return
        }
        let requests = store.repositories.map {
            WikiAvailabilityRequest(id: $0.id, owner: $0.owner, repo: $0.name)
        }
        let snapshot = await WikiAvailabilitySnapshotLoader.load(requests: requests)
        guard !Task.isCancelled else { return }
        wikiAvailabilityMap = snapshot
    }

    private func observeLibraryStateChanges() async {
        let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
        for await note in stream {
            guard !Task.isCancelled else { break }
            guard let repoID = note.userInfo?["repoId"] as? Int64,
                  let raw = note.userInfo?["libraryState"] as? String else { continue }
            libraryStateMap[repoID] = LibraryState.parse(raw)
        }
    }

    private func reportCount() {
        onRepoCountChange(filteredRepositories.count)
    }
}

/// Awesome 行点击必须与顶部全局多选按钮共享同一状态机。
/// 抽出策略后可直接覆盖“多选只切换集合、单选才打开详情”的关键分支，避免 UI 回归。
@MainActor
enum AwesomeListSelectionPolicy {
    static func select(
        _ repo: AwesomeRepositoryItem,
        awesomeStore: AwesomeStore,
        multiSelectionStore: MultiSelectionStore
    ) {
        if multiSelectionStore.isActive {
            multiSelectionStore.toggle(
                SelectionSnapshot(ghRepoId: repo.id, owner: repo.owner, name: repo.name)
            )
        } else {
            awesomeStore.selectedRepositoryID = repo.id
        }
    }
}

/// Awesome 与其它 Explore 列表共用同一组持久筛选设置，但仓库来自独立来源。
/// 这里把筛选需要的设置和本地事实显式建模，避免 UI 分支各自解释 `unknown` 的含义。
struct AwesomeGlobalFilterOptions {
    let hideArchived: Bool
    let hideForks: Bool
    let starFilter: RepoStarFilter
    let libraryFilter: RepoLibraryFilter
    let languages: [String]
    let wikiFilter: RepoSignalAvailabilityFilter
    let healthFilter: RepoSignalAvailabilityFilter
    let openSSFFilter: RepoSignalAvailabilityFilter
}

struct AwesomeGlobalFilterFacts {
    let isStarred: Bool
    let isInLibrary: Bool
    let wikiAvailability: Bool?
    let hasHealthData: Bool
    let hasOpenSSFData: Bool
}

enum AwesomeGlobalFilterPolicy {
    static func matches(
        _ repo: AwesomeRepositoryItem,
        options: AwesomeGlobalFilterOptions,
        facts: AwesomeGlobalFilterFacts
    ) -> Bool {
        guard options.starFilter.matches(isStarred: facts.isStarred) else { return false }
        if options.hideArchived, repo.isArchived { return false }
        if options.hideForks, repo.isFork { return false }
        if !options.languages.isEmpty {
            guard let language = repo.language else { return false }
            guard options.languages.contains(where: {
                $0.caseInsensitiveCompare(language) == .orderedSame
            }) else { return false }
        }
        switch options.libraryFilter {
        case .all:
            break
        case .inLibrary:
            guard facts.isInLibrary else { return false }
        case .outsideLibrary:
            guard !facts.isInLibrary else { return false }
        }
        if options.wikiFilter != .unknown {
            guard let wikiAvailability = facts.wikiAvailability,
                  matchesAvailability(wikiAvailability, filter: options.wikiFilter)
            else { return false }
        }
        guard matchesAvailability(facts.hasHealthData, filter: options.healthFilter) else { return false }
        guard matchesAvailability(facts.hasOpenSSFData, filter: options.openSSFFilter) else { return false }
        return true
    }

    private static func matchesAvailability(
        _ available: Bool,
        filter: RepoSignalAvailabilityFilter
    ) -> Bool {
        switch filter {
        case .unknown: return true
        case .available: return available
        case .missing: return !available
        }
    }
}

private enum AwesomeSortOption: String, CaseIterable, Identifiable {
    case original
    case stars
    case updated
    case name

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .original: return "awesome.sort.original"
        case .stars: return "awesome.sort.stars"
        case .updated: return "awesome.sort.updated"
        case .name: return "awesome.sort.name"
        }
    }
}

private struct AwesomeSectionGroup: Identifiable {
    let title: String
    let repositories: [AwesomeRepositoryItem]
    var id: String { title }
}

private struct AwesomeWikiAvailabilityTaskIdentity: Hashable {
    let filter: RepoSignalAvailabilityFilter
    let repositoryIDs: [Int64]
}
