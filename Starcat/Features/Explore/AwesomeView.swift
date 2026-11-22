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
    @Namespace private var selectionSpace
    @State private var skillPageBudget = RepoSkillPageBudget()
    @State private var isLoadingVisiblePage = false
    let store: AwesomeStore
    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @State private var searchText = ""
    @State private var quickSearchDraft = ""
    @State private var isQuickSearchExpanded = false
    @State private var selectedSection: String?
    @State private var sort: AwesomeSortOption = .original
    @State private var libraryStateMap: [Int64: LibraryState] = [:]
    @State private var wikiAvailabilityMap: [Int64: Bool] = [:]

    private var listModel: AwesomeListModel { store.listModel }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            filterBar
            Divider()
            errorBanner
            MiddleListPresentation(showsSkeleton: showsSkeleton, rowCount: 10) {
                content
            }
        }
        .preference(key: RepoLicenseOptionsPreferenceKey.self,
                    value: RepoLicenseFilter.options(store.repositories.map(\.licenseSpdx)))
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
            reportCount()
        }
        .task(id: listIdentity) {
            await updateListProjection()
            await fillVisiblePageIfNeeded()
        }
        .task(id: skillScanTaskIdentity) {
            guard settings.skillFilter != .any, listModel.identity == listIdentity else { return }
            dependencies.repoSkillStore.enqueue(skillCandidates, scope: skillScanScope)
            await fillVisiblePageIfNeeded()
        }
        .onChange(of: store.hasMoreRepositories) { _, hasMore in
            if !hasMore { reportCount() }
        }
        .onChange(of: store.selectedSourceID) { _, _ in
            resetQuickSearch()
            selectedSection = nil
            sort = .original
            dependencies.exploreMultiSelectionStore.clearSelection()
            reportCount()
        }
        .onChange(of: listModel.projectionRevision) { _, _ in
            reportCount()
            retainVisibleMultiSelection(listModel.repositoryIDs)
        }
    }

    private var presentationQuery: String {
        "\(store.selectedSourceID ?? ""):\(searchText):\(selectedSection ?? ""):\(sort):\(settings.skillScanFilterIdentity)"
    }

    private var showsSkeleton: Bool {
        guard authSession.state.isAuthenticated else { return false }
        if store.repositories.isEmpty, store.resources.isEmpty,
           !store.hasLoadedCachedState || store.isLoading {
            return true
        }
        guard !store.enabledSources.isEmpty else { return false }
        // 页内补齐完整来源属于筛选。普通刷新只替换同一查询的结果版本。
        return (requiresCompleteRepositorySet && store.hasMoreRepositories) ||
            listModel.identity?.sourceID != store.selectedSourceID ||
            listModel.identity?.query != listIdentity.query
    }

    private var filterBar: some View {
        QuickSearchToolbarContent(
            isExpanded: $isQuickSearchExpanded,
            draft: $quickSearchDraft,
            committedQuery: searchText,
            placeholder: "list.quickSearch.placeholder",
            onSubmit: { query in
                let normalizedQuery = QuickSearchTextMatcher.normalized(query)
                searchText = normalizedQuery
                quickSearchDraft = normalizedQuery
            },
            onClear: { searchText = "" }
        ) {
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

            // 与其它中栏共用 UnifiedSortMenu：fixedSize 紧贴内容，避免原生 Picker
            // 定宽后按钮在 frame 内居中、拉大与搜索图标的视觉间距。
            UnifiedSortMenu(
                selection: $sort,
                options: AwesomeSortOption.allCases,
                displayName: { $0.titleKey },
                iconSource: { $0.iconSource }
            )

            // 与其它中栏一致：Spacer 让搜索 / 筛选靠左，同步 / 多选靠右。
            Spacer()
                .layoutPriority(AdaptiveToolbarStatusText.spacerPriority)

            Button("awesome.sources.button") {
                Task { await store.presentSourceManager() }
            }
            .lineLimit(1)
            .fixedSize()
            .disabled(!authSession.state.isAuthenticated)
            .help(Text("awesome.sources.manage"))
            .accessibilityLabel(Text("awesome.sources.manage"))

            SyncIconButton(
                isRefreshing: store.isRefreshing,
                disabled: store.isRefreshing,
                tooltip: String.l10n("explore.refresh.tooltip")
            ) {
                Task { await store.refresh() }
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

    /// 切换 Awesome 数据源时不能沿用上一个来源的搜索条件，避免新列表看起来像空数据。
    private func resetQuickSearch() {
        isQuickSearchExpanded = false
        quickSearchDraft = ""
        searchText = ""
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
        } else if store.enabledSources.isEmpty {
            ContentUnavailableView {
                Label("awesome.empty.noSources.title", businessIcon: .curatedCollection, pointSize: 40)
            } description: {
                Text("awesome.empty.noSources.subtitle")
            } actions: {
                Button("awesome.sources.manage") {
                    Task { await store.presentSourceManager() }
                }
            }
        } else if listModel.rows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            repositoryList
        }
    }

    private var repositoryList: some View {
        let multiStore = dependencies.exploreMultiSelectionStore
        let groups = listModel.groups
        // 按实际章节顺序只登记首屏 15 项；不能在每个章节重新从 0 播放，或逐行扫描整个列表。
        let revealIndices = Dictionary(uniqueKeysWithValues: groups.lazy.flatMap(\.items)
            .prefix(ListRowRevealMetrics.animatedRowLimit)
            .enumerated().map { ($0.element.id, $0.offset) })
        // 数据追加和后台刷新不改变动画身份，避免正在阅读的卡片反复退场。
        let snapshotID = "\(store.selectedSourceID ?? ""):\(searchText):\(selectedSection ?? ""):\(sort):\(settings.skillScanFilterIdentity)".hashValue
        return List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Group {
                            switch item {
                            case .repository(let repo): repositoryRow(repo)
                            case .resource(let resource): resourceRow(resource)
                            }
                        }
                        .listRowReveal(
                            index: revealIndices[item.id] ?? ListRowRevealMetrics.animatedRowLimit,
                            snapshotID: snapshotID,
                            replayAfterSnapshotCommit: true
                        )
                        .automaticListPagination(appearingIndex: listModel.rowIndices[item.id] ?? -1)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .automaticListPagination(
            visibleItemCount: listModel.rows.count,
            loadedItemCount: store.repositories.count,
            hasMore: listModel.hasMore || (store.hasMoreRepositories && !requiresCompleteRepositorySet),
            isLoading: listModel.isUpdating || isLoadingVisiblePage || store.isLoadingMoreRepositories,
            identity: "\(presentationQuery):\(listModel.projectionRevision)"
        ) {
            await loadNextVisiblePage()
        }
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
                selectionNamespace: multiStore.isActive ? nil : selectionSpace
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

    private var skillCandidates: [Repo] {
        // formatter 只在真正启用 Skills 筛选后创建，并在本批次复用；不跨隔离域共享可变实例。
        let formatter = ISO8601DateFormatter.shared
        return listModel.skillCandidates.map {
            $0.discoveryDTO(dateFormatter: formatter)
                .toEphemeralRepo(isStarred: dependencies.starredRegistry.contains(ghRepoId: $0.id))
        }
    }

    private var skillScanTaskIdentity: String? {
        guard settings.skillFilter != .any else { return nil }
        return "\(skillScanScope):\(listModel.projectionRevision):\(dependencies.repoSkillStore.paginationRevision)"
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
        await updateListProjection()
        guard !Task.isCancelled else { return }
        let visibleIDs = Set(listModel.repositoryIDs)
        multiStore.selectAll(store.repositories.filter { visibleIDs.contains($0.id) }.map { selectionSnapshot(for: $0) })
    }

    /// 全局筛选可能让一页只剩少量结果。继续读取本地页直到凑满一个可滚动首屏，
    /// 否则空结果页没有行可触发预取，用户会误以为整个来源没有匹配仓库。
    private var skillScanScope: String {
        "awesome:\(store.selectedSourceID ?? ""):\(searchText):\(selectedSection ?? ""):\(settings.skillScanFilterIdentity)"
    }

    private func fillVisiblePageIfNeeded() async {
        guard !requiresCompleteRepositorySet else { return }
        guard listModel.identity == listIdentity,
              ListPaginationPolicy.shouldFillVisibleWindow(
                  visibleItemCount: listModel.total, hasMore: store.hasMoreRepositories
              ),
              let lastRepositoryID = store.repositories.last?.id,
              !Task.isCancelled else { return }
        if settings.skillFilter != .any,
           !skillPageBudget.claim(scope: "\(skillScanScope):\(dependencies.repoSkillStore.paginationRevision)") { return }
        await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: lastRepositoryID)
    }

    private var listIdentity: AwesomeListIdentity {
        AwesomeListIdentity(
            revision: store.repositoryRevision,
            sourceID: store.selectedSourceID,
            query: AwesomeListQuery(
                localeIdentifier: locale.identifier,
                search: searchText, section: selectedSection, sort: sort,
                options: AwesomeGlobalFilterOptions(
                    hideArchived: settings.hideArchived,
                    hideForks: settings.hideForks,
                    starFilter: settings.starFilter,
                    libraryFilter: settings.libraryFilter,
                    languages: settings.globalFilterLanguages,
                    wikiFilter: settings.wikiAvailabilityFilter,
                    healthFilter: settings.healthAvailabilityFilter,
                    openSSFFilter: settings.openSSFAvailabilityFilter,
                    licenseFilter: settings.licenseFilter
                ),
                skillFilter: settings.skillFilter,
                skillRevision: settings.skillFilter == .any ? 0 : dependencies.repoSkillStore.revision,
                starredIDs: settings.starFilter == .all ? [] : dependencies.starredRegistry.ids,
                libraryIDs: settings.libraryFilter == .all ? [] :
                    Set(libraryStateMap.compactMap { $0.value == .inLibrary ? $0.key : nil }),
                wikiAvailability: settings.wikiAvailabilityFilter == .unknown ? [:] : wikiAvailabilityMap,
                healthIDs: settings.healthAvailabilityFilter == .unknown ? [] :
                    Set(dependencies.repoHealthStore.snapshots.keys),
                openSSFIDs: settings.openSSFAvailabilityFilter == .unknown ? [] :
                    Set(dependencies.openSSFScoreStore.records.compactMap { $0.value.badgeData != nil ? $0.key : nil })
            )
        )
    }

    private func updateListProjection() async {
        let identity = listIdentity
        guard !requiresCompleteRepositorySet || !store.hasMoreRepositories else { return }
        let presence: [Int64: RepoSkillPresence] = settings.skillFilter == .any ? [:] :
            Dictionary(uniqueKeysWithValues: store.repositories.map {
                ($0.id, dependencies.repoSkillStore.presence(repositoryID: $0.id))
            })
        await listModel.update(
            identity: identity, repositories: store.repositories,
            resources: store.resources, skillPresence: presence
        )
    }

    private func loadNextVisiblePage() async {
        guard !isLoadingVisiblePage, !store.isLoadingMoreRepositories, listModel.identity == listIdentity else { return }
        isLoadingVisiblePage = true
        defer { isLoadingVisiblePage = false }
        if listModel.hasMore {
            listModel.loadMore()
        } else if !requiresCompleteRepositorySet, let lastID = store.repositories.last?.id {
            let requestedQuery = listIdentity.query
            let requestedSourceID = store.selectedSourceID
            await store.loadMoreRepositoriesIfNeeded(currentRepositoryID: lastID)
            guard store.selectedSourceID == requestedSourceID, listIdentity.query == requestedQuery else { return }
            await updateListProjection()
            guard store.selectedSourceID == requestedSourceID, listIdentity.query == requestedQuery,
                  listModel.identity == listIdentity else { return }
            listModel.loadMore()
        }
    }

    private var wikiAvailabilityTaskIdentity: AwesomeWikiAvailabilityTaskIdentity {
        AwesomeWikiAvailabilityTaskIdentity(
            filter: settings.wikiAvailabilityFilter,
            repositoryIDs: settings.wikiAvailabilityFilter == .unknown ? [] : store.repositories.map(\.id)
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
        // 完整读取与后台投影分两次提交；不能在两者之间把上一查询的数量报给工具栏。
        guard listModel.identity == listIdentity else { return }
        if settings.skillFilter != .any {
            onRepoCountChange(listModel.total)
            return
        }
        // 许可证需要完整来源才能发布完整计数。
        guard !settings.licenseFilter.isActive || !store.hasMoreRepositories else { return }
        if store.hasMoreRepositories, !requiresCompleteRepositorySet {
            // 默认分页浏览时用数据源总数。
            onRepoCountChange(store.currentRepositoryCount)
        } else {
            onRepoCountChange(listModel.total)
        }
    }

    private var requiresCompleteRepositorySet: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSection != nil
            || sort != .original
            || settings.licenseFilter.isActive
    }

    private var completeDataTaskIdentity: AwesomeCompleteDataTaskIdentity {
        AwesomeCompleteDataTaskIdentity(
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedSection: selectedSection,
            sort: sort,
            licenseFilter: settings.licenseFilter,
            sourceID: store.selectedSourceID,
            hasMoreRepositories: store.hasMoreRepositories
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
struct AwesomeGlobalFilterOptions: Hashable, Sendable {
    let hideArchived: Bool
    let hideForks: Bool
    let starFilter: RepoStarFilter
    let libraryFilter: RepoLibraryFilter
    let languages: [String]
    let wikiFilter: RepoSignalAvailabilityFilter
    let healthFilter: RepoSignalAvailabilityFilter
    let openSSFFilter: RepoSignalAvailabilityFilter
    var licenseFilter: RepoLicenseFilter = .all

    /// 外站资源没有仓库事实；启用此类筛选时隐藏资源，不将缺失元数据当作命中。
    var includesResources: Bool {
        !licenseFilter.isActive && !hideArchived && !hideForks && languages.isEmpty
            && starFilter == .all && libraryFilter == .all && wikiFilter == .unknown
            && healthFilter == .unknown && openSSFFilter == .unknown
    }
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
        guard options.licenseFilter.matches(repo.licenseSpdx) else { return false }
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

enum AwesomeSortOption: String, CaseIterable, Identifiable, Hashable, Sendable {
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
    // 与 ExploreSortOption 同款图标，保证排序菜单在全 App 内视觉一致。
    var iconSource: BusinessIcon.Source {
        switch self {
        case .original: return .business(.metadata)
        case .stars: return .business(.stars)
        case .updated: return .business(.recentUpdate)
        case .name: return .business(.sortAZ)
        }
    }
}

struct AwesomeSectionGroup: Identifiable, Sendable {
    let title: String
    let items: [AwesomeDisplayItem]
    var id: String { title }
}

enum AwesomeDisplayItem: Identifiable, Sendable {
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

private struct AwesomeWikiAvailabilityTaskIdentity: Hashable {
    let filter: RepoSignalAvailabilityFilter
    let repositoryIDs: [Int64]
}

private struct AwesomeCompleteDataTaskIdentity: Hashable {
    let searchText: String
    let selectedSection: String?
    let sort: AwesomeSortOption
    var licenseFilter: RepoLicenseFilter = .all
    let sourceID: String?
    let hasMoreRepositories: Bool
}
