//
//  GitHubNotificationInboxService.swift
//  Starcat
//
//  通知 inbox 同步：首次 all=true 翻页回填最多 300 条；之后 since + If-Modified-Since。
//  选中已读：蓝点先灭，400ms 内划走则恢复且不 PATCH；停满再异步 PATCH。
//  右栏「完成」：DELETE thread 标 Done，只动当前这一条，成功后删本地行。
//  Star / Unstar / Fork 在 `user_repo_activity` 账本，时间线两表 UNION 游标翻页。
//
//  关键约束：
//  - 回填历史不发系统通知，但会写 notified_at，避免增量把旧条目补弹一次。
//  - 禁止 mark-all。
//  - 403 视为缺 `notifications` scope，UI 引导重新授权。
//  - `@Observable`：Inbox 工具栏 `SyncIconButton(isRefreshing: inbox.isSyncing)` 必须能
//    收到 `isSyncing` 变化。普通 class 赋值 SwiftUI 看不见，点刷新会真拉网、时间文案
//    会更新，图标却不转圈。304 / 极快返回仍走 `isSyncing=true`，交给按钮的
//    `minVisibleDuration`（默认 1s）转满一圈。
//

import Foundation
import Observation

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
    case cannotClose
    case cannotDone
}

@MainActor
@Observable
final class GitHubNotificationInboxService {

    private let apiClient: any GitHubAPIClientProtocol
    private let projectAPIClient: (any GitHubAPIClientProtocol)?
    private let threadRepository: any GitHubNotificationThreadRepositoryProtocol
    private let syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol
    private let notificationService: AppNotificationService
    private let settings: AppSettings
    private let activityRepository: (any UserRepoActivityRepositoryProtocol)?
    private let organizationIssueSyncService: OrganizationIssueTimelineSyncService?
    private let userIDProvider: () -> Int64?
    private let isProjectAccessAvailable: () -> Bool
    private let clock: () -> Date
    private let dwellNanoseconds: UInt64

    /// Inbox 刷新按钮绑定这个旗标。必须可被 Observation 跟踪，否则 `SyncIconButton` 不转。
    private(set) var isSyncing = false
    private(set) var missingScope = false
    private(set) var lastErrorMessage: String?
    /// 系统通知点击时 inbox 视图可能还没挂上，先记在这里。
    var pendingOpenThreadId: String?
    /// 中栏当前分段。右栏上下一条要用同一份过滤结果。
    var listSegment: GitHubNotificationSegment = .all

    private var dwellTasks: [String: Task<Void, Never>] = [:]
    /// Issue / PR 的 `open` / `closed` / `merged`。内存是 UI 即时源，库里的 `issue_state` 是冷启动源。
    private var issueStates: [String: String] = [:]
    /// 同一 thread 并发刷新状态时共用一次 GET，避免选中 hydrate 和评论框各打一遍。
    private var issueStateRefreshTasks: [String: Task<Void, Never>] = [:]
    /// 正在 Done 的 id。取消 dwell 时不要把蓝点闪回来，这条马上要从表里删掉。
    private var completingIDs: Set<String> = []

    init(
        apiClient: any GitHubAPIClientProtocol,
        threadRepository: any GitHubNotificationThreadRepositoryProtocol,
        syncStateRepository: any GitHubNotificationSyncStateRepositoryProtocol,
        notificationService: AppNotificationService,
        settings: AppSettings,
        activityRepository: (any UserRepoActivityRepositoryProtocol)? = nil,
        projectAPIClient: (any GitHubAPIClientProtocol)? = nil,
        organizationIssueSyncService: OrganizationIssueTimelineSyncService? = nil,
        userIDProvider: @escaping () -> Int64? = { nil },
        isProjectAccessAvailable: @escaping () -> Bool = { false },
        clock: @escaping () -> Date = Date.init,
        dwellNanoseconds: UInt64 = GitHubNotificationMapper.dwellNanoseconds
    ) {
        self.apiClient = apiClient
        self.projectAPIClient = projectAPIClient
        self.threadRepository = threadRepository
        self.syncStateRepository = syncStateRepository
        self.notificationService = notificationService
        self.settings = settings
        self.activityRepository = activityRepository
        self.organizationIssueSyncService = organizationIssueSyncService
        self.userIDProvider = userIDProvider
        self.isProjectAccessAvailable = isProjectAccessAvailable
        self.clock = clock
        self.dwellNanoseconds = dwellNanoseconds
    }

