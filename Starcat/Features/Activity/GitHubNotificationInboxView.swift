//
//  GitHubNotificationInboxView.swift
//  Starcat
//
//  活动页「通知」中栏：Mail 密度时间线（HH:mm + 轴线 + 事件句 + 主体类型 chip）。
//  不用 UnifiedRepoRow，也不走活动页通用详情。
//

import AppKit
import SwiftUI

struct GitHubNotificationInboxView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    @Binding var selectedItem: ActivityItem?

    @State private var records: [GitHubNotificationThreadRecord] = []
    @State private var segment: GitHubNotificationSegment = .all
    @State private var lastFetchedAt: Date?
    @State private var selectedThreadId: String?

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
            records = await inbox.fetchCached()
            lastFetchedAt = await inbox.lastFetchedAt()
            consumePendingOpenIfNeeded()
            await inbox.sync()
            await reloadFromCache()
            consumePendingOpenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
            Task { await reloadFromCache() }
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
                await inbox.sync()
                await reloadFromCache()
            }
        }
    }

    /// 只保留分段 + 同步行，和星标中栏 `manageFilterBar` 同高。
    /// 总数 / 未读走系统 `navigationSubtitle`（面包屑下一行），不要再叠 `通知 42` 标题。
    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $segment) {
                ForEach(GitHubNotificationSegment.allCases) { item in
                    Text(LocalizedStringKey(item.titleKey)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: segment) { _, newValue in
                inbox.listSegment = newValue
            }

            Spacer(minLength: 8)

            if let lastFetchedAt {
                Text(String(format: String.l10n("activity.notification.lastSynced"), RelativeTimeText.pastEvent(lastFetchedAt, locale: locale)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            SyncIconButton(
                isRefreshing: inbox.isSyncing,
                disabled: inbox.isSyncing,
                tooltip: String.l10n("activity.refresh")
            ) {
                Task {
                    await inbox.sync()
                    await reloadFromCache()
                }
            }

            Menu {
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
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    @ViewBuilder
    private var content: some View {
        if inbox.missingScope && records.isEmpty {
            missingScopeEmpty
        } else if records.isEmpty && inbox.isSyncing {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRecords.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    private var visibleRecords: [GitHubNotificationThreadRecord] {
        records.filter { GitHubNotificationMapper.matchesSegment($0, segment: segment) }
    }

    private var groupedRecords: [(GitHubNotificationDayGroup, [GitHubNotificationThreadRecord])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [GitHubNotificationDayGroup: [GitHubNotificationThreadRecord]] = [:]
        for record in visibleRecords {
            let date = GitHubNotificationMapper.parseDate(record.updatedAt) ?? now
            let group = GitHubNotificationMapper.dayGroup(for: date, now: now, calendar: calendar)
            buckets[group, default: []].append(record)
        }
        return GitHubNotificationDayGroup.allCases.compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return (group, rows)
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
                    case .row(let record, let isFirst, let isLast):
                        GitHubNotificationTimelineRow(
                            record: record,
                            isSelected: selectedThreadId == record.id,
                            isFirstInTimeline: isFirst,
                            isLastInTimeline: isLast,
                            onSelect: {
                                Task { await select(record) }
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 整条时间线（含分组标题）共用一根轴线，避免「一组只有一条」时上下线段都被裁掉。
    private var timelineEntries: [GitHubNotificationTimelineEntry] {
        let groups = groupedRecords
        var entries: [GitHubNotificationTimelineEntry] = []
        for (groupIndex, (group, rows)) in groups.enumerated() {
            entries.append(.header(group, isFirst: groupIndex == 0))
            for (rowIndex, record) in rows.enumerated() {
                let isLast = groupIndex == groups.count - 1 && rowIndex == rows.count - 1
                entries.append(.row(record, isFirst: false, isLast: isLast))
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

    private func reloadFromCache() async {
        records = await inbox.fetchCached()
        lastFetchedAt = await inbox.lastFetchedAt()
        if let selectedThreadId,
           let record = records.first(where: { $0.id == selectedThreadId }) {
            selectedItem = await makeItem(from: record)
        }
    }

    private func consumePendingOpenIfNeeded() {
        guard let threadId = inbox.pendingOpenThreadId else { return }
        inbox.pendingOpenThreadId = nil
        Task {
            if let cached = records.first(where: { $0.id == threadId }) {
                await select(cached)
                return
            }
            if let record = try? await dependencies.githubNotificationThreadRepository.fetch(id: threadId) {
                await select(record)
            }
        }
    }

    private func select(_ record: GitHubNotificationThreadRecord) async {
        if let previous = selectedThreadId, previous != record.id {
            await inbox.cancelDwell(id: previous)
        }
        selectedThreadId = record.id
        selectedItem = await makeItem(from: record)
        await inbox.beginDwell(id: record.id)
        await inbox.hydrate(id: record.id)
        if let updated = try? await dependencies.githubNotificationThreadRepository.fetch(id: record.id) {
            selectedItem = await makeItem(from: updated)
        }
    }

    private func makeItem(from record: GitHubNotificationThreadRecord) async -> ActivityItem {
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
                repositoryId: record.repositoryId
            )
        )
    }
}

/// 时间线条目：分组标题与通知行共用一根轴线。
private enum GitHubNotificationTimelineEntry: Identifiable {
    case header(GitHubNotificationDayGroup, isFirst: Bool)
    case row(GitHubNotificationThreadRecord, isFirst: Bool, isLast: Bool)

    var id: String {
        switch self {
        case .header(let group, _):
            return "header-\(group.rawValue)"
        case .row(let record, _, _):
            return record.id
        }
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

/// 时间线行：`HH:mm` + 轴线 + 头像 + 事件句 + 仓库次行 + 可选摘录。选中是行内圆角底，不整行拉满。
private struct GitHubNotificationTimelineRow: View {
    let record: GitHubNotificationThreadRecord
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
                    login: GitHubNotificationMapper.eventActor(for: record) ?? "",
                    size: 24
                )
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: GitHubNotificationMapper.eventHeadline(for: record, locale: locale))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        GitHubNotificationReasonChip(chip: GitHubNotificationMapper.subjectChip(for: record))
                    }

                    HStack(spacing: 6) {
                        RemoteAvatar(
                            urlString: GitHubNotificationMapper.repositoryAvatarURL(
                                fromFullName: record.repositoryFullName
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
                        unread: record.unread,
                        isFirst: isFirstInTimeline,
                        isLast: isLastInTimeline,
                        showsDot: true
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
            .padding(.horizontal, GitHubNotificationTimelineMetrics.selectedInset)
            .padding(.vertical, 1)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: GitHubNotificationTimelineMetrics.rowCornerRadius,
                style: .continuous
            )
            .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
            .padding(.horizontal, GitHubNotificationTimelineMetrics.selectedInset)
            .padding(.vertical, 1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        return .clear
    }

    private var updatedAt: Date? {
        GitHubNotificationMapper.parseDate(record.updatedAt)
    }

    private var stamp: String {
        guard let date = updatedAt else { return "--:--" }
        return GitHubNotificationMapper.timelineStamp(date: date, locale: locale)
    }

    private var caption: String {
        let relative = updatedAt.map { RelativeTimeText.pastEvent($0, locale: locale) } ?? ""
        return GitHubNotificationMapper.timelineCaption(
            fullName: record.repositoryFullName,
            subjectType: record.subjectType,
            number: record.subjectNumber,
            relativeTime: relative
        )
    }

    /// 没 hydrate 就不要留空行，行高才稳。
    private var snippet: String? {
        guard let text = GitHubNotificationMapper.listSnippet(record.excerpt),
              !text.isEmpty
        else { return nil }
        return text
    }
}

/// 组内上下接缝的 1pt 轴线；圆点本身就是未读指示。高度必须铺满整行，不能写死。
private struct GitHubNotificationTimelineRail: View {
    let unread: Bool
    let isFirst: Bool
    let isLast: Bool
    var showsDot: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(isFirst ? 0 : 0.35))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            if showsDot {
                Circle()
                    .fill(unread ? Color.accentColor : Color.secondary)
                    .frame(width: unread ? 8 : 6, height: unread ? 8 : 6)
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
        case .release, .discussion, .comment, .mention, .review, .assign:
            // Release / Discussion / 其它剩余 chip 用安静灰，不靠彩虹色抢扫描。
            return Color.secondary
        }
    }
}
