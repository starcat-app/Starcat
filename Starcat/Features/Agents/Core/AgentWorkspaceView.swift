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

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var viewModel = AgentWorkspaceViewModel()
    let chromeState: WorkspaceChromeState

    private let contextChips = ["@ 已选 24 repos", "Trending 本周", "AI Agent", "README 缓存"]
    private let artifactTabs = ["概览", "结构化结果", "证据", "行动", "日志"]

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

            historyRow(title: "AI Agent 专题周报", caption: "刚刚 · 24 repos")
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
            contextBar
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

    private var contextBar: some View {
        HStack(spacing: 8) {
            Text("上下文")
                .font(agentFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(contextChips, id: \.self) { chip in
                contextChip(chip)
            }
            Spacer()
            Button {
            } label: {
                Label("管理上下文", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .font(agentFont(.caption))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private func contextChip(_ text: String) -> some View {
        Text(text)
            .font(agentFont(.caption))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    private var runTimeline: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                userPromptBubble
                assistantRunBlock
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var userPromptBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            Text(viewModel.prompt.isEmpty ? "基于这些 repo 生成一期 AI Agent 专题周报，并标出值得继续研究的项目。" : viewModel.prompt)
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

                Text(assistantTranscriptText)
                    .font(agentFont(.body))
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)

                planBlock
                toolOutputBlock
                artifactReferenceBlock

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

    private var planBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            transcriptSectionHeader("执行计划", icon: "list.bullet.rectangle")

            ForEach(Array(transcriptPlanSteps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(agentFont(.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(agentFont(.caption, weight: .semibold))
                        Text(step.detail)
                            .font(agentFont(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolOutputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            transcriptSectionHeader("工具过程", icon: "wrench.and.screwdriver")

            ForEach(transcriptToolRows) { row in
                transcriptToolRow(row)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    private var artifactReferenceBlock: some View {
        Button {
            if let artifact = viewModel.selectedArtifact ?? viewModel.artifacts.first {
                viewModel.selectedArtifactID = artifact.id
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(agentIconFont(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    Text(transcriptArtifactTitle)
                        .font(agentFont(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("右侧 Artifact Inspector 可继续查看结构化结果、证据和日志。")
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(viewModel.artifacts.isEmpty)
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

    private func transcriptToolRow(_ row: AgentTranscriptToolRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.systemImage)
                .font(agentIconFont(size: 13, weight: .semibold))
                .foregroundStyle(row.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(agentFont(.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(row.summary)
                        .font(agentFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(row.detail)
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
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

    private var assistantTranscriptText: String {
        let output = viewModel.assistantOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }
        if viewModel.status == .completed {
            return "我已经完成这轮 Agent run。下面保留了关键计划、工具过程和产物引用，右侧可以继续核验结构化结果。"
        }
        if viewModel.isRunning {
            return "我正在把你的目标拆成可审查的执行步骤，并在每一步留下工具输出和产物引用，避免只给出一段不可追踪的回答。"
        }
        return "我会先确认目标和上下文，再读取候选来源、形成主题判断，最后生成可核验的 Markdown artifact。当前只是 UI transcript 形态预览，真实数据接入会在后续 runtime 中替换。"
    }

    private var transcriptPlanSteps: [AgentPlanStep] {
        if !viewModel.planSteps.isEmpty { return viewModel.planSteps }
        return [
            AgentPlanStep(title: "确认目标", detail: "把你的输入收敛成明确的 Agent run 目标和产物类型。"),
            AgentPlanStep(title: "读取上下文", detail: "后续会接入当前选择的 repo、README、笔记、标签和状态。"),
            AgentPlanStep(title: "生成产物", detail: "输出可复制、可导出、可在 Inspector 中核验的 artifact。")
        ]
    }

    private var transcriptToolRows: [AgentTranscriptToolRow] {
        if !viewModel.toolOutputs.isEmpty {
            return viewModel.toolOutputs.map {
                AgentTranscriptToolRow(
                    name: $0.toolName,
                    summary: $0.summary,
                    detail: $0.detail,
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            }
        }
        return [
            AgentTranscriptToolRow(name: "agent.parseGoal", summary: "Ready", detail: "识别任务目标、上下文边界和产物类型。", systemImage: "checkmark.circle.fill", tint: .green),
            AgentTranscriptToolRow(name: "context.resolveRepos", summary: "Waiting", detail: "正式接入后会解析当前选择和可用 repo 上下文。", systemImage: "circle.dotted", tint: .accentColor),
            AgentTranscriptToolRow(name: "artifact.prepare", summary: "Pending", detail: "等待 runtime 生成报告、日志或确认请求。", systemImage: "circle", tint: .secondary)
        ]
    }

    private var transcriptArtifactTitle: String {
        viewModel.selectedArtifact?.title ?? viewModel.artifacts.first?.title ?? "等待生成 Agent Artifact"
    }

    private var waitingForConfirmation: Bool {
        viewModel.isRunning || viewModel.status == .completed
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
            structuredResultPane
        }
    }

    private var artifactInspectorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artifact Inspector")
                        .font(agentFont(.headline))
                    Text("同一套 renderer 承载报告、对比表、聚类、标签计划和引用答案。")
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

            HStack(spacing: 6) {
                ForEach(artifactTabs, id: \.self) { tab in
                    Text(tab)
                        .font(agentFont(.caption, weight: tab == "结构化结果" ? .semibold : .regular))
                        .foregroundStyle(tab == "结构化结果" ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tab == "结构化结果" ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var structuredResultPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                resultSummary
                resultCard(
                    title: "AI Agent 工具链",
                    score: "92",
                    repos: ["modelcontextprotocol/swift-sdk", "SwiftedMind/SwiftAgent", "openai/openai-agents"],
                    insight: "MCP、Swift Agent runtime、tool-calling 框架是当前最值得继续跟踪的组合。"
                )
                resultCard(
                    title: "本地优先开发者工具",
                    score: "86",
                    repos: ["zed-industries/zed", "sindresorhus/Defaults", "groue/GRDB.swift"],
                    insight: "适合 Starcat 后续桌面端能力建设，但需要关注 macOS 版本与依赖体积。"
                )
                actionPreview

                if let artifact = viewModel.selectedArtifact {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artifact.title)
                            .font(agentFont(.subheadline, weight: .semibold))
                        Text(artifact.content)
                            .font(agentFont(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                }
            }
            .padding(16)
        }
    }

    private var resultSummary: some View {
        HStack(spacing: 10) {
            metricTile("\(max(viewModel.planSteps.count, 3))", "计划步骤")
            metricTile("\(max(viewModel.toolOutputs.count, 4))", "工具输出")
            metricTile("\(max(viewModel.artifacts.count, 1))", "产出物")
        }
    }

    private func metricTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(agentFont(.title3, weight: .semibold))
            Text(label)
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultCard(title: String, score: String, repos: [String], insight: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(agentFont(.subheadline, weight: .semibold))
                Spacer()
                Text("推荐 \(score)")
                    .font(agentFont(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }

            Text(insight)
                .font(agentFont(.caption))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(repos, id: \.self) { repo in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(repo)
                            .font(agentFont(.caption, weight: .medium))
                        Spacer()
                        Text("已 star")
                            .font(agentFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionPreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("待确认行动")
                .font(agentFont(.subheadline, weight: .semibold))
            actionRow(icon: "tag", title: "建议创建 tag: ai-agent", caption: "确认后才写入")
            actionRow(icon: "square.and.arrow.down", title: "导出 Markdown artifact", caption: "本地文件，不自动上传")
            actionRow(icon: "arrow.clockwise", title: "局部重写「采用建议」段落", caption: "只重写 artifact 节点")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionRow(icon: String, title: String, caption: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(agentFont(.caption, weight: .medium))
                Text(caption)
                    .font(agentFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
                .disabled(viewModel.isRunning || viewModel.selectedAgent?.isEnabled != true)
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

    private struct AgentTranscriptToolRow: Identifiable {
        let name: String
        let summary: String
        let detail: String
        let systemImage: String
        let tint: Color

        var id: String { "\(name)-\(summary)" }
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
