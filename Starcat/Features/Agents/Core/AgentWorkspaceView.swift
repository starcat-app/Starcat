//
//  AgentWorkspaceView.swift
//  Starcat
//
//  覆盖式 Agent 工作台。
//
//  这是所有内置 Agent 的统一入口：左侧选择 Agent，右侧展示 run header、步骤时间线、
//  Artifact 和底部输入框。P0 先承载 GitHub Weekly Report，后续新增 Agent 不应再
//  单独创建一套工作台 UI。
//

import SwiftUI

struct AgentWorkspaceView: View {

    @State private var viewModel = AgentWorkspaceViewModel()
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                agentRail
                    .frame(width: 260)
                Divider()
                runSurface
            }
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Workspace")
                    .font(.headline)
                Text("Run built-in Starcat agents with visible steps and artifacts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if viewModel.isRunning {
                    viewModel.cancel()
                }
                onClose()
            } label: {
                Label("Back", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .help("Back to Starcat")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var agentRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Built-in Agents")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            ForEach(viewModel.agents) { agent in
                agentButton(agent)
            }

            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private func agentButton(_ agent: AgentDefinition) -> some View {
        Button {
            viewModel.selectAgent(agent)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agent.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(agent.isEnabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(agent.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !agent.isEnabled {
                            Text("Soon")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                    Text(agent.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        ForEach(agent.capabilityLabels, id: \.self) { label in
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(agent.id == viewModel.selectedAgentID ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!agent.isEnabled || viewModel.isRunning)
        .padding(.horizontal, 8)
    }

    private var runSurface: some View {
        VStack(spacing: 0) {
            runHeader
            Divider()
            HStack(spacing: 0) {
                timeline
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 440)
                Divider()
                artifactPane
            }
            Divider()
            composer
        }
    }

    private var runHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.runTitle)
                    .font(.title3.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRunning {
                Button {
                    viewModel.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("Timeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)

                if viewModel.steps.isEmpty {
                    emptyTimeline
                } else {
                    ForEach(viewModel.steps) { step in
                        stepCard(step)
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }

    private var emptyTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text("Run an agent to see each step here.")
                .font(.subheadline)
            Text("P0 shows planning, data preparation, topic clustering, report drafting, and artifact creation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func stepCard(_ step: AgentRunStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stepIcon(step.status))
                .foregroundStyle(stepColor(step.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var artifactPane: some View {
        VStack(spacing: 0) {
            artifactToolbar
            Divider()
            if let artifact = viewModel.selectedArtifact {
                ScrollView {
                    Text(artifact.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                ContentUnavailableView(
                    "No Artifact",
                    systemImage: "doc.text",
                    description: Text("Run an agent to generate Markdown or other artifacts.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var artifactToolbar: some View {
        HStack(spacing: 10) {
            Text("Artifacts")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let artifact = viewModel.selectedArtifact {
                Text(artifact.type.title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
            }
            Spacer()
            Button {
                viewModel.copySelectedArtifact()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(viewModel.selectedArtifact == nil)
            Button {
                viewModel.exportSelectedArtifact()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.selectedArtifact == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Tell the agent what to do...", text: $viewModel.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(viewModel.isRunning)
            Button {
                viewModel.run()
            } label: {
                Label("Run", systemImage: "arrow.up.circle.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(viewModel.isRunning || viewModel.selectedAgent?.isEnabled != true)
        }
        .padding(14)
    }

    private var statusText: String {
        switch viewModel.status {
        case .idle:
            return "Ready"
        case .planning:
            return "Planning"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
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
