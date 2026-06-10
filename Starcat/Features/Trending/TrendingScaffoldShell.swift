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
            // R-01 v1.2 P0：三段渲染已下沉到 ContentView (RepoLocalSections)，
            // hero 不再持有 showLocalSections 概念；可见性由 RepoLocalSections
            // 内部根据 repo.id != 0 自动判定。
            //
            // tooltip 与 onStarTapped 行为对齐：已 star 显示「取消 star」；
            // 未 star（无论本地墓碑行还是 ephemeral）显示「star」。
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

    /// trailing actions：
    /// - 本地命中（id != 0）→ `[.share, .ai]`（与 Manage 详情页对齐，share / ai 都依赖 repo.id）
    /// - 未命中（ephemeral, id == 0）→ 空数组（share 走 AI 摘要缓存键 = repo.id，ephemeral
    ///   会撞坏；ai 也类似。trending hero 上方已有「在 GitHub 查看」入口承接外链需求）。
    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        repo.id != 0 ? [.share, .ai] : []
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

    /// hero ⭐/☆ chip 点击（**严格按 R-01 §3.2.3 / Q1 / Q2 / N1 / N2 决策**）：
    ///
    /// - 已 star（本地命中且 isStarred = true）→ **直接 unstar，不弹 confirm**
    /// - 未 star（本地墓碑行 / 本地未命中 ephemeral）→ 直接 star
    /// - 未登录 → `authSession.signIn()` 触发设备流后**不抛错 return**（chip
    ///   不抖动，因为这不是失败语义）
    /// - API 抛错 → 直接重新抛出让 `StarStatChipButton` 触发抖动 + 短暂红色
    ///   600ms（不弹 toast / alert）
    ///
    /// 注意签名是 `async throws`：throws 不再 catch 写日志，由 chip 统一处理
    /// 失败反馈（chip 内部 catch 后会调 AppLog.sync.error）。
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }

        if repo.isStarred {
            try await dependencies.starActionService.unstar(repo: repo)
        } else {
            _ = try await dependencies.starActionService.star(owner: repo.owner, repo: repo.name)
        }

        // 成功后强制刷 sidebar / list，让 manage 列表 row 状态同步；
        // 本 view 重新解析一次切到本地真值（hero 三段开启 / 关闭）。
        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
        await resolveRepo()
    }
}
