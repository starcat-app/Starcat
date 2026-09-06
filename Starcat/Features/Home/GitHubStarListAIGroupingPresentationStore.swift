//
//  GitHubStarListAIGroupingPresentationStore.swift
//  Starcat
//
//  AI 仓库分组审核页的缓存展示状态。
//
//  关键约束：会话仍是业务真源；本类型只缓存可重建的展示快照，并把连续批次更新
//  合并到同一帧附近，避免近 2,000 个任务在 SwiftUI body 内被反复映射、排序和筛选。
//

import Foundation
import Observation

@MainActor
@Observable
final class GitHubStarListAIGroupingPresentationStore {
    var filter: GitHubStarListAIResultFilter = .actionable {
        didSet {
            visibleLimit = Self.pageSize
            rebuildVisibleItems()
        }
    }

    var searchText = "" {
        didSet { scheduleSearch() }
    }

    private(set) var snapshot: GitHubStarListAIGroupingPresentationSnapshot = .empty
    private(set) var visibleItems: [GitHubStarListAIReviewItem] = []
    private(set) var matchingItemCount = 0
    private(set) var canLoadMore = false
    private(set) var isReady = false

    @ObservationIgnored private var appliedSearchText = ""
    @ObservationIgnored private var visibleLimit = GitHubStarListAIGroupingPresentationStore.pageSize
    @ObservationIgnored private var matchingItems: [GitHubStarListAIReviewItem] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private static let pageSize = 100
    /// 运行中最多每秒刷新十次审核快照；进度仍足够及时，同时给滚动和行布局留出主线程时间。
    private static let refreshInterval: Duration = .milliseconds(100)

    /// 连续的任务状态写入会让 revision 快速递增；固定时间窗内只生成一次最新快照。
    /// 不能在每次 revision 时取消并重启计时，否则持续运行时既可能饿死刷新，也会在短间隔内反复重建全量结果。
    func scheduleSynchronize(from session: GitHubStarListAIGroupingSession, immediate: Bool = false) {
        if immediate {
            synchronizeImmediately(from: session)
            return
        }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, weak session] in
            guard let self else { return }
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                self.refreshTask = nil
                return
            }
            self.refreshTask = nil
            guard !Task.isCancelled, let session else { return }
            // 不保留旧 revision；时间窗结束时直接读取会话最新值，一次吸收期间所有变化。
            synchronize(from: session)
        }
    }

    func loadMore() {
        guard canLoadMore else { return }
        visibleLimit += Self.pageSize
        appendNextVisiblePage()
    }

    func synchronizeImmediately(from session: GitHubStarListAIGroupingSession) {
        refreshTask?.cancel()
        refreshTask = nil
        synchronize(from: session)
    }

    private func synchronize(from session: GitHubStarListAIGroupingSession) {
        let availableLists = session.availableLists.map { list in
            GitHubStarListAIListDisplay(
                id: list.id,
                name: list.name,
                instruction: session.rulesByListID[list.id]?.instruction ?? "",
                colorHex: list.colorHex
            )
        }
        snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: session.jobs,
            availableLists: availableLists,
            existingListIDsByRepo: session.existingListIDsByRepo,
            selectedListIDsByRepo: session.selectedListIDsByRepo,
            editedListIDsByRepo: session.editedListIDsByRepo,
            ignoredRepoIDs: session.ignoredRepoIDs,
            preparedRepositoryCount: session.preparedRepositoryCount,
            ungroupedRepositoryCount: session.ungroupedRepositoryCount,
            preparedAnalysisRepositoryCount: session.preparedAnalysisRepositoryCount,
            preparedAutomaticallyIgnoredRepoCount: session.preparedAutomaticallyIgnoredRepoIDs.count,
            membershipCountByListID: session.membershipCountByListID,
            rulesByListID: session.rulesByListID
        )
        isReady = true
        rebuildVisibleItems()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appliedSearchText = ""
            visibleLimit = Self.pageSize
            rebuildVisibleItems()
            return
        }
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, query == searchText else { return }
            appliedSearchText = query
            visibleLimit = Self.pageSize
            rebuildVisibleItems()
        }
    }

    private func rebuildVisibleItems() {
        matchingItems = snapshot.items.filter {
            $0.matches(filter: filter, searchText: appliedSearchText)
        }
        matchingItemCount = matchingItems.count
        visibleItems = Array(matchingItems.prefix(visibleLimit))
        canLoadMore = visibleItems.count < matchingItems.count
    }

    /// 筛选条件不变时，下一页只追加固定数量；匹配结果会在会话快照更新时统一重建。
    /// 额外保留一份轻量展示数组，换取深度滚动时不再反复扫描全部审核项。
    private func appendNextVisiblePage() {
        let lowerBound = visibleItems.count
        let upperBound = min(visibleLimit, matchingItems.count)
        guard lowerBound < upperBound else {
            canLoadMore = false
            return
        }
        visibleItems.append(contentsOf: matchingItems[lowerBound..<upperBound])
        canLoadMore = upperBound < matchingItems.count
    }
}
