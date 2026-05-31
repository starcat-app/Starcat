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

    @State private var viewModel: RepoTagsSectionViewModel?
    @State private var showPicker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
            Text("尚未打标签")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - add 按钮 + popover

    private var addButton: some View {
        Button {
            showPicker = true
        } label: {
            Label("添加 / 修改", systemImage: "plus.circle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            if let vm = viewModel {
                TagPickerView(
                    allTags: vm.allTags,
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
            errorMessage = "加载标签失败：\(error.localizedDescription)"
        }
    }

    /// 单个移除（chip 上的 × 按钮）。
    func removeTag(repoId: Int64, tagId: String) async {
        do {
            try await repoTagRepository.removeTag(repoId: repoId, tagId: tagId)
            await loadFor(repoId: repoId)
        } catch {
            errorMessage = "移除失败：\(error.localizedDescription)"
        }
    }

    /// picker 提交：替换式 setTags，事务保证一致性。
    func commit(repoId: Int64, tagIds: Set<String>) async {
        do {
            try await repoTagRepository.setTags(repoId: repoId, tagIds: Array(tagIds))
            await loadFor(repoId: repoId)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - TagPickerView

/// popover 内容：可搜索标签 + 多选 + 应用 / 取消。
///
/// 注意：本组件维护"本地 selection"。父级提交时传新的集合，
/// 父级用 setTags 替换式更新（不需要本组件去逐个 add/remove）。
struct TagPickerView: View {

    let allTags: [Tag]
    let initiallySelected: Set<String>
    let isLoading: Bool
    let onCommit: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索标签", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredTags.isEmpty {
                        Text(allTags.isEmpty ? "还没有任何标签，先去标签管理创建。" : "未找到匹配标签")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(filteredTags) { tag in
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
                    Text("已选 \(selected.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { onCommit(selected) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
        .onAppear {
            selected = initiallySelected
        }
        .overlay {
            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// 大小写不敏感前缀+包含匹配。
    private var filteredTags: [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allTags }
        return allTags.filter { $0.name.lowercased().contains(q) }
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
                Text(tag.name)
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
            Text(tag.name)
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
