//
//  GitHubNotificationInboxView.swift
//  Starcat
//
//  活动页「通知」中栏：Mail 密度时间线（HH:mm + 轴线 + 事件句 + 主体类型 chip）。
//  「全部」把 GitHub 通知和当前用户 Star / Unstar / Fork 账本按时间混排，SQL UNION 游标翻页。
//  筛选复用全局浮层，以胶囊多选和紧凑单选组合查询；账本行点开走仓库详情。
//

import AppKit
import SwiftUI

struct GitHubNotificationInboxView: View {
    private enum ContentPhase: Equatable {
        case readingLocalPage
        case skeleton
        case ready
    }

    @Namespace private var selectionSpace

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    @Binding var selectedItem: ActivityItem?

    @State private var rows: [GitHubInboxTimelineRow] = []
    @State private var cursor: GitHubInboxTimelineCursor?
    @State private var hasMore = false
    @State private var isLoadingPage = false
    /// 首次读取期间先保留中栏底色，等现有首页查询确认缓存是否可展示，避免命中时闪出骨架。
    @State private var hasReadLocalFirstPage = false
    /// 首轮同步后的首页读取完成前，空的本地首页不足以判定权限空态，组织 Issue 仍可能补入数据。
    @State private var hasFinishedInitialLoad = false
    @State private var pagingGeneration = 0
    @State private var filter: GitHubNotificationFilter = .all
    @State private var lastFetchedAt: Date?
    @State private var selectedThreadId: String?
    @State private var isShowingHistoryResyncConfirmation = false
    @State private var isQuickSearchExpanded = false
    @State private var quickSearchDraft = ""
    @State private var quickSearchQuery = ""

    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

    private var contentPhase: ContentPhase {
        guard hasReadLocalFirstPage else { return .readingLocalPage }
        if rows.isEmpty && (!hasFinishedInitialLoad || isLoadingPage || inbox.isSyncing) {
            return .skeleton
        }
        return .ready
    }

    /// 首次页面仍在加载时提交搜索，待行数或游标状态变化后需要自动重试补页。
    private var quickSearchLoadIdentity: String {
        "\(quickSearchQuery)|\(rows.count)|\(hasMore)"
    }

