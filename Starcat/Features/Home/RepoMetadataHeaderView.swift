//
//  RepoMetadataHeaderView.swift
//  Starcat
//
//  Repo 详情顶部元信息面板的公共组件。
//
//  设计目标：
//  - Manage / Activity 的 repo-backed 详情共享同一套顶部信息结构与交互反馈。
//  - 顶部面板本身不滚动；README WebView 滚动时由外层折叠容器隐藏。
//  - 点击头像、Stats、Watchers、AI 等 hero 内交互统一使用 `.buttonStyle(.plain)`、
//    `.focusEffectDisabled()` 和 `.pressableHover()`，避免不同页面出现不同 hover / focus 体验。
//

import SwiftUI
import TipKit
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
                    Text(repo.fullName)
                        .font(interfaceScale.font(.workspaceTitle))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(repo.fullName)

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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
            dependencies.telemetryManager.track(
                .aiPanelOpened,
                properties: [.source: .string("detail")]
            )
            RepoAIWindowController.show(
                repo: repo,
                dependencies: dependencies,
                homeViewModel: viewModel,
                openSettings: openSettings
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
        .gettingStartedPopoverTip(GettingStartedTips.ai)
        .help("ai.assistant.openButton.help")
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

    var body: some View {
        Menu {
            CopyFeedbackButton(
                providesContent: { publicURL.absoluteString },
                tooltip: "repo.share.link.copy.help"
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
                            Text("repo.share.ai.create")
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
                .disabled(isSharing)
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

struct RepoShareSheetItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case success(String)
        case failure(String)
    }

    let id = UUID()
    let kind: Kind

    static func success(_ url: String) -> RepoShareSheetItem {
        RepoShareSheetItem(kind: .success(url))
    }

    static func failure(_ message: String) -> RepoShareSheetItem {
        RepoShareSheetItem(kind: .failure(message))
    }
}

struct RepoShareResultSheet: View {
    let item: RepoShareSheetItem
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            actions
        }
        .padding(22)
        .frame(width: 430)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(headerTint.gradient)
                    .frame(width: 48, height: 48)
                    .shadow(color: headerTint.opacity(0.25), radius: 16, x: 0, y: 8)
                Image(systemName: headerIcon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(titleKey)
                    .font(.title3.weight(.semibold))
                Text(subtitleKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .success(let url):
            VStack(alignment: .leading, spacing: 8) {
                Text("repo.share.success.linkLabel")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: url)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                if didCopy {
                    Label("repo.share.success.copied", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
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
        }
    }

    private var actions: some View {
        HStack {
            switch item.kind {
            case .success(let url):
                Button("repo.share.success.copyLink") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    didCopy = true
                }
                Button("repo.share.success.openInBrowser") {
                    if let target = URL(string: url) {
                        NSWorkspace.shared.open(target)
                    }
                }
            case .failure:
                Button("repo.share.error.retry") {
                    dismiss()
                    onRetry()
                }
            }

            Spacer()

            Button("repo.share.success.close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    private var titleKey: LocalizedStringKey {
        switch item.kind {
        case .success: return "repo.share.success.title"
        case .failure: return "repo.share.error.title"
        }
    }

    private var subtitleKey: LocalizedStringKey {
        switch item.kind {
        case .success: return "repo.share.success.subtitle"
        case .failure: return "repo.share.error.subtitle"
        }
    }

    private var headerIcon: String {
        switch item.kind {
        case .success: return "link.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var headerTint: Color {
        switch item.kind {
        case .success: return .accentColor
        case .failure: return .orange
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
                Text(formattedDate)
                    .monospacedDigit()
                    .lineLimit(1)
                    .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
            }
            Text(label)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
    }

    private var formattedDate: String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
