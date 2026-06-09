//
//  ActivityDetailView.swift
//  Starcat
//
//  Activity 页右侧详情。
//
//  每种活动的详情字段不同，因此这里按 `ActivityKind` 分支渲染，而不是把 Activity
//  伪装成 Repo 后塞回 `RepoDetailView`。Release 详情复用 `ReleaseRecord` 与 assets_json；
//  Star / Repository / Suggestion 则展示本地 Repo 元数据和跳转入口。
//

import SwiftUI
import AppKit

struct ActivityDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    let item: ActivityItem?

    /// Activity 详情页自持一个 README ViewModel。
    ///
    /// 不复用 HomeView 注入给 Manage / Trending 的 ReadmeViewModel，是为了避免
    /// Activity 里点星标 / 仓库 / 建议活动时污染右侧主详情页的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    // R-01 §3.2.3 / §5.4：原 `repoMetadataPanelCollapseProgress` / `repoMetadataPanelHeight`
    // / `showUnstarConfirm` / `unstarError` / `isUnstarring` 状态已迁移：
    // - Hero 折叠由 `RepoDetailScaffold` 内部状态管理
    // - star/unstar 走 `StarActionService`（无 confirm，失败仅日志）

    var body: some View {
        Group {
            if let item {
                if shouldShowReadme(for: item), item.repo != nil {
                    repoBackedDetailPage(item)
                } else {
                    ScrollView {
                        activityMetadataPanel(item)
                    }
                    .detailScrollViewStyle()
                }
            } else {
                emptyState
            }
        }
        .task(id: readmeLoadKey(for: item)) {
            await loadReadmeIfNeeded(for: item)
        }
    }

    /// Activity 详情顶部面板。
    ///
    /// Manage / Trending 详情页顶部都有“语言色 → 透明”的 hero 背景，用来让当前选择
    /// 和右侧详情形成同一视觉锚点。Activity 没有统一的 repo 模型，因此直接使用
    /// `ActivityItem.accentColor`：有 repo 主语言时取语言色，没有语言标识时回退分类色。
    private func activityMetadataPanel(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(item)
            Divider()
            detailBody(item)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            activityGradientBackground(for: item)
        }
    }

    /// Activity 详情 hero 区渐变背景。
    ///
    /// 透明度与 `RepoDetailView.metadataGradientBackground(language:)` 保持一致：
    /// 顶部 0.18、底部 0，既能表达当前卡片的 accent，又不会干扰正文 / README 阅读。
    @ViewBuilder
    private func activityGradientBackground(for item: ActivityItem) -> some View {
        let tint = item.accentColor
        LinearGradient(
            colors: [tint.opacity(0.18), tint.opacity(0.0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private func header(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            leadingIconButton(item, size: 48)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: item.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    MetaBadge(systemImage: item.category.systemImage, text: item.category.localizedTitle, tint: .secondary)
                    if let date = item.createdAt {
                        RelativeDateBadge(date: date)
                    }
                    if let repo = item.repo, let language = repo.language, !language.isEmpty {
                        LanguageBadge(language: language, style: .full)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func detailBody(_ item: ActivityItem) -> some View {
        switch item.kind {
        case .announcement:
            announcementDetail(item)
        case .release:
            releaseDetail(item)
        case .star:
            repoDetail(item, titleKey: "activity.detail.starTitle")
        case .repository:
            repoDetail(item, titleKey: "activity.detail.repositoryTitle")
        case .following:
            announcementDetail(item)
        case .suggestion:
            repoDetail(item, titleKey: "activity.detail.suggestionTitle")
        }
    }

    private func announcementDetail(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let body = item.body {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    private func releaseDetail(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let release = item.release {
                VStack(alignment: .leading, spacing: 8) {
                    Label(release.tagName, systemImage: "tag.fill")
                        .font(.headline)

                    if let body = release.bodyTruncated, !body.isEmpty {
                        Text(body)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    let assets = ReleaseAssetCodec.decode(release.assetsJson)
                    if !assets.isEmpty {
                        Divider()
                        Text("activity.detail.assets")
                            .font(.headline)
                        ForEach(assets) { asset in
                            assetRow(asset)
                        }
                    }
                }
            } else if let body = item.body {
                Text(body)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }

    private func repoDetail(_ item: ActivityItem, titleKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleKey)
                .font(.headline)

            if let repo = item.repo {
                if let description = repo.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    StarsBadge(count: repo.starsCount, style: .full)
                    MetaBadge(systemImage: "tuningfork", text: repo.forksCount.formattedShort, tint: .secondary)
                    MetaBadge(systemImage: "eye", text: repo.watchersCount.formattedShort, tint: .secondary)
                    if repo.isArchived {
                        ArchivedBadge()
                    }
                }

                if !repo.topicsArray.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("activity.detail.topics")
                            .font(.headline)
                        ActivityFlowLayout(spacing: 6) {
                            ForEach(repo.topicsArray, id: \.self) { topic in
                                Text(verbatim: topic)
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
            } else if let body = item.body {
                Text(body)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }

    /// R-01 §5.4：Activity-repo-backed 详情迁移到 RepoDetailScaffold + ActivityRepoDetailContent。
    ///
    /// 关键差异（vs Manage 详情）：
    /// - `fallbackAccentColor` 用 activity category 色（无语言时回退分类色，与 Manage 不同）
    /// - star/unstar 失败仅打日志，UI 不弹 alert（dong4j Q5-A 决策）
    /// - 旧 `repoMetadataPanelCollapseProgress/Height` 状态不再使用——Scaffold 自管
    @ViewBuilder
    private func repoBackedDetailPage(_ item: ActivityItem) -> some View {
        if let repo = item.repo, let readmeVM {
            RepoDetailScaffold(
                repo: repo,
                viewData: RepoDetailViewData(
                    hero: RepoDetailHero(repo: repo),
                    trailingActions: [.share, .ai],
                    translation: ReadmeTranslationContext(fullName: repo.fullName),
                    backendHint: nil
                ),
                fallbackAccentColor: item.category.iconColor,
                onStarTapped: {
                    Task {
                        do {
                            try await dependencies.starActionService.unstar(repo: repo)
                        } catch {
                            AppLog.sync.error("activity detail unstar failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            ) { onScrollOffset in
                ActivityRepoDetailContent(
                    repo: repo,
                    onScrollOffset: onScrollOffset
                )
                .environment(readmeVM)
            }
        } else if item.repo != nil {
            // readmeVM 还没异步初始化好（loadReadmeIfNeeded 需要一帧建出来）→ 占位
            VStack(spacing: 10) {
                ProgressView()
                Text("readme.loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func assetRow(_ asset: ReleaseAsset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: assetIcon(asset.name))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: asset.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            CopyFeedbackButton(
                providesContent: { asset.browserDownloadUrl },
                tooltip: "releases.copyDownloadLink"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .foregroundStyle(didCopy ? Color.green : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }

            if let url = URL(string: asset.browserDownloadUrl) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("releases.downloadAsset")
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("activity.detail.emptyTitle")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("activity.detail.emptySubtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func leadingIconButton(_ item: ActivityItem, size: CGFloat) -> some View {
        if let url = targetURL(for: item) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                leadingIconImage(item, size: size)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("activity.openOnGitHub")
        } else {
            leadingIconImage(item, size: size)
        }
    }

    @ViewBuilder
    private func leadingIconImage(_ item: ActivityItem, size: CGFloat) -> some View {
        if let repo = item.repo {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: size)
        } else {
            ZStack {
                Circle()
                    .fill(item.accentColor.opacity(0.18))
                Image(systemName: item.category.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(item.accentColor)
            }
            .frame(width: size, height: size)
        }
    }

    private func targetURL(for item: ActivityItem) -> URL? {
        if let url = item.htmlURL {
            return url
        }
        if let repo = item.repo {
            return RepoExternalLinks.repo(repo)
        }
        return nil
    }

    private func shouldShowReadme(for item: ActivityItem) -> Bool {
        switch item.kind {
        case .star, .repository, .suggestion:
            return true
        case .announcement, .release, .following:
            return false
        }
    }

    private func readmeLoadKey(for item: ActivityItem?) -> String {
        guard let item, shouldShowReadme(for: item), let repo = item.repo else {
            return "none"
        }
        return "\(item.kind.rawValue):\(repo.id):\(authSession.state.isAuthenticated)"
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        let model = ReadmeViewModel(api: dependencies.readmeAPI)
        readmeVM = model
        return model
    }

    private func loadReadmeIfNeeded(for item: ActivityItem?) async {
        guard let item, shouldShowReadme(for: item), let repo = item.repo else {
            readmeVM?.reset()
            return
        }
        ensureReadmeViewModel().load(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
    }

    // R-01 §3.2.3：performUnstar / errorAlertBinding 已迁移到 StarActionService 单点
    //（onStarTapped 闭包内调 `dependencies.starActionService.unstar(repo:)`，
    //  无 confirm，失败仅日志）。

    private func assetIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".dmg") { return "internaldrive" }
        if lower.hasSuffix(".pkg") { return "shippingbox.fill" }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "doc.zipper" }
        if lower.hasSuffix(".exe") || lower.hasSuffix(".msi") { return "pc" }
        if lower.hasSuffix(".deb") || lower.hasSuffix(".rpm") || lower.hasSuffix(".appimage") { return "terminal" }
        if lower.hasSuffix(".app") { return "macwindow" }
        return "doc"
    }
}

/// 简单横向自动换行布局，专用于 Activity 详情里的 topics。
///
/// `RepoTagsSection` 也有一个 private FlowLayout，但 private 类型不能跨文件复用；
/// 这里保留一份小而独立的实现，避免为了一个详情页 tag 列表把共享层继续扩大。
private struct ActivityFlowLayout: Layout {
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
