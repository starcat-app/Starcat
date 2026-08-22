//
//  GitHubNotificationIssueTimelineConversation.swift
//  Starcat
//
//  Issue 事件流详情：开帖卡 + 评论 / 事件按时间交错。
//
//  只读已 hydrate 的标题 / 正文 / 标签。时间线走 Inbox：内存 → 文件 → 网络。
//  发评 / 关帖后 `timelineRevision` 变了会再读一次缓存。
//  翻译只套评论卡，开帖和事件行保持原文。
//

import AppKit
import MarkdownUI
import SwiftUI

struct GitHubNotificationIssueTimelineConversation: View {
    let payload: ActivityNotificationPayload
    let title: String
    let locale: Locale
    let inbox: GitHubNotificationInboxService
    /// Inbox 缓存刷新代数。发评 / 关帖后会 +1，用来重读内存时间线。
    let timelineRevision: Int
    /// 只给评论卡做对照。事件行不读这个。
    let translation: ReadmeTranslationViewModel?

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings

    @State private var items: [GitHubNotificationIssueTimelineItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        // `.task` 必须挂在始终在树上的容器上。挂在空 `ForEach` 上时 SwiftUI
        // 不会启动任务，开帖卡出来、事件永远不拉——Issue #3 就是这样。
        VStack(alignment: .leading, spacing: 12) {
            openingCard
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

    private var openingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                GitHubNotificationActorAvatar(login: payload.authorLogin ?? "", size: 26)
                Text(verbatim: actorName(payload.authorLogin))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: GitHubNotificationMapper.commentCardAction(isOpeningPost: true, locale: locale))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let createdAt = payload.authorCreatedAt {
                    Text(verbatim: GitHubNotificationMapper.commentTimeLabel(date: createdAt, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08))

            Divider()

            if !title.isEmpty {
                Text(verbatim: title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            if !payload.labels.isEmpty {
                GitHubNotificationIssueTimelineLabelFlow(spacing: 6) {
                    ForEach(Array(payload.labels.enumerated()), id: \.offset) { _, label in
                        GitHubNotificationIssueTimelineLabelChip(label: label)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, title.isEmpty ? 12 : 8)
            }

            if let excerpt = payload.excerpt, !excerpt.isEmpty {
                GitHubNotificationIssueTimelineMarkdown(
                    content: excerpt,
                    repositoryFullName: payload.repositoryFullName
                )
                .padding(12)
            } else {
                Text("activity.notification.detail.noDescription")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func timelineCommentCard(_ comment: GitHubNotificationComment) -> some View {
        let document = commentTranslationDocument
        let isShowing: Bool = {
            if case .showingTranslation = translation?.displayMode { return true }
            return false
        }()
        let rendered = translation?.renderState.translations ?? []
        let translationsByID = Dictionary(
            rendered.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let blocks = document.blocks.filter { block in
            if case .comment(let id) = block.kind { return id == comment.id }
            return false
        }
        return GitHubNotificationCommentCard(
            login: comment.login,
            createdAt: GitHubNotificationMapper.parseDate(comment.createdAt),
            markdown: comment.body,
            repositoryFullName: payload.repositoryFullName,
            isOpeningPost: false,
            locale: locale,
            reduceMotion: reduceMotion,
            blocks: blocks,
            translations: blocks.compactMap { block in
                block.segmentId.flatMap { translationsByID[$0] }
            },
            isShowingTranslation: isShowing,
            translationMode: translation?.renderState.mode ?? settings.readmeTranslationMode,
            prefersAnimatedEntrance: translation?.renderState.prefersAnimatedEntrance ?? false,
            isJobTranslating: translation?.isTranslating ?? false,
            translationLanguage: settings.effectiveReadmeTranslationLanguage
        )
        .equatable()
    }

    /// 只切评论正文。开帖和事件不进翻译文档。
    private var commentTranslationDocument: GitHubNotificationTranslation.Document {
        let comments: [GitHubNotificationComment] = items.compactMap { item in
            guard case .comment(let comment) = item else { return nil }
            return GitHubNotificationComment(
                id: comment.id,
                login: comment.login,
                body: GitHubNotificationMapper.prepareMarkdown(comment.body),
                htmlURL: comment.htmlURL,
                createdAt: comment.createdAt
            )
        }
        return GitHubNotificationTranslation.makeDocument(opening: nil, comments: comments)
    }

    private func actorName(_ login: String?) -> String {
        let trimmed = login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return GitHubNotificationMapper.copy(locale, zh: "有人", en: "Someone")
        }
        return trimmed
    }

    private func loadTimeline(force: Bool) async {
        if let cached = inbox.cachedIssueTimeline(threadId: payload.threadId), !force {
            items = cached
            loadFailed = false
            isLoading = false
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

private struct GitHubNotificationIssueTimelineMarkdown: View {
    let content: String
    let repositoryFullName: String

    var body: some View {
        Markdown(
            GitHubNotificationMapper.autolinkIssueReferences(
                GitHubNotificationMapper.prepareMarkdown(content),
                repositoryFullName: repositoryFullName
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
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

/// 验证期副本：多个标签必须能换行。
private struct GitHubNotificationIssueTimelineLabelFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
