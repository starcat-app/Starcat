//
//  AutoTidyScheduler.swift
//  Starcat
//
//  HOM-126 - 自动后台 AI 整理调度器。
//
//  模块职责：
//  - 根据标签整理与 GitHub Lists 分组各自的设置监听三类触发源：
//    ① App 启动延迟、② 同步完成、③ 定期定时。
//  - 标签整理读取未分类标签的仓库；GitHub Lists 分组只读取未分组仓库，并在进入 AI
//    队列前排除组织 OAuth 不可处理项与本配置下已经分析过的无匹配项。
//  - 一轮跑完后，把 (applied / ignored / failed / total) 结果写回
//    `AppSettings.autoTidySettings.lastRunAt + lastRunStats`，让设置页只读区展示。
//
//  关键约束 / 已踩过的坑：
//  - **反抖动**：两次自动触发间隔最少 `minTriggerInterval`（默认 5 分钟）。
//    用户短时间手动按多次同步、或同步队列里 ETag 抖动让 `state == .completed` 被
//    多次写入时，避免把 BatchAIQueueService 拉成"刚跑完又被打断"的尴尬态。
//  - **不重入**：若 BatchAIQueueService 已在 `isRunning`（无论是手动 HOM-52 还是上轮
//    自动整理），新触发直接静默忽略——不排队、不打断。下一次触发自然会重新评估。
//  - **两套独立总开关**：触发时分别读取标签整理与 GitHub Lists 分组设置；关闭其中
//    一套不会影响另一套。已挂的监听不主动卸载，closure 内按实时设置 guard 即可。
//  - **生命周期**：调度器由 `AppDependencies` 持有（强引用），监听通过 weak self
//    回调到方法上，避免循环引用。`StarcatApp` 不直接 retain。
//  - **登录态**：未登录时仓库查询会自然返回空结果，无需额外增加 auth gate。
//  - **测试 host**：`TestEnvironment.isRunning == true` 时跳过所有触发（同步完成 /
//    定时器都不响应），避免 xcodebuild test 期间偷跑 AI 调用。
//
//  非目标（HOM-126 明确不做）：
//  - ❌ 持久化执行中队列：不会恢复中断的网络请求；仅持久化低置信度或无匹配仓库 ID，
//    避免配置不变时反复分析同一批仓库。分组规则或阈值变化后自动重新评估。
//  - ❌ 强中断：调度器**只发起**整理；面板的 pause / cancel 仍由用户走 BatchAIQueuePanel。
//  - ❌ 跨账号隔离：本地偏好按 UserDefaults 全局存，登出 / 切账号不清空配置（与
//    AISettings 其他偏好策略一致）。
//

import Foundation
import Observation

private struct AutoTidyRequestedActions: OptionSet, Sendable {
    let rawValue: Int

    static let standard = Self(rawValue: 1 << 0)
    static let githubListGrouping = Self(rawValue: 1 << 1)
}

@MainActor
@Observable
final class AutoTidyScheduler {

    // MARK: - 依赖（构造时注入）

    private let settings: AppSettings
    private let repoRepository: any RepoRepositoryProtocol
    private let batchService: BatchAIQueueService
    private let githubStarListGroupingSession: GitHubStarListAIGroupingSession
    private let syncManager: SyncManager
    private let entitlementGate: EntitlementGate?

    // MARK: - 内部状态

    /// 上次自动触发的时刻（含被拒绝的触发——只要进入了 `triggerNow` 即记录）。
    /// 用于反抖动判断。第一次触发为 nil，直接通过。
    private(set) var lastTriggerAt: Date?
    /// 标签整理与仓库分组拥有独立触发配置，因此反抖动时间也必须分开保存。
    private var lastStandardTriggerAt: Date?
    private var lastGroupingTriggerAt: Date?

    /// 最短两次自动触发间隔。HOM-126 要求 5 分钟。
    /// 暴露出来便于测试覆盖（默认值即生产值）。
    private let minTriggerInterval: TimeInterval

    /// 启动后延迟触发的 Task 句柄。app 关闭或 disable 时取消（防止延迟段被 retain）。
    private var launchDelayTask: Task<Void, Never>?

