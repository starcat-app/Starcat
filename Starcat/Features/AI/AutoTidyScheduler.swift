//
//  AutoTidyScheduler.swift
//  Starcat
//
//  HOM-126 - 自动后台 AI 整理调度器。
//
//  模块职责：
//  - 根据 `AutoTidySettings` 监听三类触发源：① App 启动延迟、② 同步完成、③ 定期定时。
//  - 任一触发命中时，从 `RepoRepository.fetchUntagged()` 取未分类 repos，按用户配的
//    排序策略截取前 N 个，调 `BatchAIQueueService.start(..., silent: true)` 静默跑。
//  - 一轮跑完后，把 (applied / ignored / failed / total) 结果写回
//    `AppSettings.autoTidySettings.lastRunAt + lastRunStats`，让设置页只读区展示。
//
//  关键约束 / 已踩过的坑：
//  - **反抖动**：两次自动触发间隔最少 `minTriggerInterval`（默认 5 分钟）。
//    用户短时间手动按多次同步、或同步队列里 ETag 抖动让 `state == .completed` 被
//    多次写入时，避免把 BatchAIQueueService 拉成"刚跑完又被打断"的尴尬态。
//  - **不重入**：若 BatchAIQueueService 已在 `isRunning`（无论是手动 HOM-52 还是上轮
//    自动整理），新触发直接静默忽略——不排队、不打断。下一次触发自然会重新评估。
//  - **设置总开关 OFF**：所有触发分支都先 guard `autoTidySettings.enabled`，
//    用户关闭总开关后**已挂的监听不会主动卸载**（@Observable 自动追踪可观察读，
//    closure 内 guard 足够；卸载监听会引入 disposable 状态机复杂度）。
//  - **生命周期**：调度器由 `AppDependencies` 持有（强引用），监听通过 weak self
//    回调到方法上，避免循环引用。`StarcatApp` 不直接 retain。
//  - **登录态**：未登录时 `RepoRepository.fetchUntagged()` 仍可调（返回 0 条），调度器
//    会自然 no-op。无需额外加 auth gate。
//  - **测试 host**：`TestEnvironment.isRunning == true` 时跳过所有触发（同步完成 /
//    定时器都不响应），避免 xcodebuild test 期间偷跑 AI 调用。
//
//  非目标（HOM-126 明确不做）：
//  - ❌ 持久化队列：自动模式不需要"app 关掉再开继续跑"，重启后启动触发即可重做一轮。
//  - ❌ 强中断：调度器**只发起**整理；面板的 pause / cancel 仍由用户走 BatchAIQueuePanel。
//  - ❌ 跨账号隔离：本地偏好按 UserDefaults 全局存，登出 / 切账号不清空配置（与
//    AISettings 其他偏好策略一致）。
//

import Foundation
import Observation

@MainActor
@Observable
final class AutoTidyScheduler {

    // MARK: - 依赖（构造时注入）

    private let settings: AppSettings
    private let repoRepository: any RepoRepositoryProtocol
    private let batchService: BatchAIQueueService
    private let githubStarListSyncService: GitHubStarListSyncService?
    private let syncManager: SyncManager
    private let entitlementGate: EntitlementGate?

    // MARK: - 内部状态

    /// 上次自动触发的时刻（含被拒绝的触发——只要进入了 `triggerNow` 即记录）。
    /// 用于反抖动判断。第一次触发为 nil，直接通过。
    private(set) var lastTriggerAt: Date?

    /// 最短两次自动触发间隔。HOM-126 要求 5 分钟。
    /// 暴露出来便于测试覆盖（默认值即生产值）。
    private let minTriggerInterval: TimeInterval

    /// 启动后延迟触发的 Task 句柄。app 关闭或 disable 时取消（防止延迟段被 retain）。
    private var launchDelayTask: Task<Void, Never>?

