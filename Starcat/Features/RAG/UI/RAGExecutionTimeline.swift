//
//  RAGExecutionTimeline.swift
//  Starcat
//
//  RAG 回答前后的紧凑步骤轨迹。
//

import SwiftUI

/// RAG 回答前后的紧凑步骤轨迹。
///
/// 当前运行步骤自动展开；前序步骤完成后自动折叠为摘要。用户可重新展开已完成步骤，
/// 但生成回答是最终阅读上下文，始终展开而不会被折叠逻辑收起。该组件只渲染脱敏的
/// `RAGExecutionStep`，不能读取 Debug trace。
struct RAGExecutionTimeline: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    let steps: [RAGExecutionStep]
    @State private var manuallyExpanded: Set<RAGExecutionStepKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                executionStep(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func executionStep(_ step: RAGExecutionStep) -> some View {
        let isExpanded = step.state == .running
            || manuallyExpanded.contains(step.kind)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    if isExpanded {
                        manuallyExpanded.remove(step.kind)
                    } else {
                        manuallyExpanded.insert(step.kind)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    stepStatusIcon(step)
                        .frame(width: 15, height: 15)
                    Text(titleKey(for: step.kind))
                        .font(interfaceScale.font(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if !isExpanded, let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if step.kind != .generation {
                        executionDuration(step)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(step.details.indices, id: \.self) { index in
                        let detail = step.details[index]
                        if step.kind == .planningReasoning || step.kind == .answerReasoning {
                            Text(detail)
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                        } else {
                            Label(detail, systemImage: "minus")
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if step.kind == .remoteContext {
                        ForEach(step.remoteAuditItems ?? []) { item in
                            remoteAuditItem(item)
                        }
                    }
                    if let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 23)
            }
        }
        .padding(.vertical, 3)
    }

    /// 回答前的可折叠步骤显示真实耗时；结束后固定为真实起止时间差。
    @ViewBuilder
    private func executionDuration(_ step: RAGExecutionStep) -> some View {
        if let duration = step.elapsedDuration() {
            Text(String(
                format: String.l10n("rag.workspace.execution.duration.format"),
                locale: locale,
                duration
            ))
            .font(interfaceScale.font(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private func stepStatusIcon(_ step: RAGExecutionStep) -> some View {
        if step.state == .running {
            ProgressView()
                .controlSize(.mini)
        } else if step.kind == .remoteContext,
                  (step.remoteAuditItems ?? []).contains(where: { $0.status == .failed || $0.status == .empty }) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(interfaceScale.font(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
        } else {
            Image(systemName: step.state == .skipped ? "arrowshape.turn.up.right" : "checkmark.circle.fill")
                .font(interfaceScale.font(size: 14, weight: .semibold))
                .foregroundStyle(step.state == .skipped ? Color.secondary : Color.green)
        }
    }

    private func remoteAuditItem(_ item: RAGRemoteExecutionAuditItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                remoteAuditStatusIcon(item.status)
                Text("\(item.repoFullName) · \(remoteResourceName(item.resource))")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(remoteStatusName(item.status))
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !item.querySummary.isEmpty {
                Text(String(
                    format: String.l10n("rag.workspace.execution.remote.queryFormat"),
                    item.querySummary
                ))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let transport = item.transport {
                    Text(transport == .cache
                         ? String.l10n("rag.workspace.execution.remote.cache")
                         : String.l10n("rag.workspace.execution.remote.network"))
                }
                if let status = item.httpStatusCode { Text("HTTP \(status)") }
                if let count = item.resultCount {
                    Text(String(
                        format: String.l10n("rag.workspace.execution.remote.resultCountFormat"),
                        count
                    ))
                }
                if let startedAt = item.startedAt, let completedAt = item.completedAt {
                    Text(String(
                        format: String.l10n("rag.workspace.execution.duration.format"),
                        locale: locale,
                        max(0, completedAt.timeIntervalSince(startedAt))
                    ))
                }
            }
            .font(interfaceScale.font(.captionSmall, design: .monospaced))
            .foregroundStyle(.secondary)
            if let error = item.errorMessage, !error.isEmpty {
                Text(error)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let url = item.requestURL {
                Link(String.l10n("rag.workspace.execution.remote.endpoint"), destination: url)
                    .font(interfaceScale.font(.captionSmall))
            }
        }
        .padding(7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func remoteAuditStatusIcon(_ status: RAGRemoteExecutionStatus) -> some View {
        switch status {
        case .pending, .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .empty, .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
        case .skipped:
            Image(systemName: "arrowshape.turn.up.right").foregroundStyle(.secondary)
        }
    }

    private func remoteStatusName(_ status: RAGRemoteExecutionStatus) -> String {
        String.l10n("rag.workspace.execution.remote.status.\(status.rawValue)")
    }

    private func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        }
    }

    private func titleKey(for kind: RAGExecutionStepKind) -> LocalizedStringKey {
        switch kind {
        case .planning: return "rag.workspace.execution.planning.title"
        case .planningReasoning: return "rag.workspace.execution.reasoning.planning.title"
        case .retrieval: return "rag.workspace.execution.retrieval.title"
        case .remoteContext: return "rag.workspace.execution.remote.title"
        case .answerReasoning: return "rag.workspace.execution.reasoning.answer.title"
        case .generation: return "rag.workspace.execution.generation.title"
        }
    }
}
