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
/// ### `showLocalSections` 开关（2026-06-08 引入，Weekly 详情页用）
///
/// 默认 `true`：渲染 `RepoTagsSection` / `RepoNotesSection` / `RepoReleaseSection` 这三个
/// **强依赖本地 `repo.id`** 的区块（用 id 查 tags / notes / release_subscriptions）。
///
/// Weekly 详情页**未命中本地**时（用户没 star 过这个项目），会传入一个 `id=0` 的临时 Repo，
/// 此时必须显式把 `showLocalSections` 设为 `false`，否则：
/// - `RepoTagsSection` / `RepoNotesSection` 会用 id=0 去查 DB → 拿不到任何数据，但会显示空 section
///   占位（"添加标签" / "无笔记"等），误导用户以为可以操作；
/// - `RepoReleaseSection` 的"订阅"按钮会用 id=0 注册订阅，破坏 release_subscriptions 表的语义。
///
/// 调用方约定：
/// - Manage 详情页（`RepoDetailView.metadataHeader`）→ 不传，走默认 `true`；
/// - Activity-Suggestion/Repo/Star 详情页（`ActivityDetailView.repoBackedDetailPage`）→ 不传，走默认 `true`；
/// - Weekly 详情页 → 本地命中传 `true`、未命中传 `false`。
struct RepoMetadataHeaderView<TrailingActions: View>: View {
    let repo: Repo
    let fallbackAccentColor: Color
    let onStarTapped: () -> Void
    /// 是否渲染需要本地 `repo.id` 的三个区块（Tags / Notes / Release）。详见类型级注释。
    let showLocalSections: Bool
    /// Stars stat 按钮的 tooltip 本地化键。
    ///
    /// Manage / Activity 详情页：默认 `"repo.unstar"`（用户已 star，点击取消）。
    /// Weekly 详情页未命中本地（用户未 star）：传 `"weekly.detail.openStargazers"`（点击跳 stargazers 页面）。
    /// 这是为了让 tooltip 与实际 `onStarTapped` 闭包做的事保持一致，避免误导。
    let starHelpKey: LocalizedStringKey
    private let trailingActions: TrailingActions

    init(
        repo: Repo,
        fallbackAccentColor: Color = .accentColor,
        showLocalSections: Bool = true,
        starHelpKey: LocalizedStringKey = "repo.unstar",
        onStarTapped: @escaping () -> Void,
        @ViewBuilder trailingActions: () -> TrailingActions
    ) {
        self.repo = repo
        self.fallbackAccentColor = fallbackAccentColor
        self.showLocalSections = showLocalSections
        self.starHelpKey = starHelpKey
        self.onStarTapped = onStarTapped
        self.trailingActions = trailingActions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            descriptionSection
            statsSection
            if showLocalSections {
                RepoTagsSection(repo: repo)
                RepoNotesSection(repo: repo)
                RepoReleaseSection(repo: repo)
            }
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
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(repo.fullName)
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
            Button(action: onStarTapped) {
                RepoStatItem(label: "repo.stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help(starHelpKey)

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
                Text("分享")
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
        .help("分享 Repo")
        .alert("分享成功", isPresented: $showSharePopup) {
            Button("复制链接") {
                if let url = shareUrl {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
            Button("在浏览器打开") {
                if let urlString = shareUrl, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("关闭", role: .cancel) {}
        } message: {
            Text(shareUrl ?? "")
        }
        .alert("分享失败", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("重试") {
                Task { await shareRepo() }
            }
            Button("取消", role: .cancel) {}
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
