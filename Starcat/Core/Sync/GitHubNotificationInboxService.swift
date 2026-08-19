//
//  GitHubNotificationInboxService.swift
//  Starcat
//
//  通知 inbox 同步：首次 all=true 翻页回填最多 300 条；之后 since + If-Modified-Since。
//  选中已读：蓝点先灭，400ms 内划走则恢复且不 PATCH；停满再异步 PATCH。
//
//  关键约束：
//  - 回填历史不发系统通知，但会写 notified_at，避免增量把旧条目补弹一次。
//  - 禁止 mark-all。
//  - 403 视为缺 `notifications` scope，UI 引导重新授权。
//

import Foundation

extension Notification.Name {
    /// 本地 thread 表变了（同步 / 已读 / 补全）。Sidebar 未读数和 inbox 列表都听这个。
    static let githubNotificationInboxDidChange = Notification.Name("starcat.githubNotificationInboxDidChange")
    /// 系统通知点击：打开活动 → 通知分类并选中该 thread。
    static let starcatOpenGitHubNotification = Notification.Name("starcat.openGitHubNotification")
    /// 右栏「在 Starcat 中查看」：切到 Manage 并选中本地仓库。
    static let starcatRevealRepoInManage = Notification.Name("starcat.revealRepoInManage")
}

enum GitHubNotificationInboxError: Error, Equatable {
    case missingScope
    case cannotComment
}

@MainActor
final class GitHubNotificationInboxService {

    private let apiClient: any GitHubAPIClientProtocol
    private let threadRepository: any GitHubNotificationThreadRepositoryProtocol
    private let syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol
    private let notificationService: AppNotificationService
    private let settings: AppSettings
    private let clock: () -> Date
    private let dwellNanoseconds: UInt64

    private(set) var isSyncing = false
    private(set) var missingScope = false
    private(set) var lastErrorMessage: String?
    /// 系统通知点击时 inbox 视图可能还没挂上，先记在这里。
    var pendingOpenThreadId: String?
    /// 中栏当前分段。右栏上下一条要用同一份过滤结果。
    var listSegment: GitHubNotificationSegment = .all

    private var dwellTasks: [String: Task<Void, Never>] = [:]

    init(
        apiClient: any GitHubAPIClientProtocol,
        threadRepository: any GitHubNotificationThreadRepositoryProtocol,
        syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol,
        notificationService: AppNotificationService,
        settings: AppSettings,
        clock: @escaping () -> Date = Date.init,
        dwellNanoseconds: UInt64 = GitHubNotificationMapper.dwellNanoseconds
    ) {
        self.apiClient = apiClient
        self.threadRepository = threadRepository
        self.syncStateRepository = syncStateRepository
        self.notificationService = notificationService
        self.settings = settings
        self.clock = clock
        self.dwellNanoseconds = dwellNanoseconds
    }

    func fetchCached(limit: Int = GitHubNotificationMapper.backfillLimit) async -> [GitHubNotificationThreadRecord] {
        (try? await threadRepository.fetchAll(limit: limit)) ?? []
    }

    func lastFetchedAt() async -> Date? {
        guard let raw = try? await syncStateRepository.current()?.lastFetchedAt else { return nil }
        return ISO8601DateFormatter.githubDate(from: raw)
    }

    /// 打开分类 / 手动刷新 / 后台 poller 共用。
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastErrorMessage = nil
        defer { isSyncing = false }

