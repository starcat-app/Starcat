//
//  AgentWorkspaceView.swift
//  Starcat
//
//  覆盖式 Agent 工作台。
//
//  本视图是所有内置 Agent 的唯一工作台壳子。Agent 只能提供定义、上下文、步骤事件
//  和产出物数据；页面结构保持统一，避免 Weekly / 替代品 / 重叠扫描各自长出一套 UI。
//

import SwiftUI

struct AgentWorkspaceView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var viewModel = AgentWorkspaceViewModel()
    @State private var expandedTraceItemIDs: Set<String> = []
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if hasRunContent {
                    userPromptBubble
                    assistantRunBlock
                } else {
                    emptyRunState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasRunContent: Bool {
        !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        viewModel.status != .idle ||
        !viewModel.planSteps.isEmpty ||
        !viewModel.steps.isEmpty ||
        !viewModel.toolOutputs.isEmpty ||
        !viewModel.traceSpans.isEmpty ||
        !viewModel.artifacts.isEmpty ||
        !viewModel.assistantOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        viewModel.errorMessage != nil
    }

    private var emptyRunState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(agentIconFont(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text("agent.workspace.empty.title")
                .font(agentFont(.subheadline, weight: .semibold))
            Text("agent.workspace.empty.subtitle")
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 96)
    }

    private var userPromptBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            Text(viewModel.prompt)
                .font(agentFont(.body))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 620, alignment: .leading)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantRunBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(agentIconFont(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Starcat")
                        .font(agentFont(.subheadline, weight: .semibold))
                    statusBadge(statusText, icon: statusIcon)
                    Spacer()
                }

                if !agentTraceItems.isEmpty {
                    runTraceBlock
                }

                if let text = assistantTranscriptText {
                    Text(text)
                        .font(agentFont(.body))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                if waitingForConfirmation {
                    confirmationStrip
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(agentFont(.callout))
                        .foregroundStyle(.red)
                        .padding(12)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
            .frame(maxWidth: 860, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runTraceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
                Text("agent.workspace.trace.title")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(String(format: String.l10n("agent.workspace.trace.countFormat"), agentTraceItems.count))
                    .font(agentFont(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                Spacer()
            }

            ForEach(agentTraceItems) { item in
                traceItemRow(item)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    private func traceItemRow(_ item: AgentTraceItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expandedTraceItemIDs.contains(item.id) {
                        expandedTraceItemIDs.remove(item.id)
                    } else {
                        expandedTraceItemIDs.insert(item.id)
                    }
                }
                if let artifactID = item.artifactID {
                    viewModel.selectedArtifactID = artifactID
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .font(agentIconFont(size: 13, weight: .semibold))
                        .foregroundStyle(item.tint)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(agentFont(.caption, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(item.kind)
                                .font(agentFont(.caption2, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .separatorColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        }
                        Text(item.subtitle)
                            .font(agentFont(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()
                    Image(systemName: expandedTraceItemIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(agentFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if expandedTraceItemIDs.contains(item.id) {
                traceDetailPane(item)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(item.tint.opacity(expandedTraceItemIDs.contains(item.id) ? 0.22 : 0.08), lineWidth: 1)
        )
    }

    private func traceDetailPane(_ item: AgentTraceItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            traceAuditBlock(String.l10n("agent.workspace.trace.input"), icon: "arrow.down.right", text: item.input)
            traceAuditBlock(String.l10n("agent.workspace.trace.output"), icon: "arrow.up.right", text: item.output)
            traceAuditBlock(String.l10n("agent.workspace.trace.log"), icon: "terminal", text: item.log)
        }
        .padding(.leading, 28)
    }

    private func traceAuditBlock(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(agentFont(.caption2, weight: .semibold))
            .foregroundStyle(.secondary)

            Text(text)
                .font(agentFont(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var confirmationStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text(viewModel.pendingConfirmations.first?.title ?? String.l10n("agent.workspace.confirmation.placeholder"))
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            if let detail = viewModel.pendingConfirmations.first?.detail {
                Text(detail)
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let approval = pendingApproval {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        viewModel.reject(approval)
                    } label: {
                        Label("agent.workspace.confirmation.reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .focusEffectDisabled()

                    Button {
                        viewModel.approve(approval)
                    } label: {
                        Label("agent.workspace.confirmation.approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .separatorColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private func transcriptSectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func statusBadge(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(agentFont(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .separatorColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var assistantTranscriptText: String? {
        let output = viewModel.assistantOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        if viewModel.status == .completed {
            return String.l10n("agent.workspace.assistant.completedFallback")
        }
        return nil
    }

    private var agentTraceItems: [AgentTraceItem] {
        if !viewModel.traceSpans.isEmpty {
            return viewModel.traceSpans.map(traceItem(from:))
        }

        var items: [AgentTraceItem] = []
        items.append(contentsOf: tracePlanItems)
        items.append(contentsOf: traceStepItems)
        items.append(contentsOf: traceToolItems)
        items.append(contentsOf: traceArtifactItems)
        return items
    }

    private func traceItem(from span: AgentTraceSpan) -> AgentTraceItem {
        AgentTraceItem(
            id: "trace-\(span.id.uuidString)",
            title: span.title,
            subtitle: "\(span.kind) · \(span.summary)",
            kind: span.kind,
            systemImage: traceIcon(for: span),
            tint: stepColor(span.status),
            input: span.input,
            output: span.output,
            log: span.log,
            artifactID: span.relatedArtifactID
        )
    }

    private var tracePlanItems: [AgentTraceItem] {
        viewModel.planSteps.enumerated().map { index, step in
            AgentTraceItem(
                id: "plan-\(index)-\(step.id.uuidString)",
                title: step.title,
                subtitle: String(format: String.l10n("agent.workspace.trace.subtitle.planFormat"), index + 1),
                kind: String.l10n("agent.workspace.trace.kind.plan"),
                systemImage: "list.bullet.rectangle",
                tint: .accentColor,
                input: """
                user_goal:
                \(viewModel.prompt)

                planning_scope:
                Agent definition + frozen Starcat repo context
                """,
                output: step.detail,
                log: "event=planCreated\nindex=\(index + 1)\nsource=runtime_event"
            )
        }
    }

    private var traceStepItems: [AgentTraceItem] {
        viewModel.steps.enumerated().map { index, step in
            let kind = stepKind(at: index, fallbackTitle: step.title)
            return AgentTraceItem(
                id: "step-\(index)-\(step.id.uuidString)",
                title: step.title,
                subtitle: "\(kind) · \(stepStatusLabel(step.status))",
                kind: kind,
                systemImage: stepIcon(step.status),
                tint: stepColor(step.status),
                input: """
                previous_state:
                status=\(statusText)

                step_context:
                \(step.title)
                """,
                output: step.detail,
                log: "event=stepUpdated\nstatus=\(stepStatusLabel(step.status))\nsource=runtime_event"
            )
        }
    }

    private var traceToolItems: [AgentTraceItem] {
        viewModel.toolOutputs.enumerated().map { index, output in
            AgentTraceItem(
                id: "tool-\(index)-\(output.id.uuidString)",
                title: output.toolName,
                subtitle: String(format: String.l10n("agent.workspace.trace.subtitle.toolCallFormat"), output.summary),
                kind: String.l10n("agent.workspace.trace.kind.tool"),
                systemImage: "checkmark.circle.fill",
                tint: .green,
                input: """
                tool_name:
                \(output.toolName)

                arguments:
                \(output.input.isEmpty ? String.l10n("agent.workspace.trace.toolInput.waiting") : output.input)
                """,
                output: output.output.isEmpty ? output.detail : output.output,
                log: output.log.isEmpty ? "event=toolOutput\nsummary=\(output.summary)\nsource=runtime_event" : output.log
            )
        }
    }

    private var traceArtifactItems: [AgentTraceItem] {
        viewModel.artifacts.enumerated().map { index, artifact in
            AgentTraceItem(
                id: "artifact-\(artifact.id.uuidString)",
                title: artifact.title,
                subtitle: "Artifact · \(artifact.type.title)",
                kind: "Artifact",
                systemImage: artifact.type == .markdown ? "doc.richtext" : "doc.text.magnifyingglass",
                tint: Color.accentColor,
                input: "tool_outputs + assistant_generation + artifact_schema",
                output: String(artifact.content.prefix(900)),
                log: "event=artifactCreated\nindex=\(index + 1)\ncreatedAt=\(artifact.createdAt.formatted())",
                artifactID: artifact.id
            )
        }
    }

    private var waitingForConfirmation: Bool {
        !viewModel.pendingConfirmations.isEmpty
    }

    private var pendingApproval: AgentApprovalRequest? {
        viewModel.approvals.first { $0.status == .pending }
    }

    private func stepStatusLabel(_ status: AgentStepStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .skipped: return "skipped"
        }
    }

    private func universalStepCard(
        title: String,
        kind: String,
        detail: String,
        status: AgentStepStatus,
        input: String,
        output: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stepIcon(status))
                    .foregroundStyle(stepColor(status))
                    .font(agentIconFont(size: 16, weight: .semibold))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(agentFont(.subheadline, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(kind)
                            .font(agentFont(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(detail)
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metaPill(String(format: String.l10n("agent.workspace.meta.inputFormat"), input))
                metaPill(String(format: String.l10n("agent.workspace.meta.outputFormat"), output))
                Spacer()
            }
            .padding(.leading, 32)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func metaPill(_ text: String) -> some View {
        Text(text)
            .font(agentFont(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .separatorColor).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Artifact Inspector

    private var artifactInspector: some View {
        VStack(spacing: 0) {
            artifactInspectorHeader
            Divider()
            artifactPane
        }
    }

    private var artifactInspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("agent.workspace.inspector.title")
                        .font(agentFont(.headline))
                    Text("agent.workspace.inspector.subtitle")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.copySelectedArtifact()
                } label: {
                    Label("agent.workspace.inspector.copy", systemImage: "doc.on.doc")
                }
                .disabled(viewModel.selectedArtifact == nil)
                Button {
                    viewModel.exportSelectedArtifact()
                } label: {
                    Label("agent.workspace.inspector.export", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.selectedArtifact == nil)
            }
            .controlSize(.small)

            artifactSelector
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var artifactSelector: some View {
        Group {
            if viewModel.artifacts.isEmpty {
                Text("agent.workspace.inspector.noArtifacts")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(viewModel.artifacts) { artifact in
                        artifactSelectorButton(artifact)
                    }
                }
            }
        }
    }

    private func artifactSelectorButton(_ artifact: AgentArtifact) -> some View {
        let isSelected = viewModel.selectedArtifact?.id == artifact.id
        return Button {
            viewModel.selectedArtifactID = artifact.id
        } label: {
            Label(artifact.type.title, systemImage: artifactTypeIcon(artifact.type))
                .font(agentFont(.caption, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(artifact.title)
    }

    private var artifactPane: some View {
        Group {
            if let artifact = viewModel.selectedArtifact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        artifactMetadata(artifact)
                        Text(artifact.content)
                            .font(agentFont(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(agentIconFont(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("agent.workspace.inspector.empty")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func artifactMetadata(_ artifact: AgentArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: artifactTypeIcon(artifact.type))
                    .font(agentIconFont(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title)
                        .font(agentFont(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(artifact.type.title) · \(artifact.content.count) chars · \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("agent.workspace.inspector.auditHint")
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func artifactTypeIcon(_ type: AgentArtifactType) -> String {
        switch type {
        case .markdown:
            return "doc.richtext"
        case .log:
            return "doc.text.magnifyingglass"
        }
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
        VStack(alignment: .leading, spacing: 8) {
            TextField(String.l10n("agent.workspace.composer.placeholder"), text: $viewModel.prompt, axis: .vertical)
                .font(agentFont(.body))
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                // 与 RAG composer 保持同一布局约束，避免纵向 TextField 首次测量时提前换行。
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .disabled(viewModel.isRunning)

            HStack(spacing: 8) {
                Spacer()

                composerActionIcon("paperclip")

                Button {
                    viewModel.run()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(agentFont(.title2))
                        .foregroundStyle(viewModel.isRunning ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.isRunning || viewModel.selectedAgent?.isEnabled != true || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func composerActionIcon(_ icon: String) -> some View {
        Button {
        } label: {
            Image(systemName: icon)
                .font(agentFont(.caption))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private struct AgentTraceItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let kind: String
        let systemImage: String
        let tint: Color
        let input: String
        let output: String
        let log: String
        var artifactID: UUID? = nil
    }

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

    private func stepKind(at index: Int, fallbackTitle title: String) -> String {
        switch index {
        case 1, 2:
            return String.l10n("agent.workspace.trace.kind.toolCall")
        case 3, 4:
            return String.l10n("agent.workspace.trace.kind.thinking")
        default:
            if title.localizedCaseInsensitiveContains("Artifact") || title.localizedCaseInsensitiveContains("Markdown") {
                return String.l10n("agent.workspace.trace.kind.artifact")
            }
            return String.l10n("agent.workspace.trace.kind.plan")
        }
    }

    private func stepIcon(_ status: AgentStepStatus) -> String {
        switch status {
        case .pending:
            return "circle"
        case .running:
            return "circle.dotted"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .skipped:
            return "minus.circle"
        }
    }

    private func traceIcon(for span: AgentTraceSpan) -> String {
        switch span.kind {
        case "Tool":
            return span.status == .failed ? "wrench.and.screwdriver" : "checkmark.circle.fill"
        case "LLM":
            return span.status == .failed ? "exclamationmark.triangle.fill" : "text.bubble"
        case "Artifact":
            return "doc.richtext"
        default:
            return stepIcon(span.status)
        }
    }

    private func stepColor(_ status: AgentStepStatus) -> Color {
        switch status {
        case .pending, .skipped:
            return .secondary
        case .running:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}