    /// 标签整理的定期触发 Timer。仅在对应定时开关启用时存活。
    private var scheduledTimer: Timer?
    /// GitHub Lists 后台分组使用独立间隔，不能挂靠标签整理的定时器。
    private var githubListGroupingScheduledTimer: Timer?

    /// 上一次观察到的 `SyncState`，用于检测「从 syncing → completed」边沿。
    /// 直接监听 `state == .completed` 会被反复触发（Equatable 包含同一时间戳的多次
    /// 状态写入 -> 实际无变化也会被 onChange 触发一次）。用边沿检测更稳。
    private var lastObservedSyncState: SyncState?

    /// 调度器是否已 `start()` 过。重复调用 start 安全（幂等）。
    private var didStart: Bool = false

    // MARK: - 初始化

    /// - Parameters:
    ///   - settings: 偏好与上次运行结果持久化容器（自动整理 read + write）。
    ///   - repoRepository: 拉未分类仓库的入口。
    ///   - batchService: 实际执行 AI 整理的队列服务（HOM-52）。
    ///   - syncManager: 同步完成时回调触发增量整理。
    ///   - minTriggerInterval: 反抖动间隔，默认 300s（5min）。测试可注入更短值。
    init(
        settings: AppSettings,
        repoRepository: any RepoRepositoryProtocol,
        batchService: BatchAIQueueService,
        githubStarListGroupingSession: GitHubStarListAIGroupingSession,
        syncManager: SyncManager,
        entitlementGate: EntitlementGate? = nil,
        minTriggerInterval: TimeInterval = 300
    ) {
        self.settings = settings
        self.repoRepository = repoRepository
        self.batchService = batchService
        self.githubStarListGroupingSession = githubStarListGroupingSession
        self.syncManager = syncManager
        self.entitlementGate = entitlementGate
        self.minTriggerInterval = minTriggerInterval
    }

    // MARK: - 启停

    /// 启动调度器：装好启动延迟、同步监听、定时器，把"批次结束回调"接到设置写回。
    ///
    /// 设计：
    /// - **幂等**：HomeView `.task` 多次进入也只装一次；防止重复 launchDelayTask。
    /// - **TestEnvironment**：测试 host 跳过整个 start，避免 xcodebuild test 偷跑 AI。
    /// - **接 batchService.onBatchFinished**：BatchAIQueueService 是 HOM-52 的产物，
    ///   `onBatchFinished` 是 HOM-126 新加的回调，本调度器是唯一订阅方（手动模式
    ///   不消费这个回调），所以这里独占赋值是安全的。
    func start() {
        guard !didStart else { return }
        if TestEnvironment.isRunning {
            AppLog.ai.info("[autoTidy] skip start in test host")
            return
        }
        didStart = true

        // 接住批次完成回调，把结果写回 settings.autoTidySettings.lastRunStats
        // **注意**：这是一个全局赋值——手动 HOM-52 的批次结束也会经过这里。
        // 这是有意为之：用户手动跑一次后，自动整理"运行状态"区也能看到最近一次成果，
        // 减少"上次自动跑成果"与"用户实际感知"的不一致。如果未来需要严格区分，
        // 可以读 batchService.silent 决定是否写回（当前不区分）。
        batchService.onBatchFinished = { [weak self] completed, ignored, failed, total in
            guard let self, self.batchService.silent else { return }
            self.recordLastRun(completed: completed, ignored: ignored, failed: failed, total: total)
        }
        githubStarListGroupingSession.onAutomaticSuggestionsDeferred = { [weak self] fingerprint, repoIDs in
            self?.recordDeferredGitHubListGroupingRepositories(
                configurationFingerprint: fingerprint,
                repoIDs: repoIDs
            )
        }

        installLaunchDelay()
        installScheduledTimer()
        // 同步监听由 HomeView `.onChange(of: syncManager.state)` 推过来调用
        // `notifySyncStateChanged(_:)`，不在这里安装 KVO/Combine，理由见该方法文档。

        AppLog.ai.info("[autoTidy] scheduler started")
    }

