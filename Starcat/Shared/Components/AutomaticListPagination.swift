//
//  AutomaticListPagination.swift
//  Starcat
//
//  自动分页列表的统一预取策略与 SwiftUI 触发器。
//
//  行级 `.onAppear` 只发生一次：如果行在刷新或上一页加载期间出现，简单的 loading guard
//  会永久丢掉这次需求。本组件观察已加载数量与列表身份；只要成功加载产生了新列表快照，
//  且已出现的行按最新数量仍位于预取窗口，SwiftUI 就会重新评估；
//  失败时数量不变，因此不会形成自动重试死循环。
//

import SwiftUI

/// Starcat 自动分页列表共享的尾部预取规则。
enum ListPaginationPolicy {
    /// 距当前可见窗口尾部还剩 10 行时开始预取，兼顾快速滚动与无效提前加载。
    static let prefetchDistance = 10

    static func shouldPrefetch(
        appearingIndex: Int,
        itemCount: Int,
        hasMore: Bool
    ) -> Bool {
        guard hasMore, itemCount > 0, appearingIndex >= 0, appearingIndex < itemCount else {
            return false
        }
        let remainingCount = itemCount - appearingIndex - 1
        return remainingCount <= prefetchDistance
    }

    /// 全局筛选可能把已加载页过滤为空；此时没有 row 能触发预取，需要主动补齐可见窗口。
    static func shouldFillVisibleWindow(visibleItemCount: Int, hasMore: Bool) -> Bool {
        hasMore && visibleItemCount < prefetchDistance
    }
}

private struct AutomaticListPaginationTaskID: Hashable {
    let identity: String
    let appearingIndex: Int
    let visibleItemCount: Int
    let loadedItemCount: Int
    let hasMore: Bool
}

private struct AutomaticListPaginationModifier: ViewModifier {
    let appearingIndex: Int
    let visibleItemCount: Int
    let loadedItemCount: Int
    let hasMore: Bool
    let isLoading: Bool
    let identity: String
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { requestIfNeeded() }
            .onChange(of: taskID) { _, _ in requestIfNeeded() }
    }

    private func requestIfNeeded() {
        guard !isLoading,
              ListPaginationPolicy.shouldPrefetch(
                  appearingIndex: appearingIndex,
                  itemCount: visibleItemCount,
                  hasMore: hasMore
              ) else { return }
        Task { await action() }
    }

    private var taskID: AutomaticListPaginationTaskID {
        AutomaticListPaginationTaskID(
            identity: identity,
            appearingIndex: appearingIndex,
            visibleItemCount: visibleItemCount,
            loadedItemCount: loadedItemCount,
            hasMore: hasMore
        )
    }
}

private struct AutomaticListPaginationFillModifier: ViewModifier {
    let visibleItemCount: Int
    let loadedItemCount: Int
    let hasMore: Bool
    let isLoading: Bool
    let identity: String
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { requestIfNeeded() }
            .onChange(of: taskID) { _, _ in requestIfNeeded() }
    }

    private func requestIfNeeded() {
        guard !isLoading,
              ListPaginationPolicy.shouldFillVisibleWindow(
                  visibleItemCount: visibleItemCount,
                  hasMore: hasMore
              ) else { return }
        Task { await action() }
    }

    private var taskID: AutomaticListPaginationTaskID {
        AutomaticListPaginationTaskID(
            identity: identity,
            appearingIndex: -1,
            visibleItemCount: visibleItemCount,
            loadedItemCount: loadedItemCount,
            hasMore: hasMore
        )
    }
}

extension View {
    /// 行进入统一预取窗口时加载下一页；成功追加后会按最新列表快照重新评估。
    func automaticListPagination(
        appearingIndex: Int,
        visibleItemCount: Int,
        loadedItemCount: Int,
        hasMore: Bool,
        isLoading: Bool,
        identity: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(AutomaticListPaginationModifier(
            appearingIndex: appearingIndex,
            visibleItemCount: visibleItemCount,
            loadedItemCount: loadedItemCount,
            hasMore: hasMore,
            isLoading: isLoading,
            identity: identity,
            action: action
        ))
    }

    /// 过滤结果不足一屏时继续读取底层分页，直到出现可滚动窗口或数据耗尽。
    func automaticListPaginationFill(
        visibleItemCount: Int,
        loadedItemCount: Int,
        hasMore: Bool,
        isLoading: Bool,
        identity: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(AutomaticListPaginationFillModifier(
            visibleItemCount: visibleItemCount,
            loadedItemCount: loadedItemCount,
            hasMore: hasMore,
            isLoading: isLoading,
            identity: identity,
            action: action
        ))
    }
}
