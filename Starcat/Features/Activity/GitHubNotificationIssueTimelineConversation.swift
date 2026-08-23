//
//  GitHubNotificationIssueTimelineConversation.swift
//  Starcat
//
//  Issue 事件流详情：开帖卡 + 评论 / 事件按时间交错。
//
//  只读已 hydrate 的标题 / 正文 / 标签。时间线走 Inbox：内存 → 文件 → 网络。
//  发评 / 关帖后 `timelineRevision` 变了会再读一次缓存。
//  翻译套开帖卡和评论卡，事件行保持原文。
//

import AppKit
import SwiftUI

struct GitHubNotificationIssueTimelineConversation: View {
    let payload: ActivityNotificationPayload
    let title: String
    let locale: Locale
    let inbox: GitHubNotificationInboxService
    /// Inbox 缓存刷新代数。发评 / 关帖后会 +1，用来重读内存时间线。
    let timelineRevision: Int
    /// 开帖卡和评论卡共用这份 VM；事件行不读。
    let translation: ReadmeTranslationViewModel?
    /// 必须和顶栏翻译按钮用同一份 Document，段 id 才能对上每条评论。
    let document: GitHubNotificationTranslation.Document
    /// 时间线评论后到时回传给详情页，避免工具栏仍按空缓存组文档。
    let onCommentsChange: ([GitHubNotificationComment]) -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings

