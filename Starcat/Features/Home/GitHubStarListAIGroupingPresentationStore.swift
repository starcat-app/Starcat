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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private static let pageSize = 100

    /// 连续的任务状态写入会让 revision 快速递增；短暂合并后只生成一次完整快照。
    func scheduleSynchronize(from session: GitHubStarListAIGroupingSession, immediate: Bool = false) {
        refreshTask?.cancel()
        let revision = session.presentationRevision
        refreshTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, revision == session.presentationRevision else { return }
            synchronize(from: session)
        }
    }

    func loadMore() {
        guard canLoadMore else { return }
        visibleLimit += Self.pageSize
        rebuildVisibleItems()
    }

    func synchronizeImmediately(from session: GitHubStarListAIGroupingSession) {
        refreshTask?.cancel()
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
            ignoredRepoIDs: session.ignoredRepoIDs,
            preparedRepositoryCount: session.preparedRepositoryCount,
            ungroupedRepositoryCount: session.ungroupedRepositoryCount,
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
        let matches = snapshot.items.filter {
            $0.matches(filter: filter, searchText: appliedSearchText)
        }
        matchingItemCount = matches.count
        visibleItems = Array(matches.prefix(visibleLimit))
        canLoadMore = visibleItems.count < matches.count
    }
}
