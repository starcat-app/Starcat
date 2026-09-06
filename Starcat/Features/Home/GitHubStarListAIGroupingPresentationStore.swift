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
            guard filter != oldValue else { return }
            visibleLimit = Self.pageSize
            rebuildVisibleItems()
        }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
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
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingProjectionInput: ProjectionInput?
    @ObservationIgnored private var latestObservedRevision: UInt64 = 0
    @ObservationIgnored private var latestInstalledRevision: UInt64 = 0
    @ObservationIgnored private var isScrollInteractionActive = false
    @ObservationIgnored private var hasDeferredVisibleRefresh = false

    private static let pageSize = 100
    /// 运行中最多每秒刷新十次审核快照；进度仍足够及时，同时给滚动和行布局留出主线程时间。
    private static let refreshInterval: Duration = .milliseconds(100)

    /// 连续的任务状态写入会让 revision 快速递增；固定时间窗内只生成一次最新快照。
    /// 不能在每次 revision 时取消并重启计时，否则持续运行时既可能饿死刷新，也会在短间隔内反复重建全量结果。
    func scheduleSynchronize(from session: GitHubStarListAIGroupingSession, immediate: Bool = false) {
        // 每次都记录最新 revision；即使 100ms 定时器已经存在，正在后台计算的旧结果也不能覆盖新状态。
        latestObservedRevision = session.presentationRevision
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
            // 时间窗结束时读取会话最新值；全量映射与排序交给后台单飞任务，避免抢滚动主线程。
            enqueueProjection(from: session)
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
        latestObservedRevision = session.presentationRevision
        let input = makeProjectionInput(from: session)
        install(input.makeSnapshot(), revision: input.revision)
    }

    /// 滚动手势和惯性结束前只更新轻量进度快照，不替换 `List` 的数据源。
    /// 这样后台 Worker 可以继续完成仓库，用户当前手势却不会被行移除、排序和 diff 打断。
    func setScrollInteractionActive(_ isActive: Bool) {
        guard isScrollInteractionActive != isActive else { return }
        isScrollInteractionActive = isActive
        guard !isActive, hasDeferredVisibleRefresh else { return }
        hasDeferredVisibleRefresh = false
        rebuildVisibleItems()
    }

    /// Sheet 销毁时取消等待中的刷新；展示数据本身可重建，无需让旧任务延长窗口生命周期。
    func cancelPendingWork() {
        refreshTask?.cancel()
        refreshTask = nil
        searchTask?.cancel()
        searchTask = nil
        projectionTask?.cancel()
        projectionTask = nil
        pendingProjectionInput = nil
    }

    private func makeProjectionInput(from session: GitHubStarListAIGroupingSession) -> ProjectionInput {
        ProjectionInput(
            revision: session.presentationRevision,
            jobs: session.jobs,
            availableLists: session.availableLists,
            rulesByListID: session.rulesByListID,
            existingListIDsByRepo: session.existingListIDsByRepo,
            selectedListIDsByRepo: session.selectedListIDsByRepo,
            selectedRepoIDsForBulkApply: session.selectedRepoIDsForBulkApply,
            editedListIDsByRepo: session.editedListIDsByRepo,
            ignoredRepoIDs: session.ignoredRepoIDs,
            preparedRepositoryCount: session.preparedRepositoryCount,
            ungroupedRepositoryCount: session.ungroupedRepositoryCount,
            preparedAnalysisRepositoryCount: session.preparedAnalysisRepositoryCount,
            preparedAutomaticallyIgnoredRepoCount: session.preparedAutomaticallyIgnoredRepoIDs.count,
            membershipCountByListID: session.membershipCountByListID
        )
    }

    /// 后台投影严格单飞：计算期间若又收到 revision，只保留最后一份输入。
    /// 这既限制 CPU 占用，也避免多个已过期数组依次提交给 SwiftUI 造成额外 diff。
    private func enqueueProjection(from session: GitHubStarListAIGroupingSession) {
        pendingProjectionInput = makeProjectionInput(from: session)
        startProjectionLoopIfNeeded()
    }

    private func startProjectionLoopIfNeeded() {
        guard projectionTask == nil, pendingProjectionInput != nil else { return }
        projectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let input = self?.takePendingProjectionInput() else { break }
                // 输入和输出都是 Sendable 值快照；后台任务不读取 Observable Session。
                let snapshot = await Task.detached(priority: .userInitiated) {
                    input.makeSnapshot()
                }.value
                guard !Task.isCancelled, let self else { break }
                // 有更新输入时直接丢弃旧输出，下一轮只计算并提交最新 revision。
                guard self.pendingProjectionInput == nil,
                      input.revision == self.latestObservedRevision,
                      input.revision >= self.latestInstalledRevision
                else { continue }
                self.install(snapshot, revision: input.revision)
            }
            guard let self else { return }
            self.projectionTask = nil
            self.startProjectionLoopIfNeeded()
        }
    }

    private func takePendingProjectionInput() -> ProjectionInput? {
        defer { pendingProjectionInput = nil }
        return pendingProjectionInput
    }

    private func install(
        _ newSnapshot: GitHubStarListAIGroupingPresentationSnapshot,
        revision: UInt64
    ) {
        snapshot = newSnapshot
        latestInstalledRevision = revision
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
        guard !isScrollInteractionActive else {
            hasDeferredVisibleRefresh = true
            return
        }
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

    /// 从 MainActor 复制出的不可变输入；只有 `makeSnapshot()` 在后台执行。
    /// 不把 Session 引用带进 detached task，避免跨 actor 读取 Observation 状态。
    private struct ProjectionInput: Sendable {
        let revision: UInt64
        let jobs: [GitHubStarListAIGroupingJob]
        let availableLists: [GitHubStarList]
        let rulesByListID: [String: GitHubStarListAIRule]
        let existingListIDsByRepo: [Int64: Set<String>]
        let selectedListIDsByRepo: [Int64: Set<String>]
        let selectedRepoIDsForBulkApply: Set<Int64>
        let editedListIDsByRepo: [Int64: Set<String>]
        let ignoredRepoIDs: Set<Int64>
        let preparedRepositoryCount: Int
        let ungroupedRepositoryCount: Int
        let preparedAnalysisRepositoryCount: Int
        let preparedAutomaticallyIgnoredRepoCount: Int
        let membershipCountByListID: [String: Int]

        nonisolated func makeSnapshot() -> GitHubStarListAIGroupingPresentationSnapshot {
            let listDisplays = availableLists.map { list in
                GitHubStarListAIListDisplay(
                    id: list.id,
                    name: list.name,
                    instruction: rulesByListID[list.id]?.instruction ?? "",
                    colorHex: list.colorHex
                )
            }
            return GitHubStarListAIGroupingPresentationSnapshot(
                jobs: jobs,
                availableLists: listDisplays,
                existingListIDsByRepo: existingListIDsByRepo,
                selectedListIDsByRepo: selectedListIDsByRepo,
                selectedRepoIDsForBulkApply: selectedRepoIDsForBulkApply,
                editedListIDsByRepo: editedListIDsByRepo,
                ignoredRepoIDs: ignoredRepoIDs,
                preparedRepositoryCount: preparedRepositoryCount,
                ungroupedRepositoryCount: ungroupedRepositoryCount,
                preparedAnalysisRepositoryCount: preparedAnalysisRepositoryCount,
                preparedAutomaticallyIgnoredRepoCount: preparedAutomaticallyIgnoredRepoCount,
                membershipCountByListID: membershipCountByListID,
                rulesByListID: rulesByListID
            )
        }
    }
}
