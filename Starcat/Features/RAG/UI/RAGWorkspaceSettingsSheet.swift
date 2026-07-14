//
//  RAGWorkspaceSettingsSheet.swift
//  Starcat
//
//  RAG 工作台配置 Sheet：提示词与检索策略共用一个入口。
//  提示词写入 `AppSettings.ragPromptSettings`；检索写入
//  `AppSettings.ragRetrievalSettings`（UserDefaults JSON），下一轮问答由
//  `makeKnowledgeRAGService` 读入生效。
//
//  UI（2026-07-13）：
//  - System 吃主要高度、User 次之；重置放在 segmented 右侧。
//  - 字号直接读 `settings.interfaceScale`（与独立窗口同一档位），不只缩放外框。
//  - 占位符说明收进 popover，避免底部一长串 token 且无含义。
//  - 2026-07-14：一行 4 段 segmented（问答 / 规划 / 压缩 / 标题）。
//  - 2026-07-14：增加提示词 / 检索一级分段。
//  - 2026-07-14：检索页对齐「侧栏 + 内容卡片」；预设切换静默写字段；保存持久化。
//  - 2026-07-14：由 PromptSettingsSheet 重命名为 SettingsSheet。
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

    /// UI 档位 → 持久化模型；`.custom` 无固定表。
    var builtInSettings: RAGRetrievalSettings? {
        switch self {
        case .balanced: return .balanced
        case .strict: return .strict
        case .broad: return .broad
        case .custom: return nil
        }
    }

    /// 与三档内置完全一致（含 enabledSources）才算命中，否则一律自定义。
    static func matching(settings: RAGRetrievalSettings) -> RAGRetrievalPreset {
        let normalized = settings.normalized()
        if normalized == .balanced { return .balanced }
        if normalized == .strict { return .strict }
        if normalized == .broad { return .broad }
        return .custom
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
                .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "rag.workspace.prompt.placeholder.outputLanguage"),
                .init(token: "{questionSection}", systemImage: "text.bubble", meaningKey: "rag.workspace.prompt.placeholder.questionSection"),
                .init(token: "{evidenceSection}", systemImage: "doc.text.magnifyingglass", meaningKey: "rag.workspace.prompt.placeholder.evidenceSection"),
                .init(token: "{remoteSection}", systemImage: "network", meaningKey: "rag.workspace.prompt.placeholder.remoteSection"),
                .init(token: "{attachmentSection}", systemImage: "paperclip", meaningKey: "rag.workspace.prompt.placeholder.attachmentSection"),
            ]
        case .planner:
            return [
                .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "rag.workspace.prompt.placeholder.outputLanguagePlanner"),
                .init(token: "{question}", systemImage: "text.bubble", meaningKey: "rag.workspace.prompt.placeholder.question"),
                .init(token: "{explicitRepositories}", systemImage: "building.2", meaningKey: "rag.workspace.prompt.placeholder.explicitRepositories"),
                .init(token: "{explicitRepoMode}", systemImage: "switch.2", meaningKey: "rag.workspace.prompt.placeholder.explicitRepoMode"),
                .init(token: "{attachmentDescriptors}", systemImage: "paperclip", meaningKey: "rag.workspace.prompt.placeholder.attachmentDescriptors"),
                .init(token: "{pastedGitHubLinks}", systemImage: "link", meaningKey: "rag.workspace.prompt.placeholder.pastedGitHubLinks"),
                .init(token: "{previousUserQuestion}", systemImage: "arrow.uturn.backward", meaningKey: "rag.workspace.prompt.placeholder.previousUserQuestion"),
                .init(token: "{previousReferencedRepositories}", systemImage: "clock.arrow.circlepath", meaningKey: "rag.workspace.prompt.placeholder.previousReferencedRepositories"),
            ]
        case .compressor:
            return [
                .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "rag.workspace.prompt.placeholder.outputLanguageCompressor"),
                .init(token: "{existingSummarySection}", systemImage: "doc.text", meaningKey: "rag.workspace.prompt.placeholder.existingSummarySection"),
                .init(token: "{newMessagesSection}", systemImage: "text.badge.plus", meaningKey: "rag.workspace.prompt.placeholder.newMessagesSection"),
            ]
        case .title:
            return [
                .init(token: "{outputLanguage}", systemImage: "globe", meaningKey: "rag.workspace.prompt.placeholder.outputLanguageTitle"),
                .init(token: "{firstQuestion}", systemImage: "text.bubble", meaningKey: "rag.workspace.prompt.placeholder.firstQuestion"),
            ]
        }
    }
}

