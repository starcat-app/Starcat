//
//  GitHubStarListAIGroupingSession.swift
//  Starcat
//
//  GitHub Lists AI 分组的独立会话状态机。
//
//  模块职责：
//  - 承载关闭 Sheet 后仍继续存在的分析进度、审核选择和应用结果；
//  - 以五个长期 Worker 单仓调用 AI，完成一个仓库就立即发布结果并领取下一项；
//  - 把 GitHub mutation 的可重试错误、组织 OAuth 限制和永久错误分开呈现。
//
//  关键约束：
//  - AI 只能返回用户已创建且填写了规则的 List；应用前仍会重新减去最新 membership；
//  - 关闭窗口不改变任务；暂停只阻止领取新仓库，停止才取消 Task；generation 防止迟到结果覆盖新会话；
//  - GitHub 是远端真源。远端失败时绝不伪造本地成功，单仓失败也不阻断其余仓库。
//

import CryptoKit
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

/// 后台调度器需要区分“没有启动条件”和“当前规则已经处理完”，否则无法安全保存
/// 低置信度仓库的有限队列进度。
enum GitHubStarListAIAutomaticStartResult: Equatable, Sendable {
    case unavailable
    case upToDate(configurationFingerprint: String)
    case started(configurationFingerprint: String, repositoryCount: Int)
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
    /// 持久化自动忽略项只参与本轮审计展示，不计入 AI 分析进度，也不会被 Worker 领取。
    var isExcludedFromAnalysis = false

    var isApplied: Bool {
        if case .applied = applyState { true } else { false }
    }

    var automaticallyIgnoredFailure: GitHubStarListAIApplyFailure? {
        if case .ignored(let failure) = applyState { failure } else { nil }
    }
}

/// 仓库分组开始页使用的轻量内存快照。
///
/// HomeViewModel 已经为 Sidebar 缓存了相同数据；打开 Sheet 时直接传递这份值，
/// 避免为了四个统计数字和分组规则再次查询 SQLite。完整仓库仍只在开始整理后加载。
struct GitHubStarListAIGroupingPreflightContext: Equatable, Sendable {
    let repositoryCount: Int
    let ungroupedRepositoryCount: Int
    /// 本次真正会进入 AI 队列的数量。多选入口可包含已有分组仓库，因此不能由“未分组”反推。
    let analysisRepositoryCount: Int
    /// 这些仓库仍展示在本轮结果中，但只有用户手动重试后才会重新进入 AI 队列。
    let automaticallyIgnoredRepoIDs: Set<Int64>
    let availableLists: [GitHubStarList]
    let membershipCountByListID: [String: Int]
    let rulesByListID: [String: GitHubStarListAIRule]

    init(
        repositoryCount: Int,
        ungroupedRepositoryCount: Int,
        analysisRepositoryCount: Int? = nil,
        automaticallyIgnoredRepoIDs: Set<Int64> = [],
        availableLists: [GitHubStarList],
        membershipCountByListID: [String: Int],
        rulesByListID: [String: GitHubStarListAIRule]
    ) {
        self.repositoryCount = repositoryCount
        self.ungroupedRepositoryCount = ungroupedRepositoryCount
        self.automaticallyIgnoredRepoIDs = automaticallyIgnoredRepoIDs
        self.analysisRepositoryCount = analysisRepositoryCount
            ?? max(0, ungroupedRepositoryCount - automaticallyIgnoredRepoIDs.count)
        self.availableLists = availableLists
        self.membershipCountByListID = membershipCountByListID
        self.rulesByListID = rulesByListID
    }
}

/// GitHub Lists 建议生成的最小能力边界。
///
/// 会话只依赖这一项能力，测试可注入可控 Provider 验证 Worker 并发与渐进回写，
/// 不需要触发真实 AI Provider 或修改用户的全局 AI 设置。
@MainActor
protocol GitHubStarListSuggestionProviding: AnyObject {
    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]]
}

extension RepoAIInsightService: GitHubStarListSuggestionProviding {}

