//
//  AmbientGridView.swift
//  Starcat
//
//  五行 Ambient 网格的几何与渲染。方格按实际 content height 定边，横向使用
//  ceil 列数超宽铺放并由 viewport 居中裁切，形成无边距、无缝隙的全屏图片墙。
//

import Foundation
import SwiftUI

/// 从当前 SwiftUI content geometry 推导五行 full-bleed tile 和裁切宽度。
struct AmbientGridMetrics: Equatable, Sendable {
    static let rowCount = 5

    let tilePointSize: Double
    let columnCount: Int
    let contentWidth: Double
    let contentHeight: Double
    let viewportWidth: Double
    let viewportHeight: Double
    let isUsable: Bool

    init(size: CGSize) {
        let width = max(1, Double(size.width))
        let height = max(1, Double(size.height))
        let tile = max(1, height / Double(Self.rowCount))
        // 多取完整一列并居中裁切，而不是缩小 tile 或留下左右黑边。
        let columns = max(1, Int(ceil(width / tile)))

        tilePointSize = tile
        columnCount = columns
        contentWidth = Double(columns) * tile
        contentHeight = Double(Self.rowCount) * tile
        viewportWidth = width
        viewportHeight = height
        // AppKit 全屏切换期间可能短暂送出 0×0 / 极小 content size；这些不是可展示布局。
        isUsable = size.width >= 100 && size.height >= 200
    }

    func layout(displayScale: Double) -> AmbientGridLayout {
        AmbientGridLayout(
            config: AmbientGridConfig(rowCount: Self.rowCount, columnCount: columnCount),
            tilePointSize: tilePointSize,
            displayScale: displayScale
        )
    }
}

/// 已加载状态的固定五行无缝图片墙。
struct AmbientGridView: View {
    let snapshots: [AmbientSlotSnapshot]
    let metrics: AmbientGridMetrics
    let changedSlotIDs: Set<Int>
    let flipDuration: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 0) {
            ForEach(snapshots) { snapshot in
                AmbientCellView(
                    snapshot: snapshot,
                    tilePointSize: metrics.tilePointSize,
                    flipDuration: flipDuration,
                    animatesCardChange: !reduceMotion && changedSlotIDs.contains(snapshot.id)
                )
            }
        }
        .frame(width: metrics.contentWidth, height: metrics.contentHeight)
        // 外层 viewport 只负责裁掉左右超出的半格；不能缩放内层网格，否则 tile 不再是正方形。
        .frame(width: metrics.viewportWidth, height: metrics.viewportHeight)
        .clipped()
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(metrics.tilePointSize),
                spacing: 0,
                alignment: .center
            ),
            count: metrics.columnCount
        )
    }
}
