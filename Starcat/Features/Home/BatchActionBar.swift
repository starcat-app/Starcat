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
//  - 批量打标签走"多选 tag → 对每个 tag 执行 batchAddTag(repoIds, tagId)"流程。
//    语义仍是追加标签，不做"替换式批量改标签"，避免清掉用户在每个 repo 上已有的其它标签。
//  - W12 PR-3：批量 unstar 按钮仅在 Manage 显示（库内 100% 已 star）；
//    > 5 条强制走 BatchStarConfirmSheet 二次确认；执行中切到进度态 + 取消按钮；
//    完成后通过 ToastOverlay 弹「成功 X / 跳过 Y / 失败 Z」摘要。
//  - 完成后自动退出多选模式
//  - W12 PR-5（2026-06-12）：数据源从 `viewModel.multiSelectedRepoIDs` 切到
//    `manageMultiSelectionStore`（与 trending/weekly/activity 同款），ghRepoId 即 Repo.id
//    （同一 Int64 域）直接喂 batchAddTag；UI 文案：「批量打标签」→「打标签」并加 borderedProminent
//    主显著度。两个组件（BatchActionBar / RemoteBatchActionBar）按业务语义保留独立命名。
//  - GitHub Stars List 视图额外显示分组 membership 菜单；多选仓库可以同时属于多个分组，
//    勾选只补齐目标 membership，取消勾选只移除目标 membership。
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
    /// Manage 多选入口把仓库值快照交给 HomeView；Sheet 与队列仍由主窗口统一承载。
    let onStartSelectedBatchAI: (([Repo]) -> Void)?

    @Environment(AppDependencies.self) private var dependencies
    /// 仅 manage 上下文需要；explore 上下文中为 nil（该环境未注入）。
    @Environment(HomeViewModel.self) private var viewModel

    @State private var showTagSheet: Bool = false
    /// 每次打开打标签 sheet 前自增，强制 SwiftUI 重建 sheet 内容树
    /// → `.task` 重触发 → `loadTags()` 读取最新 DB 数据。
    @State private var tagSheetRefreshID: Int = 0
    @State private var showUnstarConfirm: Bool = false
    @State private var showStarConfirm: Bool = false
    @State private var toastMessage: String?
    @State private var isUpdatingGitHubStarLists: Bool = false
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
            } else if isUpdatingGitHubStarLists {
                updatingGitHubStarListsContent
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
            .id(tagSheetRefreshID)  // 强制重建视图 → .task 重触发 → 读取最新标签
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
            // 多选状态操作较多，视觉上只保留数字以节省水平空间；
            // VoiceOver 仍使用完整的“已选 N 个”文案，避免失去语义。
            Text(count, format: .number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(
                    Text(String(format: String.l10n("batch.selectedCountFormat"), count))
                )

            Spacer()

            // AI 整理与手动打标签只属于本地 Manage 仓库；Explore 数据可能尚未落本地库。
            if context == .manage {
                Button(action: startSelectedBatchAI) {
                    Label("batchAI.generateTags.title", systemImage: "sparkles")
                }
                .labelStyle(.iconOnly)
                .disabled(count == 0)
                .help(Text("batchAI.generateTags.title"))

                Button {
                    tagSheetRefreshID &+= 1
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

            if isGitHubStarListSelection {
                githubStarListMembershipMenu
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
                exitMultiSelect()
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

    private var updatingGitHubStarListsContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text("githubStarLists.aiGrouping.applying")
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

    /// 固定点击时的完整 Repo 快照，后续打开配置 Sheet 或刷新列表都不能改变任务范围。
    private func startSelectedBatchAI() {
        guard let onStartSelectedBatchAI else { return }
        let repositoriesByID = Dictionary(uniqueKeysWithValues: viewModel.items.map { ($0.id, $0) })
        let repositories = store.sortedSnapshots.compactMap { repositoriesByID[$0.ghRepoId] }
        // MultiSelectionStore 会在列表刷新后剔除不可见项；这里仍做最后一道一致性校验，
        // 防止刷新与点击同帧发生时悄悄少处理某个已选仓库。
        guard !repositories.isEmpty, repositories.count == store.count else {
            AppLog.ai.error(
                "[batch-ai] selected repository snapshot mismatch: selected=\(self.store.count, privacy: .public), resolved=\(repositories.count, privacy: .public)"
            )
            return
        }
        onStartSelectedBatchAI(repositories)
    }

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

    private var githubStarListMembershipMenu: some View {
        Menu {
            if viewModel.githubStarLists.isEmpty {
                Text("githubStarLists.context.noGroups")
            } else {
                ForEach(viewModel.githubStarLists) { list in
                    let allSelectedAreMembers = allSelectedReposBelong(to: list.id)
                    Toggle(
                        isOn: githubStarListBatchMembershipBinding(
                            listID: list.id,
                            allSelectedAreMembers: allSelectedAreMembers
                        )
                    ) {
                        GitHubStarListMenuLabel(
                            list: list,
                            repositoryCount: viewModel.githubStarListCounts[list.id] ?? 0
                        )
                    }
                }
            }
        } label: {
            Label(
                "githubStarLists.aiGrouping.action.modifyGroups",
                systemImage: "arrowshape.turn.up.right.fill"
            )
        }
        // 底栏空间有限，只隐藏可见文字；Label 仍为 VoiceOver 保留完整动作名称。
        .labelStyle(.iconOnly)
        .disabled(store.count == 0 || isUpdatingGitHubStarLists)
        .help(Text("githubStarLists.aiGrouping.action.modifyGroups"))
    }

    private func githubStarListBatchMembershipBinding(
        listID: String,
        allSelectedAreMembers: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { allSelectedAreMembers },
            set: { shouldBelong in
                guard shouldBelong != allSelectedAreMembers else { return }
                startGitHubStarListBatchMembershipUpdate(
                    listID: listID,
                    shouldBelong: shouldBelong
                )
            }
        )
    }

    private func startGitHubStarListBatchMembershipUpdate(
        listID: String,
        shouldBelong: Bool
    ) {
        let targets = selectedTargets()
        guard !targets.isEmpty else { return }

        isUpdatingGitHubStarLists = true
        Task {
            let summary = await dependencies.githubStarListSyncService.updateRepos(
                targets,
                membershipIn: listID,
                shouldBelong: shouldBelong
            )
            // 只刷新 membership 投影，不立即 reload 当前列表：在「未分组」中首次勾选后，
            // 仓库虽然已不属于当前查询，但批量快照必须保留，用户才能继续勾选其它分组。
            await viewModel.refreshSidebar()
            isUpdatingGitHubStarLists = false
            toastMessage = String.l10n(
                summary.failed == 0
                    ? "githubStarLists.toast.updated"
                    : "githubStarLists.toast.failed"
            )
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

    private var isGitHubStarListSelection: Bool {
        switch viewModel.selection {
        case .githubStarListUngrouped:
            return true
        case .githubStarList:
            return true
        default:
            return false
        }
    }

    private func allSelectedReposBelong(to listID: String) -> Bool {
        let targets = selectedTargets()
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy {
            viewModel.isRepo($0.ghRepoId, inGitHubStarList: listID)
        }
    }

    private func exitMultiSelect() {
        let shouldReloadGitHubList = isGitHubStarListSelection
        store.exit()
        guard shouldReloadGitHubList else { return }
        Task {
            await viewModel.reloadItems(forceRefresh: true)
        }
    }
}

// MARK: - BatchTagSheet

/// 批量打标签 sheet：选择一组 tag → 追加到所有 selected repos。
///
/// **2026-07-05 优化**：列表顶部新增「新建标签」入口，点击后内联展开创建表单
/// （名称 + 色板），创建后标签自动加入列表并选中，避免用户退出多选 → 建标签 → 重进多选。
private struct BatchTagSheet: View {

    let repoIds: Set<Int64>
    let tagRepository: any TagRepositoryProtocol
    let repoTagRepository: any RepoTagRepositoryProtocol
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm: BatchTagSheetViewModel?
    @State private var query: String = ""
    @State private var selectedTagIds: Set<String> = []

    // 内联新建标签
    @State private var isCreatingTag: Bool = false
    @State private var newTagName: String = ""
    @State private var newTagColorHex: String = TagColorPalette.defaultHex
    @State private var newTagIcon: String? = SFSymbolPreset.defaultIcon

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
                if isCreatingTag {
                    createTagForm
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // ──── 新建标签入口 ────
                        if !isCreatingTag {
                            createTagButton
                            Divider()
                        }

                        // ──── 已有标签列表 ────
                        let tags = filteredTags(vm.tags)
                        if tags.isEmpty && !isCreatingTag {
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
                if !selectedTagIds.isEmpty {
                    Text(String(format: String.l10n("tagPicker.selectedCountFormat"), selectedTagIds.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("general.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.apply") {
                    Task {
                        let ok = await vm?.apply(repoIds: repoIds, tagIds: selectedTagIds) ?? false
                        if ok { onCompleted() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTagIds.isEmpty || (vm?.isApplying ?? false))
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 460)
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

    // MARK: - 新建标签入口

    /// 列表中「➕ 新建标签」按钮行。
    private var createTagButton: some View {
        Button {
            isCreatingTag = true
            newTagName = ""
            newTagColorHex = TagColorPalette.defaultHex
            newTagIcon = SFSymbolPreset.defaultIcon
            vm?.clearError()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("batch.createTag")
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - 内联新建标签表单

    /// 展开的内联创建表单：名称输入 + 12 色板 + 图标 grid + 取消 / 创建按钮。
    ///
    /// 颜色和图标用静态默认值（`TagColorPalette.defaultHex` / `SFSymbolPreset.defaultIcon`），
    /// 用户自行选择覆盖。**不使用 `TagAutoVisual.pick`**：那是 AI 批量生成时的稳定哈希算法，
    /// 手动创建标签不应替用户做随机选择。
    ///
    /// 图标 grid 用 VStack/HStack 手动排版而**不是 `SFSymbolGridPicker`**：
    /// 后者内部是 `LazyVGrid`，嵌套在本表单所在的 `LazyVStack` → `ScrollView` 内会导致
    /// SwiftUI 布局系统无法解析高度 → 死循环 → 应用无响应。
    private var createTagForm: some View {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        let isDuplicate = vm?.isDuplicateName(trimmedName) ?? false

        return InlineTagCreatePanel(
            name: $newTagName,
            colorHex: $newTagColorHex,
            icon: $newTagIcon,
            isDuplicate: isDuplicate,
            isSaving: vm?.isCreating ?? false,
            error: nil,
            onCancel: {
                isCreatingTag = false
                newTagName = ""
            },
            onCreate: {
                guard let tag = await vm?.createTag(
                    name: trimmedName,
                    colorHex: newTagColorHex,
                    icon: newTagIcon
                ) else { return }
                selectedTagIds.insert(tag.id)
                isCreatingTag = false
                newTagName = ""
                newTagIcon = SFSymbolPreset.defaultIcon
                query = ""
            }
        )
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
        let selected = selectedTagIds.contains(tag.id)
        return Button {
            if selected {
                selectedTagIds.remove(tag.id)
            } else {
                selectedTagIds.insert(tag.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
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
    private(set) var isCreating: Bool = false
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

    /// 在列表内联创建新标签并插入 `tags` 顶部。
    ///
    /// - Parameter icon: 用户选择的图标名（nil 表示无图标）。
    /// - Returns: 创建成功返回新 Tag 供 UI 自动选中；失败返回 nil（errorMessage 已写）。
    func createTag(name: String, colorHex: String, icon: String?) async -> Tag? {
        isCreating = true
        defer { isCreating = false }
        do {
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tag = Tag(
                id: UUID().uuidString,
                name: name,
                color: colorHex,
                icon: icon,
                sortOrder: 0,
                isPreset: false,
                parentId: nil,
                createdAt: now,
                updatedAt: now
            )
            try await tagRepository.create(tag)
            tags.insert(tag, at: 0)
            errorMessage = nil
            return tag
        } catch {
            errorMessage = "batch.createTag.failed"
            return nil
        }
    }

    /// 检查标签名（case-insensitive）是否与已有标签冲突。
    ///
    /// 在用户输入时实时调用，用于禁用「创建标签」按钮和显示重名提示。
    func isDuplicateName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return tags.contains { $0.name.lowercased() == name.lowercased() }
    }

    /// 清除错误提示（关闭新建标签表单时重置）。
    func clearError() {
        errorMessage = nil
    }

    /// 把 tagIds 逐个追加到 repoIds 中每一个 repo。
    ///
    /// 这里复用现有 `batchAddTag(repoIds:tagId:)`，而不是新增仓储 API：
    /// 追加标签是幂等写入，循环多次事务边界清晰，并且每个 tagId 都会沿用仓储层
    /// 已有的 repo 标签变更通知，详情页和 Browser Plugin 能同步刷新。
    /// - Returns: 成功 true 让 UI 关闭 sheet；失败 false（errorMessage 已写）。
    @discardableResult
    func apply(repoIds: Set<Int64>, tagIds: Set<String>) async -> Bool {
        guard !tagIds.isEmpty else { return false }
        isApplying = true
        defer { isApplying = false }
        do {
            let repoIdArray = Array(repoIds)
            for tagId in tagIds {
                try await repoTagRepository.batchAddTag(repoIds: repoIdArray, tagId: tagId)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "batch.addTagsFailed"
            return false
        }
    }
}
