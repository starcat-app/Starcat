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
//    `RecommendationContextService`（read-through cache）。`loadInitial` 先异步读磁盘 cache，
//    但磁盘 I/O 在独立 actor 中执行，不阻塞主线程；fresh 快照直接返回，只有 stale / miss
//    才走 refresh 拉新 + 写盘。
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
    private var currentSnapshot: RecommendationCacheSnapshot?
    /// 当前详情会话已经向 UI 暴露的条数。磁盘可以缓存更多页，但重新进入详情时
    /// 必须从首批开始，不能一次构造全部卡片和头像请求。
    private var visibleItemCount = 0

    var hasItems: Bool { !items.isEmpty }

    /// 初次加载：先异步读 cache，再按 freshness 决定是否 refresh。
    ///
    /// 流程：
    /// 1. `guard loadedRepoID != repoID` —— 同一 repo 重复进入详情页不重拉；
    /// 2. 在后台 actor 读 cache → 赋 items / hasMore（**这一步不进网络**）；
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

        // 第 2 步：后台读 cache 后给 UI 数据。cache miss 时本步 no-op，
        // 列表显示 empty + 骨架屏（与之前无 cache 行为一致）。
        let totalStartedAt = ContinuousClock.now
        let serviceScope = await service.currentServiceScope()
        guard !Task.isCancelled, loadedRepoID == repoID else { return }
        if let snapshot = await service.cachedSnapshot(repoID: repoID, serviceScope: serviceScope) {
            apply(snapshot: snapshot, pageSize: service.pageSize, resetVisibleItems: true)
            // 推荐缓存把空结果与有结果的重探时刻都编码在 snapshot 里；这里必须真正
            // 尊重 freshness，否则 1h / 7d TTL 只停留在磁盘字段上，每次进详情仍会打服务端。
            if snapshot.freshness() == .fresh {
                return
            }
        } else {
            currentSnapshot = nil
            visibleItemCount = 0
            items = []
            hasMore = false
        }

        // 第 3 步：仅 stale / miss 才异步 refresh 拉新 + 写盘。
        do {
            let fresh = try await service.refresh(
                repoID: repoID,
                offset: 0,
                serviceScope: serviceScope
            )
            guard loadedRepoID == repoID else { return }
            apply(snapshot: fresh, pageSize: service.pageSize, resetVisibleItems: true)
            AppLog.ui.debug(
                "Recommend initial load repo=\(repoID, privacy: .public) visible=\(self.items.count, privacy: .public) cached=\(fresh.items.count, privacy: .public) elapsed=\(String(describing: totalStartedAt.duration(to: .now)), privacy: .public)"
            )
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
              (visibleItemCount < snapshot.items.count || snapshot.hasMore),
              !isLoadingMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        do {
            let nextVisibleCount = min(visibleItemCount + service.pageSize, snapshot.items.count)
            if nextVisibleCount > visibleItemCount {
                // 磁盘中已经缓存后续页时只解锁下一批，不发网络请求。
                visibleItemCount = nextVisibleCount
                apply(snapshot: snapshot, pageSize: service.pageSize, resetVisibleItems: false)
                return
            }

            let updated = try await service.refreshNextPage(
                repoID: repoID,
                currentSnapshot: snapshot
            )
            guard loadedRepoID == repoID else { return }
            visibleItemCount = min(visibleItemCount + service.pageSize, updated.items.count)
            apply(snapshot: updated, pageSize: service.pageSize, resetVisibleItems: false)
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
        currentSnapshot = nil
        visibleItemCount = 0
        items = []
        hasMore = false
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
    }

    /// 把完整磁盘快照裁成当前会话可见页。`currentSnapshot` 保留全部缓存结果，
    /// `items` 永远只包含用户已经通过“更多”解锁的前缀。
    private func apply(
        snapshot: RecommendationCacheSnapshot,
        pageSize: Int,
        resetVisibleItems: Bool
    ) {
        currentSnapshot = snapshot
        if resetVisibleItems {
            visibleItemCount = min(pageSize, snapshot.items.count)
        } else {
            visibleItemCount = min(visibleItemCount, snapshot.items.count)
        }
        items = Array(snapshot.items.prefix(visibleItemCount))
        hasMore = visibleItemCount < snapshot.items.count || snapshot.hasMore
    }
}
