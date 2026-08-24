//
//  AgentRunInspectorView.swift
//  Starcat
//
//  Agent 工作台的任务检查器。
//
//  右栏沿用 RAG 工作台已验证的“等宽页签 + 紧凑信息组”视觉语言，但业务数据仍来自
//  Agent Run 的冻结事实。时间线选中步骤时临时进入步骤详情，返回后继续保留原页签；
//  这样三种 Runtime 可以共用布局，同时完整展示各自真实返回的过程事件。
//

import SwiftUI

/// Inspector 标题与中栏 `runHeader` 同构，保证 `HSplitView` 下两栏分割线水平对齐。
struct AgentRunInspectorHeader: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let viewModel: AgentWorkspaceViewModel

    private var pendingApproval: AgentApprovalRequest? {
        viewModel.approvals.first { $0.status == .pending }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sidebar.trailing")
                .font(interfaceScale.font(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("agent.workspace.inspector.title")
                    .font(interfaceScale.font(.panelTitle, weight: .semibold))
                    .lineLimit(1)
                Text(inspectorSubtitle)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Text(statusLabel)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(statusTint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusTint.opacity(0.10), in: Capsule())

            if viewModel.inspectorTab == .artifacts,
               viewModel.selectedArtifact != nil,
               viewModel.selectedTraceEvent == nil,
               viewModel.selectedKnowledgeAudit == nil,
               pendingApproval == nil {
                CopyFeedbackButton(
                    providesContent: { viewModel.selectedArtifact?.content ?? "" },
                    tooltip: "agent.workspace.inspector.copy"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(interfaceScale.font(size: 13, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : .secondary)
                        .frame(width: 24, height: 24)
                }
                Button {
                    viewModel.exportSelectedArtifact()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(interfaceScale.font(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("agent.workspace.inspector.export")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var inspectorSubtitle: String {
        if pendingApproval != nil { return String.l10n("agent.workspace.inspector.approval.subtitle") }
        if viewModel.selectedTraceEvent != nil { return String.l10n("agent.workspace.inspector.step.subtitle") }
        if viewModel.selectedKnowledgeAudit != nil { return String.l10n("agent.workspace.knowledgeAudit.subtitle") }
        switch viewModel.inspectorTab {
        case .run: return String.l10n("agent.workspace.inspector.summary.subtitle")
        case .context: return String.l10n("agent.workspace.inspector.context.subtitle")
        case .artifacts: return String.l10n("agent.workspace.inspector.artifact.subtitle")
        }
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .idle: String.l10n("agent.workspace.status.idle")
        case .planning: String.l10n("agent.workspace.status.planning")
        case .running: String.l10n("agent.workspace.status.running")
        case .waitingForConfirmation: String.l10n("agent.workspace.status.waitingForConfirmation")
        case .completed: String.l10n("agent.workspace.status.completed")
        case .failed: String.l10n("agent.workspace.status.failed")
        case .cancelled: String.l10n("agent.workspace.status.cancelled")
        }
    }

    private var statusTint: Color {
        switch viewModel.status {
        case .completed: .green
        case .failed: .red
        case .waitingForConfirmation: .orange
        case .planning, .running: .accentColor
        case .idle, .cancelled: .secondary
        }
    }
}

/// Agent Run 的统一任务检查器。页签负责浏览 Run，时间线选择负责查看单步事实。
struct AgentRunInspectorView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    let viewModel: AgentWorkspaceViewModel

    private var pendingApproval: AgentApprovalRequest? {
        viewModel.approvals.first { $0.status == .pending }
    }

    private var presentation: AgentRunInspectorPresentation {
        AgentRunInspectorPresentation(
            traceEvents: viewModel.traceEvents,
            messages: viewModel.messages,
            approvals: viewModel.approvals,
            artifacts: viewModel.artifacts,
            runRecord: viewModel.currentRunRecord
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let approval = pendingApproval {
                approvalInspector(approval)
            } else if let event = viewModel.selectedTraceEvent {
                traceInspector(event)
            } else if let audit = viewModel.selectedKnowledgeAudit {
                knowledgeAuditInspector(audit)
            } else {
                inspectorTabs
                ScrollView {
                    switch viewModel.inspectorTab {
                    case .run: runInspector
                    case .context: contextInspector
                    case .artifacts: artifactsInspector
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var inspectorTabs: some View {
        EqualWidthSegmentedControl(
            items: AgentInspectorTab.allCases,
            selection: Binding(
                get: { viewModel.inspectorTab },
                set: { viewModel.selectInspectorTab($0) }
            ),
            title: \.titleKey,
            font: interfaceScale.font(.caption, weight: .medium),
            controlHeight: 32
        )
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var runInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorGroup(title: String.l10n("agent.workspace.inspector.overview.execution"), icon: "point.3.connected.trianglepath.dotted") {
                metricRow(String.l10n("agent.workspace.inspector.overview.events"), presentation.stepCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.completed"), presentation.completedStepCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.active"), presentation.activeStepCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.failed"), presentation.failedStepCount.formatted(), valueColor: presentation.failedStepCount > 0 ? .red : .primary)
                metricRow(String.l10n("agent.workspace.inspector.summary.toolCalls"), presentation.toolCallCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.retries"), presentation.retryCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.compactions"), presentation.compactionCount.formatted())
            }

            inspectorGroup(title: String.l10n("agent.workspace.inspector.overview.runtime"), icon: "cpu") {
                metricRow(String.l10n("agent.workspace.inspector.overview.backend"), viewModel.runtimeBackend.displayName)
                if let provider = viewModel.runtimeProviderName {
                    metricRow(String.l10n("agent.workspace.inspector.overview.provider"), provider)
                }
                metricRow(String.l10n("agent.workspace.inspector.overview.model"), runtimeModelLabel)
                if let effort = viewModel.runtimeReasoningEffort {
                    metricRow(String.l10n("agent.workspace.inspector.overview.reasoning"), effort)
                }
                metricRow(String.l10n("agent.workspace.inspector.overview.startedAt"), dateLabel(presentation.startedAt))
                metricRow(String.l10n("agent.workspace.inspector.overview.duration"), durationLabel)
                metricRow(String.l10n("agent.workspace.inspector.overview.lastActivity"), dateLabel(presentation.lastActivityAt))
            }

            inspectorGroup(title: String.l10n("agent.workspace.inspector.overview.usage"), icon: "gauge.with.dots.needle.50percent") {
                metricRow(String.l10n("agent.workspace.inspector.summary.tokens"), viewModel.usage.totalTokens.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.inputTokens"), viewModel.usage.inputTokens.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.outputTokens"), viewModel.usage.outputTokens.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.reasoningTokens"), viewModel.usage.reasoningTokens.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.cachedTokens"), viewModel.usage.cachedTokens.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.cacheWriteTokens"), viewModel.usage.cacheWriteTokens?.formatted() ?? String.l10n("agent.workspace.inspector.value.unavailable"))
                metricRow(String.l10n("agent.workspace.inspector.overview.contextWindow"), contextWindowLabel)
                metricRow(String.l10n("agent.workspace.inspector.overview.firstOutput"), viewModel.usage.firstOutputLatencyMilliseconds.map(formatDuration) ?? String.l10n("agent.workspace.inspector.value.unavailable"))
                metricRow(String.l10n("agent.workspace.inspector.overview.cost"), estimatedCostLabel)
                if let source = viewModel.usage.estimatedCostSource {
                    metricRow(String.l10n("ai.usage.calls.source"), pricingSourceLabel(source))
                }
            }

            inspectorGroup(title: String.l10n("agent.workspace.inspector.overview.audit"), icon: "checkmark.shield") {
                metricRow(String.l10n("agent.workspace.inspector.overview.sources"), presentation.sourceCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.knowledgeAudits"), presentation.knowledgeAuditCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.approvals"), presentation.approvalRequestCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.approved"), presentation.approvedApprovalCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.rejected"), presentation.rejectedApprovalCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.fileChanges"), presentation.fileChangeCount.formatted())
                metricRow(String.l10n("agent.workspace.inspector.overview.warnings"), presentation.warningCount.formatted(), valueColor: presentation.warningCount > 0 ? .orange : .primary)
                metricRow(String.l10n("agent.workspace.inspector.overview.artifacts"), presentation.artifactCount.formatted())
            }

            if let error = viewModel.errorMessage {
                inspectorGroup(title: String.l10n("agent.workspace.inspector.summary.error"), icon: "exclamationmark.triangle.fill", tint: .red) {
                    Text(error)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var contextInspector: some View {
        if let context = viewModel.currentRunContext {
            VStack(alignment: .leading, spacing: 12) {
                inspectorGroup(title: String.l10n("agent.workspace.inspector.context.snapshot"), icon: "snowflake") {
                    metricRow(String.l10n("agent.workspace.inspector.context.source"), context.sourceDescription)
                    metricRow(String.l10n("agent.workspace.inspector.context.generatedAt"), dateLabel(context.generatedAt))
                    metricRow(String.l10n("agent.workspace.inspector.context.repositories"), context.repos.count.formatted())
                    metricRow(String.l10n("agent.workspace.inspector.context.knowledgeEligible"), (context.knowledgeEligibleRepoIDs?.count ?? 0).formatted())
                    metricRow(String.l10n("agent.workspace.inspector.context.attachments"), context.attachments.count.formatted())
                    metricRow(String.l10n("agent.workspace.inspector.context.links"), (context.githubLinks?.count ?? 0).formatted())
                    metricRow(String.l10n("agent.workspace.inspector.context.webSearch"), booleanLabel(context.webSearchEnabled == true))
                }

                if !context.repos.isEmpty {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.context.repositoryList"), icon: "shippingbox") {
                        ForEach(context.repos) { repo in
                            compactItemRow(
                                icon: repo.isPrivate ? "lock.fill" : "shippingbox",
                                title: repo.fullName,
                                subtitle: repo.language ?? String.l10n("agent.workspace.inspector.value.unavailable")
                            )
                        }
                    }
                }

                if !context.attachments.isEmpty {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.context.attachmentList"), icon: "paperclip") {
                        ForEach(context.attachments) { attachment in
                            compactItemRow(
                                icon: "doc",
                                title: attachment.name,
                                subtitle: ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)
                            )
                        }
                    }
                }

                if let links = context.githubLinks, !links.isEmpty {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.context.linkList"), icon: "link") {
                        ForEach(links) { link in
                            compactItemRow(icon: "link", title: "\(link.owner)/\(link.repository)", subtitle: link.url.absoluteString)
                        }
                    }
                }

                if let failureReason = context.failureReason {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.context.failure"), icon: "exclamationmark.triangle", tint: .red) {
                        Text(failureReason)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(Color.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        } else {
            emptyState(icon: "snowflake", title: String.l10n("agent.workspace.inspector.context.empty"))
        }
    }

    @ViewBuilder
    private var artifactsInspector: some View {
        if viewModel.artifacts.isEmpty {
            emptyState(icon: "doc.text.magnifyingglass", title: String.l10n("agent.workspace.inspector.noArtifacts"))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                inspectorGroup(title: String.l10n("agent.workspace.inspector.artifacts.list"), icon: "square.stack.3d.up") {
                    ForEach(viewModel.artifacts) { artifact in
                        artifactRow(artifact)
                    }
                }

                if let artifact = viewModel.selectedArtifact {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.artifacts.selected"), icon: artifactIcon(artifact)) {
                        metricRow(String.l10n("agent.workspace.inspector.artifacts.type"), artifact.type.title)
                        metricRow(String.l10n("agent.workspace.inspector.artifacts.characters"), artifact.content.count.formatted())
                        metricRow(String.l10n("agent.workspace.inspector.artifacts.createdAt"), dateLabel(artifact.createdAt))
                        if let toolCallID = artifact.toolCallID {
                            metricRow(String.l10n("agent.workspace.inspector.artifacts.toolCall"), toolCallID)
                        }
                        if artifact.type == .log {
                            Divider()
                            Text(AgentTracePresentationBudget.bounded(artifact.content, limit: AgentTracePresentationBudget.codeCharacters))
                                .font(interfaceScale.font(.code, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("agent.workspace.inspector.artifacts.markdownHint")
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func traceInspector(_ event: AgentTraceEvent) -> some View {
        VStack(spacing: 0) {
            detailNavigation(title: AgentTraceTitlePresentation.title(for: event), icon: "point.3.connected.trianglepath.dotted")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inspectorGroup(title: String.l10n("agent.workspace.inspector.step.metadata"), icon: "info.circle") {
                        metricRow(String.l10n("agent.workspace.inspector.step.status"), event.status.rawValue)
                        metricRow(String.l10n("agent.workspace.inspector.step.kind"), event.kind.rawValue)
                        metricRow(String.l10n("agent.workspace.inspector.overview.backend"), event.backend.displayName)
                        metricRow(String.l10n("agent.workspace.inspector.step.sequence"), event.sequence.formatted())
                        if let providerEventID = event.providerEventID {
                            metricRow(String.l10n("agent.workspace.inspector.step.providerEvent"), providerEventID)
                        }
                        if event.title != AgentTraceTitlePresentation.title(for: event) {
                            metricRow(String.l10n("agent.workspace.inspector.step.originalTitle"), event.title)
                        }
                        metricRow(String.l10n("agent.workspace.inspector.overview.startedAt"), dateLabel(event.startedAt))
                        metricRow(
                            String.l10n("agent.workspace.inspector.step.completedAt"),
                            event.completedAt.map(dateLabel) ?? String.l10n("agent.workspace.inspector.value.unavailable")
                        )
                        metricRow(String.l10n("agent.workspace.inspector.overview.duration"), event.durationMilliseconds.map(formatDuration) ?? String.l10n("agent.workspace.inspector.value.unavailable"))
                        if let attempt = event.attempt {
                            metricRow(String.l10n("agent.workspace.inspector.step.attempt"), attempt.formatted())
                        }
                        if let parentID = event.parentID {
                            metricRow(String.l10n("agent.workspace.inspector.step.parent"), parentID)
                        }
                    }

                    inspectorGroup(title: String.l10n("agent.workspace.inspector.step.details"), icon: "list.bullet.rectangle") {
                        if let summary = event.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            AgentTraceMarkdownText(markdown: summary, tone: .primary)
                        }
                        if event.hasDetails {
                            AgentTraceDetailsView(event: event)
                        } else if event.summary == nil {
                            Text("agent.workspace.inspector.step.noDetails")
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let usage = event.usage {
                        inspectorGroup(title: String.l10n("agent.workspace.inspector.step.usage"), icon: "gauge.with.dots.needle.50percent") {
                            metricRow(String.l10n("agent.workspace.inspector.overview.inputTokens"), usage.inputTokens.formatted())
                            metricRow(String.l10n("agent.workspace.inspector.overview.outputTokens"), usage.outputTokens.formatted())
                            metricRow(String.l10n("agent.workspace.inspector.overview.reasoningTokens"), usage.reasoningTokens.formatted())
                            metricRow(String.l10n("agent.workspace.inspector.overview.cachedTokens"), usage.cachedTokens.formatted())
                            metricRow(String.l10n("agent.workspace.inspector.overview.cacheWriteTokens"), usage.cacheWriteTokens?.formatted() ?? String.l10n("agent.workspace.inspector.value.unavailable"))
                            metricRow(String.l10n("agent.workspace.inspector.summary.tokens"), usage.totalTokens.formatted())
                            metricRow(String.l10n("agent.workspace.inspector.overview.contextWindow"), contextWindowLabel(for: usage))
                            metricRow(String.l10n("agent.workspace.inspector.overview.firstOutput"), usage.firstOutputLatencyMilliseconds.map(formatDuration) ?? String.l10n("agent.workspace.inspector.value.unavailable"))
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func knowledgeAuditInspector(_ audit: AgentKnowledgeRetrievalAudit) -> some View {
        VStack(spacing: 0) {
            detailNavigation(title: String.l10n("agent.workspace.knowledgeAudit.title"), icon: "checkmark.shield")
            Divider()
            ScrollView {
                AgentKnowledgeAuditView(audit: audit, showsTitle: false)
                    .padding(14)
            }
        }
    }

    private func approvalInspector(_ approval: AgentApprovalRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                inspectorGroup(title: String.l10n("agent.workspace.inspector.approval.title"), icon: "checkmark.shield", tint: .orange) {
                    metricRow(String.l10n("agent.workspace.inspector.approval.tool"), approval.toolName)
                    metricRow(String.l10n("agent.workspace.inspector.approval.permission"), approval.permission.localizedTitle)
                }
                inspectorGroup(title: String.l10n("agent.workspace.timeline.input"), icon: "curlybraces") {
                    Text((try? approval.input.jsonString()) ?? "{}")
                        .font(interfaceScale.font(.code, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                inspectorGroup(title: String.l10n("agent.workspace.inspector.approval.risk"), icon: "exclamationmark.triangle", tint: .orange) {
                    Text("agent.workspace.inspector.approval.riskDetail")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button { viewModel.reject(approval) } label: {
                        Label("agent.workspace.confirmation.reject", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    Button { viewModel.approve(approval) } label: {
                        Label("agent.workspace.confirmation.approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
    }

    private func detailNavigation(title: String, icon: String) -> some View {
        Button {
            viewModel.clearInspectorDetail()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: icon)
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("agent.workspace.inspector.step.back")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func inspectorGroup<Content: View>(
        title: String,
        icon: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(interfaceScale.font(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 0.5)
        }
    }

    private func metricRow(_ title: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func compactItemRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artifactRow(_ artifact: AgentArtifact) -> some View {
        Button {
            viewModel.selectArtifact(artifact.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: artifactIcon(artifact))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(viewModel.selectedArtifact?.id == artifact.id ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.title)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(String(format: String.l10n("agent.workspace.inspector.artifactMetadataFormat"), artifact.type.title, artifact.content.count))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if viewModel.selectedArtifact?.id == artifact.id {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.09))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func emptyState(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(interfaceScale.font(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 60)
    }

    private var runtimeModelLabel: String {
        viewModel.runtimeModelName
            ?? viewModel.currentRunContext?.selectedModelID
            ?? viewModel.currentRunRecord?.model
            ?? String.l10n("agent.workspace.inspector.value.unavailable")
    }

    private var durationLabel: String {
        guard let milliseconds = presentation.durationMilliseconds() else {
            return String.l10n("agent.workspace.inspector.value.unavailable")
        }
        return formatDuration(milliseconds)
    }

    private var estimatedCostLabel: String {
        guard let cost = viewModel.usage.estimatedCost else {
            return String.l10n("agent.workspace.inspector.value.unavailable")
        }
        return NSDecimalNumber(decimal: cost).doubleValue.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(2 ... 6))
                .locale(locale)
        )
    }

    private func pricingSourceLabel(_ source: String) -> String {
        switch source {
        case "litellm-live": "LiteLLM · Live"
        case "litellm-cache": "LiteLLM · Cache"
        case "litellm-stale-cache": "LiteLLM · Stale Cache"
        case "litellm-seed": "LiteLLM · Offline"
        default: source
        }
    }

    private var contextWindowLabel: String {
        contextWindowLabel(for: viewModel.usage)
    }

    private func contextWindowLabel(for usage: AgentUsage) -> String {
        guard let used = usage.contextWindowUsedTokens,
              let limit = usage.contextWindowLimitTokens,
              limit > 0
        else { return String.l10n("agent.workspace.inspector.value.unavailable") }
        let percent = min(100, max(0, Double(used) / Double(limit) * 100))
        return String(format: "%@ / %@ · %.0f%%", used.formatted(), limit.formatted(), percent)
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return String.l10n("agent.workspace.inspector.value.unavailable") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds.formatted()) ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return String(format: "%d min %.0f s", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func booleanLabel(_ value: Bool) -> String {
        String.l10n(value
            ? "agent.workspace.inspector.value.enabled"
            : "agent.workspace.inspector.value.disabled")
    }

    private func artifactIcon(_ artifact: AgentArtifact) -> String {
        artifact.type == .markdown ? "doc.richtext" : "doc.text.magnifyingglass"
    }
}