/// 占位符条目：token 原文 + SF Symbol + 含义 i18n key。
private struct RAGPromptPlaceholderItem: Identifiable {
    let token: String
    let systemImage: String
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
    /// Sheet 内草稿；点「保存」才写入 `AppSettings.ragRetrievalSettings`。
    @State private var retrievalPreset: RAGRetrievalPreset
    @State private var minimumVectorSimilarity: Double
    @State private var finalEvidenceChunkLimit: String
    @State private var perRepositoryEvidenceLimit: String
    @State private var evidenceTokenBudget: String
    @State private var includesReadme: Bool
    @State private var includesNotes: Bool
    @State private var includesSummary: Bool
    @State private var includesMetadata: Bool
    @State private var rerankEnabled: Bool
    @State private var rerankProvider: RAGRerankProvider
    @State private var rerankEndpoint: String
    @State private var rerankModel: String
    @State private var rerankAPIKey: String
    @State private var rerankCandidateLimit: String
    @State private var rerankCredentialError: String?
    /// `apply(_:)` 写字段期间抬起，挡住误判「自定义」；用户手动拖滑杆 / 改数字时则放行。
    @State private var isApplyingRetrievalPreset = false

    init(settings: AppSettings) {
        self.settings = settings
        _draft = State(initialValue: settings.ragPromptSettings)
        let retrieval = settings.ragRetrievalSettings.normalized()
        _retrievalPreset = State(initialValue: RAGRetrievalPreset.matching(settings: retrieval))
        _minimumVectorSimilarity = State(initialValue: retrieval.minimumVectorSimilarity)
        _finalEvidenceChunkLimit = State(initialValue: String(retrieval.finalEvidenceChunkLimit))
        _perRepositoryEvidenceLimit = State(initialValue: String(retrieval.perRepositoryEvidenceLimit))
        _evidenceTokenBudget = State(initialValue: String(retrieval.evidenceTokenBudget))
        _includesReadme = State(initialValue: retrieval.enabledSources.contains(.readme))
        _includesNotes = State(initialValue: retrieval.enabledSources.contains(.notes))
        _includesSummary = State(initialValue: retrieval.enabledSources.contains(.summary))
        _includesMetadata = State(initialValue: retrieval.enabledSources.contains(.metadata))
        let rerank = settings.ragRerankConfiguration.normalized
        _rerankEnabled = State(initialValue: rerank.isEnabled)
        _rerankProvider = State(initialValue: rerank.provider)
        _rerankEndpoint = State(initialValue: rerank.endpoint)
        _rerankModel = State(initialValue: rerank.model)
        _rerankAPIKey = State(initialValue: (try? KeychainManager.shared.loadAIKey(
            forProvider: RAGRerankConfiguration.keychainID
        )) ?? "")
        _rerankCandidateLimit = State(initialValue: String(rerank.candidateLimit))
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
            // 侧栏顶栏是整页标题，不是和「提示词 / 检索」同级的导航项；字号跟右侧 detailHeader 对齐。
            HStack(spacing: interfaceScale.scaled(8)) {
                Image(systemName: "gearshape")
                    .font(interfaceScale.font(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: interfaceScale.scaled(18))
                    .accessibilityHidden(true)
                Text("rag.workspace.settings.title")
                    .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, interfaceScale.scaled(8))

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
            // 恢复默认已放到各页 segmented 右侧的 ResetIconButton，底栏不再重复。
            Button("common.cancel") { dismiss() }
                .font(ragFont(.body, scale: interfaceScale))
            Button("rag.workspace.prompt.save") {
                // 两个分区共用同一草稿生命周期：无论停在哪一栏，保存都一并写入。
                // 未启用 Rerank 时不碰 Keychain，避免仅保存提示词/检索草稿时意外覆盖已有 Token。
                guard !rerankEnabled || saveRerankAPIKey() else { return }
                settings.ragPromptSettings = draft
                settings.ragRetrievalSettings = buildRetrievalSettings()
                settings.ragRerankConfiguration = buildRerankConfiguration()
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
        VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
            settingsGroup(
                titleKey: "rag.workspace.prompt.type.title",
                systemImage: "text.quote"
            ) {
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
                settingsGroup(
                    titleKey: "rag.workspace.retrieval.preset.title",
                    systemImage: "slider.horizontal.3"
                ) {
                    presetPicker
                }
                settingsGroup(
                    titleKey: "rag.workspace.retrieval.common.title",
                    systemImage: "line.3.horizontal.decrease.circle"
                ) {
                    retrievalCommonSection
                }
                settingsGroup(
                    titleKey: "rag.workspace.retrieval.advanced.title",
                    systemImage: "gearshape.2"
                ) {
                    retrievalAdvancedSection
                }
                settingsGroup(
                    titleKey: "rag.workspace.retrieval.sources.title",
                    systemImage: "cylinder.split.1x2"
                ) {
                    retrievalSourcesSection
                }
                settingsGroup(
                    titleKey: "rag.workspace.rerank.title",
                    systemImage: "arrow.up.arrow.down.circle"
                ) {
                    rerankSection
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

    /// 与提示词页同款：预设 segmented + 右侧重置；点击恢复平衡档草稿（未点保存不落盘）。
    private var presetPicker: some View {
        HStack(spacing: interfaceScale.scaled(12)) {
            Picker("rag.workspace.retrieval.preset.title", selection: retrievalPresetBinding) {
                ForEach(RAGRetrievalPreset.allCases) { preset in
                    Text(preset.titleKey).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            ResetIconButton(
                help: Text("rag.workspace.retrieval.restoreDefaults"),
                font: interfaceScale.font(size: 13, weight: .medium),
                frameSize: interfaceScale.scaled(20)
            ) {
                apply(.balanced)
            }
        }
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

    /// Rerank 服务由用户自行配置；关闭时保留协议、地址和模型，方便临时停用后再次启用。
    private var rerankSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
            Toggle("rag.workspace.rerank.enabled", isOn: $rerankEnabled)
                .font(ragFont(.body, scale: interfaceScale, weight: .medium))
            Text("rag.workspace.rerank.enabled.hint")
                .font(ragFont(.caption2, scale: interfaceScale))
                .foregroundStyle(.secondary)
            if rerankEnabled {
                Divider()
                Picker("rag.workspace.rerank.provider", selection: $rerankProvider) {
                    Text("rag.workspace.rerank.provider.tei").tag(RAGRerankProvider.huggingFaceTEI)
                    Text("rag.workspace.rerank.provider.cohere").tag(RAGRerankProvider.cohereCompatible)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: rerankProvider) { previous, current in
                    // 仅在用户未改过默认地址时切换，手动填写的自托管地址不能被静默覆盖。
                    if rerankEndpoint == previous.defaultEndpoint {
                        rerankEndpoint = current.defaultEndpoint
                    }
                }
                Divider()
                // URL 往往很长：输入框吃满标题右侧到容器右缘，溢出只水平滚动不换行。
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.endpoint",
                    hintKey: "rag.workspace.rerank.endpoint.hint",
                    text: $rerankEndpoint,
                    expandsToTrailingEdge: true
                )
                if rerankProvider == .cohereCompatible {
                    Divider()
                    settingTextFieldRow(
                        titleKey: "rag.workspace.rerank.model",
                        hintKey: "rag.workspace.rerank.model.hint",
                        text: $rerankModel,
                        expandsToTrailingEdge: true
                    )
                }
                Divider()
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.apiKey",
                    hintKey: "rag.workspace.rerank.apiKey.hint",
                    text: $rerankAPIKey,
                    expandsToTrailingEdge: true,
                    isSecure: true
                )
                Divider()
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.candidateLimit",
                    hintKey: "rag.workspace.rerank.candidateLimit.hint",
                    text: rerankCandidateLimitBinding
                )
                if let rerankCredentialError {
                    Text(rerankCredentialError)
                        .font(ragFont(.caption2, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 四个来源各占一行，英文长标签不会被挤成省略号。
    private var retrievalSourcesSection: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
            Text("rag.workspace.retrieval.sources.hint")
                .font(ragFont(.caption2, scale: interfaceScale))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
                sourceToggle(
                    source: .readme,
                    titleKey: "rag.workspace.retrieval.source.readme",
                    isOn: includesReadmeBinding
                )
                sourceToggle(
                    source: .notes,
                    titleKey: "rag.workspace.retrieval.source.notes",
                    isOn: includesNotesBinding
                )
                sourceToggle(
                    source: .summary,
                    titleKey: "rag.workspace.retrieval.source.summary",
                    isOn: includesSummaryBinding
                )
                sourceToggle(
                    source: .metadata,
                    titleKey: "rag.workspace.retrieval.source.metadata",
                    isOn: includesMetadataBinding
                )
            }
        }
    }

    private func sourceToggle(
        source: RAGChunkSource,
        titleKey: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            // 与 `RAGWorkspaceInspector` 证据卡同款：11pt semibold + source.tintColor。
            HStack(spacing: 5) {
                Image(systemName: source.systemImageName)
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                    .foregroundStyle(source.tintColor)
                Text(titleKey)
                    .font(ragFont(.callout, scale: interfaceScale))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
    }

    private func settingsGroup<Content: View>(
        titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
            HStack(spacing: interfaceScale.scaled(6)) {
                // 分类标题旁只放默认色图标，不加色块底，避免设置页过花。
                Image(systemName: systemImage)
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: interfaceScale.scaled(14))
                    .accessibilityHidden(true)
                sectionTitle(titleKey)
                Spacer(minLength: 0)
            }
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
                finalEvidenceChunkLimit = Self.filteredChunkLimitDigits(newValue)
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var perRepositoryEvidenceLimitBinding: Binding<String> {
        Binding(
            get: { perRepositoryEvidenceLimit },
            set: { newValue in
                perRepositoryEvidenceLimit = Self.filteredChunkLimitDigits(newValue)
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var evidenceTokenBudgetBinding: Binding<String> {
        Binding(
            get: { evidenceTokenBudget },
            set: { newValue in
                evidenceTokenBudget = Self.filteredTokenBudgetDigits(newValue)
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var rerankCandidateLimitBinding: Binding<String> {
        Binding(
            get: { rerankCandidateLimit },
            set: { newValue in
                rerankCandidateLimit = newValue.filter(\.isNumber)
            }
        )
    }

    private var includesReadmeBinding: Binding<Bool> {
        sourceToggleBinding(get: { includesReadme }, set: { includesReadme = $0 })
    }

    private var includesNotesBinding: Binding<Bool> {
        sourceToggleBinding(get: { includesNotes }, set: { includesNotes = $0 })
    }

    private var includesSummaryBinding: Binding<Bool> {
        sourceToggleBinding(get: { includesSummary }, set: { includesSummary = $0 })
    }

    private var includesMetadataBinding: Binding<Bool> {
        sourceToggleBinding(get: { includesMetadata }, set: { includesMetadata = $0 })
    }

    private func sourceToggleBinding(
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: get,
            set: { newValue in
                set(newValue)
                markRetrievalCustomIfNeeded()
            }
        )
    }

    /// 用当前草稿反推 UI 档位：与三档内置完全一致才显示对应档，否则自定义。
    private func markRetrievalCustomIfNeeded() {
        guard !isApplyingRetrievalPreset else { return }
        retrievalPreset = RAGRetrievalPreset.matching(settings: buildRetrievalSettings())
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

    /// - Parameter expandsToTrailingEdge: 为 true 时输入框从标题右侧铺满到容器右缘（URL / 模型名等长文本）；
    ///   默认 false 保持短数字框（证据上限 / Token 预算 / 候选数等）。
    @ViewBuilder
    private func settingTextFieldRow(
        titleKey: LocalizedStringKey,
        hintKey: LocalizedStringKey,
        text: Binding<String>,
        expandsToTrailingEdge: Bool = false,
        isSecure: Bool = false
    ) -> some View {
        if expandsToTrailingEdge {
            // 长文本：标题与输入框同一行，说明放整行下方，避免长 hint 挤占输入宽度。
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(12)) {
                    Text(titleKey)
                        .font(ragFont(.callout, scale: interfaceScale, weight: .medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: false)
                    if isSecure {
                        SecureField("", text: text)
                            .textFieldStyle(.roundedBorder)
                            .font(interfaceScale.font(.code))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: text)
                            .textFieldStyle(.roundedBorder)
                            .font(interfaceScale.font(.code))
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(hintKey)
                    .font(ragFont(.caption2, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
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
                if isSecure {
                    SecureField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(interfaceScale.font(.code))
                        .lineLimit(1)
                        .frame(width: interfaceScale.scaled(80), alignment: .trailing)
                } else {
                    TextField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(interfaceScale.font(.code))
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .frame(width: interfaceScale.scaled(80), alignment: .trailing)
                }
            }
        }
    }

    /// 把当前 UI 草稿收成持久化模型；非法数字回落到草稿对应项 / 平衡档默认。
    private func buildRetrievalSettings() -> RAGRetrievalSettings {
        var sources = Set<RAGChunkSource>()
        if includesReadme { sources.insert(.readme) }
        if includesNotes { sources.insert(.notes) }
        if includesSummary { sources.insert(.summary) }
        if includesMetadata { sources.insert(.metadata) }

        return RAGRetrievalSettings(
            minimumVectorSimilarity: minimumVectorSimilarity,
            finalEvidenceChunkLimit: parseInt(
                finalEvidenceChunkLimit,
                fallback: RAGRetrievalSettings.balanced.finalEvidenceChunkLimit
            ),
            perRepositoryEvidenceLimit: parseInt(
                perRepositoryEvidenceLimit,
                fallback: RAGRetrievalSettings.balanced.perRepositoryEvidenceLimit
            ),
            evidenceTokenBudget: parseInt(
                evidenceTokenBudget,
                fallback: RAGRetrievalSettings.balanced.evidenceTokenBudget
            ),
            enabledSources: sources
        ).normalized()
    }

    private func buildRerankConfiguration() -> RAGRerankConfiguration {
        RAGRerankConfiguration(
            isEnabled: rerankEnabled,
            provider: rerankProvider,
            endpoint: rerankEndpoint,
            model: rerankModel,
            candidateLimit: parseInt(rerankCandidateLimit, fallback: 24)
        ).normalized
    }

    /// Token 只在用户点击保存时写入 Keychain；不跟随草稿写入 UserDefaults，也不会出现在 Debug Trace。
    private func saveRerankAPIKey() -> Bool {
        do {
            let value = rerankAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                try KeychainManager.shared.deleteAIKey(forProvider: RAGRerankConfiguration.keychainID)
            } else {
                try KeychainManager.shared.storeAIKey(value, forProvider: RAGRerankConfiguration.keychainID)
            }
            rerankCredentialError = nil
            return true
        } catch {
            rerankCredentialError = error.localizedDescription
            return false
        }
    }

    private func parseInt(_ text: String, fallback: Int) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? fallback
    }

    /// 分片上限输入：只留数字；按已输入值钳到 1…50 再回写。
    private static func filteredChunkLimitDigits(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        guard let value = Int(digits) else { return digits }
        return String(min(max(value, 1), 50))
    }

    /// Token 预算：仅数字；输入中只顶住上限 1_024_000，下限 2000 留给保存时 `normalized()`。
    private static func filteredTokenBudgetDigits(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        guard let value = Int(digits) else { return digits }
        return String(min(value, 1_024_000))
    }

    private func hydrate(from retrieval: RAGRetrievalSettings) {
        let normalized = retrieval.normalized()
        minimumVectorSimilarity = normalized.minimumVectorSimilarity
        finalEvidenceChunkLimit = String(normalized.finalEvidenceChunkLimit)
        perRepositoryEvidenceLimit = String(normalized.perRepositoryEvidenceLimit)
        evidenceTokenBudget = String(normalized.evidenceTokenBudget)
        includesReadme = normalized.enabledSources.contains(.readme)
        includesNotes = normalized.enabledSources.contains(.notes)
        includesSummary = normalized.enabledSources.contains(.summary)
        includesMetadata = normalized.enabledSources.contains(.metadata)
    }

    private func apply(_ preset: RAGRetrievalPreset) {
        guard let builtIn = preset.builtInSettings else {
            retrievalPreset = .custom
            return
        }

        // 先抬门闩再写字段：否则 Binding.set 会立刻把 preset 踢回 custom。
        isApplyingRetrievalPreset = true
        hydrate(from: builtIn)
        retrievalPreset = preset
        // 投递到下一轮主队列再放行：同帧内可能还有 Binding 扫尾。
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
            HStack(spacing: interfaceScale.scaled(6)) {
                Image(systemName: "curlybraces")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.workspace.prompt.placeholders.title")
                    .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: interfaceScale.scaled(8)) {
                        // 与设置分组同款：默认色图标，不抢 token 阅读。
                        Image(systemName: item.systemImage)
                            .font(interfaceScale.font(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: interfaceScale.scaled(14), alignment: .center)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
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
