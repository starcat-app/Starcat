//
//  AgentWorkspaceView.swift
//  Starcat
//
//  Agent 独立 Workspace Window 的三栏内容视图。
//
//  本视图是所有内置 Agent 的唯一工作台壳子。三栏结构对齐 RAG 工作台：原生
//  Sidebar / Run Surface / Inspector 组合，左右栏可拖拽并跨窗口重开恢复。
//  Agent 只提供定义与运行事实，页面结构保持统一，避免 Weekly / Repo Insight 等
//  能力各自长出一套不可复用的 UI。
//

import AppKit
import SwiftUI

/// Agent 工作台三栏尺寸约束与持久化键。
///
/// 与 RAG 工作台共用同一套原生 Sidebar / Inspector 口径：左右栏可拖拽，中栏保留稳定阅读空间。
/// 持久化值读取时必须钳制，避免旧 defaults 或手工改键后恢复出挤掉 Run Surface 的布局。
enum AgentWorkspaceLayoutMetrics {
    static let leftMinimumWidth: CGFloat = 250
    static let leftIdealWidth: CGFloat = 312
    static let leftMaximumWidth: CGFloat = 380

    static let runMinimumWidth: CGFloat = 480

    static let rightMinimumWidth: CGFloat = 320
    // 首次打开保持紧凑；用户拖拽后的真实宽度由 Inspector 栏内测量写回并优先恢复。
    static let rightDefaultWidth = rightMinimumWidth
    static let rightMaximumWidth: CGFloat = 520

    // Window Scene 与旧 AppKit 窗口的布局时序不同，左栏不能复用迁移前的宽度记录。
    static let leftWidthDefaultsKey = "AgentWorkspace.SceneV2.LeftColumnWidth"
    // v2 的 HSplitView 测量没有稳定落盘；v3 由原生 Inspector 在栏内直接写回真实宽度。
    static let rightWidthDefaultsKey = "AgentWorkspace.SceneV3.RightColumnWidth"

    static func clampedLeftWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), leftMinimumWidth), leftMaximumWidth)
    }

    static func clampedRightWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), rightMinimumWidth), rightMaximumWidth)
    }
}

/// 会影响 Agent `knowledge_search` 工具装配结果的 RAG 配置快照。
///
/// Agent Runtime 会冻结整组 Tool Registry；如果设置页在工作台存活期间修改了回退策略，
/// 必须让 SwiftUI 观察到快照变化并重新装配，否则外部 Runtime 会继续使用旧 Provider。
struct AgentRuntimeKnowledgeConfigurationSnapshot: Equatable {
    let backendConfiguration: RAGBackendConfiguration
    let retrievalSettings: RAGRetrievalSettings
    let rerankConfiguration: RAGRerankConfiguration

    @MainActor
    init(settings: AppSettings) {
        backendConfiguration = settings.ragBackendConfiguration
        retrievalSettings = settings.ragRetrievalSettings
        rerankConfiguration = settings.ragRerankConfiguration
    }
}

private enum CodexProviderEndpointState: Equatable {
    case unknown
    case checking
    case available
    case unavailable
}

struct AgentWorkspaceView: View {

