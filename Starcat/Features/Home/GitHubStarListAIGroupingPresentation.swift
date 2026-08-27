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

struct GitHubStarListAISuggestionDisplay: Identifiable, Equatable, Sendable {
    var id: String { list.id }

    let list: GitHubStarListAIListDisplay
    let confidence: Double
    let reason: String
}

enum GitHubStarListAIResultFilter: String, CaseIterable, Identifiable, Sendable {
    case actionable
    case all
    case suggestions
    case noMatch
    case analysisFailed
    case applyFailed
    case applied

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
    let applyState: GitHubStarListAIApplyState
    let isIgnoredByUser: Bool
    let analysisFailureMessage: String?
    let finishedAt: Date?

    var repoFullName: String { repo.fullName }
    var hasSuggestions: Bool { !suggestions.isEmpty }
    var actionableSuggestions: [GitHubStarListAISuggestionDisplay] {
        let currentListIDs = Set(currentLists.map(\.id))
        return suggestions.filter { !currentListIDs.contains($0.id) }
    }
    var hasActionableSuggestions: Bool { !actionableSuggestions.isEmpty }
    var hasSelection: Bool { !selectedListIDs.isEmpty }
    var isIgnored: Bool { isIgnoredByUser || automaticallyIgnoredFailure != nil }
    var isActionable: Bool {
        !isIgnored && (status == .analyzing
            || status == .failed
            || applyFailure != nil
            || (hasActionableSuggestions && !isApplied))
    }
    var isNoMatch: Bool { !isIgnored && status == .completed && suggestions.isEmpty }
    var isApplied: Bool {
        if case .applied = applyState { true } else { false }
    }
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
            hasActionableSuggestions && applyFailure == nil && !isIgnored
        case .noMatch:
            isNoMatch
        case .analysisFailed:
            status == .failed
        case .applyFailed:
            applyFailure != nil
        case .applied:
            isApplied
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
            return (lhs.finishedAt ?? .distantPast) > (rhs.finishedAt ?? .distantPast)
        }
        return lhs.repoFullName.localizedCaseInsensitiveCompare(rhs.repoFullName) == .orderedAscending
    }

    private var sortRank: Int {
        if status == .analyzing { return 0 }
        if applyFailure != nil { return 1 }
        if isIgnored { return 6 }
        if hasActionableSuggestions { return 2 }
        if status == .failed { return 3 }
        if isApplied { return 4 }
        if isNoMatch { return 5 }
        return 7
    }
}

/// 将会话状态一次性投影为审核页快照。
///
/// 这里故意把映射、排序与五类计数收敛成单次刷新，避免 SwiftUI 高频调用 `body`
/// 时重复扫描近 2,000 个任务。多分组使用 `Set<String>` 保留，不做单选降级。
struct GitHubStarListAIGroupingPresentationSnapshot: Equatable, Sendable {
    let items: [GitHubStarListAIReviewItem]
    let availableLists: [GitHubStarListAIListDisplay]
    let preparedRepositoryCount: Int
    let groupedRepositoryCount: Int
    let ungroupedRepositoryCount: Int
    let candidateListCount: Int
    let preflightGroups: [GitHubStarListAIPreflightGroupDisplay]
    let analyzedCount: Int
    let suggestionCount: Int
    let noMatchCount: Int
    let analysisFailedCount: Int
    let applyFailedCount: Int
    let recoverableApplyFailureCount: Int
    let appliedCount: Int
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
        ignoredRepoIDs: Set<Int64>,
        preparedRepositories: [Repo] = [],
        rulesByListID: [String: GitHubStarListAIRule] = [:]
    ) {
        let orderedLists = availableLists.sorted { $0.name < $1.name }
        let listsByID = Dictionary(uniqueKeysWithValues: orderedLists.map { ($0.id, $0) })
        let preparedRepoIDs = Set(preparedRepositories.map(\.id))
        let preparedRepoNamesByID = Dictionary(
            uniqueKeysWithValues: preparedRepositories.map { ($0.id, $0.fullName) }
        )
        var groupedRepoIDs: Set<Int64> = []
        var membershipCountByListID: [String: Int] = [:]
        var samplesByListID: [String: [String]] = [:]

        // membership 允许一仓多组，因此分组内计数可以重叠；顶部“已分组”只按仓库去重。
        for (repoID, listIDs) in existingListIDsByRepo where preparedRepoIDs.contains(repoID) {
            let knownListIDs = listIDs.filter { listsByID[$0] != nil }
            guard !knownListIDs.isEmpty else { continue }
            groupedRepoIDs.insert(repoID)
            for listID in knownListIDs {
                membershipCountByListID[listID, default: 0] += 1
                if let name = preparedRepoNamesByID[repoID], samplesByListID[listID, default: []].count < 3 {
                    samplesByListID[listID, default: []].append(name)
                }
            }
        }

        let preflightGroups = orderedLists.map { list in
            let rule = rulesByListID[list.id]
            return GitHubStarListAIPreflightGroupDisplay(
                list: list,
                repositoryCount: membershipCountByListID[list.id, default: 0],
                sampleRepositoryNames: samplesByListID[list.id, default: []],
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
            let item = GitHubStarListAIReviewItem(
                id: job.id,
                repo: job.repo,
                status: job.status,
                currentLists: currentLists,
                suggestions: suggestions,
                selectedListIDs: selection,
                applyState: job.applyState,
                isIgnoredByUser: ignoredRepoIDs.contains(job.id),
                analysisFailureMessage: job.analysisFailure?.localizedMessage,
                finishedAt: job.finishedAt
            )
            projectedItems.append(item)

            if job.status == .completed || job.status == .failed { analyzedCount += 1 }
            if item.matches(filter: .suggestions, searchText: "") { suggestionCount += 1 }
            if item.isNoMatch { noMatchCount += 1 }
            if job.status == .failed { analysisFailedCount += 1 }
            if item.applyFailure != nil { applyFailedCount += 1 }
            if item.applyFailure?.isRetryable == true { recoverableApplyFailureCount += 1 }
            if item.isApplied { appliedCount += 1 }
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
        self.preparedRepositoryCount = preparedRepositories.count
        self.groupedRepositoryCount = groupedRepoIDs.count
        self.ungroupedRepositoryCount = max(0, preparedRepositories.count - groupedRepoIDs.count)
        self.candidateListCount = preflightGroups.filter(\.hasAIRule).count
        self.preflightGroups = preflightGroups
        self.analyzedCount = analyzedCount
        self.suggestionCount = suggestionCount
        self.noMatchCount = noMatchCount
        self.analysisFailedCount = analysisFailedCount
        self.applyFailedCount = applyFailedCount
        self.recoverableApplyFailureCount = recoverableApplyFailureCount
        self.appliedCount = appliedCount
        self.actionableCount = actionableCount
        self.selectedRepositoryCount = selectedRepositoryCount
        self.selectedListCount = selectedListIDs.count
        self.hasContinuableJobs = hasContinuableJobs
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
        }
    }

    static let empty = Self(
        jobs: [],
        availableLists: [],
        existingListIDsByRepo: [:],
        selectedListIDsByRepo: [:],
        ignoredRepoIDs: []
    )
}
