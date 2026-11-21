//
//  ReleaseTimelineViewModel.swift
//  Starcat
//
//  版本工作区会话：在同一份订阅缓存上处理分页、搜索和一次性定位。
//

import Foundation
import Observation

/// 列表和详情共用一个选中 ID，保证筛选或刷新后的详情来自可见列表。
@MainActor @Observable
final class ReleaseTimelineViewModel {
    private let repository: any ReleaseRepositoryProtocol
    private let poll: @MainActor () async -> Void
    private static let pageSize = 20
    private var readGeneration = 0
    private(set) var entries: [ReleaseTimelineEntry] = []
    private(set) var selectedID: Int64?
    private(set) var pendingTarget: Int64?
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isChecking = false
    private var failedPageReset: Bool?

    var errorMessage: String? {
        failedPageReset.map { _ in String.l10n("releases.timeline.error.loadFailed") }
    }

    var search = "" { didSet { userChangedFilter() } }

    init(repository: any ReleaseRepositoryProtocol, poll: @escaping @MainActor () async -> Void) {
        self.repository = repository
        self.poll = poll
    }

    var visibleEntries: [ReleaseTimelineEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.repo.fullName, entry.release.tagName, entry.release.name ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var selection: ReleaseTimelineEntry? {
        entries.first { $0.id == selectedID }
    }

    func select(_ id: Int64) {
        pendingTarget = nil
        selectedID = id
    }

    /// 深链只消费一次；目标在后页时继续本地分页，用户主动选择或筛选可中止定位。
    func locate(_ id: Int64?) {
        guard let id else { return }
        search = ""
        pendingTarget = id
        reconcileSelection()
    }

    private func userChangedFilter() {
        pendingTarget = nil
        reconcileSelection()
    }

    private func reconcileSelection() {
        let visible = visibleEntries
        if let pendingTarget {
            if visible.contains(where: { $0.id == pendingTarget }) {
                select(pendingTarget)
                return
            }
            if hasLoaded && !hasMore { self.pendingTarget = nil }
        }
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }

    func reload() async { await readPage(reset: true) }

    /// 重试沿用失败页的加载方式，避免追加失败时从首页重载。
    func retry() async {
        guard let failedPageReset else { return }
        await readPage(reset: failedPageReset)
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await readPage(reset: false)
    }

    /// 刷新覆盖在途的旧页；保留已浏览窗口长度，避免刷新把第二页以后的选择踢回第一行。
    private func readPage(reset: Bool) async {
        readGeneration += 1
        let generation = readGeneration
        isLoading = true
        let limit = reset ? max(Self.pageSize, entries.count) : Self.pageSize
        defer { if generation == readGeneration { isLoading = false } }
        do {
            let page = try await repository.fetchTimeline(limit: limit, offset: reset ? 0 : entries.count)
            guard generation == readGeneration else { return }
            if reset {
                entries = page
            } else {
                let loaded = Set(entries.map(\.id))
                entries.append(contentsOf: page.filter { !loaded.contains($0.id) })
            }
            hasMore = page.count == limit
            hasLoaded = true
            failedPageReset = nil
            reconcileSelection()
        } catch {
            guard generation == readGeneration else { return }
            failedPageReset = reset
        }
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await poll()
        await reload()
    }

}

extension ReleaseTimelineEntry {
    /// GitHub 发布时间不保证带小数秒；缺失时才退回版本创建时间。
    var displayDate: Date? {
        guard let raw = release.publishedAt ?? release.createdAtRemote else { return nil }
        return (try? Date(raw, strategy: .iso8601)) ??
            (try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true)))
    }
}
