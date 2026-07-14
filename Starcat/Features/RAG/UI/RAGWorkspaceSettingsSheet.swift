//
//  RAGWorkspaceSettingsSheet.swift
//  Starcat
//
//  RAG 工作台配置 Sheet：提示词与检索策略共用一个入口。
//  提示词部分直接编辑运行时配置；检索页当前只承载可验证的界面状态，待检索
//  设置模型接入后再统一写入 AppSettings，避免 UI 验收阶段提前改变真实召回行为。
//
//  UI（2026-07-13）：
//  - System 吃主要高度、User 次之；重置放在 segmented 右侧。
//  - 字号直接读 `settings.interfaceScale`（与独立窗口同一档位），不只缩放外框。
//  - 占位符说明收进 popover，避免底部一长串 token 且无含义。
//  - 2026-07-14：一行 4 段 segmented（回答 / 规划 / 压缩 / 标题）。
//  - 2026-07-14：增加提示词 / 检索一级分段，先完成检索配置界面验收。
//  - 2026-07-14：检索页对齐「侧栏 + 内容卡片」设置布局——收窄窗口、滚动区给
//    滚动条留 gutter、证据来源单行、预设切换时静默写字段避免被踢回「自定义」。
//  - 2026-07-14：由 PromptSettingsSheet 重命名为 SettingsSheet（不止编辑 Prompt）。
//

import SwiftUI

private enum RAGSettingsSection: String, CaseIterable, Identifiable {
    case prompts
    case retrieval

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .prompts: return "rag.workspace.settings.section.prompts"
        case .retrieval: return "rag.workspace.settings.section.retrieval"
        }
    }
}

private enum RAGRetrievalPreset: String, CaseIterable, Identifiable {
    case balanced
    case strict
    case broad
    case custom

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .balanced: return "rag.workspace.retrieval.preset.balanced"
        case .strict: return "rag.workspace.retrieval.preset.strict"
        case .broad: return "rag.workspace.retrieval.preset.broad"
        case .custom: return "rag.workspace.retrieval.preset.custom"
        }
    }
}

/// Sheet 外框：参考系统设置式侧栏布局，宽度吃提示词编辑、高度吃检索卡片。
private enum RAGSettingsSheetMetrics {
    static let width: CGFloat = 680
    static let height: CGFloat = 620
    static let sidebarWidth: CGFloat = 168
    /// macOS overlay 滚动条会盖住右缘控件；内容尾部预留 gutter。
    static let scrollTrailerGutter: CGFloat = 14
}

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

