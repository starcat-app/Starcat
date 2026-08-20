//
//  GitHubNotificationDetailView.swift
//  Starcat
//
//  通知页右栏：按 GitHub Issue 会话排版（评论卡片 + 底部评论框）。
//  顶区与中栏同构：`.navigationTitle` / `.navigationSubtitle` + 与分段条同高的工具行，
//  避免中栏 / 右栏分割线错层。根节点挂 `detailHeroTintBackground`，和账本仓库详情同一道光晕。
//

import AppKit
import Kingfisher
import MarkdownUI
import SwiftUI

struct GitHubNotificationDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @Binding var selectedItem: ActivityItem?
    @State private var isComposerExpanded = false
    @State private var isMarkingDone = false
    @State private var isDoneHelpPresented = false
    @State private var doneError: String?
    @State private var translationVM: ReadmeTranslationViewModel?
    @State private var translationPaywall: ProPaywallContext?
    @State private var isConversationScrolling = false

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
        .sheet(item: translationPaywallBinding) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
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
        .background(.background)
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
            if let translationError = translationVM?.errorMessage, !translationError.isEmpty {
                Text(verbatim: translationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                    .padding(.bottom, 6)
            }
            Divider()
            if !isComposerExpanded {
                ScrollView {
                    // 长会话继续用 LazyVStack 控制屏外卡片数量；滚动期另外暂停文字选择层，
                    // 避免译文批次更新和 NSTextField SelectionOverlay 一起反复刷新布局图。
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let payload = item.notification {
                            repoRow(payload)
                            conversation(payload, translation: translationVM)
                        }
                    }
                    .padding(18)
                }
                .onScrollPhaseChange { _, newPhase in
                    let isScrolling = newPhase != .idle
                    guard isConversationScrolling != isScrolling else { return }
                    isConversationScrolling = isScrolling
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
        // 语言色光晕挂在会话详情根上，和账本 / Manage 详情同一套；工具行走透明才能透出来。
        .detailHeroTintBackground(tint: item.accentColor)
        // 标题进系统导航栏，和中栏「活动 > 通知 / 46 条通知」同一层；下面只留一行工具条。
        .navigationTitle(item.title)
        .navigationSubtitle(navigationSubtitle(item))
        .onChange(of: item.notification?.threadId) { _, _ in
            isComposerExpanded = false
            isConversationScrolling = false
            isDoneHelpPresented = false
            doneError = nil
            prepareTranslation(for: item)
        }
        .onChange(of: isComposerExpanded) { _, isExpanded in
            // 展开撰写器会移除会话 ScrollView；手动复位，避免重新折叠后仍保持滚动态策略。
            if isExpanded { isConversationScrolling = false }
        }
        .onChange(of: settings.readmeTranslationLanguage) { _, _ in
            prepareTranslation(for: item)
        }
        .onChange(of: locale.identifier) { _, _ in
            guard settings.readmeTranslationLanguage == .auto else { return }
            prepareTranslation(for: item)
        }
        .onChange(of: settings.readmeTranslationMode) { _, _ in
            prepareTranslation(for: item)
        }
        .onChange(of: translationHydrationSignature(item)) { _, _ in
            // 评论后到时不要把已显示的对照打回原文；只在原文态刷新缓存探测。
            refreshTranslationSourceIfNeeded(for: item)
        }
        .onAppear {
            isConversationScrolling = false
            prepareTranslation(for: item)
        }
    }

    /// 与中栏分段条同高：chip + 可点 `Issue #20` 在左，入口 / 上下条在右。
    /// 高度走 `manageListFilterBarChrome()`，不要只靠相同 padding——Picker 比 chip 高。
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
                if let vm = translationVM, let payload = item.notification {
                    translationControls(payload: payload, viewModel: vm)
                }
                if item.notification?.threadId != nil {
                    doneButton(item)
                }
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
                .toolbarIconHover()
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
                .toolbarIconHover()
                .help(GitHubNotificationMapper.copy(locale, zh: "下一条", en: "Next notification"))
            }
        }
        .manageListFilterBarChrome()
        // 透明，让根节点语言色光晕透到 chip 行和标题栏背后。
        .background(.clear)
    }

    /// 完成走 Inbox Done；感叹号只开说明，避免把主操作吃进 popover。
    private func doneButton(_ item: ActivityItem) -> some View {
        HStack(spacing: 0) {
            Button {
                Task { await markCurrentDone(item) }
            } label: {
                if isMarkingDone {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                } else {
                    Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "完成", en: "Done"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isMarkingDone || item.notification?.threadId == nil)
            .toolbarIconHover(cornerRadius: 0)
            .help(GitHubNotificationMapper.copy(
                locale,
                zh: "从 GitHub 收件箱移走这条，不会关闭 Issue",
                en: "Remove this from the GitHub inbox. Does not close the issue."
            ))

            Button {
                isDoneHelpPresented.toggle()
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .toolbarIconHover(cornerRadius: 0)
            .help(GitHubNotificationMapper.copy(
                locale,
                zh: "查看「完成」会做什么",
                en: "What Done does"
            ))
            .popover(isPresented: $isDoneHelpPresented, arrowEdge: .bottom) {
                GitHubNotificationDoneHelpPopover(locale: locale)
                    .appLocaleEnvironment()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
        )
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
                    size: 26,
                    fallbackSymbol: "shippingbox.fill",
                    showBorder: false
                )
                // 比评论作者再大一档：title3 是项目里仓库名的常用档，headline 在 macOS 上几乎看不出差。
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
        .clickablePointer()
    }

    @ViewBuilder
    private func conversation(
        _ payload: ActivityNotificationPayload,
        translation: ReadmeTranslationViewModel?
    ) -> some View {
        let document = translationDocument(payload)
        let isShowing = {
            if case .showingTranslation = translation?.displayMode { return true }
            return false
        }()
        let translations = translation?.renderState.translations ?? []
        // 对照/替换跟当前这次翻译的 mode，避免菜单已改、译文还是上一档。
        let translationMode = translation?.renderState.mode ?? settings.readmeTranslationMode
        let isJobTranslating = translation?.isTranslating ?? false
        let translationLanguage = settings.effectiveReadmeTranslationLanguage
        let allowsTextSelection = !isConversationScrolling
        let prefersAnimatedEntrance =
            (translation?.renderState.prefersAnimatedEntrance ?? false) && !isConversationScrolling

        if let excerpt = payload.excerpt, !excerpt.isEmpty {
            GitHubNotificationCommentCard(
                login: payload.authorLogin ?? "",
                createdAt: payload.authorCreatedAt,
                markdown: excerpt,
                repositoryFullName: payload.repositoryFullName,
                isOpeningPost: true,
                blocks: document.blocks.filter { $0.kind == .opening },
                translations: translations,
                isShowingTranslation: isShowing,
                translationMode: translationMode,
                prefersAnimatedEntrance: prefersAnimatedEntrance,
                isJobTranslating: isJobTranslating,
                translationLanguage: translationLanguage,
                allowsTextSelection: allowsTextSelection
            )
        }

        ForEach(payload.comments) { comment in
            GitHubNotificationCommentCard(
                login: comment.login,
                createdAt: GitHubNotificationMapper.parseDate(comment.createdAt),
                markdown: comment.body,
                repositoryFullName: payload.repositoryFullName,
                isOpeningPost: false,
                blocks: document.blocks.filter {
                    if case .comment(let id) = $0.kind { return id == comment.id }
                    return false
                },
                translations: translations,
                isShowingTranslation: isShowing,
                translationMode: translationMode,
                prefersAnimatedEntrance: prefersAnimatedEntrance,
                isJobTranslating: isJobTranslating,
                translationLanguage: translationLanguage,
                allowsTextSelection: allowsTextSelection
            )
        }
    }

    private func translationDocument(_ payload: ActivityNotificationPayload) -> GitHubNotificationTranslation.Document {
        GitHubNotificationTranslation.makeDocument(
            opening: payload.excerpt.map(GitHubNotificationMapper.prepareMarkdown),
            comments: payload.comments.map { comment in
                GitHubNotificationComment(
                    id: comment.id,
                    login: comment.login,
                    body: GitHubNotificationMapper.prepareMarkdown(comment.body),
                    htmlURL: comment.htmlURL,
                    createdAt: comment.createdAt
                )
            }
        )
    }

    private func prepareTranslation(for item: ActivityItem) {
        let vm: ReadmeTranslationViewModel
        if let existing = translationVM {
            vm = existing
        } else {
            vm = ReadmeTranslationViewModel(service: dependencies.readmeTranslationService)
            translationVM = vm
        }
        guard let payload = item.notification else {
            vm.prepare(
                identity: nil,
                cacheOwner: nil,
                cacheRepo: nil,
                sourceHtml: nil,
                targetLanguage: settings.effectiveReadmeTranslationLanguage,
                mode: settings.readmeTranslationMode
            )
            return
        }
        let document = translationDocument(payload)
        vm.prepare(
            identity: GitHubNotificationTranslation.identity(threadId: payload.threadId),
            cacheOwner: GitHubNotificationTranslation.cacheOwner,
            cacheRepo: GitHubNotificationTranslation.cacheRepo(threadId: payload.threadId),
            sourceHtml: document.sourceText,
            targetLanguage: settings.effectiveReadmeTranslationLanguage,
            mode: settings.readmeTranslationMode
        )
    }

    /// excerpt / 评论条数变化（同一 thread 后到）才刷新；切帖走 threadId onChange。
    private func translationHydrationSignature(_ item: ActivityItem) -> String {
        guard let payload = item.notification else { return "" }
        return "\(payload.excerpt?.count ?? 0)|\(payload.comments.count)|\(payload.comments.last?.id ?? 0)"
    }

    /// 评论后到时：原文态重新探测缓存；对照已上屏或正在翻译则不动，避免闪回原文。
    private func refreshTranslationSourceIfNeeded(for item: ActivityItem) {
        guard let vm = translationVM else {
            prepareTranslation(for: item)
            return
        }
        if vm.isTranslating { return }
        if case .showingTranslation = vm.displayMode { return }
        prepareTranslation(for: item)
    }

    private var translationPaywallBinding: Binding<ProPaywallContext?> {
        Binding(
            get: { translationPaywall ?? translationVM?.paywallContext },
            set: { newValue in
                if newValue == nil {
                    translationPaywall = nil
                    translationVM?.dismissPaywall()
                } else {
                    translationPaywall = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func translationControls(
        payload: ActivityNotificationPayload,
        viewModel: ReadmeTranslationViewModel
    ) -> some View {
        let document = translationDocument(payload)
        GitHubNotificationTranslationControls(
            viewModel: viewModel,
            document: document,
            threadId: payload.threadId,
            settings: settings,
            reduceMotion: reduceMotion
        )
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
            .toolbarIconHover()
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
            .toolbarIconHover()
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
        .clickablePointer()
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
            .clickablePointer()
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
            .clickablePointer()
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

private struct GitHubNotificationCommentCard: View {
    let login: String
    let createdAt: Date?
    let markdown: String
    let repositoryFullName: String
    let isOpeningPost: Bool
    var blocks: [GitHubNotificationTranslation.Block] = []
    var translations: [ReadmeRenderedTranslation] = []
    var isShowingTranslation: Bool = false
    var translationMode: ReadmeTranslationMode = .segmented
    var prefersAnimatedEntrance: Bool = false
    /// 整帖任务还在跑。光圈是否亮看 `isHaloActive`：本卡段到齐就先灭。
    var isJobTranslating: Bool = false
    var translationLanguage: ReadmeTranslationLanguage = .auto
    var allowsTextSelection: Bool = true
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var relevantTranslations: [ReadmeRenderedTranslation] {
        let ids = Set(blocks.compactMap(\.segmentId))
        guard !ids.isEmpty else { return [] }
        return translations.filter { ids.contains($0.id) }
    }

    /// 本卡还有未完成、且需要送 AI 的段才亮。围栏 / 已是目标语言的段不占光圈。
    private var isHaloActive: Bool {
        guard isJobTranslating else { return false }
        let done = Set(relevantTranslations.map(\.id))
        for block in blocks {
            guard let id = block.segmentId, !done.contains(id) else { continue }
            if TranslationSourceLanguageGate.shouldSkipTranslation(
                text: block.markdown,
                target: translationLanguage
            ) {
                continue
            }
            return true
        }
        return false
    }

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
                commentBody
                    .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isOpeningPost ? 0.12 : 0.08), lineWidth: 1)
                .opacity(isHaloActive ? 0 : 1)
                .animation(
                    .easeInOut(duration: StarcatAIHaloMetrics.fadeDuration(reduceMotion)),
                    value: isHaloActive
                )
        )
        // 正 padding 给光圈留 gutter；负 padding 把占位收回去，空闲时卡片间距不变。
        .padding(StarcatAIHaloMetrics.glowBleed)
        .overlay {
            if isJobTranslating {
                // 和 README 共用连续 CA 光圈；卡片滚动时不进入 SwiftUI TimelineView / blur。
                StarcatAIBloomHaloLayerView(
                    isActive: isHaloActive,
                    reduceMotion: reduceMotion
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(-StarcatAIHaloMetrics.glowBleed)
    }

    @ViewBuilder
    private var commentBody: some View {
        if isShowingTranslation, !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    translatedBlock(block)
                }
            }
            // 只给「新译文到达」做入场；切回原文走 identity，避免整卡闪。
            .animation(translationEntranceAnimation, value: relevantTranslations.map(\.id))
        } else {
            GitHubNotificationMarkdown(
                content: markdown,
                repositoryFullName: repositoryFullName,
                allowsTextSelection: allowsTextSelection
            )
        }
    }

    private var translationEntranceAnimation: Animation? {
        if reduceMotion || !prefersAnimatedEntrance { return nil }
        switch translationMode {
        case .segmented:
            return .easeOut(duration: 0.18)
        case .full:
            return .easeOut(duration: 0.16)
        }
    }

    @ViewBuilder
    private func translatedBlock(_ block: GitHubNotificationTranslation.Block) -> some View {
        let translated = block.segmentId.flatMap { id in
            GitHubNotificationTranslation.translation(for: id, from: relevantTranslations)
        }
        switch translationMode {
        case .segmented:
            // 分段对照：原文保留，译文跟在下面。代码围栏没有 segmentId，只显示原文。
            VStack(alignment: .leading, spacing: 6) {
                GitHubNotificationMarkdown(
                    content: block.markdown,
                    repositoryFullName: repositoryFullName,
                    allowsTextSelection: allowsTextSelection
                )
                if let translated, !translated.isEmpty {
                    Text(translated)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .notificationTextSelection(allowsTextSelection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .identity
                        ))
                }
            }
        case .full:
            // 全文替换：有译文就只显示译文；围栏和尚未翻完的段仍用原文，避免卡片被掏空。
            GitHubNotificationMarkdown(
                content: translated.flatMap { $0.isEmpty ? nil : $0 } ?? block.markdown,
                repositoryFullName: repositoryFullName,
                allowsTextSelection: allowsTextSelection
            )
            .id("\(block.segmentId ?? "fence")-\(translated == nil || translated?.isEmpty == true ? "src" : "tx")")
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
    }
}

/// 完成钮说明：Inbox Done 只移走收件箱条目，不关 Issue / PR。文案走 mapper，不改 Catalog。
private struct GitHubNotificationDoneHelpPopover: View {
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "完成", en: "Done"))
                .font(.headline)
                .foregroundStyle(.primary)
            Text(verbatim: GitHubNotificationMapper.copy(
                locale,
                zh: "把这条从 GitHub 收件箱移走，等同 Inbox 的 Done。不会关闭 Issue 或 Pull Request。",
                en: "Removes this thread from the GitHub inbox (same as Inbox Done). It does not close the issue or pull request."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }
}

/// 顶栏翻译：22×22 方底气泡，和 Starcat / GitHub 同一套节奏；chevron 无独立底，只做附属。
/// 默认分段对照；全文只替换卡片正文。切段仍按 Markdown 块，缓存按 mode 分文件。
private struct GitHubNotificationTranslationControls: View {
    let viewModel: ReadmeTranslationViewModel
    let document: GitHubNotificationTranslation.Document
    let threadId: String
    let settings: AppSettings
    let reduceMotion: Bool

    @State private var isHoveringWhileTranslating = false

    private var isShowingTranslation: Bool {
        if case .showingTranslation = viewModel.displayMode { return true }
        return false
    }

    private var hasSegments: Bool {
        !document.segments.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if viewModel.isTranslating {
                    viewModel.cancelTranslation()
                } else {
                    viewModel.toggleTranslation(
                        identity: GitHubNotificationTranslation.identity(threadId: threadId),
                        cacheOwner: GitHubNotificationTranslation.cacheOwner,
                        cacheRepo: GitHubNotificationTranslation.cacheRepo(threadId: threadId),
                        sourceHtml: document.sourceText,
                        sourceSegments: document.segments,
                        targetLanguage: settings.effectiveReadmeTranslationLanguage,
                        mode: settings.readmeTranslationMode
                    )
                }
            } label: {
                iconView
                    .squareLogoActionChrome(
                        side: 22,
                        backgroundColor: isShowingTranslation
                            ? Color.accentColor.opacity(0.14)
                            : Color.secondary.opacity(0.10)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .toolbarIconHover()
            .disabled(!viewModel.isTranslating && !hasSegments)
            .help(buttonTooltip)
            .onHover { hovering in
                if viewModel.isTranslating {
                    isHoveringWhileTranslating = hovering
                } else if isHoveringWhileTranslating {
                    isHoveringWhileTranslating = false
                }
            }
            .accessibilityLabel(Text(isShowingTranslation
                ? "readme.translate.showOriginal"
                : "readme.translate.action"))

            Menu {
                Picker(selection: Binding(
                    get: { settings.readmeTranslationMode },
                    set: { settings.readmeTranslationMode = $0 }
                )) {
                    ForEach(ReadmeTranslationMode.allCases) { mode in
                        Label(
                            LocalizedStringKey(mode.displayNameKey),
                            systemImage: mode.systemImage
                        )
                        .tag(mode)
                    }
                } label: {
                    Text("readme.translate.menu.mode")
                }
                .pickerStyle(.inline)

                Divider()

                Picker(selection: Binding(
                    get: { settings.readmeTranslationLanguage },
                    set: { settings.readmeTranslationLanguage = $0 }
                )) {
                    ForEach(ReadmeTranslationLanguage.allCases) { lang in
                        Text(verbatim: lang.displayName).tag(lang)
                    }
                } label: {
                    Text("readme.translate.menu.language")
                }
                .pickerStyle(.inline)

                Divider()

                Button {
                    viewModel.regenerate(
                        identity: GitHubNotificationTranslation.identity(threadId: threadId),
                        cacheOwner: GitHubNotificationTranslation.cacheOwner,
                        cacheRepo: GitHubNotificationTranslation.cacheRepo(threadId: threadId),
                        sourceHtml: document.sourceText,
                        sourceSegments: document.segments,
                        targetLanguage: settings.effectiveReadmeTranslationLanguage,
                        mode: settings.readmeTranslationMode
                    )
                } label: {
                    Label("readme.translate.menu.regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isTranslating || !hasSegments)
            } label: {
                // 和中栏「全部」筛选菜单右侧同一套，不要另起 compact / semibold。
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .frame(height: 22)
            .focusEffectDisabled()
            .clickablePointer()
            .help("readme.translate.menu.tooltip")
        }
    }

    /// 翻译中不用系统 8 瓣 spinner：那段数已经在 VM 里，圆环才能看出走了多少。
    /// hover 仍切红色 stop，ZStack + opacity 避免重建圆环把进度动画打回去。
    @ViewBuilder
    private var iconView: some View {
        if viewModel.isTranslating {
            ZStack {
                translationProgressRing
                    .opacity(isHoveringWhileTranslating ? 0 : 1)
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
                    .opacity(isHoveringWhileTranslating ? 1 : 0)
            }
            .frame(width: 14, height: 14)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHoveringWhileTranslating)
            .accessibilityValue(Text(verbatim: translationProgressLabel))
        } else {
            // 14×14 画布对齐 GitHub logo；12pt medium 抵消 SF Symbol 比 bitmap 更满。
            Image(systemName: isShowingTranslation ? "character.bubble.fill" : "character.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isShowingTranslation ? Color.accentColor : Color.primary)
                .frame(width: 14, height: 14)
        }
    }

    private var translationProgress: Double {
        let total = viewModel.totalSegmentCount
        guard total > 0 else { return 0 }
        return min(max(Double(viewModel.completedSegmentCount) / Double(total), 0), 1)
    }

    private var translationProgressLabel: String {
        "\(viewModel.completedSegmentCount)/\(viewModel.totalSegmentCount)"
    }

    private var translationProgressRing: some View {
        let fraction = translationProgress
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: fraction)
        }
        .frame(width: 14, height: 14)
    }

    private var buttonTooltip: LocalizedStringKey {
        if viewModel.isTranslating && isHoveringWhileTranslating {
            return "readme.translate.tooltip.stop"
        }
        if isShowingTranslation { return "readme.translate.tooltip.showOriginal" }
        return "readme.translate.tooltip.translate"
    }
}

/// 底部评论框：空草稿缩成一行；点进去才展开撰写 / 预览。Catalog 本轮不能加 key，文案走 mapper.copy。
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
    /// 点进一行占位后才展开卡片。失焦且草稿空才收回，避免底栏按钮抢焦点时被立刻收掉。
    @State private var isComposerActive = false
    @State private var collapseIdleTask: Task<Void, Never>?

    private var threadId: String { payload.threadId }
    private var repositoryFullName: String { payload.repositoryFullName }
    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsFullComposer {
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
                .transition(.opacity)
            } else {
                idleBar
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : nil, alignment: .top)
        // 非全屏必须按内容高度收拢。光圈 overlay 不能再写成 ZStack + infinity，
        // 否则会吃掉右栏剩余高度，一行占位会被撑在大空盒子中间。
        .fixedSize(horizontal: false, vertical: !isExpanded)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                .opacity(isGenerating ? 0 : 1)
                .animation(.easeInOut(duration: StarcatAIHaloMetrics.fadeDuration(reduceMotion)), value: isGenerating)
        )
        // 光晕铺在 clip 外面的一圈 gutter 里，加大 blur 才不会被圆角裁掉。
        .padding(StarcatAIHaloMetrics.glowBleed)
        .overlay {
            StarcatAIGeneratingHalo(isActive: isGenerating)
        }
        .animation(composerAnimation, value: showsFullComposer)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background)
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .task(id: threadId) {
            resetComposerForThreadChange()
            await refreshCloseEligibility(fetchRemoteState: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
            Task { await refreshCloseEligibility(fetchRemoteState: false) }
        }
        .onDisappear {
            generateTask?.cancel()
            successResetTask?.cancel()
            collapseIdleTask?.cancel()
        }
        // 预览态焦点在 SwiftUI；撰写态在 NSTextView，Esc 由 textView doCommandBy 再走同一套。
        .onKeyPress(.escape) {
            handleEscape() ? .handled : .ignored
        }
    }

    /// 全屏、正在写、有草稿、预览或 AI 生成中都保持卡片，避免半当中缩成一行。
    private var showsFullComposer: Bool {
        isExpanded
            || isComposerActive
            || !trimmed.isEmpty
            || isGenerating
            || isPosting
            || isPreview
    }

    private var composerAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    /// 「留下评论」做成卡片顶栏：浅底 + 底部分割，输入区不再套第二圈重描边。
    private var composerHeader: some View {
        HStack(spacing: 8) {
            composerHeaderAvatar
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

    /// 空态一行：整行可点，点进去才展开卡片。规范要求折叠行不要只靠小图标触发。
    /// 头像不用 UserLink：外层已经是 Button，不能再套一层可点头像。
    private var idleBar: some View {
        Button {
            activateComposer()
        } label: {
            HStack(spacing: 8) {
                RemoteAvatar(
                    urlString: authSession.state.user?.avatarUrl,
                    size: 22,
                    fallbackSymbol: "person.crop.circle.fill",
                    showBorder: false
                )
                Text(verbatim: GitHubNotificationMapper.copy(
                    locale,
                    zh: "留下评论…",
                    en: "Leave a comment…"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .clickablePointer()
        .accessibilityLabel(Text(verbatim: GitHubNotificationMapper.copy(
            locale,
            zh: "留下评论",
            en: "Leave a comment"
        )))
    }

    @ViewBuilder
    private var composerHeaderAvatar: some View {
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
    }

    private func activateComposer() {
        collapseIdleTask?.cancel()
        withAnimation(composerAnimation) {
            isComposerActive = true
        }
    }

    /// 点卡片里的 Preview / AI / 发送时，NSTextView 会先失焦。立刻收会把这次点击吃掉。
    private func scheduleCollapseIfIdle() {
        collapseIdleTask?.cancel()
        collapseIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            collapseComposerIfIdle()
        }
    }

    private func collapseComposerIfIdle() {
        guard trimmed.isEmpty,
              !isGenerating,
              !isPosting,
              !isPreview,
              !isExpanded,
              paywallContext == nil
        else { return }
        withAnimation(composerAnimation) {
            isComposerActive = false
        }
    }

    /// Esc：全屏先缩回卡片；卡片且草稿空再收成一行。有草稿不丢内容。
    /// 输入法未上屏时交给 NSTextView，避免把拼音一起取消。
    @discardableResult
    private func handleEscape() -> Bool {
        if isExpanded {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                isExpanded = false
            }
            return true
        }
        guard showsFullComposer,
              trimmed.isEmpty,
              !isGenerating,
              !isPosting,
              !isPreview
        else { return false }
        collapseIdleTask?.cancel()
        withAnimation(composerAnimation) {
            isComposerActive = false
        }
        return true
    }

    private func resetComposerForThreadChange() {
        collapseIdleTask?.cancel()
        draft = ""
        isPreview = false
        isComposerActive = false
        errorMessage = nil
        measuredEditorHeight = 0
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
                .clickablePointer()
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
            .clickablePointer()
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
                    shouldBecomeFirstResponder: true,
                    onHeightChange: { measuredEditorHeight = $0 },
                    onEditingChange: { editing in
                        if editing {
                            collapseIdleTask?.cancel()
                            isComposerActive = true
                        } else {
                            scheduleCollapseIfIdle()
                        }
                    },
                    onEscape: { handleEscape() }
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
        .clickablePointer()
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
                .clickablePointer()
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
                .clickablePointer()
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
                .clickablePointer()
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
        Group {
            if didGenerate {
                // 成功态跟复制按钮一样用绿色勾；不要再垫一层 secondary 圆，会把绿色盖成灰。
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.green)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAIHovered ? Color.accentColor : Color.secondary)
                    .background(
                        Circle().fill(Color.secondary.opacity(isAIHovered ? 0.16 : 0.10))
                    )
            }
        }
        .frame(width: 22, height: 22)
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
            collapseComposerIfIdle()
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
                collapseComposerIfIdle()
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
    var shouldBecomeFirstResponder: Bool = false
    let onHeightChange: (CGFloat) -> Void
    var onEditingChange: ((Bool) -> Void)? = nil
    /// 撰写态 first responder 在 NSTextView，Esc 不会回到 SwiftUI，这里回传是否已处理。
    var onEscape: (() -> Bool)? = nil

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
        scrollView.onMeasuredHeight = { [coordinator = context.coordinator] height in
            coordinator.parent.onHeightChange(height)
        }
        scrollView.maximumHeight = maximumHeight
        // 等容器拿到宽度后再测 usedRect，避免首帧按单行高度跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? GitHubNotificationCommentNSTextView else { return }
        if let commentScroll = scrollView as? GitHubNotificationCommentScrollView {
            commentScroll.onMeasuredHeight = { [coordinator = context.coordinator] height in
                coordinator.parent.onHeightChange(height)
            }
            commentScroll.maximumHeight = maximumHeight
        }
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            // 手打字走 textDidChange，glyph 已经按当前宽度折行。
            // AI 流式写 draft 只进这里，立刻测高会把整段当成一行，框就停在 3 行。
            scrollView.layoutSubtreeIfNeeded()
            context.coordinator.reportHeight(for: textView)
            DispatchQueue.main.async {
                context.coordinator.reportHeight(for: textView)
            }
        }
        if shouldBecomeFirstResponder {
            context.coordinator.focusIfNeeded(textView, in: scrollView)
        } else {
            context.coordinator.didRequestFocus = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GitHubNotificationCommentTextEditor
        var didRequestFocus = false

        init(parent: GitHubNotificationCommentTextEditor) {
            self.parent = parent
        }

        func focusIfNeeded(_ textView: NSTextView, in scrollView: NSScrollView) {
            guard !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async {
                scrollView.window?.makeFirstResponder(textView)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onEditingChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEditingChange?(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? GitHubNotificationCommentNSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            // 输入法候选未上屏时 Esc 应只取消拼音，不能收评论框。
            if textView.hasMarkedText() { return false }
            return parent.onEscape?() ?? false
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            if let scrollView = textView.enclosingScrollView {
                let width = scrollView.contentSize.width
                if width <= 1 { return }
                if abs(textView.frame.width - width) >= 0.5 {
                    textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, 1)))
                }
            }
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
    /// SwiftUI 侧的高度上限，layout 里测高后回传，让 AI 写入也能把外框撑开。
    var maximumHeight: CGFloat = 0
    var onMeasuredHeight: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0

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
        let reported = maximumHeight > 0 ? min(used, maximumHeight) : used
        guard abs(reported - lastReportedHeight) >= 0.5 else { return }
        lastReportedHeight = reported
        onMeasuredHeight?(reported)
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
    var allowsTextSelection: Bool = true

    var body: some View {
        Markdown(
            GitHubNotificationMapper.autolinkIssueReferences(
                GitHubNotificationMapper.prepareMarkdown(content),
                repositoryFullName: repositoryFullName
            )
        )
        .markdownImageProvider(GitHubNotificationImageProvider())
        .notificationTextSelection(allowsTextSelection)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

private extension View {
    /// macOS 的文字选择会创建 AppKit SelectionOverlay。会话滚动时临时卸掉，停止后恢复。
    @ViewBuilder
    func notificationTextSelection(_ isEnabled: Bool) -> some View {
        if isEnabled {
            self.textSelection(.enabled)
        } else {
            self.textSelection(.disabled)
        }
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
