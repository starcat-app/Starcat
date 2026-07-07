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
            viewModel.configureRuntime(DefaultAgentRuntime(
                textGenerator: AgentTextGeneratorFactory.make(settings: dependencies.settings)
            ))
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
                    agentSection("发现", agents: viewModel.agents.filter { ["github-weekly-report", "repo-alternatives"].contains($0.id) })
                    agentSection("消化", agents: viewModel.agents.filter { ["recall-search", "repo-insight"].contains($0.id) })
                    agentSection("整理", agents: viewModel.agents.filter { ["overlap-scan", "untagged-tidy"].contains($0.id) })
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
                    Text("Agent")
                        .font(agentFont(.headline))
                    Text("任务工作台")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

        }
        .padding(14)
    }

    private func agentSection(_ title: String, agents: [AgentDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
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
                            Text("预告")
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
            Text("历史任务")
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            historyRow(title: "AI Agent 专题周报", caption: "最近一次 · 本地快照")
            historyRow(title: "Swift MCP 替代品", caption: "昨天 · 对比表")
        }
    }

    private func historyRow(title: String, caption: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(agentFont(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                    Text(viewModel.selectedAgent?.title ?? "Agent 工作台")
                        .font(agentFont(.title3, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(agentFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text("统一 Run Surface · steps / tools / artifacts / confirmations")
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            headerPill(statusText, icon: statusIcon)
            headerPill("只读模式", icon: "lock")
            headerPill("预计 1 run", icon: "chart.bar.doc.horizontal")

            Button {
                if viewModel.isRunning {
                    viewModel.cancel()
                }
            } label: {
                Label("停止", systemImage: "stop.circle")
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
            Text("输入任务后开始 Agent run")
                .font(agentFont(.subheadline, weight: .semibold))
            Text("中栏会按执行顺序展示步骤、工具调用和产出物。")
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
                Text("Run Trace")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(agentTraceItems.count) spans")
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
            traceAuditBlock("输入", icon: "arrow.down.right", text: item.input)
            traceAuditBlock("输出", icon: "arrow.up.right", text: item.output)
            traceAuditBlock("日志", icon: "terminal", text: item.log)
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
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
            Text("需要写入标签、状态或取消 star 时，会在这里等待你确认。")
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
            Spacer()
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
            return "我已经完成这轮 Agent run。下面保留了关键计划、工具过程和产物引用，右侧可以查看、复制或导出产出物。"
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
                subtitle: "Plan · step \(index + 1)",
                kind: "Plan",
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
            AgentTraceItem(
                id: "step-\(index)-\(step.id.uuidString)",
                title: step.title,
                subtitle: "\(stepKind(for: step.title)) · \(stepStatusLabel(step.status))",
                kind: stepKind(for: step.title),
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
                subtitle: "Tool Call · \(output.summary)",
                kind: "Tool",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                input: """
                tool_name:
                \(output.toolName)

                arguments:
                \(output.input.isEmpty ? "等待 runtime 输出工具参数。" : output.input)
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
        viewModel.isRunning || viewModel.status == .completed
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
                metaPill("输入: \(input)")
                metaPill("输出: \(output)")
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
                    Text("Artifact Inspector")
                        .font(agentFont(.headline))
                    Text("查看、复制、导出本轮 Agent 产出物；执行过程在中栏 trace 中审计。")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.copySelectedArtifact()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .disabled(viewModel.selectedArtifact == nil)
                Button {
                    viewModel.exportSelectedArtifact()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.down")
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
                Text("暂无产出物")
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
                    Text("运行 Agent 后将在这里显示 Markdown 或 Run Log。")
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

            Text("当前右栏只承载产出物查看与导出；步骤、工具调用、AI 输入输出和日志在中栏 trace 中展开审计。")
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
                composerMenu("Craft", icon: "wand.and.sparkles")
                composerMenu("自动", icon: "arrow.triangle.branch")
                composerMenu("技能", icon: "hammer")
                composerMenu("只读", icon: "lock")
                composerMenu("@ Repo", icon: "at")
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
            TextField("继续给 Agent 指令，或 @ 选择已 star repo，/ 调用技能与工具", text: $viewModel.prompt, axis: .vertical)
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

    private func composerMenu(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
            Image(systemName: "chevron.down")
                .font(agentFont(.caption, weight: .semibold))
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
            return "就绪"
        case .planning:
            return "规划中"
        case .running:
            return "运行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .idle:
            return "circle"
        case .planning, .running:
            return "circle.dotted"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        }
    }

    private func stepKind(for title: String) -> String {
        if title.contains("数据") || title.contains("准备") { return "Tool Call" }
        if title.contains("聚类") || title.contains("生成") { return "Thinking" }
        if title.contains("Artifact") || title.contains("Markdown") { return "Artifact" }
        return "Plan"
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
