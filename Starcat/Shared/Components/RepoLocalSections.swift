//
//  RepoLocalSections.swift
//  Starcat
//
//  R-01「三场景共用架构」本地段（Tags / Notes）的统一封装与转场动画。
//
//  ⚠️ **v2.0 修订（2026-06-12，dong4j 反馈）**：原本是「三段（Tags / Notes / Release）」,
//      v2.0 起 Release 订阅段被压缩为 hero stats 行的紧凑 stat 单元
//      `RepoReleaseStatItem`（详见 `Starcat/Features/Releases/RepoReleaseSection.swift`
//      与 `RepoMetadataHeaderView.statsSection`），不再挂在本组件下。
//      下方原有的注释中所有「三段」字样均应理解为「Tags / Notes 两段」,
//      但出于「保留历史推理 + 不做大修注释」原则没有逐处替换,新协作者读到时请知悉。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2.4 / §3.2.6 / §5.x ContentView 集合 + R-01 v1.2 P0）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Tags 段、Notes 段、Releases 订阅段是三个**强依赖本地 `repo.id`**的区块：
//  它们都用 `repo.id` 去查 / 写 `repo_tags` / `repo_notes` /
//  `release_subscriptions` 表,未命中本地（id == 0 的 ephemeral repo）必须
//  隐藏,否则会用 id=0 误命中 / 误写入墓碑数据。
//
//  设计 §3.2.4 + §3.2.6 明文要求：
//  1. **三段渲染位置**（**v1.5 修订, 2026-06-10**）：**RepoDetailScaffold metadataPanel
//     内**（hero + heroExtension 之后）—— 跟随折叠面板整段收起,让 README 滚动时
//     有完整阅读空间。
//
//     v1.2 P0 原放置在 ContentView 内（理由「各场景 section 集合不同,hero 不该
//     知道有几段要展开」）;但实际落地 4 场景的 RepoLocalSections 调用 100% 同构,
//     抽象层灵活性未被使用。dong4j 在 v1.5 反馈滚动 README 时三段挤压阅读区 →
//     方案 A：内置到 Scaffold 跟随折叠（折叠一致性 > 抽象灵活性）。
//     详见 `Starcat/Shared/Components/RepoDetailScaffold.swift` 文件头 v1.5 修订段。
//  2. **转场动画**：API 200 后切到本地命中（isStarred 变化或 repo.id 从 0→非零）
//     时,三段以 `.spring(response: 0.25, dampingFraction: 0.85)` + transition
//     `.move(edge: .top).combined(with: .opacity)` 平滑展开/收起。
//     与折叠面板的 PreferenceKey 高度测量协同 —— 三段加入后 panelHeight 自然
//     增长,折叠面板与 spring 转场两层动画都是 short-duration spring,叠加视觉 OK。
//  3. **数据就位才展开**：不在 loading 中先展开占位（避免空 section 闪烁）。
//
//  本组件把三段 + transition + animation + 登录守卫一次封装,Scaffold 直接挂载
//  即可,确保动画规格、隐藏逻辑、padding、登录守卫全场景一致。
//
//  ────────────────────────────────────────────────────────────────────────────
//  isVisible 判定语义（**v2.0 修订, 2026-06-10**, dong4j 真机验证后回归）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本组件**内部**用 `isAuthenticated && repo.isStarred` 判定是否渲染三段。
//  **核心思想：以本地 DB `is_starred` 列的内存镜像作单一信任源**。
//
//  ## 演进路径（重要历史避坑）
//
//  - **v1.4** 守卫 `isAuthenticated && repo.id != 0`：v9 schema 之后 trending row
//    自带 ghRepoId(非 0)→ `TrendingRepo.makeEphemeralRepo()` 用 ghRepoId 作
//    `Repo.id` → 用户**没 star 过**的 trending repo 进详情页时 `repo.id != 0`
//    仍然成立 → 三段被错误展示 + AI 摘要按钮可点 → 点 AI 摘要时
//    `INSERT INTO ai_summaries(repo_id=...)` FK 失败(ghRepoId 不在 repos 表)。
//
//  - **v1.7** 改为 `isAuthenticated && starredRegistry.contains(ghRepoId: repo.id)`：
//    本意是绑「写权限 fileprivate 锁死」的单一信任源；但 dong4j 真机回归发现
//    Manage 详情页**所有已 star repo 都不显**三段 + 点 ⭐ 走 star 而非 unstar。
//    根因：`StarredRegistry.reload()` 是异步的(`AppDependencies.init` 末尾
//    `Task { await bootstrapper.reload() }`),且 `SyncManager` 304 ETag 命中
//    早退路径直接 `return`,**不触发 `onSyncCompleted` hook**(v2.0 已补上),
//    任一路径未跑完 registry.ids 就是空集 → contains 永远返 false。
//
//  - **v2.0** 回归 `repo.isStarred`(本提交):
//    1. `Repo.isStarred` 是本地 DB `is_starred` 列的内存镜像,在 4 场景全部可信:
//       - Manage:`fetchAllStarred` 已 filter `is_starred == true` → 真值
//       - Trending 本地命中:`findByOwnerName` 返回的 Repo 含 isStarred 真值
//       - Trending ephemeral:`makeEphemeralRepo()` 显式 `isStarred = false`
//       - Activity:基于 Repo 表查询 → 真值
//       - Weekly:同 Trending(三段降级 resolveRepo)
//    2. **不依赖异步生效的 registry**,Manage 启动时无论 registry 是否 reload 完
//       都能正确判定;
//    3. 同时根治 v1.4 corner case：trending ephemeral 的 isStarred=false 直接
//       拦住三段 / AI 按钮显示,不会再触发 FK 失败。
//
//  ## 与 `StarActionService.toggle` 的关系
//
//  view 层用 `repo.isStarred`(同步 DB 真值)是稳的;但 `StarActionService.toggle`
//  内部仍补充 registry corner case:`repo.isStarred || registry.contains(...)`
//  任一为 true 即 unstar —— 解决「刚 star 完 displayRepo 还是 ephemeral
//  isStarred=false 但 registry 已 add」的瞬间 stale 问题(详见
//  `StarringSubsystem.swift` v2.0 修订段)。
//
//  ## 双条件 AND 守卫语义
//
//  - **`authSession.state.isAuthenticated`(已登录)**：未登录用户没有「我的标签 /
//    笔记 / 订阅」概念。`AuthSession.signOut()` 出于「保护用户数据,重新登录后
//    不丢笔记」**不**清空 `repo_tags` / `repo_notes` / `release_subscriptions`
//    表 → 单 isStarred 守卫无法防住「已登出 + 本地有历史数据」corner case;
//    必须显式加 isAuthenticated 兜住。
//  - **`repo.isStarred`(已 star)**：三段都是「已 star repo 的私人配置」,
//    未 star 不应该展示。
//
//  调用方**不需要**传 isLocalHit / isAuthenticated / isStarred 等开关——只要
//  保证传入的 repo 对象是「最新已解析」的真实状态,本组件读
//  `@Environment(AuthSession.self)` 自动响应登录态 + 由 SwiftUI Identity
//  在 repo 切换时重渲染。v1.5 起调用方收口为唯一一处（Scaffold metadataPanel）,
//  4 个 ContentView 不再各自调用,彻底消除分散判断的不一致风险。
//

