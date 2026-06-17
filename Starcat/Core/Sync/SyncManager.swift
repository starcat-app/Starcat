//
//  SyncManager.swift
//  Starcat
//
//  全量同步管理器。
//
//  当前职责（Week 2）：
//  - 触发后从 page=1 开始分页拉 GitHub starred repos
//  - 每页批量 upsert 到本地数据库
//  - 用 Link 头判断是否有下一页
//  - 收尾：标记本地"远端已不在"的 repo 为 unstarred
//  - 通过 @Observable 暴露进度供 UI 观察
//
//  W4-4 C1 新增：
//  - Rate Limit 主动退避：撞 429/403 自动 sleep 到 reset 时间 + 安全 buffer
//    再重试同一页（每轮 runSync 最多自动重试 1 次，避免死循环）
//
//  W4-4 C2 新增：
//  - Page 1 ETag 早退：首页带 If-None-Match，命中 304 直接结束本次同步
//
//  W4-4 C3 新增：
//  - 增量同步：非 force 且本地有 lastSyncAt 时，扫描页面遇到 starred_at <= lastSyncAt 即停。
//    本质上把"全量 1801 条 / 19 页"压缩为"只拉新增的几条"。
//
//  unstar 检测策略（C2 + C3 综合）：
//  - ETag 304 → 整体未变（含 page 1 内容） → 不动 is_starred
//  - 增量路径 → 只追加新 star，不调 markUnstarredExcept（增量看不到中间页 unstar）
//  - 全量路径（force=true 或首次同步）→ 完整扫一遍 + markUnstarredExcept 兜底检测 unstar
//
//  建议每隔 N 天或用户主动触发 force=true 走一次全量 sweep。当前 UI 暂未暴露 force。
//
//  尚未做（Week 5+ 或后续优化）：
//  - 后台定时同步（NSBackgroundActivityScheduler）+ 周期性 force=true 全量 sweep
//  - 部分失败的断点续传
//

import Foundation
import Observation

/// 同步状态。
enum SyncState: Equatable {
    case idle
    case syncing
    case completed(at: Date)
    case failed(message: String)
    case rateLimited(retryAt: Date)
}

/// 同步进度快照。
struct SyncProgress: Equatable {
    /// 已写入数据库的 repo 数。
    var current: Int
    /// 远端总数；nil 表示尚未从 Link 头解析出来。
    var total: Int?
    /// 当前正在处理的页码。
    var currentPage: Int

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1.0, Double(current) / Double(total))
    }
}

/// 同步管理器，全局唯一。
@MainActor
@Observable
final class SyncManager {

    // MARK: - 可观察状态

    var state: SyncState = .idle
    var progress: SyncProgress?

    /// R-07（2026-06-15）：首次写入 page 1 后的「边沿信号」。
    ///
    /// 设计意图：让 `HomeView` 能在 SyncManager 还在跑后续页时就提前触发
    /// `reloadItems` 把第一页 ~100 条 star 上屏，避免首次登录时盯着空白
    /// 等十几秒拉完全部 1800 条才看到任何内容。
    ///
    /// 触发规则（严格）：
    /// - 全量 / 增量主路径：page 1 `upsertStarred` 成功后赋值一次（同一帧）
    /// - **304 早退**不触发（无新数据，registry 已在 304 路径自己刷过）
    /// - **失败 / 取消**不触发（throw 跳过赋值，状态走 .failed / .idle）
    /// - **page 1 dtos 为空**不触发（在 upsert 之前 break）
    ///
    /// 为什么用 `Date?` 而不是 Int 计数：① `@Observable` 的 `onChange` 监听
    /// 用值变化触发，Date 每次必不同天然形成边沿；② Int 计数会让 view
    /// 端误以为"递增有语义"——其实只是"又拉了一次"；③ Date 自带"刚刚"
    /// 的时间语义，将来如需"5 秒内只触发一次"加防抖逻辑也直接。
    ///
    /// 与 `state == .completed` 关系：completed 仍是收尾的最终全集 reload
    /// 触发点；本字段只负责"首屏边沿"，两者协作不互斥。
    var firstPageWrittenAt: Date?

