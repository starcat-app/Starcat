//
//  GitHubNotificationIssueSummaryPopover.swift
//  Starcat
//
//  Issue 总结 Popover 的内容。独立 Markdown 子视图观察正文快照，
//  避免流式更新反复刷新标题和操作区。
//

import SwiftUI

/// 弹层读取当前总结会话，生成任务由 Store 持有，可在下次打开时继续阅读。
struct GitHubNotificationIssueSummaryPopover: View {
    let title: String
    let payload: ActivityNotificationPayload
    let timeline: [GitHubNotificationIssueTimelineItem]
    let language: String
    let session: GitHubNotificationIssueSummarySession
    let preparationError: String?
    let preparationNeedsSettings: Bool
    let onRegenerate: () -> Void

    @Environment(\.locale) private var locale

    private var errorMessage: String? { preparationError ?? session.errorMessage }
    private var needsSettings: Bool { preparationNeedsSettings || session.needsSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            GitHubNotificationIssueSummaryMarkdownView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            notices
            Divider()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .font(.headline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("activity.issueSummary.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: subjectLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subjectLabel)
            }
            Spacer(minLength: 4)
            CopyFeedbackButton(
                providesContent: { session.markdown },
                tooltip: "ai.assistant.summary.copy.tooltip"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .disabled(!session.hasContent || session.isGenerating)
            .accessibilityLabel(Text("ai.assistant.summary.copy.tooltip"))
        }
    }

    private var subjectLabel: String {
        let number = payload.subjectNumber.map { " · #\($0)" } ?? ""
        return payload.repositoryFullName + number
    }

    @ViewBuilder
    private var notices: some View {
        if let errorMessage {
            Text(verbatim: errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(errorMessage)
            if session.hasContent && preparationError == nil {
                Text("activity.issueSummary.incomplete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if session.hasStarted && !session.matchesSource(title: title, payload: payload, timeline: timeline, language: language) {
            Text("activity.issueSummary.stale")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if let context = session.context {
            let scope = String(
                format: String.l10n("activity.issueSummary.scope"),
                locale: locale,
                Int64(context.includedCommentCount)
            )
            Text(verbatim: scope)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(scope)
            if context.isTruncated {
                Text("activity.issueSummary.truncated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if session.isGenerating {
                ProgressView().controlSize(.small)
                Text("activity.issueSummary.loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if session.wasInterrupted {
                Text("activity.issueSummary.stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let generatedAt = session.generatedAt, session.hasContent {
                generatedAtFooterLabel(generatedAt)
            }
            Spacer(minLength: 0)
            if needsSettings {
                Button("readme.translate.error.goToAISettings") {
                    AppDelegate.openSettingsWindow(target: "ai")
                }
            }
            if session.isGenerating {
                Button("ai.assistant.input.stop.help") { session.stop() }
            } else {
                Button(errorMessage == nil ? "activity.issueSummary.regenerate" : "action.retry", action: onRegenerate)
            }
        }
        .controlSize(.small)
    }

    /// 左下角展示上次总结时间（与「重新总结」同排、左对齐）：相对时间扫一眼可读，
    /// hover 给出精确时刻；生成中 / 停止状态优先占用该位置。
    private func generatedAtFooterLabel(_ generatedAt: Date) -> some View {
        let relative = generatedAt.formatted(.relative(presentation: .named).locale(locale))
        return Text(verbatim: String(
            format: String.l10n("activity.issueSummary.generatedAt"),
            locale: locale,
            relative
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(generatedAt.formatted(.dateTime.locale(locale).year().month().day().hour().minute()))
    }
}
