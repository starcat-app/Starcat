//
//  ActivityCategoryCountService.swift
//  Starcat
//
//  Activity 分类与 Sidebar 之间共享的轻量计数状态。
//  按数据库账号恢复少量整数，切入栏目先显示上次结果，再由本地查询校准。
//

import Foundation
import Observation

/// 计数独立于列表生命周期；未知值保持 nil，真实查询返回的 0 才能覆盖缓存。
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
    /// ViewModel 和异步读库任务持有启动时的代际，换号后的迟到结果不能写入新账号。
    private(set) var scopeRevision: UInt64 = 0

    private let defaults: UserDefaults?
    private var cacheKey: String
    private var isChangingAccount = false

    private var undoStarRepository: (any UndoStarHistoryRepositoryProtocol)?
    private var notificationRepository: (any GitHubNotificationThreadRepositoryProtocol)?
    private var activityRepository: (any UserRepoActivityRepositoryProtocol)?
    private var countTask: Task<Void, Never>?
    private var notificationCountTask: Task<Void, Never>?
    private var activityCountTask: Task<Void, Never>?

    /// 测试默认不落盘；生产显式注入 UserDefaults，与实际打开的数据库账号绑定。
    init(defaults: UserDefaults? = nil, accountID: Int64? = nil) {
        self.defaults = defaults
        cacheKey = Self.cacheKey(accountID: accountID)
        restoreCachedCounts()
    }

    func count(for category: ActivityCategory) -> Int? {
        if category == .undoStar { return undoStarCount }
        if category == .notification { return notificationUnreadCount }
        return localCounts?[category]
    }

    /// 局部快照只提交已成功读取的分类，不能把未读取的分类当成零。
    func applyLocalCounts(_ counts: [ActivityCategory: Int], scopeRevision: UInt64) {
        guard accepts(scopeRevision) else { return }
        let local = counts.filter { $0.key != .notification && $0.key != .undoStar }
        guard !local.isEmpty else { return }
        localCounts = (localCounts ?? [:]).merging(local) { _, updated in updated }
        persistCounts()
    }

    func applyUndoStarCount(_ count: Int, scopeRevision: UInt64) {
        guard accepts(scopeRevision) else { return }
        undoStarCount = count
        persistCounts()
    }

    /// 必须在数据库 reopen 前失效，覆盖 reopen 挂起期间旧查询返回的窗口。
    func prepareForAccountChange() {
        isChangingAccount = true
        localCounts = nil
        undoStarCount = nil
        notificationUnreadCount = nil
        notificationTotalCount = nil
    }

    /// 数据库切换成功后，先同步恢复对应账号，再异步校准独立计数。
    func activate(accountID: Int64?) {
        scopeRevision &+= 1
        cacheKey = Self.cacheKey(accountID: accountID)
        isChangingAccount = false
        restoreCachedCounts()
        Task {
            await refreshUndoStarCount()
            await refreshNotificationCounts()
        }
    }

    /// reopen 失败时数据库仍属于原账号，保留代际让原页面继续发布，不能永久失效。
    func cancelAccountChange() {
        isChangingAccount = false
        restoreCachedCounts()
        Task {
            await refreshUndoStarCount()
            await refreshNotificationCounts()
        }
    }

    private func accepts(_ revision: UInt64) -> Bool {
        !isChangingAccount && revision == scopeRevision
    }

    private static func cacheKey(accountID: Int64?) -> String {
        "activity.sidebar.counts.v1.\(accountID.map(String.init) ?? "_anonymous")"
    }

    /// 快照只有个位数整数，同步读取能在首帧直接展示；不保存活动内容或认证信息。
    private func restoreCachedCounts() {
        let cached = defaults?.dictionary(forKey: cacheKey) as? [String: Int] ?? [:]
        let local = Dictionary(uniqueKeysWithValues: cached.compactMap { key, value -> (ActivityCategory, Int)? in
            guard let category = ActivityCategory(rawValue: key),
                  category != .notification, category != .undoStar else { return nil }
            return (category, value)
        })
        localCounts = local.isEmpty ? nil : local
        undoStarCount = cached[ActivityCategory.undoStar.rawValue]
        notificationUnreadCount = cached[ActivityCategory.notification.rawValue]
        notificationTotalCount = cached["notificationTotal"]
    }

    private func persistCounts() {
        var cached = Dictionary(uniqueKeysWithValues: (localCounts ?? [:]).map { ($0.key.rawValue, $0.value) })
        cached[ActivityCategory.undoStar.rawValue] = undoStarCount
        cached[ActivityCategory.notification.rawValue] = notificationUnreadCount
        cached["notificationTotal"] = notificationTotalCount
        defaults?.set(cached, forKey: cacheKey)
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
        guard !isChangingAccount, let repo = undoStarRepository else { return }
        let revision = scopeRevision
        do {
            let count = try await repo.count()
            applyUndoStarCount(count, scopeRevision: revision)
        } catch { }
    }

    private func refreshNotificationCounts() async {
        guard !isChangingAccount, let repo = notificationRepository else { return }
        let revision = scopeRevision
        do {
            async let unread = repo.unreadCount()
            async let total = repo.totalCount()
            let unreadCount = try await unread
            // 「全部」面包屑含账本行；侧栏角标仍只用 GitHub 未读。
            let activities = try await activityRepository?.count() ?? 0
            let totalCount = try await total
            guard accepts(revision) else { return }
            notificationUnreadCount = unreadCount
            notificationTotalCount = totalCount + activities
            persistCounts()
        } catch { }
    }
}
