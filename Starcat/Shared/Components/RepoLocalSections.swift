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
//  `release_subscriptions` 表，未命中本地（id == 0 的 ephemeral repo）必须
//  隐藏，否则会用 id=0 误命中 / 误写入墓碑数据。
//
//  设计 §3.2.4 + §3.2.6 明文要求：
//  1. **三段渲染位置**：ContentView 内部（不在 hero）—— 因为各场景的 section
//     集合不同，hero 不该知道有几段要展开。
//  2. **转场动画**：API 200 后切到本地命中（isStarred 变化或 repo.id 从 0→非零）
//     时，三段以 `.spring(response: 0.25, dampingFraction: 0.85)` + transition
//     `.move(edge: .top).combined(with: .opacity)` 平滑展开/收起。
//  3. **数据就位才展开**：不在 loading 中先展开占位（避免空 section 闪烁）。
//
//  本组件把三段 + transition + animation 一次封装，4 个 ContentView 都直接
//  调用即可，确保动画规格、隐藏逻辑、padding 全场景一致。
//
//  ────────────────────────────────────────────────────────────────────────────
//  isVisible 判定语义
//  ────────────────────────────────────────────────────────────────────────────
//
//  本组件**内部**用 `repo.id != 0` 判定是否渲染三段。原因：
//
//  - Trending / Weekly 未命中本地 → 通过 `makeEphemeralRepo()` 构造 id=0 临时
//    Repo，期间不渲染三段；
//  - 用户在详情页点 ⭐ → StarActionService 写 DB 拿到真 id → 外层 view
//    （TrendingScaffoldShell.resolveRepo / WeeklyDetailView.resolveRepo）切到
//    本地真值，传入新 repo（id != 0），本组件 `repo.id != 0` 变 true →
//    spring 0.25s 三段展开。
//
//  调用方**不需要**传 isLocalHit / isVisible 等开关——只要保证传入的 repo
//  对象是「最新已解析」的真实状态即可。这避免了 ContentView 各自判断、
//  各自传参导致的不一致。
//

import SwiftUI

/// repo 详情页三段（Tags / Notes / Release）渲染容器，内置 spring 0.25s 转场。
///
/// 调用契约：
///
/// ```swift
/// // 在 4 个 ContentView 的 body 顶部直接挂载
/// var body: some View {
///     VStack(spacing: 0) {
///         RepoLocalSections(repo: repo)
///         ReadmeStateView(...)
///     }
/// }
/// ```
///
/// 当 `repo.id` 从 0 变为非零（用户在 Trending / Weekly 详情点 star 后
/// resolveRepo 切到本地真值）→ 三段 spring 展开；反之收起。
struct RepoLocalSections: View {

    let repo: Repo

    /// horizontal padding：与 `RepoMetadataHeaderView` 保持一致 24pt，让三段视觉
    /// 边距与 hero 严格对齐（避免读者察觉 hero / body 区分）。
    private let horizontalPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if repo.id != 0 {
                RepoTagsSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                RepoNotesSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
                RepoReleaseSection(repo: repo)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, repo.id != 0 ? 12 : 0)
        // 设计 §3.2.4：spring(response: 0.25, dampingFraction: 0.85)
        // - response 0.25s：足够慢让用户察觉「star 后展开」的因果，又足够快不显拖沓
        // - dampingFraction 0.85：略带回弹但不过分晃动
        // - value 绑 repo.id：从 0 → 非零（star 后切本地）触发；
        //   切换不同 repo（id 直接变）也会触发，符合"打开新详情即时展开"语义
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: repo.id)
    }
}
