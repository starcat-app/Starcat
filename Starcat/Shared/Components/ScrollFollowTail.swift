//
//  ScrollFollowTail.swift
//  Starcat
//
//  「跟随尾部 (Follow Tail)」共享组件：让任何流式更新的 ScrollView
//  在用户没主动上滚时自动滚到底部，在用户上滚后停止跟随，
//  在用户重新滚回底部时再自动恢复跟随。
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │ 为什么单独抽这个文件                                              │
//  ├──────────────────────────────────────────────────────────────────┤
//  │ Starcat 至少 3 处会有"流式输出 + 用户想往上翻看历史"的场景：     │
//  │   1. AI 摘要生成（RepoAIWindowContentView.summarySection，         │
//  │      token-by-token 写 streamingSummaryText）                       │
//  │   2. AI 对话回答（同文件 chatSection，chat.messages.last 增量改）  │
//  │   3. 未来批量队列日志 / 任意其它 streaming 输出                    │
//  │ 三者的"跟随策略"完全一致：                                          │
//  │   - 流式中且用户在底部 → 自动 scrollTo(.bottom)                     │
//  │   - 用户向上滚远了 → 停止跟随                                       │
//  │   - 用户滚回底部 → 恢复跟随                                         │
//  │ 把状态机抽到 ScrollTailController + 把浮按钮抽到                    │
//  │ FollowTailFloatingButton，调用方就不用各自维护一组散落的           │
//  │ @State / phase / offset，否则改一处必漏另一处。                     │
//  └──────────────────────────────────────────────────────────────────┘
//
//  关键约束 / 已踩过的坑（写之前的考量，避免后续 reviewer 重新踩一遍）：
//
//  1. **不能用 `offset == maxOffset` 浮点判等**：macOS ScrollView 的
//     bouncing 行为会让 contentOffset.y 在到底瞬间溢出几 pt 进负值或
//     超出 maxOffset；scrollTo(anchor: .bottom) 也会停在锚点像素的 1pt
//     之外。判等永远不稳。改用 distanceFromBottom + 双阈值滞回区。
//
//  2. **必须门控 ScrollPhase**：scrollTo(...) 自己触发的 geometry change
//     phase 是 `.animating` 而非用户手势。如果不门控，组件自身的
//     "跟随→滚动→geometry 变化"会立刻被识别成"用户上滚"，把跟随关
//     掉——典型的反馈循环 bug。只接受 `.tracking / .interacting /
//     .decelerating` 这三种"用户手势驱动"的相位才更新跟随态。
//
//  3. **双阈值滞回区（hysteresis）**：
//        distanceFromBottom > 1pt  才关闭跟随
//        distanceFromBottom < 8pt 才恢复跟随
//     2026-06-15 dong4j 二次反馈"80pt 太大，只要滚动就该停止"，
//     从初版的 80/24 收紧到 1/8。设计意图变化：
//       - 关闭阈值 1pt（而非 0pt）：留 1pt 浮点防护——macOS ScrollView
//         bouncing 行为下 contentOffset.y 在底部 phase 切到 .tracking
//         的瞬间可能有 0~1pt 浮点抖动，纯 0 判定会被噪声误触关闭跟随；
//         1pt 足够吸收浮点噪声，又对用户视觉零感知（1pt ≈ 0.4 行像素）。
//       - 恢复阈值 8pt（而非 0pt）：留 bouncing 与"接近底部"的视觉余量
//         ——用户滚回底部时手势惯性常停在 4~6pt，<8pt 让"几乎到底"也算
//         恢复，避免最后几 pt 反复挪鼠标恢复跟随的强迫体验。
//     滞回区（disengage > reengage）虽然只剩 7pt 仍然保留：用户停在
//     distance=5pt 时 is_following 已是 false，内容流式增长 → distance
//     继续增大不会反弹回 reengage 区，单调发散方向上不抖动。
//
//  4. **初始 isFollowing = true**：用户打开窗口默认期待"自动跟随最
//     新输出"，这个默认值与生成流程的预期 100% 吻合。
//
//  5. **不主动判 contentSize ≤ containerSize 的"内容还很短"情况**：
//     内容短时 distanceFromBottom 永远 < 24，所以会一直保持跟随，与
//     预期一致，无需特殊逻辑。
//

