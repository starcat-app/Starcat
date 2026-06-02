//
//  ListRowRevealModifier.swift
//  Starcat
//
//  通用列表行渐进式入场动画。
//
//  设计目的：
//  - 让 List 首屏和滚动中新进入可视区域的 row 有轻量 reveal 反馈。
//  - 不改变数据加载策略，不引入数据库分页 / 无限滚动复杂度。
//  - 尊重系统 Reduce Motion 设置，避免给不希望动效的用户增加负担。
//

import SwiftUI

extension View {
    /// 列表 row 的轻量渐进式入场动画。
    ///
    /// 这不是数据分页：数据仍由对应 ViewModel 按原策略加载。SwiftUI `List` 会懒创建
    /// 当前可视区域附近的 row，因此 `.onAppear` 可覆盖“首屏逐行出现”和
    /// “滚动到新 row 时再出现”两个体验点，成本远低于真正分页。
    ///
    /// - Parameters:
    ///   - index: row 在当前快照中的顺序，只用于计算短 stagger delay。
    ///   - snapshotID: 列表快照版本；快照变化时重新播放 reveal。
    func listRowReveal(index: Int, snapshotID: Int) -> some View {
        modifier(ListRowRevealModifier(index: index, snapshotID: snapshotID))
    }
}

/// 通用 row reveal modifier。
///
/// 关键约束：
/// - 用取模 delay，而不是 `index * delay`，避免滚动到很靠后的 row 时出现长时间等待。
/// - 只做 opacity + 小幅 y-offset，不参与 layout 大小变化，降低 List 重排风险。
/// - 不做数据库层分页；真正 pagination 需要单独设计 cursor / 排序 / 搜索 / 缓存一致性。
private struct ListRowRevealModifier: ViewModifier {
    let index: Int
    let snapshotID: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || reduceMotion ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 7)
            .onAppear(perform: reveal)
            .onChange(of: snapshotID) { _, _ in
                reveal()
            }
    }

    private func reveal() {
        guard !reduceMotion else {
            isVisible = true
            return
        }

        isVisible = false
        let delay = min(Double(index % 14) * 0.012, 0.16)
        withAnimation(.easeOut(duration: 0.22).delay(delay)) {
            isVisible = true
        }
    }
}
