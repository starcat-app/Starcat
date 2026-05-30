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
//  尚未做（Week 3+ 或后续优化）：
//  - 增量同步：starred_at 时间戳对比
//  - 后台定时同步（NSBackgroundActivityScheduler）
//  - 部分失败的断点续传
//  - Rate Limit 主动等待（当前依赖 NetworkError.rateLimited 抛出后中止）
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

    private let apiClient: GitHubAPIClient
    private let repository: RepoRepository

    /// 当前进行中的同步 Task，便于取消。
    private var runningTask: Task<Void, Never>?

    // MARK: - 初始化

    init(apiClient: GitHubAPIClient, repository: RepoRepository) {
        self.apiClient = apiClient
        self.repository = repository
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

        do {
            while true {
                try Task.checkCancellation()

                let response = try await apiClient.starredRepos(page: page, perPage: perPage)
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
}
