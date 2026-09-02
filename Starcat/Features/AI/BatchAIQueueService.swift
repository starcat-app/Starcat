//
//  BatchAIQueueService.swift
//  Starcat
//
//  HOM-52 批量未分类仓库 AI 整理 - 队列状态机 + UI 可观察对象。
//
//  模块职责：
//  - 维护单一全局批量整理队列，并用有界并发避免 AI 配额尖刺。
//  - 每个仓库都是独立队列任务，由固定数量 Worker 并发领取，完成后立即回写并继续取下一项。
//  - AI 结果可乱序返回，但任务领取、落库与 Observable 状态整合始终收口在 MainActor。
//  - 暴露 @Observable 状态供 BatchAIQueuePanel / 入口 Banner 直接绑定。
//
//  关键约束：
//  - **会话内存级**：队列、进度、失败记录不落库。重启 app 即清空。
//    设计理由：(1) 已生成的 AI 摘要存在 ai_summaries 表，重启后再次整理会命中 cache
//    不重复消耗配额；(2) 落库要新增 batch_ai_jobs 表 + 迁移 + Repository，
//    与 dong4j 强调的"最小代码"冲突；(3) 用户预期的"后台继续"指 panel 关闭后仍跑，
//    而非跨进程恢复——若未来真有需求，再独立 V8 迁移即可。
//  - **有界并发**：暂停只阻止下一波派发，终止则取消整组 in-flight Task；429 会临时
//    降为单路并发，避免为了吞吐量把 Provider 推入持续限流。
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
    /// 展示层通过分页快照读取；新批次开始时整个数组被替换（不保留上一轮记录）。
    private(set) var jobs: [BatchAIJob] = [] {
        didSet { presentationRevision &+= 1 }
    }

    /// 列表层只观察轻量 revision，再按帧合并生成当前分页范围内的展示快照。
    private(set) var presentationRevision: UInt64 = 0

    /// 用户在审核列表左侧勾选、准备参与批量应用的仓库。
    ///
    /// 这与 `BatchAIJob.selectedSuggestedTagIDs` 是两个层级：前者决定应用哪些仓库，
    /// 后者决定每个仓库应用哪些标签。状态必须归队列会话持有，才能跨搜索、分页和关窗重开保留。
    private(set) var selectedRepoIDsForTagApplication: Set<Int64> = [] {
        didSet { presentationRevision &+= 1 }
    }

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
    ///   静默模式下 HomeView 不自动展示批量标签工作区；
    ///   Sidebar 改用「AI 自动整理中 N/M」轻量行展示进度。
    /// - 服务自身不主动唤起 UI（本来就不持有 UI），所以"静默"语义全部由订阅方实现。
    ///
    /// 生命周期：在 `start(...)` 时设置，`reset()` 清回 false。
    private(set) var silent: Bool = false

    /// 当前 Worker 正在处理的 repo id；数量不会超过 `defaultConcurrency`。
    private(set) var processingJobIDs: Set<Int64> = []

    /// 本次批次的开始时刻，用于估算剩余时间（已用时 / 完成数 → 平均耗时）。
    private(set) var startedAt: Date?

    /// 用户主动取消标志位：与 `runLoopTask.cancel()` 共同表达用户终止意图。
    private var cancelRequested: Bool = false

    /// 当前队列 Task。取消句柄会把 cancellation 传给整波 in-flight AI 请求；
    /// runLoop 仍负责统一收口 job 与 UI 状态，避免调用方直接改写状态机。
    private var runLoopTask: Task<Void, Never>?

    /// 批次级全库标签词表快照；每轮只查询一次，避免逐仓重复扫描标签表和使用次数。
    private var sharedTagLibrary: [String]?

    /// 批次启动时标签库的完整 canonical key 快照，用于给审核 Chip 标注“已有 / 新标签”。
    /// 与给模型的 `sharedTagLibrary` 分开保存：后者受字符预算截断，不能作为来源判断依据。
    private var initialTagCanonicalKeys: Set<String>?

    /// 同一批次的多个 Worker 可能同时遇到同一个新标签。按 canonical key 共享创建任务，
    /// 保证只创建一次，其余 Worker 复用同一结果，避免并发 UNIQUE 冲突和同义写法重复建标。
    private var pendingTagCreationsByCanonicalKey: [String: Task<Tag, Error>] = [:]

    /// 可重试失败的最早再次执行时刻，避免 429 / 5xx 立即空转轰炸 Provider。
    private var retryNotBeforeByRepoID: [Int64: Date] = [:]

    /// 遇到 429 后的临时单路窗口；窗口结束后恢复默认 5 路并发。
    private var rateLimitCooldownUntil: Date?

    /// 本轮是否已有标签落库，退出 runLoop 时据此合并一次 Sidebar 刷新。
    private var hasPendingTagsChangedNotification: Bool = false

    // MARK: - 依赖（按 AppDependencies 装配顺序注入）

    private let insightService: any BatchAIInsightProviding
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let aiSummaryRepository: any AISummaryRepositoryProtocol
    private let entitlementGate: EntitlementGate?
    private let notificationService: ReleaseNotificationService?

    /// 正常状态下保留 5 个长驻 Worker；每个 Worker 完成一个仓库后立即领取下一项。
    private static let defaultConcurrency = 5
    private static let rateLimitCooldown: TimeInterval = 30

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

    /// 当前真正可以由“应用选中项”处理的仓库 ID。
    /// 用户可以保留仓库勾选但暂时清空其标签；这种行不计入底栏有效选择，也不会触发空应用。
    var effectiveSelectedRepoIDsForTagApplication: Set<Int64> {
        Set(jobs.compactMap { job in
            guard selectedRepoIDsForTagApplication.contains(job.repoId),
                  !job.selectedSuggestedTagIDs.isEmpty
            else { return nil }
            switch job.tagReviewState {
            case .pending, .failed:
                return job.repoId
            case .notRequired, .applying, .applied, .ignored:
                return nil
            }
        })
    }

    var selectedTagReviewRepositoryCount: Int {
        effectiveSelectedRepoIDsForTagApplication.count
    }

    var selectedTagReviewTagCount: Int {
        let effectiveRepoIDs = effectiveSelectedRepoIDsForTagApplication
        return jobs.lazy
            .filter { effectiveRepoIDs.contains($0.repoId) }
            .reduce(into: 0) { $0 += $1.selectedSuggestedTagIDs.count }
    }

    /// 标签正在写入数据库时不能丢弃会话，否则 UI 状态虽已清空，异步写入仍可能继续完成。
    var isApplyingSuggestedTags: Bool {
        jobs.contains { job in
            if case .applying = job.tagReviewState { true } else { false }
        }
    }

    /// 手动任务关闭后仍值得保留的内容：未处理队列、分析失败或待确认/应用失败的标签。
    /// 自动后台任务由调度器记录结果，不应反过来阻塞用户发起新的手动整理。
    var hasUnresolvedManualWork: Bool {
        guard !silent, !jobs.isEmpty else { return false }
        return jobs.contains { job in
            switch job.status {
            case .queued, .processing, .failed:
                return true
            case .completed, .ignored:
                break
            }
            switch job.tagReviewState {
            case .pending, .applying, .failed:
                return true
            case .notRequired, .applied, .ignored:
                return false
            }
        }
    }

    /// 运行中的 Worker 必须先终止；标签应用中的会话则等待本次数据库写入收口。
    var canDiscardCurrentSession: Bool {
        !isRunning && !isApplyingSuggestedTags && hasUnresolvedManualWork
    }

    /// 全部 job 都进入终态时认为本次批次结束。
    var isFinished: Bool { !jobs.isEmpty && finishedCount == jobs.count }

    var isManualSessionResolved: Bool {
        !silent
            && !jobs.isEmpty
            && !isRunning
            && !isApplyingSuggestedTags
            && !hasUnresolvedManualWork
    }

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
        guard !hasUnresolvedManualWork else {
            // 人工审核与失败结果只存在当前会话内。新批次直接替换 jobs 会造成不可恢复的数据丢失，
            // 因此必须先回到现有窗口处理或明确放弃，再允许开始下一轮。
            AppLog.ai.warning("[batch-ai] start() ignored: unresolved manual session exists")
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
        self.selectedRepoIDsForTagApplication = []
        self.repoCache = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.isPaused = false
        self.isRunning = true
        self.cancelRequested = false
        self.hasPendingTagsChangedNotification = false
        self.startedAt = Date()
        self.processingJobIDs = []
        self.sharedTagLibrary = nil
        self.initialTagCanonicalKeys = nil
        self.pendingTagCreationsByCanonicalKey = [:]
        self.retryNotBeforeByRepoID = [:]
        self.rateLimitCooldownUntil = nil
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
        selectedRepoIDsForTagApplication = []
        options = nil
        startedAt = nil
        processingJobIDs = []
        cancelRequested = false
        silent = false
        hasPendingTagsChangedNotification = false
        sharedTagLibrary = nil
        initialTagCanonicalKeys = nil
        pendingTagCreationsByCanonicalKey = [:]
        retryNotBeforeByRepoID = [:]
        rateLimitCooldownUntil = nil
        repoCache = [:]
    }

    /// 放弃当前批次的内存态结果，让用户可以立即开始下一批整理。
    ///
    /// 已经写入数据库的标签与摘要不属于队列内存，必须保留；这里只清除尚未应用的建议、
    /// 失败记录和进度。返回 false 表示 Worker 或标签落库仍在执行，调用方应保持窗口不变。
    @discardableResult
    func discardCurrentSession() -> Bool {
        guard canDiscardCurrentSession else { return false }
        reset()
        return true
    }

    /// 完整结果在窗口打开期间保留供复查；窗口关闭或下一轮配置出现时再清理。
    @discardableResult
    func finishManualSessionIfResolved() -> Bool {
        guard isManualSessionResolved else { return false }
        reset()
        return true
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
        retryNotBeforeByRepoID[jobId] = nil
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
            retryNotBeforeByRepoID[jobs[idx].repoId] = nil
            touched = true
        }
        if touched, !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        }
    }

    /// “失败”Tab 同时收纳生成失败和人工应用失败；批量重试必须覆盖两条恢复路径。
    /// 先串行重试标签落库，避免它与重新启动的 AI Worker 同时修改同一会话状态。
    func retryAllFailures() async {
        guard !isRunning, !isApplyingSuggestedTags else { return }
        let reviewFailureRepoIDs = jobs.compactMap { job -> Int64? in
            if case .failed = job.tagReviewState { return job.repoId }
            return nil
        }
        for repoID in reviewFailureRepoIDs {
            guard !Task.isCancelled else { return }
            await applySelectedSuggestedTags(repoId: repoID)
        }
        retryAllFailed()
    }

    // MARK: - 人工标签审核

    /// 切换仓库是否参与底栏“应用选中项”。只有仍可审核且至少保留一个标签的行可被勾选。
    func toggleRepoForTagApplication(repoId: Int64) {
        guard let job = jobs.first(where: { $0.repoId == repoId }),
              !job.selectedSuggestedTagIDs.isEmpty
        else { return }
        switch job.tagReviewState {
        case .pending, .failed:
            if selectedRepoIDsForTagApplication.contains(repoId) {
                selectedRepoIDsForTagApplication.remove(repoId)
            } else {
                selectedRepoIDsForTagApplication.insert(repoId)
            }
        case .notRequired, .applying, .applied, .ignored:
            return
        }
    }

    func isRepoSelectedForTagApplication(repoId: Int64) -> Bool {
        selectedRepoIDsForTagApplication.contains(repoId)
    }

    /// 选中当前会话内所有仍可应用、且至少选择了一个候选标签的仓库。
    /// 这里操作的是仓库层复选状态，不改动每一行内部的候选标签选择。
    func selectAllTagReviewRepositories() {
        selectedRepoIDsForTagApplication = Set(jobs.compactMap { job in
            guard !job.selectedSuggestedTagIDs.isEmpty else { return nil }
            switch job.tagReviewState {
            case .pending, .failed:
                return job.repoId
            case .notRequired, .applying, .applied, .ignored:
                return nil
            }
        })
    }

    /// 清空仓库层复选状态，保留每行已选择的候选标签，方便用户稍后重新批量勾选。
    func clearTagReviewRepositorySelection() {
        selectedRepoIDsForTagApplication = []
    }

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
            selectedRepoIDsForTagApplication.remove(repoId)
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
                    if jobs[latestIndex].suggestedTagAvailability[suggestion.id] == .missing {
                        jobs[latestIndex].suggestedTagAvailability[suggestion.id] = .created
                    }
                }
            }

            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .applied
            selectedRepoIDsForTagApplication.remove(repoId)
            onTagsChanged?()
        } catch {
            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .failed(BatchAIFailure(error: error))
        }
    }

    /// 依照队列顺序应用底栏勾选的仓库。
    ///
    /// 标签可能需要按 canonical key 创建；串行复用单仓应用路径可以避免多个仓库同时创建同名标签，
    /// 同时每完成一个仓库就即时更新该行。单仓失败会保留勾选并继续处理其余仓库。
    func applySelectedTagReviewRepositories() async {
        let selectedRepoIDs = effectiveSelectedRepoIDsForTagApplication
        guard !selectedRepoIDs.isEmpty else { return }
        let orderedRepoIDs = jobs
            .map(\.repoId)
            .filter { selectedRepoIDs.contains($0) }
        for repoId in orderedRepoIDs {
            guard !Task.isCancelled else { return }
            await applySelectedSuggestedTags(repoId: repoId)
        }
    }

    // MARK: - 主循环

    private func launchRunLoop() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
            self.runLoopTask = nil
            // resume() 可能刚好发生在旧 Worker Group 收尾之前；旧 Task 尚未置 nil 时
            // launchRunLoop() 会被 guard 拦住，因此这里对仍可运行的队列补一次无缝续跑。
            if self.isRunning,
               !self.isPaused,
               !self.cancelRequested,
               self.jobs.contains(where: { $0.status == .queued }) {
                self.launchRunLoop()
            }
        }
    }

    /// 建立固定数量的仓库级 Worker，直到全部进入终态、被暂停或被取消。
    ///
    /// 每个 Worker 完成一个仓库后立即写回状态，再原子领取下一个 queued job；
    /// 不等待其它 Worker，因此快请求的完成状态会立即出现在列表和顶部进度中。
    private func runLoop() async {
        guard let options else { return }

        if options.actions.contains(.tags) {
            if initialTagCanonicalKeys == nil {
                do {
                    let tags = try await tagRepository.fetchAll()
                    initialTagCanonicalKeys = Set(tags.compactMap { tag in
                        let key = AITagSuggestionPolicy.canonicalKey(tag.name)
                        return key.isEmpty ? nil : key
                    })
                } catch {
                    // 来源标识是辅助信息；读取失败时继续生成建议，但不能把未知状态误标成新标签。
                    AppLog.ai.error("[batch-ai] load initial tag availability failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if sharedTagLibrary == nil {
                sharedTagLibrary = await RepoAIInsightService.makeSharedTagLibrary(
                    repoTagRepository: repoTagRepository,
                    tagRepository: tagRepository
                )
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<Self.defaultConcurrency {
                group.addTask { [weak self] in
                    await self?.runWorker(index: workerIndex, options: options)
                }
            }
            await group.waitForAll()
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
            processingJobIDs = []
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

    // MARK: - Worker 调度与单 job 处理

    private struct JobOutcome: Sendable {
        var suggestions: [AITagSuggestion]
    }

    private var activeConcurrency: Int {
        guard let rateLimitCooldownUntil else { return Self.defaultConcurrency }
        return rateLimitCooldownUntil > .now ? 1 : Self.defaultConcurrency
    }

    /// 单个 Worker 连续消费队列。`workerIndex` 只用于 429 冷却期动态降到单路；
    /// 任务领取与状态变更都在 MainActor 上串行，因此两个 Worker 不会拿到同一仓库。
    private func runWorker(index workerIndex: Int, options: BatchAIQueueOptions) async {
        while !Task.isCancelled, !cancelRequested, !isPaused {
            guard jobs.contains(where: { $0.status == .queued }) else { return }
            if workerIndex >= activeConcurrency {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }

            guard let repoID = claimNextEligibleJob() else {
                guard jobs.contains(where: { $0.status == .queued }) else { return }
                await waitForRetryWindow()
                continue
            }

            await processClaimedJob(repoID: repoID, options: options)
            // 每完成一个仓库就让出 MainActor，让 PresentationStore 合并 revision 并立即刷新该行。
            await Task.yield()
        }
    }

    /// 原子领取一个已到重试时间的任务，并立即切换到 processing。
    private func claimNextEligibleJob() -> Int64? {
        guard !cancelRequested, !isPaused else { return nil }
        let now = Date.now
        guard let index = jobs.firstIndex(where: {
            $0.status == .queued && (retryNotBeforeByRepoID[$0.repoId] ?? .distantPast) <= now
        }) else { return nil }

        let repoID = jobs[index].repoId
        retryNotBeforeByRepoID[repoID] = nil
        processingJobIDs.insert(repoID)
        jobs[index].status = .processing
        jobs[index].attempts += 1
        return repoID
    }

    /// 单仓请求完成后立即整合结果；无论成功、失败或取消，都释放 Worker 的 processing 占位。
    private func processClaimedJob(repoID: Int64, options: BatchAIQueueOptions) async {
        defer { processingJobIDs.remove(repoID) }
        do {
            let result = try await processSingle(jobId: repoID, options: options)
            try Task.checkCancellation()
            guard !cancelRequested else { return }
            try await applyResult(jobId: repoID, result: result, options: options)
            retryNotBeforeByRepoID[repoID] = nil
        } catch {
            guard !cancelRequested, !Task.isCancelled, !(error is CancellationError) else { return }
            handleFailure(jobId: repoID, error: error, options: options)
        }
    }

    private func waitForRetryWindow() async {
        let nextRetry = retryNotBeforeByRepoID.values.min() ?? .now
        let seconds = max(0.05, min(1, nextRetry.timeIntervalSinceNow))
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
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

        let hints: AITagHints
        if options.shouldRun(.tags, forRepoID: jobId) {
            hints = await RepoAIInsightService.makeTagHints(
                for: repo,
                repoTagRepository: repoTagRepository,
                sharedLibraryTags: sharedTagLibrary ?? []
            )
        } else {
            hints = .empty
        }

        let includesSummary = options.shouldRun(.summary, forRepoID: jobId)
        let includesTags = options.shouldRun(.tags, forRepoID: jobId)
        let suggestions: [AITagSuggestion]
        if includesSummary || includesTags {
            let insight = try await insightService.generateBatchInsight(
                for: repo,
                existingTagHints: hints,
                includeSummary: includesSummary,
                includeTags: includesTags,
                // 标签单独运行时不需要摘要上下文，避免无意义地准备代码或外部搜索。
                codeContextEnabledOverride: includesSummary ? options.codeContextEnabledOverride : nil,
                externalContextEnabledOverride: includesSummary ? options.externalContextEnabledOverride : nil
            )
            suggestions = insight.insight.suggestedTags
        } else {
            suggestions = []
        }

        return JobOutcome(suggestions: suggestions)
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
    /// async 而非 fire-and-forget：一波 AI 结果返回后仍须逐仓完成落库与终态写入，
    /// 下一波才能开始，避免多个任务并行创建同名标签或重复绑定 repo_tags。
    private func applyResult(jobId: Int64, result: JobOutcome, options: BatchAIQueueOptions) async throws {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let suggestions = result.suggestions
        let didSummary = options.shouldRun(.summary, forRepoID: jobId)
        let didTags = options.shouldRun(.tags, forRepoID: jobId)
        var shouldMarkIgnored = false

        if didTags {
            jobs[idx].suggestedTags = suggestions
            if let initialTagCanonicalKeys {
                jobs[idx].suggestedTagAvailability = Dictionary(
                    uniqueKeysWithValues: suggestions.map { suggestion in
                        let key = AITagSuggestionPolicy.canonicalKey(suggestion.name)
                        let availability: BatchAITagSuggestionAvailability = initialTagCanonicalKeys.contains(key)
                            ? .existing
                            : .missing
                        return (suggestion.id, availability)
                    }
                )
            }
            // 只有用户主动打开的批量窗口承载人工审核。静默自动整理仍沿用原有后台语义，
            // 不能在 Sidebar 留下一批用户没有主动创建、也无法感知来源的待确认任务。
            if !silent, !options.autoApplyTags, !suggestions.isEmpty {
                jobs[idx].selectedSuggestedTagIDs = Set(suggestions.map(\.id))
                jobs[idx].tagReviewState = .pending
                // 与分组审核保持一致：有可执行建议的仓库默认进入批量应用集合，用户可手动取消。
                selectedRepoIDsForTagApplication.insert(jobId)
            }
        }

        // 标签子分支：
        // - 没勾选标签 → 直接 completed（summary 已写）。
        // - 勾选 + autoApply=true → 高于阈值的标签自动落库，低于阈值的标签留给用户确认。
        //   静默后台任务没有人工审核入口，仍把全部低于阈值的结果记为 ignored。
        // - 勾选 + autoApply=false → 标签建议保留在当前批量会话中，由用户在同一窗口逐仓确认。
        //   这种情况 status = completed（生成任务本身已完成），审核进度由 tagReviewState 单独表达。
        if didTags, options.autoApplyTags {
            let belowThreshold = suggestions.filter { $0.confidence < options.confidenceThreshold }
            let aboveThreshold = suggestions.filter { $0.confidence >= options.confidenceThreshold }

            var autoApplyOutcome = TagAutoApplyOutcome()
            if !aboveThreshold.isEmpty {
                autoApplyOutcome = await applyTagsToRepo(
                    repoId: jobId,
                    suggestions: aboveThreshold,
                    autoCreateMissingTags: options.autoCreateMissingTags
                )
                guard let currentIndex = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
                jobs[currentIndex].appliedTagNames = autoApplyOutcome.appliedNames
                for suggestionID in autoApplyOutcome.appliedSuggestionIDs {
                    if jobs[currentIndex].suggestedTagAvailability[suggestionID] == .missing {
                        jobs[currentIndex].suggestedTagAvailability[suggestionID] = .created
                    }
                }
                if !autoApplyOutcome.appliedNames.isEmpty {
                    hasPendingTagsChangedNotification = true
                }
            }

            guard let currentIndex = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
            jobs[currentIndex].belowThresholdTags = belowThreshold.map { ($0.name, $0.confidence) }
            let pendingSuggestions = autoApplyOutcome.unresolvedSuggestions + belowThreshold
            if !silent, !pendingSuggestions.isEmpty {
                // 阈值只决定能否自动应用，不能替用户丢弃有效建议；低置信度项预选最接近
                // 阈值的一项，用户既能逐仓调整，也能直接批量应用。未创建的高置信度标签
                // 同样留在当前窗口确认，不能跳过后误报为成功。
                jobs[currentIndex].suggestedTags = pendingSuggestions
                var selectedIDs = Set(autoApplyOutcome.unresolvedSuggestions.map(\.id))
                if let closestBelowThreshold = belowThreshold.max(by: { $0.confidence < $1.confidence }) {
                    selectedIDs.insert(closestBelowThreshold.id)
                }
                jobs[currentIndex].selectedSuggestedTagIDs = selectedIDs
                jobs[currentIndex].tagReviewState = .pending
                if !selectedIDs.isEmpty {
                    selectedRepoIDsForTagApplication.insert(jobId)
                }
            } else if autoApplyOutcome.appliedNames.isEmpty, !suggestions.isEmpty {
                shouldMarkIgnored = true
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

    /// 自动应用的结果必须同时返回“已落库”和“仍需确认”两部分。
    ///
    /// 不能只返回已应用名称：达到阈值但标签不存在、或绑定失败的建议如果被静默丢弃，
    /// 展示层会把仓库误归到“成功”，用户也无法在当前窗口补做确认。
    private struct TagAutoApplyOutcome {
        var appliedNames: [String] = []
        var appliedSuggestionIDs: Set<String> = []
        var unresolvedSuggestions: [AITagSuggestion] = []
    }

    /// 把通过阈值过滤的建议落库为 repo_tags 关联，但只允许复用已有标签。
    ///
    /// 批量自动应用没有逐项人工确认，不能因为模型自报高置信度就静默扩张标签库；真正的
    /// 新标签会返回给当前批量窗口继续确认。这里使用宽松 canonical key，让
    /// `Open-Source` / `open source` 等形式差异复用已有记录。
    private func applyTagsToRepo(
        repoId: Int64,
        suggestions: [AITagSuggestion],
        autoCreateMissingTags: Bool
    ) async -> TagAutoApplyOutcome {
        let existingTags: [Tag]
        do {
            existingTags = try await tagRepository.fetchAll()
        } catch {
            AppLog.ai.error("[batch-ai] load existing tags failed: repo=\(repoId, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            return TagAutoApplyOutcome(unresolvedSuggestions: suggestions)
        }

        var existingTagByName: [String: Tag] = [:]
        var existingTagByKey: [String: Tag] = [:]
        for tag in existingTags {
            existingTagByName[tag.name] = tag
            let key = AITagSuggestionPolicy.canonicalKey(tag.name)
            guard !key.isEmpty, existingTagByKey[key] == nil else { continue }
            existingTagByKey[key] = tag
        }

        var outcome = TagAutoApplyOutcome()
        for suggestion in suggestions {
            let normalized = AITagSuggestionPolicy.normalizedDisplayName(suggestion.name)
            let key = AITagSuggestionPolicy.canonicalKey(normalized)
            guard !normalized.isEmpty, !key.isEmpty else {
                outcome.unresolvedSuggestions.append(suggestion)
                continue
            }

            var tag = existingTagByName[normalized] ?? existingTagByKey[key]
            if tag == nil, autoCreateMissingTags {
                do {
                    let created = try await findOrCreateAutoTag(named: normalized, canonicalKey: key)
                    tag = created
                    existingTagByName[created.name] = created
                    existingTagByKey[key] = created
                } catch {
                    AppLog.ai.error("[batch-ai] auto-create tag failed: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                }
            }

            guard let tag else {
                AppLog.ai.notice("[batch-ai] skip new tag during auto-apply: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public)")
                outcome.unresolvedSuggestions.append(suggestion)
                continue
            }
            do {
                try await repoTagRepository.addTag(repoId: repoId, tagId: tag.id)
                outcome.appliedNames.append(tag.name)
                outcome.appliedSuggestionIDs.insert(suggestion.id)
            } catch {
                AppLog.ai.error("[batch-ai] apply tag failed: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
                outcome.unresolvedSuggestions.append(suggestion)
            }
        }
        return outcome
    }

    /// 创建或复用自动应用所需的新标签。
    ///
    /// 创建任务先登记再 await，MainActor 重入期间后来者会复用同一 Task；数据库唯一约束仍是
    /// 最终防线，若其他入口抢先创建同名标签，则在 create 失败后重新查询并复用该记录。
    private func findOrCreateAutoTag(named name: String, canonicalKey: String) async throws -> Tag {
        if let pending = pendingTagCreationsByCanonicalKey[canonicalKey] {
            return try await pending.value
        }

        let candidate = makeUserConfirmedTag(named: name)
        let repository = tagRepository
        let task = Task<Tag, Error> {
            if let existing = try await repository.findByName(name) {
                return existing
            }
            do {
                try await repository.create(candidate)
                return candidate
            } catch {
                if let existing = try await repository.findByName(name) {
                    return existing
                }
                throw error
            }
        }
        pendingTagCreationsByCanonicalKey[canonicalKey] = task
        defer { pendingTagCreationsByCanonicalKey[canonicalKey] = nil }
        return try await task.value
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

        // 即使当前 job 已达到重试上限，剩余 queued jobs 仍需立即继承降速窗口，
        // 不能继续以五路并发撞击同一个已限流 Provider。
        if isRateLimited(error) {
            rateLimitCooldownUntil = .now.addingTimeInterval(Self.rateLimitCooldown)
        }

        if isPermanentError(error) || jobs[idx].attempts >= options.maxRetries {
            jobs[idx].status = .failed
            jobs[idx].failure = failure
            jobs[idx].errorDiagnostic = diagnostic
            jobs[idx].copyDiagnostic = copyDiagnostic
            jobs[idx].finishedAt = .now
            retryNotBeforeByRepoID[jobId] = nil
        } else {
            // 可重试：指数退避后回到队列，避免 429 / 5xx 立即空转轰炸 Provider。
            // 少量 jitter 让两批同时失败后不要在同一毫秒再次撞上限流窗口。
            let exponent = max(0, jobs[idx].attempts - 1)
            let baseDelay = min(8, pow(2, Double(exponent)))
            let jitter = Double.random(in: 0...0.25)
            retryNotBeforeByRepoID[jobId] = .now.addingTimeInterval(baseDelay + jitter)
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

    private func isRateLimited(_ error: Error) -> Bool {
        guard let aiError = error as? AIClientError else { return false }
        if case .rateLimited = aiError { return true }
        return false
    }

    // MARK: - Repo 缓存（避免每次 processSingle 都查库）

    /// repoId → Repo 的会话内缓存。由 start() 时填充。
    private var repoCache: [Int64: Repo] = [:]
}
