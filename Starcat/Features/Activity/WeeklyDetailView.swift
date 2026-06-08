//
//  WeeklyDetailView.swift
//  Starcat
//
//  Activity 页 weekly 分类的右侧详情面板（2026-06-08 重写）。
//
//  ## 设计目标
//  与 Manage / Activity-建议/仓库/星标 共用 **同一套** repo-backed 详情页组件：
//  - 顶部：`CollapsibleRepoMetadataPanel` + `RepoMetadataHeaderView`（同 Manage `metadataPanel`）
//  - 底部：`ReadmeStateView` + WebView（同 Activity `activityReadmeSection`）
//  - 唯一差异：trailing actions 多一个"第 N 期"按钮，点击跳到 ruanyf/weekly 原文 issue。
//
//  ## 为什么要 fetch GitHub API
//  周刊推荐的 `WeeklyProject` 只有 7 个字段（owner / name / url / desc / stars / language / firstIssue），
//  缺少 `RepoMetadataHeaderView` 必需的 forks / watchers / topics / license / 时间字段。
//  解决方案：
//  - **本地命中**（用户已 star 过）→ 直接拿本地 `Repo` 行（含完整字段 + Tags/Notes/Release 可用）；
//  - **未命中** → 调一次 `GET /repos/{owner}/{repo}` 拉 `GitHubRepoDTO` → 拼临时 `Repo`（id=0、
//    `isStarred=false`、`cachedAt=now`），传 `showLocalSections: false` 让 Tags/Notes/Release
//    三段不渲染（因为它们要用 `repo.id` 查 DB，id=0 会撞坏 release_subscriptions 之类的本地表）。
//
//  ## 重写前的问题（2026-06-08 前的版本）
//  自造一套 hero（64pt avatar + 小 chip stats + 小 button actions），与 Manage / Activity 视觉
//  完全不一致；没有 README 滚动收起顶部面板；没有 tags/notes/release 入口（即使已 star 的项目）。
//  dong4j 明确要求"完全复用 manage 右侧详情展示页"，本次按此重写。
//
//  ## 关键约束
//  - **不复用 HomeView 全局 readmeVM**：与 ActivityDetailView 同款本地 `@State` 持有，避免周刊
//    详情污染 Manage / Trending / Activity 右侧主详情页的 README 状态。
//  - **未命中时的 onStarTapped**：传"打开 stargazers 页面"而非 unstar/star，避免误操作；tooltip
//    通过 `starHelpKey` 显式说明。本地命中走 Manage 同款 unstar 流程。
//  - **API 调用失败兜底**：网络失败 / 404 时 fallback 到一份"最小 Repo"（只填 weekly 已有字段），
//    UI 仍能渲染但部分字段空缺，不至于详情页直接白屏。
//

import SwiftUI
import AppKit

