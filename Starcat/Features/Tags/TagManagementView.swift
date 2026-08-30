//
//  TagManagementView.swift
//  Starcat
//
//  标签管理 sheet 主入口（左：List；右：Editor）。
//
//  布局：
//  +------------------------------------------------------------+
//  |  TitleBar："标签管理" + 关闭                                |
//  +-----------------------------+------------------------------+
//  |  Tag List (多选, 左 280pt)  |  TagEditorView (右剩余)       |
//  |  ● tag-A         12         |  [name field]                 |
//  |  ● tag-B          7         |  [color swatch + picker]      |
//  |  ● tag-C          0         |  [icon grid]                  |
//  |                             |  [删除]            [保存]      |
//  +-----------------------------+------------------------------+
//  |  Footer：+ 新建 / 合并 / 删除 / 错误 banner                 |
//  +------------------------------------------------------------+
//
//  关键交互：
//  - 左 List 默认单选；按住 Cmd 多选 → 启用"合并"按钮（选 ≥2 个）
//  - 右编辑面板单选时显示；多选 / 未选时显示空态
//  - 新建：弹小 sheet 输入名字 + 默认配色 → 自动选中
//  - 合并：选 ≥2 → 弹 sheet 让用户选保留哪个 target（默认列表顺序第一个）
//  - 删除：单选 / 多选都支持，确认 alert 提示"标签关联的 repo 不会被删除"
//
//  设计约束：
//  - 用 .sheet 呈现，macOS 上会成为独立 modal 窗口
//  - 不挂 NavigationStack：标签管理是扁平 CRUD，不需要导航
//

import SwiftUI

