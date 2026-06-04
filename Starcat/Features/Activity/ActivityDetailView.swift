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

    let item: ActivityItem?

    /// Activity 详情页自持一个 README ViewModel。
    ///
    /// 不复用 HomeView 注入给 Manage / Trending 的 ReadmeViewModel，是为了避免
    /// Activity 里点星标 / 仓库 / 建议活动时污染右侧主详情页的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    var body: some View {
        Group {
            if let item {
                if shouldShowReadme(for: item), item.repo != nil {
                    repoBackedDetailPage(item)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header(item)
                            Divider()
                            detailBody(item)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                emptyState
            }
        }
        .task(id: readmeLoadKey(for: item)) {
            await loadReadmeIfNeeded(for: item)
        }
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

    private func repoBackedDetailPage(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    Divider()
                    detailBody(item)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Divider()

            if let repo = item.repo {
                activityReadmeSection(repo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func activityReadmeSection(_ repo: Repo) -> some View {
        if let readmeVM {
            ReadmeStateView(
                state: readmeVM.state,
                baseURL: URL(string: repo.htmlUrl),
                owner: repo.owner,
                repo: repo.name,
                onScrollOffsetChange: { _ in }
            ) {
                readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
            } onLogin: {
                authSession.signIn()
            }
            .environment(readmeVM)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
                    .fill(LanguageColor.color(for: item.accentLanguage).opacity(0.18))
                Image(systemName: item.category.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LanguageColor.color(for: item.accentLanguage))
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
