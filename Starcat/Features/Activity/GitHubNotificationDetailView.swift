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
                GitHubNotificationCommentComposer(
                    payload: payload,
                    issueTitle: item.title,
                    repo: item.repo
                )
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
                    GitHubNotificationSubjectHeading(
                        title: heading(item),
                        url: item.htmlURL
                    )
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
                repositoryFullName: payload.repositoryFullName,
                isOpeningPost: true
            )
        }

        ForEach(payload.comments) { comment in
            GitHubNotificationCommentCard(
                login: comment.login,
                createdAt: GitHubNotificationMapper.parseDate(comment.createdAt),
                markdown: comment.body,
                repositoryFullName: payload.repositoryFullName,
                isOpeningPost: false
            )
        }
    }

    private func actionButtons(_ item: ActivityItem) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if let repo = item.repo {
                Button {
                    NotificationCenter.default.post(
                        name: .starcatRevealRepoInManage,
                        object: nil,
                        userInfo: ["repoId": repo.id]
                    )
                } label: {
                    // App Icon 带玻璃外框，缩小时看不清；用 CompactMark 放大主体。
                    StarcatCompactMark(size: 16)
                        .squareLogoActionChrome()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("activity.notification.detail.openInStarcat")
                .accessibilityLabel(Text("activity.notification.detail.openInStarcat"))
            }

            if let url = item.htmlURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    // Devicons 经典 mark；template 以适配明暗主题。与知识库引用行同一套方钮。
                    Image("github")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                        .squareLogoActionChrome()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("activity.notification.detail.openOnGitHub")
                .accessibilityLabel(Text("activity.notification.detail.openOnGitHub"))
            }
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

/// 标题下的 `Issue #20`：有 GitHub URL 时可点，hover 用 accent 提示是链接。
private struct GitHubNotificationSubjectHeading: View {
    let title: String
    let url: URL?
    @State private var isHovered = false

    var body: some View {
        if let url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                    .underline(isHovered, color: Color.accentColor)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
            .help(url.absoluteString)
        } else {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// GitHub 风格评论卡片：头像 + 「谁在何时发布/评论」+ Markdown 正文。
private struct GitHubNotificationCommentCard: View {
    let login: String
    let createdAt: Date?
    let markdown: String
    let repositoryFullName: String
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
                GitHubNotificationMarkdown(content: markdown, repositoryFullName: repositoryFullName)
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
    let payload: ActivityNotificationPayload
    let issueTitle: String
    let repo: Repo?

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var isPreview = false
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var didGenerate = false
    @State private var previousDraft: String?
    @State private var generateTask: Task<Void, Never>?
    @State private var successResetTask: Task<Void, Never>?
    @State private var paywallContext: ProPaywallContext?
    @State private var isAIHovered = false
    @State private var isOwnProject = false
    @State private var isClosed = false
    @State private var isClosing = false

    private var threadId: String { payload.threadId }
    private var repositoryFullName: String { payload.repositoryFullName }
    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

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
                            GitHubNotificationMarkdown(
                                content: draft,
                                repositoryFullName: repositoryFullName
                            )
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
                GitHubNotificationCommentTextEditor(
                    text: $draft,
                    placeholder: GitHubNotificationMapper.copy(
                        locale,
                        zh: "用 Markdown 写下评论…",
                        en: "Write a comment with Markdown…"
                    ),
                    isEditable: !isPosting && !isGenerating
                )
                .frame(minHeight: 88, maxHeight: 160)
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

            HStack(spacing: 8) {
                Spacer()
                aiCommentButton
                if canShowClose {
                    Button {
                        Task { await closeIssue() }
                    } label: {
                        if isClosing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 72)
                        } else {
                            Text(verbatim: closeButtonTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusEffectDisabled()
                    .disabled(isPosting || isGenerating || isClosing)
                    .help(closeButtonTitle)
                }
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
                .disabled(trimmed.isEmpty || isPosting || isGenerating || isClosing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background)
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .task {
            await refreshCloseEligibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
            Task { await refreshCloseEligibility() }
        }
        .onDisappear {
            generateTask?.cancel()
            successResetTask?.cancel()
        }
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 关闭和评论是一套动作：放在评论按钮左边，和 GitHub 网页同一位置。
    /// 只给「我的项目」或当前用户当 owner 的公开仓；演示数据绝不 PATCH。
    private var canShowClose: Bool {
        isOwnProject
            && !isClosed
            && !GitHubNotificationMapper.isDemoThread(threadId)
            && GitHubNotificationMapper.canReply(
                subjectType: payload.subjectType,
                number: payload.subjectNumber
            )
    }

    private var closeButtonTitle: String {
        let isPR = payload.subjectType == "PullRequest"
        if !trimmed.isEmpty {
            return GitHubNotificationMapper.copy(locale, zh: "评论并关闭", en: "Close with comment")
        }
        if isPR {
            return GitHubNotificationMapper.copy(locale, zh: "关闭 Pull Request", en: "Close pull request")
        }
        return GitHubNotificationMapper.copy(locale, zh: "关闭问题", en: "Close issue")
    }

    private var hasHydratedThread: Bool {
        if let excerpt = payload.excerpt, !excerpt.isEmpty { return true }
        return !payload.comments.isEmpty
    }

    @ViewBuilder
    private var aiCommentButton: some View {
        Group {
            if isGenerating {
                Button {
                    cancelGeneration()
                } label: {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(GitHubNotificationMapper.copy(locale, zh: "停止生成", en: "Stop generating"))
            } else if previousDraft != nil {
                Menu {
                    Button {
                        startGeneration()
                    } label: {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "用 AI 撰写", en: "Write with AI"))
                    }
                    Button {
                        restorePreviousDraft()
                    } label: {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "还原上次草稿", en: "Restore last draft"))
                    }
                } label: {
                    aiIcon
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 22)
                .focusEffectDisabled()
                .disabled(!hasHydratedThread)
                .help(aiHelp)
            } else {
                Button {
                    startGeneration()
                } label: {
                    aiIcon
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!hasHydratedThread)
                .help(aiHelp)
            }
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isAIHovered = hovering
            }
        }
    }

