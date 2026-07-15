//
//  ScrollFollowTail.swift
//  Starcat
//
//  「跟随尾部 (Follow Tail)」共享组件：让任何流式更新的 ScrollView
//  在用户没有主动滚动时自动滚到底部；用户开始滚动就立即停止跟随，
//  只有用户结束滚动且底部锚点可见时才自动恢复跟随。
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │ 为什么单独抽这个文件                                              │
//  ├──────────────────────────────────────────────────────────────────┤
//  │ Starcat 至少 3 处会有"流式输出 + 用户想往上翻看历史"的场景：     │
//  │   1. AI 摘要生成（RepoAIWindowContentView.summarySection，         │
//  │      token-by-token 写 streamingSummaryText）                       │
//  │   2. AI 对话回答（同文件 chatSection，streamingMessage 增量改）   │
//  │   3. 未来批量队列日志 / 任意其它 streaming 输出                    │
//  │ 三者的"跟随策略"完全一致：                                          │
//  │   - 流式中且用户在底部 → 自动 scrollTo(.bottom)                     │
//  │   - 用户开始主动滚动 → 立即停止跟随                                 │
//  │   - 用户结束滚动且停在底部 → 恢复跟随                               │
//  │ 状态机接收三类单向信号：用户滚动 phase、底部锚点可见性、           │
//  │ 已完成布局的内容高度。高度只触发滚动，不参与判断用户是否到底。     │
//  └──────────────────────────────────────────────────────────────────┘
//
//  关键约束 / 已踩过的坑（写之前的考量，避免后续 reviewer 重新踩一遍）：
//
//  1. **位置真源只能是底部 sentinel 的可见性**：contentSize / offset 会被
//     Markdown 重排、窗口尺寸和流式内容增长同时改变，不能代表用户是否到底。
//
//  2. **必须按 ScrollPhase 生命周期判断用户意图**：`scrollTo(...)` 自己触发的
//     phase 是 `.animating`，不能暂停跟随；`.tracking / .interacting /
//     .decelerating` 表示用户正在控制滚动，一进入就立即暂停；只有从用户 phase
//     回到 `.idle`，并且底部 sentinel 可见，才恢复跟随。
//
//  3. **sentinel 不可见不能主动关闭跟随**：流式内容增长时锚点会短暂离开可视区，
//     随后自动 scrollTo 拉回。如果据此关闭跟随，会把自身布局变化误判成用户意图。
//
//  4. **初始 isFollowing = true**：用户打开窗口默认期待"自动跟随最
//     新输出"，这个默认值与生成流程的预期 100% 吻合。
//
//  5. **浮动「滚到底部」入口由调用方可选**：状态机本身不画按钮。按钮显隐应
//     以滚动几何（是否离底）为准，不要直接绑 `isFollowing`——否则鼠标移入
//     底部 overlay 时 phase/sentinel 抖动会把按钮闪掉，并在滚动中反复刷新。
//

import SwiftUI

/// 对话区顶部 overscroll 检测需要的最小 geometry 快照。
struct ScrollFollowTailMetrics: Equatable {
    let offsetY: CGFloat
}

/// 「跟随尾部」状态机。
///
/// 由 @Observable + @State 组合在 view 中持有（macOS 15+ 标准做法）。
/// 因为它只代表"UI 滚动状态"（不属于业务 ViewModel），生命周期与 view 一致。
///
/// 调用方需要做 3 件事：
///   1. `@State private var tail = ScrollTailController()`，在 ScrollViewReader
///      内部读 `tail.isFollowing` 决定要不要 scrollTo；
///   2. 用 `.onScrollPhaseChange` 传用户 phase，用底部 sentinel 的
///      `.onScrollVisibilityChange` 传是否真正到底；
///   3. 内容实际高度变化后询问 `shouldFollowContentHeightChange`，返回 true
///      时在下一次 MainActor 调度中执行 `proxy.scrollTo(...)`，等待 contentSize 提交。
@MainActor
@Observable
final class ScrollTailController {

    /// 当前是否处于"自动跟随尾部"状态。
    ///
    /// view 只读它决定流式 trigger 变化时是否调 `proxy.scrollTo(.bottom)`。
    private(set) var isFollowing: Bool = true

