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
//  - **手动会话可恢复**：开始前原子写入队列骨架，每个仓库在 AI 调用前及结果整合后
//    单独 checkpoint。App 重启只恢复审核数据并保持暂停，不会自动重放 Provider 请求。
//    静默后台整理仍由 AutoTidyScheduler 管理，不创建人工审核草稿。
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

    /// “失败/已忽略”Tab 的批量动作勾选（批量重试 / 批量取消忽略）。
    /// 与待确认的批量应用选择分开保存：两者可选集合和动作语义完全不同；
    /// 切换 Tab 时由 Panel 清空，避免把上一个 Tab 的勾选喂给下一个 Tab 的动作。
    private(set) var bulkActionRepoIDs: Set<Int64> = [] {
        didSet { presentationRevision &+= 1 }
    }

    /// 本次启动时的执行配置。空表示当前没有进行中的批次。
    private(set) var options: BatchAIQueueOptions?

    /// 是否正在处理（取出 job → 调 AI → 落库 的整个生命周期内为 true）。
    /// 进入暂停态时为 false，但 jobs 仍保留以便用户继续。
    private(set) var isRunning: Bool = false

    /// 是否被用户暂停。`isRunning && !isPaused` 才会拉下一个 job。
    private(set) var isPaused: Bool = false

    /// 本轮的显式调用来源。Provider 路由依赖它区分人工建议与自动写入链路。
    private(set) var invocationMode: BatchAIInvocationMode = .manual

    /// HOM-126：本轮是否是「自动后台整理」触发（区别于 HOM-52 用户手动整理）。
    ///
    /// 用途：
    /// - UI 侧观察该标志，决定是否要弹浮动面板 / 强提示横幅。
    ///   静默模式下 HomeView 不自动展示批量标签工作区；
    ///   Sidebar 改用「AI 自动整理中 N/M」轻量行展示进度。
    /// - 服务自身不主动唤起 UI（本来就不持有 UI），所以"静默"语义全部由订阅方实现。
    ///
    /// 它只负责 UI 展示语义；Provider 路由必须读取 `invocationMode`，不能反向依赖该派生值。
    var silent: Bool { invocationMode == .automatic }

    /// 当前 Worker 正在处理的 repo id；数量不会超过 `defaultConcurrency`。
    private(set) var processingJobIDs: Set<Int64> = []

    /// 本次批次的开始时刻，用于估算剩余时间（已用时 / 完成数 → 平均耗时）。
    private(set) var startedAt: Date?

    /// 用户主动取消标志位：与 `runLoopTask.cancel()` 共同表达用户终止意图。
    private var cancelRequested: Bool = false

    /// 账号切换只中断当前请求，不能复用“用户终止”删除 queued 草稿。
    /// runLoop 收口 processing 项时据此写成可重试的中断失败，切回账号后由用户决定是否继续。
    private var accountResetRequested: Bool = false

    /// 当前队列 Task。取消句柄会把 cancellation 传给整波 in-flight AI 请求；
    /// runLoop 仍负责统一收口 job 与 UI 状态，避免调用方直接改写状态机。
    private var runLoopTask: Task<Void, Never>?

    /// 批次级全库标签词表快照；每轮只查询一次，避免逐仓重复扫描标签表和使用次数。
    private var sharedTagLibrary: [String]?

    /// 批次启动时标签库的完整 canonical key 快照，用于给审核 Chip 标注“已有 / 新标签”。
    /// 与给模型的 `sharedTagLibrary` 分开保存：后者受字符预算截断，不能作为来源判断依据。
    private var initialTagCanonicalKeys: Set<String>?

    /// Jev 首轮没有任何可复用标签的仓库。人工批次结束后只对这个集合做一次全局概念发现；
    /// 自动后台整理不消费该集合，因为它没有确认扩充词表的交互边界。
    private var uncoveredTagRepositoryIDs: Set<Int64> = []

    /// 单次整批概念发现得到的待确认词表。它与逐仓标签建议一起持久化在现有草稿中，
    /// 用户确认前不会创建标签；确认后才使用扩充后的闭集词表重新归类。
    private(set) var pendingTagExpansionSession: TagTaxonomyBootstrapSession?

    /// 概念发现是批次级请求，失败不能伪装成每个仓库各自失败，也不能退回逐仓 LLM。
    /// 保存一条会话级错误供工作区展示和重试。
    private(set) var tagExpansionError: String?

    /// 可重试失败的最早再次执行时刻，避免 429 / 5xx 立即空转轰炸 Provider。
    private var retryNotBeforeByRepoID: [Int64: Date] = [:]

    /// 遇到 429 后的临时单路窗口；窗口结束后恢复默认 5 路并发。
    private var rateLimitCooldownUntil: Date?

    /// 本轮是否已有标签落库，退出 runLoop 时据此合并一次 Sidebar 刷新。
    private var hasPendingTagsChangedNotification: Bool = false

    /// 底栏「应用选中项」/ 批量落库重试的会话级锁。
    ///
    /// 不能只靠「当前是否有 `.applying` 行」派生：串行多仓时仓 A 刚变 `applied`、仓 B
    /// 尚未进入 `applying` 会出现一帧 `isApplyingSuggestedTags == false`，底栏按钮反复
    /// 启用/禁用形成闪烁。整批期间保持 true，结束再清。
    private var isBulkApplyingSuggestedTags: Bool = false

    /// 整批应用开始时冻结的「已选 N 个」快照；避免 `.applying` 被排除出有效选择后数字连跳。
    private var frozenTagReviewSelectionCount: Int?

    /// 批量标签落库的真实仓库进度。生成进度已经结束后，审核面板改用这份状态展示
    /// 「正在应用 X / N」，避免顶部仍停在 2053 / 2053 而用户无法判断落库是否前进。
    private(set) var tagApplicationProgress: BatchAITagApplicationProgress?

    // MARK: - 依赖（按 AppDependencies 装配顺序注入）

    private let insightService: any BatchAIInsightProviding
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let aiSummaryRepository: any AISummaryRepositoryProtocol
    private let entitlementGate: EntitlementGate?
    private let notificationService: ReleaseNotificationService?
    private let draftRepository: (any AIOrganizationDraftRepositoryProtocol)?

    /// draft id 同时是账号切换屏障；旧账号迟到写入在新数据库中找不到该 id，会自然 no-op。
    private var activeDraftID: UUID?
    private var isDraftCreated = false

    /// 正常状态下保留 5 个长驻 Worker；每个 Worker 完成一个仓库后立即领取下一项。
    private static let defaultConcurrency = 5
    private static let rateLimitCooldown: TimeInterval = 30
    /// 每块只产生一次 repo_tags 事务和一次草稿事务；100 个仓库既能把 2,000+ 次写入
    /// 压缩到几十次，又保留取消边界、失败分块和可见进度。
    private static let tagApplicationChunkSize = 100
    /// 新标签属于全局词表而不是仓库私有关键词；每批最多扩充 5 个，避免词表线性膨胀。
    private static let maximumTagExpansionCount = 5

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
        notificationService: ReleaseNotificationService? = nil,
        draftRepository: (any AIOrganizationDraftRepositoryProtocol)? = nil
    ) {
        self.insightService = insightService
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.aiSummaryRepository = aiSummaryRepository
        self.entitlementGate = entitlementGate
        self.notificationService = notificationService
        self.draftRepository = draftRepository
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
        // 整批应用中展示开批时的勾选数，避免每仓进入 applying / 完成后底栏数字闪跳。
        if let frozenTagReviewSelectionCount {
            return frozenTagReviewSelectionCount
        }
        return effectiveSelectedRepoIDsForTagApplication.count
    }

    var selectedTagReviewTagCount: Int {
        let effectiveRepoIDs = effectiveSelectedRepoIDsForTagApplication
        return jobs.lazy
            .filter { effectiveRepoIDs.contains($0.repoId) }
            .reduce(into: 0) { $0 += $1.selectedSuggestedTagIDs.count }
    }

    /// 标签正在写入数据库时不能丢弃会话，否则 UI 状态虽已清空，异步写入仍可能继续完成。
    /// 含会话级整批锁：覆盖串行多仓间隙，防止底栏按钮闪烁。
    var isApplyingSuggestedTags: Bool {
        if isBulkApplyingSuggestedTags { return true }
        return jobs.contains { job in
            if case .applying = job.tagReviewState { true } else { false }
        }
    }

    /// 手动任务关闭后仍值得保留的内容：未处理队列、分析失败或待确认/应用失败的标签。
    /// 自动后台任务由调度器记录结果，不应反过来阻塞用户发起新的手动整理。
    var hasUnresolvedManualWork: Bool {
        guard !silent, !jobs.isEmpty else { return false }
        if pendingTagExpansionSession != nil || !uncoveredTagRepositoryIDs.isEmpty {
            return true
        }
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
    /// - Parameter invocationMode: `.automatic` 表示由自动调度器触发，
    ///   订阅方（HomeView / 浮动面板 / Banner）应避免主动弹任何 sheet / 强提示；
    ///   Sidebar 改用「AI 自动整理中 N/M」轻量行展示进度。默认 `.manual` 维持 HOM-52
    ///   手动模式行为不变。
    @discardableResult
    func start(
        repos: [Repo],
        options: BatchAIQueueOptions,
        invocationMode: BatchAIInvocationMode = .manual
    ) -> Bool {
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
            try entitlementGate?.requirePro(.batchAI, usesLocalOnly: AppSettings.shared.isGenerationTasksResolvedToLocalAI)
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
            try validateConfiguration(for: options, invocationMode: invocationMode)
        } catch {
            // 只记录一次批次级配置错误，不能把同一个缺失项扩散成数千条 job 失败。
            AppLog.ai.warning("[batch-ai] start() blocked by AI configuration: \(error.localizedDescription, privacy: .public)")
            return false
        }
        self.options = options
        self.invocationMode = invocationMode
        self.jobs = repos.map { repo in
            BatchAIJob(
                repoId: repo.id,
                repoFullName: repo.fullName,
                repoDescription: repo.description,
                ownerAvatarURL: repo.ownerAvatar
            )
        }
        self.selectedRepoIDsForTagApplication = []
        self.bulkActionRepoIDs = []
        self.repoCache = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.isPaused = false
        self.isRunning = true
        self.cancelRequested = false
        self.accountResetRequested = false
        self.hasPendingTagsChangedNotification = false
        self.startedAt = Date()
        self.processingJobIDs = []
        self.sharedTagLibrary = nil
        self.initialTagCanonicalKeys = nil
        self.uncoveredTagRepositoryIDs = []
        self.pendingTagExpansionSession = nil
        self.tagExpansionError = nil
        self.retryNotBeforeByRepoID = [:]
        self.rateLimitCooldownUntil = nil
        self.activeDraftID = invocationMode == .automatic ? nil : UUID()
        self.isDraftCreated = invocationMode == .automatic
        AppLog.ai.notice("[batch-ai] start: count=\(repos.count, privacy: .public), autoApplyTags=\(options.autoApplyTags, privacy: .public), threshold=\(options.confidenceThreshold, privacy: .public), mode=\(String(describing: invocationMode), privacy: .public)")
        launchRunLoop()
        return true
    }

    /// 以纯本地候选直接建立一轮人工审核，不启动 Provider Worker。
    ///
    /// 首次标签体系已经在独立工作台完成全局候选分析；这里仅把确定性归类结果投影为
    /// `BatchAIJob`，从而复用既有逐仓勾选、草稿恢复和最终 repo_tags 写入能力。标签关系
    /// 仍必须由用户在审核页确认，不能因为本地分析不消耗 token 就绕过保守写入边界。
    @discardableResult
    func startLocalTagReview(
        repos: [Repo],
        suggestionsByRepoID: [Int64: [AITagSuggestion]],
        options requestedOptions: BatchAIQueueOptions
    ) async -> Bool {
        guard !isRunning, runLoopTask == nil else {
            AppLog.ai.warning("[batch-ai] local taxonomy review ignored: queue is running")
            return false
        }
        guard !hasUnresolvedManualWork else {
            AppLog.ai.warning("[batch-ai] local taxonomy review ignored: unresolved manual session exists")
            return false
        }
        guard !repos.isEmpty, suggestionsByRepoID.values.contains(where: { !$0.isEmpty }) else {
            AppLog.ai.warning("[batch-ai] local taxonomy review ignored: no local suggestions")
            return false
        }
        do {
            // 本轮没有远端生成调用，Pro 门控必须按 local-only 语义判断，不能要求 AI Key。
            try entitlementGate?.requirePro(.batchAI, usesLocalOnly: true)
        } catch {
            AppLog.ai.warning("[batch-ai] local taxonomy review blocked by entitlement: \(error.localizedDescription, privacy: .public)")
            return false
        }

        var localOptions = requestedOptions
        localOptions.actions = [.tags]
        localOptions.autoApplyTags = false
        localOptions.autoCreateMissingTags = false
        localOptions.standardActionRepoIDs = nil

        let existingTags: [Tag]
        do {
            existingTags = try await tagRepository.fetchAll()
        } catch {
            AppLog.database.error("[batch-ai] load local taxonomy tags failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let existingKeys = Set(existingTags.compactMap { tag -> String? in
            let key = AITagSuggestionPolicy.canonicalKey(tag.name)
            return key.isEmpty ? nil : key
        })
        let now = Date.now

        self.options = localOptions
        self.invocationMode = .manual
        self.repoCache = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.jobs = repos.map { repo in
            var job = BatchAIJob(
                repoId: repo.id,
                repoFullName: repo.fullName,
                repoDescription: repo.description,
                ownerAvatarURL: repo.ownerAvatar
            )
            let suggestions = suggestionsByRepoID[repo.id] ?? []
            job.suggestedTags = suggestions
            job.suggestedTagAvailability = suggestions.reduce(into: [:]) { result, suggestion in
                let key = AITagSuggestionPolicy.canonicalKey(suggestion.name)
                result[suggestion.id] = existingKeys.contains(key) ? .existing : .missing
            }
            job.finishedAt = now
            if suggestions.isEmpty {
                // 未命中不是 Provider 失败；保留在“忽略”中，用户仍能看到本地体系的覆盖边界。
                job.status = .ignored
                job.tagReviewState = .ignored
                job.ignoreReason = .taxonomyUncovered
            } else {
                job.status = .completed
                job.selectedSuggestedTagIDs = Set(suggestions.map(\.id))
                job.tagReviewState = .pending
            }
            return job
        }
        self.selectedRepoIDsForTagApplication = Set(jobs.compactMap { job in
            job.tagReviewState == .pending ? job.repoId : nil
        })
        self.bulkActionRepoIDs = []
        self.isPaused = false
        self.isRunning = false
        self.cancelRequested = false
        self.accountResetRequested = false
        self.hasPendingTagsChangedNotification = false
        self.startedAt = now
        self.processingJobIDs = []
        self.sharedTagLibrary = existingTags.map(\.name)
        self.initialTagCanonicalKeys = existingKeys
        self.uncoveredTagRepositoryIDs = []
        self.pendingTagExpansionSession = nil
        self.tagExpansionError = nil
        self.retryNotBeforeByRepoID = [:]
        self.rateLimitCooldownUntil = nil
        self.activeDraftID = UUID()
        self.isDraftCreated = false

        guard await prepareDraftForRun() else {
            deleteActiveDraft()
            reset()
            return false
        }
        AppLog.ai.notice(
            "[batch-ai] local taxonomy review ready: total=\(repos.count, privacy: .public), pending=\(self.pendingTagReviewCount, privacy: .public)"
        )
        return true
    }

    /// 整理弹窗的只读预检结果。UI 与 `start()` 复用同一校验入口，避免按钮显示可用，
    /// 点击后却创建整批失败任务。返回值已经本地化，可直接作为错误说明展示。
    func configurationIssue(
        for options: BatchAIQueueOptions,
        invocationMode: BatchAIInvocationMode = .manual
    ) -> String? {
        guard options.isValidForStart else { return nil }
        do {
            try validateConfiguration(for: options, invocationMode: invocationMode)
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
        let removedRepoIDs = Set(jobs.compactMap { $0.status == .queued ? $0.repoId : nil })
        let removed = removedRepoIDs.count
        jobs.removeAll { $0.status == .queued }
        deleteDraftItems(repoIDs: removedRepoIDs)
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

    /// 账号切换时中断任何来源的批次，并清除仅属于旧账号的内存态。
    ///
    /// 不能调用普通 `cancel()`：那是用户明确终止，会删除 queued 草稿。这里必须先让
    /// in-flight AI 请求在旧账号数据库内收口为“处理中断”，同时保留未开始和未确认结果，
    /// 否则切回账号仍会重复消耗 token。
    func resetForAccountChange() async {
        if isRunning {
            accountResetRequested = true
            cancelRequested = true
            isPaused = false
            if let runLoopTask {
                runLoopTask.cancel()
                await runLoopTask.value
            } else {
                // 暂停态的旧 runLoop 已退出；重新进入统一收口，确保状态已经持久化再切库。
                launchRunLoop()
                runLoopTask?.cancel()
                await runLoopTask?.value
            }
        }
        reset()
    }

    /// 数据库切换完成后恢复当前账号的人工草稿。恢复态永远停在用户可审阅/可继续的边界，
    /// 不会从 `.queued` 或被中断的 `.processing` 自动发起 Provider 请求。
    func restoreDraftIfNeeded() async {
        guard jobs.isEmpty, !isRunning, let draftRepository else { return }
        do {
            guard let draft = try await draftRepository.loadDraft(kind: .batchTags) else { return }
            let header = try AIOrganizationDraftJSON.decode(
                BatchAIOrganizationDraftHeader.self,
                from: draft.headerJSON
            )
            let snapshots = try draft.items.map {
                try AIOrganizationDraftJSON.decode(BatchAIOrganizationDraftItem.self, from: $0.payloadJSON)
            }
            guard !snapshots.isEmpty else {
                try await draftRepository.deleteDraft(draftID: draft.id, kind: .batchTags)
                return
            }

            activeDraftID = draft.id
            isDraftCreated = true
            options = header.options
            // 只有人工会话会持久化草稿；恢复后仍保持人工路由语义，但不会自动重放请求。
            invocationMode = .manual
            startedAt = header.startedAt
            jobs = snapshots.map { $0.restoredJob() }
            repoCache = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.repo.id, $0.repo) })
            selectedRepoIDsForTagApplication = Set(
                snapshots.filter(\.isSelectedForTagApplication).map { $0.repo.id }
            )
            isPaused = jobs.contains { $0.status == .queued }
            isRunning = isPaused
            cancelRequested = false
            processingJobIDs = []
            sharedTagLibrary = nil
            initialTagCanonicalKeys = nil
            uncoveredTagRepositoryIDs = header.uncoveredTagRepositoryIDs ?? []
            pendingTagExpansionSession = header.pendingTagExpansionSession
            tagExpansionError = header.tagExpansionError
            retryNotBeforeByRepoID = [:]
            rateLimitCooldownUntil = nil

            // 中断态已在内存中转为可重试失败，立即回写，下一次启动不会再次看到“执行中”。
            for job in jobs where job.status == .failed || {
                if case .failed = job.tagReviewState { return true }
                return false
            }() {
                try await persistJob(repoID: job.repoId)
            }
            if isManualSessionResolved {
                try await draftRepository.deleteDraft(draftID: draft.id, kind: .batchTags)
                reset()
            }
        } catch {
            AppLog.database.error("[batch-ai] restore draft failed: \(error.localizedDescription, privacy: .public)")
        }
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
        bulkActionRepoIDs = []
        options = nil
        startedAt = nil
        processingJobIDs = []
        cancelRequested = false
        accountResetRequested = false
        invocationMode = .manual
        hasPendingTagsChangedNotification = false
        isBulkApplyingSuggestedTags = false
        frozenTagReviewSelectionCount = nil
        tagApplicationProgress = nil
        sharedTagLibrary = nil
        initialTagCanonicalKeys = nil
        uncoveredTagRepositoryIDs = []
        pendingTagExpansionSession = nil
        tagExpansionError = nil
        retryNotBeforeByRepoID = [:]
        rateLimitCooldownUntil = nil
        repoCache = [:]
        activeDraftID = nil
        isDraftCreated = false
    }

    /// 放弃当前批次的内存态结果，让用户可以立即开始下一批整理。
    ///
    /// 已经写入数据库的标签与摘要不属于队列内存，必须保留；这里只清除尚未应用的建议、
    /// 失败记录和进度。返回 false 表示 Worker 或标签落库仍在执行，调用方应保持窗口不变。
    @discardableResult
    func discardCurrentSession() -> Bool {
        guard canDiscardCurrentSession else { return false }
        deleteActiveDraft()
        reset()
        return true
    }

    /// 完整结果在窗口打开期间保留供复查；窗口关闭或下一轮配置出现时再清理。
    @discardableResult
    func finishManualSessionIfResolved() -> Bool {
        guard isManualSessionResolved else { return false }
        deleteActiveDraft()
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
        jobs[idx].ignoreReason = nil
        jobs[idx].finishedAt = nil
        retryNotBeforeByRepoID[jobId] = nil
        schedulePersistJob(repoID: jobId)
        if !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        } else if isPaused {
            // 暂停态单行重试与批量重试同语义：重新入队即恢复运行（旧 runLoop 已退出）。
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        }
    }

    /// 重试全部失败。批量版本，避免 UI 端循环触发 N 次 runLoop。
    func retryAllFailed() {
        retryGenerationFailures(repoIDs: nil)
    }

    /// 按选中子集重新入队生成失败仓库；`repoIDs` 为 nil 表示全部失败项。
    /// 暂停态重试 = 重新入队 + 自动恢复运行；注意标签队列暂停时旧 runLoop 已退出
    /// （与仓库分组窗口的常驻 Worker 不同），必须重新 launchRunLoop 才能消费新队列。
    func retryGenerationFailures(repoIDs: Set<Int64>?) {
        var touched = false
        for idx in jobs.indices
        where jobs[idx].status == .failed && (repoIDs.map { $0.contains(jobs[idx].repoId) } ?? true) {
            jobs[idx].status = .queued
            jobs[idx].attempts = 0
            jobs[idx].failure = nil
            jobs[idx].errorDiagnostic = nil
            jobs[idx].copyDiagnostic = nil
            jobs[idx].ignoreReason = nil
            jobs[idx].finishedAt = nil
            retryNotBeforeByRepoID[jobs[idx].repoId] = nil
            touched = true
        }
        guard touched else { return }
        schedulePersistJobs(repoIDs: Set(jobs.compactMap { $0.status == .queued ? $0.repoId : nil }))
        if isRunning {
            if isPaused {
                isPaused = false
                cancelRequested = false
                launchRunLoop()
            }
        } else {
            isRunning = true
            isPaused = false
            cancelRequested = false
            launchRunLoop()
        }
    }

    /// “失败”Tab 同时收纳生成失败和人工应用失败；批量重试必须覆盖两条恢复路径。
    /// 先串行重试标签落库，避免它与重新启动的 AI Worker 同时修改同一会话状态。
    /// 暂停态可用：runLoop 保持存活，恢复后按新队列继续。
    func retryAllFailures() async {
        guard !isRunning || isPaused, !isApplyingSuggestedTags else { return }
        let reviewFailureRepoIDs = jobs.compactMap { job -> Int64? in
            if case .failed = job.tagReviewState { return job.repoId }
            return nil
        }
        // 与底栏批量应用同一会话锁，避免串行落库间隙底栏/重试按钮闪烁。
        beginBulkTagApplication(selectionCount: nil)
        defer { endBulkTagApplication() }
        for repoID in reviewFailureRepoIDs {
            guard !Task.isCancelled else { return }
            await applySelectedSuggestedTags(repoId: repoID)
        }
        retryGenerationFailures(repoIDs: nil)
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
        schedulePersistJob(repoID: repoId)
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
        schedulePersistJobs(repoIDs: Set(jobs.map(\.repoId)))
    }

    /// 清空仓库层复选状态，保留每行已选择的候选标签，方便用户稍后重新批量勾选。
    func clearTagReviewRepositorySelection() {
        selectedRepoIDsForTagApplication = []
        schedulePersistJobs(repoIDs: Set(jobs.map(\.repoId)))
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
        schedulePersistJob(repoID: repoId)
    }

    func selectAllSuggestedTags(repoId: Int64) {
        guard let index = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
        switch jobs[index].tagReviewState {
        case .pending, .failed:
            jobs[index].selectedSuggestedTagIDs = Set(jobs[index].suggestedTags.map(\.id))
            jobs[index].tagReviewState = .pending
            schedulePersistJob(repoID: repoId)
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
            schedulePersistJob(repoID: repoId)
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
            jobs[index].ignoreReason = .userSkipped
            selectedRepoIDsForTagApplication.remove(repoId)
            schedulePersistJob(repoID: repoId)
        case .notRequired, .applying, .applied, .ignored:
            return
        }
    }

    // MARK: - “失败/已忽略”Tab 批量动作

    /// 各 Tab 的可选集合与批量动作一一对应；行渲染先按 Tab 过滤，这里再做一次防御，
    /// 防止状态在渲染后变化导致把不匹配的仓库喂给批量动作。
    /// 已忽略 Tab 里低于阈值自动忽略的行（`status == .ignored`）没有可恢复的建议，不可勾选。
    func isRepoSelectableForBulkAction(repoId: Int64, filter: BatchAIResultFilter) -> Bool {
        guard let job = jobs.first(where: { $0.repoId == repoId }) else { return false }
        switch filter {
        case .failed:
            if job.status == .failed { return true }
            if case .failed = job.tagReviewState { return true }
            return false
        case .ignored:
            return job.tagReviewState == .ignored
        case .actionable, .pendingReview, .completed, .all:
            // 待确认沿用 selectedRepoIDsForTagApplication；待处理/已完成不参与批量选择。
            return false
        }
    }

    func toggleRepoForBulkAction(repoId: Int64, filter: BatchAIResultFilter) {
        guard isRepoSelectableForBulkAction(repoId: repoId, filter: filter) else { return }
        if bulkActionRepoIDs.contains(repoId) {
            bulkActionRepoIDs.remove(repoId)
        } else {
            bulkActionRepoIDs.insert(repoId)
        }
    }

    func selectAllReposForBulkAction(filter: BatchAIResultFilter) {
        bulkActionRepoIDs = Set(jobs.compactMap { job -> Int64? in
            isRepoSelectableForBulkAction(repoId: job.repoId, filter: filter) ? job.repoId : nil
        })
    }

    func clearBulkActionSelection() {
        guard !bulkActionRepoIDs.isEmpty else { return }
        bulkActionRepoIDs = []
    }

    /// 当前 Tab 仍有效的勾选数；被批量动作消费或状态已变化的过期勾选不计入。
    func bulkActionSelectedCount(for filter: BatchAIResultFilter) -> Int {
        let selectedRepoIDs = bulkActionRepoIDs
        return jobs.filter { job in
            selectedRepoIDs.contains(job.repoId)
                && isRepoSelectableForBulkAction(repoId: job.repoId, filter: filter)
        }.count
    }

    /// 当前 Tab 可勾选总数，供「选中全部」判断是否还有未勾选项。
    func bulkActionSelectableCount(for filter: BatchAIResultFilter) -> Int {
        jobs.filter {
            isRepoSelectableForBulkAction(repoId: $0.repoId, filter: filter)
        }.count
    }

    /// 底栏批量动作：按当前 Tab 语义消费勾选集合，执行后清空勾选。
    func applyBulkAction(filter: BatchAIResultFilter) async {
        let selectedRepoIDs = bulkActionRepoIDs
        clearBulkActionSelection()
        switch filter {
        case .failed:
            // 与 retryAllFailures 同序：先串行重试标签应用，再重新入队生成失败。
            guard !isRunning || isPaused, !isApplyingSuggestedTags else { return }
            let reviewFailureRepoIDs = jobs.compactMap { job -> Int64? in
                guard selectedRepoIDs.contains(job.repoId),
                      case .failed = job.tagReviewState
                else { return nil }
                return job.repoId
            }
            beginBulkTagApplication(selectionCount: nil)
            defer { endBulkTagApplication() }
            for repoID in reviewFailureRepoIDs {
                guard !Task.isCancelled else { return }
                await applySelectedSuggestedTags(repoId: repoID)
            }
            retryGenerationFailures(repoIDs: selectedRepoIDs)
        case .ignored:
            unignoreSuggestedTags(repoIDs: selectedRepoIDs)
        case .actionable, .pendingReview, .completed, .all:
            break
        }
    }

    /// 取消忽略：恢复为待确认。忽略只可能来自待确认/应用失败行，建议标签仍在，可重新勾选应用。
    func unignoreSuggestedTags(repoIDs: Set<Int64>) {
        for index in jobs.indices where jobs[index].tagReviewState == .ignored {
            guard repoIDs.contains(jobs[index].repoId) else { continue }
            jobs[index].tagReviewState = .pending
            jobs[index].ignoreReason = nil
        }
        schedulePersistJobs(repoIDs: repoIDs)
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
            try await persistJob(repoID: repoId)
        } catch {
            jobs[initialIndex].tagReviewState = .failed(BatchAIFailure(error: error))
            return
        }

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
                try await persistJob(repoID: repoId)
            }

            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .applied
            jobs[finalIndex].ignoreReason = nil
            selectedRepoIDsForTagApplication.remove(repoId)
            try await persistJob(repoID: repoId)
            // 整批应用中只记 pending，结束时合并一次 Sidebar 刷新，避免每仓触发整窗抖动。
            if isBulkApplyingSuggestedTags {
                hasPendingTagsChangedNotification = true
            } else {
                onTagsChanged?()
            }
        } catch {
            guard let finalIndex = jobs.firstIndex(where: { $0.repoId == repoId }) else { return }
            jobs[finalIndex].tagReviewState = .failed(BatchAIFailure(error: error))
            await persistJobBestEffort(repoID: repoId)
        }
    }

    private struct PendingBulkTagApplication {
        let repoID: Int64
        let selectedSuggestionIDs: Set<String>
        let suggestions: [AITagSuggestion]
        let appliedTagNames: Set<String>
    }

    private struct ResolvedBulkTagSuggestion {
        let suggestionID: String
        let tag: Tag
    }

    private struct ResolvedBulkTagApplication {
        let repoID: Int64
        let selectedSuggestionIDs: Set<String>
        let suggestions: [ResolvedBulkTagSuggestion]
        let appliedTagNames: Set<String>
    }

    /// 依照队列顺序分块应用底栏勾选的仓库。
    ///
    /// 旧实现逐仓复用单项路径，每仓 3 个标签时会产生 8 次独立写事务，并在每次 await 后
    /// 重扫 jobs。这里先把每块的标签解析到内存，再用一次 repo_tags 事务和一次草稿事务提交；
    /// 分块之间仍保留取消与失败边界，失败块保持勾选，可继续重试。
    func applySelectedTagReviewRepositories() async {
        guard !isBulkApplyingSuggestedTags else { return }
        let selectedRepoIDs = effectiveSelectedRepoIDsForTagApplication
        guard !selectedRepoIDs.isEmpty else { return }
        let orderedRepoIDs = jobs
            .map(\.repoId)
            .filter { selectedRepoIDs.contains($0) }
        beginBulkTagApplication(selectionCount: selectedRepoIDs.count)
        defer { endBulkTagApplication() }

        let jobIndexByRepoID = Dictionary(
            uniqueKeysWithValues: jobs.indices.map { (jobs[$0].repoId, $0) }
        )
        var tagsByCanonicalKey: [String: Tag]
        do {
            let tags = try await tagRepository.fetchAll()
            tagsByCanonicalKey = Dictionary(
                tags.map { (AITagSuggestionPolicy.canonicalKey($0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            await markBulkTagApplicationsFailed(
                repoIDs: orderedRepoIDs,
                error: error,
                jobIndexByRepoID: jobIndexByRepoID
            )
            advanceTagApplicationProgress(by: orderedRepoIDs.count)
            return
        }

        var chunkStart = 0
        while chunkStart < orderedRepoIDs.count {
            guard !Task.isCancelled else { return }
            let chunkEnd = min(
                chunkStart + Self.tagApplicationChunkSize,
                orderedRepoIDs.count
            )
            let chunkRepoIDs = Array(orderedRepoIDs[chunkStart..<chunkEnd])
            let pendingApplications = pendingBulkTagApplications(
                repoIDs: chunkRepoIDs,
                jobIndexByRepoID: jobIndexByRepoID
            )
            guard !pendingApplications.isEmpty else {
                advanceTagApplicationProgress(by: chunkRepoIDs.count)
                chunkStart = chunkEnd
                continue
            }

            let activeRepoIDs = pendingApplications.map(\.repoID)
            markBulkTagApplicationsAsApplying(
                repoIDs: activeRepoIDs,
                jobIndexByRepoID: jobIndexByRepoID
            )

            do {
                let resolved = try await resolveBulkTagApplications(
                    pendingApplications,
                    tagsByCanonicalKey: tagsByCanonicalKey
                )
                tagsByCanonicalKey = resolved.tagsByCanonicalKey

                let assignments = resolved.applications.flatMap { application in
                    application.suggestions.map { suggestion in
                        RepoTagAssignment(repoId: application.repoID, tagId: suggestion.tag.id)
                    }
                }
                try await repoTagRepository.batchAddTags(assignments: assignments)
                if !assignments.isEmpty {
                    hasPendingTagsChangedNotification = true
                }

                var updatedJobs = jobs
                var updatedSelectedRepoIDs = selectedRepoIDsForTagApplication
                for application in resolved.applications {
                    guard let index = jobIndexByRepoID[application.repoID] else { continue }
                    updatedJobs[index].selectedSuggestedTagIDs.subtract(application.selectedSuggestionIDs)
                    updatedJobs[index].appliedTagNames = application.appliedTagNames.sorted()
                    for suggestion in application.suggestions
                    where updatedJobs[index].suggestedTagAvailability[suggestion.suggestionID] == .missing {
                        updatedJobs[index].suggestedTagAvailability[suggestion.suggestionID] = .created
                    }
                    updatedJobs[index].tagReviewState = .applied
                    updatedSelectedRepoIDs.remove(application.repoID)
                }

                // 草稿先写最终快照，再一次性发布内存状态。若 checkpoint 失败，数据库关联已由
                // INSERT OR IGNORE 保证可安全重试，UI 继续保留选择并显示失败，不会伪装成功。
                try await persistBulkDraftItems(
                    jobs: updatedJobs,
                    repoIDs: activeRepoIDs,
                    selectedRepoIDs: updatedSelectedRepoIDs,
                    jobIndexByRepoID: jobIndexByRepoID
                )
                jobs = updatedJobs
                selectedRepoIDsForTagApplication = updatedSelectedRepoIDs
            } catch {
                await markBulkTagApplicationsFailed(
                    repoIDs: activeRepoIDs,
                    error: error,
                    jobIndexByRepoID: jobIndexByRepoID
                )
            }

            advanceTagApplicationProgress(by: chunkRepoIDs.count)
            chunkStart = chunkEnd
        }
    }

    /// 在任何 await 之前冻结当前分块的选择。未来分块仍可继续接受用户调整，与旧串行路径一致；
    /// 当前分块一旦进入 applying 就不再读取可变 UI 状态，避免 actor 重入造成标签错配。
    private func pendingBulkTagApplications(
        repoIDs: [Int64],
        jobIndexByRepoID: [Int64: Int]
    ) -> [PendingBulkTagApplication] {
        repoIDs.compactMap { repoID in
            guard selectedRepoIDsForTagApplication.contains(repoID),
                  let index = jobIndexByRepoID[repoID]
            else { return nil }
            switch jobs[index].tagReviewState {
            case .pending, .failed:
                break
            case .notRequired, .applying, .applied, .ignored:
                return nil
            }
            let selectedIDs = jobs[index].selectedSuggestedTagIDs
            let suggestions = jobs[index].suggestedTags.filter { selectedIDs.contains($0.id) }
            guard !suggestions.isEmpty else { return nil }
            return PendingBulkTagApplication(
                repoID: repoID,
                selectedSuggestionIDs: selectedIDs,
                suggestions: suggestions,
                appliedTagNames: Set(jobs[index].appliedTagNames)
            )
        }
    }

    private func markBulkTagApplicationsAsApplying(
        repoIDs: [Int64],
        jobIndexByRepoID: [Int64: Int]
    ) {
        var updatedJobs = jobs
        for repoID in repoIDs {
            guard let index = jobIndexByRepoID[repoID] else { continue }
            updatedJobs[index].tagReviewState = .applying
        }
        jobs = updatedJobs
    }

    private func resolveBulkTagApplications(
        _ pendingApplications: [PendingBulkTagApplication],
        tagsByCanonicalKey initialTagsByCanonicalKey: [String: Tag]
    ) async throws -> (
        applications: [ResolvedBulkTagApplication],
        tagsByCanonicalKey: [String: Tag]
    ) {
        var tagsByCanonicalKey = initialTagsByCanonicalKey
        var applications: [ResolvedBulkTagApplication] = []
        applications.reserveCapacity(pendingApplications.count)

        for pending in pendingApplications {
            var resolvedSuggestions: [ResolvedBulkTagSuggestion] = []
            var appliedTagNames = pending.appliedTagNames
            for suggestion in pending.suggestions {
                let normalized = AITagSuggestionPolicy.normalizedDisplayName(suggestion.name)
                let key = AITagSuggestionPolicy.canonicalKey(normalized)
                guard !normalized.isEmpty, !key.isEmpty else { continue }

                let tag: Tag
                if let existing = tagsByCanonicalKey[key] {
                    tag = existing
                } else {
                    tag = makeUserConfirmedTag(named: normalized)
                    try await tagRepository.create(tag)
                    tagsByCanonicalKey[key] = tag
                }
                resolvedSuggestions.append(ResolvedBulkTagSuggestion(
                    suggestionID: suggestion.id,
                    tag: tag
                ))
                appliedTagNames.insert(tag.name)
            }
            applications.append(ResolvedBulkTagApplication(
                repoID: pending.repoID,
                selectedSuggestionIDs: pending.selectedSuggestionIDs,
                suggestions: resolvedSuggestions,
                appliedTagNames: appliedTagNames
            ))
        }
        return (applications, tagsByCanonicalKey)
    }

    private func markBulkTagApplicationsFailed(
        repoIDs: [Int64],
        error: Error,
        jobIndexByRepoID: [Int64: Int]
    ) async {
        let failure = BatchAIFailure(error: error)
        var updatedJobs = jobs
        for repoID in repoIDs {
            guard let index = jobIndexByRepoID[repoID] else { continue }
            updatedJobs[index].tagReviewState = .failed(failure)
        }
        jobs = updatedJobs
        // 只有失败路径退回逐项 best-effort checkpoint；正常批次始终使用单事务批量保存。
        await persistJobsBestEffort(repoIDs: Set(repoIDs))
    }

    private func persistBulkDraftItems(
        jobs proposedJobs: [BatchAIJob],
        repoIDs: [Int64],
        selectedRepoIDs: Set<Int64>,
        jobIndexByRepoID: [Int64: Int]
    ) async throws {
        guard !silent,
              isDraftCreated,
              let draftRepository,
              let activeDraftID
        else { return }
        let items = try repoIDs.map { repoID -> AIOrganizationDraftItem in
            guard let index = jobIndexByRepoID[repoID],
                  let repo = repoCache[repoID]
            else { throw CocoaError(.fileNoSuchFile) }
            return AIOrganizationDraftItem(
                repoID: repoID,
                payloadJSON: try encodedDraftItem(
                    job: proposedJobs[index],
                    repo: repo,
                    isSelectedForTagApplication: selectedRepoIDs.contains(repoID)
                )
            )
        }
        try await draftRepository.upsertItems(
            draftID: activeDraftID,
            kind: .batchTags,
            items: items
        )
    }

    private func advanceTagApplicationProgress(by processedCount: Int) {
        guard let progress = tagApplicationProgress else { return }
        tagApplicationProgress = BatchAITagApplicationProgress(
            processedRepositoryCount: min(
                progress.processedRepositoryCount + processedCount,
                progress.totalRepositoryCount
            ),
            totalRepositoryCount: progress.totalRepositoryCount
        )
    }

    /// 打开整批落库会话锁；`selectionCount` 非 nil 时冻结底栏「已选 N 个」。
    private func beginBulkTagApplication(selectionCount: Int?) {
        isBulkApplyingSuggestedTags = true
        frozenTagReviewSelectionCount = selectionCount
        tagApplicationProgress = selectionCount.map {
            BatchAITagApplicationProgress(
                processedRepositoryCount: 0,
                totalRepositoryCount: $0
            )
        }
    }

    /// 关闭整批落库会话锁，并合并发布本批产生的标签变更通知。
    private func endBulkTagApplication() {
        isBulkApplyingSuggestedTags = false
        frozenTagReviewSelectionCount = nil
        tagApplicationProgress = nil
        notifyTagsChangedIfNeeded()
    }

    // MARK: - 主循环

    private func launchRunLoop() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in
            guard let self else { return }
            guard await self.prepareDraftForRun() else {
                self.runLoopTask = nil
                return
            }
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
        var effectiveOptions = options

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
            if silent, sharedTagLibrary?.isEmpty == true {
                // 后台自动整理没有用户确认词表的界面；空标签库时逐仓让 LLM 自由造词会稳定
                // 退化成“一仓一标签”。因此只跳过标签子任务，摘要仍可继续，标签体系交给
                // 用户下次打开手动整理时通过本地全局引导建立。
                effectiveOptions.actions.remove(.tags)
                AppLog.ai.notice("[batch-ai] automatic tags skipped: empty canonical tag library")
            }
        }

        if effectiveOptions.actions.isEmpty {
            let now = Date.now
            for index in jobs.indices where jobs[index].status == .queued {
                jobs[index].status = .ignored
                jobs[index].tagReviewState = .ignored
                jobs[index].ignoreReason = .emptyTagLibrary
                jobs[index].finishedAt = now
            }
        } else {
            let workerOptions = effectiveOptions
            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<Self.defaultConcurrency {
                    group.addTask { [weak self] in
                        await self?.runWorker(index: workerIndex, options: workerOptions)
                    }
                }
                await group.waitForAll()
            }
        }

        if !cancelRequested,
           !isPaused,
           jobs.allSatisfy({ $0.status != .queued && $0.status != .processing }) {
            await prepareTagExpansionIfNeeded(options: effectiveOptions)
        }

        // 循环退出：若全部终态则关掉 isRunning；否则保留状态等用户 resume / cancel。
        if isFinished || cancelRequested || jobs.allSatisfy({ $0.status != .queued }) {
            // 用户取消时，把可能停在 .processing 的孤儿 job 收尾，避免 UI 留"永远转圈"行。
            if cancelRequested {
                let now = Date()
                for idx in jobs.indices where jobs[idx].status == .processing {
                    jobs[idx].status = .failed
                    jobs[idx].failure = accountResetRequested ? .interrupted : .cancelled
                    jobs[idx].errorDiagnostic = nil
                    jobs[idx].copyDiagnostic = nil
                    jobs[idx].finishedAt = now
                }
                await persistJobsBestEffort(repoIDs: Set(jobs.map(\.repoId)))
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
        /// 闭集首轮没有任何现有标签可复用。人工批次稍后进入整批扩词，自动批次只记忽略。
        var isVocabularyMiss: Bool
        var needsVocabularyExpansion: Bool
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
        let diagnostic = DiagnosticOperation(category: "ai", name: "batchAI.job")
        await DiagnosticContext.$current.withValue(diagnostic) {
            await processClaimedJob(repoID: repoID, options: options, diagnostic: diagnostic)
        }
    }

    /// 每次尝试仅保存有界上下文；是否耗尽重试仍由原队列状态机决定。
    private func processClaimedJob(repoID: Int64, options: BatchAIQueueOptions, diagnostic: DiagnosticOperation) async {
        defer { processingJobIDs.remove(repoID) }
        defer {
            let failed = jobs.first { $0.repoId == repoID }?.status == .failed
            diagnostic.finish(Task.isCancelled || cancelRequested ? .cancelled : failed ? .failed : .succeeded)
        }
        var outputAvailable = false
        do {
            // processing 必须先 durable 再请求 AI。若 App 在请求期间退出，恢复时才能明确
            // 标成“处理中断”，而不是把同一 queued 项静默再调用一次并重复消耗 token。
            try await persistJob(repoID: repoID)
            diagnostic.event(phase: "jobPersisted")
            let result = try await processSingle(jobId: repoID, options: options)
            outputAvailable = true
            diagnostic.event(phase: "response", fields: ["outputAvailable": .boolean(true)])
            try Task.checkCancellation()
            guard !cancelRequested else { return }
            try await applyResult(jobId: repoID, result: result, options: options)
            retryNotBeforeByRepoID[repoID] = nil
            try await persistJob(repoID: repoID)
        } catch {
            guard !cancelRequested, !Task.isCancelled, !(error is CancellationError) else { return }
            handleFailure(jobId: repoID, error: error, options: options, outputAvailable: outputAvailable)
            await persistJobBestEffort(repoID: repoID)
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
        let rawSuggestions: [AITagSuggestion]
        var reuseOnlyPolicy = options.tagGenerationPolicy
        // 队列首轮只做闭集分类；允许新增的意图留到所有仓库处理完后统一消费，
        // 不能继续让每个 Worker 独立触发 `.newOnly` LLM fallback。
        reuseOnlyPolicy.allowNewTags = false
        if includesTags && !includesSummary {
            // 纯标签任务进入标签专用路由；调用来源保留队列语义，但首轮始终关闭新增，
            // Jev 未覆盖仓库统一留给批次结束后的全局概念发现。
            let suggestionsByRepoID = try await insightService.generateBatchTagSuggestions(
                for: [repo],
                tagHintsByRepoID: [repo.id: hints],
                invocationMode: invocationMode,
                tagGenerationPolicy: reuseOnlyPolicy
            )
            rawSuggestions = suggestionsByRepoID[repo.id] ?? []
        } else if includesSummary {
            let insight = try await insightService.generateBatchInsight(
                for: repo,
                existingTagHints: hints,
                includeSummary: includesSummary,
                includeTags: includesTags,
                // 标签单独运行时不需要摘要上下文，避免无意义地准备代码或外部搜索。
                codeContextEnabledOverride: includesSummary ? options.codeContextEnabledOverride : nil,
                externalContextEnabledOverride: includesSummary ? options.externalContextEnabledOverride : nil,
                tagGenerationPolicy: reuseOnlyPolicy
            )
            rawSuggestions = insight.insight.suggestedTags
        } else {
            rawSuggestions = []
        }

        let suggestions: [AITagSuggestion]
        if includesTags,
           options.autoCreateMissingTags,
           let initialTagCanonicalKeys {
            // 非 Jev Provider 仍可能在 reuse-first 响应里夹带新名称。整批扩词开启时，首轮
            // 必须在本地再次收口为闭集，保证所有新词都经过同一个 5 个上限与确认页。
            suggestions = rawSuggestions.filter { suggestion in
                initialTagCanonicalKeys.contains(AITagSuggestionPolicy.canonicalKey(suggestion.name))
            }
        } else {
            suggestions = rawSuggestions
        }

        let isVocabularyMiss = includesTags
            && options.autoCreateMissingTags
            && suggestions.isEmpty

        // 标签任务的空结果没有任何可审核或可应用内容，不能计为“全部完成”。
        // 摘要单独运行仍允许 suggestions 为空，因此只在本仓库确实执行标签任务时失败。
        // 唯一例外是开启整批扩词后的闭集 miss：它是合法覆盖边界，不是 Provider 失败。
        guard !includesTags || !suggestions.isEmpty || isVocabularyMiss else {
            throw AIRecommendationValidationError.emptyTagSuggestions
        }

        return JobOutcome(
            suggestions: suggestions,
            isVocabularyMiss: isVocabularyMiss,
            needsVocabularyExpansion: isVocabularyMiss && !silent
        )
    }

    /// 在创建 jobs 前一次性校验本批次会调用到的任务配置。
    ///
    /// 校验必须留在 Service 层：手动弹窗和自动调度器都能启动队列，只在 UI 禁用按钮
    /// 会留下绕过路径。`ensureGenerationClientsReady` 只构造客户端，不发网络请求。
    private func validateConfiguration(
        for options: BatchAIQueueOptions,
        invocationMode: BatchAIInvocationMode
    ) throws {
        try insightService.ensureGenerationClientsReady(
            includeSummary: options.actions.contains(.summary),
            includeTags: options.actions.contains(.tags),
            invocationMode: invocationMode,
            tagGenerationPolicy: options.tagGenerationPolicy
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
        // 每次生成结果都会重新判定是否忽略，不能沿用重试前或上一阶段留下的原因。
        jobs[idx].ignoreReason = nil

        if result.needsVocabularyExpansion {
            uncoveredTagRepositoryIDs.insert(jobId)
        }

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
                    suggestions: aboveThreshold
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
                // 阈值只决定能否自动应用，不能替用户丢弃有效建议。未创建的高置信度标签
                // 优先保持选中；只有不存在这类待办时，才预选最接近阈值的一项低置信度建议，
                // 避免同一仓库把 95% 与 80% 一起默认勾上而弱化阈值语义。
                jobs[currentIndex].suggestedTags = pendingSuggestions
                var selectedIDs = Set(autoApplyOutcome.unresolvedSuggestions.map(\.id))
                if selectedIDs.isEmpty,
                   let closestBelowThreshold = belowThreshold.max(by: { $0.confidence < $1.confidence }) {
                    selectedIDs.insert(closestBelowThreshold.id)
                }
                jobs[currentIndex].selectedSuggestedTagIDs = selectedIDs
                jobs[currentIndex].tagReviewState = .pending
                if !selectedIDs.isEmpty {
                    selectedRepoIDsForTagApplication.insert(jobId)
                }
            } else if autoApplyOutcome.appliedNames.isEmpty, !suggestions.isEmpty {
                shouldMarkIgnored = true
                // 正常的低置信度跳过与“没有可直接复用的现有标签”分开记录，
                // 避免统一显示成阈值问题而误导用户。
                jobs[currentIndex].ignoreReason = aboveThreshold.isEmpty
                    ? .belowConfidenceThreshold
                    : .vocabularyMiss
            }
        }

        guard let finalIndex = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
        jobs[finalIndex].didGenerateSummary = didSummary
        jobs[finalIndex].finishedAt = Date()
        if result.isVocabularyMiss, !didSummary {
            jobs[finalIndex].tagReviewState = .ignored
            jobs[finalIndex].ignoreReason = .vocabularyMiss
            shouldMarkIgnored = true
        }
        let wroteAnything = !jobs[finalIndex].appliedTagNames.isEmpty
        jobs[finalIndex].status = shouldMarkIgnored && !didSummary && !wroteAnything ? .ignored : .completed
        if jobs[finalIndex].status != .ignored, jobs[finalIndex].tagReviewState != .ignored {
            jobs[finalIndex].ignoreReason = nil
        }
    }

    // MARK: - 整批增量词表

    private struct TagExpansionAccumulator {
        var displayName: String
        var matchesByRepositoryID: [Int64: TagTaxonomyRepositoryMatch] = [:]
    }

    /// Jev 闭集首轮结束后，只为全部未覆盖仓库发起一次 LLM 请求。
    ///
    /// 这里不创建标签，也不直接采用 LLM 的逐仓结果；返回值只被压缩成最多 5 个全局候选，
    /// 后续必须经过用户确认，再用扩充后的完整词表重新分类。这样“发现概念”与“归类仓库”
    /// 是两个明确阶段，不能退化回一仓一次 LLM、一仓一个新标签。
    private func prepareTagExpansionIfNeeded(options: BatchAIQueueOptions) async {
        guard !silent,
              options.actions.contains(.tags),
              options.autoCreateMissingTags,
              pendingTagExpansionSession == nil,
              !uncoveredTagRepositoryIDs.isEmpty
        else { return }

        let repositories = jobs.compactMap { job -> Repo? in
            guard uncoveredTagRepositoryIDs.contains(job.repoId) else { return nil }
            return repoCache[job.repoId]
        }
        guard !repositories.isEmpty else {
            uncoveredTagRepositoryIDs = []
            tagExpansionError = nil
            await persistDraftHeaderBestEffort()
            return
        }

        let library = sharedTagLibrary ?? []
        var hintsByRepositoryID: [Int64: AITagHints] = [:]
        for repository in repositories {
            hintsByRepositoryID[repository.id] = await RepoAIInsightService.makeTagHints(
                for: repository,
                repoTagRepository: repoTagRepository,
                sharedLibraryTags: library
            )
        }

        do {
            let discovered = try await insightService.generateBatchTagSuggestions(
                for: repositories,
                tagHintsByRepoID: hintsByRepositoryID,
                purpose: .newOnly
            )
            let session = makeTagExpansionSession(
                repositories: repositories,
                suggestionsByRepositoryID: discovered
            )
            pendingTagExpansionSession = session
            tagExpansionError = nil
            if session == nil {
                // 模型没有找到跨仓库可复用概念时，本轮闭集 miss 就是最终结果；保留 ignored
                // 行供用户检查，但不要制造一个无法确认的空工作台。
                uncoveredTagRepositoryIDs = []
            }
        } catch {
            tagExpansionError = Self.userVisibleFailureMessage(for: error)
            AppLog.ai.error(
                "[batch-ai] pooled tag discovery failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        await persistDraftHeaderBestEffort()
    }

    /// Provider 返回的仍是逐仓 JSON；这里用 canonical key 合并为全局候选，并用跨仓库支持数
    /// 作为确定性完整性边界。多仓批次中只出现一次的仓库私有词会被丢弃，单仓批次则允许
    /// 一个候选，否则用户选择单个仓库时永远无法扩充词表。
    private func makeTagExpansionSession(
        repositories: [Repo],
        suggestionsByRepositoryID: [Int64: [AITagSuggestion]]
    ) -> TagTaxonomyBootstrapSession? {
        let existingKeys = initialTagCanonicalKeys ?? []
        var accumulators: [String: TagExpansionAccumulator] = [:]

        for repository in repositories {
            var seenKeys: Set<String> = []
            for suggestion in suggestionsByRepositoryID[repository.id] ?? [] {
                let displayName = AITagSuggestionPolicy.normalizedDisplayName(suggestion.name)
                let key = AITagSuggestionPolicy.canonicalKey(displayName)
                guard !displayName.isEmpty,
                      displayName.count <= 36,
                      !key.isEmpty,
                      !existingKeys.contains(key),
                      seenKeys.insert(key).inserted
                else { continue }

                var accumulator = accumulators[key] ?? TagExpansionAccumulator(displayName: displayName)
                accumulator.matchesByRepositoryID[repository.id] = TagTaxonomyRepositoryMatch(
                    repoID: repository.id,
                    repositoryFullName: repository.fullName,
                    confidence: min(max(suggestion.confidence, 0), 1),
                    signals: [.llm]
                )
                accumulators[key] = accumulator
            }
        }

        let minimumSupport = repositories.count > 1 ? 2 : 1
        let candidates = accumulators.compactMap { key, accumulator -> (TagTaxonomyCandidate, Double)? in
            let matches = accumulator.matchesByRepositoryID.values.sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
                return lhs.repositoryFullName < rhs.repositoryFullName
            }
            guard matches.count >= minimumSupport else { return nil }
            let averageConfidence = matches.reduce(0.0) { $0 + $1.confidence } / Double(matches.count)
            return (
                TagTaxonomyCandidate(
                    id: "llm:\(key)",
                    name: accumulator.displayName,
                    supportCount: matches.count,
                    targetSupportCount: matches.count,
                    signals: [.llm],
                    sampleRepositoryNames: Array(matches.prefix(8).map(\.repositoryFullName)),
                    targetMatches: matches
                ),
                averageConfidence
            )
        }
        .sorted { lhs, rhs in
            if lhs.0.supportCount != rhs.0.supportCount { return lhs.0.supportCount > rhs.0.supportCount }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .prefix(Self.maximumTagExpansionCount)
        .map(\.0)

        guard !candidates.isEmpty else { return nil }
        return TagTaxonomyBootstrapSession(
            kind: .expansion,
            suggestionEngine: .llm,
            targetRepositories: repositories,
            candidates: candidates,
            defaultSelectedCandidateIDs: Set(candidates.map(\.id)),
            corpusRepositoryCount: repositories.count,
            cachedReadmeCount: 0
        )
    }

    /// 批次级发现失败后的唯一重试入口；不会重放已完成的逐仓 Jev / 摘要请求。
    func retryTagExpansionDiscovery() async {
        guard !isRunning,
              pendingTagExpansionSession == nil,
              tagExpansionError != nil,
              !uncoveredTagRepositoryIDs.isEmpty,
              let options
        else { return }
        isRunning = true
        tagExpansionError = nil
        await prepareTagExpansionIfNeeded(options: options)
        isRunning = false
    }

    /// 用户可以拒绝本次词表扩充并直接检查现有结果；未覆盖仓库保持“已忽略”，
    /// 但会话不再被待确认候选阻塞。这个出口保证“需要确认”不等于“强制接受 AI 新词”。
    func skipPendingTagExpansion() async {
        guard pendingTagExpansionSession != nil
                || tagExpansionError != nil
                || !uncoveredTagRepositoryIDs.isEmpty
        else { return }
        pendingTagExpansionSession = nil
        uncoveredTagRepositoryIDs = []
        tagExpansionError = nil
        await persistDraftHeaderBestEffort()
    }

    /// 用户确认全局候选后创建标签，再用扩充后的闭集词表重新分类未覆盖仓库。
    ///
    /// LLM 概念发现结果只负责解释“为什么值得扩词”，不会直接变成最终仓库标签；重新分类
    /// 仍走统一 Provider 路由，因此 Jev 可用时最终置信度来自 Jev，且 repo_tags 继续等待
    /// 用户在审核页逐仓确认。
    func confirmPendingTagExpansion(
        selectedCandidates: [TagTaxonomyCandidate]
    ) async -> String? {
        guard let session = pendingTagExpansionSession,
              session.kind == .expansion,
              !selectedCandidates.isEmpty,
              selectedCandidates.count <= Self.maximumTagExpansionCount
        else {
            return String.l10n("batchAI.expansion.validation")
        }

        let allowedCandidateIDs = Set(session.candidates.map(\.id))
        let normalizedCandidates = selectedCandidates.compactMap { candidate -> TagTaxonomyCandidate? in
            guard allowedCandidateIDs.contains(candidate.id) else { return nil }
            var normalized = candidate
            normalized.name = AITagSuggestionPolicy.normalizedDisplayName(candidate.name)
            return normalized
        }
        let keys = normalizedCandidates.map { AITagSuggestionPolicy.canonicalKey($0.name) }
        guard normalizedCandidates.count == selectedCandidates.count,
              keys.allSatisfy({ !$0.isEmpty }),
              Set(keys).count == keys.count
        else {
            return String.l10n("batchAI.expansion.validation")
        }

        // 先把用户的改名与勾选写入草稿；若创建或重分类失败，重启后仍回到同一确认边界。
        pendingTagExpansionSession = TagTaxonomyBootstrapSession(
            kind: .expansion,
            suggestionEngine: .llm,
            targetRepositories: session.targetRepositories,
            candidates: normalizedCandidates,
            defaultSelectedCandidateIDs: Set(normalizedCandidates.map(\.id)),
            corpusRepositoryCount: session.corpusRepositoryCount,
            cachedReadmeCount: session.cachedReadmeCount
        )
        await persistDraftHeaderBestEffort()

        var createdAnyTag = false
        do {
            let existingTags = try await tagRepository.fetchAll()
            var tagsByCanonicalKey = Dictionary(
                existingTags.map { (AITagSuggestionPolicy.canonicalKey($0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for candidate in normalizedCandidates {
                let key = AITagSuggestionPolicy.canonicalKey(candidate.name)
                guard tagsByCanonicalKey[key] == nil else { continue }
                let tag = makeUserConfirmedTag(named: candidate.name)
                try await tagRepository.create(tag)
                tagsByCanonicalKey[key] = tag
                createdAnyTag = true
            }

            let fullLibrary = tagsByCanonicalKey.values
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            sharedTagLibrary = fullLibrary
            initialTagCanonicalKeys = Set(tagsByCanonicalKey.keys)

            var hintsByRepositoryID: [Int64: AITagHints] = [:]
            for repository in session.targetRepositories {
                hintsByRepositoryID[repository.id] = await RepoAIInsightService.makeTagHints(
                    for: repository,
                    repoTagRepository: repoTagRepository,
                    sharedLibraryTags: fullLibrary
                )
            }
            let reclassified = try await insightService.generateBatchTagSuggestions(
                for: session.targetRepositories,
                tagHintsByRepoID: hintsByRepositoryID,
                invocationMode: .manual,
                tagGenerationPolicy: AITagGenerationPolicy(
                    allowNewTags: false,
                    minimumReusableConfidence: options?.tagGenerationPolicy.minimumReusableConfidence ?? 0
                )
            )

            let now = Date.now
            let vocabularyKeys = initialTagCanonicalKeys ?? []
            for repository in session.targetRepositories {
                guard let index = jobs.firstIndex(where: { $0.repoId == repository.id }) else { continue }
                let suggestions = (reclassified[repository.id] ?? []).filter { suggestion in
                    vocabularyKeys.contains(AITagSuggestionPolicy.canonicalKey(suggestion.name))
                }
                jobs[index].suggestedTags = suggestions
                jobs[index].suggestedTagAvailability = Dictionary(
                    uniqueKeysWithValues: suggestions.map { ($0.id, .existing) }
                )
                jobs[index].selectedSuggestedTagIDs = Set(suggestions.map(\.id))
                jobs[index].failure = nil
                jobs[index].errorDiagnostic = nil
                jobs[index].copyDiagnostic = nil
                jobs[index].finishedAt = now
                if suggestions.isEmpty {
                    selectedRepoIDsForTagApplication.remove(repository.id)
                    jobs[index].tagReviewState = jobs[index].didGenerateSummary ? .notRequired : .ignored
                    jobs[index].status = jobs[index].didGenerateSummary ? .completed : .ignored
                    jobs[index].ignoreReason = jobs[index].didGenerateSummary ? nil : .vocabularyMiss
                } else {
                    selectedRepoIDsForTagApplication.insert(repository.id)
                    jobs[index].tagReviewState = .pending
                    jobs[index].status = .completed
                    jobs[index].ignoreReason = nil
                }
            }

            uncoveredTagRepositoryIDs = []
            pendingTagExpansionSession = nil
            tagExpansionError = nil
            await persistJobsBestEffort(repoIDs: Set(session.targetRepositories.map(\.id)))
            await persistDraftHeaderBestEffort()
            if createdAnyTag { onTagsChanged?() }
            return nil
        } catch {
            if createdAnyTag { onTagsChanged?() }
            let message = Self.userVisibleFailureMessage(for: error)
            tagExpansionError = message
            await persistDraftHeaderBestEffort()
            AppLog.ai.error(
                "[batch-ai] confirm tag expansion failed: \(error.localizedDescription, privacy: .public)"
            )
            return message
        }
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
    /// 批量自动应用没有逐项人工确认，不能因为模型自报高置信度就静默扩张标签库；词表外
    /// 名称会返回给当前批量窗口继续确认。这里使用宽松 canonical key，让
    /// `Open-Source` / `open source` 等形式差异复用已有记录。新增标签只能由扩词确认页或
    /// 逐仓人工确认入口创建，不能在这个底层写入路径保留旧的隐式扩词能力。
    private func applyTagsToRepo(
        repoId: Int64,
        suggestions: [AITagSuggestion]
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

            let tag = existingTagByName[normalized] ?? existingTagByKey[key]
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

    /// 处理单个 job 的失败：分流"重试" vs "终态失败"。
    private func handleFailure(jobId: Int64, error: Error, options: BatchAIQueueOptions,
                               outputAvailable: Bool = false) {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI",
            impact: outputAvailable ? .dataRisk : .blocked,
            summary: outputAvailable ? .dataSaveFailed : .aiUnavailable
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

        // 即使当前 job 已达到重试上限，剩余 queued jobs 仍需立即继承降速窗口，
        // 不能继续以五路并发撞击同一个已限流 Provider。
        if isRateLimited(error) {
            rateLimitCooldownUntil = .now.addingTimeInterval(Self.rateLimitCooldown)
        }

        if isPermanentError(error) || jobs[idx].attempts >= options.maxRetries {
            // 单次尝试失败不落盘；现有重试已耗尽或确定不可重试时才确认请求失败。
            friendly.record(category: "ai", operation: "batchAI.job", service: "ai-provider",
                context: ["repoID": String(jobId)],
                fields: ["attempt": .integer(jobs[idx].attempts), "outputAvailable": .boolean(outputAvailable)])
            jobs[idx].status = .failed
            jobs[idx].failure = failure
            jobs[idx].errorDiagnostic = diagnostic
            jobs[idx].copyDiagnostic = copyDiagnostic
            jobs[idx].ignoreReason = nil
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
        // 结构合法但业务结果不可用时，自动重复相同请求只会继续消耗配额；保留失败态，
        // 由用户检查模型 / 规则后通过现有“重试”入口再次发起。
        if error is AIRecommendationValidationError {
            return true
        }
        if error is TypeSafeClientError {
            // TypeSafeClient 已在单次请求内处理传输错误、408、429 与 5xx 的有限重试。
            // 这里再按 job 重试会形成乘法放大；失败行仍保留给用户通过现有入口显式重试。
            return true
        }
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
        if let aiError = error as? AIClientError, case .rateLimited = aiError {
            return true
        }
        return (error as? TypeSafeClientError)?.isRateLimitLike == true
    }

    // MARK: - 人工会话草稿

    /// 首次启动时先原子保存 Header 与全部 queued Item。后续 resume/重试复用同一 draft，
    /// 从而保证任何 Provider 请求开始前，数据库都已经知道该仓库正在本轮队列里。
    private func prepareDraftForRun() async -> Bool {
        guard !silent, !isDraftCreated else { return true }
        guard let draftRepository, let activeDraftID, let options, let startedAt else {
            // 测试或不支持持久化的注入环境保持原有行为。
            isDraftCreated = true
            return true
        }
        do {
            let header = makeDraftHeader(options: options, startedAt: startedAt)
            let items = try jobs.map { job in
                AIOrganizationDraftItem(
                    repoID: job.repoId,
                    payloadJSON: try encodedDraftItem(for: job.repoId)
                )
            }
            try await draftRepository.replaceDraft(AIOrganizationDraft(
                id: activeDraftID,
                kind: .batchTags,
                headerJSON: try AIOrganizationDraftJSON.encode(header),
                items: items
            ))
            isDraftCreated = true
            return true
        } catch {
            let now = Date.now
            for index in jobs.indices where jobs[index].status == .queued {
                jobs[index].status = .failed
                jobs[index].failure = BatchAIFailure(error: error)
                jobs[index].finishedAt = now
            }
            isRunning = false
            AppLog.database.error("[batch-ai] create draft failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func encodedDraftItem(for repoID: Int64) throws -> String {
        guard let job = jobs.first(where: { $0.repoId == repoID }),
              let repo = repoCache[repoID]
        else { throw CocoaError(.fileNoSuchFile) }
        return try encodedDraftItem(
            job: job,
            repo: repo,
            isSelectedForTagApplication: selectedRepoIDsForTagApplication.contains(repoID)
        )
    }

    /// 批量路径在发布内存状态前先持久化「拟提交快照」，因此不能通过 `jobs.first` 回读旧值。
    /// 显式传入 job 与选择态也消除了批量保存时对完整 jobs 数组的 O(n²) 重扫。
    private func encodedDraftItem(
        job: BatchAIJob,
        repo: Repo,
        isSelectedForTagApplication: Bool
    ) throws -> String {
        let snapshot = BatchAIOrganizationDraftItem(
            repo: repo,
            job: job,
            isSelectedForTagApplication: isSelectedForTagApplication
        )
        return try AIOrganizationDraftJSON.encode(snapshot)
    }

    private func makeDraftHeader(
        options: BatchAIQueueOptions,
        startedAt: Date
    ) -> BatchAIOrganizationDraftHeader {
        BatchAIOrganizationDraftHeader(
            options: options,
            startedAt: startedAt,
            pendingTagExpansionSession: pendingTagExpansionSession,
            uncoveredTagRepositoryIDs: uncoveredTagRepositoryIDs.isEmpty ? nil : uncoveredTagRepositoryIDs,
            tagExpansionError: tagExpansionError
        )
    }

    /// 草稿 Header 保存批次级扩词状态；逐仓 Item 的高频 checkpoint 不应重复改写它。
    private func persistDraftHeaderBestEffort() async {
        guard !silent,
              isDraftCreated,
              let draftRepository,
              let activeDraftID,
              let options,
              let startedAt
        else { return }
        do {
            try await draftRepository.updateHeader(
                draftID: activeDraftID,
                kind: .batchTags,
                headerJSON: try AIOrganizationDraftJSON.encode(
                    makeDraftHeader(options: options, startedAt: startedAt)
                )
            )
        } catch {
            AppLog.database.error(
                "[batch-ai] save draft header failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistJob(repoID: Int64) async throws {
        guard !silent,
              isDraftCreated,
              let draftRepository,
              let activeDraftID
        else { return }
        try await draftRepository.upsertItem(
            draftID: activeDraftID,
            kind: .batchTags,
            repoID: repoID,
            payloadJSON: try encodedDraftItem(for: repoID)
        )
    }

    private func persistJobBestEffort(repoID: Int64) async {
        do {
            try await persistJob(repoID: repoID)
        } catch {
            AppLog.database.error("[batch-ai] save draft item failed: repo=\(repoID, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistJobsBestEffort(repoIDs: Set<Int64>) async {
        for repoID in repoIDs {
            await persistJobBestEffort(repoID: repoID)
        }
    }

    private func schedulePersistJob(repoID: Int64) {
        Task { [weak self] in
            await self?.persistJobBestEffort(repoID: repoID)
        }
    }

    private func schedulePersistJobs(repoIDs: Set<Int64>) {
        guard !repoIDs.isEmpty else { return }
        Task { [weak self] in
            await self?.persistJobsBestEffort(repoIDs: repoIDs)
        }
    }

    private func deleteDraftItems(repoIDs: Set<Int64>) {
        guard !repoIDs.isEmpty,
              let draftRepository,
              let activeDraftID,
              isDraftCreated
        else { return }
        Task {
            do {
                try await draftRepository.deleteItems(
                    draftID: activeDraftID,
                    kind: .batchTags,
                    repoIDs: repoIDs
                )
            } catch {
                AppLog.database.error("[batch-ai] delete draft items failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func deleteActiveDraft() {
        guard let draftRepository, let activeDraftID, isDraftCreated else { return }
        Task {
            do {
                try await draftRepository.deleteDraft(draftID: activeDraftID, kind: .batchTags)
            } catch {
                AppLog.database.error("[batch-ai] delete draft failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Repo 缓存（避免每次 processSingle 都查库）

    /// repoId → Repo 的会话内缓存。由 start() 时填充。
    private var repoCache: [Int64: Repo] = [:]
}
