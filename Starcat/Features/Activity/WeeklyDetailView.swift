//
//  WeeklyDetailView.swift
//  Starcat
//
//  Activity 页 weekly 分类的右侧详情面板（外层路由 + 空态承载）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  D-28 v3 重构（2026-06-11，dong4j 反馈"看不到动画 + 4 详情页应该真同构"）
//  ────────────────────────────────────────────────────────────────────────────
//
//  之前 WeeklyDetailView 自持 `@State displayRepo` / `@State readmeVM` 等所有
//  解析层 state,导致同 weekly 切换 project 时无法走「shell .id 重建」路径,
//  hero 入场动画无法稳定触发。
//
//  D-28 v3 把解析层全部下沉到 `WeeklyDetailScaffoldShell`(同款 trending 模式),
//  本 view 简化为「外层路由 + 空态承载」两段:
//
//      ZStack(alignment: .topLeading) {
//          if let project {
//              WeeklyDetailScaffoldShell(project: project)
//                  .id(project.id)              // ← 关键!外层挂 .id 让 shell 重建
//                  .detailContentTransition()   // ← "轻轻落下"非对称 transition
//          } else {
//              emptyState
//                  .id("weekly-empty")
//                  .detailContentTransition()
//          }
//      }
//      .animation(.easeOut(duration: 0.4), value: weeklyAnimationKey)
//
//  **关键约束(写入注释作为永久记录)**:
//
//  1. **必须配 ZStack(alignment: .topLeading)**:Group transparent container 跨
//     分支切换 transition 不稳定触发(详见 `DetailContentTransition.swift` 文件头)。
//
//  2. **shell 外层必须挂 `.id(project.id)`**:这是 D-28 v3 vs v1/v2 的本质差别,
//     v1/v2 把 .id 挂在分支稳定标识上(`"weekly-content"`)→ shell 不重建 →
//     @State displayRepo 跨 project 持久化但 implicit animation 抓不到跨帧的
//     state 变化 → 切换瞬切无动画。v3 挂 `.id(project.id)`(`WeeklyProject.id`
//     等价于 `fullName`,与 trending 同款设计)→ shell 整体重建,@State 自动
//     重置 → loadAll 入口同步推 fallback 让第二帧立即有内容 → 配合
//     `.detailContentTransition()` insertion(opacity 0 + offset y:14)→
//     "轻轻落下"动画稳定触发,**与 trending 完全同款**。
//
//  3. **D-27 ghosting 不会复活**:v1/v2 担心的"shell 重建但外层 @State 不重置"
//     问题在 v3 不存在 —— @State 现在搬到 shell 内部,shell 重建时 @State 自然
//     一起重置,与 trending 模式完全一致。详见 `WeeklyDetailScaffoldShell.swift`
//     文件头「Shell 重建友好的同步快路径」段。
//
//  4. **animation key 用 project?.id ?? "empty"**:仅作 `.animation(value:)` 触发
//     key,与外层 `.id` 同源(都依赖 project.id 切换)→ 两者同帧变化,SwiftUI
//     用 0.4s easeOut 包裹 shell removal + insertion → 动画时长统一。
//
//  ────────────────────────────────────────────────────────────────────────────
//  历史修订全部下沉到 Shell(参考 WeeklyDetailScaffoldShell.swift 文件头)
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **D-22 全字段 ==**:Shell 内部 displayRepo prop 变化触发 SwiftUI diff
//  - **D-24 registry-derived isStarred**:Shell `handleStarTapped` 双保险
//  - **D-26 fullName 守卫**:Shell `resolveRepo` 1a fullName 校验
//  - **D-27 同步先行 + 异步升级**:Shell `loadAll` 入口同步推 fallback
//
//  本 view (WeeklyDetailView) 只负责:
//  - **路由**:有 project → 装配 shell;无 project → 显示空态
//  - **入场动画**:外层 ZStack + .id(project.id) + .detailContentTransition() +
//    .animation(value:),让 shell 切换走"轻轻落下"
//

import SwiftUI

struct WeeklyDetailView: View {

    let item: WeeklyFeedItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item {
                // D-28 v3 关键:外层挂 .id(project.id) 让 shell 整体重建,
                // @State displayRepo / readmeVM 自动重置 →
                // 配合 .detailContentTransition() 触发"轻轻落下"动画(与 trending 同款)。
                WeeklyDetailScaffoldShell(item: item)
                    .id(item.id)
                    .detailContentTransition()
            } else {
                emptyState
                    .id("weekly-empty")
                    .detailContentTransition()
            }
        }
        // 监听 project.id 变化,用 0.4s easeOut 包裹 shell removal + insertion,
        // 让 .detailContentTransition() 的非对称 transition(insertion: opacity + offset y:14
        // / removal: 仅 opacity)在 0.4s 内完成插值 — 视觉上"轻轻落下"。
        .animation(.easeOut(duration: 0.4), value: item?.id ?? 0)
    }

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
}
