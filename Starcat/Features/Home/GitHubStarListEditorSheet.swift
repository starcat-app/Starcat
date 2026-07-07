//
//  GitHubStarListEditorSheet.swift
//  Starcat
//
//  GitHub Stars List 创建 / 编辑 Sheet。
//
//  设计约束：
//  - name / description / private 写 GitHub；颜色只写 Starcat 本地缓存。
//  - 新建时用户不选颜色则传 nil，保存成功后由 `list.id` 稳定 hash 生成默认色。
//  - 删除 list 是远端 destructive mutation，必须二次确认。
//

import SwiftUI

struct GitHubStarListEditorSheet: View {

    let list: GitHubStarList?
    let service: GitHubStarListSyncService
    let onSaved: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var isPrivate: Bool
    @State private var selectedColorHex: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    private var isEditing: Bool { list != nil }

    init(
        list: GitHubStarList?,
        service: GitHubStarListSyncService,
        onSaved: @escaping @MainActor () async -> Void
    ) {
        self.list = list
        self.service = service
        self.onSaved = onSaved
        _name = State(initialValue: list?.name ?? "")
        _description = State(initialValue: list?.description ?? "")
        _isPrivate = State(initialValue: list?.isPrivate ?? false)
        _selectedColorHex = State(initialValue: list?.colorHex)
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
        .frame(minHeight: 420)
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
        HStack {
            HStack(spacing: 8) {
                Image(systemName: isEditing ? "folder" : "folder.badge.plus")
                    .foregroundStyle(.secondary)
                Text(isEditing ? "githubStarLists.editor.title.edit" : "githubStarLists.editor.title.create")
            }
            .font(.headline)
            Spacer()
            SheetCloseButton {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("githubStarLists.editor.name")
                        .font(.subheadline.weight(.semibold))
                    TextField("githubStarLists.editor.name.placeholder", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("githubStarLists.editor.description")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $description)
                        .font(.body)
                        .frame(minHeight: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }

                Toggle("githubStarLists.editor.private", isOn: $isPrivate)
                    .toggleStyle(.checkbox)

                colorSection

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

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("githubStarLists.editor.color")
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                autoColorButton
                ForEach(TagColorPalette.presets, id: \.hex) { preset in
                    Button {
                        selectedColorHex = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex) ?? .accentColor)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if selectedColorHex == preset.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
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
            }
        }
    }

    private var autoColorButton: some View {
        Button {
            selectedColorHex = nil
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 24, height: 24)
                if selectedColorHex == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("githubStarLists.editor.color.auto"))
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
            .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    colorHex: selectedColorHex
                )
            } else {
                _ = try await service.createList(
                    name: trimmedName,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                    isPrivate: isPrivate,
                    colorHex: selectedColorHex
                )
            }
            await onSaved()
            dismiss()
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