struct RAGWorkspaceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var settings: AppSettings
    @State private var section: RAGSettingsSection = .prompts
    @State private var tab: RAGPromptEditorTab = .generator
    @State private var draft: RAGPromptSettings
    @State private var isPlaceholderPopoverPresented = false
    // 下列值刻意只停留在 Sheet 内。用户正在验证界面，检索器尚未读取这些值。
    @State private var retrievalPreset: RAGRetrievalPreset = .balanced
    @State private var minimumVectorSimilarity = 0.65
    @State private var finalEvidenceChunkLimit = "8"
    @State private var perRepositoryEvidenceLimit = "3"
    @State private var evidenceTokenBudget = "8000"
    @State private var includesReadme = true
    @State private var includesNotes = true
    @State private var includesSummary = true
    @State private var includesMetadata = true
    /// `apply(_:)` 写字段期间抬起，挡住误判「自定义」；用户手动拖滑杆 / 改数字时则放行。
    @State private var isApplyingRetrievalPreset = false

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.ragPromptSettings)
    }

    /// 直接订阅设置档位，避免 sheet 只缩放外框、字体仍停在 standard。
    private var interfaceScale: InterfaceScale { settings.interfaceScale }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .frame(
            width: RAGSettingsSheetMetrics.width * interfaceScale.multiplier,
            height: RAGSettingsSheetMetrics.height * interfaceScale.multiplier
        )
        // sheet 独立环境树：显式挂档位，系统控件与自定义字体同步缩放。
        .environment(\.starcatInterfaceScale, interfaceScale)
        .dynamicTypeSize(interfaceScale.dynamicTypeSize)
        .appLocaleEnvironment()
    }

    /// 左栏只负责稳定导航；后续增加联网、模型等配置时不必重做布局。
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            Text("rag.workspace.settings.title")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, interfaceScale.scaled(6))

            ForEach(RAGSettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: interfaceScale.scaled(9)) {
                        Image(systemName: item == .prompts ? "text.quote" : "magnifyingglass")
                            .font(interfaceScale.font(size: 14, weight: .medium))
                            .frame(width: interfaceScale.scaled(18))
                        Text(item.titleKey)
                            .font(ragFont(.body, scale: interfaceScale, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(section == item ? .primary : .secondary)
                    .padding(.horizontal, interfaceScale.scaled(10))
                    .padding(.vertical, interfaceScale.scaled(8))
                    .background(
                        section == item ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Spacer()
        }
        .padding(interfaceScale.scaled(14))
        .frame(width: interfaceScale.scaled(RAGSettingsSheetMetrics.sidebarWidth), alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }

    private var settingsDetail: some View {
        VStack(spacing: 0) {
            detailHeader

            Group {
                if section == .prompts {
                    promptSettingsContent
                } else {
                    retrievalSettingsContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, interfaceScale.scaled(20))
            .padding(.bottom, interfaceScale.scaled(12))

            Divider()
            actionBar
        }
    }

    /// 右侧只展示当前分类标题，避免在左栏和内容区重复铺大标题。
    private var detailHeader: some View {
        HStack(alignment: .center, spacing: interfaceScale.scaled(10)) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: section == .prompts ? "text.quote" : "magnifyingglass")
                    .font(interfaceScale.font(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(
                width: interfaceScale.scaled(30),
                height: interfaceScale.scaled(30)
            )
            .accessibilityHidden(true)

            Text(section.titleKey)
                .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: interfaceScale.font(size: 18, weight: .medium),
                frameSize: interfaceScale.scaled(24)
            )
        }
        .padding(.horizontal, interfaceScale.scaled(20))
        .padding(.vertical, interfaceScale.scaled(14))
    }

    private var actionBar: some View {
        HStack(spacing: interfaceScale.scaled(8)) {
            if section == .prompts {
                placeholderHelpButton
            }
            Spacer()
            Button {
                if section == .prompts {
                    restoreCurrentTab()
                } else {
                    apply(.balanced)
                }
            } label: {
                Text(section == .prompts
                     ? "rag.workspace.prompt.restoreHelp"
                     : "rag.workspace.retrieval.restoreDefaults")
            }
            .font(ragFont(.body, scale: interfaceScale))
            Button("common.cancel") { dismiss() }
                .font(ragFont(.body, scale: interfaceScale))
            Button("rag.workspace.prompt.save") {
                if section == .prompts {
                    settings.ragPromptSettings = draft
                }
                dismiss()
            }
            .font(ragFont(.body, scale: interfaceScale))
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, interfaceScale.scaled(20))
        .padding(.vertical, interfaceScale.scaled(12))
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

    private var promptSettingsContent: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            HStack(spacing: interfaceScale.scaled(12)) {
                Picker("rag.workspace.prompt.title", selection: $tab) {
                    ForEach(RAGPromptEditorTab.allCases) { item in
                        Text(item.titleKey).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                ResetIconButton(
                    help: Text("rag.workspace.prompt.restoreHelp"),
                    font: interfaceScale.font(size: 13, weight: .medium),
                    frameSize: interfaceScale.scaled(20)
                ) {
                    restoreCurrentTab()
                }
            }

            promptEditor(
                titleKey: "rag.workspace.prompt.system",
                text: systemBinding,
                minHeight: interfaceScale.scaled(190)
            )
            .layoutPriority(1)

            promptEditor(
                titleKey: "rag.workspace.prompt.user",
                text: userBinding,
                minHeight: interfaceScale.scaled(108)
            )
        }
    }

    private var retrievalSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
                retrievalGroup(titleKey: "rag.workspace.retrieval.preset.title") {
                    presetPicker
                }
                retrievalGroup(titleKey: "rag.workspace.retrieval.common.title") {
                    retrievalCommonSection
                }
                retrievalGroup(titleKey: "rag.workspace.retrieval.advanced.title") {
                    retrievalAdvancedSection
                }
                retrievalGroup(titleKey: "rag.workspace.retrieval.sources.title") {
                    retrievalSourcesSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // overlay 滚动条盖住右缘控件；尾部 gutter 让数字框 / picker 仍可点。
            .padding(.trailing, interfaceScale.scaled(RAGSettingsSheetMetrics.scrollTrailerGutter))
            .padding(.bottom, interfaceScale.scaled(8))
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
    }

    /// 与 AI 索引阈值同款：四档 segmented，避免卡片标题「预设」再叠一行同名 label。
    private var presetPicker: some View {
        Picker("rag.workspace.retrieval.preset.title", selection: retrievalPresetBinding) {
            ForEach(RAGRetrievalPreset.allCases) { preset in
                Text(preset.titleKey).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private var retrievalCommonSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
                settingRow(
                    titleKey: "rag.workspace.retrieval.minimumSimilarity",
                    value: String(format: "%.2f", minimumVectorSimilarity)
                )
                Slider(value: similarityBinding, in: 0.00...1.00, step: 0.01)
                    .controlSize(.small)
                Text("rag.workspace.retrieval.minimumSimilarity.hint")
                    .font(ragFont(.caption2, scale: interfaceScale))
                    .foregroundStyle(.secondary)
            }
            Divider()
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.finalChunkLimit",
                hintKey: "rag.workspace.retrieval.finalChunkLimit.hint",
                text: finalEvidenceChunkLimitBinding
            )
        }
    }

    private var retrievalAdvancedSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.perRepositoryLimit",
                hintKey: "rag.workspace.retrieval.perRepositoryLimit.hint",
                text: perRepositoryEvidenceLimitBinding
            )
            Divider()
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.tokenBudget",
                hintKey: "rag.workspace.retrieval.tokenBudget.hint",
                text: evidenceTokenBudgetBinding
            )
        }
    }

    /// 四个来源固定单行；窗口已收窄，间距压紧以免折行。
    private var retrievalSourcesSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            Text("rag.workspace.retrieval.sources.hint")
                .font(ragFont(.caption2, scale: interfaceScale))
                .foregroundStyle(.secondary)
            HStack(spacing: interfaceScale.scaled(14)) {
                Toggle("rag.workspace.retrieval.source.readme", isOn: $includesReadme)
                Toggle("rag.workspace.retrieval.source.notes", isOn: $includesNotes)
                Toggle("rag.workspace.retrieval.source.summary", isOn: $includesSummary)
                Toggle("rag.workspace.retrieval.source.metadata", isOn: $includesMetadata)
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
            .font(ragFont(.callout, scale: interfaceScale))
        }
    }

    private func retrievalGroup<Content: View>(
        titleKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            sectionTitle(titleKey)
            content()
                .padding(interfaceScale.scaled(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.48),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }

    private var similarityBinding: Binding<Double> {
        Binding(
            get: { minimumVectorSimilarity },
            set: { value in
                minimumVectorSimilarity = value
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var retrievalPresetBinding: Binding<RAGRetrievalPreset> {
        Binding(
            get: { retrievalPreset },
            set: { apply($0) }
        )
    }

    private var finalEvidenceChunkLimitBinding: Binding<String> {
        Binding(
            get: { finalEvidenceChunkLimit },
            set: { newValue in
                finalEvidenceChunkLimit = newValue
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var perRepositoryEvidenceLimitBinding: Binding<String> {
        Binding(
            get: { perRepositoryEvidenceLimit },
            set: { newValue in
                perRepositoryEvidenceLimit = newValue
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var evidenceTokenBudgetBinding: Binding<String> {
        Binding(
            get: { evidenceTokenBudget },
            set: { newValue in
                evidenceTokenBudget = newValue
                markRetrievalCustomIfNeeded()
            }
        )
    }

    /// 预设切换程序化写字段期间禁止误标自定义。
    private func markRetrievalCustomIfNeeded() {
        guard !isApplyingRetrievalPreset else { return }
        if retrievalPreset != .custom {
            retrievalPreset = .custom
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func settingRow(titleKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(titleKey)
                .font(ragFont(.callout, scale: interfaceScale, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: interfaceScale.scaled(12))
            Text(value)
                .font(interfaceScale.font(.code, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func settingTextFieldRow(
        titleKey: LocalizedStringKey,
        hintKey: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(12)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleKey)
                    .font(ragFont(.callout, scale: interfaceScale, weight: .medium))
                    .foregroundStyle(.primary)
                Text(hintKey)
                    .font(ragFont(.caption2, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: interfaceScale.scaled(12))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.code))
                .frame(width: interfaceScale.scaled(80))
                .multilineTextAlignment(.trailing)
        }
    }

    private func apply(_ preset: RAGRetrievalPreset) {
        guard preset != .custom else {
            retrievalPreset = .custom
            return
        }

        // 先抬门闩再写字段：否则 TextField Binding.set 会立刻把 preset 踢回 custom。
        isApplyingRetrievalPreset = true
        switch preset {
        case .balanced:
            minimumVectorSimilarity = 0.65
            finalEvidenceChunkLimit = "8"
            perRepositoryEvidenceLimit = "3"
            evidenceTokenBudget = "8000"
        case .strict:
            minimumVectorSimilarity = 0.75
            finalEvidenceChunkLimit = "5"
            perRepositoryEvidenceLimit = "2"
            evidenceTokenBudget = "6000"
        case .broad:
            minimumVectorSimilarity = 0.55
            finalEvidenceChunkLimit = "10"
            perRepositoryEvidenceLimit = "4"
            evidenceTokenBudget = "12000"
        case .custom:
            break
        }
        retrievalPreset = preset
        // 投递到下一轮主队列再放行：同帧内可能还有 onChange / Binding 扫尾。
        Task { @MainActor in
            isApplyingRetrievalPreset = false
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
