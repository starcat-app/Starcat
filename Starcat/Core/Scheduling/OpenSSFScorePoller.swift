//
//  OpenSSFScorePoller.swift
//  Starcat
//
//  OpenSSF Scorecard 后台刷新调度器。
//
//  只在登录态启动，登出停止。调度器本身不持有 UI 状态；单次任务委托给
//  OpenSSFScoreService，后者按已 star / 已入库候选 + TTL + 限流决定实际请求集合。
//

import Foundation
import Observation

@MainActor
@Observable
final class OpenSSFScorePoller {
    nonisolated static let defaultInterval: TimeInterval = 24 * 60 * 60
    nonisolated static let defaultTolerance: TimeInterval = 60 * 60

    private let service: OpenSSFScoreService
    private var scheduler: NSBackgroundActivityScheduler?
    private var activeRefreshTask: Task<Int, Never>?
    private var refreshGeneration = 0

    private(set) var isRunning = false
    private(set) var isRefreshing = false
    private(set) var lastRunAt: Date?
    private(set) var lastRefreshCount: Int = 0
    private(set) var refreshProcessed: Int = 0
    private(set) var refreshTotal: Int = 0

    init(service: OpenSSFScoreService) {
        self.service = service
    }

    func start(
        interval: TimeInterval = OpenSSFScorePoller.defaultInterval,
        tolerance: TimeInterval = OpenSSFScorePoller.defaultTolerance
    ) {
        guard scheduler == nil else { return }

        let activity = NSBackgroundActivityScheduler(identifier: "\(AppConstants.bundleIdentifier).openSSFScorePoller")
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
                _ = await self.runNow()
                completion(.finished)
            }
        }

        scheduler = activity
        isRunning = true
        AppLog.general.info("OpenSSFScorePoller started, interval=\(Int(interval), privacy: .public)s")
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        isRunning = false
        AppLog.general.info("OpenSSFScorePoller stopped")
    }

    @discardableResult
    func runNow() async -> Int {
        await startRefreshTask()
    }

    /// 只终止当前这一轮刷新，不影响 NSBackgroundActivityScheduler 后续周期调度。
    func cancelCurrentRefresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isRefreshing = false
        refreshProcessed = 0
        refreshTotal = 0
        AppLog.general.info("OpenSSFScorePoller current refresh cancelled")
    }

    @discardableResult
    private func startRefreshTask() async -> Int {
        guard activeRefreshTask == nil, !isRefreshing else {
            AppLog.general.info("OpenSSFScorePoller skipped because previous refresh is still running")
            return 0
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { @MainActor [weak self] in
            await self?.performRefresh(generation: generation) ?? 0
        }
        activeRefreshTask = task

        let count = await task.value
        if refreshGeneration == generation {
            activeRefreshTask = nil
        }
        return count
    }

    private func performRefresh(generation: Int) async -> Int {
        isRefreshing = true
        refreshProcessed = 0
        refreshTotal = 0
        defer {
            if refreshGeneration == generation {
                isRefreshing = false
            }
        }

        let count = await service.refreshStaleCandidateRepos(
            limit: 100,
            progress: { [weak self] processed, total in
                await MainActor.run {
                    self?.refreshProcessed = processed
                    self?.refreshTotal = total
                }
            }
        )
        guard !Task.isCancelled else { return 0 }
        lastRunAt = Date()
        lastRefreshCount = count
        return count
    }
}
