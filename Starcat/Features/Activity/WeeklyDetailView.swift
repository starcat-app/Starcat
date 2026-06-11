//
//  WeeklyDetailView.swift
//  Starcat
//
//  Activity 页 weekly 分类的右侧详情面板。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计目标（R-01 v1.2 Phase B5 重写，2026-06-10）
//  ────────────────────────────────────────────────────────────────────────────
//
//  与 Manage / Trending / Activity-建议/仓库/星标 共用 **同一套** 详情页骨架：
//
//      `RepoDetailScaffold` (Hero + heroExtension + trailingActions + body slot)
//
//  Weekly 场景下：
//  - **trailingActions**：`[.weeklyIssue, .share, .ai]`(Scaffold 内置 weeklyIssue
//    case 渲染 capsule + secondary 描边的「第 N 期」按钮);未 star 时只剩
//    weeklyIssue 一项(share / ai 守卫绑 `StarredRegistry.contains`,见 v1.7 修订)。
//  - **body slot**:`WeeklyDetailContent` 渲染 README WebView(走 trending 缓存路径)
//  - **不接 heroExtension**:weekly 没有 contributors 字段
//
//  ────────────────────────────────────────────────────────────────────────────
//  Repo 解析策略(与 B5 重写前保持一致,逻辑搬到 Scaffold 外)
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. 本地命中(findByOwnerName)→ 用本地真值,hero 三段(tags/notes/release)开启;
//  2. 未命中 → 调 `GET /repos/{owner}/{repo}` 拉完整字段构造临时 Repo(id=0,
//     isStarred=false, **不入库**);
//  3. API 失败 → 用 WeeklyProject 现有字段构造最小 Repo(保证 hero 不白屏)。
//
//  与 B5 之前版本的差异：原 `WeeklyDetailView` 自己持有 `metadataPanelCollapseProgress`
//  / `metadataPanelHeight` + 自写 `CollapsibleRepoMetadataPanel + RepoMetadataHeaderView`
//  的"半骨架";现在折叠 / hero / trailing 全部交给 `RepoDetailScaffold`,本 view 仅
//  保留「Repo 解析 + readmeVM 局部持有 + star/unstar 协调」三块。
//
//  ────────────────────────────────────────────────────────────────────────────
//  关键约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **不复用 HomeView 全局 readmeVM**:与 Activity / Trending Shell 同款做法,本地
//    `@State` 持有,避免周刊详情污染主路径的 README 状态。
//  - **API 调用失败兜底**:网络失败 / 404 时 fallback 到一份"最小 Repo",UI 仍能
//    渲染但部分字段空缺,不至于详情页直接白屏。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.7 修订(2026-06-10, dong4j bug 反馈)
//  ────────────────────────────────────────────────────────────────────────────
//
//  原 `handleStarTapped` 三段式(本地命中-star/unstar / 未命中-跳 stargazers 页面)
//  存在两个问题:
//  ① 与 manage / trending / activity 4 详情页不同构,各家维护一套行为契约;
//  ② 未命中跳 stargazers 是当时 §3.2.6 的妥协方案,但 `StarActionService.star(...)`
//     内部已包含 `PUT /user/starred` + `GET /repos/{o}/{r}` + DB upsert,
//     完全可以直接 star 入自己账户(与 trending 路径相同)。
//
//  v1.7 把 4 详情页的行为契约统一收口到 `StarActionService.toggle(repo:)` +
//  `StarredRegistry.contains(ghRepoId:)`:
//  - **trailingActions**:守卫 `isAuthenticated && registry.contains(...)` 派生
//    `.share` / `.ai` 可见性,与 4 详情页同构;
//  - **starHelpKey**:tooltip 由 registry 派生,删 weekly 独有的「打开 Stargazers
//    页面」case;
//  - **onStarTapped**:无论命中与否都走 toggle,删跳 stargazers 妥协逻辑,
//    weekly 也能直接 star 入自己账户。
//

import SwiftUI
import AppKit