    /// HomeView 在订阅 syncManager.state 时，每次状态变化都把新值塞过来。
    ///
    /// 为什么不在 scheduler 内部直接观察 `syncManager.state`：
    /// - `@Observable` 的观察必须发生在 SwiftUI body 或 `withObservationTracking` 里，
    ///   scheduler 是 `@Observable` 自身但**没有 view 上下文**，没法稳定订阅另一个
    ///   @Observable 的状态变化（withObservationTracking 只触发一次，需要手动 re-arm，
    ///   产生复杂的状态机）。
    /// - HomeView 已经有 `.task(id: syncManager.state)` / `.onChange(of: ...)` 这种
    ///   原生 SwiftUI 订阅入口，让它把状态变化转发给 scheduler 即可，零额外机制。
    func notifySyncStateChanged(_ newState: SyncState) {
        defer { lastObservedSyncState = newState }
        let snapshot = settings.autoTidySettings
        let shouldRunStandardActions = snapshot.enabled && snapshot.triggerOnSync
        let grouping = settings.githubStarListAutoGroupingSettings
        let shouldRunGrouping = grouping.enabled && grouping.triggerOnSync
        guard shouldRunStandardActions || shouldRunGrouping else { return }
        // 边沿检测：仅在「曾观察到 syncing 且现在 completed」时触发，避免
        // .completed 被反复写入相同时间戳导致的重复触发。
        guard case .completed = newState else { return }
        if case .syncing = lastObservedSyncState {
            AppLog.ai.notice("[autoTidy] trigger via sync completion")
            triggerNow(
                reason: "sync",
                actions: requestedActions(standard: shouldRunStandardActions, grouping: shouldRunGrouping)
            )
        }
    }

    // MARK: - 触发器：启动延迟