struct TagManagementView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var dependencies

    /// 由 HomeView 注入；@Bindable 让 selection 双向绑定到 List。
    @State var viewModel: TagManagementViewModel
    /// 开始使用清单会复用 Tags 管理入口，并要求打开后直接进入新建标签流程。
    var opensNewTagSheetOnAppear: Bool = false

    // MARK: - 子 UI 状态

    /// 新建标签 sheet 显示状态。
    @State private var showNewSheet: Bool = false
    /// 防止 SwiftUI 重新触发 onAppear 时重复弹出新建 sheet。
    @State private var didApplyOpenNewTagIntent: Bool = false
    /// 删除确认 alert 显示状态。
    @State private var showDeleteAlert: Bool = false
    /// 合并目标选择 sheet 显示状态。
    @State private var showMergeSheet: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HSplitView {
                tagList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                TagEditorView(
                    tag: viewModel.singleSelected,
                    selectionCount: viewModel.selection.count,
                    onSave: handleSave,
                    onRequestDelete: { showDeleteAlert = true }
                )
                .frame(minWidth: 360, idealWidth: 460)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 460, idealHeight: 540)
        .task {
            await viewModel.loadAll()
        }
        .onAppear {
            guard opensNewTagSheetOnAppear, !didApplyOpenNewTagIntent else { return }
            didApplyOpenNewTagIntent = true
            Task { @MainActor in
                // 首次打开 TagManagementView 时，外层 sheet 还在挂载；立刻再呈现内层
                // NewTagSheet 会被 SwiftUI 忽略。延后一轮 run loop，等父 sheet 稳定后再弹。
                try? await Task.sleep(for: .milliseconds(120))
                guard opensNewTagSheetOnAppear else { return }
                showNewSheet = true
            }
        }
        .sheet(isPresented: $showNewSheet) {
            NewTagSheet { name, color, icon in
                let ok = await viewModel.create(name: name, color: color, icon: icon)
                if ok { showNewSheet = false }
            }
            .appLocaleEnvironment()
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheetContent
        }
        .sheet(item: tagPaywallBinding) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .alert("tagManagement.deleteTitle", isPresented: $showDeleteAlert) {
            Button("action.delete", role: .destructive) {
                Task { await viewModel.delete(ids: viewModel.selection) }
            }
            Button("general.cancel", role: .cancel) {}
        } message: {
            let n = viewModel.selection.count
            Text(String(format: String.l10n("tagManagement.deleteMessageFormat"), n))
        }
    }

    /// 合并 sheet：候选按主列表顺序；默认 target = 第一个。
    @ViewBuilder
    private var mergeSheetContent: some View {
        let candidates = viewModel.tags.filter { viewModel.selection.contains($0.id) }
        if let initialTargetId = candidates.first?.id {
            MergeTagsSheet(
                candidates: candidates,
                counts: viewModel.counts,
                initialTargetId: initialTargetId,
                onConfirm: { targetId in
                    await viewModel.merge(sources: viewModel.selection, into: targetId)
                    showMergeSheet = false
                }
            )
            .appLocaleEnvironment()
        }
    }

    // MARK: - 子视图

    private var tagPaywallBinding: Binding<ProPaywallContext?> {
        Binding(
            get: { viewModel.paywallContext },
            set: { newValue in
                if newValue == nil {
                    viewModel.dismissPaywall()
                }
            }
        )
    }

    private var titleBar: some View {
        // 与新建标签 / 合并标签 / GitHubStarListEditorSheet 同一套 header 语言：
        // hierarchical 图标 + 主标题 + 关闭；不用 tint 实心色块以免和内容区抢层级。
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            Text("tagManagement.title")
                .font(.headline)

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: .system(size: 16, weight: .medium),
                helpKey: "action.close"
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tagList: some View {
        @Bindable var vm = viewModel
        return List(selection: $vm.selection) {
            if viewModel.tags.isEmpty && !viewModel.isLoading {
                Text("tagManagement.noTags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.tags) { tag in
                    tagRow(tag: tag)
                        .tag(tag.id)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func tagRow(tag: Tag) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
                .frame(width: 10, height: 10)
            if let icon = tag.icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            Text(verbatim: tag.name)
                .lineLimit(1)
            Spacer()
            Text((viewModel.counts[tag.id] ?? 0).formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contextMenu {
            Button {
                Task { await viewModel.delete(ids: [tag.id]) }
            } label: {
                Label("action.delete", systemImage: "trash")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let err = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(verbatim: err)
                        .font(.caption)
                    Spacer()
                    Button {
                        viewModel.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
            .focusEffectDisabled()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            HStack(spacing: 8) {
                Button {
                    showNewSheet = true
                } label: {
                    Label("action.new", systemImage: "plus")
                }

                Button {
                    // 至少 2 个才有默认 target；sheet 内仍可改选保留哪个。
                    showMergeSheet = (pickDefaultMergeTarget() != nil)
                } label: {
                    Label("action.merge", systemImage: "arrow.triangle.merge")
                }
                .disabled(!viewModel.canMerge)
                .help("tagEditor.mergeTooltip")

                Button {
                    showDeleteAlert = true
                } label: {
                    Label("action.delete", systemImage: "trash")
                }
                .disabled(viewModel.selection.isEmpty)

                Spacer()

                Text(String(format: String.l10n("tagManagement.tagCountFormat"), viewModel.tags.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 行为辅助

    private func handleSave(name: String, color: String?, icon: String?) async {
        guard let tag = viewModel.singleSelected else { return }
        await viewModel.update(tag, name: name, color: color, icon: icon)
    }

    /// 选 ≥2 时合并的默认 target：按现有 tags 顺序中最靠前的一个。
    private func pickDefaultMergeTarget() -> String? {
        let selected = viewModel.selection
        guard selected.count >= 2 else { return nil }
        return viewModel.tags.first { selected.contains($0.id) }?.id
    }
}

// MARK: - 合并目标选择 sheet

/// 多选合并时让用户显式选择保留哪个标签；默认预选列表顺序第一个。
private struct MergeTagsSheet: View {

    let candidates: [Tag]
    let counts: [String: Int]
    let onConfirm: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targetId: String
    @State private var submitting: Bool = false

    init(
        candidates: [Tag],
        counts: [String: Int],
        initialTargetId: String,
        onConfirm: @escaping (String) async -> Void
    ) {
        self.candidates = candidates
        self.counts = counts
        self.onConfirm = onConfirm
        _targetId = State(initialValue: initialTargetId)
    }

    var body: some View {
        // Header 对齐 GitHubStarListEditorSheet / 新建标签：图标 + 主副标题 + 关闭。
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("tagManagement.mergeSheetHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 2) {
                    ForEach(candidates) { tag in
                        Button {
                            targetId = tag.id
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: targetId == tag.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(targetId == tag.id ? Color.accentColor : .secondary)
                                    .font(.system(size: 14))

                                Circle()
                                    .fill(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
                                    .frame(width: 10, height: 10)

                                if let icon = tag.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                }

                                Text(verbatim: tag.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Text((counts[tag.id] ?? 0).formatted())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(targetId == tag.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }

                if let targetName = candidates.first(where: { $0.id == targetId })?.name {
                    Text(String(format: String.l10n("tagManagement.mergeMessageFormat"), candidates.count - 1, targetName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("general.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.merge") {
                    submitting = true
                    Task {
                        await onConfirm(targetId)
                        submitting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(submitting || !candidates.contains(where: { $0.id == targetId }))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("tagManagement.mergeSheetTitle")
                    .font(.headline)
                    .lineLimit(1)
                Text("tagManagement.mergeSheetSubtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: .system(size: 16, weight: .medium),
                helpKey: "action.close"
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - 新建标签小 sheet

/// 创建标签的轻量 sheet：名字 + 颜色 swatch + 图标 grid（与 Editor 同源组件）。
private struct NewTagSheet: View {

    /// onSubmit(name, colorHex, icon)。父级负责判定成功/失败。
    let onSubmit: (String, String?, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var color: String = TagColorPalette.defaultHex
    @State private var icon: String? = SFSymbolPreset.defaultIcon
    @State private var submitting: Bool = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        // 与 GitHubStarListEditorSheet / MergeTagsSheet 同一套 header：图标 + 主副标题 + 关闭。
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                TextField("tagManagement.tagName", text: $name)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("tagManagement.color")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(TagColorPalette.presets, id: \.hex) { preset in
                            Button {
                                color = preset.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: preset.hex) ?? .gray)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle().strokeBorder(
                                            color.lowercased() == preset.hex.lowercased() ? Color.primary : Color.clear,
                                            lineWidth: 2
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(Text(LocalizedStringKey(preset.name)))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("tagManagement.icon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SFSymbolGridPicker(selection: $icon, columns: 8)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("general.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.create") {
                    submitting = true
                    Task {
                        await onSubmit(name, color, icon)
                        submitting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(trimmedName.isEmpty || submitting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.square")
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                if trimmedName.isEmpty {
                    Text("tagManagement.newTagNamePlaceholder")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: trimmedName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text("tagManagement.newTag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: .system(size: 16, weight: .medium),
                helpKey: "action.close"
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
