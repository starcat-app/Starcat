//
//  RepoMetadataHeaderView.swift
//  Starcat
//
//  Repo 详情顶部元信息面板的公共组件。
//
//  设计目标：
//  - Manage / Activity 的 repo-backed 详情共享同一套顶部信息结构与交互反馈。
//  - 顶部面板本身不滚动；README WebView 滚动时由外层折叠容器隐藏。
//  - 点击头像、仓库名、Stats、Watchers、AI 等 hero 内交互统一使用 `.buttonStyle(.plain)`、
//    `.focusEffectDisabled()` 和 `.pressableHover()`，避免不同页面出现不同 hover / focus 体验。
//

import SwiftUI
import AppKit

/// repo 详情顶部元信息内容。
///
/// 这个组件只负责渲染“自然高度”的元信息面板；是否折叠、如何测高、何时隐藏由
/// `CollapsibleRepoMetadataPanel` 处理。Activity 可以传入分类色作为 fallback，从而在
/// repo 没有主语言时仍保持“活动分类色 → 透明”的详情背景。
///
/// ### R-01 v1.5 设计 §3.2.4 / §3.2.6（2026-06-10 修订）
///
/// **本组件只渲染 hero 元信息**（avatar / 名字 / topics / desc / stats / chip /
/// trailingActions）—— Tags / Notes / Release 三段在独立组件 `RepoLocalSections`,
/// 由 **`RepoDetailScaffold.metadataPanel`** 单点挂载（紧跟在 `heroExtension`
/// 之后,跟随折叠面板整段折叠）。
///
/// **演化轨迹**：
/// - 早期：三段塞在 `RepoMetadataHeaderView` 内（god view）
/// - v1.2 P0（2026-06-10 上午）：三段下沉到 4 个 ContentView 内（理由「各场景的
///   section 集合不同,hero 不该知道有几段要展开」）
/// - v1.5（2026-06-10 下午）：dong4j 反馈滚动 README 时三段挤压阅读区,内置回
///   `RepoDetailScaffold.metadataPanel` 跟随折叠（4 场景同构事实推翻 v1.2 P0
///   原则;详见 `Starcat/Shared/Components/RepoDetailScaffold.swift` 文件头）
///
/// 三段的可见性由 `RepoLocalSections` 内部根据 `isAuthenticated && repo.isStarred`
/// 自动判定(**v2.0 修订**, 2026-06-10,从 v1.7 的 registry.contains 回归到
/// `Repo.isStarred` 字段。原因:registry.reload() 异步 + SyncManager 304 早退
/// 不触发 hook 导致 Manage 三段空缺,详见 `RepoLocalSections.swift` 文件头),
/// ContentView / Scaffold 都不需要再传 isLocalHit 等开关参数。
struct RepoMetadataHeaderView<TrailingActions: View>: View {
    let repo: Repo
    let fallbackAccentColor: Color

    /// hero ⭐/☆ chip 触发的异步动作。
    ///
    /// 设计 §3.2.3 状态机要求 chip 内部能感知 loading / 失败这两个临时状态，
    /// 所以闭包签名是 `() async throws -> Void`：
    /// - 成功（不抛错）→ `StarStatChipButton` 内部 isLoading 复位，UI 由外层
    ///   数据流（StarredRegistry @Observable）驱动重渲染（API 200 才变 UI）
    /// - 抛错 → chip 抖动 + 短暂红色 600ms（不弹 toast / alert，§3.2.3 / Q2）
    let onStarTapped: () async throws -> Void
    /// Stars stat 按钮的 tooltip 本地化键。
    ///
    /// 4 详情页(v1.7 起同构):调用方按 `StarredRegistry.contains(ghRepoId:)` 派生:
    /// - 已 star → `"repo.unstar"`(点击 unstar)
    /// - 未 star → `"trending.star"` 或 `"repo.star"`(点击 star)
    ///
    /// 这是为了让 tooltip 与实际 `onStarTapped` 闭包(`StarActionService.toggle`)
    /// 行为对齐,避免误导用户。
    let starHelpKey: LocalizedStringKey
    let headerSourceBadge: RepoDetailHeaderSourceBadge?
    let showsRepoHealthEntry: Bool
    private let trailingActions: TrailingActions

