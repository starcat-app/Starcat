//
//  AgentMessageTimelineView.swift
//  Starcat
//
//  Agent 工作台的连续任务叙事与最终结果界面。
//
//  对话正文继续由 AgentTimelineProjection 负责，执行过程优先消费持久化 Runtime Trace。
//  原始 reasoning 不进入普通界面；只有 Provider 明确给出的 summary 可以展示和恢复。
//

import SwiftUI

struct AgentMessageTimelineView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var expandedItemIDs: Set<String> = []
    @State private var collapsedItemIDs: Set<String> = []
    @State private var processExpandedOverride: Bool?
    @State private var messageTail = ScrollTailController()

    let viewModel: AgentWorkspaceViewModel

    private var presentation: AgentRunPresentation {
        AgentTimelineProjection.makePresentation(
            messages: viewModel.messages,
            approvals: viewModel.approvals,
            artifacts: viewModel.artifacts,
            userPrompt: viewModel.currentRunUserPrompt,
            status: viewModel.status
        )
    }

    private var isProcessExpanded: Bool {
        processExpandedOverride ?? traceProcessExpandedByDefault
    }

    private var traceProcessExpandedByDefault: Bool {
        guard !viewModel.traceEvents.isEmpty else { return presentation.isProcessExpandedByDefault }
        return viewModel.status == .running
            || viewModel.status == .planning
            || viewModel.status == .waitingForConfirmation
            || viewModel.traceEvents.contains { [.failed, .waiting].contains($0.status) }
    }

    private var runIdentity: String {
        viewModel.messages.first?.runID.uuidString
            ?? viewModel.selectedHistoryRunID
            ?? "draft"
    }

    var body: some View {
        ScrollView {
            // 顶层节点数量有界，而 Markdown / 工具过程高度会动态变化。这里必须使用
            // eager stack，避免 LazyStack 在滚动时反复解析可见项位置并占满主线程。
            VStack(alignment: .leading, spacing: 18) {
                if isEmpty {
                    emptyState
                } else {
                    ForEach(presentation.userItems) { item in
                        userRow(item)
                    }

                    agentIdentityRow

                    if !viewModel.traceEvents.isEmpty {
                        runtimeTraceSection
                    } else if !presentation.processSections.isEmpty {
                        processSection
                    }

                    if !viewModel.assistantOutput.isEmpty || !viewModel.assistantReasoningOutput.isEmpty {
                        streamingResultRow
                            .id("streaming-assistant")
                    }

                    // 工具型 Agent 的 Markdown artifact 就是最终正文；不再在正文前重复一段
                    // assistant 结语，确保结果像文档而不是“消息 + 卡片”的双重包装。
                    if presentation.inlineArtifacts.isEmpty,
                       let finalAnswer = presentation.finalAnswer {
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

                    // 底部 sentinel 是“用户是否仍在尾部”的唯一位置真源。内容高度变化时
                    // 由 ScrollView 的 sizeChanges anchor 校正 offset，不能再同步 scrollTo；
                    // 后者会在长工具链完成突发刷新时形成 AttributeGraph 布局反馈环。
                    Color.clear
                        .frame(height: 1)
                        .id("run-surface-bottom")
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            messageTail.updateBottomVisibility(isVisible)
                        }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            // 中栏对话贴齐左右阅读边，不再用固定 maxWidth 居中成一条窄栏。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(
            messageTail.isFollowing ? .bottom : nil,
            for: .sizeChanges
        )
        .onScrollPhaseChange { _, newPhase in
            messageTail.updatePhase(newPhase)
        }
        .onChange(of: runIdentity) { _, _ in
            // 切换实时 / 历史 Run 后恢复该状态的默认折叠与尾部跟随策略，
            // 不沿用上一 Run 的手动选择或滚动意图。
            processExpandedOverride = nil
            expandedItemIDs.removeAll()
            collapsedItemIDs.removeAll()
            messageTail.resumeFollowing()
        }
    }

    private var isEmpty: Bool {
        presentation.userItems.isEmpty
            && viewModel.traceEvents.isEmpty
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
            Spacer(minLength: 120)
            Text(item.text)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                // 背景必须先跟随文本取得实际宽度；外层 frame 只负责限制长消息并靠右。
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 560, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 连续任务叙事的核心不是卡片数量，而是让用户知道“谁正在做、做到哪一步”。
    /// Agent 身份只出现一次，下面的工具活动因此能自然组成同一条连续叙事。
    private var agentIdentityRow: some View {
        HStack(spacing: 9) {
            agentIcon
            VStack(alignment: .leading, spacing: 1) {
                Text("Starcat Agent")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(runStatusTitle)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    processExpandedOverride = !isProcessExpanded
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isProcessExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("agent.workspace.timeline.execution")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("· \(presentation.processSections.count.formatted())")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(String.l10n("agent.workspace.timeline.execution"))
            .accessibilityHint(String.l10n(isProcessExpanded ? "gettingStarted.collapse" : "gettingStarted.expand"))

            if isProcessExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(presentation.processSections) { section in
                        processRow(section)
                    }
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .padding(.leading, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shell 保持一致，内容严格来自当前 backend 的实际事件。这里没有预设“分析/检索/生成”
    /// 阶段，因此无工具任务只出现 reasoning/plan，有工具任务才出现 tool/MCP/web 等行。
    private var runtimeTraceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    processExpandedOverride = !isProcessExpanded
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isProcessExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("agent.workspace.timeline.execution")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("· \(viewModel.traceEvents.count.formatted())")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.runtimeBackend.displayName)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(String.l10n("agent.workspace.timeline.execution"))
            .accessibilityHint(String.l10n(isProcessExpanded ? "gettingStarted.collapse" : "gettingStarted.expand"))

            if isProcessExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(viewModel.traceEvents) { event in
                        traceRow(event)
                    }
                }
                .padding(.leading, 20)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .padding(.leading, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func traceRow(_ event: AgentTraceEvent) -> some View {
        let isExpanded = isTraceExpanded(event)
        return VStack(alignment: .leading, spacing: 7) {
            if event.hasDetails {
                Button { toggleTrace(event) } label: {
                    traceRowLabel(event, isExpanded: isExpanded, showsDisclosure: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityHint(String.l10n(isExpanded ? "gettingStarted.collapse" : "gettingStarted.expand"))
            } else {
                traceRowLabel(event, isExpanded: false, showsDisclosure: false)
            }

            if isExpanded {
                traceDetails(event)
                    .padding(.leading, 24)
            }
        }
        .padding(.leading, event.parentID == nil ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func traceRowLabel(
        _ event: AgentTraceEvent,
        isExpanded: Bool,
        showsDisclosure: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: traceStatusIcon(event.status))
                .foregroundStyle(traceStatusTint(event.status))
                .font(interfaceScale.font(.captionSmall))
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: traceKindIcon(event.kind))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                    Text(event.title)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if let summary = event.summary, summary != event.title {
                    Text(summary)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }
            }
            Spacer(minLength: 8)
            if let duration = event.durationMilliseconds {
                Text("\(duration.formatted()) ms")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
            if showsDisclosure {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    private func traceDetails(_ event: AgentTraceEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attempt = event.attempt {
                Text("\(String.l10n("action.retry")) \(attempt.formatted())")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(event.details.enumerated()), id: \.offset) { _, detail in
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.label)
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(detail.value)
                        .font(detail.format == .code || detail.format == .json
                            ? interfaceScale.font(.code, design: .monospaced)
                            : interfaceScale.font(.captionSmall))
                        .foregroundStyle(detail.format == .error ? Color.red : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, detail.format == .code || detail.format == .json ? 6 : 0)
                        .padding(.horizontal, detail.format == .code || detail.format == .json ? 8 : 0)
                        .background {
                            if detail.format == .code || detail.format == .json {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
            Text(item.text)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityRow(_ section: AgentProcessSection) -> some View {
        let status = aggregateStatus(section.items)
        let isExpanded = expandedItemIDs.contains(section.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                toggle(section.id)
                if let auditedItem = section.items.first(where: { $0.toolAudit?.knowledgeRetrieval != nil }),
                   let toolCallID = auditedItem.toolCallID {
                    viewModel.selectKnowledgeAudit(toolCallID: toolCallID)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: statusIcon(status))
                        .foregroundStyle(statusTint(status))
                        .font(interfaceScale.font(.captionSmall))
                        .frame(width: 16, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activityNarrative(section))
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        if let summary = activitySummary(section) {
                            Text(summary)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    Spacer()
                    if section.items.count > 1 {
                        Text("×\(section.items.count.formatted())")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolExecutionDetail(_ item: AgentTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if item.narrative == nil, !item.text.isEmpty {
                Text(item.text)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !item.sources.isEmpty {
                sourceBlock(item.sources)
            }

            if item.toolAudit?.knowledgeRetrieval != nil,
               let toolCallID = item.toolCallID {
                Button {
                    viewModel.selectKnowledgeAudit(toolCallID: toolCallID)
                } label: {
                    Label("agent.workspace.knowledgeAudit.title", systemImage: "sidebar.right")
                        .font(interfaceScale.font(.captionSmall, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 2)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.24)))
    }

    private func finalAnswerRow(_ item: AgentTimelineItem) -> some View {
        RAGMarkdownText(content: item.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineArtifactRow(_ item: AgentTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            if let artifact = item.artifact {
                if !artifactBeginsWithOwnTitle(artifact) {
                    Button {
                        viewModel.selectArtifact(artifact.id)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.green)
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
                }

                RAGMarkdownText(content: artifact.content)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
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

    private func isTraceExpanded(_ event: AgentTraceEvent) -> Bool {
        if expandedItemIDs.contains(event.id) { return true }
        if collapsedItemIDs.contains(event.id) { return false }
        switch event.status {
        case .running, .waiting, .failed:
            return true
        case .pending, .completed, .cancelled, .skipped:
            return event.kind == .warning || event.kind == .retry || event.kind == .error
        }
    }

    /// 自动展开只决定首次展示；用户点击后写入显式 expanded/collapsed 集合，后续 delta
    /// 更新同一事件时不能夺回控制权，避免流式状态刷新让折叠行反复跳开。
    private func toggleTrace(_ event: AgentTraceEvent) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if isTraceExpanded(event) {
                expandedItemIDs.remove(event.id)
                collapsedItemIDs.insert(event.id)
            } else {
                collapsedItemIDs.remove(event.id)
                expandedItemIDs.insert(event.id)
            }
        }
    }

    private func traceStatusIcon(_ status: AgentTraceStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .waiting: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func traceStatusTint(_ status: AgentTraceStatus) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .waiting: return .orange
        case .running: return .accentColor
        case .pending, .cancelled, .skipped: return .secondary
        }
    }

    private func traceKindIcon(_ kind: AgentTraceKind) -> String {
        switch kind {
        case .lifecycle: return "bolt.horizontal"
        case .plan: return "list.bullet.clipboard"
        case .reasoningSummary: return "brain"
        case .commentary: return "text.bubble"
        case .tool: return "wrench.and.screwdriver"
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .webSearch: return "globe"
        case .mcpTool: return "shippingbox"
        case .approval: return "checkmark.shield"
        case .warning: return "exclamationmark.triangle"
        case .retry: return "arrow.clockwise"
        case .error: return "xmark.octagon"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .unknown: return "circle.grid.2x2"
        }
    }

    private func activityNarrative(_ section: AgentProcessSection) -> String {
        section.items.last?.narrative
            ?? section.items.last?.text
            ?? ""
    }

    private func activitySummary(_ section: AgentProcessSection) -> String? {
        guard let item = section.items.last,
              !item.text.isEmpty,
              item.text != item.narrative,
              item.text != item.toolStatus?.localizedTitle else {
            return nil
        }
        return item.text
    }

    /// Markdown 已经用一级标题表达产出物名称时，不再额外绘制 artifact 卡片标题。
    /// 这是最终结果从“卡片附件”回归“正文文档”的关键视觉约束。
    private func artifactBeginsWithOwnTitle(_ artifact: AgentArtifact) -> Bool {
        guard let firstLine = artifact.content
            .split(whereSeparator: \.isNewline)
            .first else {
            return false
        }
        let markdownTitle = String(firstLine.drop(while: { $0 == "#" || $0.isWhitespace }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return markdownTitle.caseInsensitiveCompare(artifact.title) == .orderedSame
    }

    private var runStatusTitle: String {
        switch viewModel.status {
        case .completed: return String.l10n("agent.workspace.status.completed")
        case .failed: return String.l10n("agent.workspace.status.failed")
        case .cancelled: return String.l10n("agent.workspace.status.cancelled")
        case .planning: return String.l10n("agent.workspace.status.planning")
        case .running: return String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation: return String.l10n("agent.workspace.status.waitingForConfirmation")
        case .idle: return String.l10n("agent.workspace.status.idle")
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
