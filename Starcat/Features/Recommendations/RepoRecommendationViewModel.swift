//
//  RepoRecommendationViewModel.swift
//  Starcat
//
//  仓库详情页相似推荐状态机。
//
//  关键约束：
//  - 推荐是详情页的附加能力，加载失败不能影响 README / notes / release 等主内容。
//  - **v1.1 修订（2026-06-29）**：详情打开路由从本 VM 迁到 `RepoDetailScaffold`：
//    本地已 star → `RepoDetailWindowController.show` 开新 Starcat 窗；
//    非本地 / 未 star → `NSWorkspace.open(GitHub URL)`。
//    旧的「in-place 切 selection + selectedRepoID 跳行」逻辑（`open(_:repoRepository:homeViewModel:)`）
//    已删除（铁律 #1），VM 现在只负责数据 load / loadMore / reset 三件事。
//

import Foundation
import Observation

@MainActor
@Observable
final class RepoRecommendationViewModel {
    private(set) var items: [RepoRecommendationItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var hasMore = false

    private var loadedRepoID: Int64?
    private var nextOffset: Int?
    private let pageSize = 10

    var hasItems: Bool { !items.isEmpty }

    func loadInitial(repoID: Int64, api: RecommendAPI) async {
        guard repoID > 0 else {
            reset()
            return
        }
        guard loadedRepoID != repoID else { return }

        loadedRepoID = repoID
        items = []
        hasMore = false
        nextOffset = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await api.fetchRecommendations(repoID: repoID, limit: pageSize, offset: 0)
            guard loadedRepoID == repoID else { return }
            items = page.items
            hasMore = page.hasMore
            nextOffset = page.nextOffset
        } catch is CancellationError {
            // SwiftUI 快速切换 repo 时取消旧任务是正常路径。
        } catch {
            guard loadedRepoID == repoID else { return }
            errorMessage = error.localizedDescription
            AppLog.network.warning("recommend: load failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMore(api: RecommendAPI) async {
        guard let repoID = loadedRepoID, let nextOffset, hasMore, !isLoadingMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        do {
            let page = try await api.fetchRecommendations(repoID: repoID, limit: pageSize, offset: nextOffset)
            guard loadedRepoID == repoID else { return }
            items.append(contentsOf: page.items)
            hasMore = page.hasMore
            self.nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            AppLog.network.warning("recommend: load more failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 详情打开路由（v1.1 已迁出）
    //
    // 旧实现 `open(_:repoRepository:homeViewModel:)` 走 in-place 导航：把主窗 selection
    // 切到 .allStars + selectedRepoID 跳到对应 repo。体感问题：跨 selection 切换会触发
    // 异步 reload，期间 selectedRepoID 可能被清，detail 视图表现为「卡加载」。
    //
    // v1.1 拆出成「本地已 star → 开新 Starcat 窗」+「非本地 → 浏览器开 GitHub URL」两条
    // 路径，路由逻辑迁到 `RepoDetailScaffold`（那里有 dependencies / homeViewModel
    // 上下文），ViewModel 只负责数据 load / loadMore / reset。`open` 方法已删除（铁律 #1）。

    private func reset() {
        loadedRepoID = nil
        nextOffset = nil
        items = []
        hasMore = false
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
    }
}
