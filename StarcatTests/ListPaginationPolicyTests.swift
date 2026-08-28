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
