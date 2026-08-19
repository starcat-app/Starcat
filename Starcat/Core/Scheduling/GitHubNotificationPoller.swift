//
//  GitHubNotificationPoller.swift
//  Starcat
//
//  通知 inbox 后台轮询。GitHub 的 X-Poll-Interval 常是 60s，产品下限仍 ≥ 30 分钟，
//  与 Release / Health 同档，避免前台打开时已经够用的增量再被后台打爆配额。
//
//  测试 host 跳过 NSBackgroundActivityScheduler：测试进程没有稳定的后台窗口。
//

import Foundation

@MainActor
final class GitHubNotificationPoller {

    /// 产品下限：30 分钟。GitHub 建议的 poll interval 只作上限参考，不会把后台节奏打到 1 分钟。
    nonisolated static let minimumInterval: TimeInterval = 30 * 60
    nonisolated static let defaultTolerance: TimeInterval = 5 * 60

    private let inbox: GitHubNotificationInboxService
    private let syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol
    private var scheduler: NSBackgroundActivityScheduler?
    private(set) var isRunning = false

    init(
        inbox: GitHubNotificationInboxService,
        syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol
    ) {
        self.inbox = inbox
        self.syncStateRepository = syncStateRepository
    }

    func start() {
        guard !TestEnvironment.isRunning else { return }
        guard scheduler == nil else { return }

        let activity = NSBackgroundActivityScheduler(
            identifier: "\(AppConstants.bundleIdentifier).githubNotificationPoller"
        )
        activity.repeats = true
        activity.interval = Self.minimumInterval
        activity.tolerance = Self.defaultTolerance
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                await self.inbox.sync()
                await self.alignIntervalWithGitHub()
                completion(.finished)
            }
        }
        scheduler = activity
        isRunning = true
        AppLog.general.info("GitHubNotificationPoller started")
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        isRunning = false
        AppLog.general.info("GitHubNotificationPoller stopped")
    }

    func runNow() async {
        await inbox.sync()
    }

    /// 若 GitHub 给了更大的 poll interval，把 scheduler 拉到 max(30min, github)。
    private func alignIntervalWithGitHub() async {
        guard let seconds = try? await syncStateRepository.current()?.lastPollIntervalSeconds else {
            return
        }
        let interval = max(Self.minimumInterval, TimeInterval(seconds))
        scheduler?.interval = interval
    }
}
