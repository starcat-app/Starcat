//
//  DataContributionCoordinator.swift
//  Starcat
//
//  公开 Star 数据贡献的旁路编排器：完整同步快照、单任务上传和静默重试。
//
//  并发约束：
//  - actor 内同一时间只保留一个上传 Task，重复触发只做幂等唤醒。
//  - 切换账户先取消请求，再让 DatabaseManager reopen；旧账号结果不能落入新账号 DB。
//  - 所有错误都在本模块收口，不抛回 SyncManager、不触发通知或用户可见错误。
//

import Foundation
import Network

actor DataContributionCoordinator {
    private static let maximumRetryDelay: TimeInterval = 24 * 60 * 60

    private let repository: DataContributionRepository
    private let repoRepository: any RepoRepositoryProtocol
    private let uploader: any CollectionSnapshotUploading
    private let retryBaseDelay: TimeInterval
    private let jitterProvider: @Sendable () -> Double
    private let automaticallyScheduleRetry: Bool
    private let networkMonitor = DataContributionNetworkMonitor()

    private var activeAccountID: Int64?
    private var uploadTask: Task<Void, Never>?
    private var rescanRequested = false
    private var retryWakeTask: Task<Void, Never>?
    private var isNetworkMonitorStarted = false

    init(
        repository: DataContributionRepository,
        repoRepository: any RepoRepositoryProtocol,
        uploader: any CollectionSnapshotUploading,
        retryBaseDelay: TimeInterval = 30,
        jitterProvider: @escaping @Sendable () -> Double = { Double.random(in: 0.85...1.15) },
        automaticallyScheduleRetry: Bool = true
    ) {
        self.repository = repository
        self.repoRepository = repoRepository
        self.uploader = uploader
        self.retryBaseDelay = retryBaseDelay
        self.jitterProvider = jitterProvider
        self.automaticallyScheduleRetry = automaticallyScheduleRetry
    }

    /// App 启动后只安装一次网络恢复监听；未登录时不会读取任何账户数据。
    func start() {
        guard !isNetworkMonitorStarted else { return }
        isNetworkMonitorStarted = true
        networkMonitor.start { [weak self] in
            Task { await self?.networkBecameAvailable() }
        }
    }

    /// 必须在 DatabaseManager.reopen 之前调用，取消旧账号的 HTTP 请求和定时唤醒。
    func suspendForAccountChange() {
        activeAccountID = nil
        uploadTask?.cancel()
        uploadTask = nil
        rescanRequested = false
        retryWakeTask?.cancel()
        retryWakeTask = nil
    }

    /// 数据库切换完成后绑定真实账户，并扫描一次已到期任务。
    func activate(accountID: Int64?) {
        suspendForAccountChange()
        activeAccountID = accountID
        kick()
    }

    func preferences(accountID: Int64) async throws -> DataContributionPreferences {
        try await repository.preferences(accountID: accountID)
    }

    /// 设置修改与 Outbox 清理由同一 SQLite 事务完成；开启不会主动触发 GitHub 同步。
    @discardableResult
    func setEnabled(_ isEnabled: Bool, accountID: Int64) async throws -> DataContributionPreferences {
        _ = try await repository.setEnabled(isEnabled, accountID: accountID)
        let value = try await repository.preferences(accountID: accountID)
        if isEnabled { kick() }
        return value
    }

    /// 仅由 SyncManager 的“成功完整同步”边沿触发。构造、入队、上传任一步失败都静默收口。
    func handleSuccessfulFullSync(accountID: Int64, capturedAt: Date) async {
        guard activeAccountID == accountID else { return }
        do {
            let preferences = try await repository.preferences(accountID: accountID)
            guard preferences.isEnabled, let participantID = preferences.participantID else { return }
            let repos = try await repoRepository.fetchAllStarred()
            guard activeAccountID == accountID else { return }
            let snapshot = try RecommendationSnapshotBuilder.build(
                repositories: repos,
                participantID: participantID,
                capturedAt: capturedAt
            )
            try await repository.enqueue(snapshot: snapshot, accountID: accountID)
            kick()
        } catch {
            // 旁路契约：这里故意不记包含 error 文本的日志，也不改变正常同步结果。
        }
    }

    private func networkBecameAvailable() {
        kick()
    }

    private func kick() {
        guard let accountID = activeAccountID else { return }
        guard uploadTask == nil else {
            // 完整同步可能恰好在一次“空队列扫描”进行时入队，记住边沿，扫描收尾后再跑一次。
            rescanRequested = true
            return
        }
        uploadTask = Task { [weak self] in
            await self?.runOneDueTask(accountID: accountID)
        }
    }

    private func runOneDueTask(accountID: Int64) async {
        defer { finishUploadScan(accountID: accountID) }
        guard activeAccountID == accountID else { return }

        var attemptedTask: DataContributionOutboxTask?
        do {
            guard let task = try await repository.dueTask(accountID: accountID) else { return }
            attemptedTask = task
            try Task.checkCancellation()
            try await uploader.upload(task: task)
            try Task.checkCancellation()
            guard activeAccountID == accountID else { return }
            try await repository.remove(taskID: task.id, accountID: accountID)
        } catch is CancellationError {
            // Outbox 仍是 pending/retry_wait，下次启动或账户恢复后继续同一业务键。
        } catch DataContributionRepositoryError.accountScopeChanged {
            // 数据库已切换；旧库中的任务保持原样，不能在新库里写重试状态。
        } catch {
            guard let attemptedTask else { return }
            await deferFailedTask(error: error, task: attemptedTask, accountID: accountID)
        }
    }

    private func finishUploadScan(accountID: Int64) {
        uploadTask = nil
        guard activeAccountID == accountID, rescanRequested else { return }
        rescanRequested = false
        kick()
    }

    private func deferFailedTask(
        error: Error,
        task: DataContributionOutboxTask,
        accountID: Int64
    ) async {
        guard activeAccountID == accountID else { return }
        do {
            let nextAttempt = task.attemptCount + 1
            let delay = Self.retryDelay(
                for: error,
                attemptCount: nextAttempt,
                baseDelay: retryBaseDelay,
                jitter: jitterProvider()
            )
            let retryAt = Date().addingTimeInterval(delay)
            let didMarkRetry = try await repository.markRetry(
                taskID: task.id,
                accountID: accountID,
                attemptCount: nextAttempt,
                nextAttemptAt: retryAt
            )
            // 上传期间的新完整快照可以覆盖单槽 Outbox。旧请求失败时只能延后它自己；
            // UPDATE 未命中说明最新快照已经接管队列，应由 rescan 立即处理，不能被旧错误拖延。
            if didMarkRetry {
                scheduleRetry(at: retryAt, accountID: accountID)
            }
        } catch {
            // 连写本地重试状态失败也不能冒泡；原任务仍在数据库中等待下次启动扫描。
        }
    }

    private func scheduleRetry(at date: Date, accountID: Int64) {
        guard automaticallyScheduleRetry else { return }
        retryWakeTask?.cancel()
        retryWakeTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.retryTimerFired(accountID: accountID)
        }
    }

    private func retryTimerFired(accountID: Int64) {
        retryWakeTask = nil
        guard activeAccountID == accountID else { return }
        kick()
    }

    static func retryDelay(
        for error: Error,
        attemptCount: Int,
        baseDelay: TimeInterval = 30,
        jitter: Double = 1
    ) -> TimeInterval {
        if let apiError = error as? CollectionAPIError {
            switch apiError {
            case .httpStatus(let status) where status == 429 || status >= 500:
                break
            case .invalidResponse:
                break
            case .configurationMissing, .invalidStoredPayload, .httpStatus:
                return maximumRetryDelay
            }
        }

        let exponent = min(max(0, attemptCount - 1), 20)
        let exponential = max(1, baseDelay) * pow(2, Double(exponent))
        return min(maximumRetryDelay, exponential * min(max(jitter, 0.5), 1.5))
    }
}

/// NWPathMonitor 只产生“网络恢复”唤醒信号，不保存路径详情，也不影响正常 App 网络栈。
private final class DataContributionNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ink.starcat.data-contribution.network")

    func start(onAvailable: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            onAvailable()
        }
        monitor.start(queue: queue)
    }
}
