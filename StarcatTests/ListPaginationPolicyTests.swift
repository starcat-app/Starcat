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
        #expect(ListPaginationPolicy.repoCardPageSize == 20)
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

    @Test("可滚动的首批停在顶部时不追加，筛选补页保留预算")
    func prefetchRequiresScrollOrAFullUnscrollableWindow() {
        #expect(!ListPaginationPolicy.canPrefetchFromViewport(
            offsetFromTop: 0, documentHeight: 1_400, viewportHeight: 1_000, visibleItemCount: 20
        ))
        #expect(ListPaginationPolicy.canPrefetchFromViewport(
            offsetFromTop: 20, documentHeight: 1_400, viewportHeight: 1_000, visibleItemCount: 20
        ))
        #expect(ListPaginationPolicy.canPrefetchFromViewport(
            offsetFromTop: 0, documentHeight: 1_400, viewportHeight: 1_500, visibleItemCount: 20
        ))
        #expect(!ListPaginationPolicy.canPrefetchFromViewport(
            offsetFromTop: 0, documentHeight: 280, viewportHeight: 1_000, visibleItemCount: 3
        ))
    }

    @Test("同一页的尾行只追加一次，追加后按新尾部判断")
    @MainActor
    func claimsOneRequestPerPage() {
        let gate = RepoCardPaginationGate()
        let first = RepoCardPaginationPage(identity: "query", visibleItemCount: 20, loadedItemCount: 20, hasMore: true)
        let second = RepoCardPaginationPage(identity: "query", visibleItemCount: 40, loadedItemCount: 40, hasMore: true)
        gate.update(first, isLoading: false)
        #expect(!gate.claim(first, appearingIndex: 8))
        #expect(gate.claim(first, appearingIndex: 9))
        #expect(!gate.claim(first, appearingIndex: 19))

        gate.update(second, isLoading: true)
        #expect(!gate.claim(second, appearingIndex: 39))
        gate.update(second, isLoading: false)
        #expect(!gate.claim(first, appearingIndex: 19))
        #expect(!gate.claim(second, appearingIndex: 19))
        #expect(gate.claim(second, appearingIndex: 39))
    }

    @Test("过滤补页消费同一页，失败后忙闲切换不会自动重试")
    @MainActor
    func fillAndVisibleRowShareAttempt() {
        let gate = RepoCardPaginationGate()
        let first = RepoCardPaginationPage(identity: "filter", visibleItemCount: 3, loadedItemCount: 20, hasMore: true)
        gate.update(first, isLoading: false)
        #expect(gate.claim(first, appearingIndex: nil))
        #expect(!gate.claim(first, appearingIndex: 2))
        gate.update(first, isLoading: true)
        gate.update(first, isLoading: false)
        #expect(!gate.claim(first, appearingIndex: nil))

        let changedQuery = RepoCardPaginationPage(identity: "new", visibleItemCount: 3, loadedItemCount: 20, hasMore: true)
        gate.update(changedQuery, isLoading: false)
        #expect(!gate.claim(first, appearingIndex: 2))
        #expect(gate.claim(changedQuery, appearingIndex: nil))
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

    @Test("瀑布流追加新页不重排历史卡片")
    func appendsMasonryPageWithoutRebuildingPrefix() {
        var columns = SmartCollectionMasonryDistribution.distribute(
            Array(0..<40),
            columnCount: 3
        )
        let prefixColumns = columns

        SmartCollectionMasonryDistribution.append(
            Array(40..<80),
            startingAt: 40,
            to: &columns
        )

        #expect(columns == SmartCollectionMasonryDistribution.distribute(
            Array(0..<80),
            columnCount: 3
        ))
        #expect(zip(prefixColumns, columns).allSatisfy { prefix, appended in
            Array(appended.prefix(prefix.count)) == prefix
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