    /// 最近一次的滚动相位。
    ///
    /// 主要给本控制器识别完整用户滚动生命周期。也暴露给对话段那种
    /// "还需要顺带判 overscroll"的场景复用同一个 phase 状态，避免一个
    /// view 上挂两个 onScrollPhaseChange。
    @ObservationIgnored private(set) var lastPhase: ScrollPhase = .idle

    /// 底部 sentinel 当前是否可见。它是“是否到底”的唯一位置真源。
    @ObservationIgnored private var isBottomVisible: Bool = true

    /// 当前滚动生命周期是否由用户手势发起。
    @ObservationIgnored private var isUserScrollInProgress: Bool = false

    /// 最近一次由内容增长触发的滚动时间。它只做限频，不是 UI 状态，变化时不能发布 Observation。
    @ObservationIgnored private var lastAutomaticScrollAt: TimeInterval?

    /// 流式 Markdown 快照约 10Hz；尾随滚动控制在 5Hz，避免每次布局都重算可视区域。
    private let minimumAutomaticScrollInterval: TimeInterval

    init(minimumAutomaticScrollInterval: TimeInterval = 0.20) {
        self.minimumAutomaticScrollInterval = max(0, minimumAutomaticScrollInterval)
    }

    /// SwiftUI 把滚动 phase 递给控制器。
    func updatePhase(_ phase: ScrollPhase) {
        lastPhase = phase

        switch phase {
        case .tracking, .interacting, .decelerating:
            // 用户一接管滚动就立即暂停，不能等距离变化；否则下一次流式 token
            // 可能抢先 scrollTo(.bottom)，覆盖用户刚开始的滚动操作。
            isUserScrollInProgress = true
            setFollowing(false)
        case .idle:
            guard isUserScrollInProgress else { return }
            isUserScrollInProgress = false
            // 仅在用户滚动生命周期结束后恢复。滚动过程中即使经过底部也不恢复，
            // 避免 bounce / 惯性尚未结束时被新 token 再次拉动。
            if isBottomVisible {
                setFollowing(true)
            }
        case .animating:
            // 程序化 scrollTo 不代表用户接管，保持当前跟随状态。
            break
        @unknown default:
            break
        }
    }

    /// 底部锚点可见性变化。不可见只记录，不主动关闭跟随；可见且用户手势已经
    /// 结束时恢复，兼容“idle 回调早于 visibility 回调”的系统时序。
    func updateBottomVisibility(_ isVisible: Bool) {
        guard isBottomVisible != isVisible else { return }
        isBottomVisible = isVisible
        if isVisible, !isUserScrollInProgress, lastPhase == .idle {
            setFollowing(true)
        }
    }

    /// 根据“已完成布局”的内容高度变化决定是否重新贴底。
    ///
    /// 增长来自 token / Markdown 重排，按时间窗口合并；缩短通常来自执行阶段折叠，
    /// 必须立即校正，否则旧 contentSize 会让视口停在已经不存在的空白区域。
    /// 高度变化只决定“何时滚”，底部 sentinel 仍是“滚到哪里”的唯一真源。
    func shouldFollowContentHeightChange(
        from oldHeight: CGFloat,
        to newHeight: CGFloat,
        now: TimeInterval
    ) -> Bool {
        guard isFollowing else { return false }
        guard abs(newHeight - oldHeight) > 0.5 else { return false }

        if newHeight < oldHeight {
            lastAutomaticScrollAt = now
            return true
        }

        if let lastAutomaticScrollAt,
           now - lastAutomaticScrollAt < minimumAutomaticScrollInterval {
            return false
        }
        lastAutomaticScrollAt = now
        return true
    }

    /// 用户主动离开尾部（如大纲跳转）：立即停止跟随，避免流式输出把视口拽回底部。
    func pauseFollowing() {
        setFollowing(false)
    }

    /// 用户点击「滚到底部」：恢复跟随；真正对齐由调用方 `scrollTo` 完成。
    func resumeFollowing() {
        setFollowing(true)
        // 手动“滚到底部”和新会话安装都应立即生效，不能继承上一段流式输出的限频窗口。
        lastAutomaticScrollAt = nil
    }

    /// Observation 不会替我们过滤“新旧值相同”的写入。统一走这里，避免滚动可见性
    /// 回调在 SwiftUI 布局期间重复发布同一状态，形成布局与状态更新互相触发的反馈环。
    private func setFollowing(_ newValue: Bool) {
        guard isFollowing != newValue else { return }
        isFollowing = newValue
    }
}
