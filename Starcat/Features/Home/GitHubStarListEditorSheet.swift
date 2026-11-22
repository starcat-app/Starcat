//
//  GitHubStarListEditorSheet.swift
//  Starcat
//
//  GitHub Stars List 创建 / 编辑 Sheet。
//
//  设计约束：
//  - name / description / private 写 GitHub；颜色和 AI 分组规则只写 Starcat 本地缓存。
//  - 新建默认无图标，显式传空字符串；nil 在 Repository 中代表保留旧颜色，不能用于清除。
//  - 删除 list 是远端 destructive mutation，必须二次确认。
//  - Header 对齐新建标签：单行标题（新增分组 / 编辑分组）+ 左上角分组语义图标（rectangle.3.group），不要二级标题。
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

    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var description: String
    @State private var isPrivate: Bool
    @State private var selectedColorHex: String
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

    private var canSave: Bool {
        !isSaving && !isLoadingAIRule && !trimmedName.isEmpty
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
        _selectedColorHex = State(initialValue: list?.colorHex ?? GitHubStarList.noColorHex)
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
        .defaultFocus($isNameFocused, true)
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

    /// 对齐新建标签：单行标题、不要二级标题；左上角用分组语义图标（rectangle.3.group）。
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(interfaceScale.font(.iconMedium, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            Text(isEditing ? "githubStarLists.editor.title.edit" : "githubStarLists.editor.title.create")
                .font(interfaceScale.font(.panelTitle))

            Spacer(minLength: 8)

            SheetCloseButton {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            githubSection
            Divider()
            starcatSection

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("githubStarLists.editor.section.githubGroup")

            labeledField("githubStarLists.editor.name") {
                TextField(
                    "githubStarLists.editor.name",
                    text: $name,
                    prompt: Text("githubStarLists.editor.name.placeholder")
                )
                .labelsHidden()
                .font(interfaceScale.font(.body))
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                // 回车提交只属于单行名称，避免把多行编辑或输入法由窗口级快捷键接管。
                .onSubmit { Task { await save() } }
            }

            labeledField("githubStarLists.editor.description.optional") {
                TextField(
                    "githubStarLists.editor.description.optional",
                    text: $description,
                    prompt: Text("githubStarLists.editor.description.placeholder"),
                    axis: .vertical
                )
                .labelsHidden()
                .starcatMarkdownBodyFont(baseline: .compact)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            }

            switchRow(
                "githubStarLists.editor.private.group",
                isOn: $isPrivate,
                help: "githubStarLists.editor.private.visibilityHelp"
            )
        }
    }

    private var starcatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("githubStarLists.editor.section.starcatLocal")
            colorField
            aiRuleBlock
        }
    }

    /// 长译文和大字号下让色板另起一行，保留完整标签和各色点的点击区。
    private var colorField: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                fieldLabel("githubStarLists.editor.color.group")
                colorRow
            }
            .fixedSize(horizontal: true, vertical: false)

            labeledField("githubStarLists.editor.color.group") {
                colorRow
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 4) {
            noColorButton
            ForEach(TagColorPalette.presets, id: \.hex) { preset in
                Button {
                    selectedColorHex = preset.hex
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex) ?? .accentColor)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle().strokeBorder(
                                selectedColorHex == preset.hex ? Color.primary : Color.secondary.opacity(0.25),
                                lineWidth: selectedColorHex == preset.hex ? 2 : 1
                            )
                        }
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text(LocalizedStringKey(preset.name)))
                .accessibilityLabel(Text(LocalizedStringKey(preset.name)))
                .accessibilityAddTraits(selectedColorHex == preset.hex ? .isSelected : [])
            }
        }
    }

    /// 无图标是可保存的选择，提交空值以清除原有颜色。
    private var noColorButton: some View {
        Button {
            selectedColorHex = GitHubStarList.noColorHex
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 20, height: 20)
                    if selectedColorHex.isEmpty {
                        Image(systemName: "checkmark")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHidden(true)

                fieldLabel("githubStarLists.editor.color.none")
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selectedColorHex.isEmpty ? .isSelected : [])
    }

    /// AI 规则新建默认折叠；整行标题可点，符合折叠/展开规范。
    private var aiRuleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)) {
                    isAIRuleExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isAIRuleExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionStrong))
                        .foregroundStyle(.secondary)
                        .frame(width: interfaceScale.scaled(12))
                        .accessibilityHidden(true)
                    Text("githubStarLists.editor.aiRule.title")
                        .font(interfaceScale.font(.bodyEmphasis))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isAIRuleExpanded {
                TextField(
                    "githubStarLists.editor.aiRule.title",
                    text: $aiInstruction,
                    prompt: Text("githubStarLists.editor.aiRule.example"),
                    axis: .vertical
                )
                .labelsHidden()
                .starcatMarkdownBodyFont(baseline: .compact)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .disabled(isLoadingAIRule)

                formHint("githubStarLists.editor.aiRule.providerHelp")

                switchRow(
                    "githubStarLists.editor.aiRule.autoApply",
                    isOn: $autoApplyEnabled,
                    isDisabled: isLoadingAIRule || !hasAIInstruction,
                    help: !hasAIInstruction ? "githubStarLists.editor.aiRule.backgroundGrouping.disabledHelp" : nil
                )
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
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(isSaving ? "githubStarLists.editor.saving" : (isEditing ? "action.save" : "action.create")) {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .font(interfaceScale.font(.body))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(interfaceScale.font(.captionStrong))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(interfaceScale.font(.body))
            .foregroundStyle(.primary)
    }

    private func formHint(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 开关禁用时原因仍可读；轨道复用 AI 分组预检的紧凑样式。
    private func switchRow(
        _ title: LocalizedStringKey,
        isOn: Binding<Bool>,
        isDisabled: Bool = false,
        help: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(interfaceScale.font(.body))
                        .foregroundStyle(isDisabled ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    CompactSwitchIndicator(isOn: isOn.wrappedValue, isEnabled: !isDisabled)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isDisabled)

            if let help {
                formHint(help)
            }
        }
    }

    private func labeledField<Content: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(titleKey)
            content()
        }
    }

    private func save() async {
        guard canSave else { return }
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
