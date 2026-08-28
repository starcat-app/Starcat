//
//  RecommendationContextService.swift
//  Starcat
//
//  相似仓库推荐结果 SWR 中间层（2026-06-29，与 `WikiContextService` 同款分层）。
//
//  模块职责：
//  - 封装 "查 `DiskRecommendationCache` → 命中读盘 / miss 走 `RecommendAPI` 拉新 + 写盘"
//    的 cache 编排逻辑；
//  - 调用方（`RepoRecommendationViewModel`）只关心 "给我这个 repo 的推荐项"，不感知
//    cache / network 两层。
//  - 保持 `DiskRecommendationCache` 纯 CRUD：本层是唯一会发起网络请求并写盘的组合层。
//
//  与 `WikiContextService` 的差异：
//    1. **不做 SWR 后台刷新**：wiki 列表"已收录基本永久稳定"，stale 时仍可返回
//       旧值 + 后台慢慢刷；推荐是"看到新东西"的发现型能力，stale 价值不大，
//       直接重新拉即可。所以本服务只提供 `cachedSnapshot`（异步磁盘只读）+ `refresh`
//       （异步拉取 + 写盘），VM 自己拼装"先 cache 渲染 + stale 时 refresh"流程。
//    2. **不存 inFlight 去重**：WikiContextService 有 `inFlightRefreshes` map
//       防止并发刷新；推荐调用方只有详情页的 VM 持有 service，不会多入口并发，
//       同一 repo 同时只会有一个 refresh 任务在跑（VM 的 `isLoading` 守卫）。
//    3. **错误上抛但保留缓存**：网络失败不覆盖磁盘旧值，由 VM 记录 `errorMessage`；
//       推荐是辅助能力，错误不会阻塞详情页主内容。
//

import Foundation

/// 抽象网络层 —— 让 `RecommendationContextService` 在测试时可注入 stub，不必启 URLProtocol。
///
/// **不嵌套在 `RecommendationContextService` 内**：嵌进 `@MainActor final class` 会让
/// protocol 继承 main actor isolation，而生产实现 `RecommendAPI` 是独立 actor，无法
/// conform。顶层 protocol 不带 actor isolation，actor 自身的 async method 直接满足要求。
protocol RecommendationStatusFetching: Sendable {
    func fetchRecommendations(repoID: Int64, limit: Int, offset: Int) async throws -> RepoRecommendationPage
    func recommendationCacheScope() async -> String
}

extension RecommendationStatusFetching {
    /// 测试 stub 或固定实现未声明作用域时使用稳定默认值。
    func recommendationCacheScope() async -> String { "recommendation-default" }
}

extension RecommendAPI: RecommendationStatusFetching {}

/// 推荐 SWR 编排层（所有公开方法 `@MainActor`）。
///
/// 单例由 `AppDependencies.recommendationContextService` 注入；测试通过 init
/// 注入 stub `RecommendationStatusFetching` + 独立 `DiskRecommendationCache(rootOverride:)`
/// 隔离。
@MainActor
final class RecommendationContextService {

    // MARK: - 依赖

    private let cache: DiskRecommendationCache
    private let fetcher: RecommendationStatusFetching
    let pageSize: Int

    init(
        cache: DiskRecommendationCache,
        fetcher: RecommendationStatusFetching,
        pageSize: Int = 10
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.pageSize = pageSize
    }

    // MARK: - 异步只读：磁盘 I/O 不占 MainActor

    /// 读 cache 拿当前已知推荐项，不发起网络。
    /// - cache miss → 返回 nil（调用方决定走 `refresh`）；
    /// - cache hit（fresh 或 stale 都算）→ 返回当时探测到的 items。
    func cachedSnapshot(repoID: Int64, serviceScope: String) async -> RecommendationCacheSnapshot? {
        let startedAt = ContinuousClock.now
        let snapshot = await cache.load(repoID: repoID)
        let elapsed = startedAt.duration(to: .now)
        AppLog.ui.debug(
            "Recommend cache load repo=\(repoID, privacy: .public) hit=\(snapshot != nil, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
        )
        guard snapshot?.serviceScope == serviceScope else { return nil }
        return snapshot
    }

