//
//  RepoDetailView.swift
//  Starcat
//
//  右栏：仓库详情。
//
//  Week 3：基础元信息卡片（头像、名称、描述、stats、topics、外链）。
//  Week 4：接入 README WebView 渲染 + ETag 缓存。
//
//  布局策略：
//  - 元信息卡片固定在顶部（不滚动），README 区域占满剩余高度独立滚动
//  - 这样长 README 不会把 stats 推到屏幕外，用户始终能看到 stars 数等关键指标
//
//  设计约束：
//  - 无选中行时显示空态
//  - "Open on GitHub" 按钮：用 NSWorkspace 打开外部浏览器，不在沙盒内嵌
//  - README 加载通过 ReadmeViewModel 协调（由 HomeView 持有并通过 .onChange 驱动）
//
//  状态归属：
//  - HomeViewModel：列表 / sidebar / selectedRepo（环境注入）
//  - ReadmeViewModel：README 加载状态机（环境注入；HomeView 持有）
//  - 本 view 自身无状态
//

import SwiftUI
import AppKit

struct RepoDetailView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(ReadmeViewModel.self) private var readmeVM

    var body: some View {
        if let repo = viewModel.selectedRepo {
            VStack(alignment: .leading, spacing: 0) {
                metadataHeader(repo)
                Divider()
                readmeSection(repo)
            }
            .navigationTitle(repo.name)
            .navigationSubtitle(repo.owner)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openOnGitHub(url: repo.htmlUrl)
                    } label: {
                        Label("在 GitHub 打开", systemImage: "safari")
                    }
                }
            }
        } else {
            emptyState
        }
    }

    /// 元信息区域（不滚动，固定在顶部）。
    private func metadataHeader(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(repo)
            descriptionSection(repo)
            statsSection(repo)
            topicsSection(repo)
            // W4 A3：用户自定义标签段，紧贴 GitHub topics 之后
            RepoTagsSection(repo: repo)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// README 区域。占据剩余高度，由 WebView 自己处理滚动。
    ///
    /// 把 `owner` / `name` 透传给 ReadmeWebView 用于图片相对路径重写
    /// （GitHub HTML render 端点对原生 `<img src="./xx">` 不做绝对化，
    /// 必须客户端补一次 raw URL 改写）。
    private func readmeSection(_ repo: Repo) -> some View {
        ReadmeStateView(
            state: readmeVM.state,
            baseURL: URL(string: repo.htmlUrl),
            owner: repo.owner,
            repo: repo.name
        ) {
            readmeVM.reload(repo: repo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 子段

    private func header(_ repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if repo.isArchived {
                        BadgeChip(text: "Archived", systemImage: "archivebox", tint: .orange)
                    }
                    if repo.isFork {
                        BadgeChip(text: "Fork", systemImage: "tuningfork", tint: .gray)
                    }
                    if repo.isPrivate {
                        BadgeChip(text: "Private", systemImage: "lock.fill", tint: .purple)
                    }
                    if let license = repo.license {
                        BadgeChip(text: license, systemImage: "scale.3d", tint: .secondary)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func descriptionSection(_ repo: Repo) -> some View {
        if let desc = repo.description, !desc.isEmpty {
            Text(desc)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func statsSection(_ repo: Repo) -> some View {
        HStack(spacing: 24) {
            StatItem(label: "Stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            StatItem(label: "Forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            StatItem(label: "Watchers", value: repo.watchersCount, systemImage: "eye.fill", tint: .secondary)
        }
    }

    @ViewBuilder
    private func topicsSection(_ repo: Repo) -> some View {
        let topics = repo.topicsArray
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Topics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("未选中仓库")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("从左侧列表选择一个查看详情")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 外链

    private func openOnGitHub(url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - README 状态视图

/// 把 ReadmeViewModel.LoadState 翻译为视觉。
///
/// 拆成独立 View 的好处：
/// - 状态切换造成的 view tree 重建只影响这一块，元信息区不受波及
/// - 重试按钮的回调通过闭包传入，保持本组件无副作用
private struct ReadmeStateView: View {

    let state: ReadmeViewModel.LoadState
    let baseURL: URL?
    /// 仓库 owner / name —— 透传给 ReadmeWebView 用于图片相对路径重写
    let owner: String
    let repo: String
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("加载 README…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let html, let cachedAt):
            VStack(spacing: 0) {
                ReadmeWebView(
                    htmlFragment: html,
                    baseURL: baseURL,
                    owner: owner,
                    repo: repo
                )
                cacheFooter(cachedAt: cachedAt)
            }

        case .empty:
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("该仓库没有 README")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("仓库作者可能尚未添加 README.md")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("加载 README 失败")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("重试", action: onRetry)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 缓存时间脚注，便于用户判断是否需要手动刷新。
    private func cacheFooter(cachedAt: Date) -> some View {
        HStack {
            Image(systemName: "clock")
                .font(.caption2)
            Text("缓存于 \(cachedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
            Spacer()
            Button("刷新", action: onRetry)
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
    }
}

// MARK: - 小组件

/// 通用胶囊徽章；命名避开 `Tag`（与 Core/Database/Models/Tag 冲突）。
private struct BadgeChip: View {
    let text: String
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

private struct StatItem: View {
    let label: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(value, format: .number).monospacedDigit()
            }
            .font(.system(size: 16, weight: .medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - FlowLayout（Topics 自动换行）

/// 简易 Flow 布局：左到右排列，超出宽度换行。
/// 用 SwiftUI 原生 `Layout` 协议实现，避免依赖第三方。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
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
