//
//  SmartCollectionMultiSelectField.swift
//  Starcat
//
//  智能集合规则编辑器用的 Popover 多选字段。
//
//  **为什么不用 Menu + Button**：
//  SwiftUI `Menu` 点任意项后会立刻 dismiss，多选必须反复打开下拉 —— 反人类。
//  `Popover + Toggle` 可连续勾选，点外部或 Esc 才关闭（与 SearchCenter 内容类型字段一致）。
//

import SwiftUI

struct SmartCollectionMultiSelectOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

/// Popover 多选：语言 / 标签等长列表。
struct SmartCollectionMultiSelectField: View {
    let titleKey: LocalizedStringKey
    var showsInlineTitle: Bool = true
    @Binding var selectedIDs: [String]
    let options: [SmartCollectionMultiSelectOption]

    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsInlineTitle {
                Text(titleKey)
                    .font(.callout)
            }

            Button {
                isPresented.toggle()
            } label: {
                fieldLabel
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                selectionPopover
                    .appLocaleEnvironment()
            }
        }
    }

    private var fieldLabel: some View {
        HStack(spacing: 6) {
            Text(displayText)
                .font(.system(size: 12))
                .foregroundStyle(selectedIDs.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private var selectionPopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if options.isEmpty {
                    Text("smartCollections.editor.multiSelect.emptyOptions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(options) { option in
                        Toggle(option.label, isOn: toggleBinding(for: option.id))
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 280)
    }

    private var displayText: String {
        if selectedIDs.isEmpty {
            return String.l10n("smartCollections.editor.multiSelect.none")
        }
        let labelMap = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.label) })
        let labels = selectedIDs.compactMap { labelMap[$0] ?? $0 }
        return labels.joined(separator: String.l10n("smartCollections.rule.listSeparator"))
    }

    private func toggleBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn {
                    if !selectedIDs.contains(id) {
                        selectedIDs.append(id)
                    }
                } else {
                    selectedIDs.removeAll { $0 == id }
                }
            }
        )
    }
}

/// 健康度 A–E：仅 5 档，用 macOS `.button` Toggle 横排，无需下拉。
struct SmartCollectionGradePicker: View {
    @Binding var selectedGrades: [String]

    private static let grades = ["A", "B", "C", "D", "E"]

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                ForEach(Self.grades, id: \.self) { grade in
                    Toggle(grade, isOn: gradeBinding(grade))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
        } label: {
            Text("smartCollections.editor.healthGrades")
                .lineLimit(1)
        }
    }

    private func gradeBinding(_ grade: String) -> Binding<Bool> {
        Binding(
            get: { selectedGrades.contains(grade) },
            set: { isOn in
                if isOn {
                    if !selectedGrades.contains(grade) {
                        selectedGrades.append(grade)
                    }
                } else {
                    selectedGrades.removeAll { $0 == grade }
                }
            }
        )
    }
}
