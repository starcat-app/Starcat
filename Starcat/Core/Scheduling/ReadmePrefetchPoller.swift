//
//  ReadmePrefetchPoller.swift
//  Starcat
//
//  README 后台预拉调度器。
//
//  模块级说明：
//  - 只在登录态且设置开关开启时启动；
//  - 使用 `NSBackgroundActivityScheduler` 让系统选择合适时机执行；
//  - 启动后延迟首批，避开登录恢复 / 用户 DB 切换的启动竞争窗口；
//  - 单批限量、串行、低 QoS；候选项很多时连续小批量 drain，避免 1 小时只跑一批。
//

import Foundation

@MainActor
@Observable
final class ReadmePrefetchPoller {
    nonisolated static let defaultInterval: TimeInterval = 60 * 60
    nonisolated static let defaultTolerance: TimeInterval = 15 * 60
    nonisolated static let defaultInitialBatchDelay: TimeInterval = 10 * 60
    nonisolated static let continuousBatchDelay: TimeInterval = 30

    private let service: ReadmePrefetchService
    private var scheduler: NSBackgroundActivityScheduler?
    private var initialBatchTask: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var isDraining = false
    private(set) var nextRunAt: Date?
    private(set) var lastRunAt: Date?
    private(set) var lastProcessedCount: Int = 0

    init(service: ReadmePrefetchService) {
        self.service = service
    }

    @discardableResult
    func start(
        interval: TimeInterval = ReadmePrefetchPoller.defaultInterval,
        tolerance: TimeInterval = ReadmePrefetchPoller.defaultTolerance
    ) -> Bool {
        guard scheduler == nil else { return false }

        service.markIdleIfDisabled()

        let activity = NSBackgroundActivityScheduler(identifier: "\(AppConstants.bundleIdentifier).readmePrefetchPoller")
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = tolerance
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                await self.performRefresh()
                completion(.finished)
            }
        }

        scheduler = activity
        isRunning = true
        AppLog.network.info("ReadmePrefetchPoller started, interval=\(Int(interval), privacy: .public)s")
        return true
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        cancelScheduledInitialBatch()
        isRunning = false
        service.markDisabled()
        AppLog.network.info("ReadmePrefetchPoller stopped")
    }

    /// 安排启动后的首批预拉。
    ///
    /// 登录恢复时 AuthSession 会先用 cached profile 让 UI 秒开，真实 `/user` 校验和用户 DB
    /// 切换稍后完成。首批预拉延迟执行，避免在 DB 尚未切稳时查询候选项并把 UI 误置为
    /// “暂时不可用”。用户仍可通过设置页“立即拉取”绕过等待。
    func scheduleInitialBatch(after delay: TimeInterval = ReadmePrefetchPoller.defaultInitialBatchDelay) {
        guard isRunning, !isDraining, !service.isRunning else { return }
        cancelScheduledInitialBatch()

        let fireDate = Date().addingTimeInterval(delay)
        nextRunAt = fireDate
        initialBatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            nextRunAt = nil
            await performRefresh()
        }
        AppLog.network.info("ReadmePrefetchPoller initial batch scheduled after \(Int(delay), privacy: .public)s")
    }

    @discardableResult
    func runNow() async -> Int {
        cancelScheduledInitialBatch()
        return await performRefresh()
    }

    /// 连续跑 README 预拉小批次。
    ///
    /// 设计约束：
    /// - 单批仍交给 `ReadmePrefetchService.runBatch` 控制上限和 repo 间隔；
    /// - 只有“本批刚好跑满上限”才继续下一批，避免空转查询；
    /// - 批间短 sleep 给前台 UI / SQLite / GitHub API 留出喘息窗口；
    /// - `isDraining` 是 poller 级互斥，覆盖“批间等待”窗口，避免手动按钮和系统调度重复启动。
    @discardableResult
    private func performRefresh() async -> Int {
        nextRunAt = nil
        guard !isDraining, !service.isRunning else {
            AppLog.network.info("ReadmePrefetchPoller skipped because previous refresh is still running")
            return 0
        }

        isDraining = true
        defer { isDraining = false }

        var accumulatedCount = 0
        while isRunning {
            let count = await service.runBatch()
            lastRunAt = Date()
            lastProcessedCount = count
            accumulatedCount += count

            guard shouldContinueAfterBatch(processed: count) else { break }

            AppLog.network.info(
                "ReadmePrefetchPoller full batch processed; continuing after \(Int(Self.continuousBatchDelay), privacy: .public)s"
            )
            try? await Task.sleep(nanoseconds: UInt64(Self.continuousBatchDelay * 1_000_000_000))
        }

        return accumulatedCount
    }

    private func shouldContinueAfterBatch(processed: Int) -> Bool {
        guard processed >= ReadmePrefetchService.defaultBatchLimit else { return false }
        guard case .completed(_, let total) = service.status else { return false }
        return total >= ReadmePrefetchService.defaultBatchLimit
    }

    private func cancelScheduledInitialBatch() {
        initialBatchTask?.cancel()
        initialBatchTask = nil
        nextRunAt = nil
    }
}
