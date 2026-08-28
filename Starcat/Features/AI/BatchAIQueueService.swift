//
//  BatchAIQueueService.swift
//  Starcat
//
//  HOM-52 批量未分类仓库 AI 整理 - 队列状态机 + UI 可观察对象。
//
//  模块职责：
//  - 维护单一全局批量整理队列（同时只跑一个批次，避免 AI 配额尖刺）。
//  - 串行处理 jobs：取下一个 queued → 调 RepoAIInsightService.generateInsight
//    → 按 Options 落库标签 → 写终态。
//  - 暴露 @Observable 状态供 BatchAIQueuePanel / 入口 Banner 直接绑定。
//
//  关键约束：
//  - **会话内存级**：队列、进度、失败记录不落库。重启 app 即清空。
//    设计理由：(1) 已生成的 AI 摘要存在 ai_summaries 表，重启后再次整理会命中 cache
//    不重复消耗配额；(2) 落库要新增 batch_ai_jobs 表 + 迁移 + Repository，
//    与 dong4j 强调的"最小代码"冲突；(3) 用户预期的"后台继续"指 panel 关闭后仍跑，
//    而非跨进程恢复——若未来真有需求，再独立 V8 迁移即可。
//  - **串行执行**：一次只处理一个 repo。AI provider 多数有速率限制，且串行能让
//    "暂停"语义干净（当前 job 跑完即停）。如需提速，后续可加 concurrency 配置。
//  - **重试不可重试错误甄别**：API Key 缺失 / Provider 缺失这类配置错误**不消耗重试次数**——
//    用户没改配置之前永远不会成功，重试只会让 panel 失败计数误增。
//

import Foundation
import Observation

@MainActor
@Observable
final class BatchAIQueueService {

    // MARK: - 可观察状态（@Observable 自动生成 didSet / willSet 跟踪）

    /// 当前队列中的所有 jobs（含已完成 / 已失败 / 已忽略 / 仍在排队）。
    /// UI 用 ForEach 直接绑定。新批次开始时整个数组被替换（不保留上一轮记录）。
    private(set) var jobs: [BatchAIJob] = []

    /// 本次启动时的执行配置。空表示当前没有进行中的批次。
    private(set) var options: BatchAIQueueOptions?

    /// 是否正在处理（取出 job → 调 AI → 落库 的整个生命周期内为 true）。
    /// 进入暂停态时为 false，但 jobs 仍保留以便用户继续。
    private(set) var isRunning: Bool = false

    /// 是否被用户暂停。`isRunning && !isPaused` 才会拉下一个 job。
    private(set) var isPaused: Bool = false

    /// HOM-126：本轮是否是「自动后台整理」触发（区别于 HOM-52 用户手动整理）。
    ///
    /// 用途：
    /// - UI 侧观察该标志，决定是否要弹浮动面板 / 强提示横幅。
    ///   静默模式下 HomeView 不自动 `showBatchAIPanel = true`、不弹任何 sheet；
    ///   Sidebar 改用「AI 自动整理中 N/M」轻量行展示进度。
    /// - 服务自身不主动唤起 UI（本来就不持有 UI），所以"静默"语义全部由订阅方实现。
    ///
    /// 生命周期：在 `start(...)` 时设置，`reset()` 清回 false。
    private(set) var silent: Bool = false

    /// 当前正在处理的 job repoId（用于 UI 高亮当前行）。
    private(set) var currentJobId: Int64?

    /// 本次批次的开始时刻，用于估算剩余时间（已用时 / 完成数 → 平均耗时）。
    private(set) var startedAt: Date?

    /// 用户主动取消标志位：与 `runLoopTask.cancel()` 共同表达用户终止意图。
    private var cancelRequested: Bool = false

    /// 当前串行队列 Task。取消句柄会把 cancellation 传给 in-flight AI 请求；
    /// runLoop 仍负责统一收口 job 与 UI 状态，避免调用方直接改写状态机。
    private var runLoopTask: Task<Void, Never>?

    /// 本轮是否已有标签落库，退出 runLoop 时据此合并一次 Sidebar 刷新。
    private var hasPendingTagsChangedNotification: Bool = false

    // MARK: - 依赖（按 AppDependencies 装配顺序注入）

    private let insightService: any BatchAIInsightProviding
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let aiSummaryRepository: any AISummaryRepositoryProtocol
    private let entitlementGate: EntitlementGate?
    private let notificationService: ReleaseNotificationService?

    /// 一批任务内确实应用过标签后，通知外部刷新 Sidebar 计数 / 当前列表。
    ///
    /// 回调只在本轮退出时合并触发一次，不能每完成一个 repo 都做一次全量 Sidebar
    /// 查询。后者会让自动整理期间持续发布十余组 Observable 状态，刚好与分类切换的
    /// SwiftUI diff 叠加，形成整窗动画停顿。
    /// 设计上用闭包而非 NotificationCenter，避免跨模块字符串通知名飘移。
    var onTagsChanged: (() -> Void)?

