//
//  ListPaginationPolicyTests.swift
//  StarcatTests
//
//  锁住自动分页的统一 10 行预取窗口与过滤后空窗口补页边界。
//

import Testing
@testable import Starcat

@Suite("ListPaginationPolicy")
struct ListPaginationPolicyTests {
    @Test("剩余 10 行时开始预取")
    func prefetchesWithTenRowsRemaining() {
        #expect(ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 29,
            itemCount: 40,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 28,
            itemCount: 40,
            hasMore: true
        ))
    }

    @Test("短列表和边界索引保持安全")
    func handlesShortListsAndInvalidIndices() {
        #expect(ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 0,
            itemCount: 1,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 0,
            itemCount: 0,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 40,
            itemCount: 40,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldPrefetch(
            appearingIndex: 39,
            itemCount: 40,
            hasMore: false
        ))
    }

    @Test("瀑布流分列后两列都能进入统一预取窗口")
    func prefetchesAcrossMasonryColumnsUsingSourceIndices() {
        let columns = SmartCollectionMasonryDistribution.distribute(
            Array(0..<16),
            columnCount: 2
        )

        #expect(columns == [
            [0, 2, 4, 6, 8, 10, 12, 14],
            [1, 3, 5, 7, 9, 11, 13, 15]
        ])
        #expect(columns.allSatisfy { column in
            column.contains { index in
                ListPaginationPolicy.shouldPrefetch(
                    appearingIndex: index,
                    itemCount: 16,
                    hasMore: true
                )
            }
        })
    }

    @Test("宽屏瀑布流按纵向行数判断首屏补页")
    func countsMasonryRowsForVisibleWindowFill() {
        #expect(SmartCollectionMasonryDistribution.rowCount(itemCount: 0, columnCount: 7) == 0)
        #expect(SmartCollectionMasonryDistribution.rowCount(itemCount: 40, columnCount: 7) == 6)
        #expect(SmartCollectionMasonryDistribution.rowCount(itemCount: 80, columnCount: 7) == 12)

        #expect(ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: SmartCollectionMasonryDistribution.rowCount(itemCount: 40, columnCount: 7),
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: SmartCollectionMasonryDistribution.rowCount(itemCount: 80, columnCount: 7),
            hasMore: true
        ))
    }

    @Test("过滤后不足预取窗口时继续补页")
    func fillsFilteredVisibleWindow() {
        #expect(ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: 0,
            hasMore: true
        ))
        #expect(ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: 9,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: 10,
            hasMore: true
        ))
        #expect(!ListPaginationPolicy.shouldFillVisibleWindow(
            visibleItemCount: 0,
            hasMore: false
        ))
    }
}
