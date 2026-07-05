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
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// 即将被清理的记录数
    private(set) var expiringCount: Int = 0

    var sortOption: UndoStarSortOption = .unstarredAtDesc {
        didSet { Task { await reload() } }
    }

    private let repository: any UndoStarHistoryRepositoryProtocol
    private let settings: AppSettings

    init(repository: any UndoStarHistoryRepositoryProtocol, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
    }

    func reload() async {
        isLoading = true
        loadError = nil
        do {
            records = try await repository.fetchAll(sort: sortOption)
            await refreshExpiringCount()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
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
    @Environment(AppDependencies.self) private var dependencies

    @State private var viewModel: UndoStarViewModel
    @State private var toastMessage: String?

    /// 选中行 → 通知上层展示详情页
    @Binding var selectedRecord: UndoStarRecord?
    var onSelectRepo: ((Repo?) -> Void)?

    /// 正在执行 star 操作的 repo ID（用于即时 UI 反馈）
    @State private var starringRepoIDs: Set<Int64> = []
    /// 清空全部确认弹窗
    @State private var showClearAllConfirm = false

    init(
        repository: any UndoStarHistoryRepositoryProtocol,
        settings: AppSettings,
        selectedRecord: Binding<UndoStarRecord?>,
        onSelectRepo: ((Repo?) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: UndoStarViewModel(repository: repository, settings: settings))
        _selectedRecord = selectedRecord
        self.onSelectRepo = onSelectRepo
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
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
            await viewModel.load()
            await viewModel.refreshExpiringCount()
            dependencies.activityCategoryCountService.applyUndoStarCount(viewModel.records.count)
        }
        .onChange(of: viewModel.records.count) { _, newCount in
            dependencies.activityCategoryCountService.applyUndoStarCount(newCount)
        }
        .onReceive(NotificationCenter.default.publisher(for: .undoStarHistoryDidChange)) { notification in
            Task { await viewModel.refreshExpiringCount() }
            let starredID = notification.userInfo?["starredGhRepoId"] as? Int64
            let previousSelectedID = selectedRecord?.ghRepoId

            withAnimation(.easeOut(duration: 0.3)) {
                if let id = starredID {
                    viewModel.removeRecords(ghRepoIds: [id])
                }
            }

            // 如果当前详情页展示的 repo 已被 star，关闭详情或切到第一条
            if let previousSelectedID, starredID == previousSelectedID {
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
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // 排序菜单（与星标模块同款组件）
            UnifiedSortMenu(
                selection: $viewModel.sortOption,
                options: UndoStarSortOption.allCases,
                displayName: { $0.displayName },
                systemImage: { $0.systemImage }
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            RepoSkeletonListView(rowCount: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.loadError, viewModel.records.isEmpty {
            emptyState(systemImage: "exclamationmark.triangle", text: error)
        } else if viewModel.records.isEmpty {
            emptyState(systemImage: "clock.arrow.circlepath", titleKey: "activity.undoStar.empty")
        } else {
            recordList
        }
    }

    private var recordList: some View {
        let store = dependencies.undoStarMultiSelectionStore
        return List {
            ForEach(viewModel.records) { record in
                let isStarring = starringRepoIDs.contains(record.ghRepoId)
                Button {
                    if store.isActive {
                        store.toggle(SelectionSnapshot(
                            ghRepoId: record.ghRepoId,
                            owner: record.owner,
                            name: record.name
                        ))
                    } else {
                        selectedRecord = record
                        // 异步取完整 Repo 数据给详情页
                        Task {
                            if let repo = try? await dependencies.undoStarHistoryRepository.fetchRepo(ghRepoId: record.ghRepoId) {
                                onSelectRepo?(repo)
                            } else {
                                onSelectRepo?(record.asRepo())
                            }
                        }
                    }
                } label: {
                    UnifiedRepoRow(
                        card: record.asCardData(isStarring: isStarring),
                        isSelected: store.isActive
                            ? store.contains(ghRepoId: record.ghRepoId)
                            : (selectedRecord?.ghRepoId == record.ghRepoId),
                        showStarredCheckmark: false
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // 单个 Star 操作（非多选模式下的行内 Star 按钮需要额外处理，
                // 这里先走详情页 Star，后续可加行尾 Star 按钮）
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .animation(.easeOut(duration: 0.3), value: viewModel.records.map(\.id))
        .background {
            let store = dependencies.undoStarMultiSelectionStore
            Button {
                let snapshots = viewModel.records.map {
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

    var systemImage: String {
        switch self {
        case .unstarredAtDesc: return "clock.arrow.circlepath"
        case .starsDesc:       return "star.fill"
        case .starsAsc:        return "star"
        case .updatedDesc:     return "arrow.up"
        case .updatedAsc:      return "arrow.down"
        case .nameAsc:         return "textformat.abc"
        case .nameDesc:        return "textformat.abc"
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
            readStatus: nil,
            openSSFScore: nil,
            healthBadge: nil
        )
    }
}
