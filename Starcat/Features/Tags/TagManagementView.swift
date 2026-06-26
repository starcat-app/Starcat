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
//  - 合并：选 ≥2 → 弹 alert 选 target
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

    // MARK: - 子 UI 状态

    /// 新建标签 sheet 显示状态。
    @State private var showNewSheet: Bool = false
    /// 删除确认 alert 显示状态。
    @State private var showDeleteAlert: Bool = false
    /// 合并 alert 显示状态。
    @State private var showMergeAlert: Bool = false
    /// 合并时用户选的 target id。
    @State private var mergeTargetId: String? = nil

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
        .sheet(isPresented: $showNewSheet) {
            NewTagSheet { name, color, icon in
                let ok = await viewModel.create(name: name, color: color, icon: icon)
                if ok { showNewSheet = false }
            }
            .appLocaleEnvironment()
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
        .alert("tagManagement.mergeTitle", isPresented: $showMergeAlert, presenting: mergeTargetId) { targetId in
            Button("action.merge", role: .destructive) {
                Task {
                    await viewModel.merge(sources: viewModel.selection, into: targetId)
                }
            }
            Button("general.cancel", role: .cancel) {}
        } message: { targetId in
            let targetName = viewModel.tags.first { $0.id == targetId }?.name ?? "?"
            let others = viewModel.selection.count - 1
            Text(String(format: String.l10n("tagManagement.mergeMessageFormat"), others, targetName))
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
        HStack {
            Image(systemName: "tag.fill")
                .foregroundStyle(.tint)
            Text("tagManagement.title")
                .font(.headline)
            Spacer()
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
                    // 默认 target = 选中里第一个（按 fetchAll 排序顺序）
                    mergeTargetId = pickDefaultMergeTarget()
                    showMergeAlert = (mergeTargetId != nil)
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
    /// MVP 简化：不让用户从 sheet 里选 target，直接默认 + alert 文案显示是哪个。
    /// 用户若想换 target，可以在 List 里调整选择顺序（先单选 target，再 Cmd 加选 others）。
    private func pickDefaultMergeTarget() -> String? {
        let selected = viewModel.selection
        guard selected.count >= 2 else { return nil }
        return viewModel.tags.first { selected.contains($0.id) }?.id
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("tagManagement.newTag")
                .font(.headline)

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
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