    /// 启动后延迟 60s 自动跑一次。
    ///
    /// 设计：
    /// - 用 Task + sleep 而不是 DispatchQueue，方便随调度器生命周期取消。
    /// - 60s 是固定值（HOM-126 任务描述明确），不暴露给用户调。
    /// - sleep 后再次检查 enabled / triggerOnLaunch——用户可能在等待期间关掉开关。
    private func installLaunchDelay() {
        launchDelayTask?.cancel()
        launchDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await MainActor.run {
                guard let self else { return }
                let snapshot = self.settings.autoTidySettings
                let shouldRunStandardActions = snapshot.enabled && snapshot.triggerOnLaunch
                let grouping = self.settings.githubStarListAutoGroupingSettings
                let shouldRunGrouping = grouping.enabled && grouping.triggerOnLaunch
                guard shouldRunStandardActions || shouldRunGrouping else { return }
                AppLog.ai.notice("[autoTidy] trigger via launch delay (60s)")
                self.triggerNow(
                    reason: "launch",
                    actions: self.requestedActions(
                        standard: shouldRunStandardActions,
                        grouping: shouldRunGrouping
                    )
                )
            }
        }
    }

    // MARK: - 触发器：定期 Timer

    /// 安装定期触发定时器。仅在用户开启「定期开启」时生效。
    ///
    /// 设计：
    /// - 不用 `NSBackgroundActivityScheduler`（更省电但 wall-clock 不精确；
    ///   第一版用普通 Timer 调试简单），后续若电量诉求强可再换。
    /// - 触发时间不严格对齐"每天某点"，是「App 运行期间每 N 小时一次」，
    ///   与「启动后触发」叠加 = 开 App 延迟一次 + 之后按间隔再跑，符合前台持续整理语义。
    /// - 间隔变更 / 开关切换由 view 层 `reconfigure()` 立刻重装 Timer。
    private func installScheduledTimer() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        githubListGroupingScheduledTimer?.invalidate()
        githubListGroupingScheduledTimer = nil

        if settings.autoTidySettings.enabled, settings.autoTidySettings.triggerScheduled {
            let interval = settings.autoTidySettings.scheduledIntervalSeconds
            // Timer 在 main runloop 上跑，handler 已经在 @MainActor。
            scheduledTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.settings.autoTidySettings.enabled,
                          self.settings.autoTidySettings.triggerScheduled else { return }
                    let hours = self.settings.autoTidySettings.scheduledIntervalHours
                    AppLog.ai.notice("[autoTidy] trigger standard via scheduled timer (\(hours, privacy: .public)h)")
                    self.triggerNow(reason: "timer", actions: .standard)
                }
            }
        }

        let grouping = settings.githubStarListAutoGroupingSettings
        if grouping.enabled, grouping.triggerScheduled {
            githubListGroupingScheduledTimer = Timer.scheduledTimer(
                withTimeInterval: grouping.scheduledIntervalSeconds,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let current = self.settings.githubStarListAutoGroupingSettings
                    guard current.enabled, current.triggerScheduled else { return }
                    AppLog.ai.notice("[autoTidy] trigger GitHub Lists via scheduled timer (\(current.scheduledIntervalHours, privacy: .public)h)")
                    self.triggerNow(reason: "github-list-timer", actions: .githubListGrouping)
                }
            }
        }
    }

    /// 设置项变更后调用：根据当前 settings 重新装载定期定时器。
    ///
    /// 用户在设置页切「定期开启」/ 改间隔时，HomeView 应在 `.onChange(of:
    /// settings.autoTidySettings)` 调用本方法，让监听跟着 settings 走。
    func reconfigure() {
        // 启动延迟只在 app 启动后跑一次，重新装载意义不大；这里仅重新装定时器，
        // 因为定时器是周期性的、开关 / 间隔切换需要立即生效。
        installScheduledTimer()
        AppLog.ai.debug("[autoTidy] reconfigured (scheduledTimer reinstalled)")
    }

    // MARK: - 手动触发（设置页「立刻手动触发一次」按钮）

    /// 用户在设置页点「立刻手动触发一次」时调用。
    /// 行为：跳过反抖动检查（用户明示意图），但仍走自动模式的范围 / 排序 / silent 配置。
    /// 不复用 HOM-52 手动模式（那个会弹 BatchAIOptionsSheet 让用户选）。
    func triggerManually() {
        AppLog.ai.notice("[autoTidy] trigger via manual button (settings page)")
        runOnce(skipDebounce: true, reason: "manual", actions: .standard)
    }

    // MARK: - 核心：单轮触发

    /// 走反抖动 + 单轮执行。
    /// 内部 helper：所有自动触发（launch / sync / timer）都经过这里。
    private func triggerNow(reason: String, actions: AutoTidyRequestedActions) {
        runOnce(skipDebounce: false, reason: reason, actions: actions)
    }

    private func runOnce(
        skipDebounce: Bool,
        reason: String,
        actions requestedActions: AutoTidyRequestedActions
    ) {
        var actions = enabledActions(from: requestedActions)
        guard !actions.isEmpty else {
            AppLog.ai.debug("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: no action enabled")
            return
        }
        do {
            try entitlementGate?.requirePro(.autoOrganize)
        } catch {
            // 自动整理是后台触发，不能弹 sheet；记录原因并静默跳过，前台设置入口会负责提示。
            AppLog.ai.info("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        if !skipDebounce {
            actions = actionsPassingDebounce(actions)
            guard !actions.isEmpty else {
                AppLog.ai.debug("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: debounce")
                return
            }
        }
        // 不重入：HOM-52 手动模式或上一轮自动跑还在跑就让位
        if batchService.isRunning {
            AppLog.ai.debug("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: batchService already running")
            return
        }
        recordTriggerTime(for: actions)

        Task { [weak self] in
            guard let self else { return }
            await self.executeRound(reason: reason, actions: actions)
        }
    }

    /// 真正执行一轮：拉未分类 → 截取 → 派给 batchService。
    ///
    /// async 而非 fire-and-forget，让"取数据 + 落库前"全部跑在主 actor，避免
    /// 与 HOM-52 手动模式启动的中间态（用户在自动整理刚拉完未分类但还没 start
    /// 时点击手动 banner，可能造成同 repo 出现在两个批次）。
    @MainActor
    private func executeRound(reason: String, actions: AutoTidyRequestedActions) async {
        let snapshot = settings.autoTidySettings  // 快照防 setter 在 sleep 期间改值
        let groupingSnapshot = settings.githubStarListAutoGroupingSettings
        let needsStandardActions = actions.contains(.standard)
            && snapshot.enabled
            && snapshot.hasAnyAction
        let needsGitHubListGrouping = actions.contains(.githubListGrouping)
            && groupingSnapshot.enabled
        let untagged: [Repo]
        let ungrouped: [Repo]
        do {
            async let untaggedResult: [Repo] = needsStandardActions
                ? repoRepository.fetchUntagged()
                : []
            async let ungroupedResult: [Repo] = needsGitHubListGrouping
                ? repoRepository.fetchListPage(
                    scope: .githubStarListUngrouped,
                    filters: .empty,
                    sort: .starredAtDesc,
                    limit: Int.max,
                    offset: 0
                )
                : []
            untagged = try await untaggedResult
            ungrouped = try await ungroupedResult
        } catch {
            AppLog.ai.error("[autoTidy] load candidate repos failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // 两类动作拥有各自范围和执行服务：标签/摘要只处理未打标签仓库；Lists 只处理
        // 未分组仓库。v34 自动忽略和本规则已尝试项由 grouping session 在截取批量前排除。
        let standardPicked = snapshot.sortOrder.pick(from: untagged, limit: snapshot.maxPerRun)
        guard !standardPicked.isEmpty || !ungrouped.isEmpty else {
            AppLog.ai.notice("[autoTidy] executeRound(\(reason, privacy: .public)) no candidate repos, no-op")
            return
        }

        var startedStandardCount = 0
        if needsStandardActions, !standardPicked.isEmpty {
            if batchService.isRunning {
                AppLog.ai.debug("[autoTidy] standard actions skipped: batchService became running mid-flight")
            } else {
                let options = snapshot.makeBatchOptions(standardActionRepoIDs: Set(standardPicked.map(\.id)))
                if options.isValidForStart {
                    let didStart = batchService.start(repos: standardPicked, options: options, silent: true)
                    startedStandardCount = didStart ? standardPicked.count : 0
                }
            }
        }

        var startedGroupingCount = 0
        if needsGitHubListGrouping, !ungrouped.isEmpty {
            if githubStarListGroupingSession.mode == .manual || githubStarListGroupingSession.isRunning {
                AppLog.ai.debug("[autoTidy] GitHub Lists grouping skipped: manual/previous grouping is active")
            } else {
                // 已取消 Star 或已加入分组的仓库无需继续占用 UserDefaults；每轮用当前未分组
                // 集合顺手收缩一次，避免长期使用后 attempted IDs 只增不减。
                let currentUngroupedIDs = Set(ungrouped.map(\.id))
                let activeAttemptedIDs = groupingSnapshot.attemptedRepositoryIDs
                    .intersection(currentUngroupedIDs)
                let result = await githubStarListGroupingSession.startAutomatic(
                    repos: ungrouped,
                    confidenceThreshold: groupingSnapshot.confidenceThreshold,
                    maxPerRun: groupingSnapshot.maxPerRun,
                    sortOrder: groupingSnapshot.sortOrder,
                    attemptedRepositoryIDs: activeAttemptedIDs,
                    previousConfigurationFingerprint: groupingSnapshot.attemptConfigurationFingerprint
                )
                switch result {
                case .unavailable:
                    break
                case .upToDate(let fingerprint):
                    updateGitHubListGroupingAttemptContext(
                        configurationFingerprint: fingerprint,
                        retainedAttemptedRepositoryIDs: activeAttemptedIDs
                    )
                case .started(let fingerprint, let repositoryCount):
                    startedGroupingCount = repositoryCount
                    updateGitHubListGroupingAttemptContext(
                        configurationFingerprint: fingerprint,
                        retainedAttemptedRepositoryIDs: activeAttemptedIDs
                    )
                }
            }
        }
        AppLog.ai.notice("[autoTidy] executeRound(\(reason, privacy: .public)) started: standard=\(startedStandardCount, privacy: .public), grouping=\(startedGroupingCount, privacy: .public), summary=\(needsStandardActions && snapshot.generateSummary, privacy: .public), tags=\(needsStandardActions && snapshot.generateTags, privacy: .public), groupingThreshold=\(groupingSnapshot.confidenceThreshold, privacy: .public)")
    }

    // MARK: - 写回运行结果

    private func requestedActions(standard: Bool, grouping: Bool) -> AutoTidyRequestedActions {
        var actions: AutoTidyRequestedActions = []
        if standard { actions.insert(.standard) }
        if grouping { actions.insert(.githubListGrouping) }
        return actions
    }

    private func enabledActions(from requested: AutoTidyRequestedActions) -> AutoTidyRequestedActions {
        var actions: AutoTidyRequestedActions = []
        if requested.contains(.standard), settings.autoTidySettings.hasEnabledBackgroundAction {
            actions.insert(.standard)
        }
        if requested.contains(.githubListGrouping), settings.githubStarListAutoGroupingSettings.enabled {
            actions.insert(.githubListGrouping)
        }
        return actions
    }

    /// 两套触发器分别反抖动；同一时刻的同步事件仍可一次启动两类任务，而两个独立定时器
    /// 也不会因为其中一个刚触发就永久饿死另一个。
    private func actionsPassingDebounce(
        _ requested: AutoTidyRequestedActions,
        now: Date = .now
    ) -> AutoTidyRequestedActions {
        var actions: AutoTidyRequestedActions = []
        if requested.contains(.standard),
           lastStandardTriggerAt.map({ now.timeIntervalSince($0) >= minTriggerInterval }) ?? true {
            actions.insert(.standard)
        }
        if requested.contains(.githubListGrouping),
           lastGroupingTriggerAt.map({ now.timeIntervalSince($0) >= minTriggerInterval }) ?? true {
            actions.insert(.githubListGrouping)
        }
        return actions
    }

    private func recordTriggerTime(for actions: AutoTidyRequestedActions, now: Date = .now) {
        if actions.contains(.standard) { lastStandardTriggerAt = now }
        if actions.contains(.githubListGrouping) { lastGroupingTriggerAt = now }
        lastTriggerAt = now
    }

    private func updateGitHubListGroupingAttemptContext(
        configurationFingerprint: String,
        retainedAttemptedRepositoryIDs: Set<Int64>
    ) {
        var grouping = settings.githubStarListAutoGroupingSettings
        if grouping.attemptConfigurationFingerprint != configurationFingerprint {
            grouping.attemptedRepositoryIDs = []
        } else {
            grouping.attemptedRepositoryIDs = retainedAttemptedRepositoryIDs
        }
        grouping.attemptConfigurationFingerprint = configurationFingerprint
        settings.githubStarListAutoGroupingSettings = grouping
    }

    private func recordDeferredGitHubListGroupingRepositories(
        configurationFingerprint: String,
        repoIDs: Set<Int64>
    ) {
        var grouping = settings.githubStarListAutoGroupingSettings
        guard grouping.attemptConfigurationFingerprint == configurationFingerprint else { return }
        grouping.attemptedRepositoryIDs.formUnion(repoIDs)
        settings.githubStarListAutoGroupingSettings = grouping
    }

    /// `BatchAIQueueService.onBatchFinished` 回调入口：把本轮成果写回 settings。
    private func recordLastRun(completed: Int, ignored: Int, failed: Int, total: Int) {
        // 全量替换：用户在设置页只读区只看最近一次结果，没有"按轮次"的历史诉求。
        var s = settings.autoTidySettings
        s.lastRunAt = Date()
        s.lastRunStats = AutoTidyLastRunStats(
            total: total,
            applied: completed,
            ignored: ignored,
            failed: failed
        )
        settings.autoTidySettings = s
        AppLog.ai.notice("[autoTidy] last run recorded: applied=\(completed, privacy: .public), ignored=\(ignored, privacy: .public), failed=\(failed, privacy: .public), total=\(total, privacy: .public)")
    }

    // MARK: - UI 派生（Sidebar 轻量指示读这两个）

    /// 当前是否正在跑「自动模式」的整理（区别于用户手动 HOM-52 模式）。
    /// Sidebar 用此判断是否展示「AI 自动整理中 N/M」行。
    var isAutoTidyRunning: Bool {
        batchService.isRunning && batchService.silent
    }

    /// 自动模式下的进度文本（"12/50"）。仅 isAutoTidyRunning == true 时有意义。
    var autoTidyProgressText: String {
        let finished = batchService.finishedCount
        let total = batchService.totalCount
        return "\(finished)/\(total)"
    }

    /// Sidebar popover 需要展示更细的实时计数，但不应该直接依赖 BatchAIQueueService。
    /// 这里保持只读转发，让自动整理的 UI 状态仍由调度器统一收口。
    var autoTidyFinishedCount: Int { batchService.finishedCount }
    var autoTidyTotalCount: Int { batchService.totalCount }
    var autoTidyCompletedCount: Int { batchService.completedCount }
    var autoTidyIgnoredCount: Int { batchService.ignoredCount }
    var autoTidyFailedCount: Int { batchService.failedCount }
}
