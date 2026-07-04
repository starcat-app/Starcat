//
//  BatchActionBar.swift
//  Starcat
//
//  多选模式底部浮动操作栏（W4 A5 / W12 PR-3 扩展）。
//
//  组件结构（同文件三层）：
//  - `BatchActionBar`      底栏 UI：选中数 + 操作按钮 + 退出多选；执行中切到进度态
//  - `BatchTagSheet`       批量打标签 sheet：选标签 → 触发 batchAddTag
//  - `BatchTagSheetViewModel` 内部状态：tags / selection / 提交状态
//
//  设计约束：
//  - 用 .safeAreaInset(.bottom) 嵌入 RepoListView 底部，背景做 Material 模糊
//  - 批量打标签走"先选 1 个 tag → batchAddTag(repoIds, tagId)"流程
//    （MVP 简化：一次只能给所选 repos 加一个 tag，不做"替换式批量改标签"
//     ——那语义太重，会清掉用户在每个 repo 上已有的其它标签）
//  - W12 PR-3：批量 unstar 按钮仅在 Manage 显示（库内 100% 已 star）；
//    > 5 条强制走 BatchStarConfirmSheet 二次确认；执行中切到进度态 + 取消按钮；
//    完成后通过 ToastOverlay 弹「成功 X / 跳过 Y / 失败 Z」摘要。
//  - 完成后自动退出多选模式
//  - W12 PR-5（2026-06-12）：数据源从 `viewModel.multiSelectedRepoIDs` 切到
//    `manageMultiSelectionStore`（与 trending/weekly/activity 同款），ghRepoId 即 Repo.id
//    （同一 Int64 域）直接喂 batchAddTag；UI 文案：「批量打标签」→「打标签」并加 borderedProminent
//    主显著度。两个组件（BatchActionBar / RemoteBatchActionBar）按业务语义保留独立命名。
//  - GitHub Stars List 视图额外显示「移动到」入口；真正的 add / move 语义由
//    GitHubStarListSyncService 根据当前来源分组判断，UI 不拆两个按钮。
//

import SwiftUI

/// 多选操作上下文（2026-07-05：星标/探索统一组件）。
enum BatchActionContext {
    case manage   // 星标：打标签 + 知识库 + unstar（按分类切换逻辑）+ GitHub Star Lists 移动
    case explore  // 探索：知识库 + star + unstar（统一 4 操作）
}

// MARK: - BatchActionBar

/// 统一的批量操作底栏，星标 / 探索模块共用。
struct BatchActionBar: View {

    let context: BatchActionContext
    let store: MultiSelectionStore

    @Environment(AppDependencies.self) private var dependencies
    /// 仅 manage 上下文需要；explore 上下文中为 nil（该环境未注入）。
    @Environment(HomeViewModel.self) private var viewModel

    @State private var showTagSheet: Bool = false
    @State private var showUnstarConfirm: Bool = false
    @State private var showStarConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var isMovingGitHubStarLists: Bool = false
    @State private var isAddingToLibrary: Bool = false
    @State private var isRemovingFromLibrary: Bool = false

