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
    private(set) var isRunning = false
    private(set) var isApplying = false
    private(set) var contextErrorMessage: String?

    /// 审核页只观察轻量 revision，再按帧合并生成展示快照。
    /// 不能让 SwiftUI 的 body 直接读取并转换近 2,000 个 jobs，否则每个批次状态变化都会重复排序和筛选。
    private(set) var presentationRevision: UInt64 = 0

    /// 应用成功后由 Sidebar 注入，合并刷新 Lists 计数与当前仓库列表。
    var onMembershipsChanged: (() -> Void)?

    private var preparedRepos: [Repo] = []
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
    var preparedRepositoryCount: Int { preparedRepos.count }
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
    var hasManualContext: Bool { mode == .manual && !availableLists.isEmpty }

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

    /// Sheet 打开时只准备快照。已存在的人工会话直接复用，避免关闭再开重置选择与结果。
    func prepareManualContext() async {
        if mode == .manual, !availableLists.isEmpty { return }
        if mode == .automatic {
            stopAnalysis()
        }
        isLoadingContext = true
        contextErrorMessage = nil
        defer { isLoadingContext = false }
        do {
            async let reposResult = repoRepository.fetchAllStarred()
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let assignmentsResult = listService.allListAssignments()
            preparedRepos = try await reposResult
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            existingListIDsByRepo = try await assignmentsResult.mapValues { Set($0.map(\.id)) }
            mode = .manual
            if jobs.isEmpty {
                selectedListIDsByRepo = [:]
                ignoredRepoIDs = []
            }
        } catch {
            contextErrorMessage = error.localizedDescription
        }
    }

    func startManual() async {
        do {
            try entitlementGate.requirePro(.batchAI)
        } catch {
            contextErrorMessage = error.localizedDescription
            return
        }
        if mode != .manual || availableLists.isEmpty {
            await prepareManualContext()
        }
        guard contextErrorMessage == nil, !candidateContexts.isEmpty else { return }
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
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        mode = .idle
        contextErrorMessage = nil
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
              let repo = jobs.first(where: { $0.id == repoID })?.repo
        else { return }
        isApplying = true
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMembershipsBeforeApply()
            await self.applyOne(repo: repo, allowAutomaticRetry: true)
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
                lastFailure = failure
                guard failure.isRetryable, attempt < maximumAttempts, !Task.isCancelled else { break }
                // 仅网络/5xx/限流做短退避；组织限制、认证和永久 4xx 立即交给用户处理。
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
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        isRunning = false
        mode = .idle
    }
}

private enum AnalysisOutcome: Sendable {
    case success(repos: [Repo], results: [Int64: [GitHubStarListAISuggestion]])
    case failure(repos: [Repo], error: BatchAIFailure)
}