    /// HOM-126：本轮（自动 / 手动皆触发）全部进入终态后回调。
    ///
    /// `AutoTidyScheduler` 用它把结果（应用/忽略/失败计数）写回 `AutoTidySettings`
    /// 的「运行状态」字段，让设置页只读区展示最近一次自动跑的成果。
    /// 用闭包而非 NotificationCenter 的理由同 `onTagsChanged`。
    ///
    /// 闭包参数：本次结束时的 (completed, ignored, failed, total) 快照。
    /// 仅在 isFinished 触发，cancel 路径不触发（避免污染"上次运行结果"）。
    var onBatchFinished: ((_ completed: Int, _ ignored: Int, _ failed: Int, _ total: Int) -> Void)?

    init(
        insightService: any BatchAIInsightProviding,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        aiSummaryRepository: any AISummaryRepositoryProtocol,
        entitlementGate: EntitlementGate? = nil,
        notificationService: ReleaseNotificationService? = nil
    ) {
        self.insightService = insightService
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.aiSummaryRepository = aiSummaryRepository
        self.entitlementGate = entitlementGate
        self.notificationService = notificationService
    }

    // MARK: - 派生状态（panel UI 用）

    var totalCount: Int { jobs.count }
    var completedCount: Int { jobs.lazy.filter { $0.status == .completed }.count }
    var failedCount: Int { jobs.lazy.filter { $0.status == .failed }.count }
    var ignoredCount: Int { jobs.lazy.filter { $0.status == .ignored }.count }
    var queuedCount: Int { jobs.lazy.filter { $0.status == .queued }.count }
    var finishedCount: Int { completedCount + failedCount + ignoredCount }

    /// 已生成标签但仍需用户在批量窗口内确认的仓库数。
    /// 应用失败仍属于待确认，避免关闭窗口或新开批次时静默丢掉选择。
    var pendingTagReviewCount: Int {
        jobs.lazy.filter { job in
            switch job.tagReviewState {
            case .pending, .applying, .failed:
                true
            case .notRequired, .applied, .ignored:
                false
            }
        }.count
    }

    var hasPendingTagReview: Bool { pendingTagReviewCount > 0 }

    /// 全部 job 都进入终态时认为本次批次结束。
    var isFinished: Bool { !jobs.isEmpty && finishedCount == jobs.count }

    /// 失败列表（按时间倒序），用于 UI 顶部"X 个失败"红色提示与"重试全部"按钮。
    var failedJobs: [BatchAIJob] {
        jobs.filter { $0.status == .failed }
    }

    /// 估算剩余时间（秒）。
    ///
    /// 公式：已用时 / 完成数 × 剩余数。仅当 finishedCount >= 1 才有意义，
    /// 否则返回 nil。AI 调用耗时方差大，UI 端展示用模糊措辞"约 N 分钟"。
    var estimatedTimeRemaining: TimeInterval? {
        guard let startedAt, finishedCount > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let avgPerJob = elapsed / Double(finishedCount)
        let remaining = totalCount - finishedCount
        guard remaining > 0 else { return 0 }
        return avgPerJob * Double(remaining)
    }

    // MARK: - 公共 API