struct WeeklyDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    let project: WeeklyProject?

    /// 局部 README ViewModel；首次有 project 时按需 lazy 构造。
    /// 与 ActivityDetailView / TrendingScaffoldShell 同款做法：周刊详情页不影响 Manage / Trending 主路径的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    /// 当前 project 对应的展示用 `Repo`。
    ///
    /// 加载策略（见 `resolveRepo`）：
    /// 1. 先查本地 DB（owner/name）→ 命中即用，`isLocalHit = true`，开 tags/notes/release；
    /// 2. 未命中 → 调 `GET /repos/{owner}/{repo}` → 临时 Repo（id=0, isStarred=false），`isLocalHit = false`；
    /// 3. API 失败 → 用 `WeeklyProject` 填一份最小 Repo（只有 owner/name/desc/language/stars），`isLocalHit = false`。
    @State private var displayRepo: Repo?
    /// 当前 displayRepo 是否来自本地（决定 tags/notes/release 是否渲染、Star 按钮语义）。
    @State private var isLocalHit: Bool = false
    /// 正在拉 GitHub API（本地未命中走的回源路径）。期间显示加载占位。
    @State private var isFetchingRemote: Bool = false

    // R-01 §3.2.3 决策（Q2）：unstar **即点即生效，不弹 confirm alert**；
    // API 失败 chip 抖动 + 短暂红色（不弹 toast / alert）。失败仅 AppLog 记日志。
    // → 本 view 不持有 showUnstarConfirm / unstarError 等 @State。

    var body: some View {
        Group {
            if let project {
                content(project)
                    .id(project.id)
            } else {
                emptyState
            }
        }
        .task(id: project?.id) {
            await loadAll(for: project)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ project: WeeklyProject) -> some View {
        if let displayRepo, let readmeVM {
            RepoDetailScaffold(
                repo: displayRepo,
                viewData: RepoDetailViewData(
                    hero: RepoDetailHero(repo: displayRepo),
                    trailingActions: trailingActions(for: project, repo: displayRepo),
                    // weekly 详情不接翻译入口（与 trending 详情对齐）。
                    translation: nil,
                    backendHint: nil
                ),
                fallbackAccentColor: ActivityCategory.weekly.iconColor,
                // R-01 v1.5：三段渲染已下沉到 RepoDetailScaffold metadataPanel
                // (RepoLocalSections),**v2.0 起守卫绑 `repo.isStarred` 单一信任源**
                // (从 v1.7 的 `starredRegistry.contains(...)` 回归,详见
                // `RepoLocalSections.swift` v2.0 修订段)。
                //
                // tooltip 同步切换(**v2.0**):已 star 显示「取消 star」,未 star 显示「Star」,
                // 与 onStarTapped(toggle) 行为对齐。
                starHelpKey: starHelpKey(repo: displayRepo),
                onStarTapped: { try await handleStarTapped(repo: displayRepo) },
                body: { onScrollOffset in
                    WeeklyDetailContent(
                        repo: displayRepo,
                        onScrollOffset: onScrollOffset,
                        readmeVM: readmeVM
                    )
                }
            )
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
            // 极端兜底：project 非 nil 但 displayRepo / readmeVM 仍未填好。
            // loadAll 会同步把 fallback minimal repo 推上来，正常路径不应触发。
            EmptyView()
        }
    }

    /// 计算 trailingActions(**v2.0 修订**, 2026-06-10):
    /// - `.weeklyIssue`(周刊期号外链):仅依赖 `firstIssue + issueURL`,与登录态/star 态无关
    ///   (公开 GitHub issue 页面),**保持独立**;
    /// - `.share` / `.ai`:守卫绑 `isAuthenticated && repo.isStarred`,与 4 详情页同构
    ///   (从 v1.7 的 `registry.contains(ghRepoId:)` 回归,理由见
    ///   `RepoLocalSections.swift` v2.0 修订段)。
    /// - 已登录 + 已 star → `[.weeklyIssue, .share, .ai]`(与 Manage 详情对齐 + 周刊期号入口);
    /// - 已登录 + 未 star → `[.weeklyIssue]`(share / ai 守卫拦下);
    /// - 未登录 → 仅 `[.weeklyIssue]`(若有 firstIssue);
    /// - 无 firstIssue 时(极端:trending hint 缺扩展段)→ 移除 `.weeklyIssue` case。
    private func trailingActions(for project: WeeklyProject, repo: Repo) -> [RepoDetailAction] {
        var actions: [RepoDetailAction] = []
        if project.firstIssue > 0, let issueURL = project.issueURL {
            actions.append(.weeklyIssue(number: project.firstIssue, url: issueURL))
        }
        if authSession.state.isAuthenticated, repo.isStarred {
            actions.append(.share)
            actions.append(.ai)
        }
        return actions
    }

    /// hero ⭐/☆ chip 的 tooltip 本地化键(**v2.0 修订**)。
    /// 与 onStarTapped(`StarActionService.toggle`)行为对齐,直接派生自 `repo.isStarred`:
    /// - 已 star → 「取消 star」
    /// - 未 star → 「Star」
    private func starHelpKey(repo: Repo) -> LocalizedStringKey {
        repo.isStarred ? "repo.unstar" : "trending.star"
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
    /// 1a. **优先 findById(displayRepo?.id)** 精确匹配 — 用于 star/unstar 完成后
    ///     第二次 resolveRepo,避开 owner/name 大小写 / 重命名问题(详见 D-24)。
    /// 1b. findById 不命中(displayRepo nil / id=0 fallback / 历史未命中) → 走
    ///     `findByOwnerName(owner:name:)` 兜底。
    /// 2. 全部不命中 → 调 GitHub API,构造临时 Repo;
    /// 3. API 失败 → 用 WeeklyProject 现有字段构造最小 Repo(保证 hero 不白屏)。
    private func resolveRepo(for project: WeeklyProject) async {
        // 1a) 本地查找 — id 精确匹配 优先
        //
        // **D-24 followup**: weekly 项目 owner/name 源自阮一峰周刊 markdown 解析,
        // 偶有大小写不一致(如 `Vercel/swr` vs GitHub 真值 `vercel/swr`)。SQLite
        // 默认 BINARY collation 导致 findByOwnerName 漏掉,而 ghRepoId 全局
        // 唯一且不变,findById 精确命中无大小写陷阱。
        //
        // 触发时机:第二次以后调用 resolveRepo(handleStarTapped 之后),此时
        // displayRepo 已经有真 ghRepoId(来自初次 GitHub API fetch / star 后
        // toggle 同步覆盖)。
        if let id = displayRepo?.id, id > 0 {
            do {
                if let local = try await dependencies.repoRepository.findById(id) {
                    displayRepo = local
                    isLocalHit = true
                    isFetchingRemote = false
                    return
                }
            } catch {
                AppLog.sync.error("weekly: local repo findById(\(id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 1b) findById 未命中 → owner/name 兜底
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

    // MARK: - Star / Unstar 协调（v1.7 修订, 2026-06-10）

    /// Star stat 按钮点击——与 manage / trending / activity 4 详情页**完全同构**。
    ///
    /// `StarActionService.toggle(repo:)` 内部按 `StarredRegistry.contains` 派生 star /
    /// unstar 分支。本地命中 / 未命中 / ephemeral repo 三种情形通吃:
    /// - 已 star(registry 命中)→ unstar
    /// - 未 star(registry 未命中)→ `star(owner:repo:)` 内部完成 PUT + GET /repos +
    ///   DB upsert,即便是未命中的 ephemeral repo 也能直接入自己账户(weekly 也能 star)。
    ///
    /// **v1.7 删除妥协逻辑**:原"未命中跳 stargazers 页面"是当时担心 ephemeral repo
    /// (id=0) 写入污染 starred 集合的妥协;但 `StarActionService.star` 拉 GitHub
    /// `/repos/{o}/{r}` 后用真实 ghRepoId 写库,与 trending 完全同路径,妥协无必要。
    ///
    /// - 未登录 → `authSession.signIn()` 触发设备流,return(chip 不抖)
    /// - API 抛错 → throw 让 `StarStatChipButton` 触发抖动 + 短暂红色 600ms
    ///
    /// 失败由 chip 统一处理(抖动 + 日志),本方法不再 catch 写日志。
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        // ─────────────────────────────────────────────────────────────────
        // D-22 followup(2026-06-11, 详见 §6.3 D-24):
        // toggle 完成后**两步双保险**让 hero star 立即同步真值:
        //
        // 1. 用 registry 派生 isStarred 显式更新 displayRepo —— 第一道防线:
        //    无论 resolveRepo 步骤 1 命中与否, hero 当帧就能拿到新 isStarred。
        //    registry 是 toggle 内部 `_add`/`_remove` 的同步真值源(@MainActor
        //    @Observable, 同步内存写入), toggle await 返回后 registry 已是
        //    新真值,不受 owner/name 解析准确性影响。
        //
        // 2. 再调 resolveRepo(for:) —— 第二道防线:把本地 DB 完整字段(topics /
        //    license / forks / stars 真值)合回 displayRepo。已升级为 `findById`
        //    优先命中(详见 resolveRepo 文档段 D-24 followup 注释),避开
        //    weekly owner/name 大小写不一致漏命中陷阱;命中后 displayRepo
        //    的 isStarred 跟 registry 同步(均为 toggle 真值)。
        //
        // dong4j 2026-06-11 复现:weekly 详情第一次 star 一个 repo 后,卡片立
        // 即变实心(走 sidebar.refreshSidebar / list reload 路径),但 hero 永
        // 远空心直到切换 weekly 项目重建 view 才正常 —— 根因就是上面两步
        // 之前都没做(只调 resolveRepo,且 resolveRepo 走 owner/name 失败 →
        // 退化到 GitHub API → 写 displayRepo.isStarred=false 覆盖了刚刚 star
        // 完的真值)。
        //
        // Repo 是 value type 且 `var isStarred: Bool` 可写,直接 copy + 覆值即可。
        // ─────────────────────────────────────────────────────────────────
        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
        if let project { await resolveRepo(for: project) }
    }

}