    /// 上一轮 `runSync` **成功完成**时是否向 DB 写入了 starred repo 行。
    ///
    /// 用途：让 `HomeView` 在 `state == .completed` 时区分「304 / 无新数据早退」与
    /// 「真的 upsert 了新 stars」——前者不必 `reloadItems(forceRefresh: true)`，
    /// 避免同账号重开 App 时多跑一轮 ~700ms 的 GRDB 全量查询。
    ///
    /// 赋值规则（每轮 runSync 开头先置 false）：
    /// - page 1 **304 早退** → 保持 false
    /// - 主路径 `totalSynced > 0` → true
    /// - page 1 即空 / 失败 / 取消 → false
    private(set) var lastRunWroteRepos: Bool = false

    /// 启动期自动同步 TTL，与 `HomeViewModel.listCache` 5min TTL 对齐。
    static let defaultAutoSyncMaxAge: TimeInterval = 300

    // MARK: - 依赖

    /// D-02：依赖协议而非具体 actor，便于单测注入 Mock。
    private let apiClient: any GitHubAPIClientProtocol
    /// D-01：依赖协议而非具体 struct，便于单测注入 Mock。
    private let repository: any RepoRepositoryProtocol
    /// C1：Rate Limit 退避时额外多等多少秒（吸收时钟漂移）。
    /// 默认 5；单测里传 0 让重试逻辑近乎瞬时完成。
    private let rateLimitBufferSeconds: TimeInterval

    /// 当前进行中的同步 Task，便于取消。
    private var runningTask: Task<Void, Never>?

    /// R-01（2026-06-09）：每次全量 / 增量同步「成功完成」后的回调。
    ///
    /// 注入方：`AppDependencies` 用此 hook 让 `StarredRegistryBootstrapper.reload()`
    /// 在 SyncManager 写入新 starred 后立刻把 registry 同步到 DB。
    ///
    /// 调用时机：runSync 主路径成功结束（state = .completed 之前）；失败 / 取消路径
    /// 不调用。`weak self` 由调用方在闭包内自行处理（registry / bootstrapper 都是
    /// long-lived，正常无循环引用风险）。
    var onSyncCompleted: (@MainActor () async -> Void)?

    // MARK: - 初始化

    init(
        apiClient: any GitHubAPIClientProtocol,
        repository: any RepoRepositoryProtocol,
        rateLimitBufferSeconds: TimeInterval = 5
    ) {
        self.apiClient = apiClient
        self.repository = repository
        self.rateLimitBufferSeconds = rateLimitBufferSeconds
    }

    // MARK: - 同步入口