    var body: some View {
        let phase = contentPhase
        VStack(spacing: 0) {
            toolbar
            Divider()
            MiddleListPresentation(
                showsSkeleton: phase == .skeleton
            ) {
                ListLoadingSkeleton(rowHeight: 76, showsSectionHeader: true)
                    .padding(.horizontal, 12)
            } content: {
                content(for: phase)
            }
        }
        .task {
            inbox.listFilter = filter
            await inbox.clearDemoThreads()
            if let user = authSession.state.user {
                await inbox.backfillUserRepoActivity(userID: user.id, login: user.login)
            }
            await reloadFirstPage()
            consumePendingOpenIfNeeded()
            await inbox.sync()
            await reloadFirstPage()
            hasFinishedInitialLoad = true
            consumePendingOpenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
            Task { await reloadFirstPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userRepoActivityDidChange)) { _ in
            Task { await reloadFirstPage() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatOpenGitHubNotification)) { _ in
            consumePendingOpenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoLibraryStateDidChange)) { note in
            // 入库 / 移出只改 `repo_notes.library_state`。重拉首页会丢掉已翻页，
            // 选中项不在前 40 条时 `reloadFirstPage` 会把 selectedItem 清成 nil，右栏变空白。
            guard let repoId = note.userInfo?["repoId"] as? Int64,
                  let raw = note.userInfo?["libraryState"] as? String else { return }
            if filter.libraryState != .all {
                // 入库条件激活后，变化会改变成员资格；保留已加载的页容量，避免选中项无故丢失。
                let loadedLimit = max(rows.count, GitHubNotificationMapper.timelinePageSize)
                Task { await reloadFirstPage(limit: loadedLimit) }
                return
            }
            rows = GitHubNotificationTimelineLibraryState.apply(
                rows: rows,
                repoId: repoId,
                state: LibraryState.parse(raw)
            )
        }
        .task(id: quickSearchLoadIdentity) {
            await loadUntilSearchMatchIfNeeded()
        }
        // dwell 活在 InboxService 上。中栏 SwiftUI 重建 / 切走时不要 cancelAllDwells，
        // 否则 pending 会被恢复成未读，点开看过的条目会反复亮蓝点。
        .starcatRefreshCommand(
            pane: .list,
            identity: "activity-notification-\(inbox.isSyncing)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: !inbox.isSyncing
        ) {
            Task {
                await inbox.sync(forceOrganizationIssues: true)
                await reloadFirstPage()
            }
        }
        .confirmationDialog(
            "activity.notification.historyResync.confirmation.title",
            isPresented: $isShowingHistoryResyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("activity.notification.historyResync.confirm") {
                Task {
                    await inbox.resyncHistory()
                    await reloadFirstPage()
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("activity.notification.historyResync.confirmation.message")
        }
    }

    private var toolbarSyncDescription: String? {
        lastFetchedAt.map {
            String(format: String.l10n("activity.notification.lastSynced"), RelativeTimeText.pastEvent($0, locale: locale))
        }
    }

    /// 复用全局筛选入口 + 同步行，和星标中栏 `manageFilterBar` 同高。
    /// 总数 / 未读走系统 `navigationSubtitle`（面包屑下一行），不要再叠 `通知 42` 标题。
    @ViewBuilder
    private var toolbar: some View {
        QuickSearchToolbarContent(
            isExpanded: $isQuickSearchExpanded,
            draft: $quickSearchDraft,
            committedQuery: quickSearchQuery,
            placeholder: "list.quickSearch.activityPlaceholder",
            onSubmit: { query in
                let normalizedQuery = QuickSearchTextMatcher.normalized(query)
                quickSearchQuery = normalizedQuery
                quickSearchDraft = normalizedQuery
            },
            onClear: { quickSearchQuery = "" }
        ) {
            GitHubNotificationFilterMenu(selection: $filter, locale: locale)
                .onChange(of: filter) { _, newValue in
                    resetQuickSearch()
                    inbox.listFilter = newValue
                    // onChange 到 Task 开始之间也可能返回旧请求，立即使其过期。
                    pagingGeneration += 1
                    rows = []
                    cursor = nil
                    hasMore = false
                    isLoadingPage = true
                    Task { await reloadFirstPage() }
                }

            Spacer(minLength: 8)
                .layoutPriority(AdaptiveToolbarStatusText.spacerPriority)

            if let text = toolbarSyncDescription {
                AdaptiveToolbarStatusText(text: text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // InboxService 是 @Observable：isSyncing 闪过 true 后，按钮 minVisibleDuration 会转满一圈。
            SyncIconButton(
                isRefreshing: inbox.isSyncing,
                disabled: inbox.isSyncing,
                tooltip: AdaptiveToolbarStatusText.refreshTooltip(action: String.l10n("activity.refresh"), status: toolbarSyncDescription)
            ) {
            Task {
                await inbox.sync(forceOrganizationIssues: true)
                await reloadFirstPage()
            }
            }

            Menu {
                Button {
                    openOAuthAppSettings()
                } label: {
                    Label(
                        "activity.notification.organizationAccess.action",
                        systemImage: "building.2"
                    )
                }

                Button {
                    isShowingHistoryResyncConfirmation = true
                } label: {
                    Label(
                        "activity.notification.historyResync.action",
                        systemImage: "clock.arrow.circlepath"
                    )
                }

                Divider()

                Button {
                    if let url = URL(string: "https://github.com/notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(verbatim: GitHubNotificationMapper.copy(locale, zh: "在 GitHub 打开通知收件箱", en: "Open GitHub Notifications"))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .help(GitHubNotificationMapper.copy(locale, zh: "在 GitHub 打开通知收件箱", en: "Open GitHub Notifications"))
        }
        .manageListFilterBarChrome()
    }

    private func openOAuthAppSettings() {
        // GitHub 的授权详情页会列出每个组织的 Grant / Request 状态；比跳到某个固定组织
        // 更适合多组织账号，也不会把“我的项目”GitHub App 授权误当成通知 OAuth 授权。
        let path = "https://github.com/settings/connections/applications/\(AppConstants.githubOAuthClientID)"
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func content(for phase: ContentPhase) -> some View {
        // 同一次列表更新只计算一次搜索快照。懒加载行不能为分页数量再次扫描整张时间线。
        let visibleRows = visibleRows
        if phase == .readingLocalPage {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if rows.isEmpty {
            if inbox.missingScope {
                missingScopeEmpty
            } else if filter.isActive {
                filterEmptyState
            } else {
                emptyState
            }
        } else if visibleRows.isEmpty {
            searchEmptyState
        } else {
            timeline(visibleRows)
        }
    }

    /// 通知服务按游标分页；先过滤已加载行，并在当前页无命中时继续补页，直到命中或耗尽。
    private var visibleRows: [GitHubInboxTimelineRow] {
        QuickSearchTextMatcher.filter(rows, query: quickSearchQuery) { row in
            let display = timelineDisplay(for: row)
            return [
                display.actorLogin,
                display.headline,
                display.fullName,
                display.snippet,
                display.subjectType,
                display.language
            ]
        }
    }

    private func groupedRows(_ visibleRows: [GitHubInboxTimelineRow]) -> [(GitHubNotificationDayGroup, [GitHubInboxTimelineRow])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [GitHubNotificationDayGroup: [GitHubInboxTimelineRow]] = [:]
        for row in visibleRows {
            let date = GitHubNotificationMapper.parseDate(row.occurredAt) ?? now
            let group = GitHubNotificationMapper.dayGroup(for: date, now: now, calendar: calendar)
            buckets[group, default: []].append(row)
        }
        return GitHubNotificationDayGroup.allCases.compactMap { group in
            guard let grouped = buckets[group], !grouped.isEmpty else { return nil }
            return (group, grouped)
        }
    }

    /// 不用 `List` + `.inset`：macOS 会把每一行画成带圆角和间隙的浮卡，
    /// 和方案里的 Mail 密度时间线相反。ScrollView 才能铺满选中、接上左侧轴线。
    private func timeline(_ visibleRows: [GitHubInboxTimelineRow]) -> some View {
        let entries = timelineEntries(for: visibleRows)
        let visibleRowCount = visibleRows.count
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { _, entry in
                    switch entry {
                    case .header(let group, let isFirst):
                        GitHubNotificationTimelineHeader(
                            titleKey: group.titleKey,
                            isFirst: isFirst
                        )
                    case .row(let row, let rowIndex, let isFirst, let isLast):
                        GitHubNotificationTimelineRow(
                            display: timelineDisplay(for: row),
                            isSelected: selectedThreadId == row.id,
                            rowIndex: rowIndex,
                            selectionNamespace: selectionSpace,
                            isFirstInTimeline: isFirst,
                            isLastInTimeline: isLast,
                            onSelect: {
                                Task { await select(row) }
                            }
                        )
                        .automaticListPagination(
                            appearingIndex: rowIndex,
                            visibleItemCount: visibleRowCount,
                            loadedItemCount: visibleRowCount,
                            hasMore: hasMore,
                            isLoading: isLoadingPage,
                            identity: "notification-\(filter.identity)-\(pagingGeneration)"
                        ) {
                            await loadNextPageIfNeeded()
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 整条时间线（含分组标题）共用一根轴线，避免「一组只有一条」时上下线段都被裁掉。
    private func timelineEntries(for visibleRows: [GitHubInboxTimelineRow]) -> [GitHubNotificationTimelineEntry] {
        let groups = groupedRows(visibleRows)
        var entries: [GitHubNotificationTimelineEntry] = []
        var timelineRowIndex = 0
        for (groupIndex, (group, grouped)) in groups.enumerated() {
            entries.append(.header(group, isFirst: groupIndex == 0))
            for (groupRowIndex, row) in grouped.enumerated() {
                let isLast = groupIndex == groups.count - 1 && groupRowIndex == grouped.count - 1
                entries.append(
                    .row(
                        row,
                        rowIndex: timelineRowIndex,
                        isFirst: false,
                        isLast: isLast
                    )
                )
                timelineRowIndex += 1
            }
        }
        return entries
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("activity.notification.empty.title")
                .font(.headline)
            Text("activity.notification.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var searchEmptyState: some View {
        ContentUnavailableView {
            Label("list.quickSearch.empty", systemImage: "magnifyingglass")
        }
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("activity.notification.filter.empty", systemImage: "line.3.horizontal.decrease.circle")
        } actions: {
            Button("list.filter.reset") { filter = .all }
                .focusEffectDisabled()
        }
    }

    private var missingScopeEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("activity.notification.missingScope.title")
                .font(.headline)
            Text("activity.notification.missingScope.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("activity.notification.missingScope.action") {
                Task { await authSession.signOut() }
            }
            .buttonStyle(.bordered)
            .focusEffectDisabled()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func reloadFirstPage(limit: Int? = nil) async {
        // 首页重载代表列表上下文已变化。递增 generation，让仍在等待的旧分页结果自动失效，
        // 避免切换筛选或同步刷新时把上一份列表的下一页追加到新列表。
        pagingGeneration += 1
        let requestedGeneration = pagingGeneration
        let requestedFilter = filter
        // 同条件同步保留已加载窗口。显式筛选会先清空 rows，因此仍从一页开始。
        let requestedLimit = limit ?? max(rows.count, GitHubNotificationMapper.timelinePageSize)
        isLoadingPage = true
        defer {
            if requestedGeneration == pagingGeneration {
                isLoadingPage = false
            }
        }
        let page = await inbox.fetchTimelinePage(cursor: nil, filter: requestedFilter, limit: requestedLimit)
        let fetchedAt = await inbox.lastFetchedAt()
        guard !Task.isCancelled, requestedGeneration == pagingGeneration, requestedFilter == filter else { return }
        rows = page.rows
        hasMore = page.hasMore
        cursor = page.rows.last?.cursor
        lastFetchedAt = fetchedAt
        hasReadLocalFirstPage = true
        Task { await inbox.prefetchMissingIssueStates(from: page.rows) }
        // 状态筛选必须先出本地结果。补缺放到后台，且同一会话只启动一轮。
        if requestedFilter.issueState.issueStateFilter != nil {
            Task { await inbox.startMissingIssueStateBackfillIfNeeded() }
        }
        if inbox.pendingOpenThreadId != nil {
            consumePendingOpenIfNeeded()
            return
        }
        if let selectedThreadId,
           let row = rows.first(where: { $0.id == selectedThreadId }) {
            let item = await makeItem(from: row)
            guard !Task.isCancelled, requestedGeneration == pagingGeneration,
                  self.selectedThreadId == selectedThreadId else { return }
            selectedItem = item
        } else if selectedThreadId != nil, !rows.contains(where: { $0.id == selectedThreadId }) {
            selectedThreadId = nil
            selectedItem = nil
        }
    }

    /// 接近底部时预取下一页。重复 onAppear 由 `isLoadingPage` 挡住。
    private func loadNextPageIfNeeded() async {
        guard hasMore, !isLoadingPage, let cursor else { return }
        let requestedGeneration = pagingGeneration
        let requestedFilter = filter
        isLoadingPage = true
        defer {
            if requestedGeneration == pagingGeneration {
                isLoadingPage = false
            }
        }
        let page = await inbox.fetchTimelinePage(cursor: cursor, filter: requestedFilter)
        guard GitHubNotificationTimelinePaging.isCurrentPageRequest(
            requestedGeneration: requestedGeneration,
            currentGeneration: pagingGeneration,
            requestedFilter: requestedFilter,
            currentFilter: filter,
            requestedCursor: cursor,
            currentCursor: self.cursor
        ) else { return }
        let existing = Set(rows.map(\.id))
        let appended = page.rows.filter { !existing.contains($0.id) }
        rows.append(contentsOf: appended)
        hasMore = page.hasMore
        Task { await inbox.prefetchMissingIssueStates(from: appended) }
        if let last = page.rows.last {
            self.cursor = last.cursor
        }
    }

    /// 搜索词在当前游标页无命中时自动补页，否则列表没有可见行触发滚动预取。
    private func loadUntilSearchMatchIfNeeded() async {
        guard !quickSearchQuery.isEmpty else { return }
        while visibleRows.isEmpty, hasMore, !Task.isCancelled {
            let previousCount = rows.count
            await loadNextPageIfNeeded()
            // 若另一个首页/分页请求仍在执行，本轮没有推进游标；直接退出，避免空转占用主线程。
            guard rows.count > previousCount else { return }
        }
    }

    private func resetQuickSearch() {
        isQuickSearchExpanded = false
        quickSearchDraft = ""
        quickSearchQuery = ""
    }

    private func consumePendingOpenIfNeeded() {
        guard let threadId = inbox.pendingOpenThreadId else { return }
        inbox.pendingOpenThreadId = nil
        Task {
            if let row = rows.first(where: { $0.id == threadId }) {
                await select(row)
                return
            }
            if let record = try? await dependencies.githubNotificationThreadRepository.fetch(id: threadId) {
                await select(.notification(record, language: nil))
            }
        }
    }

    private func select(_ row: GitHubInboxTimelineRow) async {
        if let previous = selectedThreadId, previous != row.id {
            await inbox.cancelDwell(id: previous)
        }
        selectedThreadId = row.id
        selectedItem = await makeItem(from: row)
        if case .notification(let record, _) = row {
            await inbox.beginDwell(id: record.id)
            await inbox.hydrate(id: record.id)
            if let updated = try? await dependencies.githubNotificationThreadRepository.fetch(id: record.id) {
                selectedItem = await makeItem(from: .notification(updated, language: row.language))
            }
        }
    }

    private func makeItem(from row: GitHubInboxTimelineRow) async -> ActivityItem {
        switch row {
        case .notification(let record, _):
            return await makeNotificationItem(from: record)
        case .activity(let item):
            return await makeActivityItem(from: item)
        }
    }

    private func makeNotificationItem(from record: GitHubNotificationThreadRecord) async -> ActivityItem {
        let date = GitHubNotificationMapper.parseDate(record.updatedAt)
        var localRepo: Repo?
        if let repoId = record.repositoryId {
            localRepo = try? await dependencies.repoRepository.findById(repoId)
        }
        if localRepo == nil {
            let parts = record.repositoryFullName.split(separator: "/")
            if parts.count == 2 {
                localRepo = try? await dependencies.repoRepository.findByOwnerName(
                    owner: String(parts[0]),
                    name: String(parts[1])
                )
            }
        }
        return ActivityItem(
            id: "notification:\(record.id)",
            kind: .notification,
            category: .notification,
            title: record.subjectTitle,
            subtitle: GitHubNotificationMapper.subtitle(
                fullName: record.repositoryFullName,
                subjectType: record.subjectType,
                number: record.subjectNumber
            ),
            body: record.excerpt,
            createdAt: date,
            htmlURL: record.htmlUrl.flatMap(URL.init(string:)),
            repo: localRepo,
            release: nil,
            releases: [],
            isRead: !record.unread,
            notification: ActivityNotificationPayload(
                threadId: record.id,
                reason: record.reason,
                chip: GitHubNotificationMapper.subjectChip(for: record),
                subjectType: record.subjectType,
                subjectNumber: record.subjectNumber,
                repositoryFullName: record.repositoryFullName,
                actorLogin: GitHubNotificationMapper.eventActor(for: record) ?? record.actorLogin,
                authorLogin: GitHubNotificationMapper.openingPostAuthor(for: record),
                authorCreatedAt: GitHubNotificationMapper.parseDate(record.subjectCreatedAt),
                excerpt: record.excerpt,
                comments: GitHubNotificationMapper.decodeComments(record.commentsJson),
                people: GitHubNotificationMapper.relatedPeople(for: record),
                repositoryId: record.repositoryId,
                canMarkDone: record.remoteNotificationThreadID != nil,
                issueState: inbox.resolvedIssueState(
                    threadId: record.id,
                    persisted: record.issueState
                ),
                labels: GitHubNotificationMapper.decodeLabels(record.labelsJson)
            )
        )
    }

    private func makeActivityItem(from item: UserRepoActivityListItem) async -> ActivityItem {
        let date = GitHubNotificationMapper.parseDate(item.record.occurredAt)
        var localRepo = try? await dependencies.repoRepository.findById(item.record.repoId)
        if localRepo == nil {
            let parts = item.record.fullName.split(separator: "/")
            if parts.count == 2 {
                localRepo = try? await dependencies.repoRepository.findByOwnerName(
                    owner: String(parts[0]),
                    name: String(parts[1])
                )
            }
        }
        return ActivityItem(
            id: "user-repo-activity:\(item.record.id)",
            kind: .userRepoActivity,
            category: .notification,
            title: item.record.fullName,
            subtitle: GitHubNotificationMapper.userRepoActivityHeadline(
                kind: item.record.kind,
                locale: locale
            ),
            body: item.snippet,
            createdAt: date,
            htmlURL: URL(string: item.record.htmlUrl),
            repo: localRepo,
            release: nil,
            releases: [],
            isRead: true,
            userRepoActivity: ActivityUserRepoActivityPayload(kind: item.record.kind)
        )
    }

    private func timelineDisplay(for row: GitHubInboxTimelineRow) -> GitHubNotificationTimelineDisplay {
        switch row {
        case .notification(let record, let language):
            return GitHubNotificationTimelineDisplay(
                id: record.id,
                occurredAt: record.updatedAt,
                unread: record.unread,
                actorLogin: GitHubNotificationMapper.eventActor(for: record) ?? record.actorLogin ?? "",
                headline: GitHubNotificationMapper.eventHeadline(for: record, locale: locale),
                chip: GitHubNotificationMapper.subjectChip(for: record),
                fullName: record.repositoryFullName,
                snippet: GitHubNotificationMapper.listSnippet(record.excerpt),
                subjectType: record.subjectType,
                subjectNumber: record.subjectNumber,
                language: language,
                issueState: inbox.resolvedIssueState(
                    threadId: record.id,
                    persisted: record.issueState
                ),
                libraryState: nil
            )
        case .activity(let item):
            let login = authSession.state.user?.login
                ?? item.ownerLogin
                ?? ""
            return GitHubNotificationTimelineDisplay(
                id: item.record.id,
                occurredAt: item.record.occurredAt,
                unread: false,
                actorLogin: login,
                headline: GitHubNotificationMapper.userRepoActivityHeadline(
                    kind: item.record.kind,
                    locale: locale
                ),
                chip: GitHubNotificationMapper.userRepoActivityChip(kind: item.record.kind),
                fullName: item.record.fullName,
                snippet: item.snippet,
                subjectType: "",
                subjectNumber: nil,
                language: item.language,
                issueState: nil,
                libraryState: item.libraryState
            )
        }
    }
}

/// 时间线条目：分组标题与通知行共用一根轴线。
private enum GitHubNotificationTimelineEntry: Identifiable {
    case header(GitHubNotificationDayGroup, isFirst: Bool)
    case row(GitHubInboxTimelineRow, rowIndex: Int, isFirst: Bool, isLast: Bool)

    var id: String {
        switch self {
        case .header(let group, _):
            return "header-\(group.rawValue)"
        case .row(let row, _, _, _):
            return row.id
        }
    }
}

private struct GitHubNotificationTimelineDisplay: Equatable {
    let id: String
    let occurredAt: String
    let unread: Bool
    let actorLogin: String
    let headline: String
    let chip: GitHubNotificationChip
    let fullName: String
    let snippet: String?
    let subjectType: String
    let subjectNumber: Int?
    let language: String?
    let issueState: String?
    let libraryState: LibraryState?

    /// 选中条 / 轴点：有语言走 GitHub 语言色，否则通知分类蓝。
    var accentColor: Color {
        if let language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return ActivityCategory.notification.iconColor
    }
}

/// 时间线翻页触发点。抽出谓词是为了单测「快到底部」而不是「碰到最后一行」。
enum GitHubNotificationTimelinePaging {
    /// 与其它自动分页列表共享 10 行提前量；本地 SQLite keyset 分页足够轻量。
    static let prefetchRowCount = ListPaginationPolicy.prefetchDistance

    static func shouldPrefetchNextPage(
        rowIndex: Int,
        rowCount: Int,
        hasMore: Bool,
        isLoading: Bool
    ) -> Bool {
        !isLoading && ListPaginationPolicy.shouldPrefetch(
            appearingIndex: rowIndex,
            itemCount: rowCount,
            hasMore: hasMore
        )
    }

    /// `await` 返回时再次核对请求上下文。只靠 `isLoading` 不能阻止筛选切换或首页重载期间
    /// 已经发出的旧请求回写，因此 generation、完整筛选与 cursor 必须同时保持一致。
    static func isCurrentPageRequest(
        requestedGeneration: Int,
        currentGeneration: Int,
        requestedFilter: GitHubNotificationFilter,
        currentFilter: GitHubNotificationFilter,
        requestedCursor: GitHubInboxTimelineCursor,
        currentCursor: GitHubInboxTimelineCursor?
    ) -> Bool {
        requestedGeneration == currentGeneration
            && requestedFilter == currentFilter
            && requestedCursor == currentCursor
    }
}

/// 时间线听 `.repoLibraryStateDidChange` 时只改账本行徽章。
///
/// 为什么不重拉首页：徽章来自 hydrate 时的 `libraryState`，行 id / 排序 / 分页都没变。
/// `reloadFirstPage` 会把已加载页换成前 40 条，选中项不在首页就清空右栏。
enum GitHubNotificationTimelineLibraryState {
    static func apply(
        rows: [GitHubInboxTimelineRow],
        repoId: Int64,
        state: LibraryState
    ) -> [GitHubInboxTimelineRow] {
        rows.map { row in
            guard case .activity(let item) = row, item.record.repoId == repoId else {
                return row
            }
            guard item.libraryState != state else { return row }
            return .activity(
                UserRepoActivityListItem(
                    record: item.record,
                    snippet: item.snippet,
                    ownerLogin: item.ownerLogin,
                    language: item.language,
                    libraryState: state
                )
            )
        }
    }
}

private enum GitHubNotificationTimelineMetrics {
    /// `HH:mm` 下一行还要排 Open / Closed / Merged，40pt 会裁 `Closed`。
    static let stampWidth: CGFloat = 52
    static let railWidth: CGFloat = 12
    static let leadingPadding: CGFloat = 10
    static let stampSpacing: CGFloat = 8
    static let selectedInset: CGFloat = 6
    static let rowMinHeight: CGFloat = 56
    static let rowCornerRadius: CGFloat = 8

    static var railLeadingInset: CGFloat {
        leadingPadding + stampWidth + stampSpacing
    }
}

/// 与全局筛选共享浮层：事件和原因使用胶囊多选，互斥状态使用单选分段。
private struct GitHubNotificationFilterMenu: View {
    @Binding var selection: GitHubNotificationFilter
    let locale: Locale

    var body: some View {
        UnifiedFilterMenu(
            isAnyFilterActive: selection.isActive,
            // 默认筛选没有重置操作，不为隐藏的重置按钮预留底部空白。
            onReset: selection.isActive ? { selection = .all } : nil
        ) {
            chipSection(
                "activity.notification.filter.events",
                icon: "tray",
                options: GitHubNotificationFilter.eventOptions,
                selected: $selection.eventTypes
            )

            Divider()

            tabSection(
                "activity.notification.filter.read",
                icon: "envelope",
                options: GitHubNotificationFilter.readOptions,
                binding: $selection.readState
            )

            Divider()

            tabSection(
                "activity.notification.filter.state",
                icon: "checkmark.circle",
                options: GitHubNotificationFilter.stateOptions,
                binding: $selection.issueState
            )

            Divider()

            chipSection(
                "activity.notification.filter.reason",
                icon: "at",
                options: GitHubNotificationFilter.reasonOptions,
                selected: $selection.reasons
            )

            Divider()

            tabSection(
                "list.filter.library",
                icon: "heart.text.square",
                options: GitHubNotificationFilter.libraryOptions,
                binding: $selection.libraryState
            )
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey, icon: String) -> some View {
        Label(key, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    /// 与全局语言筛选复用同一胶囊；空集合由“全部”的实色选中态明确表达。
    private func chipSection(
        _ title: LocalizedStringKey,
        icon: String,
        options: [GitHubNotificationSegment],
        selected: Binding<Set<GitHubNotificationSegment>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title, icon: icon)
                .help(Text("activity.notification.filter.scope"))
            TagChipFlowLayout(spacing: 6, constrainsItemWidth: true) {
                RepoLanguageFilterChip(
                    title: String.l10n("general.all"),
                    isSelected: selected.wrappedValue.isEmpty,
                    action: { selected.wrappedValue = [] }
                ) {
                    Image(systemName: "tray")
                }
                ForEach(options) { option in
                    chip(option, selected: selected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(3)
        }
    }

    /// 标题独立成行、分段占满下一行，与全局筛选保持相同密度和长译文回退。
    private func tabSection(
        _ title: LocalizedStringKey,
        icon: String,
        options: [GitHubNotificationSegment],
        binding: Binding<GitHubNotificationSegment>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title, icon: icon)
                .help(Text("activity.notification.filter.scope"))
            RepoFilterTabs(
                label: title,
                options: options,
                selection: binding,
                title: { LocalizedStringKey($0.displayTitle(locale: locale)) },
                symbol: { $0.systemSymbol }
            )
        }
    }

    private func chip(_ option: GitHubNotificationSegment, selected: Binding<Set<GitHubNotificationSegment>>) -> some View {
        let color = chipColor(for: option)
        let isSelected = selected.wrappedValue.contains(option)
        return RepoLanguageFilterChip(
            title: option.displayTitle(locale: locale),
            isSelected: isSelected,
            action: {
                if selected.wrappedValue.contains(option) {
                    selected.wrappedValue.remove(option)
                } else {
                    selected.wrappedValue.insert(option)
                }
            },
            color: color
        ) {
            BusinessIcon(source: option.iconSource, pointSize: 14, weight: .medium)
                .foregroundStyle(isSelected ? TagChipSurface.selectedForeground(for: color) : color)
        }
    }

    /// 事件沿用时间线徽章的语义色；讨论、发行与原因补充独立颜色，“全部”仍用强调色。
    private func chipColor(for option: GitHubNotificationSegment) -> Color {
        switch option {
        case .issue:
            return Color(hex: "#bc4c00") ?? .orange
        case .pullRequest, .review:
            return Color(hex: "#8250df") ?? .purple
        case .discussion:
            return .blue
        case .release:
            return .green
        case .mention:
            return .orange
        case .star:
            return Color(hex: "#9a6700") ?? .yellow
        case .unstar:
            return Color(hex: "#cf222e") ?? .red
        case .fork:
            return Color(hex: "#1b7c83") ?? .teal
        default:
            return .accentColor
        }
    }
}

private struct GitHubNotificationTimelineHeader: View {
    let titleKey: String
    let isFirst: Bool

    var body: some View {
        HStack(alignment: .center, spacing: GitHubNotificationTimelineMetrics.stampSpacing) {
            Color.clear
                .frame(width: GitHubNotificationTimelineMetrics.stampWidth)
            Color.clear
                .frame(width: GitHubNotificationTimelineMetrics.railWidth)
            Text(LocalizedStringKey(titleKey))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, GitHubNotificationTimelineMetrics.leadingPadding)
        .padding(.trailing, 12)
        .padding(.top, isFirst ? 10 : 6)
        .padding(.bottom, 2)
        .frame(minHeight: 28)
        // 轴线用 overlay 铺满标题行，避免 VStack+infinity 把分组标题撑成整页高。
        .overlay(alignment: .leading) {
            GeometryReader { proxy in
                GitHubNotificationTimelineRail(
                    unread: false,
                    isFirst: isFirst,
                    isLast: false,
                    showsDot: false
                )
                .frame(
                    width: GitHubNotificationTimelineMetrics.railWidth,
                    height: proxy.size.height
                )
                .offset(x: GitHubNotificationTimelineMetrics.railLeadingInset)
            }
        }
    }
}

/// 时间线行：`HH:mm` + 可选 Open/Closed/Merged + 轴线 + 头像 + 事件句 + 仓库次行 + 可选摘录。
/// 选中跟 repo 卡片同一套语言色浅底 / 描边 / 左侧 3pt 竖条；不整行拉满，也不挪时间轴。
private struct GitHubNotificationTimelineRow: View {
    let display: GitHubNotificationTimelineDisplay
    let isSelected: Bool
    let rowIndex: Int
    let selectionNamespace: Namespace.ID
    let isFirstInTimeline: Bool
    let isLastInTimeline: Bool
    let onSelect: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: GitHubNotificationTimelineMetrics.stampSpacing) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: stamp)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let issueState = display.issueState {
                        GitHubNotificationIssueStateBadge(
                            state: issueState,
                            isPullRequest: display.subjectType == "PullRequest",
                            style: .stamp
                        )
                    } else if let libraryState = display.libraryState {
                        GitHubNotificationLibraryStateBadge(state: libraryState)
                    }
                }
                .frame(width: GitHubNotificationTimelineMetrics.stampWidth, alignment: .trailing)
                .padding(.top, 3)

                Color.clear
                    .frame(width: GitHubNotificationTimelineMetrics.railWidth)

                Group {
                    if usesRepositoryAvatar {
                        RemoteAvatar(
                            urlString: GitHubNotificationMapper.repositoryAvatarURL(
                                fromFullName: display.fullName
                            ),
                            size: 24,
                            fallbackSymbol: "shippingbox.fill",
                            showBorder: false
                        )
                    } else {
                        GitHubNotificationActorAvatar(
                            login: display.actorLogin,
                            size: 24
                        )
                    }
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: display.headline)
                            .font(.subheadline.weight(display.unread ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        GitHubNotificationReasonChip(chip: display.chip)
                    }

                    HStack(spacing: 6) {
                        if !usesRepositoryAvatar {
                            RemoteAvatar(
                                urlString: GitHubNotificationMapper.repositoryAvatarURL(
                                    fromFullName: display.fullName
                                ),
                                size: 14,
                                fallbackSymbol: "shippingbox.fill",
                                showBorder: false
                            )
                        }
                        Text(verbatim: caption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let snippet {
                        Text(verbatim: snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, GitHubNotificationTimelineMetrics.leadingPadding)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: GitHubNotificationTimelineMetrics.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    GitHubNotificationTimelineRail(
                        unread: display.unread,
                        isFirst: isFirstInTimeline,
                        isLast: isLastInTimeline,
                        showsDot: true,
                        accent: display.accentColor
                    )
                    .frame(
                        width: GitHubNotificationTimelineMetrics.railWidth,
                        height: proxy.size.height
                    )
                    .offset(x: GitHubNotificationTimelineMetrics.railLeadingInset)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background {
            Color.clear
                .listRowSurface(
                    index: rowIndex, isSelected: isSelected,
                    selectionNamespace: selectionNamespace,
                    accentColor: display.accentColor,
                    cornerRadius: GitHubNotificationTimelineMetrics.rowCornerRadius
                )
                .padding(.horizontal, GitHubNotificationTimelineMetrics.selectedInset)
                .padding(.vertical, 1)
        }
        .overlay(alignment: .leading) {
            // 颜色仍来自通知仓库；只绘制选中竖条，不挪动时间轴和头像。
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(display.accentColor)
                .frame(width: isSelected ? 3 : 0)
                .padding(.vertical, 8)
                .padding(.leading, GitHubNotificationTimelineMetrics.selectedInset)
        }
    }

    /// 自己的仓库操作以目标项目为视觉主体；同一条件也用于隐藏次行头像，避免重复。
    private var usesRepositoryAvatar: Bool {
        switch display.chip {
        case .star, .unstar, .fork:
            return true
        default:
            return false
        }
    }

    private var updatedAt: Date? {
        GitHubNotificationMapper.parseDate(display.occurredAt)
    }

    private var stamp: String {
        guard let date = updatedAt else { return "--:--" }
        return GitHubNotificationMapper.timelineStamp(date: date, locale: locale)
    }

    private var caption: String {
        let relative = updatedAt.map { RelativeTimeText.pastEvent($0, locale: locale) } ?? ""
        return GitHubNotificationMapper.timelineCaption(
            fullName: display.fullName,
            subjectType: display.subjectType,
            number: display.subjectNumber,
            relativeTime: relative
        )
    }

    /// 没 hydrate 就不要留空行，行高才稳。
    private var snippet: String? {
        guard let text = display.snippet, !text.isEmpty else { return nil }
        return text
    }
}

/// 组内上下接缝的 1pt 轴线。语言色点：实心 = 未读，空心 = 已读 / 账本。
private struct GitHubNotificationTimelineRail: View {
    let unread: Bool
    let isFirst: Bool
    let isLast: Bool
    var showsDot: Bool = true
    var accent: Color = Color.secondary

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(isFirst ? 0 : 0.35))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            if showsDot {
                if unread {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .strokeBorder(accent, lineWidth: 1.5)
                        .frame(width: 6, height: 6)
                }
            }
            Rectangle()
                .fill(Color.secondary.opacity(isLast ? 0 : 0.35))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: GitHubNotificationTimelineMetrics.railWidth)
    }
}

/// 时间线 / 顶栏的主体类型 chip：Issue 橙、PR 紫、其余安静灰。Mention 不在这里重复。
struct GitHubNotificationReasonChip: View {
    let chip: GitHubNotificationChip
    @Environment(\.locale) private var locale

    var body: some View {
        Text(verbatim: GitHubNotificationMapper.chipTitle(for: chip, locale: locale))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var tint: Color {
        switch chip {
        case .issue:
            return Color(hex: "#bc4c00") ?? .orange
        case .pullRequest:
            return Color(hex: "#8250df") ?? .purple
        case .security:
            return Color.red
        case .star:
            return Color(hex: "#9a6700") ?? .yellow
        case .unstar:
            return Color(hex: "#cf222e") ?? .red
        case .fork:
            return Color(hex: "#1b7c83") ?? .teal
        case .release, .discussion, .comment, .mention, .review, .assign:
            // Release / Discussion / 其它剩余 chip 用安静灰，不靠彩虹色抢扫描。
            return Color.secondary
        }
    }
}

/// Issue / PR 工作状态。时间线用无底文字挤进时间列；详情顶栏用和类型 chip 同形态的胶囊。
struct GitHubNotificationIssueStateBadge: View {
    enum Style {
        case stamp
        case chip
    }

    let state: String
    var isPullRequest: Bool = false
    var style: Style = .chip
    @Environment(\.locale) private var locale

    var body: some View {
        Text(verbatim: GitHubNotificationMapper.issueStateTitle(state: state, locale: locale))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, style == .chip ? 8 : 0)
            .padding(.vertical, style == .chip ? 3 : 0)
            .background {
                if style == .chip {
                    Capsule().fill(tint.opacity(0.14))
                }
            }
            .accessibilityLabel(Text(verbatim: GitHubNotificationMapper.issueStateTitle(state: state, locale: locale)))
    }

    /// Open 绿、Merged 紫、未合并关闭的 PR 红、Issue 关闭紫。对齐 GitHub 网页语义，不是装饰灰。
    private var tint: Color {
        switch GitHubNotificationMapper.normalizedIssueState(state) {
        case "open":
            return Color(hex: "#1a7f37") ?? .green
        case "merged":
            return Color(hex: "#8250df") ?? .purple
        case "closed":
            if isPullRequest {
                return Color(hex: "#cf222e") ?? .red
            }
            return Color(hex: "#8250df") ?? .purple
        default:
            return .secondary
        }
    }
}

/// Star / Unstar / Fork 时间列：已入库绿、未入库灰。文案短，避免撑破 52pt。
struct GitHubNotificationLibraryStateBadge: View {
    let state: LibraryState
    @Environment(\.locale) private var locale

    var body: some View {
        Text(verbatim: GitHubNotificationMapper.libraryStateStampTitle(state: state, locale: locale))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel(Text(verbatim: GitHubNotificationMapper.libraryStateFilterTitle(state: state, locale: locale)))
    }

    private var tint: Color {
        switch state {
        case .inLibrary:
            return Color(hex: "#1a7f37") ?? .green
        case .outsideLibrary:
            return .secondary
        }
    }
}