    /// 启动一批新的整理任务。
    ///
    /// 行为：清掉上一批次的 jobs（即使是已完成的）→ 把传入 repos 全部入队 → 启动循环。
    /// 如果当前正在跑且未结束，会被拒绝（调用方应先 cancel）。
    ///
    /// - Parameter silent: HOM-126 新增。`true` 表示由自动调度器触发，
    ///   订阅方（HomeView / 浮动面板 / Banner）应避免主动弹任何 sheet / 强提示；
    ///   Sidebar 改用「AI 自动整理中 N/M」轻量行展示进度。默认 `false` 维持 HOM-52
    ///   手动模式行为不变。
    @discardableResult
    func start(repos: [Repo], options: BatchAIQueueOptions, silent: Bool = false) -> Bool {
        guard !isRunning else {
            AppLog.ai.warning("[batch-ai] start() ignored: already running")
            return false
        }
        guard !hasPendingTagReview else {
            // 人工审核结果只存在当前会话内。新批次直接替换 jobs 会造成不可恢复的数据丢失，
            // 因此必须先回到现有窗口应用或忽略，再允许开始下一轮。
            AppLog.ai.warning("[batch-ai] start() ignored: pending tag review exists")
            return false
        }
        do {
            try entitlementGate?.requirePro(.batchAI)
        } catch {
            // 批量整理可能由 UI 或自动调度器触发。这里做底层硬门控，避免绕过付费墙后
            // 仍能直接启动队列；UI 入口会把同一个错误转换成 ProPaywallSheet。
            AppLog.ai.warning("[batch-ai] start() blocked by entitlement: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard options.isValidForStart, !repos.isEmpty else {
            AppLog.ai.warning("[batch-ai] start() ignored: invalid options or empty repo list")
            return false
        }
        do {
            try validateConfiguration(for: options)
        } catch {
            // 只记录一次批次级配置错误，不能把同一个缺失项扩散成数千条 job 失败。
            AppLog.ai.warning("[batch-ai] start() blocked by AI configuration: \(error.localizedDescription, privacy: .public)")
            return false
        }
        self.options = options
        self.silent = silent
        self.jobs = repos.map { repo in
            BatchAIJob(
                repoId: repo.id,
                repoFullName: repo.fullName,
                repoDescription: repo.description,
                ownerAvatarURL: repo.ownerAvatar
            )
        }
        self.repoCache = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.isPaused = false
        self.isRunning = true
        self.cancelRequested = false
        self.hasPendingTagsChangedNotification = false
        self.startedAt = Date()
        self.currentJobId = nil
        AppLog.ai.notice("[batch-ai] start: count=\(repos.count, privacy: .public), autoApplyTags=\(options.autoApplyTags, privacy: .public), threshold=\(options.confidenceThreshold, privacy: .public), silent=\(silent, privacy: .public)")
        launchRunLoop()
        return true
    }

    /// 整理弹窗的只读预检结果。UI 与 `start()` 复用同一校验入口，避免按钮显示可用，
    /// 点击后却创建整批失败任务。返回值已经本地化，可直接作为错误说明展示。
    func configurationIssue(for options: BatchAIQueueOptions) -> String? {
        guard options.isValidForStart else { return nil }
        do {
            try validateConfiguration(for: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 暂停。当前 job 跑完即停；不杀进行中的 AI 调用（强中断会触发 partial 状态难处理）。
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        AppLog.ai.notice("[batch-ai] paused")
    }

    /// 继续。
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        AppLog.ai.notice("[batch-ai] resumed")
        launchRunLoop()
    }

    /// 取消整批。
    ///
    /// 用户反馈（HOM-52 2026-06-06 17:26 dong4j）：原版本只设标志位，
    /// AI 调用可能要 5-10 秒，用户看不到任何视觉反馈以为"按钮没效果"。
    ///
    /// 当前行为：
    /// 1. **立即清空所有 queued jobs** —— 列表长度立刻下降，给用户可见反馈。
    /// 2. **取消 runLoopTask**，把 cancellation 传给当前 AI / HTTP await。
    /// 3. **派生 isCancelling 状态**供 UI 显示"正在终止..."提示，按钮 disable。
    /// 4. **runLoop 退出时**把残留 processing 状态的 job 标记为 failed("用户取消")，
    ///    避免 UI 上留下"永远在 processing"的孤儿行。
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        isPaused = false
        if let runLoopTask {
            runLoopTask.cancel()
        } else {
            // 暂停态的旧 runLoop 已经退出但 isRunning 仍为 true；重新进入一次循环，
            // 让统一收口逻辑消费 cancelRequested，避免队列永远卡在“正在终止”。
            launchRunLoop()
        }
        // 立即清空所有未开始的 job，给用户立即可见的反馈。
        // 已完成 / 已忽略 / 已失败 / processing 的 job 保留，不破坏历史记录。
        let removed = jobs.filter { $0.status == .queued }.count
        jobs.removeAll { $0.status == .queued }
        AppLog.ai.notice("[batch-ai] cancel requested, cleared \(removed, privacy: .public) queued jobs")
    }

    /// 用户明确启动手动整理时，强制抢占正在运行的自动整理轮次。
    ///
    /// 与面板里的普通 `cancel()` 相同都会取消当前 AI await；这里额外等待旧 runLoop
    /// 完全退出后才返回。调用方随后启动手动批次，保证“用户操作 > 自动后台任务”，
    /// 同时避免两个批次共享同一 jobs / options 状态。
    func preemptAutomaticRunForManualStart() async {
        guard isRunning, silent else { return }
        cancel()
        let task = runLoopTask
        task?.cancel()
        await task?.value
    }

    /// 账号切换时终止任何来源的批次，并清除仅属于旧账号的建议和进度。
    ///
    /// 这里比普通 `cancel()` 更强：必须取消 in-flight AI 请求并等待 runLoop 退出，
    /// 否则旧账号的 GitHub Lists 建议可能在数据库作用域已经切换后才尝试写回。
    func resetForAccountChange() async {
        if isRunning {
            cancel()
            let task = runLoopTask
            task?.cancel()
            await task?.value
        }
        reset()
    }

    /// UI 派生：true 时显示"正在终止当前 AI 调用..."提示。
    /// 触发后 runLoop 正在等待取消传播并收口当前 job，不再等待 Provider 正常完成。
    var isCancelling: Bool { cancelRequested && isRunning }

    /// 重置：清空全部 jobs / options / 进度。
    /// 调用方场景：用户点 panel 的"关闭"按钮且已 finished，或新开一批整理前。
    func reset() {
        guard !isRunning else { return }
        jobs = []
        options = nil
        startedAt = nil
        currentJobId = nil
        cancelRequested = false
        silent = false
        hasPendingTagsChangedNotification = false
    }

    /// 重试单个失败的 job。
    /// - 把 attempts 归零、status 重置为 queued。
    /// - 如果当前循环不在跑（已 finished），重新启动循环。
    func retry(jobId: Int64) {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
        guard jobs[idx].status == .failed else { return }
        jobs[idx].status = .queued
        jobs[idx].attempts = 0
        jobs[idx].failure = nil
        jobs[idx].errorDiagnostic = nil
        jobs[idx].copyDiagnostic = nil
        jobs[idx].finishedAt = nil
        if !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        }
    }

