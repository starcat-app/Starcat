//
//  ProjectAccessSheet.swift
//  Starcat
//
//  “我的项目”授权与同步状态 Sheet。
//
//  关键约束：
//  - GitHub App 是可选增强；未连接时明确说明仍会用现有 OAuth 展示 Public 项目；
//  - Device Flow code 必须使用共享 CopyFeedbackButton，复制成功展示统一绿色反馈；
//  - 断开只删除独立 GitHub App 凭据，不影响主登录和已经保存的用户内容。
//

import AppKit
import SwiftUI

struct ProjectAccessSheet: View {
    let onProjectsChanged: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies

    @State private var connectionTask: Task<Void, Never>?
    @State private var isClearingPrivateCache = false
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
        .frame(width: 480)
        .onDisappear {
            if case .awaitingAuthorization = accessSession.state {
                connectionTask?.cancel()
                Task { await accessSession.cancelConnection() }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("project.access.title")
                    .font(.headline)
                Text("project.access.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SheetCloseButton(action: { dismiss() })
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusCard

            if case .awaitingAuthorization(let info) = accessSession.state {
                deviceCodeCard(info)
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
            Image(systemName: statusIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(statusColor)
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
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func deviceCodeCard(_ info: OAuthDeviceCodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("project.access.deviceCode")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(verbatim: info.userCode)
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .textSelection(.enabled)

                Spacer()

                CopyFeedbackButton(
                    providesContent: { info.userCode },
                    tooltip: "project.access.copyCode"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopy ? Color.green : Color.primary)
                        .frame(width: 24, height: 24)
                }
            }

            Button("project.access.openGitHub") {
                NSWorkspace.shared.open(info.verificationURI)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Text("project.access.openGitHub.hint"))
        }
        .padding(16)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.2))
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        HStack {
            if isConnectedLike {
                Button("project.access.disconnect", role: .destructive) {
                    disconnect()
                }
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
            case .connected:
                SyncIconButton(
                    isRefreshing: isSyncing,
                    disabled: isSyncing || authSession.state.user == nil,
                    tooltip: String.l10n("project.access.refresh"),
                    action: { refreshProjects(force: true) }
                )
            case .disconnected, .installationRequired, .partialAuthorization,
                 .organizationApprovalPending,
                 .expired, .revoked, .failed:
                Button("project.access.connect") {
                    connect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var isConnectedLike: Bool {
        switch accessSession.state {
        case .installationRequired, .connected, .partialAuthorization,
             .organizationApprovalPending:
            true
        default:
            false
        }
    }

    private var isSyncing: Bool {
        if case .syncing = syncService.state { return true }
        return false
    }

    private var statusIcon: String {
        switch accessSession.state {
        case .connected: "checkmark.shield.fill"
        case .connecting, .awaitingAuthorization: "hourglass"
        case .installationRequired, .partialAuthorization,
             .organizationApprovalPending: "exclamationmark.shield.fill"
        case .expired, .revoked, .failed: "exclamationmark.triangle.fill"
        case .unavailable: "gear.badge.xmark"
        case .disconnected: "lock.open"
        }
    }

    private var statusColor: Color {
        switch accessSession.state {
        case .connected: .green
        case .connecting, .awaitingAuthorization: .accentColor
        case .installationRequired, .partialAuthorization,
             .organizationApprovalPending: .orange
        case .expired, .revoked, .failed: .red
        case .unavailable, .disconnected: .secondary
        }
    }

    private var statusTitleKey: LocalizedStringKey {
        switch accessSession.state {
        case .unavailable: "project.access.state.unavailable.title"
        case .disconnected: "project.access.state.disconnected.title"
        case .connecting: "project.access.state.connecting.title"
        case .awaitingAuthorization: "project.access.state.awaiting.title"
        case .installationRequired: "project.access.state.partial.title"
        case .connected: "project.access.state.connected.title"
        case .partialAuthorization: "project.access.state.partial.title"
        case .organizationApprovalPending: "project.access.state.pending.title"
        case .expired: "project.access.state.expired.title"
        case .revoked: "project.access.state.revoked.title"
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
        case .installationRequired: "project.access.state.partial.detail"
        case .connected: "project.access.state.connected.detail"
        case .partialAuthorization: "project.access.state.partial.detail"
        case .organizationApprovalPending: "project.access.state.pending.detail"
        case .expired: "project.access.state.expired.detail"
        case .revoked: "project.access.state.revoked.detail"
        case .failed(.network): "project.access.state.offline.detail"
        case .failed: "project.access.state.failed.detail"
        }
    }

    private func connect() {
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            do {
                let info = try await accessSession.beginConnection()
                NSWorkspace.shared.open(info.verificationURI)
                try await accessSession.completeConnection()
                refreshProjects(force: true)
            } catch is CancellationError {
                // 用户主动取消时不覆盖 cancelConnection 已发布的 disconnected 状态。
            } catch {
                // ProjectAccessSession 已映射并发布稳定错误状态，UI 无需再保存原始错误。
            }
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        Task { await accessSession.cancelConnection() }
    }

    private func disconnect() {
        guard let userID = authSession.state.user?.id else { return }
        Task { @MainActor in
            do {
                try await syncService.disconnectProjectAccess(userID: userID)
                _ = try? await syncService.refresh(userID: userID, force: true)
                await onProjectsChanged()
            } catch {
                // 状态保持在当前授权态，用户可重试；错误不带仓库或 token 信息。
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
