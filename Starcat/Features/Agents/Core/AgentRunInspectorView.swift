//
//  AgentRunInspectorView.swift
//  Starcat
//
//  Agent 工作台通用 Inspector。
//
//  Inspector 只根据当前事实展示 pending approval、选中 artifact 或 run summary，不按
//  具体 Agent 拼专用卡片，因此 Weekly、Repo Insight 和后续 Agent 共用同一交互契约。
//

import SwiftUI

struct AgentRunInspectorView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let viewModel: AgentWorkspaceViewModel

    private var pendingApproval: AgentApprovalRequest? {
        viewModel.approvals.first { $0.status == .pending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agent.workspace.inspector.title")
                    .font(interfaceScale.font(.panelTitle, weight: .semibold))
                Text(inspectorSubtitle)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.selectedArtifact != nil, pendingApproval == nil {
                Button {
                    viewModel.copySelectedArtifact()
                } label: {
                    Label("agent.workspace.inspector.copy", systemImage: "doc.on.doc")
                }
                Button {
                    viewModel.exportSelectedArtifact()
                } label: {
                    Label("agent.workspace.inspector.export", systemImage: "square.and.arrow.down")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let approval = pendingApproval {
            approvalInspector(approval)
        } else if let artifact = viewModel.selectedArtifact {
            artifactInspector(artifact)
        } else {
            runSummaryInspector
        }
    }

    private func approvalInspector(_ approval: AgentApprovalRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorSection(
                    title: String.l10n("agent.workspace.inspector.approval.title"),
                    icon: "checkmark.shield",
                    content: approval.toolName
                )
                inspectorSection(
                    title: String.l10n("agent.workspace.inspector.approval.permission"),
                    icon: "lock.shield",
                    content: approval.permission.localizedTitle
                )
                inspectorSection(
                    title: String.l10n("agent.workspace.timeline.input"),
                    icon: "curlybraces",
                    content: (try? approval.input.jsonString()) ?? "{}",
                    monospaced: true
                )
                inspectorSection(
                    title: String.l10n("agent.workspace.inspector.approval.risk"),
                    icon: "exclamationmark.triangle",
                    content: String.l10n("agent.workspace.inspector.approval.riskDetail")
                )

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        viewModel.reject(approval)
                    } label: {
                        Label("agent.workspace.confirmation.reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        viewModel.approve(approval)
                    } label: {
                        Label("agent.workspace.confirmation.approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
    }

    private func artifactInspector(_ artifact: AgentArtifact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.artifacts.count > 1 {
                    Picker("agent.workspace.inspector.artifactPicker", selection: Binding(
                        get: { viewModel.selectedArtifactID ?? artifact.id },
                        set: { viewModel.selectedArtifactID = $0 }
                    )) {
                        ForEach(viewModel.artifacts) { item in
                            Text(item.title).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: artifact.type == .markdown ? "doc.richtext" : "doc.text.magnifyingglass")
                        .font(interfaceScale.font(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.title)
                            .font(interfaceScale.font(.rowTitle, weight: .semibold))
                        Text(String(format: String.l10n("agent.workspace.inspector.artifactMetadataFormat"), artifact.type.title, artifact.content.count))
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(artifact.content)
                    .font(interfaceScale.font(.code, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }

    private var runSummaryInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryRow(
                    title: String.l10n("agent.workspace.inspector.summary.status"),
                    value: statusLabel,
                    icon: "circle.dotted"
                )
                summaryRow(
                    title: String.l10n("agent.workspace.inspector.summary.messages"),
                    value: "\(viewModel.messages.count)",
                    icon: "text.bubble"
                )
                summaryRow(
                    title: String.l10n("agent.workspace.inspector.summary.toolCalls"),
                    value: "\(toolCallCount)",
                    icon: "wrench.and.screwdriver"
                )
                summaryRow(
                    title: String.l10n("agent.workspace.inspector.summary.tokens"),
                    value: "\(viewModel.usage.totalTokens)",
                    icon: "number"
                )
                if let error = viewModel.errorMessage {
                    inspectorSection(
                        title: String.l10n("agent.workspace.inspector.summary.error"),
                        icon: "exclamationmark.triangle.fill",
                        content: error
                    )
                }
            }
            .padding(16)
        }
    }

    private func summaryRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(interfaceScale.font(.body))
            Spacer()
            Text(value)
                .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                .textSelection(.enabled)
        }
    }

    private func inspectorSection(
        title: String,
        icon: String,
        content: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content)
                .font(monospaced ? interfaceScale.font(.code, design: .monospaced) : interfaceScale.font(.body))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorSubtitle: String {
        if pendingApproval != nil { return String.l10n("agent.workspace.inspector.approval.subtitle") }
        if viewModel.selectedArtifact != nil { return String.l10n("agent.workspace.inspector.artifact.subtitle") }
        return String.l10n("agent.workspace.inspector.summary.subtitle")
    }

    private var toolCallCount: Int {
        viewModel.messages.reduce(0) { count, message in
            count + message.parts.filter { if case .toolCall = $0 { return true }; return false }.count
        }
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .idle: return String.l10n("agent.workspace.status.idle")
        case .planning: return String.l10n("agent.workspace.status.planning")
        case .running: return String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation: return String.l10n("agent.workspace.status.waitingForConfirmation")
        case .completed: return String.l10n("agent.workspace.status.completed")
        case .failed: return String.l10n("agent.workspace.status.failed")
        case .cancelled: return String.l10n("agent.workspace.status.cancelled")
        }
    }
}