    /// OpenSSF 与 Repo Health 都放在 `full_name` 同行。
    /// OpenSSF 是公开安全信号，所有详情页可见；Repo Health 是 Manage 专属 Pro 能力，
    /// 由 Scaffold 通过 `showsRepoHealthEntry` 明确放行。
    @Environment(AppDependencies.self) private var dependencies
    /// Forks / Watchers 的语义色按 colorScheme 切换 —— 见 StatSemanticColor。
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var showOpenSSFScoreSheet = false
    @State private var showRepoHealthSheet = false
    @State private var paywallContext: ProPaywallContext?

    init(
        repo: Repo,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        headerSourceBadge: RepoDetailHeaderSourceBadge? = nil,
        showsRepoHealthEntry: Bool = false,
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder trailingActions: () -> TrailingActions
    ) {
        self.repo = repo
        self.fallbackAccentColor = fallbackAccentColor
        self.starHelpKey = starHelpKey
        self.headerSourceBadge = headerSourceBadge
        self.showsRepoHealthEntry = showsRepoHealthEntry
        self.onStarTapped = onStarTapped
        self.trailingActions = trailingActions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            descriptionSection
            statsSection
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // hero tint 由 `RepoDetailScaffold` 根节点 `DetailHeroTintBackground` 统一绘制。
        .sheet(isPresented: $showOpenSSFScoreSheet) {
            OpenSSFScoreSheet(repo: repo)
                .appSheetRootEnvironment(dependencies)
        }
        .sheet(isPresented: $showRepoHealthSheet) {
            RepoHealthSheet(repo: repo)
                .appSheetRootEnvironment(dependencies)
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RepoMetadataAvatarButton(repo: repo)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    RepoFullNameCopyButton(repo: repo)

                    OpenSSFInlineBadge(repo: repo) {
                        showOpenSSFScoreSheet = true
                    }

                    // Health 只在 Manage 详情开放；按钮保留可见性，但点击前先过 Pro gate。
                    // 必须是本地已持久化的 starred repo：Health 快照表外键指向 `repos.id`。
                    if showsRepoHealthEntry && repo.hasLocalHealthCacheBacking {
                        RepoHealthInlineBadge(repo: repo) {
                            openRepoHealth()
                        }
                    }

                    if let headerSourceBadge, headerSourceBadge.isVisible {
                        RepoDetailHeaderSourceBadgeView(badge: headerSourceBadge)
                    }
                }
                badgeRow
                inlineTopicsRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
            trailingActions
        }
    }

    private func openRepoHealth() {
        guard showsRepoHealthEntry else { return }
        do {
            try dependencies.entitlementGate.requirePro(.repoHealth)
            showRepoHealthSheet = true
        } catch let error as EntitlementGateError {
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
        } catch {
            paywallContext = ProPaywallContext(feature: .repoHealth, message: error.localizedDescription)
        }
    }

    @ViewBuilder
    private var badgeRow: some View {
        HStack(spacing: 10) {
            if repo.isArchived {
                RepoBadgeChip(text: "repo.archived", systemImage: "archivebox", tint: .orange)
            }
            if repo.isFork {
                RepoBadgeChip(text: "repo.fork", systemImage: "tuningfork", tint: .gray)
            }
            if repo.isPrivate {
                RepoBadgeChip(text: "repo.private", systemImage: "lock.fill", tint: .purple)
            }
            RepoRawBadgeChip(
                text: repo.license.flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                } ?? "N/A",
                systemImage: "scale.3d",
                tint: .secondary
            )
        }
        .lineLimit(1)
        .frame(minHeight: 18, maxHeight: 18, alignment: .leading)
    }

    @ViewBuilder
    private var inlineTopicsRow: some View {
        let topics = repo.topicsArray
        let topicText = topics.isEmpty ? "N/A" : topics.joined(separator: "  ·  ")
        HStack(spacing: 6) {
            Text("repoTopics.label")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
            Text(topicText)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(topics.isEmpty ? Color.secondary : Color.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: topics.isEmpty ? "N/A" : topics.joined(separator: ", ")))
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = repo.description, !desc.isEmpty {
            Text(desc)
                .font(interfaceScale.font(.body))
                .textSelection(.enabled)
        }
    }

    private var statsSection: some View {
        HStack(alignment: .center, spacing: 24) {
            // R-01 §3.2.3 状态机：StarStatChipButton 封装 idle / loading /
            // shake / error-flash 4 状态。已 star → ⭐ 实心黄；未 star →
            // ☆ 空心灰；API 进行中 → ProgressView；失败 → 抖动 + 短暂红色。
            StarStatChipButton(
                isStarred: repo.isStarred,
                count: repo.starsCount,
                ghRepoId: repo.id,
                helpKey: starHelpKey,
                action: onStarTapped
            )
            .gettingStartedAnchor(.unstarRepo)

            Button {
                if let url = URL(string: "\(repo.htmlUrl)/fork") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                // Forks 用 StatSemanticColor.fork 蓝(light/dark 双主题),
                // 与 SearchCenter 详情卡 fork 配色同源,详情页与其他 stat 形成视觉差。
                RepoStatItem(
                    label: "repo.forks",
                    value: repo.forksCount,
                    systemImage: "tuningfork",
                    tint: StatSemanticColor.fork.resolved(colorScheme: colorScheme)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("repo.forkAction")

            WatchersMenu(repo: repo)

            RepoDateStatItem(label: "repo.created", value: repo.createdAt, systemImage: "calendar.badge.plus")
            RepoDateStatItem(label: "repo.updated", value: repo.updatedAt, systemImage: "clock.arrow.circlepath")
            // v2.0(2026-06-12,dong4j 反馈)：原本独立成段的 Releases 订阅区被压缩为这一列紧凑 stat,
            // 与 Stars / Forks / Watchers / Created / Updated 同行展示。详见
            // `Starcat/Features/Releases/RepoReleaseSection.swift` 文件头 v2.0 演化说明。
            RepoReleaseStatItem(repo: repo)
        }
    }
}

/// README 滚动时可折叠的 repo 元信息容器。
///
/// 这个组件抽离自 Manage 详情页，Activity repo-backed 详情直接复用同一测高 / 折叠动画。
/// 关键约束：内容始终留在 view tree 中，只动画外层 frame 高度，避免 WKWebView 在同一帧
/// 突然重新分配高度造成跳变。
struct CollapsibleRepoMetadataPanel<Content: View>: View {
    @Binding var collapseProgress: CGFloat
    @Binding var panelHeight: CGFloat
    private let content: Content

    init(
        collapseProgress: Binding<CGFloat>,
        panelHeight: Binding<CGFloat>,
        @ViewBuilder content: () -> Content
    ) {
        _collapseProgress = collapseProgress
        _panelHeight = panelHeight
        self.content = content()
    }

    var body: some View {
        let progress = normalizedProgress
        let measuredHeight = panelHeight > 0 ? panelHeight : nil
        let visibleHeight = measuredHeight.map { $0 * (1 - progress) }

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                content
                Divider()
                    .opacity(1 - progress)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RepoMetadataPanelHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .opacity(1 - progress)
            .offset(y: -min(panelHeight * 0.18, 28) * progress)
            .allowsHitTesting(progress < 0.98)
            .accessibilityHidden(progress >= 0.98)
        }
        .frame(
            height: visibleHeight,
            alignment: .top
        )
        .clipped()
        .onPreferenceChange(RepoMetadataPanelHeightPreferenceKey.self) { height in
            guard height > 0, abs(height - panelHeight) > 0.5 else { return }
            panelHeight = height
        }
    }

    /// 折叠进度由 WebView scroll offset 连续驱动，必须在容器内再 clamp 一次。
    ///
    /// 原因：外部调用方会在 repo 切换、滚动回弹、测试注入等路径写入状态；这里兜底可避免
    /// frame 高度出现负数或超过自然高度，保证 WKWebView 重新分配空间时没有异常跳变。
    private var normalizedProgress: CGFloat {
        min(max(collapseProgress, 0), 1)
    }
}