    /// 触发全量同步。
    /// - Parameter force: W4-4 C2，true 时跳过 page 1 ETag 条件请求，强制走全量。
    ///   默认 false（信任 ETag 早退路径）。UI 暂未暴露 force 入口；调用方在
    ///   "用户希望立即检测 unstar / 怀疑数据不一致" 场景下传 true。
    /// 重复调用：如果已在同步中，直接返回；不排队。
    func performFullSync(userID: Int64, force: Bool = false) {
        guard !isSyncing else { return }
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runSync(userID: userID, force: force)
        }
    }

    /// 启动期自动同步：仅当本地 `lastSyncAt` 超过 `maxAge` 才走网络。
    ///
    /// 与 `performFullSync` 的区别：同账号短时间内重开 App 时直接 no-op，
    /// 避免无谓的 ETag 条件请求 + `HomeView` 侧 forceRefresh 链式 DB 重查。
    /// 账号切换 / 用户手动刷新仍走 `performFullSync`。
    func performFullSyncIfStale(
        userID: Int64,
        maxAge: TimeInterval = SyncManager.defaultAutoSyncMaxAge,
        force: Bool = false
    ) {
        guard !isSyncing else { return }
        runningTask = Task { [weak self] in
            guard let self else { return }

            if !force, await self.isLastSyncFresh(userID: userID, maxAge: maxAge) {
                AppLog.sync.info(
                    "Auto sync skipped (lastSyncAt within \(Int(maxAge), privacy: .public)s TTL)"
                )
                return
            }

            await self.runSync(userID: userID, force: force)
        }
    }

    /// 取消进行中的同步。
    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    var isSyncing: Bool {
        if case .syncing = state { return true }
        return false
    }

    // MARK: - 实现

    private func runSync(userID: Int64, force: Bool) async {
        lastRunWroteRepos = false
        state = .syncing
        progress = SyncProgress(current: 0, total: nil, currentPage: 1)

        // C3：!force AND 本地有 lastSyncAt → 走增量;否则全量。
        // force 路径强制全量(供 unstar 兜底检测)。
        let cutoffStarredAt: String?
        if force {
            cutoffStarredAt = nil
        } else {
            cutoffStarredAt = (try? await repository.fetchLastSyncAt(userID: userID)) ?? nil
        }
        let incrementalMode = (cutoffStarredAt != nil)
        AppLog.sync.info("Sync started (user=\(userID, privacy: .public), force=\(force, privacy: .public), incremental=\(incrementalMode, privacy: .public))")

        var page = 1
        let perPage = 100
        var totalSynced = 0
        var allRemoteIDs: Set<Int64> = []
        let syncStartedAt = Date()
        // C1：本轮 runSync 是否已经为 rate limit 主动等待过一次。
        // 只允许 1 次自动重试 — 第二次撞墙就抛 rateLimited 让用户决定。
        // 这样避免"配额估算错误 / 重置时间漂移"导致 sleep 死循环。
        var rateLimitRetried = false

        // C2：page 1 ETag。非 force 时读历史值;force 时强制 nil 走全量。
        let cachedETag: String?
        if force {
            cachedETag = nil
        } else {
            cachedETag = (try? await repository.fetchStarsETag(userID: userID)) ?? nil
        }

        do {
            while true {
                try Task.checkCancellation()

                // C2：仅 page 1 带 If-None-Match;其他页正常拉。
                let ifNoneMatch: String? = (page == 1) ? cachedETag : nil

                // C1：单次 fetch 用 inner do-catch 包裹，专门拦 rateLimited 做退避重试。
                // 退避成功后 `continue` 同一 page 重跑，外层循环 untouched。
                let response: APIResponse<[StarredRepoDTO]>
                do {
                    response = try await apiClient.starredRepos(page: page, perPage: perPage, ifNoneMatch: ifNoneMatch)
                } catch NetworkError.rateLimited(let retryAfter) where !rateLimitRetried {
                    rateLimitRetried = true
                    try await waitForRateLimit(retryAfter: retryAfter)
                    continue
                } catch NetworkError.notModified {
                    // C2：page 1 304 → 早退。
                    // 语义：服务端 page 1 内容未变 → 信任本地，不动 is_starred。
                    // 注意：中间页 unstar 不会被这条路径检测到（见文件头说明）。
                    AppLog.sync.info("Stars page 1 not modified (ETag hit), skipping full sync")
                    let localCount = (try? await repository.starredCount()) ?? 0
                    try? await repository.updateSyncState(
                        userID: userID,
                        starredCount: localCount,
                        syncedCount: localCount,
                        status: "idle"
                    )
                    progress = SyncProgress(current: localCount, total: localCount, currentPage: 1)

                    // **R-01 v2.0 修订**(2026-06-10):304 早退路径**也必须**触发
                    // `onSyncCompleted` hook,把 registry 与本地 DB 同步。
                    //
                    // 修复原因(dong4j 真机回归发现):v1.7 引入 4 详情页用
                    // `StarredRegistry.contains` 派生 trailingActions / starHelpKey /
                    // toggle 分支后,Manage 启动期 304 命中(常态!ETag 命中即 304)
                    // → `runningTask = nil; return` 直接退出 → 不调 hook → registry
                    // 在 `AppDependencies.init` 末尾的 `Task { reload() }` 又因为
                    // `repos.is_starred` 列还没被同步初始化(304 早退前 ETag 未变 +
                    // `bootstrapper` 已经跑过一次 reload 但当时 DB 可能空)而拿到空集。
                    //
                    // 即便修复 view 层守卫回归 `repo.isStarred`(主路径),`StarActionService.toggle`
                    // 仍依赖 registry 兜「ephemeral 刚 star」corner case;hook 这条
                    // 防御让 304 早退也能确保 registry 与 DB 一致,从源头根治 stale 问题。
                    //
                    // 性能影响:`StarredRegistryBootstrapper.reload()` 内部仅查
                    // `fetchStarredRepoIDs()`(单条 SQL),开销可忽略。
                    if let hook = onSyncCompleted {
                        await hook()
                    }

                    lastRunWroteRepos = false
                    state = .completed(at: Date())
                    runningTask = nil
                    return
                }

                // C2：page 1 拿到新 ETag → 立即持久化，避免后续页失败时丢失这次的 ETag。
                if page == 1, let newEtag = response.etag, !newEtag.isEmpty {
                    try? await repository.updateStarsETag(userID: userID, etag: newEtag)
                }

                let dtos = response.value

                // 从 Link 头解析总页数 → 估算总数
                if progress?.total == nil, let lastPage = response.linkHeader.lastPage {
                    let estimatedTotal = lastPage * perPage
                    progress?.total = estimatedTotal
                }

                if dtos.isEmpty {
                    // 第一页就空 → 该用户无 star，直接完成
                    break
                }

                try await repository.upsertStarred(dtos, userID: userID, syncedAt: syncStartedAt)
                allRemoteIDs.formUnion(dtos.map { $0.repo.id })
                totalSynced += dtos.count
                progress?.current = totalSynced
                progress?.currentPage = page

                // R-07：page 1 写库成功 → 立刻翻边沿信号，HomeView 把首页 ~100 条上屏。
                // 增量模式时 page 1 可能就 break，但本句仍执行；增量第一页写入也是值得"上屏"的场景。
                // 失败 / cancellation 不会到这里（前面有 throw）。
                if page == 1 {
                    firstPageWrittenAt = Date()
                }

                AppLog.sync.debug("Synced page \(page, privacy: .public): \(dtos.count, privacy: .public) repos (total \(totalSynced, privacy: .public))")

                // C3：增量模式 — 该页"最旧"的一条 starred_at 已 <= cutoff 说明后续页全是已知，停。
                // 注：本页越界部分也被 upsert 了，幂等无害；优化为"只 upsert > cutoff 的子集"留待后续。
                if incrementalMode, let cutoff = cutoffStarredAt,
                   let oldestInPage = dtos.last?.starredAt, oldestInPage <= cutoff {
                    AppLog.sync.info("Incremental sync stopped at page \(page, privacy: .public): reached cutoff \(cutoff, privacy: .public)")
                    break
                }

                // 判断是否还有下一页
                if response.linkHeader.nextPage == nil {
                    break
                }
                page = response.linkHeader.nextPage ?? (page + 1)
            }

            try Task.checkCancellation()

            // 全量路径才做 unstar 兜底；增量看不到中间页 unstar，跳过避免误删。
            if !incrementalMode {
                try await repository.markUnstarredExcept(remoteRepoIDs: allRemoteIDs, userID: userID)
            }

            // 进度与统计的最终值：
            // - 全量：totalSynced == 本地 starred 总数
            // - 增量：totalSynced 只是本次新增 / 边界页的条数，应用本地 starredCount 才反映真实总数
            let finalCount: Int
            if incrementalMode {
                finalCount = (try? await repository.starredCount()) ?? totalSynced
            } else {
                finalCount = totalSynced
            }

            try await repository.updateSyncState(
                userID: userID,
                starredCount: finalCount,
                syncedCount: finalCount,
                status: "idle"
            )

            // 进度补齐到 100%。
            // 注意：GitHub Stars API 的总数靠 Link 头 last 页号估算（lastPage * perPage），
            // 真实最后一页只有 1~perPage 条，所以估算值通常偏大。
            // 同步完成时把 total 校正为实际拉到的数量，避免 UI 显示 "1801 / 1900" 这类残留估算误差。
            progress = SyncProgress(current: finalCount, total: finalCount, currentPage: page)

            // R-01：同步完成 hook —— 让 AppDependencies 注入的 bootstrapper.reload()
            // 把 registry 同步到刚写入的 DB 状态。失败 / 取消路径不调，避免 registry
            // 漂移（DB 半截写入）。
            if let hook = onSyncCompleted {
                await hook()
            }

            lastRunWroteRepos = totalSynced > 0
            state = .completed(at: Date())
            AppLog.sync.info("Sync complete (incremental=\(incrementalMode, privacy: .public)): wrote \(totalSynced, privacy: .public), local total \(finalCount, privacy: .public) in \(Int(Date().timeIntervalSince(syncStartedAt)), privacy: .public)s")
        } catch is CancellationError {
            state = .idle
            AppLog.sync.info("Sync cancelled")
        } catch NetworkError.cancelled {
            state = .idle
            AppLog.sync.info("Sync cancelled (network)")
        } catch NetworkError.rateLimited(let retryAfter) {
            let retryAt = Date().addingTimeInterval(retryAfter)
            state = .rateLimited(retryAt: retryAt)
            AppLog.sync.warning("Rate limited; retry at \(retryAt, privacy: .public)")
        } catch NetworkError.unauthorized {
            state = .failed(message: String.l10n("sync.error.tokenExpired"))
            AppLog.sync.error("Unauthorized during sync")
        } catch let error as LocalizedError {
            state = .failed(message: error.localizedDescription)
            AppLog.sync.error("Sync failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            state = .failed(message: error.localizedDescription)
            AppLog.sync.error("Sync failed (unknown): \(error.localizedDescription, privacy: .public)")
        }

        runningTask = nil
    }

    /// 判断本地 `lastSyncAt` 是否在 TTL 内。解析失败 / 无记录 → 视为过期（需要 sync）。
    private func isLastSyncFresh(userID: Int64, maxAge: TimeInterval) async -> Bool {
        guard let iso = try? await repository.fetchLastSyncAt(userID: userID),
              let lastSync = ISO8601DateFormatter.shared.date(from: iso) else {
            return false
        }
        return Date().timeIntervalSince(lastSync) < maxAge
    }

    // MARK: - C1：Rate Limit 主动等待

    /// 撞 Rate Limit 后等待到 reset + buffer 再继续。
    ///
    /// 行为：
    /// - state 切到 `.rateLimited(retryAt:)`，UI 据此显示倒计时
    /// - `Task.sleep` 全程响应 cancel（用户点取消立即抛 CancellationError）
    /// - 苏醒后 state 切回 `.syncing`，让外层 while 继续重试同一页
    ///
    /// buffer 默认 5 秒（init 注入），吸收"客户端 vs GitHub 服务器"的时钟漂移与 reset 时间精度（GitHub 给的是秒级 epoch）。
    private func waitForRateLimit(retryAfter: TimeInterval) async throws {
        let waitFor = max(0, retryAfter) + rateLimitBufferSeconds
        let retryAt = Date().addingTimeInterval(waitFor)
        AppLog.sync.warning("Rate limited; auto-waiting \(Int(waitFor), privacy: .public)s until \(retryAt, privacy: .public)")
        state = .rateLimited(retryAt: retryAt)
        try await Task.sleep(for: .seconds(waitFor))
        try Task.checkCancellation()
        state = .syncing
        AppLog.sync.info("Rate limit window passed; resuming sync")
    }
}
