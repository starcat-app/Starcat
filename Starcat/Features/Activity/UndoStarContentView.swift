//
//  UndoStarContentView.swift
//  Starcat
//
//  Undo Star 历史记录内容视图（2026-07-05）。
//

import SwiftUI

// MARK: - UndoStarViewModel

@MainActor
@Observable
final class UndoStarViewModel {
    private(set) var records: [UndoStarRecord] = []
    // View 首帧早于 .task，初始即处于加载态，避免短暂显示“没有取消星标记录”。
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// 即将被清理的记录数
    private(set) var expiringCount: Int = 0
    /// 排序结果就绪时递增，驱动 `listRowReveal` 只在排序切换后重播行入场。
    private(set) var rowRevealRevision = 0
    private(set) var loadedSortOption: UndoStarSortOption?

    /// 只有没有可浏览记录时才用骨架；刷新和排序期间保留原列表及其选择状态。
    var showsSkeleton: Bool { isLoading && records.isEmpty }

    var sortOption: UndoStarSortOption = .unstarredAtDesc {
        didSet { Task { await reload() } }
    }

    private let repository: any UndoStarHistoryRepositoryProtocol
    private let settings: AppSettings
    private var reloadGeneration = 0

    init(repository: any UndoStarHistoryRepositoryProtocol, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        loadError = nil
        let requestedSort = sortOption
        defer {
            if generation == reloadGeneration { isLoading = false }
        }
        do {
            let fetched = try await repository.fetchAll(sort: requestedSort)
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            // 排序结果真正就绪后才重播行入场，避免对仍在显示的旧顺序提前播放。
            if loadedSortOption != requestedSort {
                loadedSortOption = requestedSort
                rowRevealRevision &+= 1
            }
            records = fetched
            await refreshExpiringCount()
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    /// 刷新即将被清理的记录数。
    func refreshExpiringCount() async {
        let retentionDays = settings.undoStarRetentionDays
        guard retentionDays > 0 else { expiringCount = 0; return }
        let cutoff = ISO8601DateFormatter.shared.string(
            from: Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        )
        expiringCount = (try? await repository.countExpired(before: cutoff)) ?? 0
    }

    func load() async { await reload() }

    func clearAll() async {
        do {
            try await repository.clearAll()
            records = []
            // 广播给设置页保留计数与侧栏角标；本视图自己的 onReceive 会再空载一次，无害。
            NotificationCenter.default.post(name: .undoStarHistoryDidChange, object: nil)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Star 成功后从列表中移除（带 2 秒延迟）。
    func removeAfterDelay(ghRepoId: Int64) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            records.removeAll { $0.ghRepoId == ghRepoId }
        }
    }

    /// 从列表中移除指定 repo（带动画）。
    func removeRecords(ghRepoIds: Set<Int64>) {
        records.removeAll { ghRepoIds.contains($0.ghRepoId) }
    }
}

// MARK: - UndoStarContentView

struct UndoStarContentView: View {
    @Namespace private var selectionSpace
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var viewModel: UndoStarViewModel
    @State private var toastMessage: String?

    /// 选中行 → 通知上层展示详情页
    @Binding var selectedRecord: UndoStarRecord?
    let autoSelectFirstRecordRequestID: Int
    var onSelectRepo: ((Repo?) -> Void)?
    @State private var consumedAutoSelectRequestID = 0

    /// 正在执行 star 操作的 repo ID（用于即时 UI 反馈）
    @State private var starringRepoIDs: Set<Int64> = []
    /// 清空全部确认弹窗
    @State private var showClearAllConfirm = false
    @State private var isQuickSearchExpanded = false
    @State private var quickSearchDraft = ""
    @State private var quickSearchQuery = ""

    init(
        repository: any UndoStarHistoryRepositoryProtocol,
        settings: AppSettings,
        selectedRecord: Binding<UndoStarRecord?>,
        autoSelectFirstRecordRequestID: Int = 0,
        onSelectRepo: ((Repo?) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: UndoStarViewModel(repository: repository, settings: settings))
        _selectedRecord = selectedRecord
        self.autoSelectFirstRecordRequestID = autoSelectFirstRecordRequestID
        self.onSelectRepo = onSelectRepo
    }

    /// 取消星标列表读库也可能跨越账号切换，计数只提交给开始加载时的账号代际。
    @State private var countScopeRevision: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            MiddleListPresentation(
                showsSkeleton: viewModel.showsSkeleton,
                rowCount: 5
            ) {
                content
            }
        }
        .toast(message: $toastMessage, icon: "checkmark.circle.fill")
        .alert("activity.undoStar.clearAll.confirmTitle", isPresented: $showClearAllConfirm) {
            Button("settings.undoStar.shortenCancel", role: .cancel) {}
            Button("settings.undoStar.shortenDelete", role: .destructive) {
                Task {
                    await viewModel.clearAll()
                    toastMessage = String.l10n("activity.undoStar.cleared")
                }
            }
        } message: {
            Text("activity.undoStar.clearAll.confirmMessage")
        }
        .task {
            let revision = dependencies.activityCategoryCountService.scopeRevision
            countScopeRevision = revision
            await viewModel.load()
            await viewModel.refreshExpiringCount()
            if viewModel.loadError == nil {
                dependencies.activityCategoryCountService.applyUndoStarCount(
                    viewModel.records.count, scopeRevision: revision
                )
            }
            selectFirstRecordIfRequested()
        }
        .onChange(of: viewModel.records.count) { _, newCount in
            if let countScopeRevision, viewModel.loadError == nil {
                dependencies.activityCategoryCountService.applyUndoStarCount(
                    newCount, scopeRevision: countScopeRevision
                )
            }
            selectFirstRecordIfRequested()
        }
        .onChange(of: autoSelectFirstRecordRequestID) { _, _ in
            selectFirstRecordIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .undoStarHistoryDidChange)) { notification in
            let starredID = notification.userInfo?["starredGhRepoId"] as? Int64
            let previousSelectedID = selectedRecord?.ghRepoId

            if let starredID {
                // 恢复 Star：只定向移除对应记录
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                    viewModel.removeRecords(ghRepoIds: [starredID])
                }
                // 如果当前详情页展示的 repo 已被 star，关闭详情或切到第一条
                if starredID == previousSelectedID {
                    selectFirstRecordOrClearDetail()
                }
            } else {
                // 无指定 ID 的全量变更：新取消 Star 入账、设置页「立即删除」、
                // 后台过期清理都会走到这里。内存列表必须整表重载，
                // 否则清理完成后该分类仍显示已被删除的记录。
                Task {
                    await viewModel.reload()
                    if let previousSelectedID,
                       !viewModel.records.contains(where: { $0.ghRepoId == previousSelectedID }) {
                        selectFirstRecordOrClearDetail()
                    }
                }
            }
            Task { await viewModel.refreshExpiringCount() }
        }
        .starcatRefreshCommand(
            pane: .list,
            identity: "undo-star-\(viewModel.sortOption.rawValue)-\(viewModel.isLoading)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: !viewModel.isLoading
        ) {
            refreshCurrentUndoStarList()
        }
    }

    /// `⌘R` 与首次加载复用同一个本地历史查询，并同步侧栏计数。
    private func refreshCurrentUndoStarList() {
        guard let countScopeRevision else { return }
        Task {
            await viewModel.reload()
            guard viewModel.loadError == nil else { return }
            dependencies.activityCategoryCountService.applyUndoStarCount(
                viewModel.records.count, scopeRevision: countScopeRevision
            )
            selectFirstRecordIfRequested()
        }
    }

    private func selectFirstRecordIfRequested() {
        guard autoSelectFirstRecordRequestID > consumedAutoSelectRequestID,
              !viewModel.isLoading,
              let first = viewModel.records.first else { return }
        consumedAutoSelectRequestID = autoSelectFirstRecordRequestID
        selectRecord(first)
    }

    private func selectRecord(_ record: UndoStarRecord) {
        selectedRecord = record
        Task {
            if let repo = try? await dependencies.undoStarHistoryRepository.fetchRepo(ghRepoId: record.ghRepoId) {
                onSelectRepo?(repo)
            } else {
                onSelectRepo?(record.asRepo())
            }
        }
    }

    /// 详情页当前记录已消失（被恢复 Star 或被清理）时：列表非空选第一条，否则关闭详情。
    private func selectFirstRecordOrClearDetail() {
        if viewModel.records.isEmpty {
            selectedRecord = nil
            onSelectRepo?(nil)
        } else if let first = viewModel.records.first {
            selectedRecord = first
            Task {
                if let repo = try? await dependencies.undoStarHistoryRepository.fetchRepo(ghRepoId: first.ghRepoId) {
                    onSelectRepo?(repo)
                } else {
                    onSelectRepo?(first.asRepo())
                }
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        QuickSearchToolbarContent(
            isExpanded: $isQuickSearchExpanded,
            draft: $quickSearchDraft,
            committedQuery: quickSearchQuery,
            placeholder: "list.quickSearch.activityPlaceholder",
            onSubmit: { query in
                let normalizedQuery = QuickSearchTextMatcher.normalized(query)
                quickSearchQuery = normalizedQuery
                quickSearchDraft = normalizedQuery
            },
            onClear: { quickSearchQuery = "" }
        ) {
            // 排序菜单（与星标模块同款组件）
            UnifiedSortMenu(
                selection: $viewModel.sortOption,
                options: UndoStarSortOption.allCases,
                displayName: { $0.displayName },
                iconSource: { $0.iconSource }
            )

            Spacer()

            if viewModel.expiringCount > 0 {
                Text(String(format: String.l10n("activity.undoStar.expiringFormat"), viewModel.expiringCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 清空按钮
            DestructiveIconButton(help: Text("activity.undoStar.clearAll.help")) {
                showClearAllConfirm = true
            }
            .disabled(viewModel.records.isEmpty)

            // 此分类没有刷新按钮，多选紧接现有顶栏操作，继续复用 Undo Star 的选择状态。
            MultiSelectButton(
                isActive: dependencies.undoStarMultiSelectionStore.isActive,
                action: { dependencies.undoStarMultiSelectionStore.toggle() },
                isDisabled: !authSession.state.isAuthenticated
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.loadError, viewModel.records.isEmpty {
            emptyState(systemImage: "exclamationmark.triangle", text: error)
        } else if viewModel.records.isEmpty {
            emptyState(systemImage: "clock.arrow.circlepath", titleKey: "activity.undoStar.empty")
        } else if visibleRecords.isEmpty {
            emptyState(systemImage: "magnifyingglass", titleKey: "list.quickSearch.empty")
        } else {
            recordList
        }
    }

    /// Undo Star 已一次性加载完整历史，因此可直接在内存中匹配仓库主信息。
    private var visibleRecords: [UndoStarRecord] {
        viewModel.records.filter { record in
            QuickSearchTextMatcher.matches(
                quickSearchQuery,
                candidates: [
                    record.fullName,
                    record.owner,
                    record.name,
                    record.repoDescription,
                    record.language
                ]
            )
        }
    }

    private var recordList: some View {
        let store = dependencies.undoStarMultiSelectionStore
        // 只在查询变化时重播；恢复星标、计数更新和后台刷新不重播整列。
        let snapshotID = "\(viewModel.rowRevealRevision):\(quickSearchQuery)".hashValue
        return List {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                let isStarring = starringRepoIDs.contains(record.ghRepoId)
                Button {
                    if store.isActive {
                        store.toggle(SelectionSnapshot(
                            ghRepoId: record.ghRepoId,
                            owner: record.owner,
                            name: record.name
                        ))
                    } else {
                        selectRecord(record)
                    }
                } label: {
                    UnifiedRepoRow(
                        card: record.asCardData(isStarring: isStarring),
                        isSelected: store.isActive
                            ? store.contains(ghRepoId: record.ghRepoId)
                            : (selectedRecord?.ghRepoId == record.ghRepoId),
                        selectionNamespace: store.isActive ? nil : selectionSpace
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowReveal(index: index, snapshotID: snapshotID, replayAfterSnapshotCommit: true)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // 这里先走详情页 Star，后续可加行尾 Star 按钮）
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .background {
            let store = dependencies.undoStarMultiSelectionStore
            Button {
                let snapshots = visibleRecords.map {
                    SelectionSnapshot(ghRepoId: $0.ghRepoId, owner: $0.owner, name: $0.name)
                }
                store.selectAll(snapshots)
            } label: { EmptyView() }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!store.isActive)
            .hidden()
        }
    }

    private func emptyState(systemImage: String, titleKey: LocalizedStringKey? = nil, text: String? = nil) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if let titleKey { Text(titleKey).font(.headline) }
            else if let text { Text(verbatim: text).font(.headline) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - UndoStarSortOption UI 扩展

extension UndoStarSortOption {
    var displayName: LocalizedStringKey {
        switch self {
        case .unstarredAtDesc: return "sort.unstarredAtDesc"
        case .starsDesc:       return "settings.sort.starsDesc"
        case .starsAsc:        return "settings.sort.starsAsc"
        case .updatedDesc:     return "settings.sort.updatedDesc"
        case .updatedAsc:      return "settings.sort.updatedAsc"
        case .nameAsc:         return "settings.sort.nameAsc"
        case .nameDesc:        return "settings.sort.nameDesc"
        }
    }

    var iconSource: BusinessIcon.Source {
        switch self {
        case .unstarredAtDesc: return .business(.recentUpdate)
        case .starsDesc:       return .business(.stars)
        case .starsAsc:        return .business(.stars)
        case .updatedDesc:     return .business(.recentUpdate)
        case .updatedAsc:      return .business(.recentUpdate)
        case .nameAsc:         return .business(.sortAZ)
        case .nameDesc:        return .business(.sortZA)
        }
    }
}

// MARK: - UndoStarRecord → RepoCardViewData / Repo

private extension UndoStarRecord {
    /// 最小 Repo（数据库无行时回退）。
    func asRepo() -> Repo {
        Repo(
            id: ghRepoId,
            owner: owner,
            name: name,
            fullName: fullName,
            description: repoDescription,
            language: language,
            starsCount: starsCount,
            forksCount: forksCount,
            watchersCount: watchersCount,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: htmlUrl,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            accessState: .accessible,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    func asCardData(isStarring: Bool = false) -> RepoCardViewData {
        RepoCardViewData(
            ghRepoId: ghRepoId,
            fullName: fullName,
            owner: owner,
            repo: name,
            avatarURL: nil,
            description: repoDescription,
            language: language,
            starsCount: starsCount,
            forksCount: forksCount,
            isArchived: false,
            isFork: false,
            isPrivate: false,
            isStarred: isStarring,
            isInLibrary: false,
            badge: nil,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            footerMetadata: nil,
            readStatus: nil,
            openSSFScore: nil,
            healthBadge: nil
        )
    }
}
