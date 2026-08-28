//
//  GitHubStarListAIGroupingSession.swift
//  Starcat
//
//  GitHub Lists AI 分组的独立会话状态机。
//
//  模块职责：
//  - 承载关闭 Sheet 后仍继续存在的分析进度、审核选择和应用结果；
//  - 以小批量、有限并发调用 AI，避免复用标签队列造成文案与取消语义串线；
//  - 把 GitHub mutation 的可重试错误、组织 OAuth 限制和永久错误分开呈现。
//
//  关键约束：
//  - AI 只能返回用户已创建且填写了规则的 List；应用前仍会重新减去最新 membership；
//  - 关闭窗口不取消，只有“停止分析”才取消 Task；generation 防止迟到结果覆盖新会话；
//  - GitHub 是远端真源。远端失败时绝不伪造本地成功，单仓失败也不阻断其余仓库。
//

import Foundation
import Observation

enum GitHubStarListAIGroupingJobStatus: Equatable, Sendable {
    case queued
    case analyzing
    case completed
    case failed
    case stopped
}

enum GitHubStarListAIGroupingSessionMode: Equatable, Sendable {
    case idle
    case manual
    case automatic
}

enum GitHubStarListAIApplyFailureKind: Equatable, Sendable {
    case organizationOAuthRestriction
    case transport
    case rateLimited
    case authentication
    case repositoryUnavailable
    case permanent
}

struct GitHubStarListAIApplyFailure: Equatable, Sendable {
    let kind: GitHubStarListAIApplyFailureKind
    let detail: String?

    var isRetryable: Bool {
        kind == .transport || kind == .rateLimited
    }

    /// 组织 OAuth 策略是仓库级确定性限制，重复调用不会恢复。
    /// 这类结果应直接结束本轮审核，避免用户逐条重试或手动忽略。
    var shouldAutomaticallyIgnore: Bool {
        kind == .organizationOAuthRestriction
    }

    var localizedMessage: String {
        switch kind {
        case .organizationOAuthRestriction:
            String.l10n("githubStarLists.aiGrouping.applyFailure.organizationRestriction")
        case .transport:
            detail ?? String.l10n("githubStarLists.aiGrouping.applyFailure.network")
        case .rateLimited:
            detail ?? String.l10n("githubStarLists.aiGrouping.applyFailure.rateLimited")
        case .authentication:
            String.l10n("githubStarLists.aiGrouping.applyFailure.authentication")
        case .repositoryUnavailable:
            String.l10n("githubStarLists.aiGrouping.applyFailure.repositoryUnavailable")
        case .permanent:
            detail ?? String.l10n("githubStarLists.aiGrouping.applyFailure.unknown")
        }
    }

    static func classify(_ error: Error) -> Self {
        guard let network = error as? NetworkError else {
            return Self(kind: .permanent, detail: Self.shortDetail(error.localizedDescription))
        }
        switch network {
        case .clientError(_, let message):
            let normalized = (message ?? "").lowercased()
            if normalized.contains("oauth app access restrictions")
                || normalized.contains("restricting access to your organization's data") {
                return Self(kind: .organizationOAuthRestriction, detail: nil)
            }
            return Self(kind: .permanent, detail: Self.shortDetail(message))
        case .transport:
            return Self(kind: .transport, detail: network.localizedDescription)
        case .serverError:
            // GitHub 5xx 与传输错误采用相同恢复入口，避免为用户暴露 HTTP 实现细节。
            return Self(kind: .transport, detail: network.localizedDescription)
        case .rateLimited:
            return Self(kind: .rateLimited, detail: network.localizedDescription)
        case .unauthorized:
            return Self(kind: .authentication, detail: nil)
        case .notFound:
            return Self(kind: .repositoryUnavailable, detail: nil)
        case .cancelled:
            return Self(kind: .transport, detail: String.l10n("network.error.cancelled"))
        case .invalidURL, .invalidResponse, .notModified, .decodingError:
            return Self(kind: .permanent, detail: network.localizedDescription)
        }
    }

    private static func shortDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 200 ? String(trimmed.prefix(197)) + "…" : trimmed
    }
}

