//
//  AgentWorkspaceView.swift
//  Starcat
//
//  Agent 独立 Workspace Window 的三栏内容视图。
//
//  本视图是所有内置 Agent 的唯一工作台壳子。Agent 只提供定义与运行事实，页面结构
//  保持统一，避免 Weekly / Repo Insight 等能力各自长出一套不可复用的 UI。
//

import AppKit
import SwiftUI

struct AgentWorkspaceView: View {

    private static let contextPickerPanelHeight: CGFloat = 420
    private static let contextPickerPanelGap: CGFloat = 12

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = AgentWorkspaceViewModel()
    @State private var composerContentHeight: CGFloat = 0
    @State private var isComposerContextExpanded = false
    @FocusState private var isContextPickerSearchFocused: Bool
    let chromeState: WorkspaceChromeState

    var body: some View {
        HStack(spacing: 0) {
            if !chromeState.isLeftColumnCollapsed {
                agentRail
                    .frame(width: 312)
                Divider()
            }
            runSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .task {
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
            configureAgentRuntime()
            await viewModel.reloadHistory()
        }
        .onChange(of: viewModel.selectedModelID) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in
            configureAgentRuntime()
        }
        .onChange(of: locale.identifier) { _, _ in
            viewModel.refreshLocalizedDefinitions(BuiltInAgents.all)
            configureAgentRuntime()
        }
        .animation(.easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(.easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    /// 每次模型选择变化都重建尚未启动的 Runtime；已经运行的实例由 ViewModel 拒绝替换，
    /// 从而保证一次 run 从首个 token 到最终 artifact 始终使用同一模型。
    private func configureAgentRuntime() {
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
        do {
            let tagCapability = RepositoryTagCapabilityExecutor(
                source: DatabaseRepositoryTagCapabilitySource(
                    repoRepository: dependencies.repoRepository,
                    tagRepository: dependencies.tagRepository,
                    repoTagRepository: dependencies.repoTagRepository
                )
            )
            let toolRegistry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: externalSearchTool,
                knowledgeTool: AgentKnowledgeTool(searcher: knowledgeSearcher),
                additionalTools: UntaggedTidyAgentTools.make(executor: tagCapability)
            ))
            let modelClient = try AgentLoopModelClientFactory.make(
                settings: dependencies.settings,
                selectedModelID: viewModel.selectedModelID
            )
            viewModel.configureRuntime(LoopAgentRuntime(
                modelClient: modelClient,
                toolRegistry: toolRegistry,
                runRepository: dependencies.agentRunRepository,
                mode: viewModel.selectedAgent?.workflow.executionMode ?? .readonlyPlanning,
                localeIdentifier: locale.identifier,
                preferredLanguage: preferredOutputLanguage,
                externalSearchPolicy: AgentExternalSearchPolicy.current(settings: dependencies.settings)
            ))
        } catch {
            viewModel.configureRuntime(UnavailableAgentRuntime(message: error.localizedDescription))
        }
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
                    agentSection("agent.workspace.section.discovery", agents: viewModel.agents.filter { ["github-weekly-report", "repo-alternatives"].contains($0.id) })
                    agentSection("agent.workspace.section.digest", agents: viewModel.agents.filter { ["repo-insight", "release-watcher"].contains($0.id) })
                    agentSection("agent.workspace.section.organize", agents: viewModel.agents.filter { ["overlap-scan", "untagged-tidy"].contains($0.id) })
                    historySection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                    Text("agent.workspace.title")
                        .font(agentFont(.headline))
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
                            Text("agent.workspace.badge.preview")
                                .font(agentFont(.caption2, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
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
                ForEach(viewModel.historyRuns) { run in
                    historyRunButton(run)
                }
            }
        }
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
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        runTimeline

                        if viewModel.isContextPickerPresented {
                            agentContextPicker
                                .padding(.horizontal, 16)
                                .padding(.bottom, Self.contextPickerPanelGap)
                                .zIndex(1)
                        }
                    }
                    Divider()
                    composer
                }
                .frame(minWidth: 460, idealWidth: 560)
                .layoutPriority(1)
                if !chromeState.isRightColumnCollapsed {
                    Divider()
                    artifactInspector
                        .frame(minWidth: 430, idealWidth: 520)
                }
            }
        }
    }

    private var runHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.selectedAgent?.title ?? String.l10n("agent.workspace.window.title"))
                    .font(agentFont(.title3, weight: .semibold))
                Text("agent.workspace.header.subtitle")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var runTimeline: some View {
        AgentMessageTimelineView(viewModel: viewModel)
    }

    // MARK: - Artifact Inspector

    private var artifactInspector: some View {
        AgentRunInspectorView(viewModel: viewModel)
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

            if viewModel.selectedModelID == nil {
                Label("agent.workspace.model.required", systemImage: "sparkles")
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

                agentModelMenu

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
            ForEach(viewModel.availableModels) { model in
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
        case title3
        case headline
        case subheadline
        case body
        case callout
        case caption
        case caption2

        /// Maps local workspace roles onto the shared `DESIGN.md` typography tokens.
        var typography: StarcatTypography {
            switch self {
            case .title2, .title3: return .workspaceTitle
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

}
