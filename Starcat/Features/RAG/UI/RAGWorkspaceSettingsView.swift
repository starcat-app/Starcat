//
//  RAGWorkspaceSettingsView.swift
//  Starcat
//
//  RAG 工作台设置内容：主设置的三个 RAG 分类与验收期保留的独立窗口共用草稿和控件。
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
    case prompts
    case retrieval

    var id: String { rawValue }

    var titleKeyString: String {
        switch self {
        case .inference: return "rag.workspace.settings.section.inference"
        case .prompts: return "rag.workspace.settings.section.prompts"
        case .retrieval: return "rag.workspace.settings.section.retrieval"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }

    /// 只有三个一级分类，搜索只做稳定的分类过滤，不引入第二套深链模型。
    var searchKeywords: [String] {
        switch self {
        case .inference: return ["inference", "backend", "cli", "codex", "claude", "推理", "后端"]
        case .prompts: return ["prompt", "system", "user", "template", "提示词", "模板"]
        case .retrieval: return ["retrieval", "rerank", "evidence", "vector", "检索", "重排", "证据"]
        }
    }

    var systemImage: String {
        switch self {
        case .inference: return "cpu"
        case .prompts: return "text.quote"
        case .retrieval: return "magnifyingglass"
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

/// 设置内容的局部布局常量。
private enum RAGSettingsLayoutMetrics {
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
                .init(token: "{repositoryInsightsSection}", systemImage: "gauge.with.dots.needle.bottom.0percent", meaningKey: "rag.workspace.prompt.placeholder.repositoryInsightsSection"),
                .init(token: "{repoContextSection}", systemImage: "brain.head.profile", meaningKey: "rag.workspace.prompt.placeholder.repoContextSection"),
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
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var settings: AppSettings
    let presentation: RAGWorkspaceSettingsPresentation
    @State private var tab: RAGPromptEditorTab = .generator
    @State private var draft: RAGPromptSettings
    /// CLI 只在 Direct 版可选；App Store 即使从旧偏好读到 CLI，也先归一成 API 草稿。
    @State private var inferenceBackend: RAGInferenceBackend
    @State private var codexRuntimeInspection: RAGCLIRuntimeInspection = .checking
    @State private var claudeRuntimeInspection: RAGCLIRuntimeInspection = .checking
    @State private var isInspectingCLIRuntimes = false
    @State private var isPlaceholderPopoverPresented = false
    @State private var isDefaultPromptPopoverPresented = false
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
    /// `apply(_:)` 写字段期间抬起，挡住误判「自定义」；用户手动拖滑杆 / 改数字时则放行。
    @State private var isApplyingRetrievalPreset = false

    init(
        settings: AppSettings,
        presentation: RAGWorkspaceSettingsPresentation
    ) {
        self.settings = settings
        self.presentation = presentation
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

    /// 直接订阅设置档位，避免独立窗口只缩放外框、字体仍停在 standard。
    private var interfaceScale: InterfaceScale { settings.interfaceScale }

    private var availableInferenceBackends: [RAGInferenceBackend] {
        RAGInferenceBackend.available(using: DistributionGate())
    }

    @ViewBuilder
    var body: some View {
        if case .embeddedInMainSettings(let section) = presentation {
            embeddedSettingsPage(section: section)
                .environment(\.starcatInterfaceScale, interfaceScale)
                .dynamicTypeSize(interfaceScale.dynamicTypeSize)
        }
    }

    /// 主设置 Sidebar 已直接承载「推理 / 提示词 / 检索」，这里仅渲染当前分类内容。
    /// 三项仍复用同一 View 类型和草稿状态，切换分类不会产生第二套导航或双写。
    private func embeddedSettingsPage(section: RAGSettingsSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
                switch section {
                case .inference:
                    inferenceSettingsSections
                case .prompts:
                    promptSettingsSections
                case .retrieval:
                    retrievalSettingsSections
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, interfaceScale.scaled(20))
            .padding(.trailing, interfaceScale.scaled(RAGSettingsLayoutMetrics.scrollTrailerGutter))
            .padding(.bottom, interfaceScale.scaled(20))
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        rerankAPIKeyAutoSaveTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let errorMessage = await RAGRerankCredentialAutoSaver.shared.persist(value)
            guard !Task.isCancelled else { return }
            rerankCredentialError = errorMessage
        }
    }

    /// 提示词底栏入口：点开看 token + 含义，避免一行塞满无说明的占位符列表。
    private var placeholderHelpButton: some View {
        Button {
            isDefaultPromptPopoverPresented = false
            isPlaceholderPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                Text("rag.workspace.prompt.placeholders.open")
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
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

    /// 默认 Prompt 永远只读展示；用户可以复制后自行比较，不在这里写回草稿。
    private var defaultPromptReferenceButton: some View {
        Button {
            isPlaceholderPopoverPresented = false
            isDefaultPromptPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                Text("rag.workspace.prompt.default.open")
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
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

    /// 不含滚动容器的提示词内容，供独立窗口与主设置分类页共享。
    private var promptSettingsSections: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
            // 与检索「预设」同款容器：带描边的卡片 + 等宽 tab，避免 settingsGroup
            // 半透明底把 EqualWidthSegmentedControl 轨道衬底吃掉、看起来像裸文字+蓝 pill。
            retrievalSettingsGroup(
                titleKey: "rag.workspace.prompt.type.title",
                systemImage: "text.quote"
            ) {
                // 等宽铺满（重置除外）：中英文不再因文案长短变成半行短条。
                HStack(spacing: interfaceScale.scaled(12)) {
                    EqualWidthSegmentedControl(
                        items: Array(RAGPromptEditorTab.allCases),
                        selection: $tab,
                        title: \.titleKey
                    )
                    .accessibilityLabel("rag.workspace.prompt.title")

                    promptCompatibilityBadge

                    ResetIconButton(
                        help: Text("rag.workspace.prompt.restoreHelp")
                    ) {
                        restoreCurrentTab()
                    }
                }
            }
            settingsGroup(
                titleKey: "rag.workspace.prompt.system",
                systemImage: "text.alignleft"
            ) {
                promptEditor(
                    text: systemBinding,
                    minHeight: interfaceScale.scaled(190)
                )
            }
            settingsGroup(
                titleKey: "rag.workspace.prompt.user",
                systemImage: "text.bubble"
            ) {
                VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
                    promptEditor(
                        text: userBinding,
                        minHeight: interfaceScale.scaled(108)
                    )
                    if promptCompatibility.state == .limited {
                        promptCompatibilityNotice
                    }
                }
            }

            // 参考其他提示词设置页的 footer：辅助入口属于当前提示词内容，放在全部
            // 编辑器之后并右对齐，既不占用窗口 Toolbar，也不与类型控件争抢宽度。
            VStack(spacing: interfaceScale.scaled(10)) {
                Divider()
                HStack(spacing: interfaceScale.scaled(16)) {
                    Spacer(minLength: 0)
                    placeholderHelpButton
                    defaultPromptReferenceButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, interfaceScale.scaled(2))
        }
    }

    /// 不含滚动容器的推理内容；CLI 探测任务由实际承载它的页面外壳负责启动。
    private var inferenceSettingsSections: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
                HStack(spacing: interfaceScale.scaled(8)) {
                    sectionTitle("rag.workspace.inference.backend.title", systemImage: "cpu")
                    Spacer(minLength: 0)
                    if availableInferenceBackends.contains(where: \.isCLI) {
                        SyncIconButton(
                            isRefreshing: isInspectingCLIRuntimes,
                            disabled: isInspectingCLIRuntimes,
                            font: interfaceScale.font(size: 15, weight: .medium),
                            frameSize: interfaceScale.scaled(28),
                            tooltip: String.l10n("rag.workspace.inference.refresh.help")
                        ) {
                            Task { await inspectCLIRuntimes() }
                        }
                        .accessibilityLabel("rag.workspace.inference.refresh.label")
                    }
                }

                Text("rag.workspace.inference.backend.summary")
                    .font(ragFont(.caption, scale: interfaceScale))
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
                        .font(ragFont(.caption, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsGroup(
                titleKey: "rag.workspace.inference.boundary.title",
                systemImage: "lock.shield"
            ) {
                VStack(alignment: .leading, spacing: interfaceScale.scaled(8)) {
                    Label("rag.workspace.inference.boundary.retrieval", systemImage: "checkmark.shield")
                    Label("rag.workspace.inference.boundary.tools", systemImage: "nosign")
                    Label("rag.workspace.inference.boundary.otherFeatures", systemImage: "arrow.triangle.branch")
                }
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
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

    /// 不含滚动容器的检索内容，主设置可直接接在推理和提示词之后继续滚动。
    private var retrievalSettingsSections: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
            retrievalSettingsGroup(
                titleKey: "rag.workspace.retrieval.preset.title",
                systemImage: "slider.horizontal.3"
            ) {
                presetPicker
            }
            retrievalSettingsGroup(
                titleKey: "rag.workspace.retrieval.common.title",
                systemImage: "line.3.horizontal.decrease.circle"
            ) {
                retrievalCommonSection
            }
            retrievalSettingsGroup(
                titleKey: "rag.workspace.retrieval.advanced.title",
                systemImage: "gearshape.2"
            ) {
                retrievalAdvancedSection
            }
            retrievalSettingsGroup(
                titleKey: "rag.workspace.retrieval.sources.title",
                systemImage: "cylinder.split.1x2"
            ) {
                retrievalSourcesSection
            }
            retrievalSettingsGroup(
                titleKey: "rag.workspace.rerank.title",
                systemImage: "arrow.up.arrow.down.circle"
            ) {
                rerankSection
            }
        }
    }

    /// 与提示词页同款：等宽预设 tab + 右侧重置；主设置自动保存，独立窗口仍保留草稿提交。
    private var presetPicker: some View {
        HStack(spacing: interfaceScale.scaled(12)) {
            EqualWidthSegmentedControl(
                items: Array(RAGRetrievalPreset.allCases),
                selection: retrievalPresetBinding,
                title: \.titleKey
            )
            .accessibilityLabel("rag.workspace.retrieval.preset.title")

            ResetIconButton(
                help: Text("rag.workspace.retrieval.restoreDefaults")
            ) {
                apply(.balanced)
            }
        }
    }

    private var retrievalCommonSection: some View {
        // 自定义卡片没有 Form 自动分隔线；行间显式 Divider + 统一竖向 padding。
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
                settingRow(
                    titleKey: "rag.workspace.retrieval.minimumSimilarity",
                    value: String(format: "%.2f", minimumVectorSimilarity)
                )
                Slider(value: similarityBinding, in: 0.00...1.00, step: 0.01)
                    .controlSize(.small)
                Text("rag.workspace.retrieval.minimumSimilarity.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, interfaceScale.scaled(8))

            Divider()
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.perRepositoryLimit",
                hintKey: "rag.workspace.retrieval.perRepositoryLimit.hint",
                text: perRepositoryEvidenceLimitBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))

            Divider()
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.finalChunkLimit",
                hintKey: "rag.workspace.retrieval.finalChunkLimit.hint",
                text: finalEvidenceChunkLimitBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
        }
    }

    private var retrievalAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingTextFieldRow(
                titleKey: "rag.workspace.retrieval.tokenBudget",
                hintKey: "rag.workspace.retrieval.tokenBudget.hint",
                text: evidenceTokenBudgetBinding
            )
            .padding(.vertical, interfaceScale.scaled(8))
        }
    }

    /// Rerank 服务由用户自行配置；关闭时保留协议、地址和模型，方便临时停用后再次启用。
    private var rerankSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("rag.workspace.rerank.enabled", isOn: $rerankEnabled)
                .font(ragFont(.body, scale: interfaceScale))
                .padding(.vertical, interfaceScale.scaled(8))
            Text("rag.workspace.rerank.enabled.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, interfaceScale.scaled(8))
            if rerankEnabled {
                Divider()
                // 与提示词 / 预设同款：等宽铺满，中英文布局一致。
                EqualWidthSegmentedControl(
                    items: [RAGRerankProvider.huggingFaceTEI, .cohereCompatible],
                    selection: $rerankProvider,
                    title: { provider in
                        switch provider {
                        case .huggingFaceTEI: return "rag.workspace.rerank.provider.tei"
                        case .cohereCompatible: return "rag.workspace.rerank.provider.cohere"
                        }
                    }
                )
                .accessibilityLabel("rag.workspace.rerank.provider")
                .onChange(of: rerankProvider) { previous, current in
                    // 仅在用户未改过默认地址时切换，手动填写的自托管地址不能被静默覆盖。
                    if rerankEndpoint == previous.defaultEndpoint {
                        rerankEndpoint = current.defaultEndpoint
                    }
                }
                .padding(.vertical, interfaceScale.scaled(10))
                Divider()
                // URL 往往很长：输入框吃满标题右侧到容器右缘，溢出只水平滚动不换行。
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.endpoint",
                    hintKey: "rag.workspace.rerank.endpoint.hint",
                    text: $rerankEndpoint,
                    expandsToTrailingEdge: true
                )
                .padding(.vertical, interfaceScale.scaled(8))
                if rerankProvider == .cohereCompatible {
                    Divider()
                    settingTextFieldRow(
                        titleKey: "rag.workspace.rerank.model",
                        hintKey: "rag.workspace.rerank.model.hint",
                        text: $rerankModel,
                        expandsToTrailingEdge: true
                    )
                    .padding(.vertical, interfaceScale.scaled(8))
                }
                Divider()
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.apiKey",
                    hintKey: "rag.workspace.rerank.apiKey.hint",
                    text: rerankAPIKeyBinding,
                    expandsToTrailingEdge: true,
                    isSecure: true
                )
                .padding(.vertical, interfaceScale.scaled(8))
                Divider()
                settingTextFieldRow(
                    titleKey: "rag.workspace.rerank.candidateLimit",
                    hintKey: "rag.workspace.rerank.candidateLimit.hint",
                    text: rerankCandidateLimitBinding
                )
                .padding(.vertical, interfaceScale.scaled(8))
                if let rerankCredentialError {
                    Divider()
                    Text(rerankCredentialError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, interfaceScale.scaled(8))
                }
            }
        }
    }

    /// 四个来源各占一行，英文长标签不会被挤成省略号。
    private var retrievalSourcesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("rag.workspace.retrieval.sources.hint")
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
                titleKey: "rag.workspace.retrieval.source.notes",
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
        .toggleStyle(.checkbox)
    }

    private func settingsGroup<Content: View>(
        titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 分组标题与卡片内容拉开到 12pt，避免「标题贴着 tab」的拥挤感。
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            // 双栏工作台不改成 Form；此处等效采用设置页 Section header 的字号、图标和间距契约。
            sectionTitle(titleKey, systemImage: systemImage)
            content()
                .padding(interfaceScale.scaled(14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    StarcatSurface.groupedCard(colorScheme: colorScheme),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
        }
    }

    /// 带描边的设置卡片：检索各分组 + 提示词「类型」tab 共用，保证分段控件轨道衬底不被半透明底吃掉。
    /// System / User 长文本编辑仍走 `settingsGroup` 的更轻密度。
    private func retrievalSettingsGroup<Content: View>(
        titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(12)) {
            sectionTitle(titleKey, systemImage: systemImage)
            retrievalSettingsCard(content: content)
        }
    }

    private func retrievalSettingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(interfaceScale.scaled(14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StarcatSurface.raisedCard(colorScheme: colorScheme),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
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

    /// 与主设置页 `SettingsSectionHeader.prominent` 同款：13pt 图标、20pt 图标框、13pt semibold 标题。
    private func sectionTitle(_ key: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: interfaceScale.scaled(6)) {
            Image(systemName: systemImage)
                .font(interfaceScale.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: interfaceScale.scaled(20), height: interfaceScale.scaled(20))
                .accessibilityHidden(true)
            Text(key)
                .font(ragFont(.body, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private func settingRow(titleKey: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(titleKey)
                .font(ragFont(.body, scale: interfaceScale))
                .foregroundStyle(.primary)
            Spacer(minLength: interfaceScale.scaled(12))
            Text(value)
                .font(ragFont(.body, scale: interfaceScale, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// - Parameter expandsToTrailingEdge: 为 true 时输入框从标题右侧铺满到容器右缘（URL / 模型名等长文本）；
    ///   默认 false 保持短数字框（分片上限 / Token 预算 / 候选数等）。
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
                        .font(ragFont(.body, scale: interfaceScale))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: true, vertical: false)
                    if isSecure {
                        SecureField("", text: text)
                            .textFieldStyle(.roundedBorder)
                            .font(ragFont(.body, scale: interfaceScale, design: .monospaced))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("", text: text)
                            .textFieldStyle(.roundedBorder)
                            .font(ragFont(.body, scale: interfaceScale, design: .monospaced))
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text(hintKey)
                    // 设置备注遵循规范的系统 `.caption`，通过动态字体档位自适应一次，
                    // 不再叠加 RAG 工作台的手工字号倍率。
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(12)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(titleKey)
                        .font(ragFont(.body, scale: interfaceScale))
                        .foregroundStyle(.primary)
                    Text(hintKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: interfaceScale.scaled(12))
                if isSecure {
                    SecureField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(ragFont(.body, scale: interfaceScale, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: interfaceScale.scaled(80), alignment: .trailing)
                } else {
                    TextField("", text: text)
                        .textFieldStyle(.roundedBorder)
                        .font(ragFont(.body, scale: interfaceScale, design: .monospaced))
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
        switch tab {
        case .generator: return draft.generator
        case .planner: return draft.planner
        case .compressor: return draft.compressor
        case .title: return draft.title
        }
    }

    private var promptCompatibility: RAGPromptCompatibility {
        RAGPromptCompatibilityAnalyzer.analyze(
            current: currentPromptConfiguration,
            reference: tab.defaultConfiguration
        )
    }

    /// 仅表达当前编辑页的真实状态；“已自定义”不是错误，只有缺失占位符才使用警告色。
    private var promptCompatibilityBadge: some View {
        let compatibility = promptCompatibility
        let isLimited = compatibility.state == .limited
        return HStack(spacing: interfaceScale.scaled(5)) {
            Image(systemName: isLimited ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .font(interfaceScale.font(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(promptCompatibilityStatusKey(compatibility.state))
                .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isLimited ? Color.orange : Color.secondary)
        .padding(.horizontal, interfaceScale.scaled(8))
        .frame(minWidth: interfaceScale.scaled(76), minHeight: interfaceScale.scaled(24))
        .background(
            (isLimited ? Color.orange : Color.secondary).opacity(isLimited ? 0.12 : 0.08),
            in: Capsule()
        )
        .accessibilityElement(children: .combine)
    }

    /// 缺失或重复占位符紧邻 User Prompt 展示；这里只报告问题并保留恢复默认入口，
    /// 不再自动改写用户草稿，避免无法可靠推断的 Prompt 结构被程序拼坏。
    private var promptCompatibilityNotice: some View {
        let compatibility = promptCompatibility
        let missing = compatibility.missingPlaceholders
        let duplicated = compatibility.duplicatedPlaceholders
        return VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            if !missing.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(6)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(interfaceScale.font(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    Text(
                        String(
                            format: String.l10n("rag.workspace.prompt.compatibility.messageFormat"),
                            missing.count
                        )
                    )
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                    .foregroundStyle(.primary)
                }

                Text(missing.joined(separator: "  "))
                    .font(interfaceScale.font(.code))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if missing.contains("{repositoryInsightsSection}") {
                    Text("rag.workspace.prompt.compatibility.repositoryInsights")
                        .font(ragFont(.caption, scale: interfaceScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !duplicated.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(6)) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(interfaceScale.font(size: 11, weight: .semibold))
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
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                    .foregroundStyle(.primary)
                }

                Text(duplicated.joined(separator: "  "))
                    .font(interfaceScale.font(.code))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text("rag.workspace.prompt.compatibility.duplicatedHint")
                    .font(ragFont(.caption, scale: interfaceScale))
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
        .padding(interfaceScale.scaled(10))
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
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

    private func promptEditor(
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(interfaceScale.font(.code))
            .scrollContentBackground(.hidden)
            .padding(interfaceScale.scaled(8))
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StarcatSurface.editor(colorScheme: colorScheme))
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
                    .font(interfaceScale.font(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.workspace.prompt.default.title")
                    .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: interfaceScale.scaled(8))
                Text(tabTitle)
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("rag.workspace.prompt.default.description")
                .font(ragFont(.caption, scale: interfaceScale))
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
        .dynamicTypeSize(interfaceScale.dynamicTypeSize)
    }

    private func promptBlock(
        title: LocalizedStringKey,
        copyTooltip: LocalizedStringKey,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            HStack(spacing: interfaceScale.scaled(8)) {
                Text(title)
                    .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: interfaceScale.scaled(8))
                CopyFeedbackButton(
                    providesContent: { content },
                    tooltip: copyTooltip
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        // 默认 Prompt 弹层的标题行比标准设置行更紧凑；glyph 主动降到
                        // 11pt，仍保留 28pt 命中区，避免图标压过 Section 标题。
                        .font(interfaceScale.font(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .frame(
                            width: interfaceScale.scaled(28),
                            height: interfaceScale.scaled(28)
                        )
                        .contentShape(Rectangle())
                }
            }

            Text(content)
                .font(interfaceScale.font(.code))
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
