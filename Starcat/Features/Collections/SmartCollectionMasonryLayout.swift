//
//  SmartCollectionMasonryLayout.swift
//  Starcat
//
//  智能集合右栏瀑布流：多列 LazyVStack + 按序轮转分列。
//
//  为什么不用自定义 `Layout` 最短列算法：
//  - `sizeThatFits(height: nil)` 与变高卡片组合时容易触发布局反馈环；
//  - `HStack + LazyVStack` 由系统 lazy 管线处理变高卡片，支持分页 onAppear。
//
//  关键约束：卡片内部禁止用 `GeometryReader` 反向读取列宽。可用宽度必须由
//  `SmartCollectionDetailPanel` 根据容器宽度和列数一次算出后向下传递，否则滚动
//  预取会反复污染 AttributeGraph，最终让主线程持续满载。
//
//  分列策略：index % columnCount（左→右轮转）。高度参差时视觉仍是瀑布流，
//  且 LazyVStack 只渲染可见卡片，滚动 + 分页更省。
//
//  P0 性能：调用方预计算 `columns` 后传入，避免 body 每帧对全量 items 做 O(n×列数) 扫描。
//

import SwiftUI

/// 瀑布流分列工具（非 View，避免泛型推断歧义）。
enum SmartCollectionMasonryDistribution {
    /// 把卡片数量换算成纵向行数。分页填充必须按行判断，否则宽屏多列会把 40 张卡片
    /// 误判为 40 行，首屏实际只有数行且无法滚动时也不会继续取下一页。
    static func rowCount(itemCount: Int, columnCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let count = max(1, columnCount)
        return (itemCount + count - 1) / count
    }

    /// 按 index % columnCount 轮转分列；与旧 `itemsForColumn` 语义一致。
    static func distribute<Item>(_ items: [Item], columnCount: Int) -> [[Item]] {
        let count = max(1, columnCount)
        var buckets = (0..<count).map { _ in [Item]() }
        for (index, item) in items.enumerated() {
            buckets[index % count].append(item)
        }
        return buckets
    }

    /// 把新页直接追加到既有 bucket，保持 `index % columnCount` 的稳定顺序。
    /// 调用方必须传底层结果中的起始索引；这样追加一页只做 O(pageSize)，不会重新分发历史卡片。
    static func append<Item>(
        _ items: [Item],
        startingAt startIndex: Int,
        to columns: inout [[Item]]
    ) {
        guard !columns.isEmpty else { return }
        for (offset, item) in items.enumerated() {
            columns[(startIndex + offset) % columns.count].append(item)
        }
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
