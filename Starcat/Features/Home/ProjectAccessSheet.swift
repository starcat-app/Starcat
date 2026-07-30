//
//  ProjectAccessSheet.swift
//  Starcat
//
//  “我的项目”授权与同步状态 Sheet。
//
//  关键约束：
//  - GitHub App 是可选增强；未连接时明确说明仍会用现有 OAuth 展示 Public 项目；
//  - 安装与用户授权在同一次 GitHub 浏览器流程完成，不再要求第二次 Device Flow；
//  - 断开只删除独立 GitHub App 凭据，不影响主登录和已经保存的用户内容。
//

import AppKit
import SwiftUI

struct ProjectAccessSheet: View {
    let onProjectsChanged: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies

    @State private var isCheckingInstallation = false
    @State private var isClearingPrivateCache = false
    @State private var isDisconnecting = false
    @State private var disconnectAfterAuthorization = false
    @State private var showsDisconnectConfirmation = false
    @State private var privateCacheClearMessage: LocalizedStringKey?

    private var accessSession: ProjectAccessSession {
        dependencies.projectAccessSession
    }

    private var syncService: UserProjectSyncService {
        dependencies.userProjectSyncService
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(24)
        }
        .frame(width: 520)
        .alert(
            "project.access.disconnect.confirm.title",
            isPresented: $showsDisconnectConfirmation
        ) {
            Button("common.cancel", role: .cancel) {}
            Button("project.access.disconnect.confirm.action", role: .destructive) {
                disconnect()
            }
        } message: {
            Text("project.access.disconnect.confirm.detail")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("project.access.title")
                    .font(.headline)
                Text("project.access.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            SheetCloseButton(action: { dismiss() })
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusCard

            if accessSession.state == .disconnected {
                permissionSummary
            }

            actionArea
            Divider()
            privateCacheArea
        }
    }