    private var aiIcon: some View {
        Image(systemName: didGenerate ? "checkmark.circle.fill" : "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(didGenerate ? Color.green : (isAIHovered ? Color.accentColor : Color.secondary))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(Color.secondary.opacity(isAIHovered || didGenerate ? 0.16 : 0.10))
            )
            .contentTransition(.symbolEffect(.replace))
    }

    private var aiHelp: String {
        if !hasHydratedThread {
            return GitHubNotificationMapper.copy(
                locale,
                zh: "等评论加载完成后再用 AI 撰写",
                en: "Wait for comments to load, then write with AI"
            )
        }
        return GitHubNotificationMapper.copy(
            locale,
            zh: trimmed.isEmpty ? "用 AI 撰写评论" : "用 AI 润色并补全评论",
            en: trimmed.isEmpty ? "Write a comment with AI" : "Improve and complete this comment with AI"
        )
    }

    private func startGeneration() {
        guard hasHydratedThread, !isGenerating else { return }
        do {
            try dependencies.repoAIInsightService.ensureGitHubCommentReady()
        } catch let error as EntitlementGateError {
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isPreview = false
        errorMessage = nil
        previousDraft = draft
        isGenerating = true
        didGenerate = false
        successResetTask?.cancel()
        generateTask?.cancel()
        generateTask = Task { await generateComment() }
    }

    private func cancelGeneration() {
        generateTask?.cancel()
        generateTask = nil
        isGenerating = false
        if let previousDraft {
            draft = previousDraft
        }
    }

    private func restorePreviousDraft() {
        guard let previousDraft else { return }
        draft = previousDraft
        self.previousDraft = nil
        didGenerate = false
    }

    private func generateComment() async {
        let snapshot = previousDraft ?? draft
        let login = authSession.state.user?.login ?? "user"
        var summary: String?
        if let repo,
           let insight = try? await dependencies.repoAIInsightService.cachedInsightFast(for: repo) {
            summary = insight.summaryMarkdown ?? insight.summary
        }
        let pack = GitHubNotificationCommentAI.pack(
            title: issueTitle,
            payload: payload,
            repo: repo,
            summaryMarkdown: summary,
            currentUserLogin: login,
            draft: snapshot
        )
        do {
            let result = try await dependencies.repoAIInsightService.generateGitHubCommentDraft(pack: pack) { partial in
                guard !Task.isCancelled else { return }
                draft = partial
            }
            guard !Task.isCancelled else {
                isGenerating = false
                return
            }
            draft = result
            isGenerating = false
            didGenerate = true
            scheduleSuccessReset()
        } catch is CancellationError {
            isGenerating = false
            if let previousDraft {
                draft = previousDraft
            }
        } catch {
            isGenerating = false
            if let previousDraft {
                draft = previousDraft
            }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSuccessReset() {
        successResetTask?.cancel()
        successResetTask = Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 1_500))
            guard !Task.isCancelled else { return }
            didGenerate = false
        }
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

    private func closeIssue() async {
        isClosing = true
        errorMessage = nil
        defer { isClosing = false }
        do {
            if !trimmed.isEmpty {
                try await inbox.postComment(threadId: threadId, body: trimmed)
                draft = ""
                isPreview = false
            }
            try await inbox.closeIssue(threadId: threadId)
            isClosed = true
        } catch {
            errorMessage = submitErrorMessage(error)
        }
    }

    private func refreshCloseEligibility() async {
        isClosed = inbox.cachedIssueState(threadId: threadId) == "closed"
        isOwnProject = await resolveOwnProject()
    }

    /// 「我的项目」关系优先；否则 owner 等于当前登录名（个人仓还没进项目列表也能关）。
    private func resolveOwnProject() async -> Bool {
        if GitHubNotificationMapper.isDemoThread(threadId) { return false }
        if let repoId = payload.repositoryId ?? repo?.id,
           (try? await dependencies.userProjectRepository.fetchProject(repoID: repoId)) != nil {
            return true
        }
        guard let login = authSession.state.user?.login,
              let owner = payload.repositoryFullName.split(separator: "/").first
        else { return false }
        return String(owner).caseInsensitiveCompare(login) == .orderedSame
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
        if error as? GitHubNotificationInboxError == .cannotClose {
            return GitHubNotificationMapper.copy(
                locale,
                zh: "无法关闭（可能没有写权限或仓库是私有的）。请到 GitHub 打开。",
                en: "Couldn’t close this (no write access, or private repo?). Open it on GitHub."
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

/// 评论输入必须走 NSTextView：SwiftUI `TextEditor` + overlay `Text` 的 placeholder
/// 和 insertion point 不在同一坐标系。笔记页已经用 padding 猜过几次（`RepoNotesSection`
/// / `NoteEditorSheet` 的 5pt inset 公式），macOS 版本一变就会再错位。
/// 这里与 `AICommandTextEditor` / `AIChatTextView` 相同：placeholder 画在
/// `NSTextView.draw` 里，原点就是 `textContainerInset`，和光标同一条基线。
private struct GitHubNotificationCommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = GitHubNotificationCommentScrollView()
        let textView = GitHubNotificationCommentNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = GitHubNotificationCommentNSTextView.contentInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? GitHubNotificationCommentNSTextView else { return }
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitHubNotificationCommentTextEditor

        init(parent: GitHubNotificationCommentTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? GitHubNotificationCommentNSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

private final class GitHubNotificationCommentScrollView: NSScrollView {
    /// 让 NSTextView 至少铺满评论框，空白处点击也能聚焦，而不是只有第一行可点。
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        let minHeight = contentSize.height
        if abs(textView.frame.width - width) >= 0.5 || textView.minSize.height < minHeight {
            textView.minSize = NSSize(width: 0, height: minHeight)
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, minHeight)))
        }
    }
}

private final class GitHubNotificationCommentNSTextView: NSTextView {
    static let contentInset = NSSize(width: 8, height: 8)
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}

/// 通知正文：GitHub 评论里的 HTML `<img>` 先收成 Markdown 图片，再用 Kingfisher 拉远程图。
/// `#20` 在 `prepareMarkdown` 之后再 autolink，点了走系统浏览器。
private struct GitHubNotificationMarkdown: View {
    let content: String
    let repositoryFullName: String

    var body: some View {
        Markdown(
            GitHubNotificationMapper.autolinkIssueReferences(
                GitHubNotificationMapper.prepareMarkdown(content),
                repositoryFullName: repositoryFullName
            )
        )
        .markdownImageProvider(GitHubNotificationImageProvider())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
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