    func fetchCached(limit: Int = GitHubNotificationMapper.backfillLimit) async -> [GitHubNotificationThreadRecord] {
        (try? await threadRepository.fetchAll(limit: limit)) ?? []
    }

    /// 「全部」两表混排；Unread / 主体类型 / Mention / Review 只含通知；Star / Unstar / Fork 只含账本。
    func fetchTimelinePage(
        cursor: GitHubInboxTimelineCursor?,
        limit: Int = GitHubNotificationMapper.timelinePageSize
    ) async -> (rows: [GitHubInboxTimelineRow], hasMore: Bool) {
        guard let activityRepository else {
            let threads = (try? await threadRepository.fetchAll(limit: limit + 1)) ?? []
            let hasMore = threads.count > limit
            let page = Array(threads.prefix(limit))
            return (page.map { .notification($0, language: nil) }, hasMore)
        }
        return (try? await activityRepository.fetchPage(
            segment: listSegment,
            cursor: cursor,
            limit: limit
        )) ?? ([], false)
    }

    func timelineTotalCount() async -> Int {
        let notifications = (try? await threadRepository.totalCount()) ?? 0
        guard listSegment == .all else { return notifications }
        let activities = (try? await activityRepository?.count()) ?? 0
        return notifications + activities
    }

    /// 把本地仍 star / 仍是自己的 fork 灌进账本。可重复跑。
    func backfillUserRepoActivity(userID: Int64, login: String) async {
        try? await activityRepository?.backfillFromLocalCaches(
            actor: UserRepoActivityActor(userID: userID, userName: login)
        )
    }

    /// 清掉本机残留的 `starcat-demo-` 演示 thread。不再生成新的。
    func clearDemoThreads() async {
        try? await threadRepository.deleteIDs(withPrefix: GitHubNotificationMapper.demoThreadIDPrefix)
        postDidChange()
    }

    func lastFetchedAt() async -> Date? {
        guard let raw = try? await syncStateRepository.current()?.lastFetchedAt else { return nil }
        return ISO8601DateFormatter.githubDate(from: raw)
    }

    /// 打开分类 / 手动刷新 / 后台 poller 共用。
    ///
    /// 无论回填、增量还是 304，都先拉高 `isSyncing`。已在同步中的二次点击直接返回，
    /// 按钮此时已经在转，不需要再写一套空转动画。
    func sync(forceOrganizationIssues: Bool = false) async {
        await sync(
            forceBackfill: false,
            forceOrganizationIssues: forceOrganizationIssues
        )
    }

    /// 组织 OAuth 授权变化后重新抓取最近历史。
    ///
    /// 只重置同步游标，保留 thread 表；相同 thread 仍走既有 upsert，继续保护本地已读状态。
    func resyncHistory() async {
        await sync(forceBackfill: true, forceOrganizationIssues: true)
    }