enum GitHubStarListAIApplyState: Equatable, Sendable {
    case idle
    case applying
    case applied(Set<String>)
    case ignored(GitHubStarListAIApplyFailure)
    case failed(GitHubStarListAIApplyFailure)
}

struct GitHubStarListAIGroupingJob: Identifiable, Equatable, Sendable {
    var id: Int64 { repo.id }

    let repo: Repo
    var status: GitHubStarListAIGroupingJobStatus = .queued
    var suggestions: [GitHubStarListAISuggestion] = []
    var analysisFailure: BatchAIFailure?
    var applyState: GitHubStarListAIApplyState = .idle
    var finishedAt: Date?
}

/// 仓库分组开始页使用的轻量内存快照。
///
/// HomeViewModel 已经为 Sidebar 缓存了相同数据；打开 Sheet 时直接传递这份值，
/// 避免为了四个统计数字和分组规则再次查询 SQLite。完整仓库仍只在开始整理后加载。
struct GitHubStarListAIGroupingPreflightContext: Equatable, Sendable {
    let repositoryCount: Int
    let ungroupedRepositoryCount: Int
    let availableLists: [GitHubStarList]
    let membershipCountByListID: [String: Int]
    let rulesByListID: [String: GitHubStarListAIRule]
}

@MainActor
@Observable
final class GitHubStarListAIGroupingSession {
    private let repoRepository: any RepoRepositoryProtocol
    private let listService: GitHubStarListSyncService
    private let insightService: RepoAIInsightService
    private let entitlementGate: EntitlementGate

