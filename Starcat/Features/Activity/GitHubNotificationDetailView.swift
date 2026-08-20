//
//  GitHubNotificationDetailView.swift
//  Starcat
//
//  通知页右栏：按 GitHub Issue 会话排版（评论卡片 + 底部评论框）。
//  顶区与中栏同构：`.navigationTitle` / `.navigationSubtitle` + 与分段条同高的工具行，
//  避免中栏 / 右栏分割线错层。
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
    @State private var isComposerExpanded = false
    @State private var isMarkingDone = false
    @State private var doneError: String?

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
            headerToolbar(item)
            if let doneError, !doneError.isEmpty {
                Text(verbatim: doneError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                    .padding(.bottom, 6)
            }
            Divider()
            if !isComposerExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let payload = item.notification {
                            repoRow(payload)
                            conversation(payload)
                        }
                    }
                    .padding(18)
                }
            }
            if let payload = item.notification,
               GitHubNotificationMapper.canReply(
                subjectType: payload.subjectType,
                number: payload.subjectNumber
               ) {
                if !isComposerExpanded {
                    Divider()
                }
                GitHubNotificationCommentComposer(
                    payload: payload,
                    issueTitle: item.title,
                    repo: item.repo,
                    isExpanded: $isComposerExpanded
                )
                .frame(maxHeight: isComposerExpanded ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 标题进系统导航栏，和中栏「活动 > 通知 / 46 条通知」同一层；下面只留一行工具条。
        .navigationTitle(item.title)
        .navigationSubtitle(navigationSubtitle(item))
        .onChange(of: item.notification?.threadId) { _, _ in
            isComposerExpanded = false
            doneError = nil
        }
    }

    /// 与中栏分段条同高：chip + 可点 `Issue #20` 在左，入口 / 上下条在右。
    /// 关掉详情靠中栏改选或清空选择，不再单独放关闭钮。
    private func headerToolbar(_ item: ActivityItem) -> some View {
        HStack(spacing: 8) {
            if let chip = item.notification?.chip {
                GitHubNotificationReasonChip(chip: chip)
            }
            GitHubNotificationSubjectHeading(
                title: heading(item),
                url: item.htmlURL
            )
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                detailLinkButtons(item)
                doneButton(item)
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
            }
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    /// 只 Done 当前这条，等同 GitHub Inbox 的 Done，不会关闭 Issue。
    private func doneButton(_ item: ActivityItem) -> some View {
        Button {
            Task { await markCurrentDone(item) }
        } label: {
            if isMarkingDone {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "完成", en: "Done"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isMarkingDone || item.notification?.threadId == nil)
        .help(GitHubNotificationMapper.copy(
            locale,
            zh: "从 GitHub 收件箱移走这条，不会关闭 Issue",
            en: "Remove this from the GitHub inbox. Does not close the issue."
        ))
    }

    private func navigationSubtitle(_ item: ActivityItem) -> String {
        item.notification?.repositoryFullName ?? heading(item)
    }

    private func repoRow(_ payload: ActivityNotificationPayload) -> some View {
        Button {
            if let url = URL(string: "https://github.com/\(payload.repositoryFullName)") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                RemoteAvatar(
                    urlString: GitHubNotificationMapper.repositoryAvatarURL(
                        fromFullName: payload.repositoryFullName
                    ),
                    size: 18,
                    fallbackSymbol: "shippingbox.fill",
                    showBorder: false
                )
                Text(verbatim: payload.repositoryFullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
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
                login: payload.authorLogin ?? "",
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

    /// GitHub / Starcat 入口放工具行：会话滚走或评论框展开时仍能点。
    @ViewBuilder
    private func detailLinkButtons(_ item: ActivityItem) -> some View {
        if let repo = item.repo {
            Button {
                NotificationCenter.default.post(
                    name: .starcatRevealRepoInManage,
                    object: nil,
                    userInfo: ["repoId": repo.id]
                )
            } label: {
                StarcatCompactMark(size: 14)
                    .squareLogoActionChrome(side: 22)
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
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.primary)
                    .squareLogoActionChrome(side: 22)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("activity.notification.detail.openOnGitHub")
            .accessibilityLabel(Text("activity.notification.detail.openOnGitHub"))
        }
    }

    private func heading(_ item: ActivityItem) -> String {
        guard let payload = item.notification else { return item.title }
        return GitHubNotificationMapper.subjectHeading(type: payload.subjectType, number: payload.subjectNumber, locale: locale)
    }

    private func selectAdjacent(_ delta: Int) {
        Task {
            guard let current = selectedItem?.notification?.threadId,
                  let next = await adjacentThreadId(after: current, delta: delta)
            else { return }
            inbox.pendingOpenThreadId = next
            NotificationCenter.default.post(name: .starcatOpenGitHubNotification, object: nil)
        }
    }

    /// 完成当前条后优先打开下一条；已经是最后一条则打开上一条。
    private func markCurrentDone(_ item: ActivityItem) async {
        guard let threadId = item.notification?.threadId, !threadId.isEmpty else { return }
        isMarkingDone = true
        doneError = nil
        defer { isMarkingDone = false }

        let nextId: String?
        if let following = await adjacentThreadId(after: threadId, delta: 1) {
            nextId = following
        } else {
            nextId = await adjacentThreadId(after: threadId, delta: -1)
        }
        inbox.pendingOpenThreadId = nextId
        do {
            try await inbox.markThreadDone(id: threadId)
            if nextId == nil {
                selectedItem = nil
            }
        } catch {
            if inbox.pendingOpenThreadId == nextId {
                inbox.pendingOpenThreadId = nil
            }
            doneError = doneErrorMessage(error)
        }
    }

    private func adjacentThreadId(after currentId: String, delta: Int) async -> String? {
        let records = await inbox.fetchCached()
        let visible = records.filter {
            GitHubNotificationMapper.matchesSegment($0, segment: inbox.listSegment)
        }
        guard let index = visible.firstIndex(where: { $0.id == currentId }) else { return nil }
        let next = index + delta
        guard visible.indices.contains(next) else { return nil }
        return visible[next].id
    }

    private func doneErrorMessage(_ error: Error) -> String {
        if error as? GitHubNotificationInboxError == .cannotDone {
            return GitHubNotificationMapper.copy(
                locale,
                zh: "没法把这条标为完成。",
                en: "Couldn’t mark this notification as done."
            )
        }
        if let network = error as? NetworkError {
            switch network {
            case .unauthorized:
                return GitHubNotificationMapper.copy(
                    locale,
                    zh: "GitHub 授权失效，请重新登录后再试。",
                    en: "GitHub authorization expired. Sign in again and retry."
                )
            case .clientError(let code, _) where code == 401:
                return GitHubNotificationMapper.copy(
                    locale,
                    zh: "GitHub 授权失效，请重新登录后再试。",
                    en: "GitHub authorization expired. Sign in again and retry."
                )
            case .clientError(let code, _) where code == 403:
                return GitHubNotificationMapper.copy(
                    locale,
                    zh: "没有通知权限，请重新授权后再试。",
                    en: "Missing notifications access. Reauthorize and retry."
                )
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// 撰写 / 预览：对齐 `PillSegmentedControl` compact，但标题走 mapper.copy，不新增 Catalog key。
private struct GitHubNotificationComposerTabBar: View {
    @Binding var isPreview: Bool
    let locale: Locale

    var body: some View {
        HStack(spacing: 0) {
            tab(
                GitHubNotificationMapper.copy(locale, zh: "撰写", en: "Write"),
                selected: !isPreview
            ) {
                isPreview = false
            }
            tab(
                GitHubNotificationMapper.copy(locale, zh: "预览", en: "Preview"),
                selected: isPreview
            ) {
                isPreview = true
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.08), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(
                    selected ? Color.primary.opacity(0.10) : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// 通知 actor 头像。Dependabot 不是合法 user login，远程 png 会 404，
/// 所以用本地 `DependabotMark`；裁成圆，和其他 GitHub 头像一致。
struct GitHubNotificationActorAvatar: View {
    let login: String
    var size: CGFloat
    var fallbackSymbol: String = "person.crop.circle.fill"

    var body: some View {
        if let assetName = GitHubNotificationMapper.actorAvatarAssetName(login: login) {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            RemoteAvatar(
                urlString: GitHubNotificationMapper.actorAvatarURL(login: login),
                size: size,
                fallbackSymbol: fallbackSymbol,
                showBorder: false
            )
        }
    }
}

/// GitHub 用户头像 + login：有合法 login / App slug 时打开对应主页。
/// hover 用 accent + 下划线，和 `Issue #N` 同一套提示。
private struct GitHubNotificationUserLink: View {
    let login: String
    var avatarSize: CGFloat
    var nameFont: Font = .subheadline.weight(.semibold)
    var showsName: Bool = true
    @Environment(\.locale) private var locale
    @State private var isHovered = false

    var body: some View {
        let label = HStack(spacing: 8) {
            GitHubNotificationActorAvatar(login: trimmedLogin, size: avatarSize)
            if showsName {
                Text(verbatim: displayName)
                    .font(nameFont)
                    .foregroundStyle(linkTint)
                    .underline(isHovered && profileURL != nil, color: Color.accentColor)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())

        if let profileURL {
            Button {
                NSWorkspace.shared.open(profileURL)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
            .help(profileURL.absoluteString)
            .accessibilityLabel(Text(verbatim: displayName))
        } else {
            label
        }
    }

    private var trimmedLogin: String {
        login.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileURL: URL? {
        GitHubNotificationMapper.profileHTMLURL(login: trimmedLogin)
    }

    private var displayName: String {
        if trimmedLogin.isEmpty {
            return GitHubNotificationMapper.copy(locale, zh: "有人", en: "Someone")
        }
        return trimmedLogin
    }

    private var linkTint: Color {
        isHovered && profileURL != nil ? Color.accentColor : Color.primary
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
            HStack(spacing: 6) {
                GitHubNotificationUserLink(
                    login: login,
                    avatarSize: isOpeningPost ? 26 : 22
                )
                Text(verbatim: GitHubNotificationMapper.commentCardAction(
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
            .padding(.vertical, isOpeningPost ? 10 : 8)
            .background(isOpeningPost ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))

            Divider()

            if !markdown.isEmpty {
                GitHubNotificationMarkdown(content: markdown, repositoryFullName: repositoryFullName)
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isOpeningPost ? 0.12 : 0.08), lineWidth: 1)
        )
    }
}

/// 底部评论框：撰写 / 预览 + 发到 GitHub。Catalog 本轮不能加 key，文案走 mapper.copy。
private struct GitHubNotificationCommentComposer: View {
    let payload: ActivityNotificationPayload
    let issueTitle: String
    let repo: Repo?
    @Binding var isExpanded: Bool

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
    /// 没向 GitHub 确认 state 之前不显示关闭/重开，避免已关闭 Issue 误显示「关闭问题」。
    @State private var knownIssueState: String?
    @State private var isUpdatingIssueState = false
    /// AppKit 回传的内容高度；收起时从 3 行起涨，到上限再滚动。
    @State private var measuredEditorHeight: CGFloat = 0

    private var threadId: String { payload.threadId }
    private var repositoryFullName: String { payload.repositoryFullName }
    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerHeader
            Divider()
            composerBody
                .padding(.horizontal, 10)
                .padding(.top, 8)
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            composerFooter
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background)
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .task(id: threadId) {
            measuredEditorHeight = 0
            await refreshCloseEligibility(fetchRemoteState: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
            Task { await refreshCloseEligibility(fetchRemoteState: false) }
        }
        .onDisappear {
            generateTask?.cancel()
            successResetTask?.cancel()
        }
    }

    /// 「留下评论」做成卡片顶栏：浅底 + 底部分割，输入区不再套第二圈重描边。
    private var composerHeader: some View {
        HStack(spacing: 8) {
            if let login = authSession.state.user?.login, !login.isEmpty {
                GitHubNotificationUserLink(
                    login: login,
                    avatarSize: 22,
                    showsName: false
                )
            } else {
                RemoteAvatar(
                    urlString: authSession.state.user?.avatarUrl,
                    size: 22,
                    fallbackSymbol: "person.crop.circle.fill",
                    showBorder: false
                )
            }
            Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "留下评论", en: "Leave a comment"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            GitHubNotificationComposerTabBar(isPreview: $isPreview, locale: locale)
            composerExpandButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
    }

    private var composerFooter: some View {
        HStack(spacing: 8) {
            Spacer()
            aiCommentButton
            if canShowIssueStateButton {
                Button {
                    Task { await applyIssueState() }
                } label: {
                    if isUpdatingIssueState {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 72)
                    } else {
                        Text(verbatim: issueStateButtonTitle)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
                .disabled(isPosting || isGenerating || isUpdatingIssueState)
                .help(issueStateButtonTitle)
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
            .disabled(trimmed.isEmpty || isPosting || isGenerating || isUpdatingIssueState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 状态按钮：open 关、closed 重开。未知 state 先不画，避免误显示关闭。
    private var canShowIssueStateButton: Bool {
        isOwnProject
            && (knownIssueState == "open" || knownIssueState == "closed")
            && !GitHubNotificationMapper.isDemoThread(threadId)
            && GitHubNotificationMapper.canReply(
                subjectType: payload.subjectType,
                number: payload.subjectNumber
            )
    }

    private var issueStateButtonTitle: String {
        GitHubNotificationMapper.issueStateActionTitle(
            isClosed: knownIssueState == "closed",
            isPullRequest: payload.subjectType == "PullRequest",
            hasComment: !trimmed.isEmpty,
            locale: locale
        )
    }

    /// 收起态对齐 RAG composer：默认 3 行，随正文长高，到上限后内部滚动。
    /// 点展开后由父视图收起会话列表，输入区吃掉右栏剩余高度。
    private var composerFont: NSFont {
        .systemFont(ofSize: NSFont.systemFontSize)
    }

    private var composerLineHeight: CGFloat {
        let font = composerFont
        return font.ascender - font.descender + font.leading
    }

    private var composerMinHeight: CGFloat {
        ceil(composerLineHeight * 3 + GitHubNotificationCommentNSTextView.contentInset.height * 2)
    }

    private var composerCollapsedMaxHeight: CGFloat {
        ceil(composerLineHeight * 8 + GitHubNotificationCommentNSTextView.contentInset.height * 2)
    }

    private var composerEditorHeight: CGFloat {
        let measured = measuredEditorHeight > 0 ? measuredEditorHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerCollapsedMaxHeight)
    }

    @ViewBuilder
    private var composerBody: some View {
        Group {
            if isPreview {
                ScrollView {
                    if trimmed.isEmpty {
                        Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "没什么可预览的", en: "Nothing to preview"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        GitHubNotificationMarkdown(
                            content: draft,
                            repositoryFullName: repositoryFullName
                        )
                    }
                }
                .padding(8)
            } else {
                GitHubNotificationCommentTextEditor(
                    text: $draft,
                    placeholder: GitHubNotificationMapper.copy(
                        locale,
                        zh: "用 Markdown 写下评论…",
                        en: "Write a comment with Markdown…"
                    ),
                    isEditable: !isPosting && !isGenerating,
                    maximumHeight: composerCollapsedMaxHeight,
                    onHeightChange: { measuredEditorHeight = $0 }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isExpanded ? .infinity : composerEditorHeight)
        .frame(height: isExpanded ? nil : composerEditorHeight)
        .layoutPriority(isExpanded ? 1 : 0)
    }

    private var composerExpandButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(GitHubNotificationMapper.copy(
            locale,
            zh: isExpanded ? "收起评论框" : "展开评论框",
            en: isExpanded ? "Collapse comment box" : "Expand comment box"
        ))
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

    private func applyIssueState() async {
        isUpdatingIssueState = true
        errorMessage = nil
        defer { isUpdatingIssueState = false }
        let shouldReopen = knownIssueState == "closed"
        do {
            if !trimmed.isEmpty {
                try await inbox.postComment(threadId: threadId, body: trimmed)
                draft = ""
                isPreview = false
            }
            if shouldReopen {
                try await inbox.reopenIssue(threadId: threadId)
                knownIssueState = "open"
            } else {
                try await inbox.closeIssue(threadId: threadId)
                knownIssueState = "closed"
            }
        } catch {
            errorMessage = submitErrorMessage(error)
        }
    }

    /// 关闭 / 重开都要先 GET 到明确的 open/closed。未知 state 不画按钮。
    private func refreshCloseEligibility(fetchRemoteState: Bool) async {
        if fetchRemoteState {
            knownIssueState = nil
        }
        isOwnProject = await resolveOwnProject()
        let canConsider = isOwnProject
            && !GitHubNotificationMapper.isDemoThread(threadId)
            && GitHubNotificationMapper.canReply(
                subjectType: payload.subjectType,
                number: payload.subjectNumber
            )
        guard canConsider else {
            knownIssueState = nil
            return
        }
        if fetchRemoteState {
            await inbox.refreshIssueState(threadId: threadId)
        }
        let cached = inbox.cachedIssueState(threadId: threadId)
        if cached == "open" || cached == "closed" {
            knownIssueState = cached
        } else {
            knownIssueState = nil
        }
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
/// 和 insertion point 不在同一坐标系。测高对齐 RAG `AICommandTextEditor`：
/// usedRect + inset，由外层按 3 行下限 / 8 行上限钳制，超出后内部滚动。
private struct GitHubNotificationCommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEditable: Bool = true
    let maximumHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void

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
        // 等容器拿到宽度后再测 usedRect，避免首帧按单行高度跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
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
            context.coordinator.reportHeight(for: textView)
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
            reportHeight(for: textView)
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let height = min(
                ceil(usedHeight + GitHubNotificationCommentNSTextView.contentInset.height * 2),
                parent.maximumHeight
            )
            parent.onHeightChange(height)
        }
    }
}

private final class GitHubNotificationCommentScrollView: NSScrollView {
    /// 空白处也能点进输入：textView 至少铺满当前 SwiftUI 框；内容更高时再长高，交给滚动。
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        let minHeight = contentSize.height
        var used = minHeight
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            used = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
        }
        let height = max(minHeight, used)
        textView.minSize = NSSize(width: 0, height: minHeight)
        if abs(textView.frame.width - width) >= 0.5 || abs(textView.frame.height - height) >= 0.5 {
            textView.setFrameSize(NSSize(width: width, height: height))
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
