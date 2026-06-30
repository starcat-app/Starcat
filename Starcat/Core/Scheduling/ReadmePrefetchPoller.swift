//
//  ReadmePrefetchPoller.swift
//  Starcat
//
//  README 后台预拉调度器。
//
//  模块级说明：
//  - 只在登录态且设置开关开启时启动；
//  - 使用 `NSBackgroundActivityScheduler` 让系统选择合适时机执行；
//  - 单轮限量、串行、低 QoS，上一轮未完成时跳过，避免影响 Starcat 前台操作。
//

import Foundation

@MainActor
final class ReadmePrefetchPoller {
    nonisolated static let defaultInterval: TimeInterval = 60 * 60
    nonisolated static let defaultTolerance: TimeInterval = 15 * 60

    private let service: ReadmePrefetchService
    private var scheduler: NSBackgroundActivityScheduler?

    private(set) var isRunning = false
    private(set) var lastRunAt: Date?
    private(set) var lastProcessedCount: Int = 0

    init(service: ReadmePrefetchService) {
        self.service = service
    }

    func start(
        interval: TimeInterval = ReadmePrefetchPoller.defaultInterval,
        tolerance: TimeInterval = ReadmePrefetchPoller.defaultTolerance
    ) {
        guard scheduler == nil else { return }

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
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        isRunning = false
        service.markDisabled()
        AppLog.network.info("ReadmePrefetchPoller stopped")
    }

    @discardableResult
    func runNow() async -> Int {
        await performRefresh()
        return lastProcessedCount
    }

    private func performRefresh() async {
        guard !service.isRunning else {
            AppLog.network.info("ReadmePrefetchPoller skipped because previous refresh is still running")
            return
        }

        let count = await service.runBatch()
        lastRunAt = Date()
        lastProcessedCount = count
    }
}
