//
//  ActivityDetailView.swift
//  Starcat
//
//  Activity 页右侧详情（外层路由 + non-repo metadataPanel 自绘）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  D-28 v3 重构（2026-06-11，dong4j 反馈"看不到动画 + 4 详情页应该真同构"）
//  ────────────────────────────────────────────────────────────────────────────
//
//  之前 ActivityDetailView 自持 `@State displayRepo` / `@State readmeVM` 等所有
//  解析层 state,导致同分支切换 item 时无法走「shell .id 重建」路径,hero 入场
//  动画无法稳定触发。
//
//  D-28 v3 把 repo-backed 解析层下沉到 `ActivityDetailScaffoldShell`(同款
//  trending / weekly 模式),本 view 简化为「外层路由 + non-repo 自绘
//  metadataPanel + 空态承载」三段:
//
//      ZStack(alignment: .topLeading) {
//          if let item {
//              if shouldShowReadme(for: item), item.repo != nil {
//                  // repo-backed:走共用 shell,与 trending/weekly 同款
//                  ActivityDetailScaffoldShell(item: item)
//                      .id(item.id)                  // ← 关键!外层挂 .id 让 shell 重建
//                      .detailContentTransition()
//              } else {
//                  // non-repo (announcement / release / following):自绘 metadataPanel
//                  ScrollView { activityMetadataPanel(item) }
//                      .detailScrollViewStyle()
//                      .id(item.id)
//                      .detailContentTransition()
//              }
//          } else {
//              emptyState
//                  .id("activity-empty")
//                  .detailContentTransition()
//          }
//      }
//      .animation(.easeOut(duration: 0.4), value: item?.id ?? "activity-empty")
//
//  **关键约束**:
//
//  1. **必须配 ZStack(alignment: .topLeading)**:Group transparent container
//     跨分支切换 transition 不稳定触发。
//
//  2. **shell 外层必须挂 `.id(item.id)`**:这是 D-28 v3 vs v1/v2 的本质差别——
//     shell 重建时 @State 自动重置,与 trending 完全同款行为。同 kind 内切换
//     不同 item(如 star A → star B)也走"轻轻落下"动画,**与 manage 同分支
//     切 repo 体验一致**(Activity item.repo 是本地真值,shell .task 同步设
//     displayRepo,无 API 等待)。
//
//  3. **non-repo 分支也挂 `.id(item.id)`**:让 announcement / release / following
//     之间切换、或同 kind 切 item 时,`activityMetadataPanel` 也走 `.detailContentTransition()`
//     的"轻轻落下"动画,与 repo-backed 分支视觉同构。
//
//  4. **animation key 用 item?.id ?? "empty"**:与外层 .id 同源,两者同帧变化 →
//     SwiftUI 用 0.4s easeOut 包裹 transition 时长。
//
//  ────────────────────────────────────────────────────────────────────────────
//  历史修订全部下沉到 Shell（参考 ActivityDetailScaffoldShell.swift 文件头）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **D-22 全字段 ==**:Shell 内部 displayRepo prop 变化触发 SwiftUI diff
//  - **D-24 registry-derived isStarred**:Shell `handleStarTapped` 同步覆值
//
//  本 view (ActivityDetailView) 只负责:
//  - **路由**:三分支判断(repo-backed shell / non-repo metadataPanel / empty)
//  - **non-repo 自绘**:announcement / release / following 的 hero header +
//    detailBody(announcementDetail / releaseDetail 等)
//  - **入场动画**:外层 ZStack + .id(item.id) + .detailContentTransition() +
//    .animation(value:),让分支切换和同分支 item 切换都走"轻轻落下"
//

import SwiftUI
import AppKit

struct ActivityDetailView: View {

    let item: ActivityItem?

    /// 2026-06-15:外层 0.4s easeOut 包裹的 detail transition 在「关闭应用内动画」
    /// 时降级为瞬切。`.detailContentTransition()` modifier 内部已按 reduceMotion
    /// 兜底为 `.opacity`,这里再守住 .animation 包裹时长 = 0,实现完全瞬切。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item {
                if item.kind == .release, item.repo != nil {
                    // 发行版改为 repo-backed 详情：上半部分复用 RepoDetailScaffold，
                    // 下半部分渲染该 repo 聚合后的 Release notes Markdown 时间线。
                    ActivityReleaseDetailScaffoldShell(item: item)
                        .id(item.id)
                        .detailContentTransition()
                } else if shouldShowReadme(for: item), item.repo != nil {
                    // D-28 v3:repo-backed 走共用 shell(与 trending/weekly 同款 4 详情页同构)。
                    // 外层挂 .id(item.id) 让 shell 重建 → @State 自动重置 →
                    // 配合 .detailContentTransition() 触发"轻轻落下"动画。
                    ActivityDetailScaffoldShell(item: item)
                        .id(item.id)
                        .detailContentTransition()
                } else {
                    // non-repo kind(announcement / release / following / 无 repo 的 corner case):
                    // 自绘 metadataPanel + ScrollView,同样挂 .id(item.id) + .detailContentTransition()
                    // 让切换走"轻轻落下"动画。
                    ScrollView {
                        activityMetadataPanel(item)
                    }
                    .detailScrollViewStyle()
                    .id(item.id)
                    .detailContentTransition()
                }
            } else {
                emptyState
                    .id("activity-empty")
                    .detailContentTransition()
            }
        }
        // 监听 item.id 变化,用 0.4s easeOut 包裹分支 / item 切换的 transition,
        // 让 .detailContentTransition() 的非对称 transition(insertion: opacity + offset y:14
        // / removal: 仅 opacity)在 0.4s 内完成插值 — 视觉上"轻轻落下"。
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: item?.id ?? "activity-empty")
    }

    // MARK: - non-repo 详情自绘（announcement / release / following 等）

    /// Activity 详情顶部面板（non-repo kind 走这条分支）。
    ///
    /// Manage / Trending 详情页顶部都有"语言色 → 透明"的 hero 背景，用来让当前选择
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

                    if let body = release.bodyMarkdown, !body.isEmpty {
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

    // MARK: - 空态

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "tray.full",
            title: "activity.detail.emptyTitle",
            subtitle: "activity.detail.emptySubtitle",
            iconSize: 42,
            spacing: 12
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 图标 / 路由 helper

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
