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

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var viewModel = AgentWorkspaceViewModel()
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
            viewModel.configureContextProvider(RepositoryAgentRunContextProvider(
                repository: dependencies.repoRepository
            ))
            viewModel.configureRunRepository(dependencies.agentRunRepository)
            let externalSearchTool = ExternalSearchAgentTool(
                collector: AppSettingsAgentExternalSearchCollector(settings: dependencies.settings)
            )
            do {
                let toolRegistry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                    externalSearchTool: externalSearchTool
                ))
                let modelClient = try AgentLoopModelClientFactory.make(settings: dependencies.settings)
                viewModel.configureRuntime(LoopAgentRuntime(
                    modelClient: modelClient,
                    toolRegistry: toolRegistry,
                    runRepository: dependencies.agentRunRepository,
                    localeIdentifier: locale.identifier,
                    preferredLanguage: locale.language.languageCode?.identifier == "zh" ? "Simplified Chinese" : "English",
                    externalSearchPolicy: AgentExternalSearchPolicy.current(settings: dependencies.settings)
                ))
            } catch {
                viewModel.configureRuntime(UnavailableAgentRuntime(message: error.localizedDescription))
            }
            await viewModel.reloadHistory()
        }
        .animation(.easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(.easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    // MARK: - Agent Rail

    private var agentRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agentSection("agent.workspace.section.discovery", agents: viewModel.agents.filter { ["github-weekly-report", "repo-alternatives"].contains($0.id) })
                    agentSection("agent.workspace.section.digest", agents: viewModel.agents.filter { ["recall-search", "repo-insight"].contains($0.id) })
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
                    runTimeline
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
                HStack(spacing: 8) {
                    Text(viewModel.selectedAgent?.title ?? String.l10n("agent.workspace.window.title"))
                        .font(agentFont(.title3, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(agentFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("agent.workspace.header.subtitle")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            headerPill(statusText, icon: statusIcon)
            headerPill(String.l10n("agent.workspace.header.readOnly"), icon: "lock")
            headerPill(String.l10n("agent.workspace.header.estimatedRun"), icon: "chart.bar.doc.horizontal")

            Button {
                if viewModel.isRunning {
                    viewModel.cancel()
                }
            } label: {
                Label("agent.workspace.stop", systemImage: "stop.circle")
            }
            .controlSize(.small)
            .disabled(!viewModel.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func headerPill(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(agentFont(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
            HStack(spacing: 10) {
                composerContextChip(String.l10n("agent.workspace.composer.scope"), icon: "tray.full")
                composerContextChip(String.l10n("agent.workspace.composer.mode"), icon: "lock")
                composerContextChip(String.l10n("agent.workspace.composer.tools"), icon: "wrench.and.screwdriver")
                Spacer()
            }
            .padding(.horizontal, 18)

            agentComposerInputBox
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var agentComposerInputBox: some View {
        let canSubmit = !viewModel.isRunning
            && viewModel.selectedAgent?.isEnabled == true
            && !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let requiresCommandReturn = dependencies.settings.aiChatRequiresCommandReturn
        return VStack(alignment: .leading, spacing: 8) {
            if !viewModel.attachments.isEmpty {
                attachmentStrip
            }

            TextField(String.l10n("agent.workspace.composer.placeholder"), text: $viewModel.prompt, axis: .vertical)
                .font(agentFont(.body))
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                // 与 RAG composer 保持同一布局约束，避免纵向 TextField 首次测量时提前换行。
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .disabled(viewModel.isRunning)
                // 纯 Return：开=换行 / 关=发送。⌘↩ 由下方隐藏 Button 承接（onKeyPress 无 modifiers 参数）。
                .onKeyPress(.return) {
                    let flags = (NSApp.currentEvent?.modifierFlags ?? [])
                        .intersection(.deviceIndependentFlagsMask)
                    if flags.contains(.command) {
                        return .ignored
                    }
                    if requiresCommandReturn {
                        return .ignored
                    }
                    guard canSubmit else { return .handled }
                    viewModel.run()
                    return .handled
                }
                .background {
                    // 与设置对称：开=⌘↩发送，关=⌘↩换行。
                    Button("") {
                        if requiresCommandReturn {
                            guard canSubmit else { return }
                            viewModel.run()
                        } else {
                            insertNewlineIntoFocusedFieldEditor()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

            HStack(spacing: 8) {
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
                    viewModel.run()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(agentFont(.title2))
                        .foregroundStyle(canSubmit ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!canSubmit)
                .help(
                    requiresCommandReturn
                        ? "settings.general.shortcuts.aiCommandReturn.description.on"
                        : "settings.general.shortcuts.aiCommandReturn.description.off"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.44))
        )
        .padding(.horizontal, 18)
    }

    /// ⌘↩ 换行时写进当前 field editor，尽量落在光标处而不是字符串末尾。
    private func insertNewlineIntoFocusedFieldEditor() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.insertNewline(nil)
            return
        }
        viewModel.prompt += "\n"
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

    private var statusText: String {
        switch viewModel.status {
        case .idle:
            return String.l10n("agent.workspace.status.ready")
        case .planning:
            return String.l10n("agent.workspace.status.planning")
        case .running:
            return String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation:
            return String.l10n("agent.workspace.status.waitingForConfirmation")
        case .completed:
            return String.l10n("agent.workspace.status.completed")
        case .failed:
            return String.l10n("agent.workspace.status.failed")
        case .cancelled:
            return String.l10n("agent.workspace.status.cancelled")
        }
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .idle:
            return "circle"
        case .planning, .running, .waitingForConfirmation:
            return "circle.dotted"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        }
    }

}
