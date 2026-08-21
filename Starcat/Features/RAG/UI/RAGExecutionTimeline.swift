//
//  RAGExecutionTimeline.swift
//  Starcat
//
//  RAG 回答前后的紧凑步骤轨迹。
//
//  查询规划把规划思考缩进成子步骤；规划 JSON 仍须等思考流结束才解析，
//  所以父步骤在 planningCompleted 之前保持 running。
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

/// 时间线顶层条目。规划思考不是并列第二步，渲染时缩进挂在查询规划下面。
enum RAGExecutionTimelineItem: Identifiable, Equatable {
    case step(RAGExecutionStep)
    case planning(parent: RAGExecutionStep, reasoning: RAGExecutionStep?)

    var id: RAGExecutionStepKind {
        switch self {
        case .step(let step):
            return step.kind
        case .planning:
            return .planning
        }
    }
}

/// 把扁平 execution trace 收成 Agent 常见的「父步骤 + 内部思考」结构。
///
/// 存储仍保持 `planning` / `planningReasoning` 两条记录，避免改已落地的会话 JSON。
enum RAGExecutionTimelineGrouping {
    static func items(from steps: [RAGExecutionStep]) -> [RAGExecutionTimelineItem] {
        var items: [RAGExecutionTimelineItem] = []
        var index = 0
        while index < steps.count {
            let step = steps[index]
            if step.kind == .planning {
                var reasoning: RAGExecutionStep?
                if index + 1 < steps.count, steps[index + 1].kind == .planningReasoning {
                    reasoning = steps[index + 1]
                    index += 1
                }
                items.append(.planning(parent: step, reasoning: reasoning))
            } else {
                items.append(.step(step))
            }
            index += 1
        }
        return items
    }

    /// 运行中默认展开。查询规划在结果刚写出、还没有下一个顶层步骤时也保持展开。
    static func defaultExpanded(
        for step: RAGExecutionStep,
        items: [RAGExecutionTimelineItem]
    ) -> Bool {
        if step.state == .running {
            return true
        }
        if step.kind == .planning {
            return items.last?.id == .planning
        }
        return false
    }
}

/// 执行步骤的局部折叠状态。
///
/// 默认展开/折叠由 `defaultExpanded` 决定；两个集合只记录用户对当前默认值的反向操作。
/// 必须把「默认展开时的主动折叠」单独保存，否则后续流式 delta 触发 View 刷新时会再次被强制展开。
struct RAGExecutionDisclosureState {
    private var userExpanded: Set<RAGExecutionStepKind> = []
    private var userCollapsed: Set<RAGExecutionStepKind> = []

    func isExpanded(_ step: RAGExecutionStep, defaultExpanded: Bool) -> Bool {
        if defaultExpanded {
            return !userCollapsed.contains(step.kind)
        }
        return userExpanded.contains(step.kind)
    }

    func isExpanded(_ step: RAGExecutionStep) -> Bool {
        isExpanded(step, defaultExpanded: step.state == .running)
    }

    mutating func toggle(_ step: RAGExecutionStep, defaultExpanded: Bool) {
        if defaultExpanded {
            if userCollapsed.contains(step.kind) {
                userCollapsed.remove(step.kind)
            } else {
                userCollapsed.insert(step.kind)
            }
            return
        }

        if userExpanded.contains(step.kind) {
            userExpanded.remove(step.kind)
        } else {
            userExpanded.insert(step.kind)
        }
    }

    mutating func toggle(_ step: RAGExecutionStep) {
        toggle(step, defaultExpanded: step.state == .running)
    }
}

