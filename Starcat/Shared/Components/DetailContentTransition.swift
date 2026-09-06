//
//  DetailContentTransition.swift
//  Starcat
//
//  详情页 root 切换 transition 共享 modifier。
//
//  ────────────────────────────────────────────────────────────────────────────
//  D-28 修订（2026-06-11，dong4j 反馈：活动分类详情页 hero 缺切换动画）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本组件抽取自 `RepoDetailView` 私有的 `detailContentTransition` helper，
//  用于让 4 详情页（manage / trending / activity / weekly）root 切换 hero
//  入场效果**完全同构**。原 `RepoDetailView` 的实现存在两个问题:
//
//    1. modifier / transition 配置只对 manage / trending 生效（写在
//       `RepoDetailView.swift` 私有作用域内）;
//    2. activity / weekly 两个详情页 root 用的是 `Group { ... }` —— Group 是
//       transparent container,**不在 view tree 创建 layout 节点**,跨分支
//       切换时 SwiftUI 没有"宿主"协调 old removal + new insertion → 即便挂
//       `.transition` 也不稳定触发。
//
//  ────────────────────────────────────────────────────────────────────────────
//  使用范式（与 RepoDetailView 同款）
//  ────────────────────────────────────────────────────────────────────────────
//
//      ZStack(alignment: .topLeading) {
//          if let repo = ... {
//              SomeContent()
//                  .id("a-\(repo.id)")
//                  .detailContentTransition()
//          } else {
//              EmptyState()
//                  .id("empty")
//                  .detailContentTransition()
//          }
//      }
//      .animation(.easeOut(duration: 0.4), value: contentID)
//
//  关键约束（写入注释作为永久记录）:
//
//    - **必须配 ZStack(alignment: .topLeading)**——Group 是 transparent
//      container,跨分支切换缺"容器宿主"协调 old removal + new insertion,
//      transition 不稳定触发（参见 `RepoDetailView.swift` 文件头描述）。
//    - **每个分支必须挂 `.id(...)`**——SwiftUI 通过 id 变化识别"分支切换",
//      继而触发 transition;同分支内 prop 变化（如 selected repo 切换且仍在
//      manage 分支）也通过 id 变化驱动 transition。
//    - **外层必须挂 `.animation(.easeOut(duration: 0.4), value: contentID)`**
//      ——`.transition` 单独挂没用,需要 `.animation(_:value:)` 监听变化才会
//      插值;duration 0.4s 是 `RepoDetailView` 经验值（21:44 调试得出,比
//      README 首帧渲染稍慢一点让用户感受到"轻轻落下",过快肉眼几乎看不到）。
//    - **必须给外层提供稳定的 contentID**——任意分支切换 / repo 切换都让 id
//      变化,同状态内重新选同一条 → id 不变 → 无动画（避免列表 row 高亮等
//      副作用过多触发 transition）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  非对称 transition 设计（重要）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **insertion 新内容**: `opacity` 0→1 + `offset y:14→0` 滑入,让用户感觉
//    "新内容轻轻落下"。
//  - **removal 旧内容**: 仅 `opacity` 1→0 直接淡出,**不滑动**——否则新旧两份
//    内容同时在 view tree 里漂移,视觉上很乱,特别是 README WebView 切换时
//    容易显得抖动。
//
//  reduceMotion 兜底: 完全去掉 offset,只保留 opacity 淡入淡出,避免前庭不适。
//
//  14pt 的 offset（21:44 从 8pt 调大,见 RepoDetailView 文件头）: 经验值,
//  让"轻轻落下"明显可感知;8pt 在 macOS 大屏 + WebView 渲染延迟下太微弱,
//  肉眼几乎看不出来。再大（>20pt）就像"页面跳",14pt 是平衡点。
//

import SwiftUI

extension View {

    /// 详情页 root 切换 transition modifier。
    ///
    /// 用法见文件头使用范式段 —— 必须配 `ZStack(alignment: .topLeading)` +
    /// 每个分支 `.id(...)` + 外层 `.animation(.easeOut(duration: 0.4),
    /// value: contentID)`。
    ///
    /// 4 详情页（manage / trending / activity / weekly）应使用统一签名,
    /// 后续新增详情页（如 search / discover 等）也直接复用此 modifier,
    /// 保持 4+ 场景视觉**完全同构**。
    func detailContentTransition() -> some View {
        modifier(DetailContentTransitionModifier())
    }

}

/// 详情页 root 切换 transition 实现（私有,通过 `.detailContentTransition()`
/// extension 暴露使用入口）。
///
/// `@Environment(\.starcatReduceMotion)` 必须在 ViewModifier 内部读取
/// 而非暴露给调用方,因为 SwiftUI environment 只有在 view tree 内才有效;
/// 把环境读取下沉到 modifier 让调用方完全无需关心 reduceMotion 兜底逻辑。
private struct DetailContentTransitionModifier: ViewModifier {

    /// 系统级"减少动效"开关,开启时退化为仅 opacity 淡入（不再上滑）。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    /// 当前应使用的非对称 transition。
    ///
    /// reduceMotion 时直接返 `.opacity`（同时作用 insertion / removal 对称）;
    /// 否则返非对称: insertion = opacity + offset y:14 / removal = 仅 opacity。
    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)),
            removal: .opacity
        )
    }
}