    /// 定期触发的 Timer。仅在 `triggerScheduled == true` 且 `enabled == true` 时存活。
    /// 间隔读自 `autoTidySettings.scheduledIntervalHours`（默认 1 小时）。
    private var scheduledTimer: Timer?

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
        syncManager: SyncManager,
        githubStarListSyncService: GitHubStarListSyncService? = nil,
        entitlementGate: EntitlementGate? = nil,
        minTriggerInterval: TimeInterval = 300
    ) {
        self.settings = settings
        self.repoRepository = repoRepository
        self.batchService = batchService
        self.syncManager = syncManager
        self.githubStarListSyncService = githubStarListSyncService
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
            self?.recordLastRun(completed: completed, ignored: ignored, failed: failed, total: total)
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
        // 仓库分组是独立能力：全局开关打开后固定接 GitHub Stars 同步完成事件，
        // 不再依赖标签分类的「同步后整理」开关。
        guard shouldRunStandardActions || snapshot.generateGitHubListGrouping else { return }
        // 边沿检测：仅在「曾观察到 syncing 且现在 completed」时触发，避免
        // .completed 被反复写入相同时间戳导致的重复触发。
        guard case .completed = newState else { return }
        if case .syncing = lastObservedSyncState {
            AppLog.ai.notice("[autoTidy] trigger via sync completion")
            triggerNow(reason: "sync")
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
                // 仓库分组独立启用后也在启动暖机完成时检查一次，不借用标签分类开关。
                guard shouldRunStandardActions || snapshot.generateGitHubListGrouping else { return }
                AppLog.ai.notice("[autoTidy] trigger via launch delay (60s)")
                self.triggerNow(reason: "launch")
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
        guard settings.autoTidySettings.enabled,
              settings.autoTidySettings.triggerScheduled else { return }
        let interval = settings.autoTidySettings.scheduledIntervalSeconds
        // Timer 在 main runloop 上跑，handler 已经在 @MainActor。
        // `repeats: true` 让它持续触发；卸载靠 invalidate。
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.settings.autoTidySettings.enabled,
                      self.settings.autoTidySettings.triggerScheduled else { return }
                let hours = self.settings.autoTidySettings.scheduledIntervalHours
                AppLog.ai.notice("[autoTidy] trigger via scheduled timer (\(hours, privacy: .public)h)")
                self.triggerNow(reason: "timer")
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
        runOnce(skipDebounce: true, reason: "manual")
    }

    // MARK: - 核心：单轮触发

    /// 走反抖动 + 单轮执行。
    /// 内部 helper：所有自动触发（launch / sync / timer）都经过这里。
    private func triggerNow(reason: String) {
        runOnce(skipDebounce: false, reason: reason)
    }

    private func runOnce(skipDebounce: Bool, reason: String) {
        guard settings.autoTidySettings.hasEnabledBackgroundAction else {
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
        // 反抖动
        if !skipDebounce, let last = lastTriggerAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minTriggerInterval {
                AppLog.ai.debug("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: debounce (elapsed \(Int(elapsed), privacy: .public)s < \(Int(self.minTriggerInterval), privacy: .public)s)")
                return
            }
        }
        // 不重入：HOM-52 手动模式或上一轮自动跑还在跑就让位
        if batchService.isRunning {
            AppLog.ai.debug("[autoTidy] runOnce(\(reason, privacy: .public)) skipped: batchService already running")
            return
        }
        lastTriggerAt = Date()

        Task { [weak self] in
            guard let self else { return }
            await self.executeRound(reason: reason)
        }
    }

    /// 真正执行一轮：拉未分类 → 截取 → 派给 batchService。
    ///
    /// async 而非 fire-and-forget，让"取数据 + 落库前"全部跑在主 actor，避免
    /// 与 HOM-52 手动模式启动的中间态（用户在自动整理刚拉完未分类但还没 start
    /// 时点击手动 banner，可能造成同 repo 出现在两个批次）。
    @MainActor
    private func executeRound(reason: String) async {
        let snapshot = settings.autoTidySettings  // 快照防 setter 在 sleep 期间改值
        let needsStandardActions = snapshot.enabled && snapshot.hasAnyAction
        let needsGitHubListGrouping = snapshot.generateGitHubListGrouping
        let untagged: [Repo]
        let allStarred: [Repo]
        do {
            async let untaggedResult: [Repo] = needsStandardActions
                ? repoRepository.fetchUntagged()
                : []
            async let allStarredResult: [Repo] = needsGitHubListGrouping
                ? repoRepository.fetchAllStarred()
                : []
            untagged = try await untaggedResult
            allStarred = try await allStarredResult
        } catch {
            AppLog.ai.error("[autoTidy] load candidate repos failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // 两类动作的范围不同：摘要/标签仍只处理未打标签仓库，Lists 才覆盖全部 Stars。
        // 先保留原有未分类仓库的处理额度，再用剩余额度补 Lists 候选，避免开启新功能后
        // 较新的已分类仓库把原有 Auto Tidy 的摘要/标签任务长期挤出队列。
        let standardPicked = snapshot.sortOrder.pick(from: untagged, limit: snapshot.maxPerRun)
        let standardPickedIDs = Set(standardPicked.map(\.id))
        let remainingLimit = max(snapshot.maxPerRun - standardPicked.count, 0)
        let groupingOnlyCandidates = allStarred.filter { !standardPickedIDs.contains($0.id) }
        let groupingOnlyPicked = snapshot.sortOrder.pick(from: groupingOnlyCandidates, limit: remainingLimit)
        let picked = standardPicked + groupingOnlyPicked
        guard !picked.isEmpty else {
            AppLog.ai.notice("[autoTidy] executeRound(\(reason, privacy: .public)) no candidate repos, no-op")
            return
        }

        let pickedIDs = Set(picked.map(\.id))
        let standardRepoIDs = standardPickedIDs
        let githubListGrouping = await makeAutomaticGitHubListGroupingConfiguration(
            eligibleRepoIDs: needsGitHubListGrouping ? pickedIDs : []
        )

        // 再次确认 batchService 仍空闲（fetchUntagged 是 async，期间可能有用户手动启动）
        guard !batchService.isRunning else {
            AppLog.ai.debug("[autoTidy] executeRound(\(reason, privacy: .public)) skipped: batchService became running mid-flight")
            return
        }

        let options = snapshot.makeBatchOptions(
            githubListGrouping: githubListGrouping,
            standardActionRepoIDs: standardRepoIDs
        )
        guard options.isValidForStart else {
            AppLog.ai.notice("[autoTidy] executeRound(\(reason, privacy: .public)) no eligible actions, no-op")
            return
        }
        AppLog.ai.notice("[autoTidy] executeRound(\(reason, privacy: .public)) starting: untagged=\(untagged.count, privacy: .public), starred=\(allStarred.count, privacy: .public), picked=\(picked.count, privacy: .public), summary=\(needsStandardActions && snapshot.generateSummary, privacy: .public), tags=\(needsStandardActions && snapshot.generateTags, privacy: .public), lists=\(githubListGrouping != nil, privacy: .public), tagThreshold=\(snapshot.confidenceThreshold, privacy: .public), groupingThreshold=\(snapshot.githubListGroupingConfidenceThreshold, privacy: .public)")
        batchService.start(repos: picked, options: options, silent: true)
    }

    /// 构造后台自动分组的双重授权快照。没有全局开关、没有服务、没有规则或 List 级
    /// 开关关闭时均返回 nil，底层队列因此没有任何 GitHub Lists 写入路径。
    private func makeAutomaticGitHubListGroupingConfiguration(
        eligibleRepoIDs: Set<Int64>
    ) async -> GitHubStarListAIGroupingConfiguration? {
        guard settings.autoTidySettings.generateGitHubListGrouping,
              !eligibleRepoIDs.isEmpty,
              let githubStarListSyncService
        else { return nil }

        do {
            async let listsResult = githubStarListSyncService.allLists()
            async let rulesResult = githubStarListSyncService.allAIRules()
            async let assignmentsResult = githubStarListSyncService.allListAssignments()
            let lists = try await listsResult
            let rules = try await rulesResult
            let assignments = try await assignmentsResult
            let ruleByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            let candidates = lists.compactMap { list -> GitHubStarListAIContext? in
                guard let rule = ruleByID[list.id],
                      rule.autoApplyEnabled,
                      !rule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return GitHubStarListAIContext(
                    listId: list.id,
                    name: list.name,
                    instruction: rule.instruction,
                    autoApplyEnabled: true
                )
            }
            guard !candidates.isEmpty else { return nil }
            return GitHubStarListAIGroupingConfiguration(
                candidates: candidates,
                existingListIDsByRepo: assignments.mapValues { Set($0.map(\.id)) },
                eligibleRepoIDs: eligibleRepoIDs,
                autoApply: true,
                // 仓库分组的远端写入边界独立于标签分类，不能读取标签阈值。
                confidenceThreshold: settings.autoTidySettings.githubListGroupingConfidenceThreshold
            )
        } catch {
            AppLog.ai.error("[autoTidy] load GitHub Lists grouping snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - 写回运行结果

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
