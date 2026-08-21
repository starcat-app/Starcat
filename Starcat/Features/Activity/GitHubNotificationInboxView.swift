//
//  GitHubNotificationInboxView.swift
//  Starcat
//
//  活动页「通知」中栏：Mail 密度时间线（HH:mm + 轴线 + 事件句 + 主体类型 chip）。
//  「全部」把 GitHub 通知和当前用户 Star / Unstar / Fork 账本按时间混排，SQL UNION 游标翻页。
//  类型筛选用下拉（默认 All），形态对齐 Manage 排序菜单；账本行点开走仓库详情，不是 Issue 会话。
//

import AppKit
import SwiftUI

struct GitHubNotificationInboxView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    @Binding var selectedItem: ActivityItem?

    @State private var rows: [GitHubInboxTimelineRow] = []
    @State private var cursor: GitHubInboxTimelineCursor?
    @State private var hasMore = false
    @State private var isLoadingPage = false
    @State private var segment: GitHubNotificationSegment = .all
    @State private var lastFetchedAt: Date?
    @State private var selectedThreadId: String?
    @State private var isShowingHistoryResyncConfirmation = false

    private var inbox: GitHubNotificationInboxService {
        dependencies.githubNotificationInboxService
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task {
            inbox.listSegment = segment
            await inbox.clearDemoThreads()
            if let user = authSession.state.user {
                await inbox.backfillUserRepoActivity(userID: user.id, login: user.login)
            }
            await reloadFirstPage()
            consumePendingOpenIfNeeded()
            await inbox.sync()
            await reloadFirstPage()
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

    /// 只保留类型下拉 + 同步行，和星标中栏 `manageFilterBar` 同高。
    /// 总数 / 未读走系统 `navigationSubtitle`（面包屑下一行），不要再叠 `通知 42` 标题。
    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            GitHubNotificationSegmentMenu(selection: $segment, locale: locale)
                .onChange(of: segment) { _, newValue in
                    inbox.listSegment = newValue
                    Task { await reloadFirstPage() }
                }

            Spacer(minLength: 8)

            if let lastFetchedAt {
                Text(String(format: String.l10n("activity.notification.lastSynced"), RelativeTimeText.pastEvent(lastFetchedAt, locale: locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // InboxService 是 @Observable：isSyncing 闪过 true 后，按钮 minVisibleDuration 会转满一圈。
            SyncIconButton(
                isRefreshing: inbox.isSyncing,
                disabled: inbox.isSyncing,
                tooltip: String.l10n("activity.refresh")
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
    private var content: some View {
        if inbox.missingScope && rows.isEmpty {
            missingScopeEmpty
        } else if rows.isEmpty && inbox.isSyncing {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    private var groupedRows: [(GitHubNotificationDayGroup, [GitHubInboxTimelineRow])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [GitHubNotificationDayGroup: [GitHubInboxTimelineRow]] = [:]
        for row in rows {
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
    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { _, entry in
                    switch entry {
                    case .header(let group, let isFirst):
                        GitHubNotificationTimelineHeader(
                            titleKey: group.titleKey,
                            isFirst: isFirst
                        )
                    case .row(let row, let isFirst, let isLast):
                        GitHubNotificationTimelineRow(
                            display: timelineDisplay(for: row),
                            isSelected: selectedThreadId == row.id,
                            isFirstInTimeline: isFirst,
                            isLastInTimeline: isLast,
                            onSelect: {
                                Task { await select(row) }
                            }
                        )
                        .onAppear {
                            if isLast {
                                Task { await loadNextPageIfNeeded() }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 整条时间线（含分组标题）共用一根轴线，避免「一组只有一条」时上下线段都被裁掉。
    private var timelineEntries: [GitHubNotificationTimelineEntry] {
        let groups = groupedRows
        var entries: [GitHubNotificationTimelineEntry] = []
        for (groupIndex, (group, grouped)) in groups.enumerated() {
            entries.append(.header(group, isFirst: groupIndex == 0))
            for (rowIndex, row) in grouped.enumerated() {
                let isLast = groupIndex == groups.count - 1 && rowIndex == grouped.count - 1
                entries.append(.row(row, isFirst: false, isLast: isLast))
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

    private func reloadFirstPage() async {
        isLoadingPage = true
        defer { isLoadingPage = false }
        let page = await inbox.fetchTimelinePage(cursor: nil)
        rows = page.rows
        hasMore = page.hasMore
        cursor = page.rows.last?.cursor
        lastFetchedAt = await inbox.lastFetchedAt()
        if inbox.pendingOpenThreadId != nil {
            consumePendingOpenIfNeeded()
            return
        }
        if let selectedThreadId,
           let row = rows.first(where: { $0.id == selectedThreadId }) {
            selectedItem = await makeItem(from: row)
        } else if selectedThreadId != nil, !rows.contains(where: { $0.id == selectedThreadId }) {
            selectedThreadId = nil
            selectedItem = nil
        }
    }

    private func loadNextPageIfNeeded() async {
        guard hasMore, !isLoadingPage, let cursor else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let page = await inbox.fetchTimelinePage(cursor: cursor)
        let existing = Set(rows.map(\.id))
        rows.append(contentsOf: page.rows.filter { !existing.contains($0.id) })
        hasMore = page.hasMore
        if let last = page.rows.last {
            self.cursor = last.cursor
        }
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
                canMarkDone: record.remoteNotificationThreadID != nil
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
                language: language
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
                language: item.language
            )
        }
    }
}

/// 时间线条目：分组标题与通知行共用一根轴线。
private enum GitHubNotificationTimelineEntry: Identifiable {
    case header(GitHubNotificationDayGroup, isFirst: Bool)
    case row(GitHubInboxTimelineRow, isFirst: Bool, isLast: Bool)

    var id: String {
        switch self {
        case .header(let group, _):
            return "header-\(group.rawValue)"
        case .row(let row, _, _):
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

    /// 选中条 / 轴点：有语言走 GitHub 语言色，否则通知分类蓝。
    var accentColor: Color {
        if let language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return ActivityCategory.notification.iconColor
    }
}

private enum GitHubNotificationTimelineMetrics {
    /// 只排 `HH:mm`，日期在分组标题里。
    static let stampWidth: CGFloat = 40
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

/// 通知类型下拉。视觉对齐 `UnifiedSortMenu`，图标用筛选而不是排序箭头。
///
/// 不用分段控件：状态 / 主体类型 / Mention·Review / 账本会把同步行挤掉。
/// `Picker` + `.inline` 让当前项带勾。
private struct GitHubNotificationSegmentMenu: View {
    @Binding var selection: GitHubNotificationSegment
    let locale: Locale

    var body: some View {
        Menu {
            Picker(
                GitHubNotificationMapper.copy(locale, zh: "筛选", en: "Filter"),
                selection: $selection
            ) {
                ForEach(GitHubNotificationSegment.allCases) { item in
                    if item.showsDividerBefore {
                        Divider()
                    }
                    Label {
                        Text(verbatim: item.displayTitle(locale: locale))
                    } icon: {
                        Image(systemName: item.systemImage)
                    }
                    .tag(item)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text(verbatim: selection.displayTitle(locale: locale))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(GitHubNotificationMapper.copy(locale, zh: "筛选", en: "Filter"))
            .accessibilityValue(selection.displayTitle(locale: locale))
        }
        .fixedSize()
        .help(GitHubNotificationMapper.copy(locale, zh: "按类型筛选通知", en: "Filter notifications by type"))
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

/// 时间线行：`HH:mm` + 轴线 + 头像 + 事件句 + 仓库次行 + 可选摘录。
/// 选中跟 repo 卡片同一套语言色浅底 / 描边 / 左侧 3pt 竖条；不整行拉满，也不挪时间轴。
private struct GitHubNotificationTimelineRow: View {
    let display: GitHubNotificationTimelineDisplay
    let isSelected: Bool
    let isFirstInTimeline: Bool
    let isLastInTimeline: Bool
    let onSelect: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: GitHubNotificationTimelineMetrics.stampSpacing) {
                Text(verbatim: stamp)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: GitHubNotificationTimelineMetrics.stampWidth, alignment: .trailing)
                    .padding(.top, 3)

                Color.clear
                    .frame(width: GitHubNotificationTimelineMetrics.railWidth)

                GitHubNotificationActorAvatar(
                    login: display.actorLogin,
                    size: 24
                )
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
                        RemoteAvatar(
                            urlString: GitHubNotificationMapper.repositoryAvatarURL(
                                fromFullName: display.fullName
                            ),
                            size: 14,
                            fallbackSymbol: "shippingbox.fill",
                            showBorder: false
                        )
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
            RoundedRectangle(
                cornerRadius: GitHubNotificationTimelineMetrics.rowCornerRadius,
                style: .continuous
            )
            .fill(rowFill)
            .background {
                // 与 `RepoRowSurface` 同款：半透明 controlBackground 让浅/深色下选中都够跳。
                RoundedRectangle(
                    cornerRadius: GitHubNotificationTimelineMetrics.rowCornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isHovered ? 0.40 : 0))
            }
            .overlay(alignment: .leading) {
                // 选中左侧 3pt 语言色条。贴在圆角底上，不改 `HH:mm` / 轴线布局。
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(display.accentColor)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, GitHubNotificationTimelineMetrics.selectedInset)
            .padding(.vertical, 1)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: GitHubNotificationTimelineMetrics.rowCornerRadius,
                style: .continuous
            )
            .stroke(
                isSelected ? display.accentColor.opacity(0.42) : Color.clear,
                lineWidth: 1
            )
            .padding(.horizontal, GitHubNotificationTimelineMetrics.selectedInset)
            .padding(.vertical, 1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                isHovered = hovering
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }

    private var rowFill: Color {
        if isSelected {
            return display.accentColor.opacity(0.18)
        }
        if isHovered {
            return display.accentColor.opacity(0.08)
        }
        return .clear
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
