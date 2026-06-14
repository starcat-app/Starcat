//
//  ActivityDetailScaffoldShell.swift
//  Starcat
//
//  R-01「三场景共用架构」Activity 详情页 repo-backed 外壳（D-28 v3，2026-06-11）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（dong4j 2026-06-11 反馈："4 详情页应该真同构,照搬 trending 模式"）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本 view 是 Activity 详情页 **repo-backed kind**(`.star` / `.repository` /
//  `.suggestion`,且 `item.repo != nil`)的「外壳 + Repo 解析层」,与
//  `TrendingScaffoldShell` / `WeeklyDetailScaffoldShell` 同款架构。
//
//  R-01 §5.4 把 Activity-repo-backed 渲染层迁到 `RepoDetailScaffold` 共用骨架,
//  但**外壳没拆**——`ActivityDetailView` 自持 `@State displayRepo` /
//  `@State readmeVM`,导致同分支切换 item 时无法走「shell .id 重建」路径,
//  hero 入场动画无法稳定触发。这是 D-28 v1/v2 修复未果的根因。
//
//  D-28 v3 把 Activity-repo-backed 拆成两层(对齐 Trending 模式):
//  - **ActivityDetailScaffoldShell**(本文件)— 持有 `@State displayRepo` /
//    `@State readmeVM`,输入仅 `let item: ActivityItem`(必传 repo-backed item,
//    且 `item.repo != nil` 已由调用方守卫)。外层挂 `.id(item.id)` 时整个
//    shell 重建,@State 自动重置 + .task(id:) 立即跑同步路径同步推 displayRepo →
//    第二帧有内容 → 配合 `.detailContentTransition()` 触发"轻轻落下"。
//  - **ActivityDetailView**(外层简化)— 三分支路由(repo-backed shell /
//    non-repo metadataPanel / empty),各分支挂 `.id(item.id)` +
//    `.detailContentTransition()` + 外层 `.animation(value:)`。
//
//  ────────────────────────────────────────────────────────────────────────────
//  关键约束(写入注释作为永久记录)
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. **同步快路径不调网络**:Activity item.repo 是从 ActivityRepository 查 DB
//     得到的本地 Repo 对象(已 star 过的 repo,字段完整),**不需要任何 API 调用**
//     就能渲染 hero。Shell 重建后 .task(id: item.id) 同步设 `displayRepo = item.repo`,
//     第二帧立即渲染 RepoDetailScaffold。这是 Activity vs Weekly 的关键差异——
//     Activity 不需要 makeFallbackRepo 兜底,因为 item.repo 已经是真值。
//
//  2. **不复用 HomeView 全局 readmeVM**:与 Weekly / Trending shell 同款做法,
//     Shell 局部 `@State` 持有,避免污染主路径 README 状态。
//
//  3. **handleStarTapped 后 displayRepo 用 registry 派生 isStarred**:
//     与 D-24 修法一致,toggle 完成后 registry-derived 显式覆值 displayRepo。
//     注:Shell .id 重建后 displayRepo 重置,新一轮 .task 设到 item.repo 真值;
//     用户再次 star/unstar 时走 handleStarTapped 路径同步覆值。
//

import SwiftUI

/// Activity 场景的 repo-backed 详情页外壳。
///
/// 调用方守卫:仅当 `shouldShowReadme(for: item) == true && item.repo != nil`
/// 才装配本 shell。其它 kind(announcement / release / following 等)走
/// `ActivityDetailView` 自绘 `activityMetadataPanel`。
struct ActivityDetailScaffoldShell: View {

