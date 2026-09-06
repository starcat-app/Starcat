//
//  ListRowRevealModifier.swift
//  Starcat
//
//  通用列表行渐进式入场动画。
//
//  设计目的：
//  - 让 List 首屏 row 有轻量 reveal 反馈；更深的行直接显示，避免滚动时反复建状态。
//  - 不改变数据加载策略，不引入数据库分页 / 无限滚动复杂度。
//  - 尊重系统 Reduce Motion 设置，避免给不希望动效的用户增加负担。
//

import SwiftUI

/// Repo List 行动画的统一边界；独立成可测试的纯值，避免各模块各写一个 14 / 15。
enum ListRowRevealMetrics {
    static let animatedRowLimit = 15

    static func shouldAnimate(index: Int) -> Bool {
        index >= 0 && index < animatedRowLimit
    }
}

extension View {
    /// 列表 row 的轻量渐进式入场动画。
    ///
    /// 这不是数据分页：数据仍由对应 ViewModel 按原策略加载。只有前 15 行保留
    /// `.onAppear` 动画，更深的行不持有动画状态，避免滚动时额外触发 transaction。
    ///
    /// - Parameters:
    ///   - index: row 在当前快照中的顺序，只用于计算短 stagger delay。
    ///   - snapshotID: 列表快照版本；快照变化时重新播放 reveal。
    ///   - skipAnimation: 少数调用方可显式跳过行动画（例如 Activity 切分类性能兜底）。
    ///     默认 false；排序切换 / 首次加载仍保留 reveal。
    ///   - replayAfterSnapshotCommit: 是否在快照变化后先提交一帧隐藏状态再播放。
    ///     默认关闭，避免改变现有列表的分页 / 刷新行为；只给明确拥有“发布完成”触发器的列表启用。
    @ViewBuilder
    func listRowReveal(
        index: Int,
        snapshotID: Int,
        skipAnimation: Bool = false,
        replayAfterSnapshotCommit: Bool = false
    ) -> some View {
        // 只有首屏 15 行需要 reveal。更深的行直接返回原 View，避免给长列表每一行都
        // 分配两份 @State 和三个生命周期回调。
        if ListRowRevealMetrics.shouldAnimate(index: index) {
            modifier(ListRowRevealModifier(
                index: index,
                snapshotID: snapshotID,
                skipAnimation: skipAnimation,
                replayAfterSnapshotCommit: replayAfterSnapshotCommit
            ))
        } else {
            self
        }
    }
}

/// 通用 row reveal modifier。
///
/// 关键约束：
/// - 用取模 delay，而不是 `index * delay`，避免滚动到很靠后的 row 时出现长时间等待。
/// - 只做 opacity + 小幅 y-offset，不参与 layout 大小变化，降低 List 重排风险。
/// - 不做数据库层分页；真正 pagination 需要单独设计 cursor / 排序 / 搜索 / 缓存一致性。
/// - `skipAnimation` 旁路只留给明确不应播放行动画的调用方；普通列表切换继续保留 reveal。
///   逻辑等价于 reduceMotion，但语义不同——这是性能兜底，不是无障碍诉求。
private struct ListRowRevealModifier: ViewModifier {
    let index: Int
    let snapshotID: Int
    let skipAnimation: Bool
    let replayAfterSnapshotCommit: Bool

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatListInteractionSuppressed) private var interactionSuppressed
    @State private var isVisible = false
    @State private var revealGeneration = 0

    /// 是否跳过动画。
    ///
    /// 首屏前 15 行覆盖最大化窗口的可见卡片；List 预创建的屏外 rows 如果继续持有 delay/animation
    /// 状态，会在分类切换时放大主线程事务。屏外行直接显示，滚动体验也更稳定。
    private var bypassAnimation: Bool {
        reduceMotion || skipAnimation || interactionSuppressed
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || bypassAnimation ? 1 : 0)
            .offset(y: isVisible || bypassAnimation ? 0 : 7)
            .onAppear {
                reveal(afterRenderCommit: false)
            }
            .onChange(of: snapshotID) { _, _ in
                reveal(afterRenderCommit: replayAfterSnapshotCommit)
            }
            .onDisappear {
                guard replayAfterSnapshotCommit else { return }
                // 让已经离屏的 row 取消下一帧待执行的 reveal，避免快速切换后旧任务回写。
                revealGeneration &+= 1
            }
            .onChange(of: interactionSuppressed) { _, isSuppressed in
                guard isSuppressed else { return }
                revealGeneration &+= 1
                isVisible = true
            }
    }

    private func reveal(afterRenderCommit: Bool) {
        guard afterRenderCommit else {
            revealImmediately()
            return
        }

        revealGeneration &+= 1
        let generation = revealGeneration

        guard !bypassAnimation else {
            isVisible = true
            return
        }

        isVisible = false
        // SwiftUI 可能合并同一轮更新里的 false -> true；非阻塞等待约一个显示帧，
        // 让隐藏状态先有机会提交。只有首屏最多 15 个 row 会走到这里。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard generation == revealGeneration else { return }
            animateReveal()
        }
    }

    private func revealImmediately() {
        guard !bypassAnimation else {
            isVisible = true
            return
        }

        isVisible = false
        animateReveal()
    }

    private func animateReveal() {
        let delay = min(Double(index % ListRowRevealMetrics.animatedRowLimit) * 0.012, 0.17)
        withAnimation(.easeOut(duration: 0.22).delay(delay)) {
            isVisible = true
        }
    }
}
