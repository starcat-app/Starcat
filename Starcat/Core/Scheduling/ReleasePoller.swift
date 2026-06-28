//
//  ReleasePoller.swift
//  Starcat
//
//  后台 Release 轮询调度器（HOM-47）。
//
//  设计要点：
//  - 使用 `NSBackgroundActivityScheduler`（macOS 原生 API），由系统在低负载、合适功耗的窗口期触发
//      比 Timer 自调度更省电，符合 Apple 后台任务设计建议（见 docs/1-立项/开发前问题清单 §xxx）
//  - 默认间隔 4 小时（`tolerance` 30 分钟）；GitHub Release 发布频率远低于此，覆盖典型日常需求
//  - 巡检入口委托给 `ReleaseMonitor.runOnce()`，本类只负责调度 + 通知派发 + 启停
//  - App 取消所有订阅时不强制停止 scheduler（仍跑空巡）；订阅再开后立即生效
//
//  生命周期：
//  - start(): 创建 scheduler 并 schedule（幂等：重复调用直接 no-op）
//  - stop():  invalidate scheduler，释放
//  - runNow(): 手动触发一次巡检（详情页 / 设置页 "立即检查更新" 按钮 + 单测路径）
//

import Foundation

@MainActor
final class ReleasePoller {

    // MARK: - 依赖

    private let monitor: ReleaseMonitor
    private let notificationService: ReleaseNotificationService

    // MARK: - 调度参数

    /// 默认轮询间隔：4 小时。
    /// 选 4 而不是 6 小时是平衡 "及时性 vs 配额 vs 功耗"：
    /// - GitHub 5000/h 配额够支撑 ~80 个订阅 × 6 次/天的查询
    /// - 大多数 Release 发布的"被发现 4h 内"对用户体验已足够
    ///
    /// `nonisolated`：本类整体 `@MainActor`，但 `start(interval:tolerance:)` 的
    /// 默认参数值表达式（`= ReleasePoller.defaultInterval`）在 Swift 6 严格模式下
    /// 默认是 `nonisolated` 上下文求值的，引用 `@MainActor`-isolated static 会报
    /// "main actor-isolated static property cannot be referenced from a nonisolated
    /// context"。常量本身不可变 + 值类型，标 `nonisolated` 完全安全。
    nonisolated static let defaultInterval: TimeInterval = 4 * 60 * 60

    /// scheduler 容差：允许系统在 [interval-tolerance, interval+tolerance] 任意时间点触发。
    /// `nonisolated` 同 `defaultInterval`，原因见上。
    nonisolated static let defaultTolerance: TimeInterval = 30 * 60

    // MARK: - 状态

    private var scheduler: NSBackgroundActivityScheduler?

    /// 当前是否正在运行（暴露给 UI / 测试用，不影响调度）。
    private(set) var isRunning: Bool = false

    /// 上次手动 / 调度触发时间，用于 UI 展示 "上次检查于"。
    private(set) var lastRunAt: Date?

    /// 上次巡检报告（含通知列表，UI 可订阅）。
    private(set) var lastReport: ReleaseMonitorReport?

    init(monitor: ReleaseMonitor, notificationService: ReleaseNotificationService) {
        self.monitor = monitor
        self.notificationService = notificationService
    }

    // MARK: - 生命周期

    /// 启动调度器。重复调用是 no-op。
    func start(
        interval: TimeInterval = ReleasePoller.defaultInterval,
        tolerance: TimeInterval = ReleasePoller.defaultTolerance
    ) {
        guard scheduler == nil else { return }

        let activity = NSBackgroundActivityScheduler(identifier: "\(AppConstants.bundleIdentifier).releasePoller")
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = tolerance
        activity.qualityOfService = .utility

        // closure 在系统选定的后台线程上跑；hop 回 main actor 后再用 monitor / state。
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                await self.performScan()
                completion(.finished)
            }
        }

        scheduler = activity
        isRunning = true
        AppLog.general.info("ReleasePoller started, interval=\(Int(interval), privacy: .public)s")
    }

    /// 停止调度器（不影响已派发的通知）。
    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        isRunning = false
        AppLog.general.info("ReleasePoller stopped")
    }

    // MARK: - 立即触发

    /// 手动触发一次巡检（UI / 单测调用）。
    /// 与调度器触发走同一路径。
    @discardableResult
    func runNow() async -> ReleaseMonitorReport {
        await performScan()
        // performScan 内部已经赋值 lastReport
        return lastReport ?? ReleaseMonitorReport(newReleasesByRepo: [:], notifications: [], perRepoErrors: [:])
    }

    // MARK: - 私有

    /// 实际跑一次巡检 + 通知派发；维护 lastRunAt / lastReport 状态。
    private func performScan() async {
        let report = await monitor.runOnce()
        lastRunAt = Date()
        lastReport = report

        // 把 notifications 推给系统通知中心（service 内部静默处理无授权情况）。
        if !report.notifications.isEmpty {
            await notificationService.dispatch(report.notifications)
        }
    }
}
