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
//  isVisible 判定语义（v1.4 修订,2026-06-10）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本组件**内部**用 `isAuthenticated && repo.id != 0` 判定是否渲染三段：
//
//  1. **`repo.id != 0`（本地命中）**：
//     - Trending / Weekly 未命中本地 → `makeEphemeralRepo()` 构造 id=0 临时
//       Repo,三段没法用 id 关联 `repo_tags` / `repo_notes` /
//       `release_subscriptions`,必须隐藏;
//     - 用户在详情页点 ⭐ → StarActionService 写 DB 拿到真 id → 外层 view
//       （TrendingScaffoldShell.resolveRepo / WeeklyDetailView.resolveRepo）
//       切到本地真值,传入新 repo（id != 0）→ 三段 spring 0.25s 展开。
//
//  2. **`authSession.state.isAuthenticated`（已登录）（v1.4 新增）**：
//     - Tags / Notes（含阅读状态）/ Release 订阅在语义上是**用户的私人配置**,
//       未登录态根本不存在「我的标签 / 我的笔记 / 我的订阅」概念——这些功能
//       的入口必须先登录;
//     - corner case：用户曾登录过 → 本地 DB 留有 repo_tags / repo_notes
//       数据 → 登出后 `signOut()` 不会清这些表（合理：保护用户数据,重新
//       登录后还在）→ 但 trending 详情页 resolveRepo 仍可能命中
//       `repo.id != 0`,单看 id 守卫会泄漏私人数据到登录页之外。
//       加 `isAuthenticated` 守卫消除此泄漏路径;
//     - 一致性：与「⭐/☆ chip 未登录点击触发 signIn() 引导」对齐——三段都是
//       已登录后的功能,未登录入口该藏就藏。
//
//  调用方**不需要**传 isLocalHit / isAuthenticated 等开关——只要保证传入
//  的 repo 对象是「最新已解析」的真实状态,本组件读 `@Environment(AuthSession)`
//  自动响应登录态变化。v1.5 起调用方收口为唯一一处（Scaffold metadataPanel）,
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
/// 可见性：`isAuthenticated && repo.id != 0` 时三段 spring 展开;
/// 任一条件不满足时收起（包括登出 / 切到 ephemeral repo）。
struct RepoLocalSections: View {

    let repo: Repo

    /// 登录态门控（v1.4 修订）：未登录时三段隐藏,与「未登录用户没有私人配置」
    /// 语义对齐。通过 Environment 注入,4 个 ContentView 调用方零改动。
    @Environment(AuthSession.self) private var authSession

    /// horizontal padding：与 `RepoMetadataHeaderView` 保持一致 24pt,让三段视觉
    /// 边距与 hero 严格对齐（避免读者察觉 hero / body 区分）。
    private let horizontalPadding: CGFloat = 24

    /// 三段是否可见。两条件 AND：
    /// - `authSession.state.isAuthenticated`：登录是「我的标签/笔记/订阅」的语义前提
    /// - `repo.id != 0`：非 ephemeral,能用 id 关联本地表
    private var isVisible: Bool {
        authSession.state.isAuthenticated && repo.id != 0
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
