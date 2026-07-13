//
//  RAGWorkspacePromptSettingsSheet.swift
//  Starcat
//
//  RAG 工作台提示词编辑 Sheet：Generator / Planner 两套 System + User 模板，
//  可恢复英文默认值；运行时仍由 Builder 注入 `{outputLanguage}` 等占位符。
//

import SwiftUI

private enum RAGPromptEditorTab: String, CaseIterable, Identifiable {
    case generator
    case planner

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .generator: return "rag.workspace.prompt.tab.generator"
        case .planner: return "rag.workspace.prompt.tab.planner"
        }
    }
}

struct RAGWorkspacePromptSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @Bindable var settings: AppSettings
    @State private var tab: RAGPromptEditorTab = .generator
    @State private var draft: RAGPromptSettings

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.ragPromptSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("rag.workspace.prompt.title")
                    .font(.headline)
                Spacer(minLength: 8)
                ResetIconButton(help: Text("rag.workspace.prompt.restoreHelp")) {
                    restoreCurrentTab()
                }
                SheetCloseButton(action: { dismiss() })
            }

            Picker("rag.workspace.prompt.title", selection: $tab) {
                ForEach(RAGPromptEditorTab.allCases) { item in
                    Text(item.titleKey).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            promptEditor(
                titleKey: "rag.workspace.prompt.system",
                text: systemBinding,
                height: 160
            )
            promptEditor(
                titleKey: "rag.workspace.prompt.user",
                text: userBinding,
                height: 200
            )

            Text(placeholderHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("rag.workspace.prompt.save") {
                    settings.ragPromptSettings = draft
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 720 * interfaceScale.multiplier, height: 560 * interfaceScale.multiplier)
        .appLocaleEnvironment()
    }

    private var systemBinding: Binding<String> {
        Binding(
            get: {
                switch tab {
                case .generator: return draft.generator.systemPrompt
                case .planner: return draft.planner.systemPrompt
                }
            },
            set: { value in
                switch tab {
                case .generator: draft.generator.systemPrompt = value
                case .planner: draft.planner.systemPrompt = value
                }
            }
        )
    }

    private var userBinding: Binding<String> {
        Binding(
            get: {
                switch tab {
                case .generator: return draft.generator.userPromptTemplate
                case .planner: return draft.planner.userPromptTemplate
                }
            },
            set: { value in
                switch tab {
                case .generator: draft.generator.userPromptTemplate = value
                case .planner: draft.planner.userPromptTemplate = value
                }
            }
        )
    }

    private var placeholderHint: LocalizedStringKey {
        switch tab {
        case .generator: return "rag.workspace.prompt.placeholders.generator"
        case .planner: return "rag.workspace.prompt.placeholders.planner"
        }
    }

    private func restoreCurrentTab() {
        switch tab {
        case .generator: draft.generator = RAGDefaultPrompts.generator
        case .planner: draft.planner = RAGDefaultPrompts.planner
        }
    }

    private func promptEditor(titleKey: LocalizedStringKey, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
    }
}
