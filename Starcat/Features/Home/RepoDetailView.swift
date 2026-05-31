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
//  - 元信息卡片默认在顶部展示，README 区域占满剩余高度独立滚动
//  - README 向下滚动后收起元信息卡片，把阅读空间还给内容；回到顶部再展开
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
    // W4 B1：取消 star 需要的依赖
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession

    // W4 B1：取消 star 流程的 UI 状态
    @State private var showUnstarConfirm: Bool = false
    @State private var isUnstarring: Bool = false
    @State private var unstarError: String?

    // W4 B2：Clone URL 复制 → Toast 提示
    @State private var toastMessage: String?

    /// README 向下滚动时折叠顶部信息面板。
    ///
    /// 这里用 Bool 而不是把 offset 存成状态，是为了避免 WebView 每个滚动像素都触发
    /// SwiftUI 重绘；只有跨过阈值时才改变布局。
    @State private var isMetadataPanelHidden: Bool = false

    var body: some View {
        if let repo = viewModel.selectedRepo {
            VStack(alignment: .leading, spacing: 0) {
                if !isMetadataPanelHidden {
                    metadataHeader(repo)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                        .transition(.opacity)
                }
                readmeSection(repo)
            }
            .navigationTitle(repo.name)
            .navigationSubtitle(repo.owner)
            .animation(.easeInOut(duration: 0.18), value: isMetadataPanelHidden)
            .toolbar {
                // W4 B3：GitHub 页面快捷入口（替换原单一"在 GitHub 打开"按钮）
                ToolbarItem(placement: .primaryAction) {
                    externalLinksMenu(repo: repo)
                }
                // W4 B2：Clone URL 复制
                ToolbarItem(placement: .primaryAction) {
                    cloneMenu(repo: repo)
                }
                // W4 B1：Unstar 按钮（destructive）
                ToolbarItem(placement: .primaryAction) {
                    unstarButton
                }
            }
            // W4 B2：Toast 浮层（统一复制提示）
            .toast(message: $toastMessage, icon: "doc.on.clipboard")
            .alert("取消 Star？", isPresented: $showUnstarConfirm, presenting: repo) { repo in
                Button("取消 Star", role: .destructive) {
                    Task { await performUnstar(repo: repo) }
                }
                Button("不取消", role: .cancel) {}
            } message: { repo in
                Text("将通过 GitHub API 取消对 \(repo.fullName) 的 star，并从本地列表移除。\n打过的标签和写过的笔记会保留，重新 star 后即可恢复。")
            }
            .alert("取消失败", isPresented: errorAlertBinding, presenting: unstarError) { _ in
                Button("好") { unstarError = nil }
            } message: { msg in
                Text(msg)
            }
            .onChange(of: repo.id) { _, _ in
                isMetadataPanelHidden = false
            }
        } else {
            emptyState
        }
    }

    // MARK: - W4 B3：GitHub 页面快捷入口

    /// 详情页 toolbar "在 GitHub 打开" Menu。
    ///
    /// 默认动作：点击主按钮 → 打开 repo 主页（保留 B3 之前的"一键到 GitHub"语义）
    /// 下拉子项：Issues / Pulls / Releases / Homepage（若有）
    @ViewBuilder
    private func externalLinksMenu(repo: Repo) -> some View {
        Menu {
            if let issues = RepoExternalLinks.issues(repo) {
                Button {
                    NSWorkspace.shared.open(issues)
                } label: {
                    Label("Issues", systemImage: "exclamationmark.bubble")
                }
            }
            if let pulls = RepoExternalLinks.pulls(repo) {
                Button {
                    NSWorkspace.shared.open(pulls)
                } label: {
                    Label("Pull Requests", systemImage: "arrow.triangle.pull")
                }
            }
            if let releases = RepoExternalLinks.releases(repo) {
                Button {
                    NSWorkspace.shared.open(releases)
                } label: {
                    Label("Releases", systemImage: "tag.circle")
                }
            }
            if let homepage = RepoExternalLinks.homepage(repo) {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("Homepage", systemImage: "house")
                    Text(homepage.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("在 GitHub 打开", systemImage: "safari")
        } primaryAction: {
            // 点击主按钮（不展开菜单）→ 打开 repo 主页
            if let url = RepoExternalLinks.repo(repo) {
                NSWorkspace.shared.open(url)
            }
        }
        .help("点击：打开仓库主页；展开：Issues / Releases / Homepage")
    }

    // MARK: - W4 B2：Clone URL 复制 Menu

    /// 详情页 toolbar 的 "克隆地址" Menu。
    ///
    /// 行为：
    /// - HTTPS 总是可选（GitHub API 必返）
    /// - SSH 仅当 repo.sshUrl 非空时显示
    /// - 复制走 NSPasteboard，触发 Toast
    @ViewBuilder
    private func cloneMenu(repo: Repo) -> some View {
        Menu {
            if let https = repo.cloneUrl, !https.isEmpty {
                Button {
                    copy(https, success: "已复制 HTTPS 地址")
                } label: {
                    Label("HTTPS", systemImage: "globe")
                }
                Text(https)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let ssh = repo.sshUrl, !ssh.isEmpty {
                Button {
                    copy(ssh, success: "已复制 SSH 地址")
                } label: {
                    Label("SSH", systemImage: "terminal")
                }
                Text(ssh)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("克隆地址", systemImage: "doc.on.clipboard")
        }
        .help("复制 git clone 地址")
    }

    /// 写 NSPasteboard + 给 Toast 一个文案。
    /// 任何复制功能（包括 B3 即将加的项目链接菜单）都复用此函数。
    private func copy(_ string: String, success: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        toastMessage = success
    }

    // MARK: - W4 B1：Unstar 按钮 + 流程

    @ViewBuilder
    private var unstarButton: some View {
        if isUnstarring {
            ProgressView().controlSize(.small)
        } else {
            Button(role: .destructive) {
                showUnstarConfirm = true
            } label: {
                Label("取消 Star", systemImage: "star.slash")
            }
            .help("从你的 Stars 列表中移除该仓库")
        }
    }

    /// 取消 star 主流程：
    /// 1. 调 GitHub API 远端解除（失败：alert 报错、不动本地）
    /// 2. 调本地 markUnstarred（保留 tag / note，给 re-star 留后路）
    /// 3. 触发 Sidebar + 列表刷新（HomeViewModel 自带 race 防护）
    private func performUnstar(repo: Repo) async {
        guard case .authenticated(let user) = authSession.state else {
            unstarError = "需要登录"
            return
        }
        isUnstarring = true
        defer { isUnstarring = false }
        do {
            try await dependencies.apiClient.unstar(owner: repo.owner, repo: repo.name)
            try await dependencies.repoRepository.markUnstarred(repoId: repo.id, userID: user.id)
            // 刷新 Sidebar 计数 + 列表（reloadItems 内部会清掉已不在列表的 selection）
            await viewModel.refreshSidebar()
            await viewModel.reloadItems()
        } catch {
            unstarError = "取消失败：\(error.localizedDescription)"
            AppLog.sync.error("unstar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 错误 alert 的 isPresented binding —— 让 unstarError 非 nil 时弹窗
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { unstarError != nil },
            set: { if !$0 { unstarError = nil } }
        )
    }

    /// 元信息区域（不滚动，固定在顶部）。
    private func metadataHeader(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(repo)
            descriptionSection(repo)
            statsSection(repo)
            // W4 A3：用户自定义标签段；GitHub topics 已收进 header 的单行信息。
            RepoTagsSection(repo: repo)
            // W4 A4：私有笔记 + 状态段
            RepoNotesSection(repo: repo)
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
            repo: repo.name,
            onScrollOffsetChange: updateMetadataPanelVisibility
        ) {
            readmeVM.reload(repo: repo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// WebView 内部滚动位置 → 顶部信息面板显示状态。
    ///
    /// 24pt 阈值用于避开触控板轻微回弹 / 亚像素抖动：用户明显开始阅读时才折叠，
    /// 回到 README 顶部附近再展开。
    private func updateMetadataPanelVisibility(offsetY: CGFloat) {
        let shouldHide = offsetY > 24
        guard shouldHide != isMetadataPanelHidden else { return }
        isMetadataPanelHidden = shouldHide
    }

    // MARK: - 子段

    private func header(_ repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(repo.fullName)
                badgeRow(repo)
                inlineTopicsRow(repo)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    @ViewBuilder
    private func badgeRow(_ repo: Repo) -> some View {
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
            BadgeChip(
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
    private func inlineTopicsRow(_ repo: Repo) -> some View {
        let topics = repo.topicsArray
        let topicText = topics.isEmpty ? "N/A" : topics.joined(separator: "  ·  ")
        HStack(spacing: 6) {
            Text("Topics")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(topicText)
                .font(.caption)
                .foregroundStyle(topics.isEmpty ? Color.secondary : Color.blue)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(topics.isEmpty ? "N/A" : topics.joined(separator: ", "))
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
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
        HStack(alignment: .center, spacing: 24) {
            StatItem(label: "Stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            StatItem(label: "Forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            StatItem(label: "Watchers", value: repo.watchersCount, systemImage: "eye.fill", tint: .secondary)
            DateStatItem(label: "Created", value: repo.createdAt, systemImage: "calendar.badge.plus")
            DateStatItem(label: "Updated", value: repo.updatedAt, systemImage: "clock.arrow.circlepath")
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

}

// MARK: - README 状态视图

/// 把 ReadmeViewModel.LoadState 翻译为视觉。
///
/// 拆成独立 View 的好处：
/// - 状态切换造成的 view tree 重建只影响这一块，元信息区不受波及
/// - 重试按钮的回调通过闭包传入，保持本组件无副作用
private struct ReadmeStateView: View {

    @Environment(ReadmeViewModel.self) private var readmeVM

    let state: ReadmeViewModel.LoadState
    let baseURL: URL?
    /// 仓库 owner / name —— 透传给 ReadmeWebView 用于图片相对路径重写
    let owner: String
    let repo: String
    let onScrollOffsetChange: (CGFloat) -> Void
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
                    repo: repo,
                    onScrollOffsetChange: onScrollOffsetChange
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
                    .focusEffectDisabled()
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
            Button {
                onRetry()
            } label: {
                if readmeVM.isRefreshing {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(readmeVM.isRefreshing)
            .help("刷新内容")
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

private struct DateStatItem: View {
    let label: String
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
