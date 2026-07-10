//
//  AgentMessageTimelineView.swift
//  Starcat
//
//  Agent 工作台的统一消息事实时间线。
//
//  user、assistant、tool-call、tool-result、approval 和 artifact 全部由持久化事实投影；
//  展开状态只属于当前窗口，不写回运行数据。
//

import SwiftUI

struct AgentMessageTimelineView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var expandedItemIDs: Set<String> = []

    let viewModel: AgentWorkspaceViewModel

    private var items: [AgentTimelineItem] {
        AgentTimelineProjection.makeItems(
            messages: viewModel.messages,
            approvals: viewModel.approvals,
            artifacts: viewModel.artifacts,
            userPrompt: viewModel.prompt
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty,
                       viewModel.assistantReasoningOutput.isEmpty,
                       viewModel.assistantOutput.isEmpty,
                       viewModel.errorMessage == nil {
                        emptyState
                    } else {
                        ForEach(items) { item in
                            timelineRow(item)
                                .id(item.id)
                        }
                        if !viewModel.assistantReasoningOutput.isEmpty || !viewModel.assistantOutput.isEmpty {
                            streamingRow
                                .id("streaming-assistant")
                        }
                        if let error = viewModel.errorMessage {
                            errorRow(error)
                                .id("run-error")
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: items.map(\.id)) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.assistantOutput) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.assistantReasoningOutput) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(interfaceScale.font(size: 28))
                .foregroundStyle(.secondary)
            Text("agent.workspace.empty.title")
                .font(interfaceScale.font(.rowTitle, weight: .semibold))
            Text("agent.workspace.empty.subtitle")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    @ViewBuilder
    private func timelineRow(_ item: AgentTimelineItem) -> some View {
        switch item.kind {
        case .user:
            userRow(item)
        case .assistant:
            assistantRow(item)
        case .toolCall, .toolResult:
            toolRow(item)
        case .approval:
            approvalRow(item)
        case .artifact:
            artifactRow(item)
        }
    }

    private func userRow(_ item: AgentTimelineItem) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: 80)
            Text(item.text)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 620, alignment: .leading)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantRow(_ item: AgentTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            agentIcon
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(interfaceScale.font(.rowTitle, weight: .semibold))
                if let reasoning = item.reasoning {
                    disclosureButton(
                        id: item.id,
                        title: String.l10n("agent.workspace.timeline.reasoning"),
                        icon: "brain"
                    )
                    if expandedItemIDs.contains(item.id) {
                        auditText(reasoning)
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(interfaceScale.font(.body))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolRow(_ item: AgentTimelineItem) -> some View {
        let isResult = item.kind == .toolResult
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(item.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isResult ? statusIcon(item.toolStatus) : "wrench.and.screwdriver")
                        .foregroundStyle(statusTint(item.toolStatus))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(interfaceScale.font(.caption, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(isResult ? String.l10n("agent.workspace.timeline.toolResult") : String.l10n("agent.workspace.timeline.toolCall"))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.text)
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: expandedItemIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if expandedItemIDs.contains(item.id) {
                if let input = item.input {
                    auditBlock(String.l10n("agent.workspace.timeline.input"), icon: "arrow.down.right", text: input)
                }
                if let output = item.output {
                    auditBlock(String.l10n("agent.workspace.timeline.output"), icon: "arrow.up.right", text: output)
                }
                if !item.sources.isEmpty {
                    sourceBlock(item.sources)
                }
                if let log = item.log {
                    auditBlock(String.l10n("agent.workspace.timeline.execution"), icon: "clock", text: log)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: 860, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .padding(.leading, 40)
    }

    private func approvalRow(_ item: AgentTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(item.approval?.status == .pending ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(interfaceScale.font(.caption, weight: .semibold))
                    Text(String.l10n("agent.workspace.timeline.approval"))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.text)
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if let input = item.input {
                disclosureButton(
                    id: item.id,
                    title: String.l10n("agent.workspace.timeline.reviewArguments"),
                    icon: "curlybraces"
                )
                if expandedItemIDs.contains(item.id) {
                    auditText(input)
                }
            }

            if let approval = item.approval, approval.status == .pending {
                approvalActions(approval)
            }
        }
        .padding(12)
        .frame(maxWidth: 860, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.24)))
        .padding(.leading, 40)
    }

    private func artifactRow(_ item: AgentTimelineItem) -> some View {
        Button {
            if let artifact = item.artifact {
                viewModel.selectedArtifactID = artifact.id
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(interfaceScale.font(.rowTitle, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(item.text)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: 860, alignment: .leading)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.20)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.leading, 40)
    }

    private var streamingRow: some View {
        HStack(alignment: .top, spacing: 10) {
            agentIcon
            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.assistantReasoningOutput.isEmpty {
                    Label("agent.workspace.timeline.reasoning", systemImage: "brain")
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    auditText(viewModel.assistantReasoningOutput)
                }
                if !viewModel.assistantOutput.isEmpty {
                    Text(viewModel.assistantOutput)
                        .font(interfaceScale.font(.body))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private func errorRow(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(interfaceScale.font(.bodyEmphasis))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: 860, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var agentIcon: some View {
        Image(systemName: "sparkles.rectangle.stack.fill")
            .font(interfaceScale.font(size: 16, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 28, height: 28)
            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
    }

    private func disclosureButton(id: String, title: String, icon: String) -> some View {
        Button { toggle(id) } label: {
            Label(title, systemImage: icon)
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func auditBlock(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
            auditText(text)
        }
    }

    private func auditText(_ text: String) -> some View {
        Text(text)
            .font(interfaceScale.font(.code, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sourceBlock(_ sources: [AgentToolResultSource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("agent.workspace.timeline.sources", systemImage: "link")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text(source.title)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(interfaceScale.font(.caption))
                    }
                }
            }
        }
    }

    private func approvalActions(_ approval: AgentApprovalRequest) -> some View {
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
        .controlSize(.small)
    }

    private func statusIcon(_ status: AgentToolResultStatus?) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed, .timedOut, .rejected: return "xmark.circle.fill"
        case nil: return "circle.dotted"
        }
    }

    private func statusTint(_ status: AgentToolResultStatus?) -> Color {
        switch status {
        case .completed: return .green
        case .failed, .timedOut, .rejected: return .red
        case .skipped, nil: return .secondary
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedItemIDs.contains(id) {
                expandedItemIDs.remove(id)
            } else {
                expandedItemIDs.insert(id)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let hasStreamingOutput = !viewModel.assistantReasoningOutput.isEmpty || !viewModel.assistantOutput.isEmpty
        let target = hasStreamingOutput ? "streaming-assistant" : items.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}
