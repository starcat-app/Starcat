//
//  RAGWorkspacePromptSettingsSheet.swift
//  Starcat
//
//  RAG 工作台提示词编辑 Sheet：Generator / Planner / Compressor / Title 四套
//  System + User 模板，可恢复英文默认值；运行时仍由 Builder / Service 注入
//  `{outputLanguage}` 等占位符。
//
//  UI（2026-07-13）：
//  - System 吃主要高度、User 次之；重置放在 segmented 右侧。
//  - 字号直接读 `settings.interfaceScale`（与独立窗口同一档位），不只缩放外框。
//  - 占位符说明收进 popover，避免底部一长串 token 且无含义。
//  - 2026-07-14：一行 4 段 segmented（回答 / 规划 / 压缩 / 标题）。
//

import SwiftUI

private enum RAGPromptEditorTab: String, CaseIterable, Identifiable {
    case generator
    case planner
    case compressor
    case title

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .generator: return "rag.workspace.prompt.tab.generator"
        case .planner: return "rag.workspace.prompt.tab.planner"
        case .compressor: return "rag.workspace.prompt.tab.compressor"
        case .title: return "rag.workspace.prompt.tab.title"
        }
    }

    var placeholders: [RAGPromptPlaceholderItem] {
        switch self {
        case .generator:
            return [
                .init(token: "{outputLanguage}", meaningKey: "rag.workspace.prompt.placeholder.outputLanguage"),
                .init(token: "{questionSection}", meaningKey: "rag.workspace.prompt.placeholder.questionSection"),
                .init(token: "{evidenceSection}", meaningKey: "rag.workspace.prompt.placeholder.evidenceSection"),
                .init(token: "{remoteSection}", meaningKey: "rag.workspace.prompt.placeholder.remoteSection"),
                .init(token: "{attachmentSection}", meaningKey: "rag.workspace.prompt.placeholder.attachmentSection"),
            ]
        case .planner:
            return [
                .init(token: "{outputLanguage}", meaningKey: "rag.workspace.prompt.placeholder.outputLanguagePlanner"),
                .init(token: "{question}", meaningKey: "rag.workspace.prompt.placeholder.question"),
                .init(token: "{explicitRepositories}", meaningKey: "rag.workspace.prompt.placeholder.explicitRepositories"),
                .init(token: "{explicitRepoMode}", meaningKey: "rag.workspace.prompt.placeholder.explicitRepoMode"),
                .init(token: "{attachmentDescriptors}", meaningKey: "rag.workspace.prompt.placeholder.attachmentDescriptors"),
                .init(token: "{pastedGitHubLinks}", meaningKey: "rag.workspace.prompt.placeholder.pastedGitHubLinks"),
                .init(token: "{previousUserQuestion}", meaningKey: "rag.workspace.prompt.placeholder.previousUserQuestion"),
                .init(token: "{previousReferencedRepositories}", meaningKey: "rag.workspace.prompt.placeholder.previousReferencedRepositories"),
            ]
        case .compressor:
            return [
                .init(token: "{outputLanguage}", meaningKey: "rag.workspace.prompt.placeholder.outputLanguageCompressor"),
                .init(token: "{existingSummarySection}", meaningKey: "rag.workspace.prompt.placeholder.existingSummarySection"),
                .init(token: "{newMessagesSection}", meaningKey: "rag.workspace.prompt.placeholder.newMessagesSection"),
            ]
        case .title:
            return [
                .init(token: "{outputLanguage}", meaningKey: "rag.workspace.prompt.placeholder.outputLanguageTitle"),
                .init(token: "{firstQuestion}", meaningKey: "rag.workspace.prompt.placeholder.firstQuestion"),
            ]
        }
    }
}

/// 占位符条目：token 原文 + 含义 i18n key。
private struct RAGPromptPlaceholderItem: Identifiable {
    let token: String
    let meaningKey: LocalizedStringKey
    var id: String { token }
}

