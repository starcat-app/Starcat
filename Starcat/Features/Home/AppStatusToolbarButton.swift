//
//  AppStatusToolbarButton.swift
//  Starcat
//
//  主窗口 toolbar 的全局状态入口。
//
//  设计约束：
//  - 只展示“同步 / 后台任务 / 服务可用性 / MCP / 诊断问题”的轻量概览；
//  - 诊断问题从本机 JSONL 摘要读取，避免把状态面板变成新的错误来源；
//  - 服务可用性走四个自建 API 的 `/healthz`，打开面板时实时刷新，后台每 10 分钟巡检；
//  - 跳转复用 SettingsView 已有的 Notification 路由，不新增主窗口路由状态。
//

import SwiftUI

/// toolbar 状态按钮：点击后展示应用状态 popover。
struct AppStatusToolbarButton: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.locale) private var locale

    let lastSyncedAt: Date?
    let onShowBatchAIPanel: (() -> Void)?

    @State private var isPresented = false
    @State private var diagnosticSummary: DiagnosticLogSummary = .empty

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: overallStatusIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(overallStatusColor)
                    .font(.system(size: ToolbarIconMetrics.defaultFontSize, weight: .regular))
                    .frame(
                        width: ToolbarIconMetrics.frameSize,
                        height: ToolbarIconMetrics.frameSize,
                        alignment: .center
                    )
                if activeTaskCount > 0 {
                    Text("\(activeTaskCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.16), in: Capsule())
                }
            }
            .accessibilityLabel(Text("toolbar.status.label"))
            .accessibilityValue(Text(statusCaption))
        }
        .help("toolbar.status.help")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AppStatusPanel(
                lastSyncedAt: lastSyncedAt,
                syncState: syncManager.state,
                syncProgress: syncManager.progress,
                batchService: dependencies.batchAIQueueService,
                mcpState: dependencies.mcpService.state,
                mcpEnabled: settings.mcpServiceEnabled,
                mcpEndpointURL: dependencies.mcpService.endpointURL,
                serviceSummary: dependencies.serviceAvailabilityMonitor.summary,
                diagnosticSummary: diagnosticSummary,
                relativePastDate: relativePastDate,
                relativeFutureDate: relativeFutureDate,
                onOpenDiagnostics: { openSettings(tab: "diagnostics") },
                onClearDiagnostics: {
                    Task { await clearDiagnostics() }
                },
                onOpenServices: { openSettings(tab: "services") },
                onOpenMCP: { openSettings(tab: "mcp") },
                onShowBatchAIPanel: onShowBatchAIPanel
            )
            .frame(width: 340)
            .padding(14)
            .appLocaleEnvironment()
            .task {
                await refreshDiagnostics()
                await dependencies.serviceAvailabilityMonitor.refreshNow()
            }
        }
        .task {
            await refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticIssuesDidChange)) { _ in
            Task { await refreshDiagnostics() }
        }
        .onChange(of: isPresented) { _, newValue in
            guard newValue else { return }
            Task {
                await refreshDiagnostics()
                await dependencies.serviceAvailabilityMonitor.refreshNow()
            }
        }
    }

    private var activeTaskCount: Int {
        let batch = dependencies.batchAIQueueService
        guard batch.isRunning || batch.isPaused else { return 0 }
        return max(0, batch.totalCount - batch.finishedCount)
    }

    private var hasIssue: Bool {
        diagnosticSummary.issueCount > 0 || isMCPFailed || dependencies.serviceAvailabilityMonitor.summary.hasIssue
    }

    private var isMCPFailed: Bool {
        if case .failed = dependencies.mcpService.state { return true }
        return false
    }

    private var overallStatusIcon: String {
        if hasIssue { return "exclamationmark.triangle.fill" }
        if syncManager.isSyncing || activeTaskCount > 0 { return "clock.arrow.circlepath" }
        return "checkmark.circle.fill"
    }

    private var overallStatusColor: Color {
        if hasIssue { return .orange }
        if syncManager.isSyncing || activeTaskCount > 0 { return .accentColor }
        return .green
    }

    private var statusCaption: LocalizedStringKey {
        if hasIssue { return "toolbar.status.caption.issue" }
        if syncManager.isSyncing { return "toolbar.status.caption.syncing" }
        if activeTaskCount > 0 { return "toolbar.status.caption.tasks" }
        return "toolbar.status.caption.ok"
    }

    private func refreshDiagnostics() async {
        diagnosticSummary = await DiagnosticLogStore.shared.issueSummary()
    }

    private func clearDiagnostics() async {
        await DiagnosticLogStore.shared.markIssuesAcknowledged()
        await refreshDiagnostics()
    }

    private func relativePastDate(_ date: Date) -> String {
        RelativeTimeText.pastEvent(date, locale: locale)
    }

    private func relativeFutureDate(_ date: Date) -> String {
        RelativeTimeText.futureDeadline(date, locale: locale)
    }

    private func openSettings(tab: String) {
        openSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: tab)
        }
    }
}