/// RAG 回答前后的紧凑步骤轨迹。
///
/// 查询规划把规划思考收成缩进子步骤；规划结果刚写出时父步骤保持展开，下一步开始后再收成摘要。
/// 当前运行步骤默认展开，用户可在输出期间随时折叠或重新展开。
/// 生成回答是最终阅读上下文，始终展开而不会被折叠逻辑收起。该组件只渲染脱敏的
/// `RAGExecutionStep`，不能读取 Debug trace。
struct RAGExecutionTimeline: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.ragSettingsNavigation) private var settingsNavigation

    let steps: [RAGExecutionStep]
    /// 运行中思考由 session 直接追加到 NSTextView；历史消息保持 nil。
    var livePlanningReasoning: RAGStreamingPlainTextSession? = nil
    var liveAnswerReasoning: RAGStreamingPlainTextSession? = nil
    @State private var disclosureState = RAGExecutionDisclosureState()

    var body: some View {
        let items = RAGExecutionTimelineGrouping.items(from: steps)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                switch item {
                case .planning(let parent, let reasoning):
                    planningGroup(parent: parent, reasoning: reasoning, items: items)
                case .step(let step):
                    executionStep(step, indent: 0, items: items)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 查询规划是父步骤；思考缩进一级，规划 notes 在思考之后作为这一步的结果。
    private func planningGroup(
        parent: RAGExecutionStep,
        reasoning: RAGExecutionStep?,
        items: [RAGExecutionTimelineItem]
    ) -> some View {
        let defaultExpanded = RAGExecutionTimelineGrouping.defaultExpanded(for: parent, items: items)
        let isExpanded = disclosureState.isExpanded(parent, defaultExpanded: defaultExpanded)
        return VStack(alignment: .leading, spacing: 4) {
            stepHeader(parent, isExpanded: isExpanded) {
                disclosureState.toggle(parent, defaultExpanded: defaultExpanded)
            }
            if isExpanded {
                if let reasoning {
                    executionStep(reasoning, indent: 1, items: items)
                }
                // 思考还在流式输出时规划 notes 尚未写入，不要留一块空内容区。
                if !parent.details.isEmpty || !(parent.summary ?? "").isEmpty {
                    stepDetails(parent)
                        .padding(.leading, RAGMessageAvatarMetrics.size + 7)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func executionStep(
        _ step: RAGExecutionStep,
        indent: Int,
        items: [RAGExecutionTimelineItem]
    ) -> some View {
        let defaultExpanded = RAGExecutionTimelineGrouping.defaultExpanded(for: step, items: items)
        let isExpanded = disclosureState.isExpanded(step, defaultExpanded: defaultExpanded)
        return VStack(alignment: .leading, spacing: 7) {
            stepHeader(step, isExpanded: isExpanded) {
                disclosureState.toggle(step, defaultExpanded: defaultExpanded)
            }
            if isExpanded {
                stepDetails(step)
                    .padding(.leading, RAGMessageAvatarMetrics.size + 7)
            }
        }
        .padding(.leading, CGFloat(indent) * RAGMessageAvatarMetrics.size)
        .padding(.vertical, 3)
    }

    private func stepHeader(
        _ step: RAGExecutionStep,
        isExpanded: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                toggle()
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
                    .font(interfaceScale.font(
                        RAGConversationTypography.executionTitle,
                        weight: .medium
                    ))
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
    }

    @ViewBuilder
    private func stepDetails(_ step: RAGExecutionStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if isReasoningStep(step.kind) {
                reasoningDetails(step)
            } else {
                ForEach(step.details.indices, id: \.self) { index in
                    Label(step.details[index], systemImage: "minus")
                        .font(interfaceScale.font(RAGConversationTypography.executionDetail))
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
    }

    @ViewBuilder
    private func reasoningDetails(_ step: RAGExecutionStep) -> some View {
        if step.state == .running, let session = liveReasoningSession(for: step.kind) {
            RAGStreamingReasoningViewport(session: session, pinsToBottom: true)
        } else {
            let text = completedReasoningText(for: step)
            if !text.isEmpty {
                RAGCompletedReasoningViewport(text: text)
            }
        }
    }

    /// 完成后优先用已写入步骤的 details；同轮 session 尚未被清时作为兜底。
    private func completedReasoningText(for step: RAGExecutionStep) -> String {
        if let detail = step.details.first, !detail.isEmpty {
            return detail
        }
        return liveReasoningSession(for: step.kind)?.text ?? ""
    }

    private func isReasoningStep(_ kind: RAGExecutionStepKind) -> Bool {
        kind == .planningReasoning || kind == .answerReasoning
    }

    private func liveReasoningSession(for kind: RAGExecutionStepKind) -> RAGStreamingPlainTextSession? {
        switch kind {
        case .planningReasoning:
            return livePlanningReasoning
        case .answerReasoning:
            return liveAnswerReasoning
        default:
            return nil
        }
    }

    /// 回答前的可折叠步骤显示真实耗时；结束后固定为真实起止时间差。
    @ViewBuilder
    private func executionDuration(_ step: RAGExecutionStep) -> some View {
        if step.state == .running, step.startedAt != nil {
            // 步骤耗时与 reasoning delta 解耦：Provider 无新字符时仍以 0.1s 精度读秒，
            // 且 TimelineView 只包围数字标签，不会驱动整条执行轨迹刷新。
            TimelineView(.periodic(from: .now, by: RAGLiveDurationClock.stepTickInterval)) { context in
                executionDurationText(step.elapsedDuration(at: context.date))
            }
        } else {
            executionDurationText(step.elapsedDuration())
        }
    }

    @ViewBuilder
    private func executionDurationText(_ duration: TimeInterval?) -> some View {
        if let duration {
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
    nonisolated static func shouldOfferExternalSearchSettings(for item: RAGRemoteExecutionAuditItem) -> Bool {
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
        case .repositoryInsights: return "rag.workspace.execution.repositoryInsights.title"
        case .repoContext: return "rag.workspace.execution.repoContext.title"
        case .remoteContext: return "rag.workspace.execution.remote.title"
        case .answerReasoning: return "rag.workspace.execution.reasoning.answer.title"
        case .generation: return "rag.workspace.execution.generation.title"
        }
    }
}