import SwiftUI

/// onScrollGeometryChange 的 transform 输出类型，用一次 transform 同时取多个量。
///
/// 设计动机：对话段除了"跟随尾部"还有"顶部下拉 overscroll 切回摘要面板"，
/// 后者需要 contentOffset.y，前者需要 distanceFromBottom。挂两个独立的
/// `.onScrollGeometryChange` 也能 work，但同一份 geometry 会被 SwiftUI 重读
/// 两遍 + 两个 closure 都参与 invalidation；用一个 Equatable struct 走单条
/// transform 更紧凑，也避免"两个 closure 之间被 SwiftUI 重排顺序"造成隐患。
///
/// 仅有"跟随尾部"需求的 ScrollView 不需要用这个，直接对 CGFloat 取
/// distanceFromBottom 即可。
struct ScrollFollowTailMetrics: Equatable {
    let offsetY: CGFloat
    let distanceFromBottom: CGFloat
}

/// 「跟随尾部」状态机。
///
/// 由 @Observable + @State 组合在 view 中持有（macOS 15+ 标准做法）。
/// 因为它只代表"UI 滚动状态"（不属于业务 ViewModel），生命周期与 view 一致。
///
/// 调用方需要做 3 件事：
///   1. `@State private var tail = ScrollTailController()`，在 ScrollViewReader
///      内部读 `tail.isFollowing` 决定要不要 scrollTo；
///   2. 在 ScrollView 上挂 `.onScrollPhaseChange { _, p in tail.updatePhase(p) }`
///      与 `.onScrollGeometryChange(...)` 提供 distanceFromBottom；
///   3. 当流式 trigger 变化时 `if tail.isFollowing { proxy.scrollTo(...) }`。
///
/// 浮动按钮 `FollowTailFloatingButton` 是配套 UI，调用方按需放到 ZStack 右下角。
@MainActor
@Observable
final class ScrollTailController {

    /// 当前是否处于"自动跟随尾部"状态。
    ///
    /// view 应该读它决定两件事：
    ///   - 流式 trigger 变化时是否调 `proxy.scrollTo(.bottom)`；
    ///   - 是否渲染 FollowTailFloatingButton（false 时显示，true 时隐藏）。
    private(set) var isFollowing: Bool = true

    /// 最近一次的滚动相位。
    ///
    /// 主要给本控制器自身门控用——只在用户手势相位下更新 isFollowing。
    /// 也暴露成 public 让对话段那种"还需要顺带判 overscroll"的场景复用
    /// 同一个 phase 状态，避免一个 view 上挂两个 onScrollPhaseChange。
    private(set) var lastPhase: ScrollPhase = .idle

    /// 关闭跟随的阈值（pt）。distance > 此值且为用户手势相位 → 关闭。
    ///
    /// 2026-06-15 dong4j 反馈"只要滚动就停止跟随"，从 80pt 收紧到 1pt。
    /// 1pt 而非 0pt 的原因见文件头注释 §3——留浮点防护，避开底部 bouncing
    /// 时 contentOffset.y 的 0~1pt 抖动误触。
    private let disengageThreshold: CGFloat = 1

    /// 恢复跟随的阈值（pt）。distance < 此值且为用户手势相位 → 恢复。
    ///
    /// 2026-06-15 dong4j 反馈"只要滚动就停止跟随"配套调整，从 24pt 收紧到 8pt。
    /// 8pt 留 bouncing + "接近底部"视觉余量；与 disengage=1 的 7pt 滞回区
    /// 足够避免边界抖动（用户滚到 distance>1 → 关闭 → 内容增长 → distance
    /// 继续增大，单调方向不会反弹回 reengage 区）。
    private let reengageThreshold: CGFloat = 8

