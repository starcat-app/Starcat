//
//  RAGWorkspaceSettingsView.swift
//  Starcat
//
//  RAG 工作台设置内容：推理与检索使用主设置分类，提示词通过推理页的弹窗编辑。
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
//  - 2026-09-01：由工作台内 Sheet 改为 App 级原生设置窗口。
//  - 2026-09-01：并入主设置的独立一级分类；旧窗口在验收前继续保留。
//  - 2026-10-25：原生 grouped Form 承载推理与检索，提示词弹窗沿用原草稿和自动保存。
//

import SwiftUI

/// 同一份设置草稿由主设置 Sidebar 承载，避免复制业务状态或产生双写。
enum RAGWorkspaceSettingsPresentation {
    /// 原 RAG 分类直接由主设置 Sidebar 驱动，不再提供自己的二级侧栏。
    case embeddedInMainSettings(section: RAGSettingsSection)
}

/// 主设置采用自动保存后，Rerank 凭据不能在每次按键时同步写入加密文件。
/// actor 保证防抖后的写入严格串行，避免较早任务反而覆盖用户最后输入的值。
private actor RAGRerankCredentialAutoSaver {
    static let shared = RAGRerankCredentialAutoSaver()

    func persist(_ value: String) -> String? {
        do {
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedValue.isEmpty {
                try KeychainManager.shared.deleteAIKey(forProvider: RAGRerankConfiguration.keychainID)
            } else {
                try KeychainManager.shared.storeAIKey(
                    normalizedValue,
                    forProvider: RAGRerankConfiguration.keychainID
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum RAGSettingsSection: String, CaseIterable, Identifiable {
    case inference
    case retrieval

    var id: String { rawValue }

    var titleKeyString: String {
        switch self {
        case .inference: return "rag.workspace.settings.section.inference"
        case .retrieval: return "rag.workspace.settings.section.retrieval"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }

    var introductionKey: LocalizedStringKey {
        switch self {
        case .inference: return "rag.settings.inference.introduction"
        case .retrieval: return "rag.settings.retrieval.introduction"
        }
    }

    /// 提示词关键词仍定位推理页，具体弹窗由主设置导航处理。
    var searchKeywords: [String] {
        switch self {
        case .inference: return ["inference", "backend", "cli", "codex", "claude", "推理", "后端",
                                 "prompt", "system", "user", "template", "提示词", "模板"]
        case .retrieval: return ["retrieval", "rerank", "evidence", "vector", "meilisearch", "qdrant", "检索", "重排", "证据", "自托管"]
        }
    }

    var businessIcon: BusinessIcon.Symbol {
        switch self {
        case .inference: return .inference
        case .retrieval: return .retrieval
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
                .init(token: "{repositoryInsightsSection}", systemImage: "gauge.with.dots.needle.bottom.0percent", meaningKey: "rag.workspace.prompt.placeholder.repositoryInsightsSection"),
                .init(token: "{repoContextSection}", systemImage: BusinessIcon.Symbol.codeContext.systemImage, meaningKey: "rag.workspace.prompt.placeholder.repoContextSection"),
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
                .init(token: "{webSearchEnabled}", systemImage: "network", meaningKey: "rag.workspace.prompt.placeholder.webSearchEnabled"),
                .init(token: "{deepThinkingEnabled}", systemImage: "brain.head.profile", meaningKey: "rag.workspace.prompt.placeholder.deepThinkingEnabled"),
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

    var defaultConfiguration: AIPromptConfiguration {
        switch self {
        case .generator: return RAGDefaultPrompts.generator
        case .planner: return RAGDefaultPrompts.planner
        case .compressor: return RAGDefaultPrompts.compressor
        case .title: return RAGDefaultPrompts.title
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

struct RAGWorkspaceSettingsView: View {
    @Environment(\.locale) private var locale
    @Bindable var settings: AppSettings
    let presentation: RAGWorkspaceSettingsPresentation
    @Binding var isPromptEditorPresented: Bool
    @State private var tab: RAGPromptEditorTab = .generator
    @State private var draft: RAGPromptSettings
    /// CLI 只在 Direct 版可选；App Store 即使从旧偏好读到 CLI，也先归一成 API 草稿。
    @State private var inferenceBackend: RAGInferenceBackend
    @State private var codexRuntimeInspection: RAGCLIRuntimeInspection = .checking
    @State private var claudeRuntimeInspection: RAGCLIRuntimeInspection = .checking
    @State private var isInspectingCLIRuntimes = false
    @State private var isPlaceholderPopoverPresented = false
    @State private var isDefaultPromptPopoverPresented = false
    @State private var hasCheckedPrompt = false
    @State private var isPromptCompatibilityPresented = false
    /// 独立窗口保留显式提交；嵌入主设置时通过 `onChange` 自动写入。
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
    /// 安全凭据读取是文件解密 IO，不能放在 SwiftUI View.init 里阻塞设置分类切换。
    @State private var hasLoadedRerankAPIKey = false
    /// 异步读取返回前若用户已开始输入，旧凭据不能覆盖新草稿。
    @State private var hasEditedRerankAPIKey = false
    /// 主设置自动保存使用的防抖任务；独立验收窗口仍走显式「保存」。
    @State private var rerankAPIKeyAutoSaveTask: Task<Void, Never>?
    @State private var rerankCandidateLimit: String
    @State private var rerankCredentialError: String?
    @State private var isSavingRerankCredential = false
    @State private var hasSavedRerankCredential = false
    @State private var isSourcesExpanded = false
    /// `apply(_:)` 写字段期间抬起，挡住误判「自定义」；用户手动拖滑杆 / 改数字时则放行。
    @State private var isApplyingRetrievalPreset = false

    init(
        settings: AppSettings,
        presentation: RAGWorkspaceSettingsPresentation,
        isPromptEditorPresented: Binding<Bool>
    ) {
        self.settings = settings
        self.presentation = presentation
        _isPromptEditorPresented = isPromptEditorPresented
        _draft = State(initialValue: settings.ragPromptSettings)
        let availableBackends = RAGInferenceBackend.available(using: DistributionGate())
        _inferenceBackend = State(initialValue:
            availableBackends.contains(settings.ragInferenceBackend) ? settings.ragInferenceBackend : .api
        )
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
        _rerankAPIKey = State(initialValue: "")
        _rerankCandidateLimit = State(initialValue: String(rerank.candidateLimit))
    }

    /// 设置档位仍控制间距与编辑器尺寸；文字统一使用主设置的系统语义字号。
    private var interfaceScale: InterfaceScale { settings.interfaceScale }

    private var availableInferenceBackends: [RAGInferenceBackend] {
        RAGInferenceBackend.available(using: DistributionGate())
    }

    @ViewBuilder
    var body: some View {
        if case .embeddedInMainSettings(let section) = presentation {
            embeddedSettingsPage(section: section)
                .environment(\.starcatInterfaceScale, interfaceScale)
        }
    }

    /// 推理与检索共用原草稿，提示词 Sheet 只改变编辑入口，不复制配置或新增保存流程。
    private func embeddedSettingsPage(section: RAGSettingsSection) -> some View {
        // 背景与行间距交给系统 Form，避免自绘卡片让深色底色偏亮。
        Form {
            introductionSection(section)
            switch section {
            case .inference:
                inferenceSettingsSections
                promptSettingsSection
            case .retrieval:
                retrievalSettingsSections
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isPromptEditorPresented) {
            promptEditorSheet
                .appLocaleEnvironment()
        }
        .task(id: section) {
            await loadRerankAPIKeyIfNeeded()
            if section == .inference {
                await inspectCLIRuntimes()
            }
        }
        .onScrollPhaseChange { _, newPhase in
            guard newPhase != .idle else { return }
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented = false
        }
        .onChange(of: tab) { _, _ in
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented = false
            hasCheckedPrompt = false
            isPromptCompatibilityPresented = false
        }
        .onChange(of: isPromptEditorPresented) { _, _ in
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented = false
            isPromptCompatibilityPresented = false
            hasCheckedPrompt = false
        }
        .onChange(of: section) { _, _ in
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented = false
        }
        // 主设置遵循系统设置的即时生效语义；字段变化自动写入。
        .onChange(of: inferenceBackend) { _, newValue in
            settings.ragInferenceBackend = newValue
        }
        .onChange(of: draft) { _, newValue in
            settings.ragPromptSettings = newValue
            hasCheckedPrompt = false
            isPromptCompatibilityPresented = false
        }
        .onChange(of: buildRetrievalSettings()) { _, newValue in
            settings.ragRetrievalSettings = newValue
        }
        .onChange(of: buildRerankConfiguration()) { _, newValue in
            settings.ragRerankConfiguration = newValue
        }
        .onChange(of: rerankAPIKey) { _, _ in
            guard hasEditedRerankAPIKey else { return }
            scheduleRerankAPIKeyAutoSave()
        }
        .onDisappear {
            // 用户输入后立刻离开 RAG 分类时，取消等待并立即排入串行写入队列。
            guard hasEditedRerankAPIKey else { return }
            scheduleRerankAPIKeyAutoSave(delayNanoseconds: 0)
        }
    }

    /// 一级页面使用与翻译、联网搜索相同的原生介绍卡片。
    private func introductionSection(_ section: RAGSettingsSection) -> some View {
        return Section {
            HStack(spacing: 16) {
                BusinessIcon(section.businessIcon, pointSize: 28)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.titleKey)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text(section.titleKey))
                    Text(section.introductionKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text(section.introductionKey))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    /// 加密凭据文件读取放到后台任务；主线程先完成页面切换和首帧布局。
    /// `KeychainManager` 内部以 NSLock 保护文件读写，并声明为 Sendable，可安全跨任务读取。
    @MainActor
    private func loadRerankAPIKeyIfNeeded() async {
        guard !hasLoadedRerankAPIKey else { return }
        let storedValue = await Task.detached(priority: .userInitiated) {
            (try? KeychainManager.shared.loadAIKey(
                forProvider: RAGRerankConfiguration.keychainID
            )) ?? ""
        }.value
        guard !Task.isCancelled else { return }
        if !hasEditedRerankAPIKey {
            rerankAPIKey = storedValue
        }
        hasLoadedRerankAPIKey = true
    }

    /// API Key 停止输入 450ms 后自动保存；后续输入会取消仍在等待的旧任务。
    /// 真正的文件写入由 actor 串行执行，因此已经开始的旧写入也会先于新值完成。
    @MainActor
    private func scheduleRerankAPIKeyAutoSave(delayNanoseconds: UInt64 = 450_000_000) {
        rerankAPIKeyAutoSaveTask?.cancel()
        let value = rerankAPIKey
        isSavingRerankCredential = true
        hasSavedRerankCredential = false
        rerankCredentialError = nil
        rerankAPIKeyAutoSaveTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let errorMessage = await RAGRerankCredentialAutoSaver.shared.persist(value)
            guard !Task.isCancelled else { return }
            rerankCredentialError = errorMessage
            isSavingRerankCredential = false
            hasSavedRerankCredential = errorMessage == nil
        }
    }

    /// 提示词底栏入口：点开看 token + 含义，避免一行塞满无说明的占位符列表。
    private var placeholderHelpButton: some View {
        Button {
            isDefaultPromptPopoverPresented = false
            isPlaceholderPopoverPresented.toggle()
        } label: {
            Text("settings.ai.prompt.placeholders.open")
                .font(.caption.weight(.medium))
                .lineLimit(1)
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

    /// 默认 Prompt 永远只读展示；用户可以复制后自行比较，不在这里写回草稿。
    private var defaultPromptReferenceButton: some View {
        Button {
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented.toggle()
        } label: {
            Label("rag.workspace.prompt.default.open", systemImage: "doc.text.magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityLabel("rag.workspace.prompt.default.open")
        .help("rag.workspace.prompt.default.openHelp")
        .popover(isPresented: $isDefaultPromptPopoverPresented, arrowEdge: .top) {
            RAGDefaultPromptPopover(
                configuration: tab.defaultConfiguration,
                tabTitle: tab.titleKey,
                interfaceScale: interfaceScale
            )
            .appLocaleEnvironment()
        }
    }

    /// 页内仅保留状态和编辑入口，完整模板移入与翻译页同款的轻量 Sheet。
    private var promptSettingsSection: some View {
        Section {
            HStack {
                promptCompatibilityBadge(for: promptSummaryState)
                Spacer(minLength: 12)
                Button("settings.ai.models.prompt.edit") {
                    isPromptEditorPresented = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } header: {
            SettingsSectionHeader("rag.workspace.settings.section.prompts", businessIcon: .prompts)
        } footer: {
            Text("rag.settings.prompts.scope")
        }
    }

    /// 单列尺寸、分隔线与编辑区高度沿用翻译弹窗；长模板只在 TextEditor 内滚动。
    private var promptEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("rag.workspace.settings.section.prompts")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                SheetCloseButton { isPromptEditorPresented = false }
            }

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("rag.settings.prompts.mode")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("rag.settings.prompts.modeHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("rag.settings.prompts.modeHelp"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 四项任务比翻译模式更长，长译文退回原生菜单，避免挤压编辑区。
                ViewThatFits(in: .horizontal) {
                    promptTaskPicker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    promptTaskPicker
                        .pickerStyle(.menu)
                }
            }

            Divider()

            // 与翻译页相同：切换任务时重建 NSTextView，避免继续使用旧任务的编辑状态。
            VStack(alignment: .leading, spacing: 12) {
                promptEditor(title: "rag.workspace.prompt.system", text: systemBinding, height: 180)
                Divider()
                promptEditor(title: "rag.workspace.prompt.user", text: userBinding, height: 80)
            }
            .id(tab)

            HStack(spacing: 12) {
                promptCompatibilityBadge(for: promptCompatibility.state)
                    .font(.caption)
                if hasCheckedPrompt {
                    Label(
                        LocalizedStringKey(promptCompatibility.state == .limited
                            ? "rag.settings.prompts.checkLimited" : "rag.settings.prompts.checkPassed"),
                        systemImage: promptCompatibility.state == .limited
                            ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(promptCompatibility.state == .limited ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("rag.settings.prompts.check") {
                    // 沿用原分析器，只检查当前模板，不发请求或修复用户输入。
                    hasCheckedPrompt = true
                    isPromptCompatibilityPresented = promptCompatibility.state == .limited
                }
                .buttonStyle(.link)
                .help(Text("rag.settings.prompts.checkHint"))
                .popover(isPresented: $isPromptCompatibilityPresented, arrowEdge: .top) {
                    promptCompatibilityNotice
                        .padding(16)
                        .frame(width: 380)
                        .appLocaleEnvironment()
                }
            }

            Divider()

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                defaultPromptReferenceButton
                placeholderHelpButton
                ResetIconButton(help: Text("rag.workspace.prompt.restoreHelp")) {
                    restoreCurrentTab()
                }
                Button("settings.ai.models.prompt.done") {
                    isPromptEditorPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var promptTaskPicker: some View {
        Picker("rag.settings.prompts.task", selection: $tab) {
            ForEach(RAGPromptEditorTab.allCases) { task in
                Text(task.titleKey).tag(task)
            }
        }
        .labelsHidden()
        .accessibilityLabel("rag.settings.prompts.task")
    }

    /// 恢复后端卡片和直接展示的运行信息；分组继续使用 Form 的统一背景。
    private var inferenceSettingsSections: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
                    Text("rag.workspace.inference.backend.summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: interfaceScale.scaled(10)) {
                        ForEach(availableInferenceBackends) { backend in
                            RAGInferenceBackendCard(
                                backend: backend,
                                inspection: runtimeInspection(for: backend),
                                isSelected: inferenceBackend == backend,
                                interfaceScale: interfaceScale
                            ) {
                                selectInferenceBackend(backend)
                            }
                        }
                    }

                    if availableInferenceBackends.contains(where: \.isCLI) {
                        Label("rag.workspace.inference.loginNotice", systemImage: "person.badge.key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                HStack(spacing: interfaceScale.scaled(8)) {
                    SettingsSectionHeader("rag.workspace.inference.backend.title", businessIcon: .inference)
                    Spacer(minLength: 0)
                    if availableInferenceBackends.contains(where: \.isCLI) {
                        SyncIconButton(
                            isRefreshing: isInspectingCLIRuntimes,
                            disabled: isInspectingCLIRuntimes,
                            // 卡片分组 header 行比标准 Form 行紧凑：按本页 interfaceScale
                            // 收到 13pt glyph / 24×24，与分组标题图标(cpu 13pt)同层级，
                            // 不再沿用 15pt / 28×28 的标准表单口径。
                            font: interfaceScale.font(size: 13, weight: .medium),
                            frameSize: interfaceScale.scaled(24),
                            tooltip: String.l10n("rag.workspace.inference.refresh.help")
                        ) {
                            Task { await inspectCLIRuntimes() }
                        }
                        .accessibilityLabel("rag.workspace.inference.refresh.label")
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
                    Label("rag.workspace.inference.boundary.retrieval", systemImage: "checkmark.shield")
                    Label("rag.workspace.inference.boundary.tools", systemImage: "nosign")
                    Label("rag.workspace.inference.boundary.otherFeatures", systemImage: "arrow.triangle.branch")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("rag.workspace.inference.boundary.title", systemImage: "lock.shield")
            }
        }
    }

    private func runtimeInspection(for backend: RAGInferenceBackend) -> RAGCLIRuntimeInspection? {
        switch backend {
        case .api: return nil
        case .codexCLI: return codexRuntimeInspection
        case .claudeCLI: return claudeRuntimeInspection
        }
    }

    /// 未安装的 CLI 不允许新选中；若用户卸载了当前 CLI，则保留选中态并显示恢复提示，
    /// 不能静默切到 API 产生意外费用。
    private func selectInferenceBackend(_ backend: RAGInferenceBackend) {
        guard backend == .api || runtimeInspection(for: backend)?.isAvailable == true else { return }
        inferenceBackend = backend
    }

    @MainActor
    private func inspectCLIRuntimes() async {
        guard availableInferenceBackends.contains(where: \.isCLI), !isInspectingCLIRuntimes else { return }
        isInspectingCLIRuntimes = true
        codexRuntimeInspection = .checking
        claudeRuntimeInspection = .checking

        let inspector = RAGCLIRuntimeInspector()
        async let codex = inspector.inspect(.codex)
        async let claude = inspector.inspect(.claude)
        let results = await (codex, claude)
        guard !Task.isCancelled else {
            isInspectingCLIRuntimes = false
            return
        }
        codexRuntimeInspection = results.0
        claudeRuntimeInspection = results.1
        isInspectingCLIRuntimes = false
    }

    /// 预设与关联参数归为同组；这里只调整呈现，继续复用原有草稿绑定和自动保存。
    private var retrievalSettingsSections: some View {
        Group {
            retrievalSettingsGroup(
                titleKey: "settings.retrieval.strategy.title",
                systemImage: "slider.horizontal.3"
            ) {
                presetPicker
                retrievalCommonSection
                HStack(spacing: 12) {
                    Text("settings.retrieval.strategy.matching")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("settings.retrieval.strategy.restore") { apply(.balanced) }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            retrievalSettingsGroup(
                titleKey: "settings.retrieval.sources.title",
                systemImage: "cylinder.split.1x2"
            ) {
                Button {
                    isSourcesExpanded.toggle()
                } label: {
                    HStack {
                        Text("settings.retrieval.sources.contents")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(buildRetrievalSettings().enabledSources.count) / 4")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: isSourcesExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityValue(Text(LocalizedStringKey(isSourcesExpanded ? "settings.retrieval.expanded" : "settings.retrieval.collapsed")))
                if isSourcesExpanded {
                    retrievalSourcesSection
                }
            }
            retrievalSettingsGroup(
                titleKey: "settings.retrieval.rerank.title",
                systemImage: "arrow.up.arrow.down.circle"
            ) {
                rerankSection
            }
            retrievalSettingsGroup(
                titleKey: "settings.retrieval.storage.title",
                systemImage: "magnifyingglass"
            ) {
                RAGBackendSettingsView()
            }
        }
    }

    /// 内置档位仍走 apply；恢复操作移到参数之后，明确它会同时恢复来源。
    private var presetPicker: some View {
        retrievalSelectionRow(
            titleKey: "settings.retrieval.strategy.label",
            selection: retrievalPresetBinding
        ) {
            ForEach(RAGRetrievalPreset.allCases) { preset in
                Text(preset.titleKey).tag(preset)
            }
        }
    }

    /// 保留同一行的标题和控件；长翻译或窄窗口放不下全部分段时，使用原生菜单。
    /// 标题以完整宽度参与测量，避免原生 Picker 的理想宽度把文字挤成逐字竖排。
    private func retrievalSelectionRow<Selection: Hashable, Options: View>(
        titleKey: LocalizedStringKey,
        selection: Binding<Selection>,
        @ViewBuilder options: () -> Options
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(titleKey)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                Picker(titleKey, selection: selection, content: options)
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(titleKey)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                Picker(titleKey, selection: selection, content: options)
                    .pickerStyle(.menu)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retrievalCommonSection: some View {
        // 自定义卡片没有 Form 自动分隔线；行间显式 Divider + 统一竖向 padding。
        VStack(alignment: .leading, spacing: 0) {
            SettingsSliderRow(
                title: "rag.workspace.retrieval.minimumSimilarity", value: similarityBinding,
                range: 0.00...1.00, step: 0.01,
                readout: minimumVectorSimilarity.formatted(.percent.precision(.fractionLength(0)).locale(locale))
            )
            .padding(.vertical, interfaceScale.scaled(8))

            Divider()
            settingTextFieldRow(
                titleKey: "settings.retrieval.strategy.perRepository",
                hintKey: "settings.retrieval.strategy.perRepositoryHint",
                text: perRepositoryEvidenceLimitBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))

            Divider()
            settingTextFieldRow(
                titleKey: "settings.retrieval.strategy.fragments",
                hintKey: "settings.retrieval.strategy.fragmentsHint",
                text: finalEvidenceChunkLimitBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
            // 三个数值行放在同一容器中，使用相同分隔线和 padding，避免 Form 额外增加组间留白。
            Divider()
            settingTextFieldRow(
                titleKey: "settings.retrieval.strategy.length",
                hintKey: "settings.retrieval.strategy.lengthHint",
                text: evidenceTokenBudgetBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
        }
    }

    /// Rerank 服务由用户自行配置；关闭时保留协议、地址和模型，方便临时停用后再次启用。
    private var rerankSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("settings.retrieval.rerank.enabled", isOn: $rerankEnabled)
                .font(ragFont(.body, scale: interfaceScale))
                .padding(.vertical, interfaceScale.scaled(8))
            Text("settings.retrieval.rerank.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, interfaceScale.scaled(8))
            if rerankEnabled {
                Divider()
                retrievalSelectionRow(
                    titleKey: "settings.retrieval.rerank.method",
                    selection: $rerankProvider
                ) {
                    Text("rag.workspace.rerank.provider.tei").tag(RAGRerankProvider.huggingFaceTEI)
                    Text("settings.retrieval.rerank.cohere").tag(RAGRerankProvider.cohereCompatible)
                    Text("settings.retrieval.rerank.local").tag(RAGRerankProvider.localMLX)
                }
                .onChange(of: rerankProvider) { previous, current in
                    // 仅在用户未改过默认地址时切换，手动填写的自托管地址不能被静默覆盖。
                    if rerankEndpoint == previous.defaultEndpoint {
                        rerankEndpoint = current.defaultEndpoint
                    }
                }
                .padding(.vertical, interfaceScale.scaled(10))
                if rerankProvider != .localMLX {
                    Divider()
                    rerankConnectionFields
                } else {
                    Text("settings.retrieval.rerank.localHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, interfaceScale.scaled(8))
                }
                Divider()
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.candidateLimit",
                    hintKey: "settings.retrieval.rerank.candidatesHint",
                    text: rerankCandidateLimitBinding
                )
                .padding(.vertical, interfaceScale.scaled(8))
            }
        }
    }

    /// 普通垂直栈按各行自然高度排版；统一输入列由字段组件负责，避免跨列备注参与 Grid 测量。
    private var rerankConnectionFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            RAGSettingsConnectionField(titleKey: "rag.workspace.rerank.endpoint", text: $rerankEndpoint)
                .padding(.vertical, interfaceScale.scaled(8))
            Text("rag.workspace.rerank.endpoint.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, interfaceScale.scaled(8))
            if rerankProvider == .cohereCompatible {
                Divider()
                RAGSettingsConnectionField(titleKey: "rag.workspace.rerank.model", text: $rerankModel)
                    .padding(.vertical, interfaceScale.scaled(8))
                Text("rag.workspace.rerank.model.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, interfaceScale.scaled(8))
            }
            Divider()
            RAGSettingsConnectionField(
                titleKey: "settings.services.apiKey",
                text: rerankAPIKeyBinding,
                isSecure: true
            )
            .padding(.vertical, interfaceScale.scaled(8))
            if isSavingRerankCredential || hasSavedRerankCredential || rerankCredentialError != nil {
                // 保留实际保存反馈；未编辑时不额外占用一行备注空间。
                rerankCredentialFeedback
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 四个来源各占一行，英文长标签不会被挤成省略号。
    private var retrievalSourcesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("settings.retrieval.sources.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, interfaceScale.scaled(8))
            sourceToggle(
                source: .readme,
                titleKey: "rag.workspace.retrieval.source.readme",
                isOn: includesReadmeBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
            Divider()
            sourceToggle(
                source: .notes,
                titleKey: "settings.retrieval.sources.notes",
                isOn: includesNotesBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
            Divider()
            sourceToggle(
                source: .summary,
                titleKey: "rag.workspace.retrieval.source.summary",
                isOn: includesSummaryBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
            Divider()
            sourceToggle(
                source: .metadata,
                titleKey: "rag.workspace.retrieval.source.metadata",
                isOn: includesMetadataBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
        }
    }

    /// 状态占用固定的一行，编辑、保存成功和失败不让下方配置反复跳动。
    private var rerankCredentialFeedback: some View {
        HStack(spacing: 6) {
            if isSavingRerankCredential {
                ProgressView().controlSize(.mini)
                Text("settings.retrieval.rerank.saving")
            } else if let rerankCredentialError {
                Label("settings.retrieval.rerank.saveFailed", systemImage: "exclamationmark.circle")
                Text(rerankCredentialError)
            } else if hasSavedRerankCredential {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(LocalizedStringKey(rerankAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "settings.retrieval.rerank.cleared" : "settings.retrieval.rerank.saved"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func sourceToggle(
        source: RAGChunkSource,
        titleKey: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            // 来源图标属于行 Label 的一部分：与设置页正文同为 13pt，只用语义色区分来源。
            HStack(spacing: 5) {
                Image(systemName: source.systemImageName)
                    .font(interfaceScale.font(size: 13, weight: .medium))
                    .foregroundStyle(source.tintColor)
                Text(titleKey)
                    .font(ragFont(.body, scale: interfaceScale))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    /// 保留检索各组完整内容，背景与间距由系统 Section 管理。
    private func retrievalSettingsGroup<Content: View>(
        titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            SettingsSectionHeader(titleKey, systemImage: systemImage)
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

    private var rerankAPIKeyBinding: Binding<String> {
        Binding(
            get: { rerankAPIKey },
            set: { newValue in
                hasEditedRerankAPIKey = true
                rerankAPIKey = newValue
            }
        )
    }

    private var includesReadmeBinding: Binding<Bool> {
        Binding(
            get: { includesReadme },
            set: {
                includesReadme = $0
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var includesNotesBinding: Binding<Bool> {
        Binding(
            get: { includesNotes },
            set: {
                includesNotes = $0
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var includesSummaryBinding: Binding<Bool> {
        Binding(
            get: { includesSummary },
            set: {
                includesSummary = $0
                markRetrievalCustomIfNeeded()
            }
        )
    }

    private var includesMetadataBinding: Binding<Bool> {
        Binding(
            get: { includesMetadata },
            set: {
                includesMetadata = $0
                markRetrievalCustomIfNeeded()
            }
        )
    }

    /// 用当前草稿反推 UI 档位：与三档内置完全一致才显示对应档，否则自定义。
    private func markRetrievalCustomIfNeeded() {
        guard !isApplyingRetrievalPreset else { return }
        retrievalPreset = RAGRetrievalPreset.matching(settings: buildRetrievalSettings())
    }

    /// 数值框固定同宽，按标题和完整备注的整体高度居中；统一最小行高后允许长翻译向下扩展。
    private func settingTextFieldRow(
        titleKey: LocalizedStringKey,
        hintKey: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack(alignment: .center, spacing: interfaceScale.scaled(12)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(titleKey)
                    .font(ragFont(.body, scale: interfaceScale))
                    .foregroundStyle(.primary)
                Text(hintKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: interfaceScale.scaled(12))
            TextField("", text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(ragFont(.body, scale: interfaceScale, design: .monospaced))
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(width: interfaceScale.scaled(100))
                .accessibilityLabel(titleKey)
        }
        .frame(minHeight: interfaceScale.scaled(48))
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

    private var currentPromptConfiguration: AIPromptConfiguration {
        promptConfiguration(for: tab)
    }

    /// 汇总与当前任务使用同一份草稿；不为页内状态创建第二套提示词存储。
    private func promptConfiguration(for tab: RAGPromptEditorTab) -> AIPromptConfiguration {
        switch tab {
        case .generator: return draft.generator
        case .planner: return draft.planner
        case .compressor: return draft.compressor
        case .title: return draft.title
        }
    }

    /// 入口反映全部四项任务：任一受限优先提醒，其次自定义，否则全部默认。
    private var promptSummaryState: RAGPromptCompatibilityState {
        let states = RAGPromptEditorTab.allCases.map { task in
            RAGPromptCompatibilityAnalyzer.analyze(
                current: promptConfiguration(for: task),
                reference: task.defaultConfiguration
            ).state
        }
        if states.contains(.limited) { return .limited }
        return states.contains(.customized) ? .customized : .defaultValue
    }

    private var promptCompatibility: RAGPromptCompatibility {
        RAGPromptCompatibilityAnalyzer.analyze(
            current: currentPromptConfiguration,
            reference: tab.defaultConfiguration
        )
    }

    /// 默认、自定义、受限分别表达真实草稿状态；自定义本身不表示错误。
    private func promptCompatibilityBadge(for state: RAGPromptCompatibilityState) -> some View {
        return Label(
            promptCompatibilityStatusKey(state),
            systemImage: state == .limited ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .foregroundStyle(state == .limited ? Color.orange : state == .defaultValue ? Color.green : Color.secondary)
        .accessibilityElement(children: .combine)
    }

    /// 缺失或重复占位符在检查结果中展示；这里只报告问题并保留恢复默认入口，
    /// 不再自动改写用户草稿，避免无法可靠推断的 Prompt 结构被程序拼坏。
    private var promptCompatibilityNotice: some View {
        let compatibility = promptCompatibility
        let missing = compatibility.missingPlaceholders
        let duplicated = compatibility.duplicatedPlaceholders
        return VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            if !missing.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(6)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text(
                        String(
                            format: String.l10n("rag.workspace.prompt.compatibility.messageFormat"),
                            missing.count
                        )
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                }

                Text(missing.joined(separator: "  "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if missing.contains("{repositoryInsightsSection}") {
                    Text("rag.workspace.prompt.compatibility.repositoryInsights")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !duplicated.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(6)) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text(
                        String(
                            format: String.l10n(
                                "rag.workspace.prompt.compatibility.duplicatedMessageFormat"
                            ),
                            duplicated.count
                        )
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                }

                Text(duplicated.joined(separator: "  "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("rag.workspace.prompt.compatibility.duplicatedHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: interfaceScale.scaled(8)) {
                Spacer()
                Button("rag.workspace.prompt.compatibility.restore") {
                    restoreCurrentTab()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }

    }

    private func promptCompatibilityStatusKey(
        _ state: RAGPromptCompatibilityState
    ) -> LocalizedStringKey {
        switch state {
        case .defaultValue: return "rag.workspace.prompt.compatibility.default"
        case .customized: return "rag.workspace.prompt.compatibility.customized"
        case .limited: return "rag.workspace.prompt.compatibility.limited"
        }
    }

    private func restoreCurrentTab() {
        switch tab {
        case .generator: draft.generator = RAGDefaultPrompts.generator
        case .planner: draft.planner = RAGDefaultPrompts.planner
        case .compressor: draft.compressor = RAGDefaultPrompts.compressor
        case .title: draft.title = RAGDefaultPrompts.title
        }
    }

    /// 与翻译页使用相同的标题、等宽正文、固定编辑高度和轻量描边。
    private func promptEditor(
        title: LocalizedStringKey,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: text)
                .font(.body.monospaced())
                .accessibilityLabel(title)
                .frame(height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
    }

}

/// 当前 Prompt 页的只读默认值；只提供复制，不持有 Binding，也不会间接覆盖用户草稿。
private struct RAGDefaultPromptPopover: View {
    let configuration: AIPromptConfiguration
    let tabTitle: LocalizedStringKey
    let interfaceScale: InterfaceScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(8)) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.workspace.prompt.default.title")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: interfaceScale.scaled(8))
                Text(tabTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("rag.workspace.prompt.default.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
                    promptBlock(
                        title: "rag.workspace.prompt.system",
                        copyTooltip: "rag.workspace.prompt.default.copySystem",
                        content: configuration.systemPrompt
                    )
                    promptBlock(
                        title: "rag.workspace.prompt.user",
                        copyTooltip: "rag.workspace.prompt.default.copyUser",
                        content: configuration.userPromptTemplate
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, interfaceScale.scaled(4))
            }
            .frame(height: interfaceScale.scaled(400))
        }
        .padding(interfaceScale.scaled(16))
        .frame(width: 500 * interfaceScale.multiplier)
        .environment(\.starcatInterfaceScale, interfaceScale)
    }

    private func promptBlock(
        title: LocalizedStringKey,
        copyTooltip: LocalizedStringKey,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            HStack(spacing: interfaceScale.scaled(8)) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: interfaceScale.scaled(8))
                CopyFeedbackButton(
                    providesContent: { content },
                    tooltip: copyTooltip
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        // 默认 Prompt 弹层的标题行比标准设置行更紧凑；glyph 主动降到
                        // 11pt，仍保留 28pt 命中区，避免图标压过 Section 标题。
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .frame(
                            width: interfaceScale.scaled(28),
                            height: interfaceScale.scaled(28)
                        )
                        .contentShape(Rectangle())
                }
            }

            Text(content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(interfaceScale.scaled(10))
                .background(
                    StarcatSurface.editor(colorScheme: colorScheme),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            Color.primary.opacity(StarcatSurface.composerStrokeOpacity(colorScheme: colorScheme)),
                            lineWidth: 0.5
                        )
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.workspace.prompt.placeholders.title")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: interfaceScale.scaled(8)) {
                        // 与设置分组同款：默认色图标，不抢 token 阅读。
                        Image(systemName: item.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: interfaceScale.scaled(14), alignment: .center)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.token)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text(item.meaningKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text("rag.workspace.prompt.placeholders.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(interfaceScale.scaled(16))
        .frame(width: 360 * interfaceScale.multiplier)
        .environment(\.starcatInterfaceScale, interfaceScale)
    }
}