import SwiftUI

/// repo 详情页三段（Tags / Notes / Release）渲染容器,内置 spring 0.25s 转场。
///
/// **v1.5 调用契约（2026-06-10 起）**：仅由 `RepoDetailScaffold.metadataPanel`
/// 单点挂载,4 场景 ContentView 不再调用。
///
/// ```swift
/// // RepoDetailScaffold.metadataPanel 内
/// CollapsibleRepoMetadataPanel { ... } content: {
///     VStack(spacing: 0) {
///         RepoMetadataHeaderView(repo: repo, ...) { trailingActions }
///         heroExtension_()
///         RepoLocalSections(repo: repo)   // ← 唯一调用点
///     }
/// }
/// ```
///
/// 可见性：`isAuthenticated && repo.isStarred` 时三段 spring 展开;任一条件不满足时
/// 收起(包括登出 / 未 star / 切到 ephemeral repo / Manage 后已 unstar 但视图未刷新)。
struct RepoLocalSections: View {

    let repo: Repo

    /// 登录态门控（v1.4 修订）：未登录时三段隐藏,与「未登录用户没有私人配置」
    /// 语义对齐。通过 Environment 注入,4 个 ContentView 调用方零改动。
    @Environment(AuthSession.self) private var authSession

    /// horizontal padding：与 `RepoMetadataHeaderView` 保持一致 24pt,让三段视觉
    /// 边距与 hero 严格对齐（避免读者察觉 hero / body 区分）。
    private let horizontalPadding: CGFloat = 24