    /// 重试全部失败。批量版本，避免 UI 端循环触发 N 次 runLoop。
    func retryAllFailed() {
        var touched = false
        for idx in jobs.indices where jobs[idx].status == .failed {
            jobs[idx].status = .queued
            jobs[idx].attempts = 0
            jobs[idx].failure = nil
            jobs[idx].errorDiagnostic = nil
            jobs[idx].copyDiagnostic = nil
            jobs[idx].finishedAt = nil
            touched = true
        }
        if touched, !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        }
    }

    // MARK: - 人工标签审核

    /// 切换单个候选标签的选中状态。
    func toggleSuggestedTag(repoId: Int64, suggestionID: String) {
        guard let index = jobs.firstIndex(where: { $0.repoId == repoId }),
              jobs[index].suggestedTags.contains(where: { $0.id == suggestionID })
        else { return }
        switch jobs[index].tagReviewState {
        case .pending, .failed:
            break
        case .notRequired, .applying, .applied, .ignored:
            return
        }

        if jobs[index].selectedSuggestedTagIDs.contains(suggestionID) {
            jobs[index].selectedSuggestedTagIDs.remove(suggestionID)
        } else {
            jobs[index].selectedSuggestedTagIDs.insert(suggestionID)
        }
        // 用户调整选择即开始新一轮审核，清掉上一次应用失败的展示状态。
        jobs[index].tagReviewState = .pending
    }

    func selectAllSuggestedTags(repoId: Int64) {
        guard let index = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
        switch jobs[index].tagReviewState {
        case .pending, .failed:
            jobs[index].selectedSuggestedTagIDs = Set(jobs[index].suggestedTags.map(\.id))
            jobs[index].tagReviewState = .pending
        case .notRequired, .applying, .applied, .ignored:
            return
        }
    }

    func clearSuggestedTagSelection(repoId: Int64) {
        guard let index = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
        switch jobs[index].tagReviewState {
        case .pending, .failed:
            jobs[index].selectedSuggestedTagIDs = []
            jobs[index].tagReviewState = .pending
        case .notRequired, .applying, .applied, .ignored:
            return
        }
    }

    /// 用户明确放弃本仓库的全部候选标签。
    func ignoreSuggestedTags(repoId: Int64) {
        guard let index = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
        switch jobs[index].tagReviewState {
        case .pending, .failed:
            jobs[index].selectedSuggestedTagIDs = []
            jobs[index].tagReviewState = .ignored
        case .notRequired, .applying, .applied, .ignored:
            return
        }
    }

    /// 将用户在单个仓库行内确认的标签落库。
    ///
    /// 与详情页手动应用保持同一语义：先按 canonical key 复用已有标签，确实不存在时
    /// 才创建新标签。每成功一个就从待办集合移除，途中失败后重试不会重复制造记录。
    func applySelectedSuggestedTags(repoId: Int64) async {
        guard let initialIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
        switch jobs[initialIndex].tagReviewState {
        case .pending, .failed:
            break
        case .notRequired, .applying, .applied, .ignored:
            return
        }

        let selectedIDs = jobs[initialIndex].selectedSuggestedTagIDs
        let suggestions = jobs[initialIndex].suggestedTags.filter { selectedIDs.contains($0.id) }
        guard !suggestions.isEmpty else { return }
        jobs[initialIndex].tagReviewState = .applying

        do {
            let tags = try await tagRepository.fetchAll()
            var tagsByCanonicalKey = Dictionary(
                tags.map { (AITagSuggestionPolicy.canonicalKey($0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard let loadedIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            var appliedNames = Set(jobs[loadedIndex].appliedTagNames)

            for suggestion in suggestions {
                try Task.checkCancellation()
                let normalized = AITagSuggestionPolicy.normalizedDisplayName(suggestion.name)
                let key = AITagSuggestionPolicy.canonicalKey(normalized)
                guard !normalized.isEmpty, !key.isEmpty else {
                    if let latestIndex = jobs.firstIndex(where: { $0.repoId == repoId }) {
                        jobs[latestIndex].selectedSuggestedTagIDs.remove(suggestion.id)
                    }
                    continue
                }

                let tag: Tag
                if let existing = tagsByCanonicalKey[key] {
                    tag = existing
                } else {
                    tag = makeUserConfirmedTag(named: normalized)
                    try await tagRepository.create(tag)
                    tagsByCanonicalKey[key] = tag
                }
                try await repoTagRepository.addTag(repoId: repoId, tagId: tag.id)
                appliedNames.insert(tag.name)
                if let latestIndex = jobs.firstIndex(where: { $0.repoId == repoId }) {
                    jobs[latestIndex].selectedSuggestedTagIDs.remove(suggestion.id)
                    jobs[latestIndex].appliedTagNames = appliedNames.sorted()
                }
            }

            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .applied
            onTagsChanged?()
        } catch {
            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .failed(BatchAIFailure(error: error))
        }
    }

    // MARK: - 主循环

    private func launchRunLoop() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
            self.runLoopTask = nil
        }
    }

    /// 串行拉取 queued 的 job 处理，直到全部进入终态、被暂停或被取消。
    ///
    /// 注意：方法本身是 async；start / resume / retry 都 fire-and-forget 调用一次，
    /// 不重入（循环开始时若已无 queued 直接退出）。多次触发只会再 enter 一次循环但
    /// 立刻退出，不会产生并发。
    private func runLoop() async {
        guard let options else { return }

        while true {
            if cancelRequested || Task.isCancelled {
                // 取消：把所有 queued 标 failed("用户取消")？不——保留 queued 状态，
                // 让用户能在终止后继续。取消只意味着退出循环。
                break
            }
            if isPaused { break }
            guard let nextIdx = jobs.firstIndex(where: { $0.status == .queued }) else {
                break
            }

            currentJobId = jobs[nextIdx].repoId
            jobs[nextIdx].status = .processing
            jobs[nextIdx].attempts += 1
            let jobSnapshot = jobs[nextIdx]

            do {
                let result = try await processSingle(jobId: jobSnapshot.repoId, options: options)
                // Provider 可能在最后一个 checkpoint 后正常返回；写库前再确认用户未取消。
                try Task.checkCancellation()
                if cancelRequested { break }
                try await applyResult(jobId: jobSnapshot.repoId, result: result, options: options)
            } catch {
                if cancelRequested || Task.isCancelled || error is CancellationError { break }
                handleFailure(jobId: jobSnapshot.repoId, error: error, options: options)
            }

            currentJobId = nil

            // 每完成一个 job 就让出主线程，让 UI 渲染 panel 进度
            await Task.yield()
        }

        // 循环退出：若全部终态则关掉 isRunning；否则保留状态等用户 resume / cancel。
        if isFinished || cancelRequested || jobs.allSatisfy({ $0.status != .queued }) {
            // 用户取消时，把可能停在 .processing 的孤儿 job 收尾，避免 UI 留"永远转圈"行。
            if cancelRequested {
                let now = Date()
                for idx in jobs.indices where jobs[idx].status == .processing {
                    jobs[idx].status = .failed
                    jobs[idx].failure = .cancelled
                    jobs[idx].errorDiagnostic = nil
                    jobs[idx].copyDiagnostic = nil
                    jobs[idx].finishedAt = now
                }
            }
            isRunning = false
            currentJobId = nil
            notifyTagsChangedIfNeeded()
            if isFinished {
                AppLog.ai.notice("[batch-ai] finished: completed=\(self.completedCount, privacy: .public), ignored=\(self.ignoredCount, privacy: .public), failed=\(self.failedCount, privacy: .public)")
                // HOM-126：仅在自然 finished（不是 cancel）时通知订阅方写回结果，
                // 让"上次运行状态"反映用户**完整跑完**的成果。cancel 时不触发，
                // 避免半截结果污染 AutoTidySettings.lastRunStats。
                onBatchFinished?(completedCount, ignoredCount, failedCount, totalCount)
                await notificationService?.dispatchBatchAIFinished(
                    completed: completedCount,
                    ignored: ignoredCount,
                    failed: failedCount,
                    total: totalCount
                )
            }
        }
    }

    // MARK: - 单 job 处理

    /// 处理单个 repo 的执行结果（成功路径携带的产出）。
    ///
    /// 注：`existingTagHints` 当前在 `applyResult` 内未被读取，属于历史遗留 dead 字段。
    /// 2026-06-14 hints 类型从 `[String]` 升级到 `AITagHints` 时同步升级该字段类型保持
    /// 编译，未在本次手术中删除（不擅自清理 pre-existing dead code）。
    private struct JobOutcome {
        var insight: RepoAIInsightGeneration?
        var repo: Repo
        var existingTagHints: AITagHints
    }

    /// 调 RepoAIInsightService 拉取摘要 / 标签建议；本方法**不写库**，
    /// 决策（写哪些标签 / 标 ignored）放在 applyResult 里。
    private func processSingle(jobId: Int64, options: BatchAIQueueOptions) async throws -> JobOutcome {
        // 通过 insightService 拿不到原 Repo，HomeView 进入 batch 前已经把 repos 传给 start()，
        // jobs 里只存了 repoId + fullName。这里我们需要 Repo（generateInsight 要 description / topics）。
        // 折中方案：再从 RepoTagRepository 借用全表标签做 hints（已有 fetchAll API），
        // 而 Repo 本身改由调用方 enqueue 时打包好——但为了不污染 BatchAIJob 字段过宽，
        // 这里改成 enqueue 时同时持有 [Repo]。
        guard let repo = repoCache[jobId] else {
            throw RepoAIInsightError.invalidJSON  // 复用现有 error 类型；不应发生
        }

        // 标签生成 hints：repo 自身标签（强信号）+ 字符预算内的全库复用词表。
        // 与单仓 AI 摘要应用标签路径（RepoAIInsightViewModel.generate）共享
        // `RepoAIInsightService.makeTagHints` 工厂方法，信号源单一信任源；
        // 详细约束见 `AITagHints` + `makeTagHints` 注释。
        // includeTags == false 时跳过构造，节省两次 DB 查询。
        //
        // 2026-06-14 修订（dong4j 反馈）：原版只用 `tagRepository.fetchAll().prefix(50).map(\.name)`，
        // 漏掉了 repo 自身标签——这些 repo 专属标签往往不在全局 Top 50 里，AI 看不到 →
        // 大概率生成同义新标签，与用户已有的 repo 标签重复。helper 现在显式拉 repo 自身标签
        // 单独排前面强信号注入，全库标签按使用频率排序、canonical 去重后作为复用词表。
        let hints: AITagHints
        if options.shouldRun(.tags, forRepoID: jobId) {
            hints = await RepoAIInsightService.makeTagHints(
                for: repo,
                repoTagRepository: repoTagRepository,
                tagRepository: tagRepository
            )
        } else {
            hints = .empty
        }

        let includesSummary = options.shouldRun(.summary, forRepoID: jobId)
        let includesTags = options.shouldRun(.tags, forRepoID: jobId)
        let insight: RepoAIInsightGeneration?
        if includesSummary || includesTags {
            insight = try await insightService.generateBatchInsight(
                for: repo,
                existingTagHints: hints,
                includeSummary: includesSummary,
                includeTags: includesTags,
                // 标签单独运行时不需要摘要上下文，避免无意义地准备代码或外部搜索。
                codeContextEnabledOverride: includesSummary ? options.codeContextEnabledOverride : nil,
                externalContextEnabledOverride: includesSummary ? options.externalContextEnabledOverride : nil
            )
        } else {
            insight = nil
        }

        return JobOutcome(
            insight: insight,
            repo: repo,
            existingTagHints: hints
        )
    }

    /// 在创建 jobs 前一次性校验本批次会调用到的任务配置。
    ///
    /// 校验必须留在 Service 层：手动弹窗和自动调度器都能启动队列，只在 UI 禁用按钮
    /// 会留下绕过路径。`ensureGenerationClientsReady` 只构造客户端，不发网络请求。
    private func validateConfiguration(for options: BatchAIQueueOptions) throws {
        try insightService.ensureGenerationClientsReady(
            includeSummary: options.actions.contains(.summary),
            includeTags: options.actions.contains(.tags)
        )
    }

    /// 把 processSingle 的产出按 Options 落库 + 写 job 终态。
    ///
    /// async 而非 fire-and-forget：主循环必须等"落库 + 写终态"全部完成，
    /// 否则下一轮 currentJobId 切换时，前一个 job 仍停在 .processing，UI 出现"两个 processing"假象。
    private func applyResult(jobId: Int64, result: JobOutcome, options: BatchAIQueueOptions) async throws {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let suggestions = result.insight?.insight.suggestedTags ?? []
        let didSummary = options.shouldRun(.summary, forRepoID: jobId)
        let didTags = options.shouldRun(.tags, forRepoID: jobId)
        var shouldMarkIgnored = false

        if didTags {
            jobs[idx].suggestedTags = suggestions
            // 只有用户主动打开的批量窗口承载人工审核。静默自动整理仍沿用原有后台语义，
            // 不能在 Sidebar 留下一批用户没有主动创建、也无法感知来源的待确认任务。
            if !silent, !options.autoApplyTags, !suggestions.isEmpty {
                jobs[idx].selectedSuggestedTagIDs = Set(suggestions.map(\.id))
                jobs[idx].tagReviewState = .pending
            }
        }

        // 标签子分支：
        // - 没勾选标签 → 直接 completed（summary 已写）。
        // - 勾选 + autoApply=true → 按置信度阈值过滤后落库；全部低于阈值 → ignored；否则 completed。
        // - 勾选 + autoApply=false → 标签建议保留在当前批量会话中，由用户在同一窗口逐仓确认。
        //   这种情况 status = completed（生成任务本身已完成），审核进度由 tagReviewState 单独表达。
        if didTags, options.autoApplyTags {
            let belowThreshold = suggestions.filter { $0.confidence < options.confidenceThreshold }
            let aboveThreshold = suggestions.filter { $0.confidence >= options.confidenceThreshold }

            if aboveThreshold.isEmpty, !suggestions.isEmpty {
                jobs[idx].ignoredTagsBelowThreshold = belowThreshold.map { ($0.name, $0.confidence) }
                shouldMarkIgnored = true
            } else {
                let appliedNames = await applyTagsToRepo(repoId: jobId, suggestions: aboveThreshold)
                guard let currentIndex = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
                jobs[currentIndex].appliedTagNames = appliedNames
                jobs[currentIndex].ignoredTagsBelowThreshold = belowThreshold.map { ($0.name, $0.confidence) }
                if !appliedNames.isEmpty {
                    hasPendingTagsChangedNotification = true
                }
            }
        }

        guard let finalIndex = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
        jobs[finalIndex].didGenerateSummary = didSummary
        jobs[finalIndex].finishedAt = Date()
        let wroteAnything = !jobs[finalIndex].appliedTagNames.isEmpty
        jobs[finalIndex].status = shouldMarkIgnored && !didSummary && !wroteAnything ? .ignored : .completed
    }

    /// 为用户明确确认的新标签补齐与详情页一致的默认视觉属性。
    private func makeUserConfirmedTag(named name: String) -> Tag {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let visual = TagAutoVisual.pick(for: name)
        return Tag(
            id: UUID().uuidString,
            name: name,
            color: visual.colorHex,
            icon: visual.iconName,
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 合并发布标签变更。自然完成与取消都会走这里：取消前已经落库的标签也必须最终
    /// 刷新一次，但暂停仍保留 pending，等恢复后的同一轮真正退出再发布。
    private func notifyTagsChangedIfNeeded() {
        guard hasPendingTagsChangedNotification else { return }
        hasPendingTagsChangedNotification = false
        onTagsChanged?()
    }

    /// 把通过阈值过滤的建议落库为 repo_tags 关联，但只允许复用已有标签。
    ///
    /// 批量自动应用没有逐项人工确认，不能因为模型自报高置信度就静默扩张标签库；真正的
    /// 新标签仍保留在 AI 建议里，用户可回到详情页手动确认。这里使用宽松 canonical key，
    /// 让 `Open-Source` / `open source` 等形式差异复用已有记录。
    private func applyTagsToRepo(repoId: Int64, suggestions: [AITagSuggestion]) async -> [String] {
        let existingTags: [Tag]
        do {
            existingTags = try await tagRepository.fetchAll()
        } catch {
            AppLog.ai.error("[batch-ai] load existing tags failed: repo=\(repoId, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            return []
        }

        var existingTagByName: [String: Tag] = [:]
        var existingTagByKey: [String: Tag] = [:]
        for tag in existingTags {
            existingTagByName[tag.name] = tag
            let key = AITagSuggestionPolicy.canonicalKey(tag.name)
            guard !key.isEmpty, existingTagByKey[key] == nil else { continue }
            existingTagByKey[key] = tag
        }

        var applied: [String] = []
        for suggestion in suggestions {
            let normalized = AITagSuggestionPolicy.normalizedDisplayName(suggestion.name)
            let key = AITagSuggestionPolicy.canonicalKey(normalized)
            guard !normalized.isEmpty,
                  let tag = existingTagByName[normalized] ?? existingTagByKey[key]
            else {
                AppLog.ai.notice("[batch-ai] skip new tag during auto-apply: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public)")
                continue
            }
            do {
                try await repoTagRepository.addTag(repoId: repoId, tagId: tag.id)
                applied.append(tag.name)
            } catch {
                AppLog.ai.error("[batch-ai] apply tag failed: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return applied
    }

    /// 处理单个 job 的失败：分流"重试" vs "终态失败"。
    private func handleFailure(jobId: Int64, error: Error, options: BatchAIQueueOptions) {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )
        let failure = BatchAIFailure(error: error)
        let shortMessage = failure.localizedMessage
        let copyDiagnostic = Self.copyFailureDiagnostic(
            for: error,
            friendly: friendly,
            shortMessage: shortMessage
        )
        let diagnostic = Self.displayFailureDiagnostic(
            from: copyDiagnostic,
            shortMessage: shortMessage
        )
        // 完整 payload 只能在用户主动复制时使用，不能写入持久化日志或 Console。
        AppLog.ai.error(
            "[batch-ai] job failed: repo=\(jobId, privacy: .public), attempt=\(self.jobs[idx].attempts, privacy: .public), error=\(shortMessage, privacy: .public)"
        )
        friendly.record(category: "ai", operation: "batchAI.job", service: "ai-provider")

        if isPermanentError(error) || jobs[idx].attempts >= options.maxRetries {
            jobs[idx].status = .failed
            jobs[idx].failure = failure
            jobs[idx].errorDiagnostic = diagnostic
            jobs[idx].copyDiagnostic = copyDiagnostic
            jobs[idx].finishedAt = Date()
        } else {
            // 可重试：回退到 queued，主循环下一轮会重新拉取（重试次数已在 processNext 入口 +1）。
            jobs[idx].status = .queued
        }
    }

    /// 测试与非 UI 调用方共用入口；实际 job 只保存 `BatchAIFailure`，不缓存本地化结果。
    static func userVisibleFailureMessage(for error: Error) -> String {
        BatchAIFailure(error: error).localizedMessage
    }

    /// 可展开详情：只保留结构化摘要，不包含 Request / Response payload。
    static func failureDiagnostic(
        for error: Error,
        friendly: UserFacingError,
        shortMessage: String
    ) -> String? {
        displayFailureDiagnostic(
            from: copyFailureDiagnostic(for: error, friendly: friendly, shortMessage: shortMessage),
            shortMessage: shortMessage
        )
    }

    /// 复制专用完整诊断：保留格式化 Request / Response JSON。
    static func copyFailureDiagnostic(
        for error: Error,
        friendly: UserFacingError,
        shortMessage: String
    ) -> String? {
        if let ai = error as? AIClientError, let detail = ai.diagnosticDetail {
            let redacted = DiagnosticEvent.redact(detail)
            guard redacted != shortMessage, !redacted.isEmpty else { return nil }
            return redacted
        }
        let summary = friendly.diagnosticSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary != shortMessage else { return nil }
        if summary.count > 1200 {
            return String(summary.prefix(1197)) + "…"
        }
        return summary
    }

    /// 从完整诊断中裁掉 payload，只把轻量 HTTP 摘要交给展开区渲染。
    static func displayFailureDiagnostic(from diagnostic: String?, shortMessage: String) -> String? {
        guard let diagnostic = diagnostic?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !diagnostic.isEmpty
        else { return nil }

        let payloadMarkers = ["\n\nResponse JSON:", "\n\nRequest JSON:"]
        let firstPayload = payloadMarkers
            .compactMap { diagnostic.range(of: $0)?.lowerBound }
            .min()
        let display = firstPayload.map { String(diagnostic[..<$0]) } ?? diagnostic
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != shortMessage else { return nil }
        return trimmed
    }

    /// 复制到剪贴板的完整失败报告：仓库 + 用户文案 + 诊断详情。
    static func copyableFailureReport(
        repoFullName: String,
        message: String?,
        diagnostic: String?
    ) -> String {
        var lines: [String] = []
        let repo = repoFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repo.isEmpty {
            lines.append(String(format: String.l10n("batchAI.panel.report.repoFormat"), repo))
        }
        let short = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty {
            lines.append(String(format: String.l10n("batchAI.panel.report.messageFormat"), short))
        }
        let detail = (diagnostic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }

    /// 不可重试错误判别：用户没改配置之前永远会失败的那一类。
    private func isPermanentError(_ error: Error) -> Bool {
        if let insight = error as? RepoAIInsightError {
            switch insight {
            case .missingAPIKey, .missingProvider:
                return true
            case .invalidJSON:
                return false
            }
        }
        if let ai = error as? AIClientError {
            switch ai {
            case .missingAPIKey, .invalidBaseURL, .authenticationRejected, .paymentRequired:
                return true
            case .invalidChatHistory, .emptyResponse, .responseTruncated, .modelListRequestFailed,
                 .rateLimited, .requestRejected, .networkUnavailable, .timedOut, .requestFailed:
                return false
            }
        }
        return false
    }

    // MARK: - Repo 缓存（避免每次 processSingle 都查库）

    /// repoId → Repo 的会话内缓存。由 start() 时填充。
    private var repoCache: [Int64: Repo] = [:]
}