    let item: ActivityItem

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    /// 局部 README ViewModel；首次进入时 lazy 构造。
    /// 与 Weekly / Trending Shell 同款:Shell 自持 → 不污染主路径 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    /// 当前活跃的 Repo（hero / RepoLocalSections 等都基于此渲染）。
    ///
    /// **D-24 修订**(2026-06-11):原本直接用 `item.repo` 派生 hero,但 `item` 是
    /// 父 View 传入的 prop,star/unstar 完成后 `item.repo.isStarred` 不会自动更新
    /// (parent 的 `selectedActivityItem` 是 @State 不跟随 toggle)。修法:加
    /// `@State displayRepo` 缓存活跃 repo,初始化为 `item.repo`,handleStarTapped
    /// 后用 `starredRegistry` 派生 isStarred 显式覆值。与 Trending / Weekly 详情
    /// 同构(都有 displayRepo + registry-derived 兜底)。
    @State private var displayRepo: Repo?

    var body: some View {
        // Group + if-else 与 Trending / Weekly Shell 同款。
        // Shell 重建后 displayRepo / readmeVM 都是 nil → ProgressView 一帧;
        // .task(id: item.id) 同步设 displayRepo + 触发 readmeVM.load → 下一帧渲染 Scaffold。
        Group {
            if let displayRepo, let readmeVM {
                scaffold(repo: displayRepo, readmeVM: readmeVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            // 同步先行:从 item.repo 直接设 displayRepo(item.repo 已经是本地真值,
            // 不需要任何 API 调用,与 trending/weekly 的 makeFallbackRepo 同位)。
            displayRepo = item.repo
            await loadReadmeIfNeeded()
        }
    }

    // MARK: - Scaffold 装配

    @ViewBuilder
    private func scaffold(repo: Repo, readmeVM: ReadmeViewModel) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                translation: ReadmeTranslationContext(fullName: repo.fullName),
                backendHint: nil
            ),
            fallbackAccentColor: item.category.iconColor,
            // v2.0:tooltip 与 toggle 行为对齐,直接派生自 `repo.isStarred`。
            starHelpKey: repo.isStarred ? "repo.unstar" : "repo.star",
            onStarTapped: {
                try await handleStarTapped(repo: repo)
            }
        ) { onScrollOffset in
            ActivityRepoDetailContent(
                repo: repo,
                onScrollOffset: onScrollOffset
            )
            .environment(readmeVM)
        }
    }

    /// trailingActions 守卫——与 manage / trending / weekly 4 详情页同构。
    /// 守卫绑 `Repo.isStarred`(本地 DB `is_starred` 列的内存镜像)。
    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        guard authSession.state.isAuthenticated, repo.isStarred else {
            return []
        }
        return [.share, .ai]
    }

    // MARK: - README

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        // HOM-201 P0-2（2026-06-14）：注入 `readmeAvailability` 单例，让 active 详情
        // 与 manage 全局 VM 共用同一个"已知 404"集合（详见 ReadmeAvailability.swift）。
        let model = ReadmeViewModel(
            api: dependencies.readmeAPI,
            availability: dependencies.readmeAvailability
        )
        readmeVM = model
        return model
    }

    /// 触发 README 加载（fire-and-forget）。
    private func loadReadmeIfNeeded() async {
        guard let repo = item.repo else {
            readmeVM?.reset()
            return
        }
        ensureReadmeViewModel().load(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
    }

    // MARK: - Star / Unstar 协调

    /// hero ⭐/☆ chip 点击（v2.0 修订 + D-24 修订, 2026-06-11）。
    ///
    /// 与 manage / trending / weekly 同构——`StarActionService.toggle(repo:)`
    /// 内部按 `repo.isStarred || registry.contains` 派生 star / unstar 分支。
    /// 失败抛错让 `StarStatChipButton` 触发抖动 + 短暂红色 600ms。
    ///
    /// **D-24 修订**：toggle 完成后**用 registry 派生 isStarred 显式更新 displayRepo**,
    /// 让 hero / 三段当帧拿到真值(不依赖父 View selectedActivityItem 重新派发)。
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        // D-24:registry 派生新 isStarred 显式更新 displayRepo,让 hero 当帧拿真值。
        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
    }
}
