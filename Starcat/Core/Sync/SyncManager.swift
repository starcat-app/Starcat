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
//  尚未做（Week 5+ 或后续优化）：
//  - 增量同步：starred_at 时间戳对比（W4-4 C3 即将做）
//  - ETag 缓存（W4-4 C2 即将做）
//  - 后台定时同步（NSBackgroundActivityScheduler）
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
    /// 重复调用：如果已在同步中，直接返回；不排队。
    func performFullSync(userID: Int64) {
        guard !isSyncing else { return }
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.runSync(userID: userID)
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

    private func runSync(userID: Int64) async {
        state = .syncing
        progress = SyncProgress(current: 0, total: nil, currentPage: 1)
        AppLog.sync.info("Full sync started (user=\(userID, privacy: .public))")

        var page = 1
        let perPage = 100
        var totalSynced = 0
        var allRemoteIDs: Set<Int64> = []
        let syncStartedAt = Date()
        // C1：本轮 runSync 是否已经为 rate limit 主动等待过一次。
        // 只允许 1 次自动重试 — 第二次撞墙就抛 rateLimited 让用户决定。
        // 这样避免"配额估算错误 / 重置时间漂移"导致 sleep 死循环。
        var rateLimitRetried = false

        do {
            while true {
                try Task.checkCancellation()

                // C1：单次 fetch 用 inner do-catch 包裹，专门拦 rateLimited 做退避重试。
                // 退避成功后 `continue` 同一 page 重跑，外层循环 untouched。
                let response: APIResponse<[StarredRepoDTO]>
                do {
                    response = try await apiClient.starredRepos(page: page, perPage: perPage)
                } catch NetworkError.rateLimited(let retryAfter) where !rateLimitRetried {
                    rateLimitRetried = true
                    try await waitForRateLimit(retryAfter: retryAfter)
                    continue
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

                // 判断是否还有下一页
                if response.linkHeader.nextPage == nil {
                    break
                }
                page = response.linkHeader.nextPage ?? (page + 1)
            }

            try Task.checkCancellation()

            // 标记本地多出的为 unstarred
            try await repository.markUnstarredExcept(remoteRepoIDs: allRemoteIDs, userID: userID)

            // 更新 sync_state
            try await repository.updateSyncState(
                userID: userID,
                starredCount: totalSynced,
                syncedCount: totalSynced,
                status: "idle"
            )

            // 进度补齐到 100%。
            // 注意：GitHub Stars API 的总数靠 Link 头 last 页号估算（lastPage * perPage），
            // 真实最后一页只有 1~perPage 条，所以估算值通常偏大。
            // 同步完成时把 total 校正为实际拉到的数量，避免 UI 显示 "1801 / 1900" 这类残留估算误差。
            progress = SyncProgress(current: totalSynced, total: totalSynced, currentPage: page)
            state = .completed(at: Date())
            AppLog.sync.info("Full sync complete: \(totalSynced, privacy: .public) repos in \(Int(Date().timeIntervalSince(syncStartedAt)), privacy: .public)s")
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
            state = .failed(message: "Token 失效，请重新登录")
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
