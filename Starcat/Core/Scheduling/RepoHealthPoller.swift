//
//  RepoHealthPoller.swift
//  Starcat
//
//  Repo Health 后台刷新调度器。
//
//  只在登录态启动，登出停止。它不持有 UI 状态；单次任务委托给
//  RepoHealthService，服务层按 stale_after 决定实际刷新集合。
//
//  后台健康度是“持续温和铺底”：每小时最多处理 100 条 stale repo，repo 之间留出
//  固定间隔，避免集中读写 SQLite。若上一轮还没结束，下一轮直接跳过，不并发叠加。
//

import Foundation

@MainActor
final class RepoHealthPoller {
    nonisolated static let defaultInterval: TimeInterval = 60 * 60
    nonisolated static let defaultTolerance: TimeInterval = 10 * 60
    nonisolated static let defaultDelayBetweenRepos: TimeInterval = 1

    private let service: RepoHealthService
    private var scheduler: NSBackgroundActivityScheduler?

    private(set) var isRunning = false
    private(set) var isRefreshing = false
    private(set) var lastRunAt: Date?
    private(set) var lastRefreshCount: Int = 0

    init(service: RepoHealthService) {
        self.service = service
    }

    func start(
        interval: TimeInterval = RepoHealthPoller.defaultInterval,
        tolerance: TimeInterval = RepoHealthPoller.defaultTolerance
    ) {
        guard scheduler == nil else { return }

        let activity = NSBackgroundActivityScheduler(identifier: "\(AppConstants.bundleIdentifier).repoHealthPoller")
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
        AppLog.general.info("RepoHealthPoller started, interval=\(Int(interval), privacy: .public)s")
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        isRunning = false
        AppLog.general.info("RepoHealthPoller stopped")
    }

    @discardableResult
    func runNow() async -> Int {
        await performRefresh()
        return lastRefreshCount
    }

    private func performRefresh() async {
        guard !isRefreshing else {
            AppLog.general.info("RepoHealthPoller skipped because previous refresh is still running")
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let count = await service.refreshStaleStarredRepos(
            limit: 100,
            delayBetweenRepos: Self.defaultDelayBetweenRepos
        )
        lastRunAt = Date()
        lastRefreshCount = count
    }
}