    /// SwiftUI 把 `.onScrollPhaseChange` 的最新值递给我们。
    func updatePhase(_ phase: ScrollPhase) {
        lastPhase = phase
    }

    /// SwiftUI 把"内容相对底部的距离"递给我们后调用本方法。
    ///
    /// `distanceFromBottom` 计算式由调用方负责（用 onScrollGeometryChange
    /// 的 transform 算出来）：
    ///     `contentSize.height - contentOffset.y - containerSize.height`
    /// 用户在最底部时该值约 = 0；上滚 100pt 该值 = 100。
    func updateGeometry(distanceFromBottom: CGFloat) {
        // 反馈循环防护：只接受用户手势驱动的相位变化才更新 isFollowing。
        // 程序化 scrollTo 触发的 `.animating` 一律忽略，避免组件把自己
        // 触发的滚动当作用户操作。
        switch lastPhase {
        case .tracking, .interacting, .decelerating:
            break
        case .idle, .animating:
            return
        @unknown default:
            return
        }

        if isFollowing, distanceFromBottom > disengageThreshold {
            isFollowing = false
        } else if !isFollowing, distanceFromBottom < reengageThreshold {
            isFollowing = true
        }
    }

    /// 用户主动点了浮动按钮"跟随最新" / 或调用方明确要求恢复跟随时调。
    ///
    /// 与 `updateGeometry` 走的 phase 门控不同，这是显式的用户意图，
    /// 直接置 true 不需要校验。配套地，调用方应在调用本方法**之后**
    /// 用 ScrollViewReader 的 proxy.scrollTo(.bottom) 把视图滚到底。
    func reengage() {
        isFollowing = true
    }
}

/// 「跟随最新」浮动按钮（参考 GitHub Actions Logs / Slack 频道底部跳转按钮同款）。
///
/// 当用户上滚导致 `ScrollTailController.isFollowing == false` 时显示。
/// 点击 → 调用方负责 `tail.reengage()` + `proxy.scrollTo(.bottom)`。
///
/// 视觉规范：
///   - **2026-06-15 dong4j 反馈** "右下角的跟随最新使用图标，不要展示文本了"，
///     从初版 "Capsule + ↓ + 跟随最新" 改为 **32×32 圆形 icon-only 按钮**。
///     设计理由：① 浮在 ScrollView 右下角的"跳到底部"是公认 idiom（GitHub /
///     Slack / iMessage 等都用纯 icon 圆形按钮），用户对图标的认知成本接近零；
///     ② 文案改 tooltip 后，鼠标 hover 才显示，既不占视觉重量也保留可达性；
///     ③ 圆形比胶囊更紧凑，不会与右下角内容产生横向"压舱物"感。
///   - **32×32 pt 圆形 + .regularMaterial 玻璃态** 与项目其它浮层风格一致；
///   - **arrow.down 12pt semibold + `.primary`** 前景，明暗主题自适应；
///   - **`.accessibilityLabel("scroll.followTail.label")`** 让 VoiceOver
///     仍朗读"跟随最新"，文案"看不见"但语义保留；
///   - **`.help("scroll.followTail.help")`** 鼠标 hover 出 tooltip
///     "跳转到最新内容并恢复自动跟随"；
///   - 复用 `pressableHover`：默认 hover opacity=0.78, scale=1.04，悬停反馈；
///   - 必须挂 `.focusEffectDisabled()`，禁用 macOS 默认蓝框（项目硬性规范）；
///   - `.transition(.opacity.combined(with: .move(edge: .bottom)))`
///     由调用方在 ZStack 外层 `.animation(_:value:)` 配合。
struct FollowTailFloatingButton: View {

    /// 用户点击时的回调。调用方在里面置位 `controller.reengage()` 并调
    /// `proxy.scrollTo(anchorID, anchor: .bottom)`（建议加 0.2s easeOut）。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                )
                .pressableHover(opacity: 0.78, scale: 1.04)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("scroll.followTail.help")
        .accessibilityLabel(Text("scroll.followTail.label"))
    }
}