    private static let contextPickerPanelHeight: CGFloat = 420
    private static let contextPickerPanelGap: CGFloat = 12

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ExternalAgentRuntimePreferences.backendKey)
    private var externalRuntimeBackendRawValue = AgentRuntimeBackend.builtinLoop.rawValue
    @AppStorage(ExternalAgentRuntimePreferences.codexModelKey)
    private var preferredCodexModelID = ""
    @AppStorage(ExternalAgentRuntimePreferences.codexProviderKey)
    private var preferredCodexProviderID = ""
    @AppStorage(ExternalAgentRuntimePreferences.codexReasoningEffortKey)
    private var preferredCodexReasoningEffort = ""
    @AppStorage(ExternalAgentRuntimePreferences.deepSeekModelKey)
    private var preferredDeepSeekModel = DeepSeekHarnessRuntime.defaultModel
    @AppStorage(ExternalAgentRuntimePreferences.deepSeekProviderKey)
    private var preferredDeepSeekProviderID = ""
    @AppStorage(ExternalAgentRuntimePreferences.deepSeekReasoningEffortKey)
    private var preferredDeepSeekReasoningEffort = ""
    @AppStorage(AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)
    private var persistedLeftColumnWidth = Double(AgentWorkspaceLayoutMetrics.leftIdealWidth)
    @AppStorage(AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey)
    private var persistedRightColumnWidth = Double(AgentWorkspaceLayoutMetrics.rightDefaultWidth)
    @State private var viewModel = AgentWorkspaceViewModel()
    @State private var composerContentHeight: CGFloat = 0
    @State private var isComposerContextExpanded = false
    /// 拖动期间只更新布局测量值，停止变化后再落盘，避免每个 mouse-drag 事件都写 UserDefaults。
    @State private var lastMeasuredLeftColumnWidth: CGFloat?
    @State private var lastMeasuredRightColumnWidth: CGFloat?
    @State private var leftWidthPersistenceTask: Task<Void, Never>?
    @State private var rightWidthPersistenceTask: Task<Void, Never>?
    @State private var codexModelCatalog = CodexModelCatalog.empty
    @State private var codexProviderCatalog = CodexProviderCatalog.load()
    @State private var isLoadingCodexModelCatalog = false
    @State private var codexModelCatalogError: String?
    @State private var codexProviderEndpointStates: [String: CodexProviderEndpointState] = [:]
    @State private var isHistoryExpanded = false
    /// 运行中的 Runtime 必须保持冻结；设置变更延后到当前 run 结束再装配。
    @State private var hasPendingKnowledgeConfigurationRefresh = false
    @FocusState private var isContextPickerSearchFocused: Bool
    @Bindable var chromeState: WorkspaceChromeState

    private var restoredLeftColumnWidth: CGFloat {
        AgentWorkspaceLayoutMetrics.clampedLeftWidth(persistedLeftColumnWidth)
    }

    private var restoredRightColumnWidth: CGFloat {
        AgentWorkspaceLayoutMetrics.clampedRightWidth(persistedRightColumnWidth)
    }

    private var knowledgeConfigurationSnapshot: AgentRuntimeKnowledgeConfigurationSnapshot {
        AgentRuntimeKnowledgeConfigurationSnapshot(settings: dependencies.settings)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $chromeState.leftColumnVisibility) {
            agentRail
                .navigationSplitViewColumnWidth(
                    min: AgentWorkspaceLayoutMetrics.leftMinimumWidth,
                    ideal: restoredLeftColumnWidth,
                    max: AgentWorkspaceLayoutMetrics.leftMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleLeftWidthPersistence(width)
                            }
                    }
                }
                // NavigationSplitView 的 Sidebar 是独立 preference 边界，尺寸不能再向
                // 根视图上传；在列内直接监听 GeometryReader，才能可靠写回 @AppStorage。
        } detail: {
            runSurface
                .frame(
                    minWidth: AgentWorkspaceLayoutMetrics.runMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        // 任务检查器是语义明确的 trailing inspector。使用系统 Inspector 后，宽度
        // 约束直接进入分栏控制器，不再依赖 HSplitView 对普通 idealWidth 的布局猜测。
        .inspector(isPresented: $chromeState.isRightColumnPresented) {
            artifactInspector
                .inspectorColumnWidth(
                    min: AgentWorkspaceLayoutMetrics.rightMinimumWidth,
                    ideal: restoredRightColumnWidth,
                    max: AgentWorkspaceLayoutMetrics.rightMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleRightWidthPersistence(width)
                            }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 工作台已有右上角统一控制组；移除系统自动插入的第二个 Sidebar 按钮。
        .toolbar(removing: .sidebarToggle)
        .defaultCursorShield()
        .task {
            viewModel.refreshLocalizedDefinitions(availableAgentDefinitions)
            if dependencies.distributionGate.isAvailable(.externalAgentRuntime),
               let generalAgent = availableAgentDefinitions.first(where: { $0.id == "external-general-poc" }) {
                viewModel.selectAgent(generalAgent)
            }
            let repositoryCatalog = GRDBAgentRepositoryCatalog(database: dependencies.database)
            viewModel.configureContextProvider(RepositoryAgentRunContextProvider(
                repoRepository: dependencies.repoRepository,
                repositoryCatalog: repositoryCatalog
            ))
            viewModel.configureRunRepository(dependencies.agentRunRepository)
            viewModel.configureRepositoryCatalog(repositoryCatalog)
            viewModel.configureModelOptions(
                dependencies.knowledgeRAGChatModels,
                defaultProviderID: dependencies.settings.aiChatTask.providerID,
                defaultModelName: dependencies.settings.aiChatTask.resolvedModelName
            )
            normalizeRuntimeSelections()
            configureAgentRuntime()
            await viewModel.initializeHistory()
        }
        .task(id: codexCatalogTaskID) {
            await loadCodexModelCatalogIfNeeded()
        }
        .onChange(of: viewModel.selectedModelID) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: locale.identifier) { _, _ in
            viewModel.refreshLocalizedDefinitions(availableAgentDefinitions)
            configureAgentRuntime()
        }
        .onChange(of: externalRuntimeBackendRawValue) { _, _ in
            viewModel.refreshLocalizedDefinitions(availableAgentDefinitions)
            configureAgentRuntime()
        }
        .onChange(of: preferredCodexModelID) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: preferredCodexProviderID) { _, _ in
            codexModelCatalog = .empty
            // 离开不可用 Provider 后允许下次重新选择并触发新预检，避免一次失败永久锁死菜单项。
            codexProviderEndpointStates = codexProviderEndpointStates.filter {
                $0.key == selectedCodexProviderID
            }
            configureAgentRuntime()
        }
        .onChange(of: preferredCodexReasoningEffort) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: preferredDeepSeekModel) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: preferredDeepSeekProviderID) { _, _ in
            normalizeDeepSeekSelection()
            configureAgentRuntime()
        }
        .onChange(of: preferredDeepSeekReasoningEffort) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: dependencies.settings.aiProviderProfiles) { _, _ in
            normalizeDeepSeekSelection()
            configureAgentRuntime()
        }
        .onChange(of: knowledgeConfigurationSnapshot) { _, _ in
            refreshRuntimeForKnowledgeConfigurationChange()
        }
        .onChange(of: viewModel.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning, hasPendingKnowledgeConfigurationRefresh else { return }
            hasPendingKnowledgeConfigurationRefresh = false
            configureAgentRuntime()
        }
        .animation(.easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
        .onDisappear {
            // 用户可能拖完立即关闭窗口；同步提交最后测量值，不能依赖 debounce 任务来得及执行。
            persistLastMeasuredWidths()
            leftWidthPersistenceTask?.cancel()
            rightWidthPersistenceTask?.cancel()
        }
    }

    /// 每次模型选择变化都重建尚未启动的 Runtime；已经运行的实例由 ViewModel 拒绝替换，
    /// 从而保证一次 run 从首个 token 到最终 artifact 始终使用同一模型。
    private func configureAgentRuntime() {
        let preferredBackend = activeRuntimeBackend
        let starcatModelName = viewModel.availableModels
            .first(where: { $0.id == viewModel.selectedModelID })?
            .name
        let runtimeModelName: String?
        let runtimeReasoningEffort: String?
        let runtimeProviderName: String?
        let runtimeSelectionAvailable: Bool
        switch preferredBackend {
        case .codexAppServer:
            runtimeProviderName = selectedCodexProviderOption?.displayName ?? selectedCodexProviderID
            runtimeModelName = selectedCodexModelSelection?.modelName
            runtimeReasoningEffort = selectedCodexModelSelection?.reasoningEffort
            runtimeSelectionAvailable = selectedCodexProviderOption.map(isCodexProviderAvailable) ?? false
        case .deepSeekHarness:
            // JSON-RPC carrier 不提供目录查询；这里冻结设置页已验证 Provider 的能力快照。
            runtimeProviderName = selectedDeepSeekSelection?.provider.displayName
            runtimeModelName = selectedDeepSeekSelection?.model.name
            runtimeReasoningEffort = selectedDeepSeekSelection?.reasoningEffort
            runtimeSelectionAvailable = selectedDeepSeekSelection != nil
        case .builtinLoop:
            runtimeProviderName = selectedBuiltinProviderProfile?.displayName
            runtimeModelName = starcatModelName
            runtimeReasoningEffort = nil
            runtimeSelectionAvailable = true
        }
        viewModel.configureRuntimeSelection(
            backend: preferredBackend,
            providerName: runtimeProviderName,
            modelName: runtimeModelName,
            reasoningEffort: runtimeReasoningEffort,
            isAvailable: runtimeSelectionAvailable
        )
        let externalSearchTool = ExternalSearchAgentTool(
            collector: AppSettingsAgentExternalSearchCollector(settings: dependencies.settings)
        )
        let knowledgeSearcher: any AgentKnowledgeSearching
        do {
            knowledgeSearcher = try dependencies.makeAgentKnowledgeCapabilityAdapter(
                selectedModelID: viewModel.selectedModelID
            )
        } catch {
            // RAG 配置或权益异常只关闭 knowledge_search；周刊的冻结元数据工具与 Artifact
            // 仍然可用，避免一个可选增强能力让整个 Agent Runtime 无法启动。
            AppLog.ai.warning("Agent knowledge tool unavailable: \(error.localizedDescription, privacy: .public)")
            knowledgeSearcher = UnavailableAgentKnowledgeSearcher()
        }
        var runtimes: [AgentRuntimeBackend: any AgentRuntime] = [:]
        let toolRegistry: AgentToolRegistry?
        do {
            toolRegistry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: externalSearchTool,
                knowledgeTool: AgentKnowledgeTool(searcher: knowledgeSearcher),
                // 与 MCP 走同一组 Capability 装配规则，避免 Agent 写标签后漏掉语义索引刷新。
                additionalTools: UntaggedTidyAgentTools.make(executor: dependencies.makeRepositoryTagCapability())
            ))
        } catch {
            toolRegistry = nil
            runtimes[.builtinLoop] = UnavailableAgentRuntime(message: error.localizedDescription)
        }

        if let toolRegistry {
            do {
                let modelClient = try AgentLoopModelClientFactory.make(
                    settings: dependencies.settings,
                    selectedModelID: viewModel.selectedModelID
                )
                runtimes[.builtinLoop] = LoopAgentRuntime(
                    modelClient: modelClient,
                    toolRegistry: toolRegistry,
                    runRepository: dependencies.agentRunRepository,
                    mode: viewModel.selectedAgent?.workflow.executionMode ?? .readonlyPlanning,
                    localeIdentifier: locale.identifier,
                    preferredLanguage: preferredOutputLanguage,
                    externalSearchPolicy: AgentExternalSearchPolicy.current(settings: dependencies.settings)
                )
            } catch {
                runtimes[.builtinLoop] = UnavailableAgentRuntime(message: error.localizedDescription)
            }
        }

        if preferredBackend != .builtinLoop {
            do {
                let adapter = try ExternalAgentRuntimePreferences.makeAdapter(
                    backend: preferredBackend,
                    settings: dependencies.settings
                )
                runtimes[preferredBackend] = ExternalAgentRuntime(
                    adapter: adapter,
                    distributionGate: dependencies.distributionGate,
                    selectedModelName: runtimeModelName,
                    reasoningEffort: runtimeReasoningEffort,
                    localeIdentifier: locale.identifier,
                    preferredLanguage: preferredOutputLanguage,
                    toolRegistry: toolRegistry,
                    runRepository: dependencies.agentRunRepository,
                    mcpBridgeFactory: { toolSet in
                        try await dependencies.mcpService.makeTransientBridge(toolSet: toolSet)
                    }
                )
            } catch {
                runtimes[preferredBackend] = UnavailableAgentRuntime(message: error.localizedDescription)
            }
        }
        viewModel.configureRuntime(AgentRuntimeRouter(
            preferredBackend: preferredBackend,
            runtimes: runtimes
        ))
    }

    private func refreshRuntimeForKnowledgeConfigurationChange() {
        guard !viewModel.isRunning else {
            // 当前 run 的工具与参数已经冻结，不能中途替换；完成后再让下一次请求读取新设置。
            hasPendingKnowledgeConfigurationRefresh = true
            return
        }
        configureAgentRuntime()
    }

    private var selectedCodexModelSelection: CodexModelSelection? {
        codexModelCatalog.resolvedSelection(
            preferredModelID: preferredCodexModelID.isEmpty ? nil : preferredCodexModelID,
            preferredReasoningEffort: preferredCodexReasoningEffort.isEmpty
                ? nil
                : preferredCodexReasoningEffort
        )
    }

    private var selectedCodexProviderID: String {
        codexProviderCatalog.resolvedProviderID(
            preferredProviderID: preferredCodexProviderID.isEmpty ? nil : preferredCodexProviderID
        )
    }

    private var selectedCodexProviderOption: CodexProviderOption? {
        codexProviderCatalog.providers.first(where: { $0.id == selectedCodexProviderID })
    }

    private func codexProviderEndpointState(for provider: CodexProviderOption) -> CodexProviderEndpointState {
        guard provider.requiresEndpointProbe else { return .available }
        return codexProviderEndpointStates[provider.id] ?? .unknown
    }

    private func isCodexProviderAvailable(_ provider: CodexProviderOption) -> Bool {
        guard provider.isSelectable else { return false }
        return codexProviderEndpointState(for: provider) == .available
    }

    private func isCodexProviderMenuSelectable(_ provider: CodexProviderOption) -> Bool {
        guard provider.isSelectable else { return false }
        switch codexProviderEndpointState(for: provider) {
        case .checking, .unavailable:
            return false
        case .unknown, .available:
            return true
        }
    }

    private func codexEndpointUnavailableMessage(for provider: CodexProviderOption) -> String {
        String(
            format: String.l10n("agent.workspace.runtime.codexEndpointUnavailable"),
            locale: locale,
            provider.displayName
        )
    }

    private var codexCatalogTaskID: String {
        "\(viewModel.selectedAgentID):\(activeRuntimeBackend.rawValue):\(selectedCodexProviderID)"
    }

    /// 目录失败时保留 Codex 服务端默认行为：UI 不回退展示 BYOK 模型，turn/start 也不
    /// 发送 model/effort 覆盖。本机桥接端点是例外：必须先预检，避免 Codex 自己进入
    /// 多轮网络重试；用户启动桥接服务后可从模型菜单点击重试。
    @MainActor
    private func loadCodexModelCatalogIfNeeded() async {
        guard activeRuntimeBackend == .codexAppServer else { return }
        isLoadingCodexModelCatalog = true
        defer { isLoadingCodexModelCatalog = false }
        codexModelCatalogError = nil
        let providerID = selectedCodexProviderID
        if let provider = selectedCodexProviderOption, provider.requiresEndpointProbe {
            codexProviderEndpointStates[provider.id] = .checking
            configureAgentRuntime()
            let isAvailable = await CodexProviderEndpointProbe().isAvailable(provider)
            guard !Task.isCancelled,
                  activeRuntimeBackend == .codexAppServer,
                  selectedCodexProviderID == providerID
            else { return }
            codexProviderEndpointStates[provider.id] = isAvailable ? .available : .unavailable
            configureAgentRuntime()
            guard isAvailable else {
                codexModelCatalog = .empty
                codexModelCatalogError = codexEndpointUnavailableMessage(for: provider)
                return
            }
        }
        do {
            let client = try ExternalAgentRuntimePreferences.makeCodexModelCatalogClient(
                providerID: providerID
            )
            let catalog = try await client.load()
            guard !Task.isCancelled,
                  activeRuntimeBackend == .codexAppServer,
                  selectedCodexProviderID == providerID
            else { return }
            codexModelCatalog = catalog
            if let selection = selectedCodexModelSelection {
                preferredCodexModelID = selection.modelID
                preferredCodexReasoningEffort = selection.reasoningEffort ?? ""
            }
            configureAgentRuntime()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, activeRuntimeBackend == .codexAppServer else { return }
            codexModelCatalog = .empty
            codexModelCatalogError = error.localizedDescription
            configureAgentRuntime()
        }
    }

    private var deepSeekProviderOptions: [DeepSeekRuntimeProviderOption] {
        DeepSeekRuntimeProviderCatalog.providers(settings: dependencies.settings)
    }

    private var selectedDeepSeekSelection: DeepSeekRuntimeSelection? {
        DeepSeekRuntimeProviderCatalog.resolvedSelection(
            settings: dependencies.settings,
            preferredProviderID: preferredDeepSeekProviderID.isEmpty ? nil : preferredDeepSeekProviderID,
            preferredModelName: preferredDeepSeekModel,
            preferredReasoningEffort: preferredDeepSeekReasoningEffort.isEmpty
                ? nil
                : preferredDeepSeekReasoningEffort
        )
    }

    private var selectedBuiltinProviderProfile: AIProviderProfile? {
        guard let model = viewModel.availableModels.first(where: { $0.id == viewModel.selectedModelID }) else {
            return nil
        }
        return dependencies.settings.aiProviderProfiles.first(where: { $0.id == model.providerID })
    }

    private func normalizeRuntimeSelections() {
        codexProviderCatalog = CodexProviderCatalog.load()
        preferredCodexProviderID = selectedCodexProviderID
        normalizeDeepSeekSelection()
    }

    private func normalizeDeepSeekSelection() {
        guard let selection = selectedDeepSeekSelection else { return }
        preferredDeepSeekProviderID = selection.provider.id
        preferredDeepSeekModel = selection.model.name
        preferredDeepSeekReasoningEffort = selection.reasoningEffort ?? ""
    }

    private var selectedRuntimeBackend: AgentRuntimeBackend {
        guard dependencies.distributionGate.isAvailable(.externalAgentRuntime) else {
            return .builtinLoop
        }
        return AgentRuntimeBackend(rawValue: externalRuntimeBackendRawValue) ?? .builtinLoop
    }

    /// 全局偏好只表达用户上一次选择；真正展示和执行的后端必须服从当前 Agent 契约。
    private var activeRuntimeBackend: AgentRuntimeBackend {
        viewModel.selectedAgent?.runtimePolicy.resolvedBackend(for: selectedRuntimeBackend)
            ?? selectedRuntimeBackend
    }

    private var availableRuntimeBackends: [AgentRuntimeBackend] {
        guard let policy = viewModel.selectedAgent?.runtimePolicy else {
            return AgentRuntimeBackend.allCases
        }
        return AgentRuntimeBackend.allCases.filter(policy.allowedBackends.contains)
    }

    private var availableAgentDefinitions: [AgentDefinition] {
        guard dependencies.distributionGate.isAvailable(.externalAgentRuntime) else {
            return BuiltInAgents.all
        }
        return ExternalAgentDefinitions.all + BuiltInAgents.all
    }

    /// 模型提示词使用英文语言名，避免只支持中英文而让其它 App locale 静默回退英语。
    private var preferredOutputLanguage: String {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        if languageCode == "zh" {
            return locale.language.script?.identifier == "Hant" ? "Traditional Chinese" : "Simplified Chinese"
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? languageCode
    }

    // MARK: - Agent Rail

    private var agentRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(AgentWorkspaceTaxonomy.sections) { section in
                        let agents = AgentWorkspaceTaxonomy.agents(in: section, from: viewModel.agents)
                        if !agents.isEmpty {
                            agentSection(section.titleKey, agents: agents)
                        }
                    }
                    historySection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 工作台胶囊标识（Beta / Preview 等），与左侧 Agent 列表行内 Preview 标识同构。
    private func agentWorkspaceBadge(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(agentFont(.caption2, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var railHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(agentIconFont(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("agent.workspace.title")
                            .font(agentFont(.headline))
                        agentWorkspaceBadge("agent.workspace.badge.beta")
                    }
                    Text("agent.workspace.subtitle")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

        }
        .padding(14)
    }

    private func agentSection(_ titleKey: String, agents: [AgentDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            ForEach(agents) { agent in
                agentButton(agent)
            }
        }
    }

    private func agentButton(_ agent: AgentDefinition) -> some View {
        Button {
            viewModel.selectAgent(agent)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agent.systemImage)
                    .font(agentIconFont(size: 17, weight: .regular))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(agent.id == viewModel.selectedAgentID ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(agent.title)
                            .font(agentFont(.subheadline, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !agent.isEnabled {
                            agentWorkspaceBadge("agent.workspace.badge.preview")
                        }
                    }

                    Text(agent.subtitle)
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        ForEach(agent.capabilityLabels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(agentFont(.caption2))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .separatorColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(agent.id == viewModel.selectedAgentID ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(agent.id == viewModel.selectedAgentID ? Color.accentColor.opacity(0.24) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!agent.isEnabled || viewModel.isRunning)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("agent.workspace.history.title")
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            if viewModel.historyRuns.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("agent.workspace.history.empty")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(11)
                .background(Color(nsColor: .separatorColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(AgentHistoryPresentation.visibleRuns(
                    viewModel.historyRuns,
                    isExpanded: isHistoryExpanded
                )) { run in
                    historyRunButton(run)
                }

                if viewModel.historyRuns.count > AgentHistoryPresentation.collapsedLimit {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isHistoryExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isHistoryExpanded ? "chevron.up" : "ellipsis.circle")
                                .frame(width: 18)
                            Text(historyDisclosureTitle)
                                .font(agentFont(.caption, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }

    private var historyDisclosureTitle: String {
        if isHistoryExpanded {
            return String.l10n("agent.workspace.history.collapse")
        }
        let remainingCount = viewModel.historyRuns.count - AgentHistoryPresentation.collapsedLimit
        return String(
            format: String.l10n("agent.workspace.history.moreFormat"),
            locale: locale,
            remainingCount
        )
    }

    private func historyRunButton(_ run: AgentRunRecord) -> some View {
        let isSelected = viewModel.selectedHistoryRunID == run.id
        return Button {
            Task {
                await viewModel.openHistoryRun(run)
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: historyIcon(for: run.status))
                    .foregroundStyle(historyTint(for: run.status))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title)
                        .font(agentFont(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(historySubtitle(run))
                        .font(agentFont(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(viewModel.isRunning)
    }

    private func historySubtitle(_ run: AgentRunRecord) -> String {
        "\(historyStatusLabel(for: run.status)) · \(historyTimeLabel(for: run.createdAt))"
    }

    private func historyStatusLabel(for status: String) -> String {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return String.l10n("agent.workspace.status.completed")
        case .failed:
            return String.l10n("agent.workspace.status.failed")
        case .cancelled:
            return String.l10n("agent.workspace.status.cancelled")
        case .planning:
            return String.l10n("agent.workspace.status.planning")
        case .running:
            return String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation:
            return String.l10n("agent.workspace.status.waitingForConfirmation")
        case .idle, .none:
            return String.l10n("agent.workspace.status.idle")
        }
    }

    private func historyTimeLabel(for raw: String) -> String {
        guard let date = ISO8601DateFormatter.shared.date(from: raw) else {
            return raw
        }
        return RelativeTimeText.pastEvent(date, locale: locale)
    }

    private func historyIcon(for status: String) -> String {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "pause.circle.fill"
        case .planning, .running, .waitingForConfirmation:
            return "circle.dotted"
        case .idle, .none:
            return "clock"
        }
    }

    private func historyTint(for status: String) -> Color {
        switch AgentRunStatus(rawValue: status) {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        case .planning, .running, .waitingForConfirmation:
            return .accentColor
        case .idle, .none:
            return .secondary
        }
    }

    // MARK: - Run Surface

    private var runSurface: some View {
        VStack(spacing: 0) {
            runHeader
            Divider()
            ZStack(alignment: .bottom) {
                runTimeline

                if viewModel.isContextPickerPresented {
                    agentContextPicker
                        .padding(.horizontal, 16)
                        .padding(.bottom, Self.contextPickerPanelGap)
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 与 RAG `answerHeader` 同构：headline + caption + 上下 11pt，保证 Inspector 分割线水平对齐。
    private var runHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedAgent?.title ?? String.l10n("agent.workspace.window.title"))
                    .font(agentFont(.headline, weight: .semibold))
                    .lineLimit(1)
                Text(viewModel.runTitle)
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(activeRuntimeBackend.displayName)
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var runTimeline: some View {
        AgentMessageTimelineView(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Artifact Inspector

    private var artifactInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunInspectorHeader(viewModel: viewModel)
            Divider()
            AgentRunInspectorView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.selectedRepoContexts.isEmpty || !viewModel.githubLinks.isEmpty {
                composerContextSection
                    .padding(.horizontal, 18)
            }

            agentComposerInputBox
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var agentComposerInputBox: some View {
        let canSubmit = viewModel.canSubmit
        let requiresCommandReturn = dependencies.settings.aiChatRequiresCommandReturn
        return AICommandComposerView {
            if !viewModel.attachments.isEmpty {
                attachmentStrip
            }

            if viewModel.selectedAgentRequiresRepositories, viewModel.selectedRepoContexts.isEmpty {
                Label("agent.workspace.context.singleRepositoryRequired", systemImage: "shippingbox")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }

            if case .weeklyHotspots = viewModel.selectedAgent?.workflow.repositoryContext,
               viewModel.selectedRepoContexts.isEmpty {
                Label("agent.workspace.context.weeklyHotspotsAutomatic", systemImage: "calendar.badge.clock")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }

            if activeRuntimeBackend == .builtinLoop, viewModel.selectedModelID == nil {
                Label("agent.workspace.model.required", systemImage: "sparkles")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            } else if activeRuntimeBackend == .deepSeekHarness, selectedDeepSeekSelection == nil {
                Label("agent.workspace.runtime.providerRequired", systemImage: "server.rack")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            } else if activeRuntimeBackend == .codexAppServer,
                      let credentialKey = selectedCodexProviderOption?.credentialEnvironmentKey {
                Label(
                    String(
                        format: String.l10n("agent.workspace.runtime.codexCredentialBlocked"),
                        locale: locale,
                        credentialKey
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
            } else if activeRuntimeBackend == .codexAppServer,
                      let provider = selectedCodexProviderOption,
                      codexProviderEndpointState(for: provider) == .unavailable {
                Label(
                    codexEndpointUnavailableMessage(for: provider),
                    systemImage: "exclamationmark.triangle"
                )
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
            }

            AICommandTextEditor(
                text: $viewModel.prompt,
                placeholder: String.l10n("agent.workspace.composer.placeholder"),
                font: composerNSFont,
                maximumHeight: composerMaximumHeight,
                isEditable: !viewModel.isRunning,
                onHeightChange: { composerContentHeight = $0 },
                onMentionAnchorChange: { _ in },
                onCommand: handleComposerCommand
            )
            .frame(height: composerEditorHeight)
            .onChange(of: viewModel.prompt) { _, _ in
                viewModel.handlePromptChanged()
            }

            HStack(spacing: 8) {
                Button { viewModel.presentContextPicker() } label: {
                    Image(systemName: "plus")
                        .font(agentFont(.caption, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .disabled(viewModel.isRunning || !viewModel.selectedAgentSupportsRepositorySelection)
                .help("agent.workspace.repositoryPicker.title")

                if dependencies.distributionGate.isAvailable(.externalAgentRuntime) {
                    runtimeBackendMenu
                }

                agentRuntimeModelControls

                if !viewModel.selectedRepoContexts.isEmpty,
                   case .weeklyHotspots = viewModel.selectedAgent?.workflow.repositoryContext {
                    explicitModeMenu
                }

                Spacer()

                Button {
                    viewModel.attachTextFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(agentFont(.caption))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("agent.workspace.attachment.help")
                .disabled(viewModel.isRunning)

                Button {
                    viewModel.webSearchEnabled.toggle()
                } label: {
                    Image(systemName: "globe")
                        .font(agentFont(.caption))
                        .foregroundStyle(viewModel.webSearchEnabled ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            viewModel.webSearchEnabled ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(viewModel.isRunning || !dependencies.settings.externalContextEnabled)
                .help(viewModel.webSearchEnabled
                      ? "rag.workspace.composer.webSearch.on"
                      : "rag.workspace.composer.webSearch.off")

                Button {
                    if viewModel.isRunning {
                        viewModel.cancel()
                    } else {
                        viewModel.run()
                    }
                } label: {
                    Image(systemName: viewModel.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(agentFont(.title2))
                        .foregroundStyle(viewModel.isRunning || canSubmit ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!viewModel.isRunning && !canSubmit)
                .help(
                    viewModel.isRunning
                        ? "rag.workspace.composer.cancel"
                        : requiresCommandReturn
                        ? "settings.general.shortcuts.aiCommandReturn.description.on"
                        : "settings.general.shortcuts.aiCommandReturn.description.off"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private var composerNSFont: NSFont {
        NSFont.systemFont(ofSize: interfaceScale.scaled(StarcatTypography.body.pointSize))
    }

    private var composerMinimumHeight: CGFloat {
        let lineHeight = composerNSFont.ascender - composerNSFont.descender + composerNSFont.leading
        return ceil(lineHeight * 2 + AICommandTextEditor.verticalInset * 2)
    }

    private var composerMaximumHeight: CGFloat { 118 * interfaceScale.multiplier }

    private var composerEditorHeight: CGFloat {
        min(max(composerContentHeight, composerMinimumHeight), composerMaximumHeight)
    }

    private func handleComposerCommand(_ command: AICommandTextEditor.Command) -> Bool {
        switch command {
        case .mentionTrigger:
            return viewModel.handleMentionTrigger()
        case .returnKey(let modifiers):
            if viewModel.isContextPickerPresented, !modifiers.contains(.command) {
                viewModel.selectHighlightedMention()
                return true
            }
            switch AIComposerKeyboardPolicy.action(
                for: modifiers,
                requiresCommandReturn: dependencies.settings.aiChatRequiresCommandReturn
            ) {
            case .send:
                if viewModel.isRunning {
                    viewModel.cancel()
                } else {
                    guard viewModel.canSubmit else { return true }
                    viewModel.run()
                }
                return true
            case .insertNewline:
                return false
            }
        case .upArrow:
            guard viewModel.isContextPickerPresented else { return false }
            viewModel.moveMentionSelection(by: -1)
            return true
        case .downArrow:
            guard viewModel.isContextPickerPresented else { return false }
            viewModel.moveMentionSelection(by: 1)
            return true
        case .escape:
            return viewModel.handleContextPickerEscape()
        }
    }

    private func composerContextChip(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
        }
        .font(agentFont(.caption))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private var composerContextFlow: some View {
        RAGFlowLayout(spacing: 7) {
            ForEach(viewModel.selectedRepoContexts) { reference in
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    Text(reference.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Button { viewModel.removeRepoContext(reference) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .font(agentFont(.caption))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
            }

            ForEach(viewModel.githubLinks) { link in
                composerContextChip("\(link.owner)/\(link.repository)", icon: "link")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerContextCollapsedHeight: CGFloat {
        interfaceScale.scaled(32)
    }

    /// 与 RAG Composer 相同：一行放得下时直接展示，超过一行才折叠为摘要，避免大量
    /// 已选仓库持续挤占消息区；右侧清空按钮始终可见。
    private var composerContextSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isComposerContextExpanded {
                HStack(spacing: 8) {
                    composerContextDisclosureButton(isExpanded: true)
                    clearComposerContextButton
                }
                composerContextFlow
            } else {
                HStack(spacing: 8) {
                    ViewThatFits(in: .vertical) {
                        composerContextFlow
                            .fixedSize(horizontal: false, vertical: true)
                        composerContextDisclosureButton(isExpanded: false)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: composerContextCollapsedHeight,
                        maxHeight: composerContextCollapsedHeight,
                        alignment: .topLeading
                    )
                    clearComposerContextButton
                }
            }
        }
    }

    private func composerContextDisclosureButton(isExpanded: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isComposerContextExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(agentFont(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("agent.workspace.composer.contextDisclosure")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if !viewModel.selectedRepoContexts.isEmpty {
                    Label(viewModel.selectedRepoContexts.count.formatted(), systemImage: "shippingbox")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                if !viewModel.githubLinks.isEmpty {
                    Label(viewModel.githubLinks.count.formatted(), systemImage: "link")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: composerContextCollapsedHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var clearComposerContextButton: some View {
        if !viewModel.selectedRepoContexts.isEmpty {
            Button {
                isComposerContextExpanded = false
                viewModel.clearSelectedRepoContexts()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(agentFont(.body, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("agent.workspace.composer.clearContext")
        }
    }

    /// Agent 与 RAG 共用同一种仓库选择交互，但候选范围仍由各自 ViewModel 决定。
    /// Agent 搜索全部已知项目；Star、知识库和公共 Feed 都只是可选筛选维度。
    private var agentContextPicker: some View {
        // 一个 body 周期只读取一次缓存投影，避免 header/list/footer 分别触发派生读取，
        // 也保证筛选结果计数和本轮显示行来自同一份快照。
        let candidates = viewModel.displayedMentionCandidates
        let totalCount = viewModel.repositoryPickerTotalCount
        let matchCount = viewModel.repositoryPickerMatchCount
        let isTruncated = viewModel.isRepositoryPickerTruncated
        return VStack(alignment: .leading, spacing: 0) {
            agentContextPickerHeader(totalCount: totalCount)
            Divider()

            HStack(spacing: 8) {
                RAGContextPickerFilterControls(
                    sortOption: $viewModel.repositoryPickerSortOption,
                    filters: $viewModel.repositoryPickerFilters,
                    isFilterPresented: $viewModel.isContextPickerFilterPresented,
                    isLanguageAddPresented: $viewModel.isContextPickerLanguageAddPresented,
                    includeSignalFilters: false,
                    sortOptions: agentRepositorySortOptions,
                    additionalFilterItems: agentRepositorySourceFilterItems,
                    isAdditionalFilterActive: !viewModel.selectedRepositorySources.isEmpty,
                    onReset: { viewModel.resetRepositoryPickerFilters() }
                )

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                    TextField("agent.workspace.repositoryPicker.searchPlaceholder", text: $viewModel.contextPickerQuery)
                        .textFieldStyle(.plain)
                        .font(agentFont(.callout))
                        .focused($isContextPickerSearchFocused)
                        .onChange(of: viewModel.contextPickerQuery) { _, _ in
                            viewModel.handleContextPickerQueryChanged()
                        }
                        .onSubmit {
                            viewModel.selectHighlightedMention()
                        }
                        .onExitCommand {
                            _ = viewModel.handleContextPickerEscape()
                        }
                    if !viewModel.contextPickerQuery.isEmpty {
                        Button {
                            viewModel.clearContextPickerQuery()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(agentFont(.caption))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("agent.workspace.repositoryPicker.clearFilter")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            if candidates.isEmpty {
                Text("agent.workspace.repositoryPicker.emptyFilter")
                    .font(agentFont(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            agentContextPickerRow(candidate, index: index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isTruncated {
                Divider()
                Text(String(
                    format: String.l10n("agent.workspace.repositoryPicker.narrowHint"),
                    locale: locale,
                    candidates.count,
                    matchCount
                ))
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 5)
        .frame(height: Self.contextPickerPanelHeight)
        .onAppear { isContextPickerSearchFocused = true }
        .onChange(of: viewModel.isContextPickerPresented) { _, presented in
            isContextPickerSearchFocused = presented
        }
        .appLocaleEnvironment()
    }

    private func agentContextPickerHeader(totalCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(String(
                format: String.l10n("agent.workspace.repositoryPicker.stats"),
                locale: locale,
                viewModel.selectedRepoContexts.count,
                viewModel.maximumSelectedRepoContexts,
                totalCount
            ))
            .font(agentFont(.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                viewModel.clearSelectedRepoContexts()
            } label: {
                Text("agent.workspace.repositoryPicker.clearSelected")
                    .font(agentFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .disabled(viewModel.selectedRepoContexts.isEmpty)
            .help("agent.workspace.repositoryPicker.clearSelected")

            Button {
                viewModel.dismissContextPicker()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var agentRepositorySortOptions: [RepoSortOption] {
        [.updatedDesc, .updatedAsc, .starsDesc, .starsAsc, .createdDesc, .createdAsc, .nameAsc, .nameDesc]
    }

    private var agentRepositorySourceFilterItems: [FilterMenuItem] {
        [.content(id: "agent-repository-sources", view: AnyView(agentRepositorySourceFilterSection))]
    }

    /// 来源是 Agent 筛选面板中的多选分组。多项之间按 OR 匹配，点选时保持面板打开，
    /// 便于连续组合 Weekly / Trending / Discovery 等数据来源。
    private var agentRepositorySourceFilterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("agent.workspace.repositoryPicker.source.title", systemImage: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            ForEach(AgentRepositorySource.allCases, id: \.self) { source in
                Toggle(isOn: repositorySourceBinding(source)) {
                    Label(source.title, systemImage: source.systemImage)
                }
            }
        }
    }

    private func repositorySourceBinding(_ source: AgentRepositorySource) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedRepositorySources.contains(source) },
            set: { isSelected in
                if isSelected {
                    viewModel.selectedRepositorySources.insert(source)
                } else {
                    viewModel.selectedRepositorySources.remove(source)
                }
                viewModel.highlightedMentionIndex = 0
            }
        )
    }

    private func agentContextPickerRow(_ candidate: RAGMentionCandidate, index: Int) -> some View {
        let isSelected = viewModel.selectedRepoContexts.contains { $0.id == candidate.id }
        let selectionFull = viewModel.selectedRepoContexts.count >= viewModel.maximumSelectedRepoContexts
        let canToggle = isSelected || !selectionFull
        return Button {
            viewModel.toggleRepoContext(candidate)
        } label: {
            UnifiedCompactRepoRow(
                fullName: candidate.fullName,
                owner: candidate.owner,
                ownerAvatarURL: candidate.ownerAvatar,
                language: candidate.language,
                starsCount: candidate.starsCount,
                isChecked: isSelected,
                isHighlighted: index == viewModel.highlightedMentionIndex,
                isEnabled: canToggle
            ) {
                HStack(spacing: 4) {
                    ForEach(viewModel.repositorySources(for: candidate.id).prefix(2), id: \.self) { source in
                        Image(systemName: source.systemImage)
                            .font(agentFont(.caption2))
                            .foregroundStyle(.secondary)
                            .help(source.title)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canToggle)
        .help(
            canToggle
                ? Text(candidate.fullName)
                : Text(String(
                    format: String.l10n("agent.workspace.repositoryPicker.selectionLimit"),
                    locale: locale,
                    viewModel.maximumSelectedRepoContexts
                ))
        )
    }

    private var agentModelMenu: some View {
        Menu {
            ForEach(builtinModelsForSelectedProvider) { model in
                Button {
                    viewModel.selectedModelID = model.id
                } label: {
                    if model.id == viewModel.selectedModelID {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            Label(viewModel.selectedModelDisplayName, systemImage: "sparkles")
                .font(agentFont(.caption, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning || viewModel.availableModels.isEmpty)
        .help("rag.workspace.composer.model")
    }

    private var builtinModelsForSelectedProvider: [AIModelDescriptor] {
        guard let providerID = selectedBuiltinProviderProfile?.id else { return viewModel.availableModels }
        return viewModel.availableModels.filter { $0.providerID == providerID }
    }

    private var builtinProviderMenu: some View {
        Menu {
            ForEach(dependencies.settings.aiProviderProfiles.filter(\.isVerifiedConfiguration)) { profile in
                let firstModel = viewModel.availableModels.first(where: { $0.providerID == profile.id })
                Button {
                    if let firstModel { viewModel.selectedModelID = firstModel.id }
                } label: {
                    if profile.id == selectedBuiltinProviderProfile?.id {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
                .disabled(firstModel == nil)
            }
        } label: {
            Label(selectedBuiltinProviderProfile?.displayName ?? "Provider", systemImage: "server.rack")
                .font(agentFont(.caption, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
        .help(String.l10n("agent.workspace.runtime.provider"))
    }

    /// Runtime 选择是 Direct 工作台的正式产品状态，和 Provider / Model 分开呈现。
    /// App Store 不显示该入口，并由 DistributionGate 在路由层再次强制使用内置 Loop。
    private var runtimeBackendMenu: some View {
        Menu {
            ForEach(availableRuntimeBackends, id: \.self) { backend in
                Button {
                    externalRuntimeBackendRawValue = backend.rawValue
                } label: {
                    if backend == activeRuntimeBackend {
                        Label(backend.displayName, systemImage: "checkmark")
                    } else {
                        Text(backend.displayName)
                    }
                }
            }
        } label: {
            Label(activeRuntimeBackend.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                .font(agentFont(.caption, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
        .help(String.l10n("agent.workspace.runtime.backend"))
    }

    @ViewBuilder
    private var agentRuntimeModelControls: some View {
        switch activeRuntimeBackend {
        case .codexAppServer:
            codexProviderMenu
            if isLoadingCodexModelCatalog, codexModelCatalog.models.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
            codexModelMenu
            if let selectedModel = selectedCodexModelOption,
               !selectedModel.supportedReasoningEfforts.isEmpty {
                codexReasoningEffortMenu(selectedModel)
            }
        case .deepSeekHarness:
            deepSeekProviderMenu
            deepSeekModelMenu
            if let model = selectedDeepSeekSelection?.model,
               !model.supportedReasoningEfforts.isEmpty {
                deepSeekReasoningEffortMenu(model)
            }
        case .builtinLoop:
            builtinProviderMenu
            agentModelMenu
        }
    }

    private var codexProviderMenu: some View {
        Menu {
            ForEach(codexProviderCatalog.providers) { provider in
                Button {
                    preferredCodexProviderID = provider.id
                } label: {
                    if provider.id == selectedCodexProviderID {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
                .disabled(!isCodexProviderMenuSelectable(provider))
                .help(
                    provider.credentialEnvironmentKey.map { key in
                        String(
                            format: String.l10n("agent.workspace.runtime.codexCredentialBlocked"),
                            locale: locale,
                            key
                        )
                    } ?? (codexProviderEndpointState(for: provider) == .unavailable
                        ? codexEndpointUnavailableMessage(for: provider)
                        : provider.displayName)
                )
            }
        } label: {
            Label(
                selectedCodexProviderOption?.displayName ?? selectedCodexProviderID,
                systemImage: selectedCodexProviderOption.map(isCodexProviderAvailable) == false
                    ? "exclamationmark.triangle"
                    : "server.rack"
            )
                .font(agentFont(.caption, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
        .help(String.l10n("agent.workspace.runtime.codexProviderHelp"))
    }

    private var deepSeekProviderMenu: some View {
        Menu {
            if deepSeekProviderOptions.isEmpty {
                Text("agent.workspace.runtime.noVerifiedProvider")
            } else {
                ForEach(deepSeekProviderOptions) { provider in
                    Button {
                        preferredDeepSeekProviderID = provider.id
                        preferredDeepSeekModel = provider.models.first?.name ?? ""
                        preferredDeepSeekReasoningEffort = ""
                    } label: {
                        if provider.id == selectedDeepSeekSelection?.provider.id {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            }
        } label: {
            Label(
                selectedDeepSeekSelection?.provider.displayName ?? String.l10n("agent.workspace.runtime.provider"),
                systemImage: "server.rack"
            )
            .font(agentFont(.caption, weight: .semibold))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning || deepSeekProviderOptions.isEmpty)
        .help(String.l10n("agent.workspace.runtime.deepSeekProviderHelp"))
    }

    private var deepSeekModelMenu: some View {
        Menu {
            ForEach(selectedDeepSeekSelection?.provider.models ?? []) { model in
                Button {
                    preferredDeepSeekModel = model.name
                    preferredDeepSeekReasoningEffort = ""
                } label: {
                    if model.name == selectedDeepSeekSelection?.model.name {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            Label(selectedDeepSeekSelection?.model.name ?? "—", systemImage: "sparkles")
                .font(agentFont(.caption, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning || selectedDeepSeekSelection == nil)
        .help(String.l10n("rag.workspace.composer.model"))
    }

    private func deepSeekReasoningEffortMenu(_ model: DeepSeekRuntimeModelOption) -> some View {
        Menu {
            Button {
                preferredDeepSeekReasoningEffort = ""
            } label: {
                if preferredDeepSeekReasoningEffort.isEmpty {
                    Label("agent.workspace.runtime.default", systemImage: "checkmark")
                } else {
                    Text("agent.workspace.runtime.default")
                }
            }
            Divider()
            ForEach(model.supportedReasoningEfforts, id: \.self) { effort in
                Button {
                    preferredDeepSeekReasoningEffort = effort
                } label: {
                    if effort == preferredDeepSeekReasoningEffort {
                        Label(reasoningEffortDisplayName(effort), systemImage: "checkmark")
                    } else {
                        Text(reasoningEffortDisplayName(effort))
                    }
                }
            }
        } label: {
            Label(
                preferredDeepSeekReasoningEffort.isEmpty
                    ? String.l10n("agent.workspace.runtime.default")
                    : reasoningEffortDisplayName(preferredDeepSeekReasoningEffort),
                systemImage: "brain"
            )
            .font(agentFont(.caption, weight: .semibold))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
    }

    private var selectedCodexModelOption: CodexModelOption? {
        guard let selection = selectedCodexModelSelection else { return nil }
        return codexModelCatalog.models.first(where: { $0.id == selection.modelID })
    }

    private var codexModelMenu: some View {
        Menu {
            if codexModelCatalog.models.isEmpty {
                Button("action.retry") {
                    Task { await loadCodexModelCatalogIfNeeded() }
                }
                .disabled(isLoadingCodexModelCatalog)
            } else {
                ForEach(codexModelCatalog.models) { model in
                    Button {
                        preferredCodexModelID = model.id
                        let selection = codexModelCatalog.resolvedSelection(
                            preferredModelID: model.id,
                            preferredReasoningEffort: preferredCodexReasoningEffort
                        )
                        preferredCodexReasoningEffort = selection?.reasoningEffort ?? ""
                    } label: {
                        if model.id == selectedCodexModelSelection?.modelID {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
        } label: {
            Label(
                selectedCodexModelSelection?.displayName ?? "Codex",
                systemImage: codexModelCatalogError == nil ? "sparkles" : "exclamationmark.triangle"
            )
            .font(agentFont(.caption, weight: .semibold))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
        .help(codexModelCatalogError ?? String.l10n("rag.workspace.composer.model"))
    }

    private func codexReasoningEffortMenu(_ model: CodexModelOption) -> some View {
        Menu {
            ForEach(model.supportedReasoningEfforts) { effort in
                Button {
                    preferredCodexReasoningEffort = effort.reasoningEffort
                } label: {
                    if effort.reasoningEffort == selectedCodexModelSelection?.reasoningEffort {
                        Label(reasoningEffortDisplayName(effort.reasoningEffort), systemImage: "checkmark")
                    } else {
                        Text(reasoningEffortDisplayName(effort.reasoningEffort))
                    }
                }
            }
        } label: {
            Label(
                reasoningEffortDisplayName(selectedCodexModelSelection?.reasoningEffort ?? ""),
                systemImage: "brain"
            )
            .font(agentFont(.caption, weight: .semibold))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning)
    }

    private func reasoningEffortDisplayName(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": "X-High"
        default: effort.capitalized
        }
    }

    private var explicitModeMenu: some View {
        Menu {
            Picker("", selection: $viewModel.explicitRepoMode) {
                Text("rag.workspace.repoMode.only").tag(AIComposerExplicitRepoMode.only)
                Text("rag.workspace.repoMode.prefer").tag(AIComposerExplicitRepoMode.prefer)
                Text("rag.workspace.repoMode.exclude").tag(AIComposerExplicitRepoMode.exclude)
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Label(repoModeKey(viewModel.explicitRepoMode), systemImage: "scope")
                .font(agentFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.isRunning || viewModel.selectedRepoContexts.isEmpty)
        .help("rag.workspace.composer.scope")
    }

    private func repoModeKey(_ mode: AIComposerExplicitRepoMode) -> LocalizedStringKey {
        switch mode {
        case .only: return "rag.workspace.repoMode.only"
        case .prefer: return "rag.workspace.repoMode.prefer"
        case .exclude: return "rag.workspace.repoMode.exclude"
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(viewModel.attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(attachment.name)
                            .lineLimit(1)
                        Button {
                            viewModel.removeAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("agent.workspace.attachment.remove")
                    }
                    .font(agentFont(.caption))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Helpers

    private enum AgentFontRole {
        case title2
        case headline
        case subheadline
        case body
        case callout
        case caption
        case caption2

        /// Maps local workspace roles onto the shared `DESIGN.md` typography tokens.
        var typography: StarcatTypography {
            switch self {
            case .title2:          return .workspaceTitle
            case .headline:        return .panelTitle
            case .subheadline:     return .rowTitle
            case .body:            return .body
            case .callout:         return .bodyEmphasis
            case .caption:         return .caption
            case .caption2:        return .captionSmall
            }
        }
    }

    private func agentFont(
        _ role: AgentFontRole,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func agentIconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    /// 原生 Sidebar 与 Inspector 都会连续报告尺寸；静止 250ms 后才保存最终值。
    private func scheduleLeftWidthPersistence(_ measuredWidth: CGFloat) {
        guard !chromeState.isLeftColumnCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.leftMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedLeftWidth(Double(measuredWidth))
        lastMeasuredLeftColumnWidth = width
        guard abs(CGFloat(persistedLeftColumnWidth) - width) > 0.5 else { return }

        leftWidthPersistenceTask?.cancel()
        leftWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedLeftColumnWidth = Double(width)
        }
    }

    private func scheduleRightWidthPersistence(_ measuredWidth: CGFloat) {
        guard !chromeState.isRightColumnCollapsed,
              measuredWidth >= AgentWorkspaceLayoutMetrics.rightMinimumWidth else { return }

        let width = AgentWorkspaceLayoutMetrics.clampedRightWidth(Double(measuredWidth))
        lastMeasuredRightColumnWidth = width
        guard abs(CGFloat(persistedRightColumnWidth) - width) > 0.5 else { return }

        rightWidthPersistenceTask?.cancel()
        rightWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedRightColumnWidth = Double(width)
        }
    }

    private func persistLastMeasuredWidths() {
        if let width = lastMeasuredLeftColumnWidth {
            persistedLeftColumnWidth = Double(width)
        }
        if let width = lastMeasuredRightColumnWidth {
            persistedRightColumnWidth = Double(width)
        }
    }

}
