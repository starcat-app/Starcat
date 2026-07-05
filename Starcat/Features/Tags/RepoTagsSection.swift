//
//  RepoTagsSection.swift
//  Starcat
//
//  Repo 详情页"自定义标签"段：展示已打标签 chip + 弹出 TagPicker 编辑。
//
//  组件结构（同文件内三层）：
//  - `RepoTagsSection` (UI)：展示 chips + "+" 按钮 → popover
//  - `RepoTagsSectionViewModel` (@MainActor @Observable)：管理 assigned/all
//  - `TagPickerView` (UI)：popover 内容；可搜索标签 + 多选 + 应用
//
//  设计取舍：
//  - 不再拆出 5 个文件，因为这三块强耦合（picker 改完直接 setTags 刷 chips）
//  - 不复用 TagManagementViewModel：那是面向 "tag CRUD"，这里是 "为单 repo 选 tag"，
//    职责不同（这里不能 create/delete tag，只能 assign/unassign）
//
//  数据流：
//  - 切换 repo → onChange(repo.id) → loadFor(repo)
//  - "+" 点击 → 拉 allTags + 当前 assigned → 弹 popover
//  - picker 内勾选 → 本地集合改 → 关闭时 setTags 一次性提交（替换式）
//

import SwiftUI

// MARK: - View

struct RepoTagsSection: View {

    let repo: Repo

