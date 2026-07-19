//
//  AppStatusToolbarButton.swift
//  Starcat
//
//  主窗口 toolbar 的全局状态入口。
//
//  设计约束：
//  - 只展示“同步 / 后台任务 / 服务可用性 / MCP / 浏览器插件 / 诊断问题”的轻量概览；
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
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let lastSyncedAt: Date?
    let onShowBatchAIPanel: (() -> Void)?

    @State private var isPresented = false
    @State private var diagnosticSummary: DiagnosticLogSummary = .empty
    /// Toolbar 与设置页必须观察同一个配置实例，端口冲突才能即时反映到全局状态。
    @State private var pluginConfiguration = CompanionConfiguration.shared

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
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
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
                readmePrefetchService: dependencies.readmePrefetchService,
                readmePrefetchEnabled: settings.readmePrefetchEnabled,
                readmePrefetchPoller: dependencies.readmePrefetchPoller,
                initialWarmupCoordinator: dependencies.initialWarmupCoordinator,
                openSSFScorePoller: dependencies.openSSFScorePoller,
                repoHealthPoller: dependencies.repoHealthPoller,
                undoStarCleanup: dependencies.undoStarCleanupScheduler,
                batchService: dependencies.batchAIQueueService,
                mcpState: dependencies.mcpService.state,
                mcpEnabled: settings.mcpServiceEnabled,
                mcpEndpointURL: dependencies.mcpService.endpointURL,
                browserPluginState: pluginConfiguration.serverStatus,
                browserPluginEnabled: pluginConfiguration.isEnabled,
                browserPluginEndpointURL: "http://127.0.0.1:\(pluginConfiguration.port)",
                serviceSummary: dependencies.serviceAvailabilityMonitor.summary,
                diagnosticSummary: diagnosticSummary,
                aiUsageRepository: dependencies.aiUsageRepository,
                relativePastDate: relativePastDate,
                relativeFutureDate: relativeFutureDate,
                onOpenDiagnostics: { openSettings(tab: "diagnostics") },
                onClearDiagnostics: {
                    Task { await clearDiagnostics() }
                },
                onOpenServices: { openSettings(tab: "services") },
                onOpenMCP: { openSettings(tab: "mcp") },
                onOpenBrowserPlugin: { openSettings(tab: "integrations.browserPlugin") },
                onOpenAIUsage: { AIUsageWindowController.show(dependencies: dependencies) },
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
        let batchRemaining = (batch.isRunning || batch.isPaused) ? max(0, batch.totalCount - batch.finishedCount) : 0
        let readme = dependencies.readmePrefetchService
        let readmeRemaining = readme.isRunning
            ? max(0, readme.total - readme.processed)
            : (dependencies.readmePrefetchPoller.isDraining ? 1 : 0)
        let warmup = dependencies.initialWarmupCoordinator
        let warmupRemaining: Int
        if warmup.isActive, let job = warmup.job {
            warmupRemaining = max(0, job.readmeTotal - job.readmeCovered)
                + max(0, warmup.openSSFTotal - warmup.openSSFCovered)
                + max(0, job.healthTotal - job.healthCovered)
        } else {
            warmupRemaining = warmup.isRunning ? 1 : 0
        }
        let openSSF = dependencies.openSSFScorePoller
        let openSSFRemaining = openSSF.isRefreshing
            ? max(1, openSSF.refreshTotal - openSSF.refreshProcessed)
            : 0
        let health = dependencies.repoHealthPoller
        let healthRemaining = health.isRefreshing
            ? max(1, health.refreshTotal - health.refreshProcessed)
            : 0
        return batchRemaining + readmeRemaining + warmupRemaining + openSSFRemaining + healthRemaining
    }

    private var hasIssue: Bool {
        diagnosticSummary.issueCount > 0
            || isMCPFailed
            || isBrowserPluginFailed
            || dependencies.serviceAvailabilityMonitor.summary.hasIssue
            || dependencies.initialWarmupCoordinator.job?.phase == .paused
    }

    private var isMCPFailed: Bool {
        if case .failed = dependencies.mcpService.state { return true }
        return false
    }

    private var isBrowserPluginFailed: Bool {
        if case .failed = pluginConfiguration.serverStatus { return true }
        return false
    }

    private var overallStatusIcon: String {
        if hasIssue { return "exclamationmark.circle.fill" }
        if syncManager.isSyncing || activeTaskCount > 0 { return "arrow.triangle.2.circlepath.circle.fill" }
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
    let readmePrefetchService: ReadmePrefetchService
    let readmePrefetchEnabled: Bool
    let readmePrefetchPoller: ReadmePrefetchPoller
    let initialWarmupCoordinator: InitialRepoWarmupCoordinator
    let openSSFScorePoller: OpenSSFScorePoller
    let repoHealthPoller: RepoHealthPoller
    let undoStarCleanup: UndoStarCleanupScheduler
    let batchService: BatchAIQueueService
    let mcpState: StarcatMCPService.State
    let mcpEnabled: Bool
    let mcpEndpointURL: String
    let browserPluginState: CompanionConfiguration.ServerStatus
    let browserPluginEnabled: Bool
    let browserPluginEndpointURL: String
    let serviceSummary: ServiceAvailabilitySummary
    let diagnosticSummary: DiagnosticLogSummary
    let aiUsageRepository: any AIUsageRepositoryProtocol
    let relativePastDate: (Date) -> String
    let relativeFutureDate: (Date) -> String
    let onOpenDiagnostics: () -> Void
    let onClearDiagnostics: () -> Void
    let onOpenServices: () -> Void
    let onOpenMCP: () -> Void
    let onOpenBrowserPlugin: () -> Void
    let onOpenAIUsage: () -> Void
    let onShowBatchAIPanel: (() -> Void)?

    @State private var isTaskCancelHovered = false
    @State private var aiUsageSummary = AIUsageSummary.empty
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

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
                icon: "chart.bar.xaxis",
                tint: aiUsageSummary.callCount > 0 ? .accentColor : .secondary,
                title: "ai.usage.popover.title",
                subtitle: String(
                    format: String.l10n("ai.usage.popover.summaryFormat"),
                    aiUsageSummary.totalTokens.formatted(.number.notation(.compactName).locale(locale)),
                    aiUsageSummary.callCount
                ),
                accessory: {
                    Button("ai.usage.open") { onOpenAIUsage() }
                        .controlSize(.small)
                        .focusEffectDisabled()
                }
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
                icon: browserPluginIcon,
                tint: browserPluginTint,
                title: "toolbar.status.browserPlugin.title",
                subtitle: browserPluginSubtitle,
                accessory: {
                    Button("toolbar.status.browserPlugin.open") {
                        onOpenBrowserPlugin()
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

            // Undo Star 清理状态（2026-07-05）
            if let lastCleanup = undoStarCleanup.lastCleanupAt {
                let count = undoStarCleanup.lastCleanupCount
                statusRow(
                    icon: "arrow.uturn.backward.circle",
                    tint: .secondary,
                    title: "toolbar.status.undoStar.title",
                    subtitle: count > 0
                        ? String(format: String.l10n("toolbar.status.undoStar.lastCleanupWithCount"), count, relativePastDate(lastCleanup))
                        : String(format: String.l10n("toolbar.status.undoStar.lastCleanup"), relativePastDate(lastCleanup)),
                    accessory: { EmptyView() }
                )
            }
        }
        .task { await loadAIUsageSummary() }
    }

    private func loadAIUsageSummary() async {
        do {
            aiUsageSummary = try await aiUsageRepository.summary(
                filter: AIUsageFilter(timeRange: .today),
                now: Date(),
                calendar: .current
            )
        } catch {
            // 状态 popover 是轻量入口；查询失败不应该再制造一个全局诊断问题。
            aiUsageSummary = .empty
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
                .font(interfaceScale.font(.panelTitle, weight: .semibold))
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
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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

    private var readmePrefetchSubtitle: String {
        guard readmePrefetchEnabled else {
            return String.l10n("toolbar.status.readmePrefetch.disabled")
        }
        switch readmePrefetchService.status {
        case .running:
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.progressFormat"),
                readmePrefetchService.processed,
                readmePrefetchService.total,
                readmePrefetchService.failures
            )
        case .coolingDown(let until):
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.coolingDownFormat"),
                relativeFutureDate(until)
            )
        case .waitingForRetry:
            return String.l10n("settings.storage.readmePrefetch.retrying")
        case .completed:
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.completedFormat"),
                readmePrefetchService.htmlUpdated,
                readmePrefetchService.markdownUpdated,
                readmePrefetchService.notFound,
                readmePrefetchService.failures
            )
        case .allPrefetched(let total):
            return String(
                format: String.l10n("settings.storage.readmePrefetch.allPrefetchedFormat"),
                total
            )
        case .noStarredRepos:
            return String.l10n("settings.storage.readmePrefetch.noStarredRepos")
        case .idle:
            if let lastRunAt = readmePrefetchService.lastRunAt {
                return String(format: String.l10n("toolbar.status.readmePrefetch.lastFormat"), relativePastDate(lastRunAt))
            }
            return String.l10n("toolbar.status.readmePrefetch.waiting")
        case .disabled:
            return String.l10n("toolbar.status.readmePrefetch.disabled")
        }
    }

    private var taskIcon: String {
        if isInitialWarmupPaused || isReadmePrefetchWaitingForRetry || batchService.failedCount > 0 { return "exclamationmark.triangle.fill" }
        if initialWarmupCoordinator.isRunning || openSSFScorePoller.isRefreshing || repoHealthPoller.isRefreshing || readmePrefetchService.isRunning || readmePrefetchPoller.isDraining || batchService.isRunning {
            return "clock.arrow.circlepath"
        }
        if batchService.isPaused { return "pause.circle.fill" }
        return "tray"
    }

    private var taskTint: Color {
        if isInitialWarmupPaused || isReadmePrefetchWaitingForRetry || readmePrefetchService.failures > 0 || batchService.failedCount > 0 { return .orange }
        if initialWarmupCoordinator.isRunning || openSSFScorePoller.isRefreshing || repoHealthPoller.isRefreshing || readmePrefetchService.isRunning || readmePrefetchPoller.isDraining || isReadmePrefetchCoolingDown || batchService.isRunning || batchService.isPaused {
            return .accentColor
        }
        if initialWarmupCoordinator.isCompleted || isReadmePrefetchAllFetched { return .green }
        return .secondary
    }

    private var taskSubtitle: String {
        var lines: [String] = []
        if initialWarmupCoordinator.isActive || initialWarmupCoordinator.isCompleted {
            lines.append(initialWarmupSubtitle)
        }
        if shouldShowReadmePrefetchInTasks {
            lines.append(String(format: String.l10n("toolbar.status.tasks.readmeFormat"), readmePrefetchSubtitle))
        }
        if shouldShowOpenSSFInTasks {
            lines.append(openSSFSubtitle)
        }
        if shouldShowRepoHealthInTasks {
            lines.append(repoHealthSubtitle)
        }
        if batchService.totalCount > 0 {
            lines.append(String(
                format: String.l10n("toolbar.status.tasks.batchAIFormat"),
                batchService.finishedCount,
                batchService.totalCount,
                batchService.failedCount
            ))
        }
        guard !lines.isEmpty else {
            return String.l10n("toolbar.status.tasks.empty")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var taskAccessory: some View {
        HStack(spacing: 6) {
            if hasCancellableBackgroundTask {
                cancellableTaskIndicator
            }
            if batchService.totalCount > 0 {
                Button("toolbar.status.tasks.open") {
                    onShowBatchAIPanel?()
                }
                .controlSize(.small)
                .focusEffectDisabled()
            }
        }
    }

    /// 状态面板只暴露“终止当前这一轮”的能力：
    /// - 不关闭 README / OpenSSF / Health 的周期调度开关；
    /// - 不回滚已经写入的缓存或 AI 结果；
    /// - 对批量 AI 沿用现有 cancel 语义，当前 in-flight job 结束后停止继续取队列。
    private var hasCancellableBackgroundTask: Bool {
        initialWarmupCoordinator.isRunning
            || openSSFScorePoller.isRefreshing
            || repoHealthPoller.isRefreshing
            || readmePrefetchService.isRunning
            || readmePrefetchPoller.isDraining
            || batchService.isRunning
    }

    private var cancellableTaskIndicator: some View {
        Button {
            cancelCurrentBackgroundTask()
        } label: {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .opacity(isTaskCancelHovered ? 0 : 1)
                Image(systemName: "xmark.circle.fill")
                    .font(interfaceScale.font(.iconMedium, weight: .semibold))
                    .foregroundStyle(.red)
                    .opacity(isTaskCancelHovered ? 1 : 0)
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("common.cancel"))
        .onHover { isTaskCancelHovered = $0 }
    }

    private func cancelCurrentBackgroundTask() {
        if initialWarmupCoordinator.isRunning {
            initialWarmupCoordinator.cancel()
        }
        if openSSFScorePoller.isRefreshing {
            openSSFScorePoller.cancelCurrentRefresh()
        }
        if repoHealthPoller.isRefreshing {
            repoHealthPoller.cancelCurrentRefresh()
        }
        if readmePrefetchService.isRunning || readmePrefetchPoller.isDraining {
            readmePrefetchPoller.cancelCurrentRun()
        }
        if batchService.isRunning {
            batchService.cancel()
        }
    }

    private var shouldShowReadmePrefetchInTasks: Bool {
        (readmePrefetchEnabled || readmePrefetchService.isRunning) && !initialWarmupCoordinator.isActive
    }

    private var shouldShowRepoHealthInTasks: Bool {
        repoHealthPoller.isRefreshing || repoHealthPoller.lastRunAt != nil
    }

    private var shouldShowOpenSSFInTasks: Bool {
        (openSSFScorePoller.isRefreshing || openSSFScorePoller.lastRunAt != nil) && !initialWarmupCoordinator.isActive
    }

    private var openSSFSubtitle: String {
        if openSSFScorePoller.isRefreshing {
            return String(
                format: String.l10n("toolbar.status.tasks.openSSFProgressFormat"),
                openSSFScorePoller.refreshProcessed,
                openSSFScorePoller.refreshTotal
            )
        }
        if let lastRunAt = openSSFScorePoller.lastRunAt {
            return String(
                format: String.l10n("toolbar.status.tasks.openSSFLastFormat"),
                openSSFScorePoller.lastRefreshCount,
                relativePastDate(lastRunAt)
            )
        }
        return String.l10n("toolbar.status.tasks.openSSFWaiting")
    }

    private var repoHealthSubtitle: String {
        if repoHealthPoller.isRefreshing {
            return String(
                format: String.l10n("toolbar.status.tasks.repoHealthProgressFormat"),
                repoHealthPoller.refreshProcessed,
                repoHealthPoller.refreshTotal
            )
        }
        if let lastRunAt = repoHealthPoller.lastRunAt {
            return String(
                format: String.l10n("toolbar.status.tasks.repoHealthLastFormat"),
                repoHealthPoller.lastRefreshCount,
                relativePastDate(lastRunAt)
            )
        }
        return String.l10n("toolbar.status.tasks.repoHealthWaiting")
    }

    private var initialWarmupSubtitle: String {
        guard let job = initialWarmupCoordinator.job else {
            return String.l10n("toolbar.status.initialWarmup.waiting")
        }

        switch job.phase {
        case .waiting:
            if let scheduled = job.scheduledAt.flatMap({ ISO8601DateFormatter.shared.date(from: $0) }) {
                return String(
                    format: String.l10n("toolbar.status.initialWarmup.scheduledFormat"),
                    relativeFutureDate(scheduled)
                )
            }
            return String.l10n("toolbar.status.initialWarmup.waiting")
        case .readme:
            return String(
                format: String.l10n("toolbar.status.initialWarmup.progressFormat"),
                job.readmeCovered,
                job.readmeTotal,
                initialWarmupCoordinator.openSSFCovered,
                initialWarmupCoordinator.openSSFTotal,
                job.healthCovered,
                job.healthTotal
            )
        case .openSSF, .health:
            return String(
                format: String.l10n("toolbar.status.initialWarmup.progressFormat"),
                job.readmeCovered,
                job.readmeTotal,
                initialWarmupCoordinator.openSSFCovered,
                initialWarmupCoordinator.openSSFTotal,
                job.healthCovered,
                job.healthTotal
            )
        case .paused:
            if job.lastErrorKind == "rateLimited", let retry = job.nextRetryAt.flatMap({ ISO8601DateFormatter.shared.date(from: $0) }) {
                return String(
                    format: String.l10n("toolbar.status.initialWarmup.rateLimitedFormat"),
                    relativeFutureDate(retry)
                )
            }
            if let retry = job.nextRetryAt.flatMap({ ISO8601DateFormatter.shared.date(from: $0) }) {
                return String(
                    format: String.l10n("toolbar.status.initialWarmup.pausedFormat"),
                    relativeFutureDate(retry)
                )
            }
            return String.l10n("toolbar.status.initialWarmup.paused")
        case .completed:
            return String.l10n("toolbar.status.initialWarmup.completed")
        case .disabled:
            return String.l10n("toolbar.status.readmePrefetch.disabled")
        }
    }

    private var isReadmePrefetchCoolingDown: Bool {
        if case .coolingDown = readmePrefetchService.status { return true }
        return false
    }

    private var isReadmePrefetchWaitingForRetry: Bool {
        if case .waitingForRetry = readmePrefetchService.status { return true }
        return false
    }

    private var isReadmePrefetchAllFetched: Bool {
        if case .allPrefetched = readmePrefetchService.status { return true }
        return false
    }

    private var isInitialWarmupPaused: Bool {
        initialWarmupCoordinator.job?.phase == .paused
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

    private var browserPluginIcon: String {
        if case .failed = browserPluginState { return "exclamationmark.triangle.fill" }
        if case .running = browserPluginState { return "puzzlepiece.extension.fill" }
        return "puzzlepiece.extension"
    }

    private var browserPluginTint: Color {
        if case .failed = browserPluginState { return .orange }
        if case .running = browserPluginState { return .green }
        if case .starting = browserPluginState { return .accentColor }
        return .secondary
    }

    private var browserPluginSubtitle: String {
        let statusText: String
        switch browserPluginState {
        case .running:
            statusText = String.l10n("settings.integration.browserPlugin.status.running")
        case .starting:
            statusText = String.l10n("settings.integration.browserPlugin.status.starting")
        case .failed(let failure):
            statusText = failure.localizedDescription
        case .stopped:
            statusText = browserPluginEnabled
                ? String.l10n("settings.integration.browserPlugin.status.stopped")
                : String.l10n("toolbar.status.browserPlugin.disabled")
        }
        return "\(statusText) · \(browserPluginEndpointURL)"
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
