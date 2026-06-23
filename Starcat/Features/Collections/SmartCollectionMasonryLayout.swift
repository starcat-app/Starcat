//
//  SmartCollectionMasonryLayout.swift
//  Starcat
//
//  智能集合右栏瀑布流：多列 LazyVStack + 按序轮转分列。
//
//  为什么不用自定义 `Layout` 最短列算法：
//  - 卡片内含 `GeometryReader`（topic chip 行）时，`sizeThatFits(height: nil)` 会
//    在 ScrollView 内触发布局反馈环，实测导致主界面卡死；
//  - `HStack + LazyVStack` 由系统 lazy 管线处理变高卡片，稳定且支持分页 onAppear。
//
//  分列策略：index % columnCount（左→右轮转）。高度参差时视觉仍是瀑布流，
//  且 LazyVStack 只渲染可见卡片，滚动 + 分页更省。
//
//  P0 性能：调用方预计算 `columns` 后传入，避免 body 每帧对全量 items 做 O(n×列数) 扫描。
//

import SwiftUI

/// 瀑布流分列工具（非 View，避免泛型推断歧义）。
enum SmartCollectionMasonryDistribution {
    /// 按 index % columnCount 轮转分列；与旧 `itemsForColumn` 语义一致。
    static func distribute<Item>(_ items: [Item], columnCount: Int) -> [[Item]] {
        let count = max(1, columnCount)
        var buckets = (0..<count).map { _ in [Item]() }
        for (index, item) in items.enumerated() {
            buckets[index % count].append(item)
        }
        return buckets
    }
}

/// 多列瀑布流容器（仅 Smart Collection 右栏使用）。
struct SmartCollectionMasonryStack<Item: Identifiable, Content: View>: View {
    let columns: [[Item]]
    let spacing: CGFloat
    @ViewBuilder var content: (Item) -> Content

    /// 推荐路径：调用方在 `visibleRepos` / `columnCount` 变化时预计算分列 bucket。
    init(
        columns: [[Item]],
        spacing: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.columns = columns
        self.spacing = spacing
        self.content = content
    }

    /// 骨架屏等轻量场景：items 少，body 内临时分列可接受。
    init(
        items: [Item],
        columnCount: Int,
        spacing: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.columns = SmartCollectionMasonryDistribution.distribute(items, columnCount: columnCount)
        self.spacing = spacing
        self.content = content
    }

    /// 按 index % columnCount 轮转分列；与旧 `itemsForColumn` 语义一致。
    static func distribute(_ items: [Item], columnCount: Int) -> [[Item]] {
        SmartCollectionMasonryDistribution.distribute(items, columnCount: columnCount)
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, columnItems in
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(columnItems) { item in
                        content(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