    private func sync(forceBackfill: Bool, forceOrganizationIssues: Bool) async {
        guard !isSyncing else { return }
        isSyncing = true
        lastErrorMessage = nil
        defer { isSyncing = false }

        do {
            if forceBackfill {
                try await syncStateRepository.resetForBackfill()
            }
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

        // Notifications 与组织 Issue 是两个独立远端源。前者缺 scope 或暂时失败时，
        // 后者仍可刷新；同步器内部按 scope 保存错误并保留旧缓存。
        if let userID = userIDProvider() {
            await organizationIssueSyncService?.sync(
                userID: userID,
                force: forceBackfill || forceOrganizationIssues
            )
            postDidChange()
        }
    }

    func hydrate(id: String) async {
        guard !GitHubNotificationMapper.isDemoThread(id) else { return }
        guard let record = try? await threadRepository.fetch(id: id) else { return }
        guard record.hydratedAt == nil || record.subjectCreatedAt == nil else { return }
        guard let path = GitHubNotificationMapper.path(fromAbsoluteAPIURL: record.subjectApiUrl),
              !path.isEmpty
        else { return }
        do {
            let client = apiClient(for: record)
            let hydration = try await client.hydrateNotificationSubject(path: path)
            var comments: [GitHubNotificationComment] = []
            if let commentsPath = GitHubNotificationMapper.issueCommentsPath(
                subjectType: record.subjectType,
                subjectApiURL: record.subjectApiUrl
            ) {
                comments = (try? await client.listNotificationIssueComments(path: commentsPath)) ?? []
            }
            let now = ISO8601DateFormatter.shared.string(from: clock())
            await rememberIssueState(id: id, state: hydration.state)
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
        guard !GitHubNotificationMapper.isDemoThread(threadId) else {
            throw GitHubNotificationInboxError.cannotComment
        }
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
        let created = try await apiClient(for: record).createNotificationIssueComment(path: path, body: trimmed)
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

    func cachedIssueState(threadId: String) -> String? {
        GitHubNotificationMapper.normalizedIssueState(issueStates[threadId])
    }

    /// 列表即时源：内存优先，没有再用库里上次 hydrate / 关闭写下的值。
    func resolvedIssueState(threadId: String, persisted: String?) -> String? {
        cachedIssueState(threadId: threadId)
            ?? GitHubNotificationMapper.normalizedIssueState(persisted)
    }

    /// 当前页 Issue / PR 缺状态时再 GET subject。已有库值只灌内存，避免每行都打网。
    /// 不 `postDidChange`：状态变化靠 `@Observable` 的 `issueStates` 刷新行，避免整表重载。
    func prefetchMissingIssueStates(from rows: [GitHubInboxTimelineRow]) async {
        var missing: [String] = []
        for row in rows {
            guard case .notification(let record, _) = row else { continue }
            guard GitHubNotificationMapper.canReply(
                subjectType: record.subjectType,
                number: record.subjectNumber
            ) else { continue }
            if resolvedIssueState(threadId: record.id, persisted: record.issueState) != nil {
                if issueStates[record.id] == nil,
                   let persisted = GitHubNotificationMapper.normalizedIssueState(record.issueState) {
                    issueStates[record.id] = persisted
                }
                continue
            }
            missing.append(record.id)
        }
        // 一页最多补 12 条，避免打开 inbox 就打满 40 次 GET。
        for id in missing.prefix(12) {
            await refreshIssueState(threadId: id)
        }
    }

    /// 切到打开 / 关闭 / 已合并前补一批缺失状态，否则筛选会把还没 hydrate 的行全挡掉。
    func backfillMissingIssueStates(limit: Int = 20) async {
        let ids = (try? await threadRepository.fetchIDsMissingIssueState(limit: limit)) ?? []
        for id in ids {
            await refreshIssueState(threadId: id)
        }
    }

    /// 打开详情时再 GET 一次 subject，确认当前是 open 才允许显示「关闭」。
    /// hydrate 会因 `hydratedAt` 跳过，不能靠那次缓存当真相。
    func refreshIssueState(threadId: String) async {
        guard !GitHubNotificationMapper.isDemoThread(threadId) else { return }
        if let inflight = issueStateRefreshTasks[threadId] {
            await inflight.value
            return
        }
        let task = Task { await self.fetchIssueState(threadId: threadId) }
        issueStateRefreshTasks[threadId] = task
        await task.value
        issueStateRefreshTasks[threadId] = nil
    }

    private func fetchIssueState(threadId: String) async {
        guard let record = try? await threadRepository.fetch(id: threadId),
              GitHubNotificationMapper.canReply(
                subjectType: record.subjectType,
                number: record.subjectNumber
              ),
              let path = GitHubNotificationMapper.path(fromAbsoluteAPIURL: record.subjectApiUrl),
              !path.isEmpty
        else { return }
        do {
            let hydration = try await apiClient(for: record).hydrateNotificationSubject(path: path)
            await rememberIssueState(id: threadId, state: hydration.state)
        } catch {
            AppLog.network.info(
                "Notification issue state skipped id=\(threadId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func rememberIssueState(id: String, state: String?) async {
        guard let normalized = GitHubNotificationMapper.normalizedIssueState(state) else { return }
        let changed = issueStates[id] != normalized
        issueStates[id] = normalized
        guard changed else { return }
        try? await threadRepository.updatePersistedIssueState(id: id, state: normalized)
    }

    /// `PATCH` Issue / PR 的 `state`。演示 thread 和不能回复的类型直接拒绝。
    /// 不能 PATCH 成 `merged`：合并只能在 GitHub 上发生，这里只关 / 重开。
    func updateIssueState(threadId: String, state: String) async throws {
        let normalized = state.lowercased()
        guard normalized == "open" || normalized == "closed" else {
            throw GitHubNotificationInboxError.cannotClose
        }
        guard !GitHubNotificationMapper.isDemoThread(threadId) else {
            throw GitHubNotificationInboxError.cannotClose
        }
        guard let record = try await threadRepository.fetch(id: threadId),
              let path = GitHubNotificationMapper.issueResourcePath(
                subjectType: record.subjectType,
                subjectApiURL: record.subjectApiUrl
              )
        else {
            throw GitHubNotificationInboxError.cannotClose
        }
        do {
            try await apiClient(for: record).updateNotificationIssueState(path: path, state: normalized)
            issueStates[threadId] = normalized
            try await threadRepository.updatePersistedIssueState(id: threadId, state: normalized)
            postDidChange()
        } catch let network as NetworkError {
            switch network {
            case .notFound:
                throw GitHubNotificationInboxError.cannotClose
            case .clientError(let code, _) where code == 403 || code == 404:
                throw GitHubNotificationInboxError.cannotClose
            default:
                throw network
            }
        }
    }

    func closeIssue(threadId: String) async throws {
        try await updateIssueState(threadId: threadId, state: "closed")
    }

    func reopenIssue(threadId: String) async throws {
        try await updateIssueState(threadId: threadId, state: "open")
    }

    /// 只 Done 这一条：GitHub `DELETE /notifications/threads/{id}`，成功后删本地行。
    /// 不是关 Issue，也不是 mark-all。404 当已经 Done，仍清本地。
    func markThreadDone(id: String) async throws {
        guard !id.isEmpty else {
            throw GitHubNotificationInboxError.cannotDone
        }
        completingIDs.insert(id)
        dwellTasks[id]?.cancel()
        dwellTasks[id] = nil
        defer { completingIDs.remove(id) }

        if GitHubNotificationMapper.isDemoThread(id) {
            try await threadRepository.delete(id: id)
            issueStates[id] = nil
            postDidChange()
            return
        }

        guard let record = try await threadRepository.fetch(id: id),
              let remoteThreadID = record.remoteNotificationThreadID
        else {
            throw GitHubNotificationInboxError.cannotDone
        }

        do {
            try await apiClient.markNotificationThreadDone(id: remoteThreadID)
        } catch NetworkError.notFound {
            // GitHub 已经没有这条 inbox 项，本地照样删。
        } catch let NetworkError.clientError(code, _) where code == 404 {
            // 同上。
        } catch {
            await restoreUnreadIfPending(id: id)
            throw error
        }

        try await threadRepository.removeNotificationThread(id: id)
        issueStates[id] = nil
        postDidChange()
    }

    /// 选中一行：蓝点先灭，再开始 400ms dwell。
    /// 已经 PATCH 成功 / 失败待重试的已读行不要再打成 pending，否则一取消 dwell 蓝点会闪回来。
    func beginDwell(id: String) async {
        guard let record = try? await threadRepository.fetch(id: id),
              record.remoteNotificationThreadID != nil
        else { return }
        if !record.unread {
            switch record.markReadStateValue {
            case .synced, .failed:
                return
            case .pending where dwellTasks[id] != nil:
                return
            case .idle, .pending:
                break
            }
        }

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
        for record in failed where !GitHubNotificationMapper.isDemoThread(record.id) {
            guard let remoteThreadID = record.remoteNotificationThreadID else { continue }
            do {
                try await apiClient.markNotificationThreadRead(id: remoteThreadID)
                try await threadRepository.updateLocalUnread(
                    id: record.id,
                    unread: false,
                    markReadState: .synced,
                    githubUnread: false
                )
            } catch {
                AppLog.network.info("Retry mark-read failed id=\(record.id, privacy: .public)")
            }
        }
    }

    private func patchRead(id: String) async {
        if GitHubNotificationMapper.isDemoThread(id) {
            try? await threadRepository.updateLocalUnread(
                id: id,
                unread: false,
                markReadState: .synced,
                githubUnread: false
            )
            dwellTasks[id] = nil
            postDidChange()
            return
        }
        guard let record = try? await threadRepository.fetch(id: id),
              let remoteThreadID = record.remoteNotificationThreadID
        else { return }
        do {
            try await apiClient.markNotificationThreadRead(id: remoteThreadID)
            try await threadRepository.updateLocalUnread(
                id: id,
                unread: false,
                markReadState: .synced,
                githubUnread: false
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
        guard !completingIDs.contains(id) else { return }
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

    /// 组织私仓必须继续使用把它拉下来的 Project Access 凭据；凭据失效时不静默改用
    /// public OAuth 伪装成功，公开组织 Issue 则保持主 OAuth 路径。
    private func apiClient(for record: GitHubNotificationThreadRecord) -> any GitHubAPIClientProtocol {
        if record.credentialSource == GitHubTimelineCredentialSource.projectAccess.rawValue,
           isProjectAccessAvailable(),
           let projectAPIClient {
            return projectAPIClient
        }
        return apiClient
    }
}
