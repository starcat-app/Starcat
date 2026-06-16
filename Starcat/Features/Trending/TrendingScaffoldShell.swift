//
//  TrendingScaffoldShell.swift
//  Starcat
//
//  R-01「三场景共用架构」Trending 详情页外壳。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2.3 / §5.2 + R-01 v1.2 Phase B3 落地，2026-06-10）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本 view 是 Trending 详情页的「外壳 + 解析层」：
//
//  - 输入：`TrendingRepo`（来自 trending row 选中）
//  - 解析：先查本地 DB（`findByOwnerName`）→ 命中即用本地真值（`isLocalHit = true`），
//    保留 tags / notes / release 三段；未命中退化到 `trending.makeEphemeralRepo()`
//    （`isLocalHit = false`，三段隐藏，star chip 走"重新 star"分支）。
//  - 输出：`RepoDetailScaffold` 渲染 hero + heroExtension（贡献者列）+ trailing
//    actions [.share, .ai] + body slot（`TrendingDetailContent` 的 README）。
//
//  关键约束：
//
//  1. **不与 Manage 主路径污染 README**：`TrendingDetailContent` 使用环境注入的
//     `ReadmeViewModel`（HomeView 持有，Trending / Manage 共用同一实例），但触发
//     `loadTrending()` 走 trending 缓存路径（gh_readmes_trending 而非 gh_readmes），
//     PK = owner/repo 而非 repo_id，不会撞坏 Manage 详情页 SWR 状态。
//
//  2. **Star chip 行为切换**：本地命中 + 已 star → unstar；本地命中 + 未 star（墓碑
//     行）→ 重新 star；未命中 → ephemeral repo 直接 star（成功后 StarActionService
//     会写 DB + 加入 registry，下次重渲染就走"已 star"分支）。
//
//  3. **登录态门控**：未登录用户点击 star chip 走 `authSession.signIn()` 触发设备
//     流登录，不直接跳 GitHub 网页（避免脱离 App）。
//
//  4. **重渲染时机**：`task(id: trending.id)` 保证切换 row 时重新解析；
//     `StarredRegistry` 是 `@Observable`，star/unstar 后整个 view tree 自动刷新，
//     `displayRepo` 会在下一次 onChange 中切换到本地真值。
//

import SwiftUI
import AppKit

/// Trending 场景的详情页外壳。
///
/// - Note: 本 view 单独抽到一个文件而非塞进 `RepoDetailView.swift`，是为了让
///   Trending 详情的解析逻辑（local hit vs ephemeral）与 Manage 详情解耦——
///   `RepoDetailView` 内 trending 分支只负责 `TrendingScaffoldShell(trending:)`
///   一行调用，剩下全交给本 shell。
struct TrendingScaffoldShell: View {

    let trending: TrendingRepo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    /// 当前展示用的 `Repo`：本地命中 → 真值；未命中 → ephemeral（id 可能为 0）。
    @State private var displayRepo: Repo?
    /// 是否本地命中（驱动 hero 三段渲染、star chip 行为）。
    @State private var isLocalHit: Bool = false

    // R-01 §3.2.3 决策（Q2）：unstar **即点即生效，不弹 confirm alert**；
    // API 失败 chip 抖动 + 短暂红色（不弹 toast / alert）。失败仅 AppLog 记日志。
    // → 本 view 不持有 showUnstarConfirm / unstarError 等 @State。

