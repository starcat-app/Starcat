//
//  ReleaseTimelineViewModel.swift
//  Starcat
//
//  版本工作区会话：在同一份订阅缓存上处理分页、搜索、一次性定位和已读操作。
//

import Foundation
import Observation

/// 列表和详情共用一个选中 ID；过滤、已读状态或数据变化后，不保留不可见的详情。
@MainActor @Observable
final class ReleaseTimelineViewModel {
    private let repository: any ReleaseRepositoryProtocol
    private let poll: @MainActor () async -> Void
    private static let pageSize = 20
    private var readGeneration = 0
    private(set) var entries: [ReleaseTimelineEntry] = []
    private(set) var selectedID: Int64?
    private(set) var pendingTarget: Int64?
    private(set) var unreadCount = 0
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isChecking = false
    private enum FailedAction {
        case readPage(reset: Bool)
        case markRead(id: Int64, isRead: Bool)
        case markAllRead
    }
    private var failedAction: FailedAction?

    var errorMessage: String? {
        switch failedAction {
        case .readPage: String.l10n("releases.timeline.error.loadFailed")
        case .markRead: String.l10n("releases.timeline.error.markReadFailed")
        case .markAllRead: String.l10n("releases.timeline.error.markAllReadFailed")
        case nil: nil
        }
    }

    var search = "" { didSet { userChangedFilter() } }
    var unreadOnly = false { didSet { userChangedFilter() } }

    init(repository: any ReleaseRepositoryProtocol, poll: @escaping @MainActor () async -> Void) {
        self.repository = repository
        self.poll = poll
    }

    var visibleEntries: [ReleaseTimelineEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (!unreadOnly || !entry.release.isRead) && (query.isEmpty ||
                [entry.repo.fullName, entry.release.tagName, entry.release.name ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
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
        unreadOnly = false
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

    /// 重试保留原页或记录的目标状态，即使该记录已从未读筛选中消失也能完成操作。
    func retry() async {
        switch failedAction {
        case .readPage(let reset): await readPage(reset: reset)
        case .markRead(let id, let isRead): await markRead(id: id, isRead: isRead)
        case .markAllRead: await markAllRead()
        case nil: break
        }
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
            let count = reset ? try await repository.unreadCount() : unreadCount
            guard generation == readGeneration else { return }
            if reset {
                entries = page
            } else {
                let loaded = Set(entries.map(\.id))
                entries.append(contentsOf: page.filter { !loaded.contains($0.id) })
            }
            unreadCount = count
            hasMore = page.count == limit
            hasLoaded = true
            failedAction = nil
            reconcileSelection()
        } catch {
            guard generation == readGeneration else { return }
            failedAction = .readPage(reset: reset)
        }
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await poll()
        await reload()
    }

    func toggleRead(_ entry: ReleaseTimelineEntry) async {
        await markRead(id: entry.id, isRead: !entry.release.isRead)
    }

    private func markRead(id: Int64, isRead: Bool) async {
        do {
            try await repository.markRead(releaseId: id, isRead: isRead)
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].release.isRead = isRead
            }
            reconcileSelection()
            unreadCount = try await repository.unreadCount()
            failedAction = nil
        } catch {
            failedAction = .markRead(id: id, isRead: isRead)
        }
    }

    func markAllRead() async {
        do {
            try await repository.markAllRead()
            for index in entries.indices { entries[index].release.isRead = true }
            unreadCount = 0
            failedAction = nil
            reconcileSelection()
        } catch {
            failedAction = .markAllRead
        }
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