    private var privateCacheArea: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("project.access.privateCache.title")
                    .font(.callout.weight(.medium))
                Text(privateCacheClearMessage ?? "project.access.privateCache.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("project.access.privateCache.clear", role: .destructive) {
                clearPrivateCache()
            }
            .disabled(isClearingPrivateCache)
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: accessSession.state.statusSymbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accessSession.state.statusTone.foregroundColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitleKey)
                    .font(.body.weight(.semibold))
                Text(statusDetailKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            accessSession.state.statusTone.backgroundColor,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
    }

    /// 连接前直接说明 GitHub 将展示的授权项，避免用户离开 Starcat 后才知道权限范围。
    private var permissionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("project.access.permissions.title")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            permissionRow(
                icon: "info.circle",
                title: "project.access.permissions.metadata.title",
                detail: "project.access.permissions.metadata.detail"
            )
            permissionRow(
                icon: "doc.text.magnifyingglass",
                title: "project.access.permissions.contents.title",
                detail: "project.access.permissions.contents.detail"
            )
            permissionRow(
                icon: "checklist",
                title: "project.access.permissions.selection.title",
                detail: "project.access.permissions.selection.detail"
            )

            // 只读边界是授权前最关键的安全承诺，用 warning 语义与普通说明行拉开层级。
            Label("project.access.permissions.noWrite", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionArea: some View {
        HStack {
            if canDisconnectImmediately {
                Button("project.access.disconnect", role: .destructive) {
                    showsDisconnectConfirmation = true
                }
                .disabled(isDisconnecting)
            }

            Spacer()

            switch accessSession.state {
            case .unavailable:
                EmptyView()
            case .connecting, .awaitingAuthorization:
                Button("project.access.cancel") {
                    cancelConnection()
                }
                .buttonStyle(.bordered)
            case .disconnected:
                if shouldOfferExplicitReauthorization {
                    Button("project.access.alreadyInstalled") {
                        connect(modeOverride: .reauthorization)
                    }
                    .buttonStyle(.bordered)
                }
                Button("project.access.connect") {
                    connect()
                }
                .buttonStyle(.borderedProminent)
            case .installationRequired:
                Button("project.access.install") {
                    openInstallationPage()
                }
                .buttonStyle(.borderedProminent)
                SyncIconButton(
                    isRefreshing: isCheckingInstallation,
                    disabled: isCheckingInstallation,
                    tooltip: String.l10n("project.access.checkInstallation"),
                    action: { recheckInstallation() }
                )
            case .installationCheckFailed, .connected, .partialAuthorization,
                 .organizationApprovalPending:
                Button("project.access.manage") {
                    openInstallationSettings()
                }
                .buttonStyle(.bordered)
                SyncIconButton(
                    isRefreshing: isCheckingInstallation || isSyncing,
                    disabled: isCheckingInstallation || isSyncing || authSession.state.user == nil,
                    tooltip: String.l10n(
                        accessSession.state.isInstallationCheckFailure
                            ? "project.access.checkInstallation"
                            : "project.access.refresh"
                    ),
                    action: {
                        if accessSession.state.isInstallationCheckFailure {
                            recheckInstallation()
                        } else {
                            refreshProjects(force: true)
                        }
                    }
                )
            case .disconnectionFailed(let failureCode):
                Button("project.access.manage") {
                    openInstallationSettings()
                }
                .buttonStyle(.bordered)
                if failureCode == .reauthorizationRequired {
                    Button("project.access.disconnect.reauthorize") {
                        reauthorizeAndDisconnect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .expired, .revoked, .failed:
                Button("project.access.manage") {
                    openInstallationSettings()
                }
                .buttonStyle(.bordered)
                Button("project.access.reauthorize") {
                    connect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var isConnectedLike: Bool {
        switch accessSession.state {
        case .installationRequired, .installationCheckFailed, .connected,
             .partialAuthorization, .organizationApprovalPending,
             .disconnectionFailed:
            true
        default:
            false
        }
    }

    private var canDisconnectImmediately: Bool {
        if case .disconnectionFailed(.reauthorizationRequired) = accessSession.state {
            return false
        }
        return isConnectedLike
    }

    private var isSyncing: Bool {
        if case .syncing = syncService.state { return true }
        return false
    }

    /// GitHub App 可能已由网页或另一渠道安装，但当前用户尚无本机回调记录。
    /// 此时保留安装入口，同时提供显式 OAuth 授权，避免安装页不再回调造成流程悬停。
    private var shouldOfferExplicitReauthorization: Bool {
        guard let userID = authSession.state.user?.id else { return false }
        return accessSession.shouldOfferExplicitReauthorization(for: userID)
    }

    private var statusTitleKey: LocalizedStringKey {
        switch accessSession.state {
        case .unavailable: "project.access.state.unavailable.title"
        case .disconnected: "project.access.state.disconnected.title"
        case .connecting: "project.access.state.connecting.title"
        case .awaitingAuthorization: "project.access.state.awaiting.title"
        case .installationRequired: "project.access.state.installationRequired.title"
        case .installationCheckFailed: "project.access.state.installationCheckFailed.title"
        case .connected: "project.access.state.connected.title"
        case .partialAuthorization: "project.access.state.partial.title"
        case .organizationApprovalPending: "project.access.state.pending.title"
        case .expired: "project.access.state.expired.title"
        case .revoked: "project.access.state.revoked.title"
        case .disconnectionFailed(.reauthorizationRequired):
            "project.access.state.disconnectReauthorizationRequired.title"
        case .disconnectionFailed: "project.access.state.disconnectionFailed.title"
        case .failed(.network): "project.access.state.offline.title"
        case .failed: "project.access.state.failed.title"
        }
    }

    private var statusDetailKey: LocalizedStringKey {
        switch accessSession.state {
        case .unavailable: "project.access.state.unavailable.detail"
        case .disconnected: "project.access.state.disconnected.detail"
        case .connecting: "project.access.state.connecting.detail"
        case .awaitingAuthorization: "project.access.state.awaiting.detail"
        case .installationRequired: "project.access.state.installationRequired.detail"
        case .installationCheckFailed: "project.access.state.installationCheckFailed.detail"
        case .connected: "project.access.state.connected.detail"
        case .partialAuthorization: "project.access.state.partial.detail"
        case .organizationApprovalPending: "project.access.state.pending.detail"
        case .expired: "project.access.state.expired.detail"
        case .revoked: "project.access.state.revoked.detail"
        case .disconnectionFailed(.reauthorizationRequired):
            "project.access.state.disconnectReauthorizationRequired.detail"
        case .disconnectionFailed: "project.access.state.disconnectionFailed.detail"
        case .failed(.network): "project.access.state.offline.detail"
        case .failed: "project.access.state.failed.detail"
        }
    }

    private func connect(
        modeOverride: ProjectAccessAuthorizationMode? = nil,
        disconnectAfterAuthorization: Bool = false
    ) {
        guard let userID = authSession.state.user?.id else { return }
        self.disconnectAfterAuthorization = disconnectAfterAuthorization
        accessSession.startConnection(
            userID: userID,
            modeOverride: modeOverride
        ) { result in
            let shouldDisconnect = self.disconnectAfterAuthorization
            self.disconnectAfterAuthorization = false
            switch result {
            case .connected where shouldDisconnect:
                disconnect()
            case .connected(let access) where access.isInstalled:
                // 安装已就绪：立刻同步项目关系，把 Private / Internal 刷进中栏。
                refreshProjects(force: true)
            case .connected:
                // OAuth 已成功但尚未安装 App：仍通知外层清快照 / 更新计数，避免停留在授权前列表。
                Task { @MainActor in
                    await onProjectsChanged()
                }
            case .cancelled, .failed:
                break
            }
        }
    }

    /// 当前 token 已无法刷新时先取得新 user token，callback 成功后继续原断开操作。
    private func reauthorizeAndDisconnect() {
        connect(modeOverride: .reauthorization, disconnectAfterAuthorization: true)
    }

    private func openInstallationSettings() {
        NSWorkspace.shared.open(AppConstants.githubAppSettingsURL)
    }

    /// 已有 user grant 时重新安装不会产生新的 OAuth callback；安装后由用户主动复查。
    private func openInstallationPage() {
        guard let url = AppConstants.githubAppInstallationURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func recheckInstallation() {
        guard !isCheckingInstallation else { return }
        isCheckingInstallation = true
        Task { @MainActor in
            defer { isCheckingInstallation = false }
            do {
                let access = try await accessSession.refreshInstallationState()
                if access.isInstalled {
                    refreshProjects(force: true)
                }
            } catch {
                // 状态机已区分“未安装”和“校验失败”，不向 UI 泄漏响应正文。
            }
        }
    }

    private func cancelConnection() {
        Task { await accessSession.cancelConnection() }
    }

    private func disconnect() {
        guard let userID = authSession.state.user?.id else { return }
        guard !isDisconnecting else { return }
        isDisconnecting = true
        Task { @MainActor in
            defer { isDisconnecting = false }
            do {
                try await syncService.disconnectProjectAccess(userID: userID)
                _ = try? await syncService.refresh(userID: userID, force: true)
                await onProjectsChanged()
            } catch {
                // Session 已发布稳定失败状态且保留 token；UI 不展示 GitHub 响应正文。
            }
        }
    }

    private func refreshProjects(force: Bool) {
        guard let userID = authSession.state.user?.id else { return }
        Task { @MainActor in
            _ = try? await syncService.refresh(userID: userID, force: force)
            await onProjectsChanged()
        }
    }

    private func clearPrivateCache() {
        isClearingPrivateCache = true
        privateCacheClearMessage = nil
        Task { @MainActor in
            defer { isClearingPrivateCache = false }
            do {
                _ = try await dependencies.readmeRepository.deletePrivateRemoteCaches()
                privateCacheClearMessage = "project.access.privateCache.cleared"
            } catch {
                privateCacheClearMessage = "project.access.privateCache.failed"
            }
        }
    }
}

private extension ProjectAccessState {
    var isInstallationCheckFailure: Bool {
        if case .installationCheckFailed = self { return true }
        return false
    }
}

/// 项目授权状态的视觉语义。颜色只表达状态，不参与普通内容装饰。
enum ProjectAccessStatusTone: Equatable {
    case neutral
    case active
    case success
    case warning
    case failure

    var foregroundColor: Color {
        switch self {
        case .neutral: .secondary
        case .active: .accentColor
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }

    var backgroundColor: Color {
        switch self {
        case .success: .green.opacity(0.10)
        case .warning: .orange.opacity(0.08)
        case .failure: .red.opacity(0.08)
        case .neutral, .active: .secondary.opacity(0.08)
        }
    }
}

extension ProjectAccessState {
    /// 集中维护状态图标，避免 Sheet 的标题、颜色和图标在新增状态时出现不一致。
    var statusSymbolName: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .awaitingAuthorization: "hourglass"
        case .installationRequired: "square.and.arrow.down"
        case .installationCheckFailed: "exclamationmark.arrow.triangle.2.circlepath"
        case .partialAuthorization: "checkmark.shield.fill"
        case .organizationApprovalPending: "clock.fill"
        case .expired, .revoked, .disconnectionFailed, .failed:
            "exclamationmark.triangle.fill"
        case .unavailable: "gear.badge.xmark"
        case .disconnected: "lock.shield"
        }
    }

    var statusTone: ProjectAccessStatusTone {
        switch self {
        case .connected: .success
        case .connecting, .awaitingAuthorization: .active
        case .installationRequired, .installationCheckFailed,
             .partialAuthorization, .organizationApprovalPending:
            .warning
        case .expired, .revoked, .disconnectionFailed, .failed: .failure
        case .unavailable, .disconnected: .neutral
        }
    }
}
