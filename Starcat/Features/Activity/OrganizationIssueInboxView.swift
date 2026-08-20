//
//  OrganizationIssueInboxView.swift
//  Starcat
//
//  Activity「组织 Issues」中栏与右栏详情。
//
//  中栏只消费 OrganizationIssueInboxService 的会话内快照；不借用 GitHub Notifications
//  的已读、Done、轮询和数据库语义。右栏直接渲染同一 payload，避免为私有 Issue 再落一份缓存。
//

import AppKit
import MarkdownUI
import SwiftUI

struct OrganizationIssueInboxView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    @Binding var selectedItem: ActivityItem?
    let onItemCountChange: (Int) -> Void

    @State private var service: OrganizationIssueInboxService?
    @State private var selectedOrganization: String?
    @State private var selectedState: GitHubOrganizationIssueState = .open

    var body: some View {
        Group {
            if let service {
                inbox(service)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await refresh()
        }
        .onChange(of: selectedOrganization) { _, _ in
            Task { await refresh() }
        }
        .onChange(of: selectedState) { _, _ in
            Task { await refresh() }
        }
        .starcatRefreshCommand(
            pane: .list,
            identity: "activity-organization-issues-\(service?.isLoading == true)",
            title: String.l10n("commands.actions.refreshCurrentList"),
            isEnabled: service?.isLoading != true
        ) {
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private func inbox(_ service: OrganizationIssueInboxService) -> some View {
        VStack(spacing: 0) {
            filterBar(service)
            Divider()

            if service.isLoading && service.issues.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = service.errorMessage, service.issues.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: "activity.organizationIssues.error.title",
                        subtitleText: error
                    )
                    Button("activity.organizationIssues.retry") {
                        Task { await refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.organizations.isEmpty {
                EmptyStateView(
                    systemImage: "building.2",
                    title: "activity.organizationIssues.noOrganizations.title",
                    subtitle: "activity.organizationIssues.noOrganizations.subtitle"
                )
            } else if service.issues.isEmpty {
                EmptyStateView(
                    systemImage: "smallcircle.filled.circle",
                    title: "activity.organizationIssues.empty.title",
                    subtitle: "activity.organizationIssues.empty.subtitle"
                )
            } else {
                issueList(service)
            }
        }
        .onChange(of: service.issues) { _, issues in
            applySelectionPolicy(issues)
            onItemCountChange(issues.count)
        }
        .onAppear {
            onItemCountChange(service.issues.count)
        }
    }

    private func filterBar(_ service: OrganizationIssueInboxService) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("activity.organizationIssues.organization.all") {
                    selectedOrganization = nil
                }
                Divider()
                ForEach(service.organizations, id: \.self) { organization in
                    Button {
                        selectedOrganization = organization
                    } label: {
                        Text(verbatim: organization)
                    }
                }
            } label: {
                Label {
                    Text(verbatim: selectedOrganization ?? String.l10n("activity.organizationIssues.organization.all"))
                } icon: {
                    Image(systemName: "building.2")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(service.isLoading)

            Picker("activity.organizationIssues.state.label", selection: $selectedState) {
                ForEach(GitHubOrganizationIssueState.allCases) { state in
                    Text(stateTitleKey(state)).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(service.isLoading)

            Spacer(minLength: 8)

            SyncIconButton(
                isRefreshing: service.isLoading,
                disabled: service.isLoading,
                tooltip: String.l10n("activity.refresh")
            ) {
                Task { await refresh() }
            }
        }
        .manageListFilterBarChrome()
    }

    private func issueList(_ service: OrganizationIssueInboxService) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(service.issues) { issue in
                    Button {
                        selectedItem = makeActivityItem(issue)
                    } label: {
                        OrganizationIssueRow(
                            issue: issue,
                            isSelected: selectedItem?.organizationIssue?.issue.deduplicationKey
                                == issue.deduplicationKey,
                            locale: locale
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    Divider()
                }

                if service.canLoadMore {
                    Button {
                        Task {
                            await service.loadMore(state: selectedState)
                            onItemCountChange(service.issues.count)
                        }
                    } label: {
                        if service.isLoadingMore {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("activity.organizationIssues.loadMore")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(service.isLoadingMore)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func refresh() async {
        guard let userID = authSession.state.user?.id else {
            selectedItem = nil
            onItemCountChange(0)
            return
        }
        let service = ensureService()
        await service.refresh(
            userID: userID,
            selectedOrganization: selectedOrganization,
            state: selectedState
        )
        if let selectedOrganization, !service.organizations.contains(selectedOrganization) {
            self.selectedOrganization = nil
            return
        }
        applySelectionPolicy(service.issues)
        onItemCountChange(service.issues.count)
    }

    private func ensureService() -> OrganizationIssueInboxService {
        if let service { return service }
        let model = OrganizationIssueInboxService(
            primaryClient: dependencies.apiClient,
            projectClient: dependencies.projectGitHubAPIClient,
            repository: dependencies.repoRepository,
            isProjectAccessAvailable: {
                switch dependencies.projectAccessSession.state {
                case .connected, .partialAuthorization, .organizationApprovalPending:
                    return true
                default:
                    return false
                }
            }
        )
        service = model
        return model
    }

    private func applySelectionPolicy(_ issues: [GitHubOrganizationIssue]) {
        if let selectedKey = selectedItem?.organizationIssue?.issue.deduplicationKey,
           let refreshed = issues.first(where: { $0.deduplicationKey == selectedKey }) {
            selectedItem = makeActivityItem(refreshed)
            return
        }
        selectedItem = settings.openFirstDetailOnCategoryChange
            ? issues.first.map(makeActivityItem)
            : nil
    }

    private func makeActivityItem(_ issue: GitHubOrganizationIssue) -> ActivityItem {
        var item = ActivityItem(
            id: "organization-issue:\(issue.deduplicationKey)",
            kind: .organizationIssue,
            category: .organizationIssues,
            title: issue.title,
            subtitle: "\(issue.repositoryFullName)#\(issue.number)",
            body: issue.body,
            createdAt: issue.updatedAt ?? issue.createdAt,
            htmlURL: issue.htmlURL,
            repo: nil,
            release: nil,
            releases: [],
            isRead: true
        )
        item.organizationIssue = ActivityOrganizationIssuePayload(issue: issue)
        return item
    }

    private func stateTitleKey(_ state: GitHubOrganizationIssueState) -> LocalizedStringKey {
        switch state {
        case .open: return "activity.organizationIssues.state.open"
        case .closed: return "activity.organizationIssues.state.closed"
        case .all: return "activity.organizationIssues.state.all"
        }
    }
}

private struct OrganizationIssueRow: View {
    let issue: GitHubOrganizationIssue
    let isSelected: Bool
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.state == .open ? "smallcircle.filled.circle" : "checkmark.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: issue.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(verbatim: "\(issue.repositoryFullName)#\(issue.number)")
                        .lineLimit(1)
                    if let updatedAt = issue.updatedAt {
                        Text(verbatim: "·")
                        Text(verbatim: RelativeTimeText.pastEvent(updatedAt, locale: locale))
                    }
                    if issue.commentsCount > 0 {
                        Image(systemName: "bubble.left")
                        Text(verbatim: String(issue.commentsCount))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct OrganizationIssueDetailView: View {
    @Binding var selectedItem: ActivityItem?
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if let issue = selectedItem?.organizationIssue?.issue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailHeader(issue)
                        Divider()
                        if let body = issue.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Markdown(body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("activity.organizationIssues.detail.noBody")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .detailScrollViewStyle()
            } else {
                EmptyStateView(
                    systemImage: "smallcircle.filled.circle",
                    title: "activity.organizationIssues.detail.empty.title",
                    subtitle: "activity.organizationIssues.detail.empty.subtitle"
                )
            }
        }
        .id(selectedItem?.id ?? "organization-issue-empty")
        .detailContentTransition()
    }

    private func detailHeader(_ issue: GitHubOrganizationIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: issue.repositoryFullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: issue.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("activity.organizationIssues.detail.openOnGitHub") {
                    NSWorkspace.shared.open(issue.htmlURL)
                }
            }

            HStack(spacing: 8) {
                Label {
                    Text(verbatim: stateTitle(issue.state))
                } icon: {
                    Image(systemName: issue.state == .open ? "smallcircle.filled.circle" : "checkmark.circle")
                }
                .foregroundStyle(.secondary)

                Text(verbatim: "#\(issue.number)")
                    .foregroundStyle(.secondary)

                if let author = issue.authorLogin {
                    Text(verbatim: author)
                        .foregroundStyle(.secondary)
                }

                if let updatedAt = issue.updatedAt {
                    Text(verbatim: RelativeTimeText.pastEvent(updatedAt, locale: locale))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            if !issue.labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(issue.labels, id: \.self) { label in
                            Text(verbatim: label.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (Color(hex: "#\(label.colorHex)") ?? .secondary).opacity(0.22),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
        }
    }

    private func stateTitle(_ state: GitHubOrganizationIssueState) -> String {
        switch state {
        case .open: return String.l10n("activity.organizationIssues.state.open")
        case .closed: return String.l10n("activity.organizationIssues.state.closed")
        case .all: return String.l10n("activity.organizationIssues.state.all")
        }
    }
}
