//
//  RAGExecutionTimeline.swift
//  Starcat
//
//  RAG 回答前后的紧凑步骤轨迹。
//
//  步骤图标只表达状态，不按 kind 换语义符号：
//  - running：`ellipsis.circle` + accent + `.symbolEffect(.pulse)`（reduceMotion 关闭）
//  - completed：绿色 `checkmark.circle.fill`
//  - 联网 failed/empty：橙色 `exclamationmark.circle.fill`
//  - skipped：`arrowshape.turn.up.right` + secondary
//

import SwiftUI

/// AppKit 自建的 RAG 窗口无法自行取得主 SwiftUI Scene 的 `OpenSettingsAction`，
/// 因此由创建窗口的入口注入一个窄化后的设置导航动作。
struct RAGSettingsNavigationAction {
    private let handler: @MainActor (String) -> Void

    init(handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ target: String) {
        handler(target)
    }
}

private struct RAGSettingsNavigationActionKey: EnvironmentKey {
    /// Preview / 单测没有主 Scene 时保持 no-op，避免重新引入不可靠的 AppKit selector 兜底。
    static let defaultValue = RAGSettingsNavigationAction { _ in }
}

extension EnvironmentValues {
    var ragSettingsNavigation: RAGSettingsNavigationAction {
        get { self[RAGSettingsNavigationActionKey.self] }
        set { self[RAGSettingsNavigationActionKey.self] = newValue }
    }
}

/// 执行步骤的局部折叠状态。
///
/// 运行中默认展开、完成后默认折叠是时间线的自动行为；两个集合只记录用户对当前默认值的反向操作。
/// 必须把运行中主动折叠单独保存，否则后续流式 delta 触发 View 刷新时会再次被 `running` 强制展开。
struct RAGExecutionDisclosureState {
    private var manuallyExpanded: Set<RAGExecutionStepKind> = []
    private var collapsedWhileRunning: Set<RAGExecutionStepKind> = []

    func isExpanded(_ step: RAGExecutionStep) -> Bool {
        if step.state == .running {
            return !collapsedWhileRunning.contains(step.kind)
        }
        return manuallyExpanded.contains(step.kind)
    }

    mutating func toggle(_ step: RAGExecutionStep) {
        if step.state == .running {
            if collapsedWhileRunning.contains(step.kind) {
                collapsedWhileRunning.remove(step.kind)
            } else {
                collapsedWhileRunning.insert(step.kind)
            }
            return
        }

        if manuallyExpanded.contains(step.kind) {
            manuallyExpanded.remove(step.kind)
        } else {
            manuallyExpanded.insert(step.kind)
        }
    }
}

/// RAG 回答前后的紧凑步骤轨迹。
///
/// 当前运行步骤默认展开，但用户可在输出期间随时折叠或重新展开；前序步骤完成后自动折叠为摘要。
/// 用户也可重新展开已完成步骤，
/// 但生成回答是最终阅读上下文，始终展开而不会被折叠逻辑收起。该组件只渲染脱敏的
/// `RAGExecutionStep`，不能读取 Debug trace。
struct RAGExecutionTimeline: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.ragSettingsNavigation) private var settingsNavigation

    let steps: [RAGExecutionStep]
    @State private var disclosureState = RAGExecutionDisclosureState()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                executionStep(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func executionStep(_ step: RAGExecutionStep) -> some View {
        let isExpanded = disclosureState.isExpanded(step)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    disclosureState.toggle(step)
                }
            } label: {
                // 图标槽与消息头 Starcat logo 同宽，glyph 居中，保证竖向轴线对齐。
                HStack(spacing: 7) {
                    stepStatusIcon(step)
                        .frame(
                            width: RAGMessageAvatarMetrics.size,
                            height: RAGMessageAvatarMetrics.size
                        )
                    Text(titleKey(for: step.kind))
                        .font(interfaceScale.font(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    // 摘要、耗时与 chevron 均紧随标题，和主窗口 AI 对话的 Think 行保持一致；
                    // 此处不能用 Spacer 将折叠信息推到窗口最右侧。
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
                // 与标题行一致：logo 槽宽 + HStack spacing，让展开内容贴齐标题文字左缘。
                .padding(.leading, RAGMessageAvatarMetrics.size + 7)
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

    /// 三态状态图标：进行中 / 完成 / 联网降级；不按步骤类型换语义符号。
    private func stepStatusIcon(_ step: RAGExecutionStep) -> some View {
        let isRunning = step.state == .running
        let isDegradedRemote = step.kind == .remoteContext
            && (step.remoteAuditItems ?? []).contains(where: { $0.status == .failed || $0.status == .empty })
        return Image(systemName: symbolName(for: step, isDegradedRemote: isDegradedRemote))
            .font(interfaceScale.font(size: 14, weight: .semibold))
            .foregroundStyle(stepIconColor(state: step.state, isDegradedRemote: isDegradedRemote))
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: isRunning && !reduceMotion
            )
            .accessibilityLabel(Text(titleKey(for: step.kind)))
    }

    private func stepIconColor(state: RAGExecutionStepState, isDegradedRemote: Bool) -> Color {
        switch state {
        case .running:
            return Color.accentColor
        case .skipped:
            return Color.secondary
        case .completed:
            return isDegradedRemote ? Color.orange : Color.green
        }
    }

    private func symbolName(for step: RAGExecutionStep, isDegradedRemote: Bool) -> String {
        switch step.state {
        case .running:
            return "ellipsis.circle"
        case .skipped:
            return "arrowshape.turn.up.right"
        case .completed:
            return isDegradedRemote ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        }
    }

    private func remoteAuditItem(_ item: RAGRemoteExecutionAuditItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                remoteAuditStatusIcon(item.status)
                Text(remoteAuditTitle(item))
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
            if Self.shouldOfferExternalSearchSettings(for: item) {
                Button {
                    settingsNavigation("integrations.externalSearch")
                } label: {
                    Label(
                        "rag.workspace.execution.remote.configureExternalSearch",
                        systemImage: "gearshape"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let url = item.requestURL {
                Link(String.l10n("rag.workspace.execution.remote.endpoint"), destination: url)
                    .font(interfaceScale.font(.captionSmall))
            }
            ForEach(item.resultPreviews.prefix(5)) { preview in
                Link(destination: preview.url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text(preview.title)
                            .lineLimit(1)
                    }
                }
                .font(interfaceScale.font(.captionSmall))
                .help(preview.url.absoluteString)
            }
        }
        .padding(7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 仅 External Search 执行失败时提供配置入口；无结果不代表配置错误，GitHub 失败也不归该设置项处理。
    static func shouldOfferExternalSearchSettings(for item: RAGRemoteExecutionAuditItem) -> Bool {
        item.resource == .externalWeb && item.status == .failed
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

    private func remoteAuditTitle(_ item: RAGRemoteExecutionAuditItem) -> String {
        if item.resource == .externalWeb {
            return "\(item.providerName ?? "External Search") · Web"
        }
        return "\(item.repoFullName) · \(remoteResourceName(item.resource))"
    }

    private func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        case .externalWeb: return "Web Search"
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
