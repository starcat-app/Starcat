//
//  TagEditorView.swift
//  Starcat
//
//  标签编辑面板（右栏）：单标签的 name / color / icon 编辑表单。
//
//  用法：
//  - 嵌入到 TagManagementView 右侧
//  - 单选时显示标签字段；未选 / 多选时显示空态提示
//
//  设计约束：
//  - 表单本地态：editingName / editingColor / editingIcon（脱离 tag 直接编辑）
//  - "保存"按钮提交后调 viewModel.update；不做自动保存（避免误触 UNIQUE 冲突回滚）
//  - 颜色：预设 12 色 swatch 行 + 系统 ColorPicker 自定义
//  - 图标：grid 选 + "无图标" 选项
//

import SwiftUI

struct TagEditorView: View {

    /// 当前编辑的标签；nil 表示未选 / 多选。
    let tag: Tag?

    /// 多选时显示"已选 N 个"提示；不允许编辑。
    let selectionCount: Int

    /// 保存回调：(name, color hex, icon SF Symbol) → ViewModel.update
    let onSave: (String, String?, String?) async -> Void

    /// 删除回调：触发确认 alert 再调 ViewModel.delete
    let onRequestDelete: () -> Void

    // MARK: - 本地编辑态

    @State private var editingName: String = ""
    @State private var editingColor: String = TagColorPalette.defaultHex
    @State private var editingIcon: String? = SFSymbolPreset.defaultIcon
    /// 用于判断"是否有未保存更改"以启用/禁用保存按钮。
    @State private var loadedTagId: String? = nil

    var body: some View {
        Group {
            if let tag {
                editor(for: tag)
            } else if selectionCount > 1 {
                emptyState(
                    icon: "checklist",
                    title: "已选 \(selectionCount) 个标签",
                    detail: "多选状态下不可编辑单个字段；可执行「删除」或「合并」。"
                )
            } else {
                emptyState(
                    icon: "tag",
                    title: "选择一个标签开始编辑",
                    detail: "或点击左下角「+」创建新标签。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 编辑表单

    @ViewBuilder
    private func editor(for tag: Tag) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部预览：色块 + 图标 + 当前 name
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: editingColor) ?? .accentColor)
                    .frame(width: 14, height: 14)
                if let icon = editingIcon {
                    Image(systemName: icon).font(.system(size: 13))
                }
                Text(editingName.isEmpty ? tag.name : editingName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 名字
                    section(title: "名称") {
                        TextField("标签名", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 颜色：预设 swatch + 自定义
                    section(title: "颜色") {
                        VStack(alignment: .leading, spacing: 8) {
                            colorSwatches
                            HStack {
                                ColorPicker("自定义", selection: customColorBinding, supportsOpacity: false)
                                    .labelsHidden()
                                Text(editingColor.uppercased())
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }

                    // 图标
                    section(title: "图标") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    editingIcon = nil
                                } label: {
                                    Label("无图标", systemImage: "circle.slash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                .focusEffectDisabled()
                                .foregroundStyle(editingIcon == nil ? .primary : .secondary)
                                Spacer()
                            }
                            SFSymbolGridPicker(selection: $editingIcon)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Divider()

            // 底栏：保存 + 删除
            HStack {
                Button(role: .destructive) {
                    onRequestDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }

                Spacer()

                Button("保存") {
                    Task {
                        await onSave(editingName, editingColor, editingIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onChange(of: tag.id) { _, newId in
            // 切换到不同标签时重置编辑态
            loadIntoForm(tag)
            loadedTagId = newId
        }
        .onAppear {
            if loadedTagId != tag.id {
                loadIntoForm(tag)
                loadedTagId = tag.id
            }
        }
    }

    private func loadIntoForm(_ tag: Tag) {
        editingName = tag.name
        editingColor = tag.color ?? TagColorPalette.defaultHex
        editingIcon = tag.icon
    }

    // MARK: - 颜色 swatch 行

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(TagColorPalette.presets, id: \.hex) { preset in
                Button {
                    editingColor = preset.hex
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex) ?? .gray)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    editingColor.lowercased() == preset.hex.lowercased() ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(preset.name)
            }
        }
    }

    /// 把 hex 字符串 ↔ Color 桥成 SwiftUI Binding<Color>。
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: editingColor) ?? .accentColor },
            set: { editingColor = $0.toHex() }
        )
    }

    // MARK: - section helper

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - 空态

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
