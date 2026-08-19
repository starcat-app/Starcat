//
//  GitHubNotificationInboxView.swift
//  Starcat
//
//  活动页「通知」中栏：时间线 + 分段筛选。不用 UnifiedRepoRow。
//  选中后写 selectedActivityItem，右栏走 ActivityDetailView 的 non-repo 分支。
//

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
        .onDisappear {
            inbox.cancelAllDwells()
        }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if inbox.missingScope && records.isEmpty {
            missingScopeEmpty
        } else if records.isEmpty && inbox.isSyncing {
            RepoSkeletonListView(rowCount: 8)
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
            let date = ISO8601DateFormatter.shared.date(from: record.updatedAt) ?? now
            let group = GitHubNotificationMapper.dayGroup(for: date, now: now, calendar: calendar)
            buckets[group, default: []].append(record)
        }
        return GitHubNotificationDayGroup.allCases.compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return (group, rows)
        }
    }

    private var timeline: some View {
        List {
            ForEach(groupedRecords, id: \.0) { group, rows in
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                        Button {
                            Task { await select(record) }
                        } label: {
                            GitHubNotificationTimelineRow(
                                record: record,
                                isSelected: selectedThreadId == record.id
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .listRowReveal(
                            index: index,
                            snapshotID: group.rawValue.hashValue,
                            replayAfterSnapshotCommit: false
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(LocalizedStringKey(group.titleKey))
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
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
        let date = ISO8601DateFormatter.shared.date(from: record.updatedAt)
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
                chip: GitHubNotificationMapper.chip(forReason: record.reason),
                subjectType: record.subjectType,
                subjectNumber: record.subjectNumber,
                repositoryFullName: record.repositoryFullName,
                actorLogin: record.actorLogin,
                excerpt: record.excerpt
            )
        )
    }
}

/// 时间线一行：reason chip + 标题 + 仓库编号 + 相对时间 + 未读点。
private struct GitHubNotificationTimelineRow: View {
    let record: GitHubNotificationThreadRecord
    let isSelected: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GitHubNotificationReasonChip(chip: GitHubNotificationMapper.chip(forReason: record.reason))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: record.subjectTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text(verbatim: GitHubNotificationMapper.subtitle(
                    fullName: record.repositoryFullName,
                    subjectType: record.subjectType,
                    number: record.subjectNumber
                ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                if let date = ISO8601DateFormatter.shared.date(from: record.updatedAt) {
                    Text(verbatim: RelativeTimeText.pastEvent(date, locale: locale))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if record.unread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
    }
}

struct GitHubNotificationReasonChip: View {
    let chip: GitHubNotificationChip

    var body: some View {
        Text(LocalizedStringKey(GitHubNotificationMapper.chipTitleKey(chip)))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(tint.opacity(0.18))
            )
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
    }

    private var tint: Color {
        switch chip {
        case .mention:
            return Color.accentColor
        case .review:
            return Color(hex: "#3178c6") ?? .blue
        case .assign:
            return Color(hex: "#F05138") ?? .orange
        case .security:
            return Color.red
        case .comment:
            return Color.secondary
        }
    }
}