    @State private var items: [GitHubNotificationIssueTimelineItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        // `.task` 必须挂在始终在树上的容器上。挂在空 `ForEach` 上时 SwiftUI
        // 不会启动任务，开帖卡出来、事件永远不拉——Issue #3 就是这样。
        VStack(alignment: .leading, spacing: 12) {
            openingTranslationCard
            if isLoading && items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } else if loadFailed && items.isEmpty {
                Button {
                    Task { await loadTimeline(force: true) }
                } label: {
                    Text("activity.notification.timeline.loadFailed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.top, 4)
            }
            ForEach(items) { item in
                switch item {
                case .comment(let comment):
                    timelineCommentCard(comment)
                case .event(let event):
                    GitHubNotificationIssueTimelineEventRow(
                        event: event,
                        repositoryFullName: payload.repositoryFullName,
                        locale: locale
                    )
                }
            }
        }
        .task(id: "\(payload.threadId)|\(timelineRevision)") {
            await loadTimeline(force: false)
        }
    }

    private var openingTranslationCard: some View {
        let isShowing: Bool = {
            if case .showingTranslation = translation?.displayMode { return true }
            return false
        }()
        let rendered = translation?.renderState.translations ?? []
        let blocks = GitHubNotificationTranslation.openingBlocks(in: document)
        return GitHubNotificationCommentCard(
            login: payload.authorLogin ?? "",
            createdAt: payload.authorCreatedAt,
            markdown: payload.excerpt ?? "",
            repositoryFullName: payload.repositoryFullName,
            isOpeningPost: true,
            locale: locale,
            reduceMotion: reduceMotion,
            blocks: blocks,
            translations: GitHubNotificationTranslation.cardTranslations(
                for: blocks,
                from: rendered
            ),
            isShowingTranslation: isShowing,
            translationMode: translation?.renderState.mode ?? settings.readmeTranslationMode,
            prefersAnimatedEntrance: translation?.renderState.prefersAnimatedEntrance ?? false,
            isJobTranslating: translation?.isTranslating ?? false,
            translationLanguage: settings.effectiveReadmeTranslationLanguage,
            issueTitle: title,
            labels: payload.labels
        )
        .equatable()
    }

    private func timelineCommentCard(_ comment: GitHubNotificationComment) -> some View {
        let isShowing: Bool = {
            if case .showingTranslation = translation?.displayMode { return true }
            return false
        }()
        let rendered = translation?.renderState.translations ?? []
        let blocks = GitHubNotificationTranslation.blocks(in: document, commentID: comment.id)
        return GitHubNotificationCommentCard(
            login: comment.login,
            createdAt: GitHubNotificationMapper.parseDate(comment.createdAt),
            markdown: comment.body,
            repositoryFullName: payload.repositoryFullName,
            isOpeningPost: false,
            locale: locale,
            reduceMotion: reduceMotion,
            blocks: blocks,
            translations: GitHubNotificationTranslation.cardTranslations(
                for: blocks,
                from: rendered
            ),
            isShowingTranslation: isShowing,
            translationMode: translation?.renderState.mode ?? settings.readmeTranslationMode,
            prefersAnimatedEntrance: translation?.renderState.prefersAnimatedEntrance ?? false,
            isJobTranslating: translation?.isTranslating ?? false,
            translationLanguage: settings.effectiveReadmeTranslationLanguage
        )
        .equatable()
    }

    /// 时间线里只抽出评论正文。开帖走 `payload.excerpt`，事件行不进 Document。
    private func preparedComments(
        from timeline: [GitHubNotificationIssueTimelineItem]
    ) -> [GitHubNotificationComment] {
        GitHubNotificationTranslation.preparedComments(
            timeline.compactMap { item in
                guard case .comment(let comment) = item else { return nil }
                return comment
            }
        )
    }

    private func loadTimeline(force: Bool) async {
        if let cached = inbox.cachedIssueTimeline(threadId: payload.threadId), !force {
            items = cached
            loadFailed = false
            isLoading = false
            onCommentsChange(preparedComments(from: cached))
            return
        }
        isLoading = items.isEmpty
        loadFailed = false
        do {
            let loaded = try await inbox.loadIssueTimeline(
                threadId: payload.threadId,
                force: force
            )
            items = loaded
            onCommentsChange(preparedComments(from: loaded))
            loadFailed = false
        } catch {
            if items.isEmpty {
                loadFailed = true
            }
            AppLog.network.info(
                "Issue timeline skipped id=\(payload.threadId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        isLoading = false
    }
}

/// 一条事件一行。commit 只显示短 SHA，可点到 GitHub commit。
private struct GitHubNotificationIssueTimelineEventRow: View {
    let event: GitHubNotificationIssueTimelineEvent
    let repositoryFullName: String
    let locale: Locale

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GitHubNotificationActorAvatar(login: event.actorLogin, size: 16)
            eventSentence
                .font(.caption)
            Spacer(minLength: 8)
            if let date = GitHubNotificationMapper.parseDate(event.createdAt) {
                Text(verbatim: GitHubNotificationMapper.commentTimeLabel(date: date, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var eventSentence: some View {
        let actor = actorName
        switch event.kind {
        case .labeled, .unlabeled:
            let isAdd = event.kind == .labeled
            let prefixKey = isAdd
                ? "activity.notification.timeline.labeled.prefix"
                : "activity.notification.timeline.unlabeled.prefix"
            let suffixKey = isAdd
                ? "activity.notification.timeline.labeled.suffix"
                : "activity.notification.timeline.unlabeled.suffix"
            HStack(spacing: 4) {
                Text(verbatim: String(format: String.l10n(prefixKey), actor))
                    .foregroundStyle(.secondary)
                if let label = event.label {
                    GitHubNotificationIssueTimelineLabelChip(label: label)
                }
                let suffix = String.l10n(suffixKey)
                if !suffix.isEmpty {
                    Text(verbatim: suffix)
                        .foregroundStyle(.secondary)
                }
            }
        case .closed:
            Text(verbatim: String(format: String.l10n("activity.notification.timeline.closed"), actor))
                .foregroundStyle(.secondary)
        case .reopened:
            Text(verbatim: String(format: String.l10n("activity.notification.timeline.reopened"), actor))
                .foregroundStyle(.secondary)
        case .renamed:
            Text(verbatim: String(
                format: String.l10n("activity.notification.timeline.renamed"),
                actor,
                event.renameFrom ?? "",
                event.renameTo ?? ""
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .referenced:
            HStack(spacing: 4) {
                Text(verbatim: String(
                    format: String.l10n("activity.notification.timeline.referenced.prefix"),
                    actor
                ))
                .foregroundStyle(.secondary)
                if let sha = event.commitSHA {
                    commitLink(sha)
                }
                let suffix = String.l10n("activity.notification.timeline.referenced.suffix")
                if !suffix.isEmpty {
                    Text(verbatim: suffix)
                        .foregroundStyle(.secondary)
                }
            }
        case .crossReferenced:
            HStack(spacing: 4) {
                Text(verbatim: String(
                    format: String.l10n("activity.notification.timeline.crossReferenced.prefix"),
                    actor
                ))
                .foregroundStyle(.secondary)
                crossRefLink
                let suffix = String.l10n("activity.notification.timeline.crossReferenced.suffix")
                if !suffix.isEmpty {
                    Text(verbatim: suffix)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actorName: String {
        let trimmed = event.actorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return GitHubNotificationMapper.copy(locale, zh: "有人", en: "Someone")
        }
        return trimmed
    }

    private func commitLink(_ sha: String) -> some View {
        let short = GitHubNotificationIssueTimelineParser.shortSHA(sha)
        return Button {
            if let url = GitHubNotificationIssueTimelineParser.commitHTMLURL(
                repositoryFullName: repositoryFullName,
                sha: sha
            ) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(verbatim: short)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .clickablePointer()
    }

    @ViewBuilder
    private var crossRefLink: some View {
        let number = event.crossRefNumber ?? 0
        let title = GitHubNotificationIssueTimelineParser.crossRefTitle(
            number: number,
            isPullRequest: event.isCrossRefPullRequest
        )
        if let url = event.crossRefURL.flatMap(URL.init(string:)) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .clickablePointer()
        } else {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

/// 验证期副本：不碰详情里已上线的 `GitHubNotificationLabelChip`。
private struct GitHubNotificationIssueTimelineLabelChip: View {
    let label: GitHubNotificationIssueLabel

    var body: some View {
        Text(verbatim: label.name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(contrastingForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (Color(hex: label.colorHex) ?? Color(hex: "6e7781") ?? .secondary.opacity(0.2)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }

    /// YIQ：浅底黑字、深底白字。标签色是仓库自定义的，不能走 `.primary`。
    private var contrastingForeground: Color {
        var hex = label.colorHex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
            return .primary
        }
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let yiq = (r * 299 + g * 587 + b * 114) / 1000
        return yiq >= 148 ? Color.black : Color.white
    }
}