    /// 三段是否可见。两条件 AND(**v2.0 修订**, 2026-06-10):
    /// - `authSession.state.isAuthenticated`：登录是「我的标签/笔记/订阅」的语义前提
    /// - `repo.isStarred`：当前用户已 star —— 直接读 `Repo.isStarred`(本地 DB
    ///   `is_starred` 列的内存镜像),不再走 `StarredRegistry.contains(...)`。
    ///
    /// **为什么 v2.0 不再用 `starredRegistry.contains(ghRepoId:)`**:
    /// v1.7 改用 registry 本意是绑「写权限 fileprivate 锁死」的单一信任源,但
    /// `StarredRegistry.reload()` 是异步的(`AppDependencies.init` 末尾
    /// `Task { await bootstrapper.reload() }`),且 `SyncManager` 304 ETag 命中
    /// 早退路径直接 `return`,**不触发 `onSyncCompleted` hook**(v2.0 已补上),
    /// 任一路径未跑完 registry.ids 就是空集 → contains 永远返 false → Manage
    /// 详情页所有已 star repo 三段全部不显。改用 `repo.isStarred` 让 view 层
    /// **不依赖异步生效的 registry**,Manage 启动时无论 registry 是否 reload 完
    /// 都能正确判定。
    ///
    /// **为什么 v2.0 也不用 `repo.id != 0`(v1.4 旧守卫)**:v9 schema 后 trending
    /// row 自带 ghRepoId(非 0),`TrendingRepo.makeEphemeralRepo` 用它作
    /// `Repo.id` → 未 star 的 trending repo 也满足 `repo.id != 0` → 三段被错误
    /// 展示 + AI 按钮可点导致 `ai_summaries` FK 失败。`isStarred` 直接读
    /// `is_starred` 列,ephemeral 显式 false,不会撞这个 corner case。
    private var isVisible: Bool {
        authSession.state.isAuthenticated && repo.isStarred
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isVisible {
                RepoTagsSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                RepoNotesSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                // v2.0(2026-06-12)：原 RepoReleaseSection 段已压缩为 hero stats 行的紧凑
                // stat `RepoReleaseStatItem`,与 Stars / Forks 等同行,详见 `RepoMetadataHeaderView.statsSection`。
                // 这里不再挂载第三段,以让本组件聚焦"重交互的 Tags / Notes 双段"。
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, isVisible ? 12 : 0)
        // 设计 §3.2.4：spring(response: 0.25, dampingFraction: 0.85)
        // - response 0.25s：足够慢让用户察觉「star 后展开」的因果,又足够快不显拖沓
        // - dampingFraction 0.85：略带回弹但不过分晃动
        // - value 绑 isVisible（v1.4 修订）：原来绑 repo.id 在「登录态切换且 repo.id
        //   不变」场景下不会触发动画（罕见但存在：用户登出再登入同一个详情页）;
        //   改绑 isVisible 覆盖所有触发源（登录态变 / repo.id 变 / 切不同详情页）。
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isVisible)
    }
}
