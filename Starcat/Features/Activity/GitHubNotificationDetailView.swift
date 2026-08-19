//
//  GitHubNotificationDetailView.swift
//  Starcat
//
//  通知页右栏：按 GitHub Issue 会话排版（标题 + 评论卡片 + 底部评论框），
//  不走 ActivityDetailView 的仓库 hero / 语言徽章。
//

import AppKit
import Kingfisher
import MarkdownUI
import SwiftUI

struct GitHubNotificationDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    @Binding var selectedItem: ActivityItem?

    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

    var body: some View {
        Group {
            if let item = selectedItem, item.kind == .notification {
                populatedDetail(item)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "选择一条通知", en: "Select a notification"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func populatedDetail(_ item: ActivityItem) -> some View {
        VStack(spacing: 0) {
            header(item)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let payload = item.notification {
                        repoRow(payload)
                        conversation(payload)
                    }
                    actionButtons(item)
                }
                .padding(18)
            }
            if let payload = item.notification,
               GitHubNotificationMapper.canReply(
                subjectType: payload.subjectType,
                number: payload.subjectNumber
               ) {
                Divider()
                GitHubNotificationCommentComposer(threadId: payload.threadId)
            }
        }
    }

    private func header(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: item.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let chip = item.notification?.chip {
                        GitHubNotificationReasonChip(chip: chip)
                    }
                    Text(verbatim: heading(item))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    selectAdjacent(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(GitHubNotificationMapper.copy(locale, zh: "上一条", en: "Previous notification"))

                Button {
                    selectAdjacent(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(GitHubNotificationMapper.copy(locale, zh: "下一条", en: "Next notification"))

                SheetCloseButton {
                    if let threadId = item.notification?.threadId {
                        Task { await inbox.cancelDwell(id: threadId) }
                    }
                    selectedItem = nil
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func repoRow(_ payload: ActivityNotificationPayload) -> some View {
        Button {
            if let url = URL(string: "https://github.com/\(payload.repositoryFullName)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 10) {
                RemoteAvatar(
                    urlString: GitHubNotificationMapper.repositoryAvatarURL(
                        fromFullName: payload.repositoryFullName
                    ),
                    size: 28,
                    fallbackSymbol: "shippingbox.fill",
                    showBorder: false
                )
                Text(verbatim: payload.repositoryFullName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func conversation(_ payload: ActivityNotificationPayload) -> some View {
        if let excerpt = payload.excerpt, !excerpt.isEmpty {
            GitHubNotificationCommentCard(
                login: payload.authorLogin ?? GitHubNotificationMapper.copy(locale, zh: "有人", en: "Someone"),
                createdAt: payload.authorCreatedAt,
                markdown: excerpt,
                isOpeningPost: true
            )
        }

        ForEach(payload.comments) { comment in
            GitHubNotificationCommentCard(
                login: comment.login,
                createdAt: GitHubNotificationMapper.parseDate(comment.createdAt),
                markdown: comment.body,
                isOpeningPost: false
            )
        }
    }

    private func actionButtons(_ item: ActivityItem) -> some View {
        HStack(spacing: 8) {
            if let url = item.htmlURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("activity.notification.detail.openOnGitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .focusEffectDisabled()
            }

            if let repo = item.repo {
                Button {
                    NotificationCenter.default.post(
                        name: .starcatRevealRepoInManage,
                        object: nil,
                        userInfo: ["repoId": repo.id]
                    )
                } label: {
                    Label("activity.notification.detail.openInStarcat", systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .focusEffectDisabled()
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func heading(_ item: ActivityItem) -> String {
        guard let payload = item.notification else { return item.title }
        return GitHubNotificationMapper.subjectHeading(type: payload.subjectType, number: payload.subjectNumber, locale: locale)
    }

    private func selectAdjacent(_ delta: Int) {
        Task {
            let records = await inbox.fetchCached()
            let visible = records.filter {
                GitHubNotificationMapper.matchesSegment($0, segment: inbox.listSegment)
            }
            guard let current = selectedItem?.notification?.threadId,
                  let index = visible.firstIndex(where: { $0.id == current })
            else { return }
            let next = index + delta
            guard visible.indices.contains(next) else { return }
            inbox.pendingOpenThreadId = visible[next].id
            NotificationCenter.default.post(name: .starcatOpenGitHubNotification, object: nil)
        }
    }
}

/// GitHub 风格评论卡片：头像 + 「谁在何时发布/评论」+ Markdown 正文。
private struct GitHubNotificationCommentCard: View {
    let login: String
    let createdAt: Date?
    let markdown: String
    let isOpeningPost: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RemoteAvatar(
                    urlString: "https://github.com/\(login).png?size=80",
                    size: 24,
                    fallbackSymbol: "person.crop.circle.fill",
                    showBorder: false
                )
                Text(verbatim: GitHubNotificationMapper.commentCardHeader(
                    login: login,
                    isOpeningPost: isOpeningPost,
                    locale: locale
                ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                Spacer(minLength: 8)
                if let createdAt {
                    Text(verbatim: GitHubNotificationMapper.commentTimeLabel(date: createdAt, locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if !markdown.isEmpty {
                GitHubNotificationMarkdown(content: markdown)
                    .padding(12)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
        )
    }
}

/// 底部评论框：撰写 / 预览 + 发到 GitHub。Catalog 本轮不能加 key，文案走 mapper.copy。
private struct GitHubNotificationCommentComposer: View {
    let threadId: String

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    @State private var draft = ""
    @State private var isPreview = false
    @State private var isPosting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RemoteAvatar(
                    urlString: authSession.state.user?.avatarUrl,
                    size: 24,
                    fallbackSymbol: "person.crop.circle.fill",
                    showBorder: false
                )
                Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "留下评论", en: "Leave a comment"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                composerTab(
                    GitHubNotificationMapper.copy(locale, zh: "撰写", en: "Write"),
                    selected: !isPreview
                ) {
                    isPreview = false
                }
                composerTab(
                    GitHubNotificationMapper.copy(locale, zh: "预览", en: "Preview"),
                    selected: isPreview
                ) {
                    isPreview = true
                }
            }

            if isPreview {
                Group {
                    if trimmed.isEmpty {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "没什么可预览的", en: "Nothing to preview"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    } else {
                        ScrollView {
                            GitHubNotificationMarkdown(content: draft)
                        }
                        .frame(minHeight: 88, maxHeight: 160)
                    }
                }
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                )
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88, maxHeight: 160)
                    if draft.isEmpty {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "用 Markdown 写下评论…", en: "Write a comment with Markdown…"))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                )
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if isPosting {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 52)
                    } else {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "评论", en: "Comment"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .focusEffectDisabled()
                .disabled(trimmed.isEmpty || isPosting)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background)
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func composerTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? Color.secondary.opacity(0.16) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func submit() async {
        let body = trimmed
        guard !body.isEmpty else { return }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            try await dependencies.githubNotificationInboxService.postComment(
                threadId: threadId,
                body: body
            )
            draft = ""
            isPreview = false
        } catch {
            errorMessage = submitErrorMessage(error)
        }
    }

    /// 私有仓没 `repo` scope 时常 404；不要假装发出去了。
    private func submitErrorMessage(_ error: Error) -> String {
        if error as? GitHubNotificationInboxError == .cannotComment {
            return GitHubNotificationMapper.copy(
                locale,
                zh: "这类通知不能在 Starcat 里回复。",
                en: "This notification can’t be replied to in Starcat."
            )
        }
        if let network = error as? NetworkError {
            switch network {
            case .notFound:
                return GitHubNotificationMapper.copy(
                    locale,
                    zh: "无法发表评论（可能是私有仓库）。请到 GitHub 打开。",
                    en: "Couldn’t post the comment (private repo?). Open it on GitHub."
                )
            case .clientError(let code, _) where code == 403 || code == 404:
                return GitHubNotificationMapper.copy(
                    locale,
                    zh: "无法发表评论（可能是私有仓库）。请到 GitHub 打开。",
                    en: "Couldn’t post the comment (private repo?). Open it on GitHub."
                )
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// 通知正文：GitHub 评论里的 HTML `<img>` 先收成 Markdown 图片，再用 Kingfisher 拉远程图。
private struct GitHubNotificationMarkdown: View {
    let content: String

    var body: some View {
        Markdown(GitHubNotificationMapper.prepareMarkdown(content))
            .markdownImageProvider(GitHubNotificationImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// MarkdownUI 默认 URLSession 对 GitHub user-attachments 经常拿不到图；走 Kingfisher 复用头像缓存栈。
private struct GitHubNotificationImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Group {
            if let url {
                KFImage(url)
                    .requestModifier(AnyModifier { request in
                        GitHubNotificationImageRequestModifier.modify(request)
                    })
                    .placeholder {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    .fade(duration: 0.15)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// user-attachments 在私有 Issue 里要带 token；测试 host 禁止碰 Keychain。
private enum GitHubNotificationImageRequestModifier {
    static func modify(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        guard !TestEnvironment.isRunning else { return request }
        guard let host = request.url?.host?.lowercased(),
              host.contains("github.com") || host.contains("githubusercontent.com"),
              let token = try? KeychainManager.shared.loadGithubToken(),
              !token.isEmpty
        else { return request }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
