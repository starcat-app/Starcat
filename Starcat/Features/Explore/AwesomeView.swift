//
//  AwesomeView.swift
//  Starcat
//
//  探索 → Awesome 中栏：全部/单来源、章节筛选、搜索、排序和统一 Repo 行。
//
//  README 章节只在中栏筛选，不展开到 Sidebar。全部来源按 Repository 已聚合的 GitHub ID
//  去重结果展示；单来源沿 README 原始顺序分组，来源描述只作为 metadata，不覆盖官方描述。
//

import AppKit
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
        .task(id: completeDataTaskIdentity) {
            guard requiresCompleteRepositorySet else { return }
            await store.loadAllRepositoryPages()
        }
        .task(id: filteredDisplayItemIDs) {
            await fillVisiblePageIfNeeded()
        }
        .onChange(of: store.selectedSourceID) { _, _ in
            selectedSection = nil
            sort = .original
            dependencies.exploreMultiSelectionStore.clearSelection()
            reportCount()
        }
        .onChange(of: filteredDisplayItemIDs) { _, _ in
            reportCount()
            retainVisibleMultiSelection(filteredRepositoryIDs)
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
        } else if store.isLoading, store.repositories.isEmpty, store.resources.isEmpty {
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
        } else if filteredDisplayItems.isEmpty {
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
                    ForEach(group.items) { item in
                        switch item {
                        case .repository(let repo):
                            repositoryRow(repo)
                                .task {
                                    guard !requiresCompleteRepositorySet else { return }
                                    await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: repo.id)
                                }
                        case .resource(let resource):
                            resourceRow(resource)
                        }
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
                Task { await selectAllVisibleRepositories(in: multiStore) }
            } label: {
                EmptyView()
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!multiStore.isActive)
            .hidden()
        }
    }

    private func resourceRow(_ resource: AwesomeResourceItem) -> some View {
        let multiStore = dependencies.exploreMultiSelectionStore
        return Button {
            // 资源条目不是 GitHub 仓库，不能进入仓库多选状态或详情页；单击直接打开原始证据 URL。
            guard !multiStore.isActive else { return }
            NSWorkspace.shared.open(resource.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: resource.targetType == .repositoryResource ? "doc.text" : "link")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(resource.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let description = resource.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(resource.url.host ?? resource.url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(multiStore.isActive)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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
        store.repositorySections
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
        return filtered
    }

    private var filteredResources: [AwesomeResourceItem] {
        guard resourcesMatchGlobalFilters else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.resources.filter { resource in
            let matchesSection = selectedSection == nil ||
                resource.evidence.sectionPath.joined(separator: " / ") == selectedSection
            guard matchesSection else { return false }
            guard !query.isEmpty else { return true }
            return [resource.title, resource.description, resource.url.absoluteString]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    /// 仓库专属筛选无法解释外站资源。只要用户启用了任一仓库事实筛选，就隐藏资源条目，
    /// 避免把“缺少 GitHub 元数据”误判为满足筛选条件。
    private var resourcesMatchGlobalFilters: Bool {
        guard !settings.hideArchived, !settings.hideForks, settings.globalFilterLanguages.isEmpty else { return false }
        guard case .all = settings.starFilter, case .all = settings.libraryFilter else { return false }
        guard case .unknown = settings.wikiAvailabilityFilter,
              case .unknown = settings.healthAvailabilityFilter,
              case .unknown = settings.openSSFAvailabilityFilter
        else { return false }
        return true
    }

    private var filteredDisplayItems: [AwesomeDisplayItem] {
        let items = filteredRepositories.map(AwesomeDisplayItem.repository)
            + filteredResources.map(AwesomeDisplayItem.resource)
        switch sort {
        case .original:
            return items.sorted(by: AwesomeDisplayItem.originalOrder)
        case .stars:
            return items.sorted(by: AwesomeDisplayItem.starOrder)
        case .updated:
            return items.sorted(by: AwesomeDisplayItem.updatedOrder)
        case .name:
            return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private var sectionGroups: [AwesomeSectionGroup] {
        let items = filteredDisplayItems
        guard store.selectedSourceID != nil, sort == .original, selectedSection == nil else {
            return [AwesomeSectionGroup(title: String.l10n("awesome.section.results"), items: items)]
        }
        var order: [String] = []
        var seen: Set<String> = []
        let grouped = Dictionary(grouping: items) { item in
            item.sectionPath.joined(separator: " / ").nilIfEmpty ?? String.l10n("awesome.section.other")
        }
        for item in items {
            let title = item.sectionPath.joined(separator: " / ").nilIfEmpty ?? String.l10n("awesome.section.other")
            if seen.insert(title).inserted { order.append(title) }
        }
        return order.map { AwesomeSectionGroup(title: $0, items: grouped[$0] ?? []) }
    }

    private var filteredRepositoryIDs: [Int64] {
        filteredRepositories.map(\.id)
    }

    private var filteredDisplayItemIDs: [String] {
        filteredDisplayItems.map(\.id)
    }

    private func selectionSnapshot(for repo: AwesomeRepositoryItem) -> SelectionSnapshot {
        SelectionSnapshot(ghRepoId: repo.id, owner: repo.owner, name: repo.name)
    }

    private func retainVisibleMultiSelection(_ visibleIDs: [Int64]) {
        let multiStore = dependencies.exploreMultiSelectionStore
        // 分页未完成时 visibleIDs 只是已加载前缀，不能拿它删除后续页已有的选中项。
        guard multiStore.isActive, !store.hasMoreRepositories else { return }
        multiStore.retain(visibleIDs: Set(visibleIDs))
    }

    private func selectAllVisibleRepositories(in multiStore: MultiSelectionStore) async {
        await store.loadAllRepositoryPages()
        guard !Task.isCancelled else { return }
        multiStore.selectAll(filteredRepositories.map { selectionSnapshot(for: $0) })
    }

    /// 全局筛选可能让一页 40 条只剩少量结果。继续读取本地页直到凑满一个可滚动首屏，
    /// 否则空结果页没有行可触发预取，用户会误以为整个来源没有匹配仓库。
    private func fillVisiblePageIfNeeded() async {
        guard !requiresCompleteRepositorySet else { return }
        while filteredRepositories.count < AwesomeStore.repositoryPageSize,
              store.hasMoreRepositories,
              let lastRepositoryID = store.repositories.last?.id,
              !Task.isCancelled {
            await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: lastRepositoryID)
        }
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
        if store.hasMoreRepositories, !requiresCompleteRepositorySet {
            // 默认分页浏览时不能把已加载 40 条冒充完整结果数。
            onRepoCountChange(store.currentRepositoryCount)
        } else {
            onRepoCountChange(filteredDisplayItems.count)
        }
    }

    private var requiresCompleteRepositorySet: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSection != nil
            || sort != .original
    }

    private var completeDataTaskIdentity: AwesomeCompleteDataTaskIdentity {
        AwesomeCompleteDataTaskIdentity(
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedSection: selectedSection,
            sort: sort
        )
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

private enum AwesomeSortOption: String, CaseIterable, Identifiable, Hashable {
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
    let items: [AwesomeDisplayItem]
    var id: String { title }
}

private enum AwesomeDisplayItem: Identifiable {
    case repository(AwesomeRepositoryItem)
    case resource(AwesomeResourceItem)

    var id: String {
        switch self {
        case .repository(let repo): return "repo:\(repo.id)"
        case .resource(let resource): return "resource:\(resource.id)"
        }
    }

    var title: String {
        switch self {
        case .repository(let repo): return repo.fullName
        case .resource(let resource): return resource.title
        }
    }

    var sectionPath: [String] {
        switch self {
        case .repository(let repo): return repo.evidence.first?.sectionPath ?? []
        case .resource(let resource): return resource.evidence.sectionPath
        }
    }

    private var entryOrder: Int {
        switch self {
        case .repository(let repo): return repo.evidence.first?.entryOrder ?? .max
        case .resource(let resource): return resource.evidence.entryOrder
        }
    }

    private var sourceOrder: Int {
        switch self {
        case .repository(let repo): return repo.evidence.first?.source.sortOrder ?? .max
        case .resource(let resource): return resource.evidence.source.sortOrder
        }
    }

    static func originalOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        if lhs.entryOrder != rhs.entryOrder { return lhs.entryOrder < rhs.entryOrder }
        return lhs.id < rhs.id
    }

    static func starOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.repository(let left), .repository(let right)):
            return left.stars == right.stars ? left.id < right.id : left.stars > right.stars
        case (.repository, .resource): return true
        case (.resource, .repository): return false
        case (.resource, .resource): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func updatedOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.repository(let left), .repository(let right)):
            if left.updatedAt != right.updatedAt {
                return (left.updatedAt ?? .distantPast) > (right.updatedAt ?? .distantPast)
            }
            return left.id < right.id
        case (.repository, .resource): return true
        case (.resource, .repository): return false
        case (.resource, .resource): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct AwesomeWikiAvailabilityTaskIdentity: Hashable {
    let filter: RepoSignalAvailabilityFilter
    let repositoryIDs: [Int64]
}

private struct AwesomeCompleteDataTaskIdentity: Hashable {
    let searchText: String
    let selectedSection: String?
    let sort: AwesomeSortOption
}