    private(set) var mode: GitHubStarListAIGroupingSessionMode = .idle
    private(set) var jobs: [GitHubStarListAIGroupingJob] = [] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var availableLists: [GitHubStarList] = [] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var rulesByListID: [String: GitHubStarListAIRule] = [:] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var existingListIDsByRepo: [Int64: Set<String>] = [:] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var selectedListIDsByRepo: [Int64: Set<String>] = [:] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var ignoredRepoIDs: Set<Int64> = [] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var isLoadingContext = false
    /// 点「开始整理」后才拉完整仓库；这段时间开始页必须继续显示，不能退回全屏 spinner。
    private(set) var isStartingManual = false
    private(set) var isRunning = false
    private(set) var isApplying = false
    private(set) var contextErrorMessage: String?
    /// 开始页仓库总数。用 COUNT 查询，不订阅完整 `[Repo]`。
    private(set) var preparedRepositoryCount = 0 {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var ungroupedRepositoryCount = 0 {
        didSet { presentationRevision &+= 1 }
    }

    /// 审核页只观察轻量 revision，再按帧合并生成展示快照。
    /// 不能让 SwiftUI 的 body 直接读取并转换近 2,000 个 jobs，否则每个批次状态变化都会重复排序和筛选。
    private(set) var presentationRevision: UInt64 = 0

    /// 应用成功后由 Sidebar 注入，合并刷新 Lists 计数与当前仓库列表。
    var onMembershipsChanged: (() -> Void)?

    /// 完整仓库只在点「开始整理」后加载。开始页若观察这个数组，1965 条赋值会拖住主线程 SwiftUI。
    @ObservationIgnored private var preparedRepos: [Repo] = []
    /// 0 个分组时 `availableLists` 为空，不能用它判断「已经准备过」。
    @ObservationIgnored private var hasPreparedManualContext = false
    @ObservationIgnored private(set) var membershipCountByListID: [String: Int] = [:]
    private var runTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private static let manualBatchSize = 12
    private static let manualConcurrency = 2
    private static let automaticBatchSize = 8

    init(
        repoRepository: any RepoRepositoryProtocol,
        listService: GitHubStarListSyncService,
        insightService: RepoAIInsightService,
        entitlementGate: EntitlementGate
    ) {
        self.repoRepository = repoRepository
        self.listService = listService
        self.insightService = insightService
        self.entitlementGate = entitlementGate
    }

    var totalCount: Int { jobs.count }
    /// 分析 payload 是否已从数据库展开。开始页为 false；点「开始整理」后为 true。
    var hasLoadedStarredRepositories: Bool { !preparedRepos.isEmpty }
    var preparedRepositoryIDs: [Int64] { preparedRepos.map(\.id) }
    var analyzedCount: Int { jobs.filter { $0.status == .completed || $0.status == .failed }.count }
    var suggestedCount: Int { jobs.filter { !$0.suggestions.isEmpty }.count }
    var noMatchCount: Int { jobs.filter { $0.status == .completed && $0.suggestions.isEmpty }.count }
    var analysisFailedCount: Int { jobs.filter { $0.status == .failed }.count }
    var applyFailedCount: Int {
        jobs.filter {
            if case .failed = $0.applyState { true } else { false }
        }.count
    }
    var appliedCount: Int {
        jobs.filter {
            if case .applied = $0.applyState { true } else { false }
        }.count
    }
    var isFinished: Bool { !jobs.isEmpty && analyzedCount == jobs.count }

    var candidateContexts: [GitHubStarListAIContext] {
        availableLists.compactMap { list in
            guard let rule = rulesByListID[list.id],
                  !rule.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return GitHubStarListAIContext(
                listId: list.id,
                name: list.name,
                instruction: rule.instruction,
                autoApplyEnabled: rule.autoApplyEnabled
            )
        }
    }

    /// 缺少 Sidebar 内存快照时的兜底路径。已存在的人工会话直接复用，避免重置选择与结果。
    ///
    /// 开始页不调用 `fetchAllStarred()`：近 2,000 个完整 `Repo` 会把主线程卡在 spinner 上。
    /// 用户还没有任何分组时 `availableLists` 为空，必须用 `hasPreparedManualContext` 判断是否已经准备。
    func prepareManualContext() async {
        if hasPreparedManualContext, mode == .manual { return }
        if mode == .automatic {
            stopAnalysis()
        }
        isLoadingContext = true
        contextErrorMessage = nil
        defer { isLoadingContext = false }
        do {
            async let starredCountResult = repoRepository.starredCount()
            async let ungroupedResult = listService.ungroupedRepoCount()
            async let membershipCountsResult = listService.repoCountsByList()
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            membershipCountByListID = try await membershipCountsResult
            preparedRepositoryCount = try await starredCountResult
            ungroupedRepositoryCount = try await ungroupedResult
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            mode = .manual
            hasPreparedManualContext = true
            if jobs.isEmpty {
                selectedListIDsByRepo = [:]
                ignoredRepoIDs = []
            }
        } catch {
            contextErrorMessage = error.localizedDescription
            hasPreparedManualContext = false
        }
    }

    /// 使用 Sidebar 已经加载到内存的快照进入人工整理，不再阻塞 Sheet 首帧查询数据库。
    ///
    /// 已经存在的人工审核任务必须继续复用冻结上下文，不能被 Sidebar 后续刷新覆盖；
    /// 只有尚未开始的开始页才接受最新缓存。
    func prepareManualContext(from context: GitHubStarListAIGroupingPreflightContext) {
        if mode == .manual, !jobs.isEmpty { return }
        if mode == .automatic {
            stopAnalysis()
        }
        preparedRepositoryCount = context.repositoryCount
        ungroupedRepositoryCount = context.ungroupedRepositoryCount
        availableLists = context.availableLists
        membershipCountByListID = context.membershipCountByListID
        rulesByListID = context.rulesByListID
        mode = .manual
        hasPreparedManualContext = true
        contextErrorMessage = nil
        if jobs.isEmpty {
            selectedListIDsByRepo = [:]
            ignoredRepoIDs = []
        }
    }

    /// 开始页改规则或新建分组后只重载 Lists / 规则 / 计数，不拉完整仓库。
    func reloadListsAndRules() async {
        do {
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let membershipCountsResult = listService.repoCountsByList()
            async let ungroupedResult = listService.ungroupedRepoCount()
            async let starredCountResult = repoRepository.starredCount()
            membershipCountByListID = try await membershipCountsResult
            preparedRepositoryCount = try await starredCountResult
            ungroupedRepositoryCount = try await ungroupedResult
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
        } catch {
            AppLog.ai.error("[githubListGrouping] reload lists/rules failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 点「开始整理」才展开全部 starred 仓库和 membership。开始页打开路径不得调用。
    func ensureStarredRepositoriesLoaded() async {
        guard preparedRepos.isEmpty else { return }
        do {
            async let reposResult = repoRepository.fetchAllStarred()
            async let assignmentsResult = listService.allListAssignments()
            preparedRepos = try await reposResult
            preparedRepositoryCount = preparedRepos.count
            existingListIDsByRepo = try await assignmentsResult.mapValues { Set($0.map(\.id)) }
        } catch {
            contextErrorMessage = error.localizedDescription
        }
    }

    /// 空规则不能开自动整理。开始页卡片就地保存，不经过分组编辑 Sheet。
    func saveRule(listID: String, instruction: String, autoApplyEnabled: Bool) async {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = !normalized.isEmpty && autoApplyEnabled
        do {
            try await listService.saveAIRule(
                listID: listID,
                instruction: normalized,
                autoApplyEnabled: enabled
            )
            rulesByListID[listID] = GitHubStarListAIRule(
                listId: listID,
                instruction: normalized,
                autoApplyEnabled: enabled,
                updatedAt: ISO8601DateFormatter.shared.string(from: Date())
            )
        } catch {
            AppLog.ai.error("[githubListGrouping] save rule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func startManual() async {
        do {
            try entitlementGate.requirePro(.batchAI)
        } catch {
            contextErrorMessage = error.localizedDescription
            return
        }
        if !hasPreparedManualContext {
            await prepareManualContext()
        }
        guard contextErrorMessage == nil, !candidateContexts.isEmpty else { return }
        isStartingManual = true
        defer { isStartingManual = false }
        await ensureStarredRepositoriesLoaded()
        guard contextErrorMessage == nil, !preparedRepos.isEmpty else { return }
        beginAnalysis(
            repos: preparedRepos,
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            batchSize: Self.manualBatchSize,
            concurrency: Self.manualConcurrency,
            automaticThreshold: nil
        )
    }

    /// 继续只处理尚未完成或分析失败的仓库，保留此前已生成建议和用户审核选择。
    func continueManual() {
        guard mode == .manual, !isRunning else { return }
        let retryRepos = jobs.compactMap { job -> Repo? in
            job.status == .queued || job.status == .stopped || job.status == .failed ? job.repo : nil
        }
        guard !retryRepos.isEmpty else { return }
        beginAnalysis(
            repos: retryRepos,
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            batchSize: Self.manualBatchSize,
            concurrency: Self.manualConcurrency,
            automaticThreshold: nil,
            replaceJobs: false
        )
    }

    func retryAnalysis(repoID: Int64) {
        guard mode == .manual,
              !isRunning,
              let repo = jobs.first(where: { $0.id == repoID })?.repo
        else { return }
        beginAnalysis(
            repos: [repo],
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            batchSize: 1,
            concurrency: 1,
            automaticThreshold: nil,
            replaceJobs: false
        )
    }

    /// 后台自动分组使用独立会话，但不保留审核选择。人工任务优先，运行中时后台直接让位。
    func startAutomatic(
        repos: [Repo],
        confidenceThreshold: Double
    ) async -> Bool {
        guard mode != .manual, !isRunning, !isApplying, !repos.isEmpty else { return false }
        do {
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let assignmentsResult = listService.allListAssignments()
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            existingListIDsByRepo = try await assignmentsResult.mapValues { Set($0.map(\.id)) }
        } catch {
            AppLog.ai.error("[githubListGrouping] automatic context failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let automaticCandidates = candidateContexts.filter(\.autoApplyEnabled)
        guard !automaticCandidates.isEmpty else { return false }
        beginAnalysis(
            repos: repos,
            candidates: automaticCandidates,
            existingMemberships: existingListIDsByRepo,
            mode: .automatic,
            batchSize: Self.automaticBatchSize,
            concurrency: 1,
            automaticThreshold: GitHubStarListAutoGroupingSettings.clamp(confidenceThreshold)
        )
        return true
    }

    func stopAnalysis() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        for index in jobs.indices where jobs[index].status == .analyzing || jobs[index].status == .queued {
            jobs[index].status = .stopped
        }
        if mode == .automatic {
            resetToIdle()
        }
    }

    func discardManualSession() {
        stopAnalysis()
        applyTask?.cancel()
        applyTask = nil
        isApplying = false
        jobs = []
        selectedListIDsByRepo = [:]
        ignoredRepoIDs = []
        preparedRepos = []
        preparedRepositoryCount = 0
        ungroupedRepositoryCount = 0
        membershipCountByListID = [:]
        hasPreparedManualContext = false
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        mode = .idle
        contextErrorMessage = nil
        isStartingManual = false
    }

    /// 只准备了上下文但没有启动分析时，Sheet 关闭应释放人工模式，让后台自动分组继续工作。
    /// 已有任务或结果时必须保留会话，用户下次打开才能从原进度继续审核。
    func releaseManualContextIfUnused() {
        guard mode == .manual, jobs.isEmpty, !isRunning, !isApplying else { return }
        resetToIdle()
    }

    func toggleSelection(repoID: Int64, listID: String) {
        guard mode == .manual,
              availableLists.contains(where: { $0.id == listID }),
              !(existingListIDsByRepo[repoID] ?? []).contains(listID)
        else { return }
        var selected = selectedListIDsByRepo[repoID] ?? []
        if selected.contains(listID) {
            selected.remove(listID)
        } else {
            selected.insert(listID)
        }
        selectedListIDsByRepo[repoID] = selected
        ignoredRepoIDs.remove(repoID)
        resetApplyStateForNewReview(repoID: repoID)
    }

    func selectAllSuggestions(repoID: Int64) {
        guard let job = jobs.first(where: { $0.id == repoID }) else { return }
        let current = existingListIDsByRepo[repoID] ?? []
        selectedListIDsByRepo[repoID] = Set(job.suggestions.map(\.listId)).subtracting(current)
        ignoredRepoIDs.remove(repoID)
        resetApplyStateForNewReview(repoID: repoID)
    }

    func clearSelection(repoID: Int64) {
        selectedListIDsByRepo[repoID] = []
        resetApplyStateForNewReview(repoID: repoID)
    }

    func ignore(repoID: Int64) {
        selectedListIDsByRepo[repoID] = []
        ignoredRepoIDs.insert(repoID)
        resetApplyStateForNewReview(repoID: repoID)
    }

    func applySelected(repoIDs: Set<Int64>? = nil) {
        guard mode == .manual, !isApplying else { return }
        let selectedRepos = jobs.compactMap { job -> Repo? in
            guard repoIDs == nil || repoIDs?.contains(job.id) == true,
                  !(selectedListIDsByRepo[job.id] ?? []).isEmpty
            else { return nil }
            return job.repo
        }
        guard !selectedRepos.isEmpty else { return }

        isApplying = true
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMembershipsBeforeApply()
            for repo in selectedRepos {
                guard !Task.isCancelled else { break }
                await self.applyOne(repo: repo, allowAutomaticRetry: true)
            }
            self.isApplying = false
            self.applyTask = nil
        }
    }

    func retryApply(repoID: Int64) {
        guard mode == .manual,
              !isApplying,
              let job = jobs.first(where: { $0.id == repoID }),
              case .failed(let failure) = job.applyState,
              failure.isRetryable
        else { return }
        isApplying = true
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMembershipsBeforeApply()
            await self.applyOne(repo: job.repo, allowAutomaticRetry: true)
            self.isApplying = false
            self.applyTask = nil
        }
    }

    func retryAllRecoverableApplyFailures() {
        let repoIDs = Set(jobs.compactMap { job -> Int64? in
            guard case .failed(let failure) = job.applyState, failure.isRetryable else { return nil }
            return job.id
        })
        applySelected(repoIDs: repoIDs)
    }

    private func beginAnalysis(
        repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        mode: GitHubStarListAIGroupingSessionMode,
        batchSize: Int,
        concurrency: Int,
        automaticThreshold: Double?,
        replaceJobs: Bool = true
    ) {
        generation &+= 1
        let currentGeneration = generation
        runTask?.cancel()
        self.mode = mode
        isRunning = true
        contextErrorMessage = nil
        if replaceJobs {
            jobs = repos.map { GitHubStarListAIGroupingJob(repo: $0) }
            selectedListIDsByRepo = [:]
            ignoredRepoIDs = []
        } else {
            let retryIDs = Set(repos.map(\.id))
            for index in jobs.indices where retryIDs.contains(jobs[index].id) {
                jobs[index].status = .queued
                jobs[index].analysisFailure = nil
            }
        }

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis(
                repos: repos,
                candidates: candidates,
                existingMemberships: existingMemberships,
                batchSize: batchSize,
                concurrency: max(1, concurrency),
                automaticThreshold: automaticThreshold,
                generation: currentGeneration
            )
        }
    }

    private func runAnalysis(
        repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        batchSize: Int,
        concurrency: Int,
        automaticThreshold: Double?,
        generation: UInt64
    ) async {
        let batches = stride(from: 0, to: repos.count, by: batchSize).map { start in
            Array(repos[start..<min(start + batchSize, repos.count)])
        }

        var cursor = 0
        while cursor < batches.count, !Task.isCancelled, generation == self.generation {
            let wave = Array(batches[cursor..<min(cursor + concurrency, batches.count)])
            cursor += wave.count
            let waveRepoIDs = Set(wave.flatMap { $0.map(\.id) })
            for index in jobs.indices where waveRepoIDs.contains(jobs[index].id) {
                jobs[index].status = .analyzing
            }

            await withTaskGroup(of: AnalysisOutcome.self) { group in
                for batch in wave {
                    group.addTask { [insightService] in
                        do {
                            let results = try await insightService.generateGitHubListSuggestions(
                                for: batch,
                                candidates: candidates,
                                existingListIDsByRepo: existingMemberships
                            )
                            return .success(repos: batch, results: results)
                        } catch {
                            return .failure(repos: batch, error: BatchAIFailure(error: error))
                        }
                    }
                }

                for await outcome in group {
                    guard generation == self.generation, !Task.isCancelled else { continue }
                    await self.integrate(outcome, automaticThreshold: automaticThreshold)
                }
            }
        }

        guard generation == self.generation else { return }
        isRunning = false
        runTask = nil
        if mode == .automatic {
            resetToIdle()
        }
    }

    private func integrate(
        _ outcome: AnalysisOutcome,
        automaticThreshold: Double?
    ) async {
        switch outcome {
        case .success(let repos, let results):
            for repo in repos {
                guard let index = jobs.firstIndex(where: { $0.id == repo.id }) else { continue }
                let suggestions = results[repo.id] ?? []
                jobs[index].suggestions = suggestions
                jobs[index].status = .completed
                jobs[index].analysisFailure = nil
                jobs[index].finishedAt = .now

                if let automaticThreshold {
                    let approved = GitHubStarListAISuggestionPolicy.automaticSuggestions(
                        from: suggestions,
                        candidates: candidateContexts,
                        confidenceThreshold: automaticThreshold
                    )
                    selectedListIDsByRepo[repo.id] = Set(approved.map(\.listId))
                    if !approved.isEmpty {
                        await applyOne(repo: repo, allowAutomaticRetry: true)
                    }
                } else {
                    // 每次都从当前 membership 派生默认选择，关闭再开不会把已应用关系重新选中。
                    let current = existingListIDsByRepo[repo.id] ?? []
                    selectedListIDsByRepo[repo.id] = Set(suggestions.map(\.listId)).subtracting(current)
                }
            }
        case .failure(let repos, let failure):
            let cancelled = if case .cancelled = failure { true } else { Task.isCancelled }
            for repo in repos {
                guard let index = jobs.firstIndex(where: { $0.id == repo.id }) else { continue }
                jobs[index].status = cancelled ? .stopped : .failed
                jobs[index].analysisFailure = cancelled ? nil : failure
                jobs[index].finishedAt = .now
            }
        }
    }

    private func refreshMembershipsBeforeApply() async {
        do {
            let latest = try await listService.allListAssignments()
            existingListIDsByRepo = latest.mapValues { Set($0.map(\.id)) }
        } catch {
            AppLog.network.error("GitHub star list AI membership refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyOne(repo: Repo, allowAutomaticRetry: Bool) async {
        guard let index = jobs.firstIndex(where: { $0.id == repo.id }) else { return }
        let current = existingListIDsByRepo[repo.id] ?? []
        let selected = selectedListIDsByRepo[repo.id] ?? []
        let requested = selected.subtracting(current)
        guard !requested.isEmpty else {
            selectedListIDsByRepo[repo.id] = []
            // 应用前刷新可能发现目标已经由同步、上一次超时请求或用户手动操作完成。
            // 这是成功的幂等收敛，不应继续保留“应用失败”，否则用户会无限重试。
            let alreadyApplied = selected.intersection(current)
            if !alreadyApplied.isEmpty {
                jobs[index].applyState = .applied(alreadyApplied)
            }
            return
        }
        jobs[index].applyState = .applying

        let maximumAttempts = allowAutomaticRetry ? 3 : 1
        var lastFailure: GitHubStarListAIApplyFailure?
        for attempt in 1...maximumAttempts {
            do {
                let added = try await listService.addRepo(repo, toLists: requested)
                // `addRepo` 返回空集合既可能是“远端无需新增”，也可能是应用前本地仓储
                // 已由同步刷新到目标 membership。两种情况都应把本轮请求视为已确认，
                // 否则会出现 UI 显示已应用、会话内 current groups 却仍缺失的假状态。
                let confirmed = added.isEmpty ? requested : added
                existingListIDsByRepo[repo.id] = current.union(confirmed)
                selectedListIDsByRepo[repo.id] = []
                if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
                    jobs[latestIndex].applyState = .applied(confirmed)
                }
                onMembershipsChanged?()
                return
            } catch {
                let failure = GitHubStarListAIApplyFailure.classify(error)
                if failure.shouldAutomaticallyIgnore {
                    // 组织限制作用于整个仓库，不区分目标 List。清空该仓库的全部选择并记录终态，
                    // 让批处理继续，同时保留原因供“全部”筛选审计。
                    selectedListIDsByRepo[repo.id] = []
                    if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
                        jobs[latestIndex].applyState = .ignored(failure)
                    }
                    return
                }
                lastFailure = failure
                guard failure.isRetryable, attempt < maximumAttempts, !Task.isCancelled else { break }
                // 仅网络/5xx/限流做短退避；认证和永久 4xx 立即交给用户处理。
                try? await Task.sleep(for: .milliseconds(Int64(attempt * 600)))
            }
        }

        if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
            jobs[latestIndex].applyState = .failed(
                lastFailure ?? GitHubStarListAIApplyFailure(kind: .permanent, detail: nil)
            )
        }
    }

    /// 用户重新勾选、清空或忽略后，旧的应用结果已经不再描述当前审核计划。
    /// 清回 idle 可避免“绿色已应用/红色失败”覆盖新的待应用选择。
    private func resetApplyStateForNewReview(repoID: Int64) {
        guard let index = jobs.firstIndex(where: { $0.id == repoID }),
              jobs[index].applyState != .applying
        else { return }
        jobs[index].applyState = .idle
    }

    private func resetToIdle() {
        jobs = []
        selectedListIDsByRepo = [:]
        ignoredRepoIDs = []
        preparedRepos = []
        preparedRepositoryCount = 0
        ungroupedRepositoryCount = 0
        membershipCountByListID = [:]
        hasPreparedManualContext = false
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        isRunning = false
        isStartingManual = false
        mode = .idle
    }
}

private enum AnalysisOutcome: Sendable {
    case success(repos: [Repo], results: [Int64: [GitHubStarListAISuggestion]])
    case failure(repos: [Repo], error: BatchAIFailure)
}
