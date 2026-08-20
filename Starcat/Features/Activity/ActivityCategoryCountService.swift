//
//  ActivityCategoryCountService.swift
//  Starcat
//
//  Activity 分类与 Sidebar 之间共享的轻量计数状态。
//

import Foundation
import Observation

@MainActor
@Observable
final class ActivityCategoryCountService {

    private(set) var localCounts: [ActivityCategory: Int]?
    /// Undo Star 计数独立存储（不依赖 ActivityViewModel 是否已加载）。
    private var undoStarCount: Int?
    /// 通知 inbox 未读数：侧栏角标用。不进「全部」聚合。
    private var notificationUnreadCount: Int?
    /// 通知 inbox 总数：中栏面包屑副标题用。和未读分开，避免侧栏把总数当成角标。
    private(set) var notificationTotalCount: Int?

    private var undoStarRepository: (any UndoStarHistoryRepositoryProtocol)?
    private var notificationRepository: (any GitHubNotificationThreadRepositoryProtocol)?
    private var activityRepository: (any UserRepoActivityRepositoryProtocol)?
    private var countTask: Task<Void, Never>?
    private var notificationCountTask: Task<Void, Never>?
    private var activityCountTask: Task<Void, Never>?

    func count(for category: ActivityCategory) -> Int? {
        if category == .undoStar { return undoStarCount }
        if category == .notification { return notificationUnreadCount }
        // 组织 Issue 是会话级远端结果；数量由中栏回传，不把本地聚合默认 0 画成角标。
        if category == .organizationIssues { return nil }
        guard let localCounts else { return nil }
        return localCounts[category] ?? 0
    }

    func applyLocalCounts(_ counts: [ActivityCategory: Int]) {
        localCounts = counts
    }

    func applyUndoStarCount(_ count: Int) {
        undoStarCount = count
    }

    func configure(undoStarRepository: any UndoStarHistoryRepositoryProtocol) {
        self.undoStarRepository = undoStarRepository
        Task { await refreshUndoStarCount() }
        countTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .undoStarHistoryDidChange) {
                guard !Task.isCancelled else { break }
                await refreshUndoStarCount()
            }
        }
    }

    func configureNotifications(
        repository: any GitHubNotificationThreadRepositoryProtocol,
        activityRepository: (any UserRepoActivityRepositoryProtocol)? = nil
    ) {
        self.notificationRepository = repository
        self.activityRepository = activityRepository
        Task { await refreshNotificationCounts() }
        notificationCountTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .githubNotificationInboxDidChange) {
                guard !Task.isCancelled else { break }
                await refreshNotificationCounts()
            }
        }
        activityCountTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .userRepoActivityDidChange) {
                guard !Task.isCancelled else { break }
                await refreshNotificationCounts()
            }
        }
    }

    private func refreshUndoStarCount() async {
        guard let repo = undoStarRepository else { return }
        do {
            let records = try await repo.fetchAll(sort: .unstarredAtDesc)
            undoStarCount = records.count
        } catch { }
    }

    private func refreshNotificationCounts() async {
        guard let repo = notificationRepository else { return }
        do {
            async let unread = repo.unreadCount()
            async let total = repo.totalCount()
            notificationUnreadCount = try await unread
            // 「全部」面包屑含账本行；侧栏角标仍只用 GitHub 未读。
            let activities = (try? await activityRepository?.count()) ?? 0
            notificationTotalCount = (try await total) + activities
        } catch { }
    }
}
