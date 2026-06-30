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

    @State private var viewModel = AgentWorkspaceViewModel()
    let onClose: () -> Void

    private let contextChips = ["@ 已选 24 repos", "Trending 本周", "AI Agent", "README 缓存"]
    private let artifactTabs = ["概览", "结构化结果", "证据", "行动", "日志"]

    var body: some View {
        HStack(spacing: 0) {
            agentRail
                .frame(width: 312)
            Divider()
            runSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Agent Rail

    private var agentRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader
                .padding(.top, 18)

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
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent")
                        .font(.headline)
                    Text("任务工作台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                if viewModel.isRunning {
                    viewModel.cancel()
                }
                onClose()
            } label: {
                Label("返回主界面", systemImage: "arrow.left")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
    }

    private func agentSection(_ title: String, agents: [AgentDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
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
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(agent.id == viewModel.selectedAgentID ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(agent.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if !agent.isEnabled {
                            Text("预告")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    Text(agent.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        ForEach(agent.capabilityLabels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(.caption2)
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
                .font(.caption.weight(.semibold))
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
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
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
                runTimeline
                    .frame(minWidth: 460, idealWidth: 560)
                Divider()
                artifactInspector
                    .frame(minWidth: 430, idealWidth: 520)
            }
            Divider()
            composer
        }
    }

    private var runHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(viewModel.selectedAgent?.title ?? "Agent 工作台")
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("统一 Run Surface · steps / tools / artifacts / confirmations")
                    .font(.caption)
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Text("上下文")
                .font(.caption.weight(.semibold))
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private func contextChip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
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
        }
    }

    private var userPromptBubble: some View {
        Text(viewModel.prompt.isEmpty ? "基于这些 repo 生成一期 AI Agent 专题周报，并标出值得继续研究的项目。" : viewModel.prompt)
            .font(.body)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var assistantRunBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starcat")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 10) {
                if viewModel.steps.isEmpty {
                    universalStepCard(
                        title: "规划任务",
                        kind: "Plan",
                        detail: "识别用户目标、上下文范围、可用工具和最终 artifact 类型。",
                        status: .completed,
                        input: "user_input + context chips",
                        output: "AgentRunPlan"
                    )
                    universalStepCard(
                        title: "调用工具: resolve_selected_repos",
                        kind: "Tool Call",
                        detail: "把 UI 中选择的 starred repo 快照转换成 Agent 可读上下文。",
                        status: .completed,
                        input: "24 repo selections",
                        output: "RepoContext[]"
                    )
                    universalStepCard(
                        title: "LLM 思考: 聚类主题与筛选标准",
                        kind: "Thinking",
                        detail: "按项目定位、活跃度、生态价值和采用风险形成候选主题。",
                        status: .running,
                        input: "RepoContext[] + style guide",
                        output: "streaming reasoning summary"
                    )
                    universalStepCard(
                        title: "生成 Artifact: structured_report",
                        kind: "Artifact",
                        detail: "把最终结果写入统一 artifact schema，供右侧 Inspector 渲染。",
                        status: .pending,
                        input: "ReportTopic[]",
                        output: "AgentArtifact"
                    )
                    universalStepCard(
                        title: "等待确认: 导出 / 写入标签",
                        kind: "Confirmation",
                        detail: "所有写入标签、状态或取消 star 的动作都必须由用户确认。",
                        status: .pending,
                        input: "SuggestedAction[]",
                        output: "UserDecision"
                    )
                } else {
                    ForEach(viewModel.steps) { step in
                        universalStepCard(
                            title: step.title,
                            kind: stepKind(for: step.title),
                            detail: step.detail,
                            status: step.status,
                            input: "runtime event",
                            output: step.status == .completed ? "ok" : "pending"
                        )
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
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
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(kind)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
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
            .font(.caption)
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
                        .font(.headline)
                    Text("同一套 renderer 承载报告、对比表、聚类、标签计划和引用答案。")
                        .font(.caption)
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
                        .font(.caption.weight(tab == "结构化结果" ? .semibold : .regular))
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
                            .font(.subheadline.weight(.semibold))
                        Text(artifact.content)
                            .font(.system(.caption, design: .monospaced))
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
            metricTile("24", "上下文 repo")
            metricTile("4", "主题")
            metricTile("7", "行动项")
        }
    }

    private func metricTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption)
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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("推荐 \(score)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            }

            Text(insight)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(repos, id: \.self) { repo in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(.secondary)
                        Text(repo)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("已 star")
                            .font(.caption)
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
                .font(.subheadline.weight(.semibold))
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
                    .font(.caption.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("继续给 Agent 指令，或 @ 选择已 star repo，/ 调用技能与工具", text: $viewModel.prompt, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .disabled(viewModel.isRunning)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            HStack(spacing: 10) {
                composerMenu("Craft", icon: "wand.and.sparkles")
                composerMenu("自动", icon: "arrow.triangle.branch")
                composerMenu("技能", icon: "hammer")
                composerMenu("只读", icon: "lock")
                composerMenu("@ Repo", icon: "at")
                Spacer()
                composerIcon("plus")
                composerIcon("sparkles")
                composerIcon("mic")
                Button {
                    viewModel.run()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(viewModel.isRunning ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.isRunning || viewModel.selectedAgent?.isEnabled != true)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.44))
        )
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .safeAreaInset(edge: .bottom) {
            Text("Agent 只在你确认后写入标签、状态或取消 star。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
    }

    private func composerMenu(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func composerIcon(_ icon: String) -> some View {
        Button {
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

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