@MainActor
@Observable
final class GitHubStarListAIGroupingSession {
    private let repoRepository: any RepoRepositoryProtocol
    private let listService: GitHubStarListSyncService
    private let insightService: any GitHubStarListSuggestionProviding
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
    /// “已应用”行展开后的最终 membership 草稿；与待确认建议的新增集合分开保存。
    private(set) var editedListIDsByRepo: [Int64: Set<String>] = [:] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var ignoredRepoIDs: Set<Int64> = [] {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var isLoadingContext = false
    /// 点「开始整理」后才拉完整仓库；这段时间开始页必须继续显示，不能退回全屏 spinner。
    private(set) var isStartingManual = false
    private(set) var isRunning = false
    /// 合作式暂停：已领取的 AI 请求继续收口，Worker 在下一次领取仓库前等待。
    private(set) var isPaused = false
    private(set) var isApplying = false
    private(set) var contextErrorMessage: String?
    /// 开始页仓库总数。用 COUNT 查询，不订阅完整 `[Repo]`。
    private(set) var preparedRepositoryCount = 0 {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var ungroupedRepositoryCount = 0 {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var preparedAnalysisRepositoryCount = 0 {
        didSet { presentationRevision &+= 1 }
    }
    private(set) var preparedAutomaticallyIgnoredRepoIDs: Set<Int64> = [] {
        didSet { presentationRevision &+= 1 }
    }

    /// 审核页只观察轻量 revision，再按帧合并生成展示快照。
    /// 不能让 SwiftUI 的 body 直接读取并转换近 2,000 个 jobs，否则每个批次状态变化都会重复排序和筛选。
    private(set) var presentationRevision: UInt64 = 0

    /// 应用成功后由 Sidebar 注入，合并刷新 Lists 计数与当前仓库列表。
    var onMembershipsChanged: (() -> Void)?
    /// 自动忽略标记变化只需刷新 Sidebar 预检快照，不必重载当前仓库列表。
    var onAutoIgnoredReposChanged: (() -> Void)?
    /// 后台分析已完成但没有达到自动应用阈值时，通知调度器保存“本规则已尝试”。
    /// 应用失败不走这里，保留给下一次触发重试。
    var onAutomaticSuggestionsDeferred: (
        (_ configurationFingerprint: String, _ repoIDs: Set<Int64>) -> Void
    )?

    /// 完整仓库只在点「开始整理」后加载。开始页若观察这个数组，1965 条赋值会拖住主线程 SwiftUI。
    @ObservationIgnored private var preparedRepos: [Repo] = []
    /// 0 个分组时 `availableLists` 为空，不能用它判断「已经准备过」。
    @ObservationIgnored private var hasPreparedManualContext = false
    @ObservationIgnored private(set) var membershipCountByListID: [String: Int] = [:]
    private var runTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var rateLimitCooldownUntil: Date?
    /// 人工整理启动时冻结自动确认阈值；暂停、继续和单仓重试必须保持同一语义。
    @ObservationIgnored private var manualAutomaticThreshold: Double?
    /// 当前后台任务对应的规则与阈值快照。只在 automatic mode 生命周期内有效。
    @ObservationIgnored private var automaticConfigurationFingerprint: String?
    /// 五个 Worker 的低置信度/无匹配结果先在内存合并，整轮结束只写一次 UserDefaults。
    @ObservationIgnored private var automaticDeferredRepoIDs: Set<Int64> = []

    /// 固定五个长期 Worker；不要为每个仓库创建一个 Task，否则大列表会产生无界任务。
    private static let defaultConcurrency = 5
    /// 命中 Provider 429 后只让 Worker 0 继续领取任务，避免五路请求持续放大限流。
    private static let rateLimitCooldown: TimeInterval = 30
    private static let organizationOAuthRestrictionFailure = GitHubStarListAIApplyFailure(
        kind: .organizationOAuthRestriction,
        detail: nil
    )

    init(
        repoRepository: any RepoRepositoryProtocol,
        listService: GitHubStarListSyncService,
        insightService: any GitHubStarListSuggestionProviding,
        entitlementGate: EntitlementGate
    ) {
        self.repoRepository = repoRepository
        self.listService = listService
        self.insightService = insightService
        self.entitlementGate = entitlementGate
    }

    var totalCount: Int { jobs.count }
    var analysisTotalCount: Int { jobs.count { !$0.isExcludedFromAnalysis } }
    /// 分析 payload 是否已从数据库展开。开始页为 false；点「开始整理」后为 true。
    var hasLoadedStarredRepositories: Bool { !preparedRepos.isEmpty }
    var preparedRepositoryIDs: [Int64] { preparedRepos.map(\.id) }
    var analyzedCount: Int {
        jobs.count { !$0.isExcludedFromAnalysis && ($0.status == .completed || $0.status == .failed) }
    }
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
    var isFinished: Bool { !jobs.isEmpty && analyzedCount == analysisTotalCount }

    /// 关闭窗口后仍值得保留的人工任务：尚未分析完、失败可重试，或建议仍等待用户处理。
    /// 已应用、已忽略、无匹配以及建议已属于现有分组的仓库都已经收口，不应阻塞下一轮整理。
    var hasUnresolvedManualWork: Bool {
        guard mode == .manual, !jobs.isEmpty else { return false }
        return jobs.contains { job in
            if ignoredRepoIDs.contains(job.id) { return false }
            switch job.status {
            case .queued, .analyzing, .failed, .stopped:
                return true
            case .completed:
                break
            }
            switch job.applyState {
            case .applying, .failed:
                return true
            case .applied, .ignored:
                return false
            case .idle:
                let currentListIDs = existingListIDsByRepo[job.id] ?? []
                let manuallySelectedListIDs = (selectedListIDsByRepo[job.id] ?? [])
                    .subtracting(currentListIDs)
                if !manuallySelectedListIDs.isEmpty { return true }
                return job.suggestions.contains { !currentListIDs.contains($0.listId) }
            }
        }
    }

    /// 只有非运行态且仍有内容会被丢失时，“放弃本次整理”才有实际语义。
    var canDiscardManualSession: Bool {
        !isRunning && !isApplying && hasUnresolvedManualWork
    }

    var isManualSessionResolved: Bool {
        mode == .manual
            && !jobs.isEmpty
            && !isRunning
            && !isApplying
            && !hasUnresolvedManualWork
    }

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
            async let autoIgnoredResult = listService.allAIAutoIgnoredRepos()
            membershipCountByListID = try await membershipCountsResult
            preparedRepositoryCount = try await starredCountResult
            ungroupedRepositoryCount = try await ungroupedResult
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            preparedAutomaticallyIgnoredRepoIDs = Set(try await autoIgnoredResult.map(\.repoId))
            preparedAnalysisRepositoryCount = max(
                0,
                ungroupedRepositoryCount - preparedAutomaticallyIgnoredRepoIDs.count
            )
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
        preparedAnalysisRepositoryCount = context.analysisRepositoryCount
        preparedAutomaticallyIgnoredRepoIDs = context.automaticallyIgnoredRepoIDs
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

    /// 多选入口冻结用户点击时的仓库与 membership；后续「开始整理」不得再展开为全库范围。
    func prepareManualContext(
        from context: GitHubStarListAIGroupingPreflightContext,
        repositories: [Repo],
        existingMemberships: [Int64: Set<String>]
    ) {
        guard !repositories.isEmpty else { return }
        if mode == .manual, !jobs.isEmpty { return }
        prepareManualContext(from: context)
        guard jobs.isEmpty else { return }
        preparedRepos = repositories
        existingListIDsByRepo = Dictionary(uniqueKeysWithValues: repositories.map { repo in
            (repo.id, existingMemberships[repo.id] ?? [])
        })
    }

    /// 开始页改规则或新建分组后只重载 Lists / 规则 / 计数，不拉完整仓库。
    func reloadListsAndRules() async {
        do {
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let membershipCountsResult = listService.repoCountsByList()
            async let ungroupedResult = listService.ungroupedRepoCount()
            async let starredCountResult = repoRepository.starredCount()
            async let autoIgnoredResult = listService.allAIAutoIgnoredRepos()
            membershipCountByListID = try await membershipCountsResult
            preparedRepositoryCount = try await starredCountResult
            ungroupedRepositoryCount = try await ungroupedResult
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            let autoIgnoredRepoIDs = Set(try await autoIgnoredResult.map(\.repoId))
            if preparedRepos.isEmpty {
                preparedAutomaticallyIgnoredRepoIDs = autoIgnoredRepoIDs
                preparedAnalysisRepositoryCount = max(0, ungroupedRepositoryCount - autoIgnoredRepoIDs.count)
            } else {
                preparedAutomaticallyIgnoredRepoIDs = autoIgnoredRepoIDs.intersection(preparedRepos.map(\.id))
                preparedAnalysisRepositoryCount = max(
                    0,
                    preparedRepos.count - preparedAutomaticallyIgnoredRepoIDs.count
                )
            }
        } catch {
            AppLog.ai.error("[githubListGrouping] reload lists/rules failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 点「开始整理」才展开未分组仓库和 membership。开始页打开路径不得调用。
    /// 多选入口已经冻结 `preparedRepos`，因此仍会保留用户明确选中的已有分组仓库。
    func ensureStarredRepositoriesLoaded() async {
        guard preparedRepos.isEmpty else { return }
        do {
            async let reposResult = repoRepository.fetchListPage(
                scope: .githubStarListUngrouped,
                filters: .empty,
                sort: .starredAtDesc,
                limit: Int.max,
                offset: 0
            )
            async let assignmentsResult = listService.allListAssignments()
            async let autoIgnoredResult = listService.allAIAutoIgnoredRepos()
            preparedRepos = try await reposResult
            existingListIDsByRepo = try await assignmentsResult.mapValues { Set($0.map(\.id)) }
            preparedAutomaticallyIgnoredRepoIDs = Set(try await autoIgnoredResult.map(\.repoId))
                .intersection(preparedRepos.map(\.id))
            preparedAnalysisRepositoryCount = max(
                0,
                preparedRepos.count - preparedAutomaticallyIgnoredRepoIDs.count
            )
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

    func startManual(
        autoConfirmEnabled: Bool = false,
        confidenceThreshold: Double = GitHubStarListAutoGroupingSettings.default.confidenceThreshold
    ) async {
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
        manualAutomaticThreshold = autoConfirmEnabled
            ? GitHubStarListAutoGroupingSettings.clamp(confidenceThreshold)
            : nil
        beginAnalysis(
            repos: preparedRepos,
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            automaticThreshold: manualAutomaticThreshold,
            automaticallyIgnoredRepoIDs: preparedAutomaticallyIgnoredRepoIDs
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
            automaticThreshold: manualAutomaticThreshold,
            replaceJobs: false
        )
    }

    /// 暂停只阻止 Worker 领取下一仓，不取消正在进行的 Provider 调用。
    /// 这样已经返回的结果仍能即时进入审核列表，不会制造半完成状态。
    func pauseAnalysis() {
        guard mode == .manual, isRunning, !isPaused else { return }
        isPaused = true
    }

    func resumeAnalysis() {
        guard mode == .manual, isRunning, isPaused else { return }
        isPaused = false
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
            automaticThreshold: manualAutomaticThreshold,
            replaceJobs: false
        )
    }

    /// 分析失败与应用失败是两条独立恢复路径；批量重试只重新排队分析失败仓库。
    func retryAllAnalysisFailures() {
        guard mode == .manual, !isRunning, !isApplying else { return }
        let repos = jobs.compactMap { $0.status == .failed ? $0.repo : nil }
        guard !repos.isEmpty else { return }
        beginAnalysis(
            repos: repos,
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            automaticThreshold: manualAutomaticThreshold,
            replaceJobs: false
        )
    }

    /// 后台自动分组使用独立会话，但不保留审核选择。人工任务优先，运行中时后台直接让位。
    func startAutomatic(
        repos: [Repo],
        confidenceThreshold: Double,
        maxPerRun: Int,
        sortOrder: AutoTidySortOrder,
        attemptedRepositoryIDs: Set<Int64>,
        previousConfigurationFingerprint: String?
    ) async -> GitHubStarListAIAutomaticStartResult {
        guard mode != .manual, !isRunning, !isApplying, !repos.isEmpty else { return .unavailable }
        do {
            async let listsResult = listService.allLists()
            async let rulesResult = listService.allAIRules()
            async let assignmentsResult = listService.allListAssignments()
            async let autoIgnoredResult = listService.allAIAutoIgnoredRepos()
            availableLists = try await listsResult
            let rules = try await rulesResult
            rulesByListID = Dictionary(uniqueKeysWithValues: rules.map { ($0.listId, $0) })
            existingListIDsByRepo = try await assignmentsResult.mapValues { Set($0.map(\.id)) }
            preparedAutomaticallyIgnoredRepoIDs = Set(try await autoIgnoredResult.map(\.repoId))
        } catch {
            AppLog.ai.error("[githubListGrouping] automatic context failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        let automaticCandidates = candidateContexts.filter(\.autoApplyEnabled)
        guard !automaticCandidates.isEmpty else { return .unavailable }
        let threshold = GitHubStarListAutoGroupingSettings.clamp(confidenceThreshold)
        let configurationFingerprint = Self.automaticConfigurationFingerprint(
            candidates: automaticCandidates,
            confidenceThreshold: threshold
        )
        // 规则或阈值变化后，旧的低置信度/无匹配记录失效；所有未分组仓库重新获得判断机会。
        let activeAttemptedRepositoryIDs = previousConfigurationFingerprint == configurationFingerprint
            ? attemptedRepositoryIDs
            : []
        let pickedRepos = Self.automaticRepositories(
            from: repos,
            existingListIDsByRepo: existingListIDsByRepo,
            automaticallyIgnoredRepoIDs: preparedAutomaticallyIgnoredRepoIDs,
            attemptedRepositoryIDs: activeAttemptedRepositoryIDs,
            sortOrder: sortOrder,
            limit: maxPerRun
        )
        guard !pickedRepos.isEmpty else {
            return .upToDate(configurationFingerprint: configurationFingerprint)
        }
        automaticConfigurationFingerprint = configurationFingerprint
        automaticDeferredRepoIDs = []
        beginAnalysis(
            repos: pickedRepos,
            candidates: automaticCandidates,
            existingMemberships: existingListIDsByRepo,
            mode: .automatic,
            automaticThreshold: threshold
        )
        return .started(
            configurationFingerprint: configurationFingerprint,
            repositoryCount: pickedRepos.count
        )
    }

    /// 只把会改变 AI 判断或自动应用结果的字段纳入指纹。触发时机、批量大小和排序变化
    /// 不会让已经明确低于阈值的仓库重复消耗 AI 配额。
    nonisolated static func automaticConfigurationFingerprint(
        candidates: [GitHubStarListAIContext],
        confidenceThreshold: Double
    ) -> String {
        let groups = candidates
            .sorted { $0.listId < $1.listId }
            .map { candidate in
                [candidate.listId, candidate.name, candidate.instruction]
                    .joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
        let payload = "\(GitHubStarListAutoGroupingSettings.clamp(confidenceThreshold))\u{1D}\(groups)"
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 后台队列的唯一候选口径：未分组来源仍做 membership 防御检查，并在批量截取前
    /// 排除 v34 永久忽略项和当前规则已尝试项，避免二者占掉 `maxPerRun` 名额。
    nonisolated static func automaticRepositories(
        from repos: [Repo],
        existingListIDsByRepo: [Int64: Set<String>],
        automaticallyIgnoredRepoIDs: Set<Int64>,
        attemptedRepositoryIDs: Set<Int64>,
        sortOrder: AutoTidySortOrder,
        limit: Int
    ) -> [Repo] {
        let eligibleRepos = repos.filter { repo in
            (existingListIDsByRepo[repo.id] ?? []).isEmpty
                && !automaticallyIgnoredRepoIDs.contains(repo.id)
                && !attemptedRepositoryIDs.contains(repo.id)
        }
        return sortOrder.pick(
            from: eligibleRepos,
            limit: GitHubStarListAutoGroupingSettings.clampMaxPerRun(limit)
        )
    }

    func stopAnalysis() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        isPaused = false
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
        isPaused = false
        jobs = []
        selectedListIDsByRepo = [:]
        editedListIDsByRepo = [:]
        ignoredRepoIDs = []
        preparedRepos = []
        preparedRepositoryCount = 0
        ungroupedRepositoryCount = 0
        preparedAnalysisRepositoryCount = 0
        preparedAutomaticallyIgnoredRepoIDs = []
        membershipCountByListID = [:]
        hasPreparedManualContext = false
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        mode = .idle
        contextErrorMessage = nil
        isStartingManual = false
        rateLimitCooldownUntil = nil
        manualAutomaticThreshold = nil
    }

    /// 结果在窗口仍打开时保留供用户复查；关闭窗口或再次打开入口时才结束已完全收口的会话。
    @discardableResult
    func finishManualSessionIfResolved() -> Bool {
        guard isManualSessionResolved else { return false }
        resetToIdle()
        return true
    }

    /// 所有窗口关闭路径共用同一个出口：空开始页释放上下文，未解决任务继续保留。
    func releaseManualSessionOnWindowDismiss() {
        if finishManualSessionIfResolved() { return }
        releaseManualContextIfUnused()
    }

    /// 只准备了上下文但没有启动分析时，Sheet 关闭应释放人工模式，让后台自动分组继续工作。
    /// 已有任务或结果时必须保留会话，用户下次打开才能从原进度继续审核。
    func releaseManualContextIfUnused() {
        guard mode == .manual, jobs.isEmpty, !isRunning, !isApplying else { return }
        resetToIdle()
    }

    func toggleSelection(repoID: Int64, listID: String) {
        if jobs.first(where: { $0.id == repoID })?.isApplied == true
            || editedListIDsByRepo[repoID] != nil {
            toggleAppliedMembership(repoID: repoID, listID: listID)
            return
        }
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
        if jobs.first(where: { $0.id == repoID })?.isApplied == true
            || editedListIDsByRepo[repoID] != nil {
            clearAppliedMemberships(repoID: repoID)
            return
        }
        selectedListIDsByRepo[repoID] = []
        resetApplyStateForNewReview(repoID: repoID)
    }

    func ignore(repoID: Int64) {
        selectedListIDsByRepo[repoID] = []
        ignoredRepoIDs.insert(repoID)
        resetApplyStateForNewReview(repoID: repoID)
    }

    /// 已应用行编辑的是最终 membership，因此已有分组也允许取消勾选。
    func toggleAppliedMembership(repoID: Int64, listID: String) {
        guard mode == .manual,
              availableLists.contains(where: { $0.id == listID }),
              let job = jobs.first(where: { $0.id == repoID }),
              job.isApplied || editedListIDsByRepo[repoID] != nil,
              job.applyState != .applying
        else { return }
        var edited = editedListIDsByRepo[repoID] ?? existingListIDsByRepo[repoID] ?? []
        if edited.contains(listID) {
            edited.remove(listID)
        } else {
            edited.insert(listID)
        }
        editedListIDsByRepo[repoID] = edited
    }

    func clearAppliedMemberships(repoID: Int64) {
        guard jobs.first(where: { $0.id == repoID })?.isApplied == true
            || editedListIDsByRepo[repoID] != nil
        else { return }
        editedListIDsByRepo[repoID] = []
    }

    func discardAppliedMembershipChanges(repoID: Int64) {
        editedListIDsByRepo.removeValue(forKey: repoID)
    }

    func applyMembershipChanges(repoID: Int64) {
        guard mode == .manual,
              !isApplying,
              let job = jobs.first(where: { $0.id == repoID }),
              let desiredListIDs = editedListIDsByRepo[repoID],
              desiredListIDs != (existingListIDsByRepo[repoID] ?? [])
        else { return }
        isApplying = true
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.applyExactMemberships(
                repo: job.repo,
                desiredListIDs: desiredListIDs,
                allowAutomaticRetry: true
            )
            self.isApplying = false
            self.applyTask = nil
        }
    }

    func applyReview(repoID: Int64) {
        if editedListIDsByRepo[repoID] != nil {
            applyMembershipChanges(repoID: repoID)
        } else {
            applySelected(repoIDs: [repoID])
        }
    }

    /// 持久化自动忽略只有显式重试才解除；解除后重新分析，而不是直接重放旧 mutation。
    func retryAutomaticallyIgnored(repoID: Int64) async {
        await retryAutomaticallyIgnored(repoIDs: [repoID])
    }

    func retryAllAutomaticallyIgnored() async {
        let repoIDs = Set(jobs.compactMap { job -> Int64? in
            job.automaticallyIgnoredFailure == nil ? nil : job.id
        })
        await retryAutomaticallyIgnored(repoIDs: repoIDs)
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
            if let desiredListIDs = self.editedListIDsByRepo[repoID] {
                await self.applyExactMemberships(
                    repo: job.repo,
                    desiredListIDs: desiredListIDs,
                    allowAutomaticRetry: true
                )
            } else {
                await self.refreshMembershipsBeforeApply()
                await self.applyOne(repo: job.repo, allowAutomaticRetry: true)
            }
            self.isApplying = false
            self.applyTask = nil
        }
    }

    func retryAllRecoverableApplyFailures() {
        guard mode == .manual, !isApplying else { return }
        let retryJobs = jobs.filter { job in
            guard case .failed(let failure) = job.applyState else { return false }
            return failure.isRetryable
        }
        guard !retryJobs.isEmpty else { return }

        isApplying = true
        applyTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshMembershipsBeforeApply()
            for job in retryJobs {
                guard !Task.isCancelled else { break }
                if let desiredListIDs = self.editedListIDsByRepo[job.id] {
                    await self.applyExactMemberships(
                        repo: job.repo,
                        desiredListIDs: desiredListIDs,
                        allowAutomaticRetry: true
                    )
                } else {
                    await self.applyOne(repo: job.repo, allowAutomaticRetry: true)
                }
            }
            self.isApplying = false
            self.applyTask = nil
        }
    }

    private func retryAutomaticallyIgnored(repoIDs: Set<Int64>) async {
        guard mode == .manual, !isRunning, !isApplying, !repoIDs.isEmpty else { return }
        let retryRepos = jobs.compactMap { job -> Repo? in
            guard repoIDs.contains(job.id), job.automaticallyIgnoredFailure != nil else { return nil }
            return job.repo
        }
        guard !retryRepos.isEmpty else { return }
        do {
            for repo in retryRepos {
                try await listService.clearAIAutoIgnored(repoID: repo.id)
            }
        } catch {
            contextErrorMessage = error.localizedDescription
            return
        }
        onAutoIgnoredReposChanged?()
        preparedAutomaticallyIgnoredRepoIDs.subtract(retryRepos.map(\.id))
        preparedAnalysisRepositoryCount += retryRepos.count
        for repo in retryRepos {
            guard let index = jobs.firstIndex(where: { $0.id == repo.id }) else { continue }
            jobs[index].isExcludedFromAnalysis = false
            jobs[index].applyState = .idle
            jobs[index].suggestions = []
            jobs[index].finishedAt = nil
        }
        beginAnalysis(
            repos: retryRepos,
            candidates: candidateContexts,
            existingMemberships: existingListIDsByRepo,
            mode: .manual,
            automaticThreshold: manualAutomaticThreshold,
            replaceJobs: false
        )
    }

    private func beginAnalysis(
        repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        mode: GitHubStarListAIGroupingSessionMode,
        automaticThreshold: Double?,
        replaceJobs: Bool = true,
        automaticallyIgnoredRepoIDs: Set<Int64> = []
    ) {
        generation &+= 1
        let currentGeneration = generation
        runTask?.cancel()
        self.mode = mode
        isRunning = true
        isPaused = false
        contextErrorMessage = nil
        if replaceJobs {
            rateLimitCooldownUntil = nil
            jobs = repos.map { repo in
                guard automaticallyIgnoredRepoIDs.contains(repo.id) else {
                    return GitHubStarListAIGroupingJob(repo: repo)
                }
                return GitHubStarListAIGroupingJob(
                    repo: repo,
                    status: .completed,
                    applyState: .ignored(Self.organizationOAuthRestrictionFailure),
                    finishedAt: .now,
                    isExcludedFromAnalysis: true
                )
            }
            selectedListIDsByRepo = [:]
            editedListIDsByRepo = [:]
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
                automaticThreshold: automaticThreshold,
                generation: currentGeneration
            )
        }
    }

    private func runAnalysis(
        repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        automaticThreshold: Double?,
        generation: UInt64
    ) async {
        let reposByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })

        // 只创建五个长期 Worker。领取动作在 MainActor 上原子完成，因此同一仓库不会被重复消费；
        // 网络 await 期间 MainActor 会让出执行权，五个请求仍能并行在途。
        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<Self.defaultConcurrency {
                group.addTask { [weak self] in
                    await self?.runWorker(
                        index: workerIndex,
                        reposByID: reposByID,
                        candidates: candidates,
                        existingMemberships: existingMemberships,
                        automaticThreshold: automaticThreshold,
                        generation: generation
                    )
                }
            }
            await group.waitForAll()
        }

        guard generation == self.generation, !Task.isCancelled else { return }
        isRunning = false
        runTask = nil
        if mode == .automatic {
            if let automaticConfigurationFingerprint, !automaticDeferredRepoIDs.isEmpty {
                onAutomaticSuggestionsDeferred?(
                    automaticConfigurationFingerprint,
                    automaticDeferredRepoIDs
                )
            }
            resetToIdle()
        }
    }

    /// Worker 每次只领取一个仓库；该仓库完成后立即回写，再领取下一项。
    /// 这保证慢请求只阻塞自己的 Worker，不会让同一批次的其它仓库等待统一收口。
    private func runWorker(
        index workerIndex: Int,
        reposByID: [Int64: Repo],
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        automaticThreshold: Double?,
        generation: UInt64
    ) async {
        while !Task.isCancelled, generation == self.generation {
            guard jobs.contains(where: {
                $0.status == .queued && reposByID[$0.id] != nil
            }) else { return }
            if isPaused {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            if workerIndex >= activeConcurrency {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }

            guard let repo = claimNextRepo(from: reposByID) else { return }
            await processClaimedRepo(
                repo,
                candidates: candidates,
                existingMemberships: existingMemberships,
                automaticThreshold: automaticThreshold,
                generation: generation
            )
            // 每完成一个仓库就让出 MainActor，让观察层有机会立即刷新该行状态。
            await Task.yield()
        }
    }

    /// MainActor 串行执行领取与状态切换，相当于队列的原子 pop。
    private func claimNextRepo(from reposByID: [Int64: Repo]) -> Repo? {
        guard let index = jobs.firstIndex(where: {
            $0.status == .queued && reposByID[$0.id] != nil
        }) else { return nil }
        jobs[index].status = .analyzing
        return reposByID[jobs[index].id]
    }

    private func processClaimedRepo(
        _ repo: Repo,
        candidates: [GitHubStarListAIContext],
        existingMemberships: [Int64: Set<String>],
        automaticThreshold: Double?,
        generation: UInt64
    ) async {
        do {
            let listNamesByID = Dictionary(uniqueKeysWithValues: availableLists.map { ($0.id, $0.name) })
            let existingListNames = (existingMemberships[repo.id] ?? [])
                .compactMap { listNamesByID[$0] }
                .sorted()
            let results = try await insightService.generateGitHubListSuggestions(
                for: [repo],
                candidates: candidates,
                existingListIDsByRepo: existingMemberships,
                // 名称只随仓库 payload 交给模型作为分类参考，不改变候选集与审核流程。
                existingListNamesByRepo: [repo.id: existingListNames]
            )
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            await integrate(
                .success(repos: [repo], results: results),
                automaticThreshold: automaticThreshold
            )
        } catch {
            guard generation == self.generation,
                  !Task.isCancelled,
                  !(error is CancellationError)
            else { return }
            if isRateLimited(error) {
                rateLimitCooldownUntil = .now.addingTimeInterval(Self.rateLimitCooldown)
            }
            await integrate(
                .failure(repos: [repo], error: BatchAIFailure(error: error)),
                automaticThreshold: automaticThreshold
            )
        }
    }

    private var activeConcurrency: Int {
        guard let cooldownUntil = rateLimitCooldownUntil, cooldownUntil > .now else {
            return Self.defaultConcurrency
        }
        return 1
    }

    private func isRateLimited(_ error: Error) -> Bool {
        guard let aiError = error as? AIClientError else { return false }
        if case .rateLimited = aiError { return true }
        return false
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
                    } else if mode == .automatic,
                              automaticConfigurationFingerprint != nil {
                        // 无匹配或低于阈值都已完成本规则下的判断；继续保持未分组，但不要
                        // 在下一次后台触发时无限重复。人工自动确认不写这份后台进度。
                        automaticDeferredRepoIDs.insert(repo.id)
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
                await clearPersistedAutoIgnore(repoID: repo.id)
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
                    await persistAutoIgnore(repoID: repo.id)
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

    /// 已应用结果编辑走完整集合替换，既能新增也能移除；失败分类与首次应用保持一致。
    private func applyExactMemberships(
        repo: Repo,
        desiredListIDs: Set<String>,
        allowAutomaticRetry: Bool
    ) async {
        guard let index = jobs.firstIndex(where: { $0.id == repo.id }) else { return }
        jobs[index].applyState = .applying
        let maximumAttempts = allowAutomaticRetry ? 3 : 1
        var lastFailure: GitHubStarListAIApplyFailure?

        for attempt in 1...maximumAttempts {
            do {
                try await listService.setLists(for: repo, listIDs: desiredListIDs)
                existingListIDsByRepo[repo.id] = desiredListIDs
                editedListIDsByRepo.removeValue(forKey: repo.id)
                await clearPersistedAutoIgnore(repoID: repo.id)
                if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
                    jobs[latestIndex].applyState = .applied(desiredListIDs)
                }
                onMembershipsChanged?()
                return
            } catch {
                let failure = GitHubStarListAIApplyFailure.classify(error)
                if failure.shouldAutomaticallyIgnore {
                    await persistAutoIgnore(repoID: repo.id)
                    if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
                        jobs[latestIndex].applyState = .ignored(failure)
                    }
                    return
                }
                lastFailure = failure
                guard failure.isRetryable, attempt < maximumAttempts, !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(Int64(attempt * 600)))
            }
        }

        if let latestIndex = jobs.firstIndex(where: { $0.id == repo.id }) {
            jobs[latestIndex].applyState = .failed(
                lastFailure ?? GitHubStarListAIApplyFailure(kind: .permanent, detail: nil)
            )
        }
    }

    private func persistAutoIgnore(repoID: Int64) async {
        do {
            try await listService.markAIAutoIgnored(
                repoID: repoID,
                reason: .organizationOAuthRestriction
            )
            preparedAutomaticallyIgnoredRepoIDs.insert(repoID)
            onAutoIgnoredReposChanged?()
        } catch {
            // 远端限制已经发生，本轮仍必须收敛成忽略；持久化失败只影响跨轮次去重。
            AppLog.database.error("[githubListGrouping] persist auto-ignore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearPersistedAutoIgnore(repoID: Int64) async {
        guard preparedAutomaticallyIgnoredRepoIDs.contains(repoID) else { return }
        do {
            try await listService.clearAIAutoIgnored(repoID: repoID)
            preparedAutomaticallyIgnoredRepoIDs.remove(repoID)
        } catch {
            AppLog.database.error("[githubListGrouping] clear auto-ignore failed: \(error.localizedDescription, privacy: .public)")
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
        editedListIDsByRepo = [:]
        ignoredRepoIDs = []
        preparedRepos = []
        preparedRepositoryCount = 0
        ungroupedRepositoryCount = 0
        preparedAnalysisRepositoryCount = 0
        preparedAutomaticallyIgnoredRepoIDs = []
        membershipCountByListID = [:]
        hasPreparedManualContext = false
        availableLists = []
        rulesByListID = [:]
        existingListIDsByRepo = [:]
        rateLimitCooldownUntil = nil
        manualAutomaticThreshold = nil
        automaticConfigurationFingerprint = nil
        automaticDeferredRepoIDs = []
        isRunning = false
        isStartingManual = false
        mode = .idle
    }
}

private enum AnalysisOutcome: Sendable {
    case success(repos: [Repo], results: [Int64: [GitHubStarListAISuggestion]])
    case failure(repos: [Repo], error: BatchAIFailure)
}
