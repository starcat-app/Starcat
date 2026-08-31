//
//  SmartCollectionChipLayoutPolicy.swift
//  Starcat
//
//  智能集合卡片的 chip 单行裁剪策略。
//
//  关键约束：这里只消费上层已经确定的可用宽度，不能在卡片内部通过
//  `GeometryReader` 反向测量。后者与 ScrollView 中的多列 LazyVStack 组合时，
//  会让卡片宽度和父级高度互相触发布局，最终形成 AttributeGraph 反馈环。
//

import CoreGraphics

/// 描述单行 chip 在给定宽度下应展示多少真实项，以及是否需要尾部省略项。
struct SmartCollectionChipLayoutDecision: Equatable {
    let visibleChipCount: Int
    let showsOverflow: Bool
}

/// 纯计算的 chip 裁剪策略，供 SwiftUI View 与单元测试共同使用。
enum SmartCollectionChipLayoutPolicy {
    /// 从左到右贪心放置 chip；只要仍有未展示项，就为尾部省略 chip 预留宽度。
    ///
    /// 该方法不读取任何 View 几何状态，保证滚动期间同一输入始终得到同一结果。
    static func resolve(
        chipWidths: [CGFloat],
        availableWidth: CGFloat,
        spacing: CGFloat,
        overflowWidth: CGFloat
    ) -> SmartCollectionChipLayoutDecision {
        guard availableWidth > 0 else {
            return SmartCollectionChipLayoutDecision(visibleChipCount: 0, showsOverflow: false)
        }

        var visibleChipCount = 0
        var usedWidth: CGFloat = 0

        for (index, chipWidth) in chipWidths.enumerated() {
            let leadingSpacing = visibleChipCount == 0 ? 0 : spacing
            let hasRemainingChips = index < chipWidths.index(before: chipWidths.endIndex)
            let overflowReserve = hasRemainingChips ? spacing + overflowWidth : 0

            if usedWidth + leadingSpacing + chipWidth + overflowReserve <= availableWidth {
                usedWidth += leadingSpacing + chipWidth
                visibleChipCount += 1
                continue
            }

            let overflowLeadingSpacing = visibleChipCount == 0 ? 0 : spacing
            let showsOverflow = usedWidth + overflowLeadingSpacing + overflowWidth <= availableWidth
            return SmartCollectionChipLayoutDecision(
                visibleChipCount: visibleChipCount,
                showsOverflow: showsOverflow
            )
        }

        return SmartCollectionChipLayoutDecision(
            visibleChipCount: visibleChipCount,
            showsOverflow: false
        )
    }
}
