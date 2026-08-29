//
//  GitHubStarListAIGroupingPresentation.swift
//  Starcat
//
//  AI 仓库分组审核页的纯展示模型。
//
//  关键约束：所有“待应用”状态都从当前 membership 动态派生；已存在或刚应用成功的
//  List 关系不能因为 Sheet 关闭重开而重新选中。分析失败和 GitHub 应用失败分别筛选。
//

import Foundation

struct GitHubStarListAISuggestionSelection: Hashable, Sendable {
    let repoID: Int64
    let listID: String
}

struct GitHubStarListAIListDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let instruction: String
    let colorHex: String
}

/// 整理开始前展示的已有分组摘要。
///
/// 只保留计数和少量样例名称，避免为了画概览卡片长期复制每个分组的完整仓库数组。
struct GitHubStarListAIPreflightGroupDisplay: Identifiable, Equatable, Sendable {
    var id: String { list.id }

    let list: GitHubStarListAIListDisplay
    let repositoryCount: Int
    let sampleRepositoryNames: [String]
    let hasAIRule: Bool
    let autoApplyEnabled: Bool
}

extension GitHubStarListAIGroupingPreflightContext {
    /// Sheet 的第一帧直接使用内存快照；这里最多转换 GitHub Lists 的少量分组行，
    /// 不读取完整仓库，也不触发数据库或网络请求。
    var presentationSnapshot: GitHubStarListAIGroupingPresentationSnapshot {
        let listDisplays = availableLists.map { list in
            GitHubStarListAIListDisplay(
                id: list.id,
                name: list.name,
                instruction: rulesByListID[list.id]?.instruction ?? "",
                colorHex: list.colorHex
            )
        }
        return GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [],
            availableLists: listDisplays,
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [:],
            editedListIDsByRepo: [:],
            ignoredRepoIDs: [],
            preparedRepositoryCount: repositoryCount,
            ungroupedRepositoryCount: ungroupedRepositoryCount,
            preparedAnalysisRepositoryCount: analysisRepositoryCount,
            preparedAutomaticallyIgnoredRepoCount: automaticallyIgnoredRepoIDs.count,
            membershipCountByListID: membershipCountByListID,
            rulesByListID: rulesByListID
        )
    }
}

struct GitHubStarListAISuggestionDisplay: Identifiable, Equatable, Sendable {
    var id: String { list.id }

    let list: GitHubStarListAIListDisplay
    let confidence: Double
    let reason: String
}

/// 审核列表摘要中的一个分组。
///
/// `confidence` 允许为空，因为人工审核可以勾选 AI 本轮没有建议的现有分组。
struct GitHubStarListAIGroupSummaryDisplay: Identifiable, Equatable, Sendable {
    var id: String { list.id }

    let list: GitHubStarListAIListDisplay
    let confidence: Double?
}

enum GitHubStarListAIResultFilter: String, CaseIterable, Identifiable, Sendable {
    case actionable
    case all
    case suggestions
    case noMatch
    case analysisFailed
    case applyFailed
    case applied
    /// 组织 OAuth 限制导致 GitHub 不允许改 Lists，系统跳过，不是用户点忽略。
    case automaticallyIgnored
    /// 用户在审核列表里主动点忽略。
    case ignored

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .actionable: "githubStarLists.aiGrouping.metric.remaining"
        case .all: "general.all"
        case .suggestions: "githubStarLists.aiGrouping.filter.suggestions"
        case .noMatch: "githubStarLists.aiGrouping.filter.noMatch"
        case .analysisFailed: "githubStarLists.aiGrouping.filter.analysisFailed"
        case .applyFailed: "githubStarLists.aiGrouping.filter.applyFailed"
        case .applied: "githubStarLists.aiGrouping.filter.applied"
        case .automaticallyIgnored: "githubStarLists.aiGrouping.filter.automaticallyIgnored"
        case .ignored: "githubStarLists.aiGrouping.filter.ignored"
        }
    }

    /// 分段控件宽度按英文最长标签估算。Tab 文案必须短于完整状态名。
    var tabTitleKey: String {
        switch self {
        case .actionable: "githubStarLists.aiGrouping.filter.tab.actionable"
        case .all: "general.all"
        case .suggestions: "githubStarLists.aiGrouping.filter.suggestions"
        case .noMatch: "githubStarLists.aiGrouping.filter.noMatch"
        case .analysisFailed: "githubStarLists.aiGrouping.filter.analysisFailed"
        case .applyFailed: "githubStarLists.aiGrouping.filter.tab.applyFailed"
        case .applied: "githubStarLists.aiGrouping.filter.tab.applied"
        case .automaticallyIgnored: "githubStarLists.aiGrouping.filter.tab.automaticallyIgnored"
        case .ignored: "githubStarLists.aiGrouping.filter.tab.ignored"
        }
    }
}

