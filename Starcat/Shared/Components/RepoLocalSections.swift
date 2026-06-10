//
//  RepoLocalSections.swift
//  Starcat
//
//  R-01「三场景共用架构」三段（Tags / Notes / Release）的统一封装与转场动画。
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
//  isVisible 判定语义（**v1.7 修订, 2026-06-10**, dong4j bug 反馈）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本组件**内部**用 `isAuthenticated && starredRegistry.contains(ghRepoId: repo.id)`
//  判定是否渲染三段。**核心思想：以「是否 star」作为单一信任源**。
//
//  v1.4 旧守卫 `isAuthenticated && repo.id != 0` 的硬伤：v9 schema 之后,
//  trending row 自带 ghRepoId（非 0）→ `TrendingRepo.makeEphemeralRepo()` 用
//  ghRepoId 作 `Repo.id` → 用户**没 star 过**的 trending repo 进详情页时
//  `repo.id != 0` 仍然成立 → 三段被错误展示 + AI 摘要按钮可点 → 点 AI 摘要
//  时 `INSERT INTO ai_summaries(repo_id=...)` FK 失败（ghRepoId 不在 repos 表）。
//
//  v1.7 守卫直接绑「真正的 starred 信号」：
//
//  1. **`starredRegistry.contains(ghRepoId: repo.id)`（已 star）**：
//     - StarredRegistry 是 R-01 v1.2 §4.3 的「写权限 fileprivate 锁死」单一
//       信任源,内容 = 当前用户已 star 的所有 ghRepoId 集合;
//     - 三段都是「已 star repo 的私人配置」（tags / notes / release 订阅）,
//       未 star 不应该展示;
//     - registry 是 `@Observable`,star/unstar 后所有详情页面板自动响应,
//       不需要 view 层手动 reload。
//
//  2. **`authSession.state.isAuthenticated`（已登录）**：
//     - 双保险——理论上 registry 在登出时会被 `clearAll()` 清空,但加这个
//       守卫让「未登录」语义在 view 层一眼看出,且与「⭐/☆ chip 未登录点击
//       触发 signIn() 引导」对齐;
//     - corner case：登出瞬间 registry 还没清 → 这一守卫兜住;登入瞬间
//       registry 还没 bootstrap → 守卫保持收起直到 bootstrap 完成。
//
//  v1.4 旧守卫语义对比：
//  - 旧：`isAuthenticated && repo.id != 0` ← 含义「本地有 row」≠「已 star」
//  - 新：`isAuthenticated && contains(ghRepoId)` ← 含义「真已 star」
//
//  调用方**不需要**传 isLocalHit / isAuthenticated / isStarred 等开关——只要
//  保证传入的 repo 对象是「最新已解析」的真实状态,本组件读
//  `@Environment(AuthSession / AppDependencies)` 自动响应登录态 + star 态变化。
//  v1.5 起调用方收口为唯一一处（Scaffold metadataPanel）,4 个 ContentView 不再
//  各自调用,彻底消除分散判断的不一致风险。
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
/// 可见性：`isAuthenticated && starredRegistry.contains(ghRepoId: repo.id)` 时
/// 三段 spring 展开;任一条件不满足时收起（包括登出 / 未 star / 切到 ephemeral repo）。
struct RepoLocalSections: View {

    let repo: Repo

    /// 登录态门控（v1.4 修订）：未登录时三段隐藏,与「未登录用户没有私人配置」
    /// 语义对齐。通过 Environment 注入,4 个 ContentView 调用方零改动。
    @Environment(AuthSession.self) private var authSession

    /// AppDependencies 注入（v1.7 修订）：访问 `starredRegistry` 派生 isVisible。
    /// 用 dependencies 而非直接注 `StarredRegistry`,因为后者不是单独的环境对象,
    /// 与 `RepoMetadataHeaderView` / `Scaffold` 注入约定保持一致。
    @Environment(AppDependencies.self) private var dependencies

    /// horizontal padding：与 `RepoMetadataHeaderView` 保持一致 24pt,让三段视觉
    /// 边距与 hero 严格对齐（避免读者察觉 hero / body 区分）。
    private let horizontalPadding: CGFloat = 24

    /// 三段是否可见。两条件 AND（v1.7 修订）：
    /// - `authSession.state.isAuthenticated`：登录是「我的标签/笔记/订阅」的语义前提
    /// - `starredRegistry.contains(ghRepoId: repo.id)`：当前用户已 star
    ///   （registry 是 R-01 v1.2 §4.3 写权限锁死的单一信任源,@Observable 让
    ///    star/unstar 触发自动重渲染）
    ///
    /// **为什么不再用 `repo.id != 0`**：v9 schema 后 trending row 自带 ghRepoId
    /// （非 0）,`TrendingRepo.makeEphemeralRepo` 用它作 `Repo.id` → 未 star 的
    /// trending repo 也满足 `repo.id != 0` → 三段被错误展示 + AI 按钮可点导致
    /// `ai_summaries` FK 失败。改用 `registry.contains(ghRepoId:)` 把守卫绑到
    /// 真正的 starred 信号,根治此 corner case。
    private var isVisible: Bool {
        authSession.state.isAuthenticated
            && dependencies.starredRegistry.contains(ghRepoId: repo.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isVisible {
                RepoTagsSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                RepoNotesSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                RepoReleaseSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