    var body: some View {
        Group {
            if let displayRepo {
                scaffold(for: displayRepo)
            } else {
                // 解析中（极短，loadAll 内同步把 ephemeral repo 推上来；
                // 极端情况下展示 ProgressView，避免空白）。
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: trending.id) {
            await resolveRepo()
        }
    }

    // MARK: - Scaffold 装配

    @ViewBuilder
    private func scaffold(for repo: Repo) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                // R-01 v1.2 Phase B3：trending 详情**仅本地命中（id != 0）才接翻译入口**。
                // 翻译 VM 用 `repo.id` 作缓存键，ephemeral repo（id=0）会撞坏缓存命名空间。
                translation: repo.id != 0 ? ReadmeTranslationContext(fullName: repo.fullName) : nil,
                backendHint: nil
            ),
            // R-01 v1.2 P0：三段渲染已下沉到 Scaffold metadataPanel (RepoLocalSections),
            // hero 不再持有 showLocalSections 概念;**v2.0 修订**(2026-06-10)后可见性
            // 绑 `Repo.isStarred`(本地 DB `is_starred` 列的内存镜像)。
            //
            // tooltip 与 onStarTapped 行为对齐(**v2.0 修订**):用 `repo.isStarred`
            // 派生 —— `resolveRepo()` 步骤 1 命中本地后 displayRepo 就是含真值
            // isStarred 的本地 row,步骤 2 ephemeral 显式 isStarred=false。已 star
            // 显示「取消 star」;未 star 显示「star」。**`StarActionService.toggle`
            // 内部用 `repo.isStarred || registry.contains(...)` 兜住「刚 star 完
            // displayRepo 还是旧 ephemeral」的瞬间 stale 问题**(详见
            // `StarringSubsystem.swift` v2.0 修订段)。
            starHelpKey: repo.isStarred ? "repo.unstar" : "trending.star",
            onStarTapped: {
                try await handleStarTapped(repo: repo)
            },
            heroExtension: {
                TrendingContributorsSection(contributors: trending.contributors)
            },
            body: { onScrollOffset in
                TrendingDetailContent(repo: repo, onScrollOffset: onScrollOffset)
            }
        )
    }

    /// trailing actions(**v2.0 修订**, 2026-06-10):
    /// - **未登录** → 空数组(未登录态下分享/AI 都不应展示);
    /// - 已登录 + **未 star** → 空数组(`Repo.isStarred=false`):v9 之后 trending
    ///   row 自带 ghRepoId,ephemeral repo 满足 `repo.id != 0` 但 `isStarred=false`,
    ///   守卫绑 `repo.isStarred` 直接拦住 AI 按钮 → 不会撞 `ai_summaries(repo_id=ghRepoId)`
    ///   FK 失败;
    /// - 已登录 + **已 star** → `[.share, .ai]`(share / ai 都依赖 repos 表里有
    ///   repo.id,已 star 即保证 repos 表里已写入)。
    ///
    /// **v2.0 从 v1.7 的 `starredRegistry.contains(...)` 回归**:registry async
    /// bootstrap + SyncManager 304 早退会让 contains 在启动期返 false,改用
    /// `Repo.isStarred` 直接读本地 DB 列(`resolveRepo` 命中本地时含真值,
    /// ephemeral 显式 false)。star/unstar 后 `handleStarTapped` 会调 `resolveRepo()`
    /// 重新解析,trailingActions 自动重计算。
    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        guard repo.isStarred else {
            return []
        }
        // v2.0（2026-06-16, dong4j）：OpenSSF 入口迁移到 hero `full_name` 同行，
        // 不再放在 trailing actions 数组里。
        var actions: [RepoDetailAction] = []
        if authSession.state.isAuthenticated {
            actions.append(.share)
            actions.append(.ai)
        }
        return actions
    }

    // MARK: - Repo 解析

    /// 决定 `displayRepo` 与 `isLocalHit`。
    ///
    /// 步骤：
    /// 1. 查本地 DB（`findByOwnerName`）→ 命中返回 `(local, true)`，三段段渲染；
    /// 2. 未命中 → 退化到 `trending.makeEphemeralRepo()`，`isLocalHit = false`；
    ///
    /// **不调 GitHub `/repos`**：与 `WeeklyDetailView.resolveRepo` 不同，trending
    /// row 自带 v1.2 14 字段（owner_avatar / subscribers / default_branch /
    /// open_issues 等），构造 ephemeral repo 已能让 hero 完整渲染。再调 API 既冗
    /// 余也消耗 rate limit。后续若需要更多字段（如 license），把字段补到
    /// `StarcatRepoCardDTO` v1.x 而非在视图层 fetch。
    private func resolveRepo() async {
        do {
            if let local = try await dependencies.repoRepository.findByOwnerName(
                owner: trending.owner,
                name: trending.name
            ) {
                displayRepo = local
                isLocalHit = true
                return
            }
        } catch {
            AppLog.sync.error("trending: local repo lookup failed: \(error.localizedDescription, privacy: .public)")
            // 继续 fallback，不阻塞
        }

        displayRepo = trending.makeEphemeralRepo()
        isLocalHit = false
    }

    // MARK: - Star / Unstar 协调

    /// hero ⭐/☆ chip 点击(**v2.0 修订**, 2026-06-10, R-01 §3.2.3 / Q1 / Q2 / N1 / N2):
    ///
    /// 与 manage / weekly / activity 完全同构——`StarActionService.toggle(repo:)`
    /// 内部按 `repo.isStarred || registry.contains(ghRepoId:)` 任一为 true 派生
    /// star / unstar 分支(**v2.0 折中**:既稳定信任 `Repo.isStarred` 主路径,又
    /// 用 registry 兜住「刚 star 完 displayRepo 还是 ephemeral」的瞬间 stale)。
    ///
    /// - 已 star → 直接 unstar(不弹 confirm,§3.2.3 / Q2)
    /// - 未 star → 直接 star(`star(owner:repo:)` 内部完成 PUT + GET /repos + DB upsert,
    ///   ephemeral repo / 本地墓碑行 / 完全未命中三种情形通吃)
    /// - 未登录 → `authSession.signIn()` 触发设备流后**不抛错 return**(chip
    ///   不抖动,这不是失败语义)
    /// - API 抛错 → 直接重新抛出让 `StarStatChipButton` 触发抖动 + 短暂红色 600ms
    ///   (不弹 toast / alert)
    ///
    /// 注意签名是 `async throws`:throws 不再 catch 写日志,由 chip 统一处理失败反馈
    /// (chip 内部 catch 后会调 AppLog.sync.error)。
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        // ─────────────────────────────────────────────────────────────────
        // D-22 followup(2026-06-11, 详见 §6.3 D-24):
        // toggle 完成后先**用 registry 派生 isStarred 显式更新 displayRepo**,
        // 再走 sidebar / list 刷新 + resolveRepo。
        //
        // 为什么不能只靠 resolveRepo:
        // - resolveRepo 步骤 1 调 findByOwnerName(owner:name:)。trending 这条
        //   path 一般能命中(owner/name 来自 GitHub Trending HTML, 与 DB 真值
        //   大小写一致), 但 weekly 路径源自阮一峰周刊 markdown 解析,大小写
        //   不规范时不命中 → 退化到 GitHub API → 新 Repo 又是 isStarred=false,
        //   导致 hero 永远不实心。本次为三个详情页(trending/weekly/activity)
        //   统一加这条 registry-derived 兜底,语义一致 + 抗 owner/name 漂移。
        // - registry 是 toggle 内部 `_add`/`_remove` 的同步真值源(@MainActor
        //   @Observable, 同步内存写入), toggle await 返回后 registry 已是新真值。
        //
        // Repo 是 value type 且 `var isStarred: Bool` 可写,直接 copy + 覆值即可。
        // resolveRepo() 后续会再次覆盖 displayRepo(合回本地完整字段,如 topics /
        // license / forksCount 等), isStarred 不变(本地真值与 registry 同步)。
        // ─────────────────────────────────────────────────────────────────
        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
        await resolveRepo()
    }
}
