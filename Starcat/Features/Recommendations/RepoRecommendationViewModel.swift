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
//  - **v1.1.1 修订（2026-06-29）**：从直接调 `RecommendAPI` 改为走
//    `RecommendationContextService`（read-through cache）。`loadInitial` 先同步读 cache
//    立刻给 items 赋初值；fresh 快照直接返回，只有 stale / miss 才走 refresh 拉新 + 写盘。
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
    private var currentSnapshot: RecommendationCacheSnapshot?

    var hasItems: Bool { !items.isEmpty }

    /// 初次加载：先同步读 cache 立刻渲染，再按 freshness 决定是否 refresh。
    ///
    /// 流程：
    /// 1. `guard loadedRepoID != repoID` —— 同一 repo 重复进入详情页不重拉；
    /// 2. 同步读 cache → 立刻赋 items / hasMore / nextOffset（**这一步不进网络**，详情页打开秒出数据）；
    /// 3. fresh 快照直接返回；stale / miss 才走 `service.refresh` 拉新 + 写盘；
    /// 4. 错误：保留旧 cache 值（如果 1 有），errorMessage 给 UI 显示。
    func loadInitial(repoID: Int64, service: RecommendationContextService) async {
        guard repoID > 0 else {
            clear()
            return
        }
        guard loadedRepoID != repoID else { return }

        loadedRepoID = repoID
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        // 第 2 步：同步读 cache 立刻给 UI 数据。cache miss 时本步 no-op，
        // 列表显示 empty + 骨架屏（与之前无 cache 行为一致）；cache hit
        // 时秒出。
        if let snapshot = service.cachedSnapshot(repoID: repoID) {
            currentSnapshot = snapshot
            items = snapshot.items
            hasMore = snapshot.hasMore
            nextOffset = snapshot.nextOffset
            // 推荐缓存把空结果与有结果的重探时刻都编码在 snapshot 里；这里必须真正
            // 尊重 freshness，否则 1h / 7d TTL 只停留在磁盘字段上，每次进详情仍会打服务端。
            if snapshot.freshness() == .fresh {
                return
            }
        } else {
            currentSnapshot = nil
            items = []
            hasMore = false
            nextOffset = nil
        }

        // 第 3 步：仅 stale / miss 才异步 refresh 拉新 + 写盘。
        do {
            let fresh = try await service.refresh(repoID: repoID, offset: 0)
            guard loadedRepoID == repoID else { return }
            currentSnapshot = fresh
            items = fresh.items
            hasMore = fresh.hasMore
            nextOffset = fresh.nextOffset
        } catch is CancellationError {
            // SwiftUI 快速切换 repo 时取消旧任务是正常路径。
        } catch {
            guard loadedRepoID == repoID else { return }
            // 保留旧 cache 值给 UI（步骤 2 已赋过），只把错误告诉用户。
            errorMessage = error.localizedDescription
            AppLog.network.warning("recommend: load failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 翻页：在已有 snapshot 基础上 append 新拉到的 items。
    func loadMore(service: RecommendationContextService) async {
        guard let repoID = loadedRepoID,
              let snapshot = currentSnapshot,
              snapshot.hasMore,
              !isLoadingMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        do {
            let newItems = try await service.refreshNextPage(
                repoID: repoID,
                currentSnapshot: snapshot
            )
            guard loadedRepoID == repoID else { return }
            // 重新读盘拿合并后的最新 snapshot（refreshNextPage 已落盘）。
            if let updated = service.cachedSnapshot(repoID: repoID) {
                currentSnapshot = updated
                items = updated.items
                hasMore = updated.hasMore
                nextOffset = updated.nextOffset
            }
            _ = newItems  // 合并结果已通过读盘拿到
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

    /// 清掉上一个仓库的推荐快照。Private 项目命中隐私门禁时由详情页主动调用，
    /// 防止视图复用期间短暂显示上一个 Public 仓库的推荐结果。
    func clear() {
        loadedRepoID = nil
        nextOffset = nil
        currentSnapshot = nil
        items = []
        hasMore = false
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
    }
}
