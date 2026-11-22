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

import AppKit
import SwiftUI

/// Starcat 自动分页列表共享的尾部预取规则。
enum ListPaginationPolicy {
    /// 主窗口中栏仓库卡片的首批及增量页大小。
    static let repoCardPageSize = 20

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

    /// 稀疏首屏由筛选补页逻辑处理，避免无滚动空间时绕过来源的补页预算。
    static func canPrefetchFromViewport(
        offsetFromTop: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        visibleItemCount: Int
    ) -> Bool {
        offsetFromTop > 1 ||
            (visibleItemCount >= prefetchDistance && documentHeight <= viewportHeight + 1)
    }
}

struct RepoCardPaginationPage: Equatable, Sendable {
    let identity: String
    let visibleItemCount: Int
    let loadedItemCount: Int
    let hasMore: Bool
}

/// 中栏列表内同一页可能有多个尾部行同时可见。共享一个请求闸门，首个回调消费当前页，其余回调等待新快照。
@MainActor
final class RepoCardPaginationGate {
    private(set) var page: RepoCardPaginationPage?
    private var isLoading = false
    private var didRequestPage = false

    func update(_ page: RepoCardPaginationPage?, isLoading: Bool) {
        if self.page != page { didRequestPage = false }
        self.page = page
        self.isLoading = isLoading
    }

    func claim(_ page: RepoCardPaginationPage, appearingIndex: Int?) -> Bool {
        guard self.page == page, !isLoading, !didRequestPage else { return false }
        if let appearingIndex {
            guard ListPaginationPolicy.shouldPrefetch(
                appearingIndex: appearingIndex, itemCount: page.visibleItemCount, hasMore: page.hasMore
            ) else { return false }
        } else {
            guard ListPaginationPolicy.shouldFillVisibleWindow(
                visibleItemCount: page.visibleItemCount, hasMore: page.hasMore
            ) else { return false }
        }
        didRequestPage = true
        return true
    }
}

private struct RepoCardPaginationContext: Sendable {
    let page: RepoCardPaginationPage
    let isLoading: Bool
    let gate: RepoCardPaginationGate
    let action: @MainActor () async -> Void

    @MainActor
    func request(appearingIndex: Int?) {
        Task {
            guard gate.claim(page, appearingIndex: appearingIndex) else { return }
            await action()
        }
    }
}

private struct RepoCardPaginationContextKey: EnvironmentKey {
    static let defaultValue: RepoCardPaginationContext? = nil
}

private extension EnvironmentValues {
    var repoCardPaginationContext: RepoCardPaginationContext? {
        get { self[RepoCardPaginationContextKey.self] }
        set { self[RepoCardPaginationContextKey.self] = newValue }
    }
}

private struct RepoCardPaginationContainer: ViewModifier {
    let page: RepoCardPaginationPage
    let isLoading: Bool
    let fillsFilteredWindow: Bool
    let action: @MainActor () async -> Void
    @State private var gate = RepoCardPaginationGate()

    private struct Inputs: Equatable {
        let page: RepoCardPaginationPage
        let isLoading: Bool
    }

    func body(content: Content) -> some View {
        let context = RepoCardPaginationContext(page: page, isLoading: isLoading, gate: gate, action: action)
        content
            .environment(\.repoCardPaginationContext, context)
            .onChange(of: Inputs(page: page, isLoading: isLoading), initial: true) { _, state in
                gate.update(state.page, isLoading: state.isLoading)
                if fillsFilteredWindow, !isLoading, ListPaginationPolicy.shouldFillVisibleWindow(
                    visibleItemCount: page.visibleItemCount, hasMore: page.hasMore
                ) {
                    context.request(appearingIndex: nil)
                }
            }
            .onDisappear { gate.update(nil, isLoading: false) }
    }
}

private struct RepoCardPaginationRow: ViewModifier {
    let appearingIndex: Int
    @Environment(\.repoCardPaginationContext) private var context

    func body(content: Content) -> some View {
        content.background {
            if let context, !context.isLoading, ListPaginationPolicy.shouldPrefetch(
                appearingIndex: appearingIndex,
                itemCount: context.page.visibleItemCount,
                hasMore: context.page.hasMore
            ) {
                RepoCardPaginationViewportProbe(visibleItemCount: context.page.visibleItemCount) {
                    context.request(appearingIndex: appearingIndex)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// macOS List 可在行还未进入视口时创建行。仅给候选尾行挂探针，用 AppKit 裁切范围确认实际可见性。
private struct RepoCardPaginationViewportProbe: NSViewRepresentable {
    let visibleItemCount: Int
    let onEnter: @MainActor () -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.visibleItemCount = visibleItemCount
        nsView.onEnter = onEnter
        nsView.checkVisibility(recheck: true)
    }

    final class ProbeView: NSView {
        var visibleItemCount = 0
        var onEnter: (@MainActor () -> Void)?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil, let clip = enclosingScrollView?.contentView else {
                wasVisible = false
                return
            }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportDidScroll(_:)),
                name: NSView.boundsDidChangeNotification, object: clip
            )
            checkVisibility(recheck: true)
        }

        override func layout() {
            super.layout()
            checkVisibility(recheck: false)
        }

        @objc private func viewportDidScroll(_ notification: Notification) {
            checkVisibility(recheck: false)
        }

        func checkVisibility(recheck: Bool) {
            let isVisible = canSeeTailRow
            let needsRequest = isVisible && (recheck || !wasVisible)
            wasVisible = isVisible
            if needsRequest { onEnter?() }
        }

        private var canSeeTailRow: Bool {
            guard window != nil, !visibleRect.isEmpty,
                  let scrollView = enclosingScrollView, let documentView = scrollView.documentView else { return false }
            let viewport = scrollView.documentVisibleRect
            let document = documentView.bounds
            guard viewport.intersects(convert(bounds, to: documentView)) else { return false }
            let offsetFromTop = documentView.isFlipped ? viewport.minY - document.minY : document.maxY - viewport.maxY
            return ListPaginationPolicy.canPrefetchFromViewport(
                offsetFromTop: offsetFromTop, documentHeight: document.height,
                viewportHeight: viewport.height, visibleItemCount: visibleItemCount
            )
        }
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
    /// 由中栏列表容器管理分页快照，行只报告自身的可见位置。
    func automaticListPagination(appearingIndex: Int) -> some View {
        modifier(RepoCardPaginationRow(appearingIndex: appearingIndex))
    }

    /// 同一页的滚动与筛选补齐共用一次追加机会。
    func automaticListPagination(
        visibleItemCount: Int,
        loadedItemCount: Int,
        hasMore: Bool,
        isLoading: Bool,
        identity: String,
        fillsFilteredWindow: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(RepoCardPaginationContainer(
            page: RepoCardPaginationPage(
                identity: identity, visibleItemCount: visibleItemCount,
                loadedItemCount: loadedItemCount, hasMore: hasMore
            ),
            isLoading: isLoading,
            fillsFilteredWindow: fillsFilteredWindow,
            action: action
        ))
    }

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