struct GitHubStarListAIReviewItem: Identifiable, Equatable, Sendable {
    let id: Int64
    let repo: Repo
    let status: GitHubStarListAIGroupingJobStatus
    let currentLists: [GitHubStarListAIListDisplay]
    let suggestions: [GitHubStarListAISuggestionDisplay]
    let selectedListIDs: Set<String>
    /// 已应用行展开时的最终 membership 草稿；未修改时等于当前分组集合。
    let membershipEditorListIDs: Set<String>
    let selectedGroupSummaries: [GitHubStarListAIGroupSummaryDisplay]
    let appliedGroupSummaries: [GitHubStarListAIGroupSummaryDisplay]
    let applyState: GitHubStarListAIApplyState
    let isIgnoredByUser: Bool
    let analysisFailureMessage: String?
    let finishedAt: Date?

    var repoFullName: String { repo.fullName }
    var repoDescription: String? {
        let value = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
    var hasSuggestions: Bool { !suggestions.isEmpty }
    var actionableSuggestions: [GitHubStarListAISuggestionDisplay] {
        let currentListIDs = Set(currentLists.map(\.id))
        return suggestions.filter { !currentListIDs.contains($0.id) }
    }
    var hasActionableSuggestions: Bool { !actionableSuggestions.isEmpty }
    var hasSelection: Bool { !selectedListIDs.isEmpty }
    var hasMembershipChanges: Bool {
        membershipEditorListIDs != Set(currentLists.map(\.id))
    }
    var isIgnored: Bool { isIgnoredByUser || automaticallyIgnoredFailure != nil }
    /// 待确认建议与已应用结果都可展开编辑；忽略和失败终态只保留诊断摘要。
    var canReviewSuggestions: Bool {
        status == .completed
            && !isApplied
            && !isIgnored
            && applyFailure == nil
            && hasSuggestions
    }
    var isActionable: Bool {
        !isIgnored && (status == .analyzing
            || status == .failed
            || applyFailure != nil
            // 自动应用成功后以仓库为单位进入“已应用”，避免同时出现在待处理与待确认。
            || (!isApplied && hasActionableSuggestions))
    }
    var isNoMatch: Bool { !isIgnored && status == .completed && suggestions.isEmpty }
    var isApplied: Bool {
        if case .applied = applyState { true } else { false }
    }
    var canEditAppliedMemberships: Bool { isApplied && !isApplying }
    var isApplying: Bool { applyState == .applying }
    var applyFailure: GitHubStarListAIApplyFailure? {
        if case .failed(let failure) = applyState { failure } else { nil }
    }
    var automaticallyIgnoredFailure: GitHubStarListAIApplyFailure? {
        if case .ignored(let failure) = applyState { failure } else { nil }
    }
    var appliedListIDs: Set<String> {
        if case .applied(let ids) = applyState { ids } else { [] }
    }

    func matches(filter: GitHubStarListAIResultFilter, searchText: String) -> Bool {
        let matchesFilter = switch filter {
        case .actionable:
            isActionable
        case .all:
            true
        case .suggestions:
            !isApplied && hasActionableSuggestions && applyFailure == nil && !isIgnored
        case .noMatch:
            isNoMatch
        case .analysisFailed:
            status == .failed
        case .applyFailed:
            applyFailure != nil
        case .applied:
            isApplied
        case .automaticallyIgnored:
            automaticallyIgnoredFailure != nil
        case .ignored:
            isIgnoredByUser && automaticallyIgnoredFailure == nil
        }
        guard matchesFilter else { return false }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if repoFullName.localizedStandardContains(query) { return true }
        if repo.description?.localizedStandardContains(query) == true { return true }
        return suggestions.contains { $0.list.name.localizedStandardContains(query) }
            || currentLists.contains { $0.name.localizedStandardContains(query) }
    }

    static func ordered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
        if lhs.finishedAt != rhs.finishedAt {
            // 待确认建议按生成完成时间正序追加，避免后完成的结果不断插到列表顶部。
            if lhs.sortRank == 2 {
                return (lhs.finishedAt ?? .distantFuture) < (rhs.finishedAt ?? .distantFuture)
            }
            return (lhs.finishedAt ?? .distantPast) > (rhs.finishedAt ?? .distantPast)
        }
        return lhs.repoFullName.localizedCaseInsensitiveCompare(rhs.repoFullName) == .orderedAscending
    }

    private var sortRank: Int {
        if status == .analyzing { return 0 }
        if applyFailure != nil { return 1 }
        if isIgnored { return 6 }
        if isApplied { return 4 }
        if hasActionableSuggestions { return 2 }
        if status == .failed { return 3 }
        if isNoMatch { return 5 }
        return 7
    }
}