private struct RepoMetadataPanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RepoDetailHeaderSourceBadgeView: View {
    let badge: RepoDetailHeaderSourceBadge
    @Environment(\.openURL) private var openURL
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Group {
            if let url = badge.url {
                Button {
                    openURL(url)
                } label: {
                    content
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover()
            } else {
                content
            }
        }
        .help(helpText)
    }

    private var content: some View {
        HStack(spacing: 4) {
            if !badge.sources.isEmpty {
                HStack(spacing: -4) {
                    ForEach(Array(badge.sources.prefix(4).enumerated()), id: \.offset) { _, source in
                        sourceIcon(source)
                    }
                }
            } else if let systemImage = badge.systemImage {
                Image(systemName: systemImage)
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let label = badge.label, !label.isEmpty {
                Text(label)
                    .font(interfaceScale.font(.code, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        }
    }

    private var helpText: String {
        if let help = badge.help, !help.isEmpty {
            return help
        }
        return badge.sources.map(\.presentation.displayName).joined(separator: " / ")
    }

    @ViewBuilder
    private func sourceIcon(_ source: WeeklySource) -> some View {
        if let assetName = source.presentation.assetName {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        } else {
            Image(systemName: source.presentation.systemImage)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
    }
}

/// 详情 hero 的 `owner/repo` 标题：拆成 owner + repo 两段，视觉拼接成一个完整名称。
///
/// - owner 段（`RepoOwnerSegment`）：点击弹 owner 卡片，并带关注胶囊；
/// - repo 段：点击把整个 fullName 写入剪贴板（保留旧「点全名复制」行为）。
///
/// 为什么拆分：dong4j 2026-09-02 要求 owner 名单独可点、弹 owner 卡片，同时 repo 名
/// 仍保留复制语义。绿勾始终占 14pt、未复制时透明，避免 1.5s 反馈把同行徽章挤开。
private struct RepoFullNameCopyButton: View {
    let repo: Repo

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            RepoOwnerSegment(owner: repo.owner)

            Text(verbatim: "/")
                .font(interfaceScale.font(.workspaceTitle))
                .foregroundStyle(.secondary)

            repoCopySegment
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    /// repo 名段：点击复制整个 fullName，绿勾在行末。
    private var repoCopySegment: some View {
        CopyFeedbackButton(
            providesContent: { repo.fullName },
            tooltip: "repo.hero.copyName"
        ) { didCopy in
            HStack(spacing: 6) {
                Text(verbatim: repo.name)
                    .font(interfaceScale.font(.workspaceTitle))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    // Button 默认按 intrinsic width 布局，长仓库名会把同行徽章挤出
                    // hero；minWidth 0 才允许在 HStack 里按尾部截断。
                    .frame(minWidth: 0, alignment: .leading)

                Image(systemName: "checkmark.circle.fill")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.green)
                    .opacity(didCopy ? 1 : 0)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(!didCopy)
            }
        }
        .pressableHover(scale: 1.0)
        .frame(minWidth: 0, alignment: .leading)
        .accessibilityLabel(Text("repo.hero.copyName"))
        .accessibilityValue(Text(verbatim: repo.fullName))
    }
}

/// hero `owner/repo` 的 owner 段：owner 名 + 关注胶囊，点击弹 owner 卡片。
///
/// 关注胶囊是纯状态展示（不可点击，关注操作在 `OwnerCardSheet` 内）：已关注显示绿色
/// 「已关注」、未关注显示淡色「关注」、未登录不显示（无法判断关注状态）。isFollowing
/// 在挂载时按需查询（登录态才查；公开 owner 的 profile 无需登录）。
private struct RepoOwnerSegment: View {
    let owner: String

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @State private var showOwnerCard = false
    @State private var isFollowing: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showOwnerCard = true
            } label: {
                Text(verbatim: owner)
                    .font(interfaceScale.font(.workspaceTitle))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover(scale: 1.0)
            .help("repo.owner.card.help")

            if let isFollowing {
                if isFollowing {
                    // 已关注：纯状态展示，不可点击（取消关注在 owner 卡片内操作）。
                    followingBadge(true)
                } else {
                    // 未关注：「关注」胶囊是可点击入口，点击弹 owner 卡片完成关注。
                    Button {
                        showOwnerCard = true
                    } label: {
                        followingBadge(false)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pressableHover(scale: 1.0)
                    .help("repo.owner.card.help")
                }
            }
        }
        .sheet(isPresented: $showOwnerCard) {
            OwnerCardSheet(ownerLogin: owner)
                .appSheetRootEnvironment(dependencies)
        }
        .task(id: owner) {
            await loadFollowing()
        }
    }

    @ViewBuilder
    private func followingBadge(_ following: Bool) -> some View {
        HStack(spacing: 3) {
            if following {
                Image(systemName: "checkmark.circle.fill")
                Text("repo.owner.followingBadge")
            } else {
                Image(systemName: "person.badge.plus")
                Text("repo.owner.follow")
            }
        }
        .font(interfaceScale.font(.captionSmall, weight: .semibold))
        .foregroundStyle(following ? Color.green : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill((following ? Color.green : Color.secondary).opacity(0.12))
        }
    }

    private func loadFollowing() async {
        guard authSession.state.isAuthenticated else { return }
        if let following = try? await dependencies.ownerFollowService.isFollowing(login: owner) {
            isFollowing = following
        }
    }
}

struct RepoMetadataAvatarButton: View {
    let repo: Repo

    var body: some View {
        Button {
            if let url = RepoExternalLinks.repo(repo) {
                NotificationCenter.default.post(name: .gettingStartedDidOpenRepoHomepage, object: nil)
                NSWorkspace.shared.open(url)
            }
        } label: {
            RemoteAvatar(
                urlString: RepoAvatarURL.from(owner: repo.owner),
                size: 64
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .gettingStartedAnchor(.repoHomepage)
        .help("repo.openOnGithub")
    }
}

struct RepoAIOpenButton: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
            dependencies.telemetryManager.track(
                .aiPanelOpened,
                properties: [.source: .string("detail")]
            )
            NotificationCenter.default.post(
                name: .repoAIInlineOpenRequested,
                object: nil,
                userInfo: ["repoId": repo.id]
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(interfaceScale.font(.iconSmall, weight: .semibold))
                Text("AI")
                    .font(interfaceScale.font(.body, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [.purple.opacity(0.85), .blue.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text(verbatim: openButtonHelp))
    }

    private var openButtonHelp: String {
        let settings = dependencies.settings
        guard settings.keyboardShortcutsEnabled, settings.selectedRepoAIShortcutEnabled else {
            return String.l10n("ai.assistant.openButton.help.shortcutDisabled")
        }
        return String(
            format: String.l10n("ai.assistant.openButton.help"),
            settings.selectedRepoAIShortcut.displayText
        )
    }
}

/// 仓库分享菜单。
///
/// 基础链接是免费、无登录依赖的主路径；AI 分享是已 Star 仓库可选的增强路径。
/// 两者放在同一个系统分享入口里，避免用户把「复制公开链接」误解为 Pro 能力。
struct RepoShareMenu: View {
    let publicURL: URL
    let isSharing: Bool
    let isShared: Bool
    let canCreateAIShare: Bool
    let createAIShare: () -> Void
    /// 系统菜单点击后会立即关闭，复制成功提示必须交给稳定的页面根节点显示。
    let onLinkCopied: () -> Void

    var body: some View {
        Menu {
            CopyFeedbackButton(
                providesContent: { publicURL.absoluteString },
                tooltip: "repo.share.link.copy.help",
                onCopied: onLinkCopied
            ) { didCopy in
                Label(
                    didCopy ? "common.copy.copied" : "repo.share.link.copy",
                    systemImage: didCopy ? "checkmark.circle.fill" : "link"
                )
                .foregroundStyle(didCopy ? Color.green : Color.primary)
            }

            if canCreateAIShare {
                Divider()
                Button(action: createAIShare) {
                    if isSharing {
                        Label {
                            Text("repo.share.progress.reopen")
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label(
                            isShared ? "repo.share.ai.created" : "repo.share.ai.create",
                            systemImage: isShared ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack"
                        )
                    }
                }
            }
        } label: {
            // macOS 的 Menu 由 AppKit 承载；异步操作期间替换 label 的根视图类型，
            // 可能让 toolbar 复用到空的菜单宿主，因此入口图标必须始终保持稳定。
            ToolbarIcon("square.and.arrow.up.circle")
                .accessibilityLabel(Text("repo.share.button.label"))
        }
        .accessibilityLabel(Text("repo.share.button.label"))
        .help("repo.share.button.help")
    }
}

/// AI 分享任务 Sheet。
///
/// Sheet 只读取 `repoID` 对应的任务，不观察当前列表选择；用户收起后 Task 仍由
/// RepoShareTaskStore 持有，再次点击同一 repo 会恢复当前阶段或最终结果。
struct RepoShareTaskSheet: View {
    let taskStore: RepoShareTaskStore
    let repoID: Int64
    let onCancel: () -> Void
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let job = taskStore.job(for: repoID) {
                VStack(alignment: .leading, spacing: 18) {
                    header(job)
                    content(job)
                    actions(job)
                }
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func header(_ job: RepoShareJob) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RepoShareOwnerAIAvatar(repo: job.repo)

            VStack(alignment: .leading, spacing: 6) {
                Text(titleKey(for: job.state))
                    .font(.title3.weight(.semibold))
                Text(verbatim: job.repo.fullName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitleKey(for: job.state))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            SheetCloseButton(action: { dismiss() })
        }
    }

    @ViewBuilder
    private func content(_ job: RepoShareJob) -> some View {
        switch job.state {
        case .checkingCache, .generatingSummary, .creatingLink:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Label(phaseKey(for: job.state), systemImage: phaseIcon(for: job.state))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

        case .success(let url):
            VStack(alignment: .leading, spacing: 8) {
                Text("repo.share.success.linkLabel")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // 整行都是复制命中区；右侧图标承担 1.5s 绿色成功反馈，不再新增提示行。
                CopyFeedbackButton(
                    providesContent: { url },
                    tooltip: "repo.share.success.copyLink"
                ) { didCopy in
                    HStack(spacing: 10) {
                        Text(verbatim: url)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // 固定布局盒消除两个 Symbol 固有尺寸差异，同时恢复项目统一的
                        // replace 过渡；动画只发生在盒内，不再触发链接行或 Sheet 重排。
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                            .frame(width: 18, height: 18)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }

        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("repo.share.error.reason", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .cancelled:
            Label("repo.share.cancelled.message", systemImage: "xmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func actions(_ job: RepoShareJob) -> some View {
        HStack {
            switch job.state {
            case .checkingCache, .generatingSummary, .creatingLink:
                Button {
                    dismiss()
                } label: {
                    Label("repo.share.progress.hide", systemImage: "rectangle.compress.vertical")
                }

                Spacer()

                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("repo.share.progress.cancel", systemImage: "xmark.circle")
                }

            case .success(let url):
                Button {
                    if let target = URL(string: url) {
                        NSWorkspace.shared.open(target)
                    }
                } label: {
                    Label("repo.share.success.openInBrowser", systemImage: "arrow.up.right.square")
                }

            case .failure:
                Button {
                    onRetry()
                } label: {
                    Label("repo.share.error.retry", systemImage: "arrow.clockwise")
                }

            case .cancelled:
                Button {
                    onRetry()
                } label: {
                    Label("repo.share.cancelled.retry", systemImage: "arrow.clockwise")
                }
            }

            if !job.state.isRunning {
                Spacer()

                Button("repo.share.success.close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func titleKey(for state: RepoShareJob.State) -> LocalizedStringKey {
        switch state {
        case .checkingCache, .generatingSummary, .creatingLink: return "repo.share.progress.title"
        case .cancelled: return "repo.share.cancelled.title"
        case .success: return "repo.share.success.title"
        case .failure: return "repo.share.error.title"
        }
    }

    private func subtitleKey(for state: RepoShareJob.State) -> LocalizedStringKey {
        switch state {
        case .checkingCache, .generatingSummary, .creatingLink: return "repo.share.progress.subtitle"
        case .cancelled: return "repo.share.cancelled.subtitle"
        case .success: return "repo.share.success.subtitle"
        case .failure: return "repo.share.error.subtitle"
        }
    }

    private func phaseKey(for state: RepoShareJob.State) -> LocalizedStringKey {
        switch state {
        case .checkingCache: return "repo.share.progress.checkingCache"
        case .generatingSummary: return "repo.share.progress.generatingSummary"
        case .creatingLink: return "repo.share.progress.creatingLink"
        case .cancelled, .success, .failure: return "repo.share.progress.creatingLink"
        }
    }

    private func phaseIcon(for state: RepoShareJob.State) -> String {
        switch state {
        case .checkingCache: return "tray.and.arrow.down"
        case .generatingSummary: return "sparkles"
        case .creatingLink, .success, .failure: return "link"
        case .cancelled: return "xmark.circle"
        }
    }
}

/// 分享 Sheet 左上角身份：仓库 owner 头像 + 右下角 AI sparkles 角标。
///
/// 为什么不用原来的纯色 sparkles 圆：窗口标题已经写明「AI 分享页」，主图应锚定
/// 具体仓库，而不是再放一个泛化 AI 图标。owner 头像走 `RemoteAvatar` / Kingfisher，
/// 命中列表与详情 hero 已有的内存 / 磁盘缓存，不额外打 GitHub API。
///
/// 角标只表达「这是 AI 能力」，不随任务阶段变色；阶段信息由标题和中间进度条承担。
/// 尺寸与 Activity 行 `avatarWithKindBadge` 同比例（头像约 1/3），避免抢 owner 识别。
private struct RepoShareOwnerAIAvatar: View {
    let repo: Repo

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteAvatar(
                urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                size: 48
            )

            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.gradient))
                .overlay(
                    Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
                )
                .offset(x: 2, y: 2)
                .accessibilityHidden(true)
        }
    }
}

private struct RepoBadgeChip: View {
    let text: LocalizedStringKey
    let systemImage: String
    let tint: Color
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(interfaceScale.font(.captionSmall))
            Text(text).font(interfaceScale.font(.captionSmall))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// `full_name` 同行的 OpenSSF Scorecard 入口。
///
/// 入口本身在所有详情页可见；这里只读本地缓存，不触发 OpenSSF 网络请求。
/// OpenSSF 数据由后台 poller 慢速补齐，避免多数无 Scorecard 的 repo 在详情首屏放大卡顿。
private struct OpenSSFInlineBadge: View {
    let repo: Repo
    let onTap: () -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let badge = dependencies.openSSFScoreStore.badge(for: repo.id)

        Button(action: onTap) {
            if let badge {
                OpenSSFScoreBadge(score: badge, size: .regular)
            } else {
                fallbackBadge
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("openssf.badge.help")
        .task(id: repo.id) {
            guard repo.hasLocalHealthCacheBacking else { return }
            await dependencies.openSSFScoreStore.loadCachedScores(for: [repo.id])
        }
    }

    private var fallbackBadge: some View {
            Image(systemName: "checkmark.shield.fill")
            .font(interfaceScale.font(.captionSmall, weight: .semibold))
            .foregroundStyle(OpenSSFScoreBadge.iridescentForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.accentColor.opacity(0.22), lineWidth: 0.5)
            }
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// `full_name` 同行的 Repo Health 总评分入口。
///
/// 它故意不复用 OpenSSFScoreBadge：OpenSSF 是单一安全维度，Health 是聚合评分。
/// 两者视觉需要相近但语义不同，避免用户误认为 Health 分就是 OpenSSF 分。
///
/// v1.1（2026-06-21，dong4j 反馈"列表 row 也加 Health badge"）：
/// 提取公共 `RepoHealthBadge` 后，详情页只保留两个职责——
/// 1) 缓存命中时复用公共 `RepoHealthBadge` 渲染分数胶囊；
/// 2) 缓存未命中时显示 `fallbackBadge`（占位 icon + 渐变前景），引导用户点击。
/// 列表 row 不需要 fallback——`RepoHealthStore.badge(for:)` 在无缓存时返回 nil，
/// `UnifiedRepoRow` 短路不渲染。
private struct RepoHealthInlineBadge: View {
    let repo: Repo
    let onTap: () -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let badge = dependencies.repoHealthStore.badge(for: repo.id)

        Button(action: onTap) {
            if let badge {
                RepoHealthBadge(data: badge)
            } else {
                fallbackBadge
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repoHealth.action.open")
        .task(id: repo.id) {
            guard repo.hasLocalHealthCacheBacking else { return }
            await dependencies.repoHealthStore.loadCachedSnapshots(for: [repo.id])
        }
    }

    /// 缓存未命中时的占位胶囊。
    /// 详情页独有：Pro 用户即使没缓存也能看到入口，点了触发 Pro gate / 自动补算。
    /// 列表场景不需要这种"占位"——`asCardData(healthBadge: nil)` 直接不显示 row badge。
    private var fallbackBadge: some View {
            Image(systemName: "gauge.with.dots.needle.67percent")
            .font(interfaceScale.font(.captionSmall, weight: .semibold))
            .foregroundStyle(Self.healthForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.accentColor.opacity(0.22), lineWidth: 0.5)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private static let healthForeground = LinearGradient(
        colors: [.green, .teal, .blue, .orange],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private extension Repo {
    /// Repo Health 是 `repo_health_snapshots -> repos.id` 的派生缓存，只有本地
    /// `repos` 表已有持久化行的 repo 才能写入。
    ///
    /// 不能再用 `isStarred` 当作本地缓存 backing 的代理：已加入知识库但未 star 的 repo
    /// 同样会先写入 `repos` metadata，并且应该允许手动刷新 Repo Health / OpenSSF。
    /// `cachedAt == nil` 的 repo 仍可能是 Trending / Weekly / backend hint 构造的
    /// ephemeral 展示对象，不能拿来建快照。
    var hasLocalHealthCacheBacking: Bool {
        id > 0 && cachedAt != nil
    }
}

private struct RepoRawBadgeChip: View {
    let text: String
    let systemImage: String
    let tint: Color
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(interfaceScale.font(.captionSmall))
            Text(verbatim: text).font(interfaceScale.font(.captionSmall))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct RepoStatItem: View {
    let label: LocalizedStringKey
    let value: Int
    let systemImage: String
    let tint: Color
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(interfaceScale.font(.bodyEmphasis))
                Text(value, format: .number)
                    .monospacedDigit()
                    .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
            }
            Text(label)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RepoDateStatItem: View {
    let label: LocalizedStringKey
    let value: String?
    let systemImage: String
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        // dong4j 2026-06-12 反馈:hero stats 行字号要统一。
        // 主行字号原为 12pt（理由是 yyyy-MM-dd 字符串较长,12pt 让列宽更紧凑）,
        // 但与同行其它 stat（Stars / Forks / Watchers / Releases 主行均 14pt）不一致,视觉割裂。
        // 现统一升 14pt,代价是 Created / Updated 列宽各增加约 12pt;
        // 若详情页中栏被挤压到放不下 6 列,后续可改用更短的格式（如 yy-MM-dd 或本地化 short style）来缩列宽,
        // 而不要回退字号。
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(interfaceScale.font(.bodyEmphasis))
                Text(repoDateStatLabel(from: value))
                    .monospacedDigit()
                    .lineLimit(1)
                    .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
            }
            Text(label)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
    }

}

/// 把 GitHub ISO 8601 时间转换成详情页统计行使用的短日期。
///
/// Awesome 会先把服务端时间解析成 `Date`，再通过带毫秒的 formatter 写回 DTO；
/// 因此这里必须同时兼容 `...56Z` 与 `...56.000Z`，不能使用只接受前一种格式的默认解析器。
func repoDateStatLabel(from value: String?) -> String {
    guard let date = ISO8601DateFormatter.githubDate(from: value) else {
        return "-"
    }
    return date.formatted(.iso8601.year().month().day())
}
