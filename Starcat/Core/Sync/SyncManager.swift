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
            state = .failed(message: String(localized: "sync.error.tokenExpired"))
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
