//
//  AgentHarnessProcessView.swift
//  Starcat
//
//  Harness 的紧凑过程区：公开内容与真实工具按序展示，完整事件通过菜单查阅。
//

import SwiftUI

/// 内外滚动拥有独立的跟随状态。内容增量只改变叶子行，禁止逐 token scrollTo
/// 或整个过程区的高度动画，避免重新引入长 Trace 的 AttributeGraph 布局反馈环。
struct AgentHarnessProcessView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var expandedOverride: Bool?
    @State private var expandedBlocks: Set<String> = []
    @State private var showsAllEvents = false
    @State private var tail = ScrollTailController()

    let viewModel: AgentWorkspaceViewModel

    private var isRunning: Bool {
        [.planning, .running, .waitingForConfirmation].contains(viewModel.status)
    }

    private var isExpanded: Bool {
        expandedOverride ?? (isRunning || requiresAttention)
    }

    private var requiresAttention: Bool {
        if viewModel.status == .failed || viewModel.status == .waitingForConfirmation { return true }
        return viewModel.harnessProcessRows(localeIdentifier: locale.identifier).contains { row in
            if case .trace(let event) = row.content {
                return event.status == .failed || event.status == .waiting
            }
            return false
        }
    }

    private var rows: [AgentHarnessProcessRow] {
        let settled = viewModel.harnessProcessRows(localeIdentifier: locale.identifier)
        guard showsAllEvents else {
            guard let stream = viewModel.assistantStream else { return settled }
            return AgentHarnessProcessPresentation.sorted(
                settled + AgentHarnessProcessPresentation.streamingRows(stream)
            )
        }
        let auditRows = viewModel.harnessAuditRows(localeIdentifier: locale.identifier)
        var contentRows = settled.filter {
            if case .block = $0.content { return true }
            return false
        }
        if let stream = viewModel.assistantStream {
            contentRows += AgentHarnessProcessPresentation.streamingRows(stream)
        }
        return AgentHarnessProcessPresentation.sorted(auditRows + contentRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    expandedOverride = !isExpanded
                } label: {
                    HStack(spacing: 6) {
                        Text(statusTitle)
                            .lineLimit(1)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        Spacer(minLength: 0)
                    }
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityHint(String.l10n(isExpanded ? "gettingStarted.collapse" : "gettingStarted.expand"))

                Menu {
                    Button {
                        showsAllEvents.toggle()
                        expandedOverride = true
                    } label: {
                        Label(
                            showsAllEvents ? "agent.workspace.trace.mode.process" : "agent.workspace.trace.mode.allEvents",
                            systemImage: showsAllEvents ? "list.bullet" : "list.bullet.rectangle"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(showsAllEvents ? "agent.workspace.trace.mode.process" : "agent.workspace.trace.mode.allEvents")
                .accessibilityLabel(Text("agent.workspace.timeline.execution"))
            }

            if isExpanded {
                Divider()
                if !activitySummary.isEmpty {
                    Text(activitySummary)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                processBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: requiresAttention) { _, needsAttention in
            // 新出现的失败/阻塞主动展开一次；之后仍允许用户自己收起，不制造无效按钮。
            if needsAttention { expandedOverride = true }
        }
    }

    private var processBody: some View {
        let visibleRows = rows
        // 固定上限和确定性短内容高度避免 GeometryReader -> State -> frame 的反馈循环。
        // 展开的长内容在同一滚动区内阅读，不进入外层对话的全量高度测量。
        let height = min(
            360 * interfaceScale.multiplier,
            CGFloat(max(1, visibleRows.count)) * 30 * interfaceScale.multiplier
                + CGFloat(expandedBlocks.intersection(Set(visibleRows.map(\.id))).count) * 160
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if visibleRows.isEmpty {
                    HStack(spacing: 8) {
                        if isRunning {
                            ProgressView().controlSize(.mini)
                        }
                        Text(isRunning ? "agent.workspace.trace.reasoningPending" : "agent.workspace.trace.reasoningUnavailable")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 28)
                }
                ForEach(visibleRows) { row in
                    switch row.content {
                    case .trace(let event):
                        traceRow(row, event: event)
                    case .block(let part):
                        contentRow(row, part: part)
                    }
                }
                Color.clear.frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.5) { tail.updateBottomVisibility($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .defaultScrollAnchor(.top, for: .initialOffset)
        .defaultScrollAnchor(tail.isFollowing && isRunning ? .bottom : nil, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in tail.updatePhase(phase) }
    }

    private func traceRow(_ row: AgentHarnessProcessRow, event: AgentTraceEvent) -> some View {
        Button {
            viewModel.selectTraceEvent(event.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: traceIcon(event))
                    .foregroundStyle(traceTint(event))
                    .frame(width: 16)
                if showsAllEvents {
                    Text("#\(event.sequence)")
                        .font(interfaceScale.font(.captionSmall, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(AgentTraceTitlePresentation.title(for: event))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let summary = row.summary {
                    Text("·")
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if isRunning && (event.status == .running || event.status == .pending) {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityHint(String.l10n("agent.workspace.inspector.step.subtitle"))
        .background {
            if viewModel.selectedTraceEventID == event.id {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.09))
            }
        }
    }

    @ViewBuilder
    private func contentRow(_ row: AgentHarnessProcessRow, part: AgentMessagePart) -> some View {
        switch part {
        case .text(let text), .reasoning(let text):
            let isReasoning: Bool = if case .reasoning = part { true } else { false }
            let isOpen = expandedBlocks.contains(row.id)
            let running = viewModel.assistantStream?.sequence == row.sequence && isRunning
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    // 不使用展开动画；长 Markdown 的逐帧 sizeThatFits 曾导致中栏卡死。
                    if isOpen { expandedBlocks.remove(row.id) } else { expandedBlocks.insert(row.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isReasoning ? "brain" : "text.bubble").frame(width: 16)
                        Text(isReasoning ? "agent.workspace.trace.kind.thinking" : "agent.workspace.trace.kind.commentary")
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                        Text(running ? AgentHarnessProcessRow.preview(text, running: true) : row.summary ?? "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(interfaceScale.font(.captionSmall))
                    }
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityHint(String.l10n(isOpen ? "gettingStarted.collapse" : "gettingStarted.expand"))
                if isOpen {
                    // 思考使用有界纯文本，正文复用现有 Markdown 组件；只创建用户展开的块。
                    if isReasoning {
                        Text(AgentTracePresentationBudget.bounded(text, limit: 8_000))
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 24)
                    } else {
                        RAGMarkdownText(content: AgentTracePresentationBudget.bounded(text, limit: 8_000))
                            .padding(.leading, 24)
                    }
                }
            }
        case .toolCall, .toolResult:
            EmptyView()
        }
    }

    private var activitySummary: String {
        if showsAllEvents { return String.l10n("agent.workspace.trace.mode.allEvents") }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in viewModel.harnessProcessRows(localeIdentifier: locale.identifier) {
            guard case .trace(let event) = row.content,
                  [.tool, .mcpTool, .command, .webSearch, .fileChange].contains(event.kind) else { continue }
            let title = AgentTraceTitlePresentation.title(for: event)
            if counts[title] == nil { order.append(title) }
            counts[title, default: 0] += 1
        }
        return order.map { "\($0) ×\(counts[$0, default: 0].formatted(.number.locale(locale)))" }
            .joined(separator: " · ")
    }

    private var statusTitle: String {
        if viewModel.status == .completed,
           let start = viewModel.runStartedAt, let end = viewModel.runFinishedAt {
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            let duration = formatter.string(from: max(1, end.timeIntervalSince(start))) ?? ""
            return String(format: String.l10n("agent.workspace.process.completedDurationFormat"), duration)
        }
        return String.l10n("agent.workspace.status.\(viewModel.status.rawValue)")
    }

    private func traceIcon(_ event: AgentTraceEvent) -> String {
        if event.status == .failed { return "xmark.circle.fill" }
        if event.status == .waiting { return "pause.circle.fill" }
        switch event.kind {
        case .reasoningSummary: return "brain"
        case .tool, .mcpTool:
            let name = AgentTraceTitlePresentation.normalizedToolName(event.title)
            if name == "starcat.search_repos" || name == "knowledge_search" { return "magnifyingglass" }
            if name == "starcat.get_readme" || name == "starcat.get_repo_summary" { return "doc.text" }
            return "wrench.and.screwdriver"
        case .command: return "terminal"
        case .webSearch: return "globe"
        case .fileChange: return "doc.badge.gearshape"
        case .plan, .todo: return "checklist"
        case .warning: return "exclamationmark.triangle"
        case .retry: return "arrow.clockwise"
        case .error: return "xmark.octagon"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .approval: return "checkmark.shield"
        default: return "text.bubble"
        }
    }

    private func traceTint(_ event: AgentTraceEvent) -> Color {
        if event.status == .failed || event.kind == .error { return .red }
        if event.status == .waiting || event.kind == .warning { return .orange }
        return .secondary
    }
}
