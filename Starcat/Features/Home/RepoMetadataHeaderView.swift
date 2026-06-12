//
//  RepoMetadataHeaderView.swift
//  Starcat
//
//  Repo 详情顶部元信息面板的公共组件。
//
//  设计目标：
//  - Manage / Activity 的 repo-backed 详情共享同一套顶部信息结构与交互反馈。
//  - 顶部面板本身不滚动；README WebView 滚动时由外层折叠容器隐藏。
//  - 点击头像、Stats、Watchers、AI、分享等交互统一使用 `.buttonStyle(.plain)`、
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
    private let trailingActions: TrailingActions

    init(
        repo: Repo,
        fallbackAccentColor: Color = .accentColor,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        headerSourceBadge: RepoDetailHeaderSourceBadge? = nil,
        onStarTapped: @escaping () async throws -> Void,
        @ViewBuilder trailingActions: () -> TrailingActions
    ) {
        self.repo = repo
        self.fallbackAccentColor = fallbackAccentColor
        self.starHelpKey = starHelpKey
        self.headerSourceBadge = headerSourceBadge
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
        .background(alignment: .top) {
            RepoMetadataGradientBackground(
                language: repo.language,
                fallbackAccentColor: fallbackAccentColor
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RepoMetadataAvatarButton(repo: repo)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(repo.fullName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(repo.fullName)

                    if let headerSourceBadge, !headerSourceBadge.sources.isEmpty {
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(topicText)
                .font(.caption)
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
                .font(.body)
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

            Button {
                if let url = URL(string: "\(repo.htmlUrl)/fork") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                RepoStatItem(label: "repo.forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("repo.forkAction")

            WatchersMenu(repo: repo)

            RepoDateStatItem(label: "repo.created", value: repo.createdAt, systemImage: "calendar.badge.plus")
            RepoDateStatItem(label: "repo.updated", value: repo.updatedAt, systemImage: "clock.arrow.circlepath")
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
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RepoDetailHeaderSourceBadgeView: View {
    let badge: RepoDetailHeaderSourceBadge
    @Environment(\.openURL) private var openURL

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
            HStack(spacing: -4) {
                ForEach(Array(badge.sources.prefix(4).enumerated()), id: \.offset) { _, source in
                    sourceIcon(source)
                }
            }
            if let label = badge.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
        badge.sources.map(\.displayName).joined(separator: " / ")
    }

    @ViewBuilder
    private func sourceIcon(_ source: WeeklySource) -> some View {
        switch source {
        case .unknown:
            Image(systemName: source.assetName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        default:
            Image(source.assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
    }
}

struct RepoMetadataGradientBackground: View {
    let language: String?
    let fallbackAccentColor: Color

    var body: some View {
        let tint = accentColor
        LinearGradient(
            colors: [tint.opacity(0.18), tint.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var accentColor: Color {
        if let language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return fallbackAccentColor
    }
}

struct RepoMetadataAvatarButton: View {
    let repo: Repo

    var body: some View {
        Button {
            if let url = RepoExternalLinks.repo(repo) {
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
        .help("repo.openOnGithub")
    }
}

struct RepoAIOpenButton: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel

    var body: some View {
        Button {
            RepoAIWindowController.show(
                repo: repo,
                dependencies: dependencies,
                homeViewModel: viewModel
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Text("AI")
                    .font(.system(size: 13, weight: .semibold))
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
        .help("ai.assistant.openButton.help")
    }
}

struct RepoShareButton: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @State private var isSharing = false
    @State private var showSharePopup = false
    @State private var shareUrl: String?
    @State private var shareError: String?

    var body: some View {
        Button {
            Task { await shareRepo() }
        } label: {
            HStack(spacing: 6) {
                if isSharing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text("repo.share.button.label")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.primary)
            .background(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .disabled(isSharing)
        .help("repo.share.button.help")
        .alert("repo.share.success.title", isPresented: $showSharePopup) {
            Button("repo.share.success.openInBrowser") {
                if let urlString = shareUrl, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("repo.share.success.copyLink") {
                if let url = shareUrl {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Button("repo.share.success.close", role: .cancel) {}
        } message: {
            Text(shareUrl ?? "")
        }
        .alert("repo.share.error.title", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("repo.share.error.retry") {
                Task { await shareRepo() }
            }
            Button("repo.share.error.cancel", role: .cancel) {}
        } message: {
            if let error = shareError { Text(error) }
        }
    }

    private func shareRepo() async {
        isSharing = true
        shareError = nil
        defer { isSharing = false }

        do {
            var aiInsight: RepoAIInsight?
            aiInsight = try await dependencies.repoAIInsightService.cachedInsight(for: repo)
            if aiInsight == nil {
                let result = try await dependencies.repoAIInsightService.generateInsight(for: repo)
                aiInsight = result.insight
            }

            guard let insight = aiInsight else { return }

            let shareRepoDTO = ShareRepoDTO(
                fullName: repo.fullName,
                description: repo.description,
                language: repo.language,
                starsCount: repo.starsCount,
                forksCount: repo.forksCount,
                topics: repo.topicsArray,
                homepage: repo.homepage,
                url: repo.htmlUrl
            )

            let shareTagDTOs = insight.suggestedTags.map { ShareTagDTO(name: $0.name, confidence: $0.confidence) }
            let shareAISummaryDTO = ShareAISummaryDTO(
                oneLiner: insight.oneLiner,
                summary: insight.summary,
                platforms: insight.platforms,
                suitableFor: insight.suitableFor,
                strengths: insight.strengths,
                risks: insight.risks,
                suggestedTags: shareTagDTOs
            )

            let request = ShareRepoRequest(repo: shareRepoDTO, aiSummary: shareAISummaryDTO)
            // 2026-06-08：从 environment 注入的 `dependencies.shareAPI` 取共享实例，
            // 不再每次分享 new 一个；端点配置统一走 `AppEndpoints.sharing`，
            // 本地联调改 env `STARCAT_SHARING_API_URL` 即可切到 127.0.0.1。
            let response = try await dependencies.shareAPI.shareRepo(request: request)

            shareUrl = response.shareUrl
            showSharePopup = true
        } catch {
            shareError = error.localizedDescription
        }
    }
}

private struct RepoBadgeChip: View {
    let text: LocalizedStringKey
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct RepoRawBadgeChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(verbatim: text).font(.caption2)
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

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 14))
                Text(value, format: .number)
                    .monospacedDigit()
                    .font(.system(size: 14, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RepoDateStatItem: View {
    let label: LocalizedStringKey
    let value: String?
    let systemImage: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(formattedDate)
                    .monospacedDigit()
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(label)
                .font(.system(size: 10))
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
