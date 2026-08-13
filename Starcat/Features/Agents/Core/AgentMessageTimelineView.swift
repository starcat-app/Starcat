//
//  AgentMessageTimelineView.swift
//  Starcat
//
//  Agent 工作台的过程 / 结果双层 Run Surface。
//
//  持久化消息仍是唯一事实源；本视图只消费 AgentTimelineProjection 的确定性投影。
//  原始 reasoning 不进入普通界面，call/result 合并和折叠状态也不会写回运行数据。
//

import SwiftUI

struct AgentMessageTimelineView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var expandedItemIDs: Set<String> = []
    @State private var processExpandedOverride: Bool?
    @State private var isNearBottom = true

    let viewModel: AgentWorkspaceViewModel

    private var presentation: AgentRunPresentation {
        AgentTimelineProjection.makePresentation(
            messages: viewModel.messages,
            approvals: viewModel.approvals,
            artifacts: viewModel.artifacts,
            userPrompt: viewModel.prompt,
            status: viewModel.status
        )
    }

    private var isProcessExpanded: Bool {
        processExpandedOverride ?? presentation.isProcessExpandedByDefault
    }

    private var runIdentity: String {
        viewModel.messages.first?.runID.uuidString
            ?? viewModel.selectedHistoryRunID
            ?? "draft"
    }

    private var presentationRevision: String {
        let sectionIDs = presentation.processSections.map(\.id).joined(separator: "|")
        let artifactIDs = presentation.inlineArtifacts.map(\.id).joined(separator: "|")
        return "\(sectionIDs)#\(presentation.finalAnswer?.id ?? "")#\(artifactIDs)#\(viewModel.assistantOutput.count)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if isEmpty {
                        emptyState
                    } else {
                        ForEach(presentation.userItems) { item in
                            userRow(item)
                        }

                        if !presentation.processSections.isEmpty {
                            processSection
                        }

                        if !viewModel.assistantOutput.isEmpty || !viewModel.assistantReasoningOutput.isEmpty {
                            streamingResultRow
                                .id("streaming-assistant")
                        }

                        if let finalAnswer = presentation.finalAnswer {
                            finalAnswerRow(finalAnswer)
                                .id(finalAnswer.id)
                        }

                        ForEach(presentation.inlineArtifacts) { item in
                            inlineArtifactRow(item)
                                .id(item.id)
                        }

                        if let error = viewModel.errorMessage {
                            errorRow(error)
                                .id("run-error")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("run-surface-bottom")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let remaining = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return remaining <= 80
            } action: { _, newValue in
                isNearBottom = newValue
            }
            .onChange(of: presentationRevision) { _, _ in
                // 只有仍在跟随尾部的运行中 Run 才自动滚动；用户主动上滚后不能抢回位置。
                guard isNearBottom, viewModel.isRunning else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("run-surface-bottom", anchor: .bottom)
                }
            }
            .onChange(of: runIdentity) { _, _ in
                // 切换实时 / 历史 Run 后恢复该状态的默认折叠策略，不沿用上一 Run 的手动选择。
                processExpandedOverride = nil
                expandedItemIDs.removeAll()
                isNearBottom = true
            }
        }
    }

    private var isEmpty: Bool {
        presentation.userItems.isEmpty
            && presentation.processSections.isEmpty
            && presentation.finalAnswer == nil
            && presentation.inlineArtifacts.isEmpty
            && viewModel.assistantReasoningOutput.isEmpty
            && viewModel.assistantOutput.isEmpty
            && viewModel.errorMessage == nil
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

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    processExpandedOverride = !isProcessExpanded
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isProcessExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Label("agent.workspace.timeline.execution", systemImage: "list.bullet.rectangle")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(presentation.processSections.count.formatted())
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(String.l10n("agent.workspace.timeline.execution"))
            .accessibilityHint(String.l10n(isProcessExpanded ? "gettingStarted.collapse" : "gettingStarted.expand"))

            if isProcessExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(presentation.processSections) { section in
                        processRow(section)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(12)
        .frame(maxWidth: 900, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func processRow(_ section: AgentProcessSection) -> some View {
        switch section.kind {
        case .progress:
            if let item = section.items.first {
                progressRow(item)
            }
        case .activity:
            activityRow(section)
        case .approval:
            if let item = section.items.first {
                approvalRow(item)
            }
        }
    }

    private func progressRow(_ item: AgentTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            agentIcon
            Text(item.text)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private func activityRow(_ section: AgentProcessSection) -> some View {
        let status = aggregateStatus(section.items)
        let isExpanded = expandedItemIDs.contains(section.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(section.id)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: statusIcon(status))
                        .foregroundStyle(statusTint(status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.items.first?.title ?? "")
                            .font(interfaceScale.font(.caption, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(section.items.last?.text ?? "")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if section.items.count > 1 {
                        Label(section.items.count.formatted(), systemImage: "wrench.and.screwdriver")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                ForEach(section.items) { item in
                    toolExecutionDetail(item)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: 860, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }

    private func toolExecutionDetail(_ item: AgentTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.title)
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                Spacer()
                Text(item.toolStatus?.localizedTitle ?? String.l10n("agent.tool.status.pending"))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
            if let audit = item.toolAudit?.knowledgeRetrieval {
                AgentKnowledgeAuditView(audit: audit)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        if let toolCallID = item.toolCallID {
                            viewModel.selectKnowledgeAudit(toolCallID: toolCallID)
                        }
                    }
            }
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
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
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
    }

    private func finalAnswerRow(_ item: AgentTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            agentIcon
            VStack(alignment: .leading, spacing: 10) {
                Text("Starcat")
                    .font(interfaceScale.font(.rowTitle, weight: .semibold))
                RAGMarkdownText(content: item.text)
            }
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineArtifactRow(_ item: AgentTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let artifact = item.artifact {
                    viewModel.selectArtifact(artifact.id)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(Color.accentColor)
                    Text(item.title)
                        .font(interfaceScale.font(.rowTitle, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if let artifact = item.artifact {
                RAGMarkdownText(content: artifact.content)
            }
        }
        .padding(14)
        .frame(maxWidth: 900, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.18)))
    }

    private var streamingResultRow: some View {
        HStack(alignment: .top, spacing: 10) {
            agentIcon
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.assistantOutput.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.runTitle)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    RAGMarkdownText(content: viewModel.assistantOutput)
                }
            }
            Spacer()
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(interfaceScale.font(.bodyEmphasis))
                .foregroundStyle(.red)
            if viewModel.canRetryFailedRun {
                HStack {
                    Spacer()
                    Button {
                        viewModel.retryFailedRun()
                    } label: {
                        Label("action.retry", systemImage: "play.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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

    private func aggregateStatus(_ items: [AgentTimelineItem]) -> AgentToolResultStatus? {
        let statuses = items.compactMap(\.toolStatus)
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.timedOut) { return .timedOut }
        if statuses.contains(.rejected) { return .rejected }
        if statuses.count != items.count { return nil }
        if statuses.allSatisfy({ $0 == .skipped }) { return .skipped }
        return .completed
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
}