struct WeeklyDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    let project: WeeklyProject?

    /// 局部 README ViewModel；首次有 project 时按需 lazy 构造。
    /// 与 ActivityDetailView 同款做法：周刊详情页不影响 Manage / Trending 主路径的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    /// 当前 project 对应的展示用 `Repo`。
    ///
    /// 加载策略（见 `loadRepoIfNeeded`）：
    /// 1. 先查本地 DB（owner/name）→ 命中即用，`isLocalHit = true`，开 tags/notes/release；
    /// 2. 未命中 → 调 `GET /repos/{owner}/{repo}` → 临时 Repo（id=0, isStarred=false），`isLocalHit = false`；
    /// 3. API 失败 → 用 `WeeklyProject` 填一份最小 Repo（只有 owner/name/desc/language/stars），`isLocalHit = false`。
    @State private var displayRepo: Repo?
    /// 当前 displayRepo 是否来自本地（决定 tags/notes/release 是否渲染、Star 按钮语义）。
    @State private var isLocalHit: Bool = false
    /// 正在拉 GitHub API（本地未命中走的回源路径）。期间显示加载占位。
    @State private var isFetchingRemote: Bool = false

    // —— 同 Manage / Activity 一致的折叠面板状态 ——
    @State private var metadataPanelCollapseProgress: CGFloat = 0
    @State private var metadataPanelHeight: CGFloat = 0

    // —— 已 star 项目的 unstar 流程（与 RepoDetailView / ActivityDetailView 同款）——
    @State private var showUnstarConfirm: Bool = false
    @State private var unstarError: String?

    private var metadataPanelAnimation: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.9, blendDuration: 0.08)
    }

    var body: some View {
        Group {
            if let project {
                content(project)
                    // .id 触发详情页随选中项目变化的视图重建，避免上一项滚动位置 / readme 残留。
                    .id(project.id)
            } else {
                emptyState
            }
        }
        .task(id: project?.id) {
            await loadAll(for: project)
        }
        .onChange(of: project?.id) { _, _ in
            // 切换项目时把折叠状态重置回展开，与 RepoDetailView.onChange(of: repo.id) 行为对齐。
            withAnimation(metadataPanelAnimation) {
                metadataPanelCollapseProgress = 0
            }
        }
        .alert("repo.unstar.confirm", isPresented: $showUnstarConfirm, presenting: displayRepo) { repo in
            Button("repo.unstar.action", role: .destructive) {
                Task { await performUnstar(repo: repo) }
            }
            Button("repo.unstar.dontUnstar", role: .cancel) {}
        } message: { repo in
            Text(String(format: String(localized: "repo.unstar.messageFormat"), repo.fullName))
        }
        .alert("repo.unstar.failed", isPresented: errorAlertBinding, presenting: unstarError) { _ in
            Button("general.ok") { unstarError = nil }
        } message: { msg in
            Text(LocalizedStringKey(msg))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ project: WeeklyProject) -> some View {
        if let displayRepo {
            VStack(alignment: .leading, spacing: 0) {
                CollapsibleRepoMetadataPanel(
                    collapseProgress: $metadataPanelCollapseProgress,
                    panelHeight: $metadataPanelHeight
                ) {
                    RepoMetadataHeaderView(
                        repo: displayRepo,
                        fallbackAccentColor: ActivityCategory.weekly.iconColor,
                        // 本地命中（已 star）→ 渲染 tags/notes/release，与 Manage 完全一致；
                        // 未命中（临时 repo, id=0）→ 隐藏这三段，避免用 id=0 撞坏本地表。
                        showLocalSections: isLocalHit,
                        // tooltip 同步切换：已 star 显示"取消 Star"，未 star 显示"打开 Stargazers 页面"，
                        // 避免与下方 `onStarTapped` 闭包做的事不一致。
                        starHelpKey: isLocalHit ? "repo.unstar" : "weekly.detail.openStargazers",
                        onStarTapped: { handleStarTapped(repo: displayRepo) }
                    ) {
                        HStack(spacing: 8) {
                            // 第 N 期入口：唯一与 Manage / Activity 不同的 trailing action。
                            // 放在 Share / AI 按钮之前，符合"weekly 标识"应当最显眼的预期。
                            if project.firstIssue > 0 {
                                WeeklyIssueButton(project: project)
                            }
                            // Share / AI 按钮在本地命中时才接得通（Share 需要走 AI 摘要 →
                            // 临时 Repo id=0 会撞坏 AI 摘要缓存）。未命中时只展示 Issue 按钮。
                            if isLocalHit {
                                RepoShareButton(repo: displayRepo)
                                RepoAIOpenButton(repo: displayRepo)
                            }
                        }
                    }
                }

                readmeSection(project)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if isFetchingRemote {
            // 本地未命中、正在拉 GitHub API 的过渡态。
            // 不希望出现"先白屏再 hero"的视觉跳跃，所以用占位 + 半透明 hint，与 README 加载态匹配。
            VStack(spacing: 12) {
                ProgressView()
                Text("weekly.detail.loadingRepo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 极端兜底：project 非 nil 但 displayRepo 仍未填好（理论上不会触发，
            // loadAll 会同步把 fallback minimal repo 推进来）。出现就说明有 race，记日志方便排查。
            EmptyView()
        }
    }

    // MARK: - README

    /// README 区：完全复用 Trending 详情页的 `loadTrending` + `ReadmeStateView` 链路。
    /// 周刊项目同样没有本地 Repo.id，跟 Trending 是同一类"无本地缓存"用例。
    /// 不传 `translationControl`：翻译入口依赖本地 Repo（缓存 / 持久化键都是 Repo.id），
    /// 周刊场景没有这条信息，传 nil 让 footer 跳过翻译控件。
    @ViewBuilder
    private func readmeSection(_ project: WeeklyProject) -> some View {
        if let readmeVM {
            ReadmeStateView(
                state: readmeVM.state,
                // 拼接 blob/HEAD：GitHub HTML 渲染 API 返回的相对链接缺少 blob/HEAD 前缀，
                // 补上后相对链接才能正确解析为 https://github.com/owner/repo/blob/HEAD/xxx。
                // 与 RepoDetailView.readmeSection / trendingReadmeSection 保持一致。
                baseURL: URL(string: "\(project.url.absoluteString)/blob/HEAD"),
                owner: project.owner,
                repo: project.name,
                onScrollOffsetChange: updateMetadataPanelVisibility,
                translationControl: nil
            ) {
                readmeVM.loadTrending(
                    owner: project.owner,
                    repo: project.name,
                    isLoggedIn: authSession.state.isAuthenticated
                )
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

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("weekly.detail.emptyTitle")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("weekly.detail.emptySubtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading 协调

    /// 项目切换时一次性触发：repo 元数据 + README。
    /// 顺序：repo 先（带 fallback 兜底，保证 hero 区有东西渲染）→ README 异步并发起。
    private func loadAll(for project: WeeklyProject?) async {
        guard let project else {
            // 切到空选中 → 释放 README 状态，避免上一项的 loading 残留。
            readmeVM?.reset()
            displayRepo = nil
            isLocalHit = false
            isFetchingRemote = false
            return
        }

        await resolveRepo(for: project)
        await loadReadme(for: project)
    }

    /// 决定 `displayRepo` 与 `isLocalHit`。
    ///
    /// 步骤：
    /// 1. 查本地 DB → 命中即返回（保证 tags/notes/release 完整）；
    /// 2. 未命中 → 调 GitHub API；
    /// 3. API 失败 → 用 WeeklyProject 现有字段构造最小 Repo（保证 hero 不白屏）。
    private func resolveRepo(for project: WeeklyProject) async {
        // 1) 本地查找
        do {
            if let local = try await dependencies.repoRepository.findByOwnerName(
                owner: project.owner,
                name: project.name
            ) {
                displayRepo = local
                // local 行可能 isStarred=false（用户取消 star 后的墓碑行）；
                // 此时也算"本地有 repo.id 可用"，tags/notes/release 段照常渲染。
                // Star stat 的 tooltip / 动作仍按 isStarred 真实状态决定。
                isLocalHit = true
                isFetchingRemote = false
                return
            }
        } catch {
            AppLog.sync.error("weekly: local repo lookup failed: \(error.localizedDescription, privacy: .public)")
            // 继续走远端路径，不阻塞
        }

        // 2) 调 GitHub API（仅在视图层手动 fetch；本地仍是单一信任源）
        isFetchingRemote = true
        defer { isFetchingRemote = false }
        do {
            let dto = try await dependencies.apiClient.repo(owner: project.owner, repo: project.name)
            let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
            // 用 GRDBRepoRepository.repoFromDTO + isStarred=false 拼一份临时 Repo；
            // **不入库**：避免污染本地 starred 集合，weekly 列表只是发现入口。
            displayRepo = GRDBRepoRepository.repoFromDTO(
                dto,
                starredAt: nil,
                cachedAt: cachedAt,
                isStarred: false
            )
            isLocalHit = false
            return
        } catch {
            AppLog.network.error("weekly: GitHub /repos fetch failed for \(project.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // 3) 最终兜底：用 WeeklyProject 现有字段构一份最小 Repo，保证 hero 不白屏
        displayRepo = makeFallbackRepo(from: project)
        isLocalHit = false
    }

    /// 从 WeeklyProject 构造一份"最小可用" Repo。
    ///
    /// 仅填 weekly 项目本身就有的字段：fullName / description / language / stars。
    /// forks / watchers / topics / dates 全部留默认值（0 / nil / nil）。
    /// `id = 0` 配合 `showLocalSections: false`，绝不能让此 Repo 进任何写入路径。
    private func makeFallbackRepo(from project: WeeklyProject) -> Repo {
        Repo(
            id: 0,
            owner: project.owner,
            name: project.name,
            fullName: project.fullName,
            description: project.description,
            language: project.language,
            starsCount: project.stars,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: project.url.absoluteString,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: ISO8601DateFormatter.shared.string(from: Date())
        )
    }

    private func loadReadme(for project: WeeklyProject) async {
        let model = ensureReadmeViewModel()
        model.loadTrending(
            owner: project.owner,
            repo: project.name,
            isLoggedIn: authSession.state.isAuthenticated
        )
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        let model = ReadmeViewModel(api: dependencies.readmeAPI)
        readmeVM = model
        return model
    }

    // MARK: - 折叠面板联动

    /// 与 Manage / Activity 同款滚动收缩策略：复用 `RepoDetailView.metadataCollapseProgress(for:)`，
    /// 起步距离、收缩行程、顶部抖动过滤完全一致。
    private func updateMetadataPanelVisibility(offsetY: CGFloat) {
        let progress = RepoDetailView.metadataCollapseProgress(for: offsetY)
        guard abs(progress - metadataPanelCollapseProgress) > 0.01 else { return }
        metadataPanelCollapseProgress = progress
    }

    // MARK: - Star / Unstar 协调

    /// Star stat 按钮点击。
    ///
    /// - **本地命中 + 已 star**：弹 unstar 确认 alert（与 Manage / Activity 完全一致）；
    /// - **本地命中 + 未 star**（用户曾 star 后取消的墓碑行）：调 GitHub API 重新 star，与
    ///   Trending 详情页 star 行为对齐；
    /// - **未命中**（临时 Repo）：打开 GitHub stargazers 页面，给用户看"还有谁 star 了"。
    ///   未来如想做"从 Weekly 直接 star"，需要 star 后回写本地 DB（涉及 sync 流程）。
    private func handleStarTapped(repo: Repo) {
        if isLocalHit {
            if repo.isStarred {
                showUnstarConfirm = true
            } else {
                Task { await performStar(repo: repo) }
            }
        } else {
            let url = URL(string: "\(repo.htmlUrl)/stargazers") ?? URL(string: repo.htmlUrl)!
            NSWorkspace.shared.open(url)
        }
    }

    /// 与 Activity / Manage 详情页 unstar 流程对齐。
    private func performUnstar(repo: Repo) async {
        guard case .authenticated(let user) = authSession.state else {
            unstarError = "auth.needLogin"
            return
        }
        do {
            try await dependencies.apiClient.unstar(owner: repo.owner, repo: repo.name)
            try await dependencies.repoRepository.markUnstarred(repoId: repo.id, userID: user.id)
            await homeViewModel.refreshSidebar()
            await homeViewModel.reloadItems(forceRefresh: true)
            // 取消 star 后本地 isStarred 改 false；重新查一次保证 UI 状态最新。
            if let project { await resolveRepo(for: project) }
        } catch {
            unstarError = "repo.unstar.actionFailed"
            AppLog.sync.error("weekly unstar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 本地有但已取消 star → 重新 star。
    /// 调远端 star → 等下一次全量同步把 isStarred=true 写回；当下手动刷新一次本地 repo。
    private func performStar(repo: Repo) async {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }
        do {
            try await dependencies.apiClient.star(owner: repo.owner, repo: repo.name)
            await homeViewModel.reloadItems(forceRefresh: true)
            if let project { await resolveRepo(for: project) }
        } catch {
            unstarError = "repo.star.failed"
            AppLog.sync.error("weekly star failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { unstarError != nil },
            set: { if !$0 { unstarError = nil } }
        )
    }
}

// MARK: - Issue Button

/// 第 N 期跳转按钮。
///
/// 视觉与 Manage / Activity 详情页右上角的 `RepoShareButton` / `RepoAIOpenButton` 一致——
/// capsule + secondary 描边 + secondary 文字，避免在 hero 里出现独立色调引起视觉割裂。
/// 内部图标用 `newspaper` 与列表行 / sidebar 周刊分类一致。
private struct WeeklyIssueButton: View {
    let project: WeeklyProject

    var body: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "newspaper")
                    .font(.system(size: 13, weight: .semibold))
                Text(String(format: String(localized: "weekly.issueLabelFormat"), project.firstIssue))
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
        .help("weekly.detail.openIssue")
    }

    /// 优先开周刊原文 issue 页；缺 issueURL 时退化到仓库 URL，避免点击无响应。
    private func open() {
        if let url = project.issueURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(project.url)
        }
    }
}