    /// 当前 URL + API contract 的缓存作用域。调用方在一次加载开始时固定该值，避免
    /// 设置页热切换地址期间把旧请求结果标成新服务数据。
    func currentServiceScope() async -> String {
        await fetcher.recommendationCacheScope()
    }

    // MARK: - 异步刷新

    /// 拉一次最新推荐 + 写盘 + 返回新 snapshot。**会抛错给调用方**（调用方写入 `errorMessage` 给 UI）。
    ///
    /// 返回完整 snapshot（items / hasMore / nextOffset）而非仅 items，是为了避免
    /// 调用方再回头 `cachedSnapshot(repoID:)` 多读一次盘。
    ///
    /// API 失败会向上抛出且不更新 cache（保留旧值如果有），下次 loadInitial 自然重试。
    @discardableResult
    func refresh(
        repoID: Int64,
        offset: Int = 0,
        serviceScope: String
    ) async throws -> RecommendationCacheSnapshot {
        let networkStartedAt = ContinuousClock.now
        let page = try await fetcher.fetchRecommendations(repoID: repoID, limit: pageSize, offset: offset)
        let networkElapsed = networkStartedAt.duration(to: .now)
        let snapshot = RecommendationCacheSnapshot(
            repoID: repoID,
            serviceScope: serviceScope,
            modelVersion: page.modelVersion,
            probedAt: Date(),
            nextProbeAt: RecommendationCacheSnapshot.computeNextProbeAt(items: page.items),
            items: page.items,
            hasMore: page.hasMore,
            nextOffset: page.nextOffset
        )
        let saveStartedAt = ContinuousClock.now
        try await cache.save(snapshot: snapshot)
        let saveElapsed = saveStartedAt.duration(to: .now)
        AppLog.ui.debug(
            "Recommend refresh repo=\(repoID, privacy: .public) offset=\(offset, privacy: .public) items=\(page.items.count, privacy: .public) network=\(String(describing: networkElapsed), privacy: .public) cacheSave=\(String(describing: saveElapsed), privacy: .public) model=\(page.modelVersion ?? "none", privacy: .public)"
        )
        return snapshot
    }

    /// 拉下一页（在已有 snapshot 基础上 append），写盘。
    /// 调用方需先通过 `cachedSnapshot(repoID:serviceScope:)` 拿到当前 nextOffset 才能用此方法。
    /// 返回值是合并后的完整 snapshot；需要增量的调用方按旧快照条数截取后缀。
    @discardableResult
    func refreshNextPage(
        repoID: Int64,
        currentSnapshot: RecommendationCacheSnapshot
    ) async throws -> RecommendationCacheSnapshot {
        guard let nextOffset = currentSnapshot.nextOffset, currentSnapshot.hasMore else {
            return currentSnapshot
        }
        let serviceScope = await currentServiceScope()
        guard currentSnapshot.serviceScope == serviceScope else {
            // 地址或契约已切换，不能把另一服务的下一页追加进当前快照。
            return try await refresh(repoID: repoID, serviceScope: serviceScope)
        }
        let networkStartedAt = ContinuousClock.now
        let newPage = try await fetcher.fetchRecommendations(
            repoID: repoID,
            limit: pageSize,
            offset: nextOffset
        )
        let networkElapsed = networkStartedAt.duration(to: .now)
        let merged = currentSnapshot.items + newPage.items
        let snapshot = RecommendationCacheSnapshot(
            repoID: repoID,
            serviceScope: serviceScope,
            modelVersion: newPage.modelVersion ?? currentSnapshot.modelVersion,
            probedAt: Date(),
            nextProbeAt: RecommendationCacheSnapshot.computeNextProbeAt(items: merged),
            items: merged,
            hasMore: newPage.hasMore,
            nextOffset: newPage.nextOffset
        )
        let saveStartedAt = ContinuousClock.now
        try await cache.save(snapshot: snapshot)
        let saveElapsed = saveStartedAt.duration(to: .now)
        AppLog.ui.debug(
            "Recommend load more repo=\(repoID, privacy: .public) offset=\(nextOffset, privacy: .public) items=\(newPage.items.count, privacy: .public) network=\(String(describing: networkElapsed), privacy: .public) cacheSave=\(String(describing: saveElapsed), privacy: .public)"
        )
        return snapshot
    }
}