/// 将会话状态一次性投影为审核页快照。
///
/// 开始页计数来自 COUNT / GROUP BY，不扫描完整仓库数组。审核列表的映射、排序
/// 与筛选仍收敛成单次刷新，避免 SwiftUI 高频 `body` 重复扫描近 2,000 个任务。
struct GitHubStarListAIGroupingPresentationSnapshot: Equatable, Sendable {
    let items: [GitHubStarListAIReviewItem]
    let availableLists: [GitHubStarListAIListDisplay]
    let preparedRepositoryCount: Int
    let groupedRepositoryCount: Int
    let ungroupedRepositoryCount: Int
    let analysisTotalCount: Int
    let preparedAutomaticallyIgnoredRepoCount: Int
    let candidateListCount: Int
    let preflightGroups: [GitHubStarListAIPreflightGroupDisplay]
    let analyzedCount: Int
    let suggestionCount: Int
    let noMatchCount: Int
    let analysisFailedCount: Int
    let applyFailedCount: Int
    let recoverableApplyFailureCount: Int
    let appliedCount: Int
    let automaticallyIgnoredCount: Int
    let ignoredCount: Int
    let actionableCount: Int
    let selectedRepositoryCount: Int
    let selectedListCount: Int
    let hasContinuableJobs: Bool

    var totalCount: Int { items.count }

