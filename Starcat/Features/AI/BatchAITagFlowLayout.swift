//
//  BatchAITagFlowLayout.swift
//  Starcat
//
//  批量标签审核芯片的横向自动换行布局。
//
//  该布局沿用 GitHub Lists 推荐分组的紧凑排列方式：芯片按内容宽度排列，
//  当前行空间不足时整体换到下一行，避免固定网格把短标签拉伸成大卡片。
//

import SwiftUI

/// 为批量标签审核芯片提供按内容宽度自动换行的布局。
struct BatchAITagFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    /// 先测量每个芯片，再按可用宽度计算行起点；测量与放置必须复用同一算法，
    /// 否则 SwiftUI 在窗口缩放时会出现高度和实际行数不一致的跳动。
    private func layout(
        in width: CGFloat,
        subviews: Subviews
    ) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = max(width, 1)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (origins, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