/// 状态 popover 内容。
private struct AppStatusPanel: View {
    let lastSyncedAt: Date?
    let syncState: SyncState
    let syncProgress: SyncProgress?
    let batchService: BatchAIQueueService
    let mcpState: StarcatMCPService.State
    let mcpEnabled: Bool
    let mcpEndpointURL: String
    let serviceSummary: ServiceAvailabilitySummary
    let diagnosticSummary: DiagnosticLogSummary
    let relativePastDate: (Date) -> String
    let relativeFutureDate: (Date) -> String
    let onOpenDiagnostics: () -> Void
    let onClearDiagnostics: () -> Void
    let onOpenServices: () -> Void
    let onOpenMCP: () -> Void
    let onShowBatchAIPanel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            statusRow(
                icon: syncIcon,
                tint: syncTint,
                title: "toolbar.status.sync.title",
                subtitle: syncSubtitle,
                accessory: { syncAccessory }
            )
            statusRow(
                icon: taskIcon,
                tint: taskTint,
                title: "toolbar.status.tasks.title",
                subtitle: taskSubtitle,
                accessory: { taskAccessory }
            )
            statusRow(
                icon: serviceIcon,
                tint: serviceTint,
                title: "toolbar.status.services.title",
                subtitle: serviceSubtitle,
                accessory: {
                    Button("toolbar.status.services.open") {
                        onOpenServices()
                    }
                    .controlSize(.small)
                    .focusEffectDisabled()
                }
            )
            statusRow(
                icon: mcpIcon,
                tint: mcpTint,
                title: "toolbar.status.mcp.title",
                subtitle: mcpSubtitle,
                accessory: {
                    Button("toolbar.status.mcp.open") {
                        onOpenMCP()
                    }
                    .controlSize(.small)
                    .focusEffectDisabled()
                }
            )
            statusRow(
                icon: diagnosticIcon,
                tint: diagnosticTint,
                title: "toolbar.status.diagnostics.title",
                subtitle: diagnosticSubtitle,
                accessory: { diagnosticAccessory }
            )
        }
    }

    @ViewBuilder
    private var diagnosticAccessory: some View {
        HStack(spacing: 6) {
            if diagnosticSummary.issueCount > 0 {
                Button("toolbar.status.diagnostics.clear") {
                    onClearDiagnostics()
                }
                .controlSize(.small)
                .focusEffectDisabled()
            }
            Button("toolbar.status.diagnostics.open") {
                onOpenDiagnostics()
            }
            .controlSize(.small)
            .focusEffectDisabled()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("toolbar.status.panel.title", systemImage: "waveform.path.ecg")
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private func statusRow<Accessory: View>(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }

    private var syncIcon: String {
        switch syncState {
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed, .rateLimited: return "exclamationmark.triangle.fill"
        case .idle, .completed: return "checkmark.circle.fill"
        }
    }

    private var syncTint: Color {
        switch syncState {
        case .failed, .rateLimited: return .orange
        case .syncing: return .accentColor
        case .idle, .completed: return .green
        }
    }

    private var syncSubtitle: String {
        switch syncState {
        case .syncing:
            if let progress = syncProgress, let total = progress.total {
                return String(format: String.l10n("toolbar.status.sync.progressFormat"), progress.current, total)
            }
            return String.l10n("toolbar.status.sync.running")
        case .completed(let at):
            return String(format: String.l10n("toolbar.status.sync.lastFormat"), relativePastDate(at))
        case .failed(let message):
            return message
        case .rateLimited(let retryAt):
            if RelativeTimeText.isImmediateDeadline(retryAt) {
                return String.l10n("toolbar.status.sync.rateLimitedRetryNow")
            }
            return String(format: String.l10n("toolbar.status.sync.rateLimitedFormat"), relativeFutureDate(retryAt))
        case .idle:
            if let lastSyncedAt {
                return String(format: String.l10n("toolbar.status.sync.lastFormat"), relativePastDate(lastSyncedAt))
            }
            return String.l10n("toolbar.status.sync.notYet")
        }
    }

    @ViewBuilder
    private var syncAccessory: some View {
        if case .syncing = syncState {
            ProgressView()
                .controlSize(.small)
        } else {
            EmptyView()
        }
    }

    private var taskIcon: String {
        if batchService.isRunning { return "sparkles" }
        if batchService.isPaused { return "pause.circle.fill" }
        return "tray"
    }

    private var taskTint: Color {
        if batchService.failedCount > 0 { return .orange }
        if batchService.isRunning || batchService.isPaused { return .accentColor }
        return .secondary
    }

    private var taskSubtitle: String {
        guard batchService.totalCount > 0 else {
            return String.l10n("toolbar.status.tasks.empty")
        }
        return String(
            format: String.l10n("toolbar.status.tasks.progressFormat"),
            batchService.finishedCount,
            batchService.totalCount,
            batchService.failedCount
        )
    }

    @ViewBuilder
    private var taskAccessory: some View {
        if batchService.totalCount > 0 {
            Button("toolbar.status.tasks.open") {
                onShowBatchAIPanel?()
            }
            .controlSize(.small)
            .focusEffectDisabled()
        } else {
            EmptyView()
        }
    }

    private var serviceIcon: String {
        if serviceSummary.isChecking { return "arrow.triangle.2.circlepath" }
        if serviceSummary.hasIssue { return "exclamationmark.triangle.fill" }
        if serviceSummary.isAllAvailable { return "checkmark.circle.fill" }
        return "globe"
    }

    private var serviceTint: Color {
        if serviceSummary.hasIssue { return .orange }
        if serviceSummary.isAllAvailable { return .green }
        if serviceSummary.isChecking { return .accentColor }
        return .secondary
    }

    private var serviceSubtitle: String {
        if serviceSummary.isChecking && !serviceSummary.hasChecked {
            return String.l10n("toolbar.status.services.checking")
        }
        guard serviceSummary.hasChecked else {
            return String.l10n("toolbar.status.services.notChecked")
        }
        if serviceSummary.failedServices.isEmpty {
            return String(
                format: String.l10n("toolbar.status.services.availableFormat"),
                serviceSummary.availableCount,
                serviceSummary.totalCount
            )
        }
        let failed = serviceSummary.failedServices.map(\.rawValue).joined(separator: ", ")
        return String(
            format: String.l10n("toolbar.status.services.failedFormat"),
            serviceSummary.availableCount,
            serviceSummary.totalCount,
            failed
        )
    }

    private var mcpIcon: String {
        if case .failed = mcpState { return "exclamationmark.triangle.fill" }
        if case .running = mcpState { return "network" }
        return "network.slash"
    }

    private var mcpTint: Color {
        if case .failed = mcpState { return .orange }
        if case .running = mcpState { return .green }
        return .secondary
    }

    private var mcpSubtitle: String {
        let statusText: String
        switch mcpState {
        case .running:
            statusText = String.l10n("toolbar.status.mcp.running")
        case .failed(let message):
            statusText = String(format: String.l10n("toolbar.status.mcp.failedFormat"), message)
        case .stopped:
            statusText = mcpEnabled ? String.l10n("toolbar.status.mcp.stopped") : String.l10n("toolbar.status.mcp.disabled")
        }
        return "\(statusText) · \(mcpEndpointURL)"
    }

    private var diagnosticIcon: String {
        diagnosticSummary.issueCount > 0 ? "stethoscope" : "checkmark.seal.fill"
    }

    private var diagnosticTint: Color {
        diagnosticSummary.issueCount > 0 ? .orange : .green
    }

    private var diagnosticSubtitle: String {
        guard diagnosticSummary.issueCount > 0 else {
            return String.l10n("toolbar.status.diagnostics.clean")
        }
        if let latest = diagnosticSummary.latestIssue {
            return String(format: String.l10n("toolbar.status.diagnostics.issueFormat"), diagnosticSummary.issueCount, latest.message)
        }
        return String(format: String.l10n("toolbar.status.diagnostics.countFormat"), diagnosticSummary.issueCount)
    }
}