    var body: some View {
        Group {
            if dependencies.batchStarService.isRunning {
                runningContent
            } else if isAddingToLibrary {
                addingToLibraryContent
            } else if isRemovingFromLibrary {
                removingFromLibraryContent
            } else if isMovingGitHubStarLists {
                movingGitHubStarListsContent
            } else {
                idleContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .toast(message: $toastMessage, icon: "checkmark.circle.fill", duration: 3.0)
        .sheet(isPresented: $showTagSheet) {
            BatchTagSheet(
                // W12 PR-5：snapshots.keys 即 ghRepoId == Repo.id 同一 Int64 域，直接喂。
                repoIds: Set(store.snapshots.keys),
                tagRepository: dependencies.tagRepository,
                repoTagRepository: dependencies.repoTagRepository,
                onCompleted: {
                    showTagSheet = false
                    store.exit()
                    if context == .manage {
                        Task {
                            await viewModel.refreshSidebar()
                            await viewModel.reloadItems(forceRefresh: true)
                        }
                    }
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(isPresented: $showUnstarConfirm) {
            let targets = selectedTargets()
            BatchStarConfirmSheet(
                action: .unstar,
                targets: targets,
                estimatedSkipped: estimatedSkipped(targets: targets, action: .unstar),
                onConfirm: {
                    showUnstarConfirm = false
                    startBatchUnstar(targets: targets)
                },
                onCancel: { showUnstarConfirm = false }
            )
            .appLocaleEnvironment()
        }
        .sheet(isPresented: $showStarConfirm) {
            let targets = context == .explore ? selectedTargets() : starEligibleTargets()
            BatchStarConfirmSheet(
                action: .star,
                targets: targets,
                estimatedSkipped: estimatedSkipped(targets: targets, action: .star),
                onConfirm: {
                    showStarConfirm = false
                    if context == .explore {
                        startBatch(action: .star, targets: targets)
                    } else {
                        startBatchStar(targets: targets)
                    }
                },
                onCancel: { showStarConfirm = false }
            )
            .appLocaleEnvironment()
        }
        // 监听 batchStarService.completionSummary：写一次后立即 consume，避免下次切换时残留。
        .onChange(of: dependencies.batchStarService.completionSummary) { _, newValue in
            guard let summary = newValue else { return }
            toastMessage = formatSummary(summary)
            dependencies.batchStarService.consumeSummary()

            // 完成（含部分完成）→ 退出多选模式 + 刷新 sidebar / 列表
            store.exit()
            if context == .manage {
                Task {
                    await viewModel.refreshSidebar()
                    await viewModel.reloadItems(forceRefresh: true)
                }
            }
        }
    }

    // MARK: - 默认态：选中数 + 操作按钮

    private var idleContent: some View {
        let count = store.count
        return HStack(spacing: 10) {
            Text(String(format: String.l10n("batch.selectedCountFormat"), count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            // 打标签：仅 manage 上下文
            if context == .manage {
                Button {
                    showTagSheet = true
                } label: {
                    Image(systemName: "tag.fill")
                        .accessibilityLabel(Text("batch.addTags"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
                .help(Text("batch.addTags.help"))
            }

            // 知识库操作
            if context == .manage && viewModel.selection == .library {
                // 知识库分组：仅「移出知识库」
                Button {
                    startBatchRemoveFromLibrary()
                } label: {
                    Image(systemName: "heart.slash.fill")
                        .accessibilityLabel(Text("batch.library.remove"))
                }
                .disabled(count == 0)
                .help(Text("batch.library.remove.help"))
                .tint(.red)
            } else {
                // 加入 + 移出，各自智能过滤
                Button {
                    startBatchAddToLibrary()
                } label: {
                    Image(systemName: "heart.fill")
                        .accessibilityLabel(Text("batch.library.add"))
                }
                .disabled(count == 0)
                .help(Text("batch.library.add.help"))
                .tint(.red)

                Button {
                    startBatchRemoveFromLibrary()
                } label: {
                    Image(systemName: "heart.slash.fill")
                        .accessibilityLabel(Text("batch.library.remove"))
                }
                .disabled(count == 0)
                .help(Text("batch.library.remove.help"))
                .tint(.red)
            }

            if githubStarListBatchSource != nil {
                githubStarListMoveMenu
            }

            // Star / Unstar
            if context == .explore || viewModel.selection == .library {
                // 探索模块 / 知识库分组：star + unstar 双按钮（列表项目混合 star 状态）
                Button {
                    if viewModel.selection == .library {
                        handleBatchStarTapForLibrary()
                    } else {
                        handleTap(action: .star)
                    }
                } label: {
                    Image(systemName: "star.fill")
                        .accessibilityLabel(Text("batch.star"))
                }
                .disabled(count == 0)
                .help(Text("batch.star.help"))
                .tint(.yellow)

                Button {
                    if viewModel.selection == .library {
                        handleBatchUnstarTapForLibrary()
                    } else {
                        handleTap(action: .unstar)
                    }
                } label: {
                    Image(systemName: "star.slash.fill")
                        .accessibilityLabel(Text("batch.unstar"))
                }
                .disabled(count == 0)
                .help(Text("batch.unstar.help"))
                .tint(.red)
            } else {
                // Manage 非知识库分组：仅 unstar（全部已 star）
                Button {
                    handleBatchUnstarTap()
                } label: {
                    Image(systemName: "star.slash.fill")
                        .accessibilityLabel(Text("batch.unstar"))
                }
                .disabled(count == 0)
                .help(Text("batch.unstar.help"))
                .tint(.red)
            }

            // PR-4 followup：退出按钮图标-only，accessibility + help tooltip 保留。Esc 快捷键不变。
            Button {
                store.exit()
            } label: {
                Image(systemName: "xmark.circle")
                    .accessibilityLabel(Text("batch.exitMultiSelect"))
            }
            .help(Text("batch.exitMultiSelect.help"))
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 进度态：处理中 X/N + 当前 repo + 取消

    private var runningContent: some View {
        let p = dependencies.batchStarService.progress ?? .init()
        return HStack(spacing: 10) {
            ProgressView(value: Double(p.completed), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 110)

            Text(String(format: String.l10n("batch.progress.processingFormat"), p.completed, p.total))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if let current = p.currentFullName {
                Text(verbatim: current)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(role: .destructive) {
                dependencies.batchStarService.cancel()
            } label: {
                Label("batch.progress.cancel", systemImage: "stop.circle")
            }
        }
    }

    private var movingGitHubStarListsContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("batch.githubStarLists.move.processing")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var addingToLibraryContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("batch.library.add.processing")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var removingFromLibraryContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("batch.library.remove.processing")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - 业务路由

    /// 点击「批量取消 Star」：> 5 条走确认 sheet，否则直接 enqueue。
    private func handleBatchUnstarTap() {
        let targets = selectedTargets()
        guard !targets.isEmpty else { return }
        if targets.count > 5 {
            showUnstarConfirm = true
        } else {
            startBatchUnstar(targets: targets)
        }
    }

    private func startBatchUnstar(targets: [BatchStarTarget]) {
        dependencies.batchStarService.enqueue(targets: targets, action: .unstar)
    }

    private func startBatchStar(targets: [BatchStarTarget]) {
        dependencies.batchStarService.enqueue(targets: targets, action: .star)
    }

    // MARK: - 探索模块：star / unstar（通用路由）

    private func handleTap(action: BatchStarService.Action) {
        let targets = selectedTargets()
        guard !targets.isEmpty else { return }
        if targets.count > 5 {
            if action == .star { showStarConfirm = true }
            else { showUnstarConfirm = true }
        } else {
            startBatch(action: action, targets: targets)
        }
    }

    private func startBatch(action: BatchStarService.Action, targets: [BatchStarTarget]) {
        dependencies.batchStarService.enqueue(targets: targets, action: action)
    }

    // MARK: - 知识库分组：star / unstar（带 star 状态预过滤）

    /// 知识库分组「Star」：仅处理未 star 的 repo，已 star 的自动跳过。
    private func handleBatchStarTapForLibrary() {
        let targets = starEligibleTargets()
        guard !targets.isEmpty else { return }
        if targets.count > 5 {
            showStarConfirm = true
        } else {
            startBatchStar(targets: targets)
        }
    }

    /// 知识库分组「Unstar」：仅处理已 star 的 repo，未 star 的自动跳过。
    private func handleBatchUnstarTapForLibrary() {
        let targets = unstarEligibleTargets()
        guard !targets.isEmpty else { return }
        if targets.count > 5 {
            showUnstarConfirm = true
        } else {
            startBatchUnstar(targets: targets)
        }
    }

    /// 选中项中尚未 star 的子集（知识库 star 按钮用）。
    private func starEligibleTargets() -> [BatchStarTarget] {
        let registry = dependencies.starredRegistry
        return selectedTargets().filter { !registry.contains(ghRepoId: $0.ghRepoId) }
    }

    /// 选中项中已 star 的子集（知识库 unstar 按钮用）。
    private func unstarEligibleTargets() -> [BatchStarTarget] {
        let registry = dependencies.starredRegistry
        return selectedTargets().filter { registry.contains(ghRepoId: $0.ghRepoId) }
    }

    private func startBatchAddToLibrary() {
        let snapshots = store.snapshots
        guard !snapshots.isEmpty else { return }

        isAddingToLibrary = true
        Task {
            var added = 0
            var skipped = 0
            var failed = 0

            for (repoID, snapshot) in snapshots {
                do {
                    // 探索模块的 repo 可能不在本地 DB，先补占位行以通过 FK 约束
                    if context == .explore {
                        try await dependencies.repoNoteRepository.ensureRepoRowExists(
                            repoId: repoID, owner: snapshot.owner, name: snapshot.name
                        )
                    }
                    let current = try await dependencies.repoNoteRepository.fetchLibraryState(repoId: repoID)
                    guard current != .inLibrary else {
                        skipped += 1
                        continue
                    }
                    try await dependencies.repoNoteRepository.updateLibraryState(repoId: repoID, state: .inLibrary)
                    added += 1
                } catch {
                    failed += 1
                }
            }

            isAddingToLibrary = false
            toastMessage = String(
                format: String.l10n("batch.library.add.summaryFormat"),
                added,
                skipped,
                failed
            )
            store.exit()
            if context == .manage {
                await viewModel.refreshSidebar()
                await viewModel.reloadItems(forceRefresh: true)
            }
        }
    }

    /// 批量移出知识库（仅在「知识库」分组下可用）。
    private func startBatchRemoveFromLibrary() {
        let repoIDs = Array(store.snapshots.keys)
        guard !repoIDs.isEmpty else { return }

        isRemovingFromLibrary = true
        Task {
            var removed = 0
            var skipped = 0
            var failed = 0

            for repoID in repoIDs {
                do {
                    let current = try await dependencies.repoNoteRepository.fetchLibraryState(repoId: repoID)
                    guard current == .inLibrary else {
                        skipped += 1
                        continue
                    }
                    try await dependencies.repoNoteRepository.updateLibraryState(repoId: repoID, state: .outsideLibrary)
                    removed += 1
                } catch {
                    failed += 1
                }
            }

            isRemovingFromLibrary = false
            toastMessage = String(
                format: String.l10n("batch.library.remove.summaryFormat"),
                removed,
                skipped,
                failed
            )
            store.exit()
            if context == .manage {
                await viewModel.refreshSidebar()
                await viewModel.reloadItems(forceRefresh: true)
            }
        }
    }

    private var githubStarListMoveMenu: some View {
        Menu {
            let targets = githubStarListMoveTargets
            if targets.isEmpty {
                Text("batch.githubStarLists.noMoveTargets")
            } else {
                ForEach(targets) { list in
                    Button {
                        startGitHubStarListBatchMove(to: list.id)
                    } label: {
                        Text(verbatim: list.name)
                    }
                }
            }
        } label: {
            Label("batch.githubStarLists.move", systemImage: "arrowshape.turn.up.right.fill")
        }
        .disabled(store.count == 0 || isMovingGitHubStarLists)
        .help(Text("batch.githubStarLists.move.help"))
    }

    private func startGitHubStarListBatchMove(to targetListID: String) {
        guard let source = githubStarListBatchSource else { return }
        let targets = selectedTargets()
        guard !targets.isEmpty else { return }

        isMovingGitHubStarLists = true
        Task {
            let summary = await dependencies.githubStarListSyncService.moveRepos(
                targets,
                from: source,
                to: targetListID
            )
            isMovingGitHubStarLists = false
            toastMessage = formatGitHubStarListMoveSummary(summary)
            store.exit()
            await viewModel.refreshSidebar()
            await viewModel.reloadItems(forceRefresh: true)
        }
    }

    // MARK: - 派生

    /// 选中项对应的 `BatchStarTarget` 数组。
    ///
    /// W12 PR-5：直接读 `store.targets`，store 内的 SelectionSnapshot.toTarget() 已经做了字段映射
    /// （ghRepoId / owner / name）。不需要再回 viewModel.items 反查（snapshot 在用户选中瞬间已记录
    /// 必备字段，即便后续 reloadItems 把 items 换了，snapshot 仍可独立完成批量任务）。
    private func selectedTargets() -> [BatchStarTarget] {
        store.targets
    }

    /// 预估跳过条数：当前 registry 状态已是目标态的条数。
    /// 仅做 sheet 显示，BatchStarService 执行时还会按当时 registry 实际复核。
    private func estimatedSkipped(targets: [BatchStarTarget], action: BatchStarService.Action) -> Int {
        let registry = dependencies.starredRegistry
        let expected: Bool = (action == .star) // 已 star 对 star 跳过；未 star 对 unstar 跳过
        return targets.filter { registry.contains(ghRepoId: $0.ghRepoId) == expected }.count
    }

    /// 把 Summary 格式化为 toast 文案。
    /// 使用 plain String 而非 LocalizedStringKey：toast 组件需要 String 类型。
    private func formatSummary(_ s: BatchStarService.Summary) -> String {
        let actionKey = s.action == .unstar ? "batch.summary.unstar" : "batch.summary.star"
        let prefix = String.l10n(actionKey)
        return String(
            format: String.l10n("batch.summary.format"),
            prefix,
            s.succeeded,
            s.skipped,
            s.failed
        )
    }

    private var githubStarListBatchSource: GitHubStarListBatchSource? {
        switch viewModel.selection {
        case .githubStarListUngrouped:
            return .ungrouped
        case .githubStarList(let listID):
            return .list(listID)
        default:
            return nil
        }
    }

    private var githubStarListMoveTargets: [GitHubStarList] {
        switch githubStarListBatchSource {
        case .ungrouped:
            return viewModel.githubStarLists
        case .list(let currentListID):
            return viewModel.githubStarLists.filter { $0.id != currentListID }
        case nil:
            return []
        }
    }

    private func formatGitHubStarListMoveSummary(_ summary: GitHubStarListBatchMoveSummary) -> String {
        String(
            format: String.l10n("batch.githubStarLists.move.summaryFormat"),
            summary.succeeded,
            summary.failed
        )
    }
}

// MARK: - BatchTagSheet

/// 批量打标签 sheet：选一个 tag → 应用到所有 selected repos。
private struct BatchTagSheet: View {

    let repoIds: Set<Int64>
    let tagRepository: any TagRepositoryProtocol
    let repoTagRepository: any RepoTagRepositoryProtocol
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm: BatchTagSheetViewModel?
    @State private var query: String = ""
    @State private var selectedTagId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("batch.addTags")
                    .font(.headline)
                Spacer()
                Text(String(format: String.l10n("batch.applyToReposFormat"), repoIds.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("batch.searchTags", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            if let vm {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let tags = filteredTags(vm.tags)
                        if tags.isEmpty {
                            emptyTagsMessage(isInitialEmpty: vm.tags.isEmpty)
                        } else {
                            ForEach(tags) { tag in
                                row(tag: tag)
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
            }

            if let err = vm?.errorMessage {
                Label {
                    Text(err)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("general.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.apply") {
                    Task {
                        guard let tid = selectedTagId else { return }
                        let ok = await vm?.apply(repoIds: repoIds, tagId: tid) ?? false
                        if ok { onCompleted() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTagId == nil || (vm?.isApplying ?? false))
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            if vm == nil {
                vm = BatchTagSheetViewModel(
                    tagRepository: tagRepository,
                    repoTagRepository: repoTagRepository
                )
            }
            await vm?.loadTags()
        }
    }

    private func filteredTags(_ tags: [Tag]) -> [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(q) }
    }

    private func emptyTagsMessage(isInitialEmpty: Bool) -> some View {
        let message: LocalizedStringKey = isInitialEmpty ? "batch.noTags" : "batch.noMatch"
        return Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(tag: Tag) -> some View {
        let selected = (selectedTagId == tag.id)
        return Button {
            selectedTagId = selected ? nil : tag.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Circle()
                    .fill(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
                    .frame(width: 8, height: 8)
                if let icon = tag.icon {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(verbatim: tag.name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - BatchTagSheetViewModel

@MainActor
@Observable
final class BatchTagSheetViewModel {

    private(set) var tags: [Tag] = []
    private(set) var isApplying: Bool = false
    private(set) var errorMessage: LocalizedStringKey?

    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    init(
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    func loadTags() async {
        do {
            tags = try await tagRepository.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = "batch.loadTagsFailed"
        }
    }

    /// 把 tagId 加到 repoIds 中每一个 repo。
    /// - Returns: 成功 true 让 UI 关闭 sheet；失败 false（errorMessage 已写）。
    @discardableResult
    func apply(repoIds: Set<Int64>, tagId: String) async -> Bool {
        isApplying = true
        defer { isApplying = false }
        do {
            try await repoTagRepository.batchAddTag(repoIds: Array(repoIds), tagId: tagId)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "batch.addTagsFailed"
            return false
        }
    }
}