struct RAGWorkspacePromptSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var settings: AppSettings
    @State private var tab: RAGPromptEditorTab = .generator
    @State private var draft: RAGPromptSettings
    @State private var isPlaceholderPopoverPresented = false

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.ragPromptSettings)
    }

    /// 直接订阅设置档位，避免 sheet 只缩放外框、字体仍停在 standard。
    private var interfaceScale: InterfaceScale { settings.interfaceScale }

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(16)) {
            header

            HStack(spacing: interfaceScale.scaled(12)) {
                Picker("rag.workspace.prompt.title", selection: $tab) {
                    ForEach(RAGPromptEditorTab.allCases) { item in
                        Text(item.titleKey).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                // 与 AI Settings 一致：重置跟当前 Tab，不跟关闭钮抢位。
                ResetIconButton(
                    help: Text("rag.workspace.prompt.restoreHelp"),
                    font: interfaceScale.font(size: 13, weight: .medium),
                    frameSize: interfaceScale.scaled(20)
                ) {
                    restoreCurrentTab()
                }
            }

            // System 默认更长，给弹性高度；User 模板短，固定下限即可。
            promptEditor(
                titleKey: "rag.workspace.prompt.system",
                text: systemBinding,
                minHeight: interfaceScale.scaled(240)
            )
            .layoutPriority(1)

            promptEditor(
                titleKey: "rag.workspace.prompt.user",
                text: userBinding,
                minHeight: interfaceScale.scaled(148)
            )

            VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
                placeholderHelpButton

                HStack {
                    Spacer()
                    Button("common.cancel") { dismiss() }
                        .font(ragFont(.body, scale: interfaceScale))
                    Button("rag.workspace.prompt.save") {
                        settings.ragPromptSettings = draft
                        dismiss()
                    }
                    .font(ragFont(.body, scale: interfaceScale))
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, interfaceScale.scaled(4))
        }
        .padding(interfaceScale.scaled(20))
        .frame(
            width: 820 * interfaceScale.multiplier,
            height: 640 * interfaceScale.multiplier
        )
        // sheet 独立环境树：显式挂档位，系统控件与自定义字体同步缩放。
        .environment(\.starcatInterfaceScale, interfaceScale)
        .dynamicTypeSize(interfaceScale.dynamicTypeSize)
        .appLocaleEnvironment()
    }

    /// 左上角图标 + 标题；关闭单独在右上，避免与重置相邻误触。
    private var header: some View {
        HStack(alignment: .center, spacing: interfaceScale.scaled(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: "doc.badge.gearshape")
                    .font(interfaceScale.font(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(
                width: interfaceScale.scaled(36),
                height: interfaceScale.scaled(36)
            )
            .accessibilityHidden(true)

            Text("rag.workspace.prompt.title")
                .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: interfaceScale.font(size: 18, weight: .medium),
                frameSize: interfaceScale.scaled(24)
            )
        }
    }

    /// 底部入口：点开看 token + 含义，避免一行塞满无说明的占位符列表。
    private var placeholderHelpButton: some View {
        Button {
            isPlaceholderPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                Text("rag.workspace.prompt.placeholders.open")
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                Image(systemName: "info.circle")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.prompt.placeholders.openHelp")
        .popover(isPresented: $isPlaceholderPopoverPresented, arrowEdge: .top) {
            RAGPromptPlaceholderPopover(
                items: tab.placeholders,
                interfaceScale: interfaceScale
            )
            .appLocaleEnvironment()
        }
    }

    private var systemBinding: Binding<String> {
        Binding(
            get: {
                switch tab {
                case .generator: return draft.generator.systemPrompt
                case .planner: return draft.planner.systemPrompt
                case .compressor: return draft.compressor.systemPrompt
                case .title: return draft.title.systemPrompt
                }
            },
            set: { value in
                switch tab {
                case .generator: draft.generator.systemPrompt = value
                case .planner: draft.planner.systemPrompt = value
                case .compressor: draft.compressor.systemPrompt = value
                case .title: draft.title.systemPrompt = value
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
                case .compressor: return draft.compressor.userPromptTemplate
                case .title: return draft.title.userPromptTemplate
                }
            },
            set: { value in
                switch tab {
                case .generator: draft.generator.userPromptTemplate = value
                case .planner: draft.planner.userPromptTemplate = value
                case .compressor: draft.compressor.userPromptTemplate = value
                case .title: draft.title.userPromptTemplate = value
                }
            }
        )
    }

    private func restoreCurrentTab() {
        switch tab {
        case .generator: draft.generator = RAGDefaultPrompts.generator
        case .planner: draft.planner = RAGDefaultPrompts.planner
        case .compressor: draft.compressor = RAGDefaultPrompts.compressor
        case .title: draft.title = RAGDefaultPrompts.title
        }
    }

    private func promptEditor(
        titleKey: LocalizedStringKey,
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            Text(titleKey)
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: text)
                .font(interfaceScale.font(.code))
                .scrollContentBackground(.hidden)
                .padding(interfaceScale.scaled(8))
                .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )
        }
    }
}

/// 占位符说明 Popover：当前 Tab 的全部 token 与含义。
private struct RAGPromptPlaceholderPopover: View {
    let items: [RAGPromptPlaceholderItem]
    let interfaceScale: InterfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            Text("rag.workspace.prompt.placeholders.title")
                .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.token)
                            .font(interfaceScale.font(.code, weight: .semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Text(item.meaningKey)
                            .font(ragFont(.caption, scale: interfaceScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("rag.workspace.prompt.placeholders.note")
                .font(ragFont(.caption2, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(interfaceScale.scaled(16))
        .frame(width: 360 * interfaceScale.multiplier)
        .environment(\.starcatInterfaceScale, interfaceScale)
        .dynamicTypeSize(interfaceScale.dynamicTypeSize)
    }
}