        do {
            let state = try await syncStateRepository.current()
            let isBackfill = state?.backfillCompletedAt == nil
            if isBackfill {
                try await backfill()
            } else {
                try await incremental(state: state)
            }
            try await retryFailedMarkRead()
            missingScope = false
            postDidChange()
        } catch GitHubNotificationInboxError.missingScope {
            missingScope = true
            lastErrorMessage = String.l10n("activity.notification.missingScope.subtitle")
            postDidChange()
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.network.error("GitHub notification sync failed: \(error.localizedDescription, privacy: .public)")
            postDidChange()
        }
    }

    func hydrate(id: String) async {
        guard let record = try? await threadRepository.fetch(id: id) else { return }
        guard record.hydratedAt == nil || record.subjectCreatedAt == nil else { return }
        guard let path = GitHubNotificationMapper.path(fromAbsoluteAPIURL: record.subjectApiUrl),
              !path.isEmpty
        else { return }
        do {
            let hydration = try await apiClient.hydrateNotificationSubject(path: path)
            var comments: [GitHubNotificationComment] = []
            if let commentsPath = GitHubNotificationMapper.issueCommentsPath(
                subjectType: record.subjectType,
                subjectApiURL: record.subjectApiUrl
            ) {
                comments = (try? await apiClient.listNotificationIssueComments(path: commentsPath)) ?? []
            }
            let now = ISO8601DateFormatter.shared.string(from: clock())
            try await threadRepository.updateHydration(
                id: id,
                actorLogin: hydration.actorLogin,
                excerpt: hydration.excerpt,
                commentsJson: GitHubNotificationMapper.encodeComments(comments),
                htmlUrl: hydration.htmlURL ?? record.htmlUrl,
                subjectCreatedAt: hydration.createdAt ?? record.subjectCreatedAt ?? record.updatedAt,
                hydratedAt: now
            )
            postDidChange()
        } catch {
            AppLog.network.info("Notification hydrate skipped id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 把评论发到 GitHub，成功后再写入本地 comments_json。
    /// 不加 `repo` scope：私有仓会 404，UI 引导去 GitHub 打开。
    func postComment(threadId: String, body: String) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let record = try await threadRepository.fetch(id: threadId),
              GitHubNotificationMapper.canReply(
                subjectType: record.subjectType,
                number: record.subjectNumber
              ),
              let path = GitHubNotificationMapper.issueCommentsPath(
                subjectType: record.subjectType,
                subjectApiURL: record.subjectApiUrl
              )
        else {
            throw GitHubNotificationInboxError.cannotComment
        }
        let created = try await apiClient.createNotificationIssueComment(path: path, body: trimmed)
        var comments = GitHubNotificationMapper.decodeComments(record.commentsJson)
        if !comments.contains(where: { $0.id == created.id }) {
            comments.append(created)
        }
        let now = ISO8601DateFormatter.shared.string(from: clock())
        try await threadRepository.updateHydration(
            id: threadId,
            actorLogin: record.actorLogin,
            excerpt: record.excerpt,
            commentsJson: GitHubNotificationMapper.encodeComments(comments),
            htmlUrl: record.htmlUrl,
            subjectCreatedAt: record.subjectCreatedAt,
            hydratedAt: record.hydratedAt ?? now
        )
        postDidChange()
    }

    /// 选中一行：蓝点先灭，再开始 400ms dwell。
    func beginDwell(id: String) async {
        dwellTasks[id]?.cancel()
        dwellTasks[id] = nil
        do {
            try await threadRepository.updateLocalUnread(
                id: id,
                unread: false,
                markReadState: .pending
            )
            postDidChange()
        } catch {
            AppLog.general.error("Notification optimistic read failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let nanoseconds = dwellNanoseconds
        dwellTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
                await self.patchRead(id: id)
            } catch is CancellationError {
                await self.restoreUnreadIfPending(id: id)
            } catch {
                await self.restoreUnreadIfPending(id: id)
            }
        }
    }

    func cancelDwell(id: String) async {
        dwellTasks[id]?.cancel()
        dwellTasks[id] = nil
        // 划走时立刻恢复蓝点，不等被取消的 Task 跑到 catch。
        await restoreUnreadIfPending(id: id)
    }

    func cancelAllDwells() {
        let ids = Array(dwellTasks.keys)
        for id in ids {
            dwellTasks[id]?.cancel()
            dwellTasks[id] = nil
        }
        Task {
            for id in ids {
                await self.restoreUnreadIfPending(id: id)
            }
        }
    }

    // MARK: - Private

    private func backfill() async throws {
        var collected: [GitHubNotificationThreadDTO] = []
        var lastModified: String?
        var pollInterval: Int?
        var page = 1

        while collected.count < GitHubNotificationMapper.backfillLimit {
            let response = try await fetchPage(
                page: page,
                since: nil,
                ifModifiedSince: nil
            )
            lastModified = response.lastModified ?? lastModified
            pollInterval = response.pollIntervalSeconds ?? pollInterval
            if response.threads.isEmpty { break }
            collected.append(contentsOf: response.threads)
            if response.nextPage == nil { break }
            page = response.nextPage ?? (page + 1)
        }

        let fetchedAt = ISO8601DateFormatter.shared.string(from: clock())
        let records = collected.prefix(GitHubNotificationMapper.backfillLimit).map {
            GitHubNotificationMapper.record(from: $0, fetchedAt: fetchedAt, firstSeenAt: fetchedAt)
        }
        try await threadRepository.upsertMany(Array(records))
        try await threadRepository.markNotified(ids: records.map(\.id), notifiedAt: fetchedAt)
        let watermark = try await threadRepository.maxUpdatedAt()
        try await syncStateRepository.updateAfterFetch(
            lastModified: lastModified,
            watermarkUpdatedAt: watermark,
            lastFetchedAt: clock(),
            backfillCompleted: true,
            pollIntervalSeconds: pollInterval
        )
    }

    private func incremental(state: GitHubNotificationSyncStateRecord?) async throws {
        var collected: [GitHubNotificationThreadDTO] = []
        var lastModified = state?.lastModified
        var pollInterval = state?.lastPollIntervalSeconds
        var page = 1
        var sawNotModified = false

        while collected.count < GitHubNotificationMapper.backfillLimit {
            let response = try await fetchPage(
                page: page,
                since: state?.watermarkUpdatedAt,
                ifModifiedSince: page == 1 ? state?.lastModified : nil
            )
            if response.notModified {
                sawNotModified = true
                lastModified = response.lastModified ?? lastModified
                pollInterval = response.pollIntervalSeconds ?? pollInterval
                break
            }
            lastModified = response.lastModified ?? lastModified
            pollInterval = response.pollIntervalSeconds ?? pollInterval
            if response.threads.isEmpty { break }
            collected.append(contentsOf: response.threads)
            if response.nextPage == nil { break }
            page = response.nextPage ?? (page + 1)
        }

        if !sawNotModified, !collected.isEmpty {
            let fetchedAt = ISO8601DateFormatter.shared.string(from: clock())
            let records = collected.map {
                GitHubNotificationMapper.record(from: $0, fetchedAt: fetchedAt, firstSeenAt: fetchedAt)
            }
            try await threadRepository.upsertMany(records)
            try await dispatchNewSystemNotifications()
        }

        let watermark = try await threadRepository.maxUpdatedAt() ?? state?.watermarkUpdatedAt
        try await syncStateRepository.updateAfterFetch(
            lastModified: lastModified,
            watermarkUpdatedAt: watermark,
            lastFetchedAt: clock(),
            backfillCompleted: true,
            pollIntervalSeconds: pollInterval
        )
    }

    private func fetchPage(
        page: Int,
        since: String?,
        ifModifiedSince: String?
    ) async throws -> GitHubNotificationsListResponse {
        do {
            return try await apiClient.listNotifications(
                all: true,
                since: since,
                page: page,
                perPage: GitHubNotificationMapper.pageSize,
                ifModifiedSince: ifModifiedSince
            )
        } catch let NetworkError.clientError(statusCode, _) where statusCode == 403 {
            throw GitHubNotificationInboxError.missingScope
        }
    }

    private func dispatchNewSystemNotifications() async throws {
        let unnotified = try await threadRepository.fetchUnnotified()
        let now = ISO8601DateFormatter.shared.string(from: clock())
        let highSignal = unnotified.filter { record in
            record.unread
                && GitHubNotificationMapper.systemNotificationReasons.contains(record.reason)
        }
        if !highSignal.isEmpty {
            await notificationService.dispatchGitHubInbox(highSignal)
        }
        try await threadRepository.markNotified(ids: unnotified.map(\.id), notifiedAt: now)
    }

    private func retryFailedMarkRead() async throws {
        let failed = try await threadRepository.fetchFailedMarkRead()
        for record in failed {
            do {
                try await apiClient.markNotificationThreadRead(id: record.id)
                try await threadRepository.updateLocalUnread(
                    id: record.id,
                    unread: false,
                    markReadState: .synced
                )
            } catch {
                AppLog.network.info("Retry mark-read failed id=\(record.id, privacy: .public)")
            }
        }
    }

    private func patchRead(id: String) async {
        do {
            try await apiClient.markNotificationThreadRead(id: id)
            try await threadRepository.updateLocalUnread(
                id: id,
                unread: false,
                markReadState: .synced
            )
            dwellTasks[id] = nil
            postDidChange()
        } catch {
            try? await threadRepository.updateLocalUnread(
                id: id,
                unread: false,
                markReadState: .failed
            )
            AppLog.network.error("PATCH notification thread failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            postDidChange()
        }
    }

    private func restoreUnreadIfPending(id: String) async {
        guard let record = try? await threadRepository.fetch(id: id),
              record.markReadStateValue == .pending
        else { return }
        try? await threadRepository.updateLocalUnread(
            id: id,
            unread: true,
            markReadState: .idle
        )
        dwellTasks[id] = nil
        postDidChange()
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: .githubNotificationInboxDidChange, object: nil)
    }
}
