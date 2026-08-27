//
//  GitHubStarListEditorSheet.swift
//  Starcat
//
//  GitHub Stars List 创建 / 编辑 Sheet。
//
//  设计约束：
//  - name / description / private 写 GitHub；颜色和 AI 分组规则只写 Starcat 本地缓存。
//  - 新建时用户不选颜色则传 nil，保存成功后由 `list.id` 稳定 hash 生成默认色。
//  - 删除 list 是远端 destructive mutation，必须二次确认。
//  - 顶部用分组名预览身份，图标与侧栏编辑 / 新建入口同一套 square 符号，不用颜色圆点。
//  - GitHub / Starcat 分成两段，避免创建时把 AI 规则当成必填项。
//

import SwiftUI

struct GitHubStarListEditorSheet: View {

    let list: GitHubStarList?
    let service: GitHubStarListSyncService
    let onSaved: @MainActor () async -> Void
    /// 开始页「添加 / 修改 AI 规则」需要一进来就看到规则区，避免还要再点一次折叠标题。
    let expandAIRuleOnOpen: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var name: String
    @State private var description: String
    @State private var isPrivate: Bool
    @State private var selectedColorHex: String?
    @State private var aiInstruction = ""
    @State private var autoApplyEnabled = false
    @State private var isAIRuleExpanded: Bool
    @State private var isLoadingAIRule = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var isEditing: Bool { list != nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAIInstruction: Bool {
        !aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        list: GitHubStarList?,
        service: GitHubStarListSyncService,
        expandAIRuleOnOpen: Bool = false,
        onSaved: @escaping @MainActor () async -> Void
    ) {
        self.list = list
        self.service = service
        self.expandAIRuleOnOpen = expandAIRuleOnOpen
        self.onSaved = onSaved
        _name = State(initialValue: list?.name ?? "")
        _description = State(initialValue: list?.description ?? "")
        _isPrivate = State(initialValue: list?.isPrivate ?? false)
        _selectedColorHex = State(initialValue: list?.colorHex)
        // 新建默认折叠；编辑态等规则加载后再决定是否展开，避免空规则占掉第一眼。
        _isAIRuleExpanded = State(initialValue: expandAIRuleOnOpen)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formBody
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 360)
        .task(id: list?.id) {
            await loadAIRule()
        }
        .alert("githubStarLists.editor.delete.title", isPresented: $showDeleteConfirmation) {
            Button("action.delete", role: .destructive) {
                Task { await deleteList() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("githubStarLists.editor.delete.message")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isEditing ? "slider.horizontal.2.square" : "plus.square")
                .font(interfaceScale.font(.iconMedium, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                if trimmedName.isEmpty {
                    Text("githubStarLists.editor.name.placeholder")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: trimmedName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(isEditing ? "githubStarLists.editor.title.edit" : "githubStarLists.editor.title.create")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            SheetCloseButton {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                githubSection
                starcatSection

                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("githubStarLists.editor.section.github")

            labeledField("githubStarLists.editor.name") {
                TextField("githubStarLists.editor.name.placeholder", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("githubStarLists.editor.description") {
                TextField(
                    "githubStarLists.editor.description.placeholder",
                    text: $description,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            }

            Toggle(isOn: $isPrivate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("githubStarLists.editor.private")
                    Text("githubStarLists.editor.private.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var starcatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("githubStarLists.editor.section.starcat")

            labeledField("githubStarLists.editor.color") {
                colorRow
            }

            aiRuleBlock
        }
    }

    private var colorRow: some View {
        HStack(spacing: 6) {
            autoColorButton
            ForEach(TagColorPalette.presets, id: \.hex) { preset in
                Button {
                    selectedColorHex = preset.hex
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex) ?? .accentColor)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if selectedColorHex == preset.hex {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text(LocalizedStringKey(preset.name)))
            }
            Spacer(minLength: 0)
        }
    }

    private var autoColorButton: some View {
        Button {
            selectedColorHex = nil
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 20, height: 20)
                if selectedColorHex == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("githubStarLists.editor.color.auto"))
    }

    /// AI 规则新建默认折叠；整行标题可点，符合折叠/展开规范。
    private var aiRuleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isAIRuleExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isAIRuleExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("githubStarLists.editor.aiRule.title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isAIRuleExpanded {
                TextField(
                    "githubStarLists.editor.aiRule.placeholder",
                    text: $aiInstruction,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .disabled(isLoadingAIRule)

                Text("githubStarLists.editor.aiRule.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $autoApplyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("githubStarLists.editor.aiRule.autoApply")
                        if !hasAIInstruction {
                            Text("githubStarLists.editor.aiRule.autoApply.disabledHelp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isLoadingAIRule || !hasAIInstruction)
            }
        }
        .onChange(of: hasAIInstruction) { _, hasRule in
            if !hasRule {
                autoApplyEnabled = false
            }
        }
    }

    private var footer: some View {
        HStack {
            if isEditing {
                Button("action.delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(isSaving)
            }

            Spacer()

            Button("common.cancel") {
                dismiss()
            }
            .disabled(isSaving)

            Button(isSaving ? "githubStarLists.editor.saving" : "action.save") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || isLoadingAIRule || trimmedName.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func labeledField<Content: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func save() async {
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let list {
                _ = try await service.updateList(
                    id: list.id,
                    name: trimmedName,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                    isPrivate: isPrivate,
                    colorHex: selectedColorHex,
                    aiInstruction: aiInstruction,
                    autoApplyEnabled: autoApplyEnabled
                )
            } else {
                _ = try await service.createList(
                    name: trimmedName,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                    isPrivate: isPrivate,
                    colorHex: selectedColorHex,
                    aiInstruction: aiInstruction,
                    autoApplyEnabled: autoApplyEnabled
                )
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAIRule() async {
        guard let list else { return }
        isLoadingAIRule = true
        defer { isLoadingAIRule = false }
        do {
            guard let rule = try await service.aiRule(forList: list.id) else { return }
            aiInstruction = rule.instruction
            autoApplyEnabled = rule.autoApplyEnabled
            if !rule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isAIRuleExpanded = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteList() async {
        guard let list else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await service.deleteList(id: list.id)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
