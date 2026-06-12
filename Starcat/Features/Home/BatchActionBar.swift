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
//

import SwiftUI

// MARK: - BatchActionBar

struct BatchActionBar: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppDependencies.self) private var dependencies

    @State private var showTagSheet: Bool = false

    /// W12 PR-3：当前是否要弹批量 unstar 二次确认 sheet。
    /// 仅 > 5 条时弹；≤ 5 条直接 enqueue。
    @State private var showUnstarConfirm: Bool = false

    /// 完成摘要 toast（"成功 X / 跳过 Y / 失败 Z"）。
    /// 用本地 @State 缓存，避免 service.completionSummary 被立即清空时 toast 来不及显示。
    @State private var toastMessage: String?

    var body: some View {
        Group {
            if dependencies.batchStarService.isRunning {
                runningContent
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
                repoIds: viewModel.multiSelectedRepoIDs,
                tagRepository: dependencies.tagRepository,
                repoTagRepository: dependencies.repoTagRepository,
                onCompleted: {
                    showTagSheet = false
                    viewModel.exitMultiSelectMode()
                    Task {
                        await viewModel.refreshSidebar()
                        await viewModel.reloadItems(forceRefresh: true)
                    }
                }
            )
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
        }
        // 监听 batchStarService.completionSummary：写一次后立即 consume，避免下次切换时残留。
        .onChange(of: dependencies.batchStarService.completionSummary) { _, newValue in
            guard let summary = newValue else { return }
            toastMessage = formatSummary(summary)
            dependencies.batchStarService.consumeSummary()

            // 完成（含部分完成）→ 退出多选模式 + 刷新 sidebar / 列表
            viewModel.exitMultiSelectMode()
            Task {
                await viewModel.refreshSidebar()
                await viewModel.reloadItems(forceRefresh: true)
            }
        }
    }

    // MARK: - 默认态：选中数 + 操作按钮

    private var idleContent: some View {
        HStack(spacing: 10) {
            Text(String(format: String(localized: "batch.selectedCountFormat"), viewModel.multiSelectedRepoIDs.count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button {
                showTagSheet = true
            } label: {
                Label("batch.addTags", systemImage: "tag.fill")
            }
            .disabled(viewModel.multiSelectedRepoIDs.isEmpty)
            .help(Text("batch.addTags.help"))

            // W12 PR-3：批量取消 Star。Manage 库内 100% 已 star，无需额外二分判定。
            Button {
                handleBatchUnstarTap()
            } label: {
                Label("batch.unstar", systemImage: "star.slash.fill")
            }
            .disabled(viewModel.multiSelectedRepoIDs.isEmpty)
            .help(Text("batch.unstar.help"))
            .tint(.red)

            // PR-4 followup：退出按钮改为图标-only，文案太长挤掉真正的操作按钮。
            // 文案保留在 accessibilityLabel + help（hover tooltip）。Esc 快捷键不变。
            Button {
                viewModel.exitMultiSelectMode()
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

            Text(String(format: String(localized: "batch.progress.processingFormat"), p.completed, p.total))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if let current = p.currentFullName {
                Text(verbatim: current)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
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

    // MARK: - 派生

    /// 从 viewModel.items 反查选中 repo，并映射到 `BatchStarTarget`（W12 PR-4 统一入参形态）。
    /// items 中找不到的 id 静默丢弃（典型场景：用户先选了再切分类导致 items 替换）。
    private func selectedTargets() -> [BatchStarTarget] {
        let ids = viewModel.multiSelectedRepoIDs
        return viewModel.items
            .filter { ids.contains($0.id) }
            .map { BatchStarTarget.from(repo: $0) }
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
        let prefix = String(localized: String.LocalizationValue(actionKey))
        return String(
            format: String(localized: "batch.summary.format"),
            prefix,
            s.succeeded,
            s.skipped,
            s.failed
        )
    }
}

// MARK: - RemoteBatchActionBar

/// Trending / Weekly / Activity 三个页面共用的批量操作底栏（W12 PR-4）。
///
/// 与 Manage 的 `BatchActionBar` 区别：
/// - 数据源是 `MultiSelectionStore`（owner/name 快照），而非 `HomeViewModel.multiSelectedRepoIDs`；
/// - 列表项**混合 star/unstar 状态**，因此同时暴露「批量 Star」+「批量取消 Star」两个按钮；
/// - 没有「批量打标签」按钮（trending/weekly/activity 的列表项可能不在本地 DB，
///   `batchAddTag` 需要 `repoIds: Set<Int64>` 但本地无 Repo 记录会插入失败）；
/// - 主按钮显著度：先按"未 star 占比"判断主操作——多数未 star → Star 主按钮；
///   多数已 star → Unstar 主按钮；持平时 Star 优先（鼓励发现新项目）。
///
/// 执行中切换到进度态、cancel 按钮、完成 toast 与 Manage 版本完全一致，复用
/// `BatchStarService` 的同一份状态机。
struct RemoteBatchActionBar: View {

    /// 由调用方按页面注入（trending/weekly/activity 各自的实例）。
    let store: MultiSelectionStore

    @Environment(AppDependencies.self) private var dependencies

    /// 二次确认 sheet。> 5 条时强制弹出。
    @State private var pendingAction: BatchStarService.Action?
    @State private var showConfirm: Bool = false

    /// 完成摘要 toast（与 BatchActionBar 一致；本地缓存避免 service summary 被立刻 consume 后 toast 不出现）。
    @State private var toastMessage: String?

    var body: some View {
        Group {
            if dependencies.batchStarService.isRunning {
                runningContent
            } else {
                idleContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .toast(message: $toastMessage, icon: "checkmark.circle.fill", duration: 3.0)
        .sheet(isPresented: $showConfirm) {
            if let action = pendingAction {
                let targets = store.targets
                BatchStarConfirmSheet(
                    action: action,
                    targets: targets,
                    estimatedSkipped: estimatedSkipped(targets: targets, action: action),
                    onConfirm: {
                        showConfirm = false
                        startBatch(action: action, targets: targets)
                    },
                    onCancel: { showConfirm = false }
                )
            }
        }
        .onChange(of: dependencies.batchStarService.completionSummary) { _, newValue in
            guard let summary = newValue else { return }
            toastMessage = formatSummary(summary)
            dependencies.batchStarService.consumeSummary()
            // 完成后退出多选，避免用户在 stale 选中态上再发起一次（registry 已变）。
            store.exit()
        }
    }

    // MARK: - 默认态

    private var idleContent: some View {
        let count = store.count
        let starWeight = starButtonWeight()

        return HStack(spacing: 10) {
            Text(String(format: String(localized: "batch.selectedCountFormat"), count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            // 主按钮按"未 star 占比"决定显著度（plan §3.9）。
            // borderedProminent vs bordered 是 macOS 上最直观的"主/次"差异。
            Button {
                handleTap(action: .star)
            } label: {
                Label("batch.star", systemImage: "star.fill")
            }
            .disabled(count == 0)
            .help(Text("batch.star.help"))
            .modifier(ProminentIf(active: starWeight == .star))

            Button {
                handleTap(action: .unstar)
            } label: {
                Label("batch.unstar", systemImage: "star.slash.fill")
            }
            .disabled(count == 0)
            .help(Text("batch.unstar.help"))
            .tint(.red)
            .modifier(ProminentIf(active: starWeight == .unstar))

            // PR-4 followup：退出按钮改为图标-only，与 Manage 版本对齐。
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

    // MARK: - 进度态

    private var runningContent: some View {
        let p = dependencies.batchStarService.progress ?? .init()
        return HStack(spacing: 10) {
            ProgressView(value: Double(p.completed), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 110)

            Text(String(format: String(localized: "batch.progress.processingFormat"), p.completed, p.total))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if let current = p.currentFullName {
                Text(verbatim: current)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
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

    // MARK: - 业务路由

    private func handleTap(action: BatchStarService.Action) {
        let targets = store.targets
        guard !targets.isEmpty else { return }
        if targets.count > 5 {
            pendingAction = action
            showConfirm = true
        } else {
            startBatch(action: action, targets: targets)
        }
    }

    private func startBatch(action: BatchStarService.Action, targets: [BatchStarTarget]) {
        pendingAction = nil
        dependencies.batchStarService.enqueue(targets: targets, action: action)
    }

    // MARK: - 派生

    private enum StarWeight { case star, unstar, equal }

    /// 决定主按钮：选中项中未 star 占比 > 50% → Star 主按钮；否则 Unstar 主按钮；持平时偏向 Star。
    private func starButtonWeight() -> StarWeight {
        let registry = dependencies.starredRegistry
        let total = store.count
        guard total > 0 else { return .star }
        let unstarred = store.snapshots.values.filter { !registry.contains(ghRepoId: $0.ghRepoId) }.count
        let starred = total - unstarred
        if unstarred > starred { return .star }
        if starred > unstarred { return .unstar }
        return .star
    }

    /// 与 BatchActionBar 同源算法：当前 registry 已是目标态的视为跳过。
    private func estimatedSkipped(targets: [BatchStarTarget], action: BatchStarService.Action) -> Int {
        let registry = dependencies.starredRegistry
        let expected: Bool = (action == .star)
        return targets.filter { registry.contains(ghRepoId: $0.ghRepoId) == expected }.count
    }

    private func formatSummary(_ s: BatchStarService.Summary) -> String {
        let actionKey = s.action == .unstar ? "batch.summary.unstar" : "batch.summary.star"
        let prefix = String(localized: String.LocalizationValue(actionKey))
        return String(
            format: String(localized: "batch.summary.format"),
            prefix,
            s.succeeded,
            s.skipped,
            s.failed
        )
    }
}

/// 按条件套 borderedProminent 的小 modifier；放外部避免 if/else 写两份 Button。
private struct ProminentIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.buttonStyle(.borderedProminent)
        } else {
            content
        }
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
                Text(String(format: String(localized: "batch.applyToReposFormat"), repoIds.count))
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
