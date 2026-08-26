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
    var isActionable: Bool {
        status == .analyzing
            || status == .failed
            || applyFailure != nil
            || (hasActionableSuggestions && !isApplied)
    }
    var isNoMatch: Bool { status == .completed && suggestions.isEmpty }
    var isApplied: Bool {
        if case .applied = applyState { true } else { false }
    }
    var isApplying: Bool { applyState == .applying }
    var applyFailure: GitHubStarListAIApplyFailure? {
        if case .failed(let failure) = applyState { failure } else { nil }
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
            hasActionableSuggestions && applyFailure == nil
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
        if hasActionableSuggestions { return 2 }
        if status == .failed { return 3 }
        if isApplied { return 4 }
        if isNoMatch { return 5 }
        return 6
    }
}

/// 将会话状态一次性投影为审核页快照。
///
/// 这里故意把映射、排序与五类计数收敛成单次刷新，避免 SwiftUI 高频调用 `body`
/// 时重复扫描近 2,000 个任务。多分组使用 `Set<String>` 保留，不做单选降级。
struct GitHubStarListAIGroupingPresentationSnapshot: Equatable, Sendable {
    let items: [GitHubStarListAIReviewItem]
    let availableLists: [GitHubStarListAIListDisplay]
    let analyzedCount: Int
    let suggestionCount: Int
    let noMatchCount: Int
    let analysisFailedCount: Int
    let applyFailedCount: Int
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
        ignoredRepoIDs: Set<Int64>
    ) {
        let orderedLists = availableLists.sorted { $0.name < $1.name }
        let listsByID = Dictionary(uniqueKeysWithValues: orderedLists.map { ($0.id, $0) })
        var projectedItems: [GitHubStarListAIReviewItem] = []
        projectedItems.reserveCapacity(jobs.count)

        var analyzedCount = 0
        var suggestionCount = 0
        var noMatchCount = 0
        var analysisFailedCount = 0
        var applyFailedCount = 0
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
        self.analyzedCount = analyzedCount
        self.suggestionCount = suggestionCount
        self.noMatchCount = noMatchCount
        self.analysisFailedCount = analysisFailedCount
        self.applyFailedCount = applyFailedCount
        self.appliedCount = appliedCount
        self.actionableCount = actionableCount
        self.selectedRepositoryCount = selectedRepositoryCount
        self.selectedListCount = selectedListIDs.count
        self.hasContinuableJobs = hasContinuableJobs
    }

    static let empty = Self(
        jobs: [],
        availableLists: [],
        existingListIDsByRepo: [:],
        selectedListIDsByRepo: [:],
        ignoredRepoIDs: []
    )
}