    /// 从 AppDependencies 读底层 Repository。
    /// 通过 environment 注入，避免 RepoDetailView 修改 init 签名。
    @Environment(AppDependencies.self) private var dependencies
    /// W4-4 D4：标签变更后刷新 Sidebar 计数。
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var viewModel: RepoTagsSectionViewModel?
    @State private var showPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("repoTags.label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                addButton
            }
            chipsRow
        }
        .task(id: repo.id) {
            if viewModel == nil {
                viewModel = RepoTagsSectionViewModel(
                    tagRepository: dependencies.tagRepository,
                    repoTagRepository: dependencies.repoTagRepository
                )
                // W4-4 D4：标签变更后通知 HomeViewModel 刷新 Sidebar 计数 + 列表
                viewModel?.onTagsChanged = { [weak homeViewModel] in
                    Task {
                        await homeViewModel?.refreshSidebar()
                        await homeViewModel?.reloadItems(forceRefresh: true)
                    }
                }
            }
            await viewModel?.loadFor(repoId: repo.id)
        }
    }

    // MARK: - chips

    @ViewBuilder
    private var chipsRow: some View {
        if let vm = viewModel, !vm.assigned.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(vm.assigned) { tag in
                    TagChip(tag: tag, removable: true) {
                        Task { await vm.removeTag(repoId: repo.id, tagId: tag.id) }
                    }
                }
            }
        } else {
            Text("repoTags.noTags")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - add 按钮 + popover

    /// 点击时**主动刷新**标签数据后再弹出 picker，确保能获取到
    /// 其他地方（侧边栏标签管理 / AI 批量整理）刚创建的新标签。
    private var addButton: some View {
        Button {
            Task {
                await viewModel?.loadFor(repoId: repo.id)
                showPicker = true
            }
        } label: {
            Label("tagPicker.addOrModify", systemImage: "plus.circle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            Group {
                if let vm = viewModel {
                    TagPickerView(
                        allTags: vm.allTags,
                        tagRepository: dependencies.tagRepository,
                        initiallySelected: Set(vm.assigned.map(\.id)),
                        isLoading: vm.isLoading,
                        onCommit: { newSelection in
                            Task {
                                await vm.commit(repoId: repo.id, tagIds: newSelection)
                                showPicker = false
                            }
                        },
                        onCancel: { showPicker = false }
                    )
                }
            }
            .appLocaleEnvironment()
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class RepoTagsSectionViewModel {

    private(set) var assigned: [Tag] = []
    private(set) var allTags: [Tag] = []
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    /// W4-4 D4：标签变更后通知 HomeViewModel 刷新 Sidebar 计数。
    /// 由 RepoDetailView 在创建 VM 时注入，避免直接持有 HomeViewModel（防止循环依赖）。
    var onTagsChanged: (() -> Void)?

    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    init(
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    func loadFor(repoId: Int64) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let assignedTask = repoTagRepository.fetchTags(forRepo: repoId)
            async let allTask = tagRepository.fetchAll()
            assigned = try await assignedTask
            allTags = try await allTask
            errorMessage = nil
        } catch {
            errorMessage = String(format: String.l10n("repoTags.error.loadFailedFormat"), error.localizedDescription)
        }
    }

    /// 单个移除（chip 上的 × 按钮）。
    func removeTag(repoId: Int64, tagId: String) async {
        do {
            try await repoTagRepository.removeTag(repoId: repoId, tagId: tagId)
            await loadFor(repoId: repoId)
            onTagsChanged?()
        } catch {
            errorMessage = String(format: String.l10n("repoTags.error.removeFailedFormat"), error.localizedDescription)
        }
    }

    /// picker 提交：替换式 setTags，事务保证一致性。
    func commit(repoId: Int64, tagIds: Set<String>) async {
        do {
            try await repoTagRepository.setTags(repoId: repoId, tagIds: Array(tagIds))
            await loadFor(repoId: repoId)
            if !tagIds.isEmpty {
                NotificationCenter.default.post(name: .gettingStartedDidOrganizeRepo, object: nil)
            }
            onTagsChanged?()
        } catch {
            errorMessage = String(format: String.l10n("repoTags.error.saveFailedFormat"), error.localizedDescription)
        }
    }
}

// MARK: - TagPickerView

/// popover 内容：可搜索标签 + 多选 + 内联新建标签 + 应用 / 取消。
///
/// **2026-07-05 优化**：列表顶部新增「新建标签」入口，点击后内联展开创建表单
/// （名称 + 颜色 + 图标），创建后自动加入列表并选中，无需离开 popover。
///
/// 注意：本组件维护"本地 selection"。父级提交时传新的集合，
/// 父级用 setTags 替换式更新（不需要本组件去逐个 add/remove）。
struct TagPickerView: View {

    let allTags: [Tag]
    let tagRepository: any TagRepositoryProtocol
    let initiallySelected: Set<String>
    let isLoading: Bool
    let onCommit: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var query: String = ""

    // 内联新建标签
    @State private var isCreatingTag: Bool = false
    @State private var newTagName: String = ""
    @State private var newTagColorHex: String = TagColorPalette.defaultHex
    @State private var newTagIcon: String? = SFSymbolPreset.defaultIcon
    @State private var isSaving: Bool = false
    @State private var newTagError: LocalizedStringKey?

    /// 本地新建的标签（合并 allTags 一起渲染）。
    @State private var localCreatedTags: [Tag] = []

    /// 合并后的完整标签列表（现有 + 本地新建）。
    private var mergedTags: [Tag] { localCreatedTags + allTags }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("tagPicker.placeholder", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // ──── 新建标签入口 ────
                    if !isCreatingTag {
                        pickerCreateTagButton
                        Divider()
                    }

                    // ──── 内联新建标签表单 ────
                    if isCreatingTag {
                        pickerCreateTagForm
                        Divider()
                    }

                    // ──── 已有标签列表 ────
                    let tags = filteredTags(mergedTags)
                    if tags.isEmpty && !isCreatingTag {
                        emptyPickerMessage
                    } else {
                        ForEach(tags) { tag in
                            pickerRow(tag: tag)
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 320)

            Divider()

            HStack {
                if !selected.isEmpty {
                    Text(String(format: String.l10n("tagPicker.selectedCountFormat"), selected.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("general.cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("action.apply") { onCommit(selected) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            selected = initiallySelected
        }
        .overlay {
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - 新建标签入口

    private var pickerCreateTagButton: some View {
        Button {
            isCreatingTag = true
            newTagName = ""
            newTagColorHex = TagColorPalette.defaultHex
            newTagIcon = SFSymbolPreset.defaultIcon
            newTagError = nil
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

    /// 展开的内联创建表单：名称 + 12 色板 + 图标 grid + 取消 / 创建。
    ///
    /// 颜色和图标用静态默认值，用户自行选择覆盖。**不使用 `TagAutoVisual.pick`**：
    /// 那是 AI 批量生成时的稳定哈希，手动创建不应替用户做随机选择。
    ///
    /// 图标 grid 用 VStack/HStack 排版而**不是 `SFSymbolGridPicker`**：
    /// `LazyVGrid` 嵌套在 `LazyVStack` → `ScrollView` 内会导致布局死循环 → 无响应。
    private var pickerCreateTagForm: some View {
        let trimmedName = newTagName.trimmingCharacters(in: .whitespaces)
        let isDuplicate = isDuplicateName(trimmedName)
        let canCreate = !trimmedName.isEmpty && !isDuplicate && !isSaving

        return VStack(alignment: .leading, spacing: 10) {
            // 名称
            HStack(spacing: 8) {
                Text("batch.tagName")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                TextField("batch.tagName.placeholder", text: $newTagName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isDuplicate ? Color.orange : Color.secondary.opacity(0.2))
                    )
            }

            // 重名提示
            if isDuplicate {
                Label {
                    Text(String(format: String.l10n("batch.createTag.duplicate"), trimmedName))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 44)
            }

            // 颜色
            HStack(spacing: 8) {
                Text("batch.tagColor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(TagColorPalette.presets, id: \.hex) { preset in
                        Button {
                            newTagColorHex = preset.hex
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex) ?? .accentColor)
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            newTagColorHex == preset.hex ? Color.primary : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                                .scaleEffect(newTagColorHex == preset.hex ? 1.15 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(LocalizedStringKey(preset.name))
                    }
                }
            }

            // 图标（非 Lazy grid，避免嵌套 LazyVStack 布局死循环）
            HStack(alignment: .top, spacing: 8) {
                Text("batch.tagIcon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                    .padding(.top, 2)
                pickerIconGrid
            }

            // 错误
            if let err = newTagError {
                Label { Text(err) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            // 操作按钮
            HStack {
                Spacer()
                Button("general.cancel") {
                    isCreatingTag = false
                    newTagName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("batch.createTag.confirm") {
                    Task {
                        guard let tag = await createLocalTag(
                            name: trimmedName,
                            colorHex: newTagColorHex,
                            icon: newTagIcon
                        ) else { return }
                        selected.insert(tag.id)
                        isCreatingTag = false
                        newTagName = ""
                        newTagIcon = SFSymbolPreset.defaultIcon
                        query = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
                .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 非 Lazy 的图标 grid，专用于嵌套在 `LazyVStack` 场景。
    ///
    /// `SFSymbolGridPicker` 内部是 `LazyVGrid`，放在 `LazyVStack` 内时两个 lazy 容器
    /// 互相等待对方提供高度 → 布局死循环 → 应用无响应。
    private var pickerIconGrid: some View {
        let icons = SFSymbolPreset.icons
        let columns = 6
        let rows: [[String]] = stride(from: 0, to: icons.count, by: columns).map { start in
            Array(icons[start..<min(start + columns, icons.count)])
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 4) {
                    ForEach(rows[rowIdx], id: \.self) { icon in
                        let isSelected = newTagIcon == icon
                        Button {
                            newTagIcon = isSelected ? nil : icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(icon)
                    }
                }
            }
        }
    }

    /// 创建标签并加入 `localCreatedTags`。
    private func createLocalTag(name: String, colorHex: String, icon: String?) async -> Tag? {
        isSaving = true
        defer { isSaving = false }
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
            localCreatedTags.insert(tag, at: 0)
            newTagError = nil
            return tag
        } catch {
            newTagError = "batch.createTag.failed"
            return nil
        }
    }

    /// case-insensitive 检查是否与已有标签重名。
    private func isDuplicateName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return mergedTags.contains { $0.name.lowercased() == name.lowercased() }
    }

    private var emptyPickerMessage: some View {
        let totalEmpty = mergedTags.isEmpty && !isCreatingTag
        let message: LocalizedStringKey = totalEmpty ? "tagPicker.noTags" : "tagPicker.noMatch"
        return Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 大小写不敏感前缀+包含匹配。
    private func filteredTags(_ tags: [Tag]) -> [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(q) }
    }

    private func pickerRow(tag: Tag) -> some View {
        let isOn = selected.contains(tag.id)
        return Button {
            if isOn { selected.remove(tag.id) } else { selected.insert(tag.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Circle()
                    .fill(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
                    .frame(width: 8, height: 8)
                if let icon = tag.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(verbatim: tag.name)
                    .lineLimit(1)
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

// MARK: - TagChip

/// 标签胶囊：颜色点 + 图标 + name + 可选 × 按钮。
struct TagChip: View {

    let tag: Tag
    /// true 时右侧显示 × 按钮，点击触发 onRemove。
    let removable: Bool
    let onRemove: (() -> Void)?

    init(tag: Tag, removable: Bool = false, onRemove: (() -> Void)? = nil) {
        self.tag = tag
        self.removable = removable
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(swatchColor)
                .frame(width: 6, height: 6)
            if let icon = tag.icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            Text(verbatim: tag.name)
                .font(.caption)
                .lineLimit(1)
            if removable, let onRemove {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(swatchColor.opacity(0.15), in: Capsule())
        .foregroundStyle(swatchColor)
    }

    private var swatchColor: Color {
        Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor
    }
}

// MARK: - FlowLayout

/// 与 RepoDetailView 同款 Flow 布局；
/// 单独放在这里避免 fileprivate 跨文件可见性问题。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