    init(
        jobs: [GitHubStarListAIGroupingJob],
        availableLists: [GitHubStarListAIListDisplay],
        existingListIDsByRepo: [Int64: Set<String>],
        selectedListIDsByRepo: [Int64: Set<String>],
        editedListIDsByRepo: [Int64: Set<String>] = [:],
        ignoredRepoIDs: Set<Int64>,
        preparedRepositoryCount: Int = 0,
        ungroupedRepositoryCount: Int = 0,
        preparedAnalysisRepositoryCount: Int? = nil,
        preparedAutomaticallyIgnoredRepoCount: Int = 0,
        membershipCountByListID: [String: Int] = [:],
        rulesByListID: [String: GitHubStarListAIRule] = [:]
    ) {
        let orderedLists = availableLists.sorted { $0.name < $1.name }
        let listsByID = Dictionary(uniqueKeysWithValues: orderedLists.map { ($0.id, $0) })

        let preflightGroups = orderedLists.map { list in
            let rule = rulesByListID[list.id]
            return GitHubStarListAIPreflightGroupDisplay(
                list: list,
                repositoryCount: membershipCountByListID[list.id, default: 0],
                // 样例名不再为概览去扫完整仓库表；卡片只展示计数。
                sampleRepositoryNames: [],
                hasAIRule: !(rule?.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                autoApplyEnabled: rule?.autoApplyEnabled ?? false
            )
        }
        var projectedItems: [GitHubStarListAIReviewItem] = []
        projectedItems.reserveCapacity(jobs.count)

        var analyzedCount = 0
        var suggestionCount = 0
        var noMatchCount = 0
        var analysisFailedCount = 0
        var applyFailedCount = 0
        var recoverableApplyFailureCount = 0
        var appliedCount = 0
        var automaticallyIgnoredCount = 0
        var ignoredCount = 0
        var actionableCount = 0
        var selectedRepositoryCount = 0
        var selectedListIDs: Set<String> = []
        var hasContinuableJobs = false

        for job in jobs {
            let currentIDs = existingListIDsByRepo[job.id] ?? []
            let currentLists = currentIDs.compactMap { listsByID[$0] }.sorted { $0.name < $1.name }
            let suggestions = job.suggestions.compactMap { suggestion -> GitHubStarListAISuggestionDisplay? in
                guard let list = listsByID[suggestion.listId] else { return nil }
                return GitHubStarListAISuggestionDisplay(
                    list: list,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason
                )
            }
            let selection = (selectedListIDsByRepo[job.id] ?? []).subtracting(currentIDs)
            let membershipEditorListIDs = editedListIDsByRepo[job.id] ?? currentIDs
            let appliedListIDs: Set<String> = if case .applied(let ids) = job.applyState { ids } else { [] }
            let item = GitHubStarListAIReviewItem(
                id: job.id,
                repo: job.repo,
                status: job.status,
                currentLists: currentLists,
                suggestions: suggestions,
                selectedListIDs: selection,
                membershipEditorListIDs: membershipEditorListIDs,
                // 两处摘要和芯片墙都沿用 `orderedLists`，只改变展示顺序，不遗漏多选结果。
                selectedGroupSummaries: Self.makeGroupSummaries(
                    listIDs: selection,
                    orderedLists: orderedLists,
                    suggestions: suggestions
                ),
                appliedGroupSummaries: Self.makeGroupSummaries(
                    listIDs: Self.itemAppliedListIDs(currentIDs: currentIDs, appliedListIDs: appliedListIDs),
                    orderedLists: orderedLists,
                    suggestions: suggestions
                ),
                applyState: job.applyState,
                isIgnoredByUser: ignoredRepoIDs.contains(job.id),
                analysisFailureMessage: job.analysisFailure?.localizedMessage,
                finishedAt: job.finishedAt
            )
            projectedItems.append(item)

            if !job.isExcludedFromAnalysis,
               (job.status == .completed || job.status == .failed) {
                analyzedCount += 1
            }
            if item.matches(filter: .suggestions, searchText: "") { suggestionCount += 1 }
            if item.isNoMatch { noMatchCount += 1 }
            if job.status == .failed { analysisFailedCount += 1 }
            if item.applyFailure != nil { applyFailedCount += 1 }
            if item.applyFailure?.isRetryable == true { recoverableApplyFailureCount += 1 }
            if item.isApplied { appliedCount += 1 }
            if item.automaticallyIgnoredFailure != nil { automaticallyIgnoredCount += 1 }
            if item.isIgnoredByUser && item.automaticallyIgnoredFailure == nil { ignoredCount += 1 }
            if item.isActionable { actionableCount += 1 }
            if !selection.isEmpty {
                selectedRepositoryCount += 1
                selectedListIDs.formUnion(selection)
            }
            if job.status == .queued || job.status == .stopped || job.status == .failed {
                hasContinuableJobs = true
            }
        }

        self.items = projectedItems.sorted(by: GitHubStarListAIReviewItem.ordered)
        self.availableLists = orderedLists
        self.preparedRepositoryCount = preparedRepositoryCount
        self.ungroupedRepositoryCount = ungroupedRepositoryCount
        self.analysisTotalCount = preparedAnalysisRepositoryCount
            ?? jobs.count { !$0.isExcludedFromAnalysis }
        self.preparedAutomaticallyIgnoredRepoCount = preparedAutomaticallyIgnoredRepoCount
        self.groupedRepositoryCount = max(0, preparedRepositoryCount - ungroupedRepositoryCount)
        self.candidateListCount = preflightGroups.filter(\.hasAIRule).count
        self.preflightGroups = preflightGroups
        self.analyzedCount = analyzedCount
        self.suggestionCount = suggestionCount
        self.noMatchCount = noMatchCount
        self.analysisFailedCount = analysisFailedCount
        self.applyFailedCount = applyFailedCount
        self.recoverableApplyFailureCount = recoverableApplyFailureCount
        self.appliedCount = appliedCount
        self.automaticallyIgnoredCount = automaticallyIgnoredCount
        self.ignoredCount = ignoredCount
        self.actionableCount = actionableCount
        self.selectedRepositoryCount = selectedRepositoryCount
        self.selectedListCount = selectedListIDs.count
        self.hasContinuableJobs = hasContinuableJobs
    }

    /// 快照阶段一次性生成摘要，避免 SwiftUI 每次刷新可见行时重复构造字典和排序。
    private static func makeGroupSummaries(
        listIDs: Set<String>,
        orderedLists: [GitHubStarListAIListDisplay],
        suggestions: [GitHubStarListAISuggestionDisplay]
    ) -> [GitHubStarListAIGroupSummaryDisplay] {
        guard !listIDs.isEmpty else { return [] }
        let confidenceByListID = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.id, $0.confidence) })
        return orderedLists.compactMap { list in
            guard listIDs.contains(list.id) else { return nil }
            return GitHubStarListAIGroupSummaryDisplay(
                list: list,
                confidence: confidenceByListID[list.id]
            )
        }
    }

    /// 分段控件显示的数字与对应筛选严格复用同一份判断，避免“数字可点但不是 Tab 数据”的歧义。
    func count(for filter: GitHubStarListAIResultFilter) -> Int {
        switch filter {
        case .actionable: actionableCount
        case .all: totalCount
        case .suggestions: suggestionCount
        case .noMatch: noMatchCount
        case .analysisFailed: analysisFailedCount
        case .applyFailed: applyFailedCount
        case .applied: appliedCount
        case .automaticallyIgnored: automaticallyIgnoredCount
        case .ignored: ignoredCount
        }
    }

    static let empty = Self(
        jobs: [],
        availableLists: [],
        existingListIDsByRepo: [:],
        selectedListIDsByRepo: [:],
        editedListIDsByRepo: [:],
        ignoredRepoIDs: []
    )

    /// 应用成功后展示当前完整 membership；旧快照缺少 current 时再回退到本次应用集合。
    private static func itemAppliedListIDs(
        currentIDs: Set<String>,
        appliedListIDs: Set<String>
    ) -> Set<String> {
        currentIDs.isEmpty ? appliedListIDs : currentIDs
    }
}
