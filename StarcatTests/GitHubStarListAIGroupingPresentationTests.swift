//
//  GitHubStarListAIGroupingPresentationTests.swift
//  StarcatTests
//
//  验证 AI 仓库分组审核列表的筛选、去重和 GitHub 应用失败分类。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubStarListAIGroupingPresentation")
struct GitHubStarListAIGroupingPresentationTests {
    private let swiftList = GitHubStarListAIListDisplay(
        id: "swift",
        name: "Swift Tools",
        instruction: "Native Swift developer tools",
        colorHex: "#FF9500"
    )

    @Test("建议、无匹配和分析失败筛选不会混入其它状态")
    func filtersByReviewStatus() {
        let suggested = makeItem(id: 1, status: .completed, suggestions: [suggestion])
        let noMatch = makeItem(id: 2, status: .completed)
        let failed = makeItem(id: 3, status: .failed)

        #expect(suggested.matches(filter: .suggestions, searchText: ""))
        #expect(suggested.matches(filter: .actionable, searchText: ""))
        #expect(!suggested.matches(filter: .noMatch, searchText: ""))
        #expect(noMatch.matches(filter: .noMatch, searchText: ""))
        #expect(!noMatch.matches(filter: .actionable, searchText: ""))
        #expect(failed.matches(filter: .analysisFailed, searchText: ""))
        #expect(failed.matches(filter: .actionable, searchText: ""))

        let alreadyGrouped = makeItem(
            id: 4,
            status: .completed,
            currentLists: [swiftList],
            suggestions: [suggestion]
        )
        #expect(!alreadyGrouped.hasActionableSuggestions)
        #expect(!alreadyGrouped.matches(filter: .suggestions, searchText: ""))
    }

    @Test("待确认建议按生成完成时间正序排列")
    func pendingSuggestionsKeepFirstCompletionAtTop() {
        let firstCompleted = makeItem(
            id: 1,
            status: .completed,
            suggestions: [suggestion],
            finishedAt: Date(timeIntervalSince1970: 100)
        )
        let laterCompleted = makeItem(
            id: 2,
            status: .completed,
            suggestions: [suggestion],
            finishedAt: Date(timeIntervalSince1970: 200)
        )

        let ordered = [laterCompleted, firstCompleted].sorted(by: GitHubStarListAIReviewItem.ordered)

        #expect(ordered.map(\.id) == [firstCompleted.id, laterCompleted.id])
    }

    @Test("搜索同时覆盖仓库名、建议分组和当前分组")
    func searchesRepositoryAndGroups() {
        let item = makeItem(
            id: 1,
            status: .completed,
            currentLists: [swiftList],
            suggestions: [suggestion]
        )

        #expect(item.matches(filter: .all, searchText: "owner/repo"))
        #expect(item.matches(filter: .all, searchText: "swift tools"))
        #expect(!item.matches(filter: .all, searchText: "database"))
    }

    @Test("已有 membership 会移除待应用建议，应用成功与失败分别筛选")
    func derivesActionabilityFromCurrentMembershipsAndApplyState() {
        let applied = makeItem(
            id: 1,
            status: .completed,
            currentLists: [swiftList],
            suggestions: [suggestion],
            selectedListIDs: ["swift"],
            applyState: .applied(["swift"])
        )
        #expect(applied.actionableSuggestions.isEmpty)
        #expect(applied.matches(filter: .applied, searchText: ""))
        #expect(!applied.matches(filter: .suggestions, searchText: ""))

        let failure = GitHubStarListAIApplyFailure(kind: .transport, detail: "offline")
        let applyFailed = makeItem(
            id: 2,
            status: .completed,
            suggestions: [suggestion],
            selectedListIDs: ["swift"],
            applyState: .failed(failure)
        )
        #expect(applyFailed.matches(filter: .applyFailed, searchText: ""))
        #expect(!applyFailed.matches(filter: .suggestions, searchText: ""))
    }

    @Test("组织 OAuth 限制不可重试，传输错误可重试")
    func classifiesGitHubApplyFailures() {
        let restriction = GitHubStarListAIApplyFailure.classify(NetworkError.clientError(
            statusCode: 403,
            message: "OAuth App access restrictions are restricting access to your organization's data"
        ))
        #expect(restriction.kind == .organizationOAuthRestriction)
        #expect(!restriction.isRetryable)
        #expect(restriction.shouldAutomaticallyIgnore)

        let transport = GitHubStarListAIApplyFailure.classify(NetworkError.transport(
            underlying: URLError(.networkConnectionLost)
        ))
        #expect(transport.kind == .transport)
        #expect(transport.isRetryable)
        #expect(!transport.shouldAutomaticallyIgnore)
    }

    @Test("组织限制作为已忽略终态，不再进入待处理、建议或应用失败")
    func organizationRestrictionIsAutomaticallyIgnored() {
        let restriction = GitHubStarListAIApplyFailure(
            kind: .organizationOAuthRestriction,
            detail: nil
        )
        var job = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        job.status = .completed
        job.suggestions = [GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "Swift")]
        job.applyState = .ignored(restriction)

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [job],
            availableLists: [swiftList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [:],
            ignoredRepoIDs: []
        )

        let item = try! #require(snapshot.items.first)
        #expect(item.isIgnored)
        #expect(item.automaticallyIgnoredFailure == restriction)
        #expect(item.matches(filter: .all, searchText: ""))
        #expect(item.matches(filter: .automaticallyIgnored, searchText: ""))
        #expect(!item.matches(filter: .actionable, searchText: ""))
        #expect(!item.matches(filter: .suggestions, searchText: ""))
        #expect(!item.matches(filter: .applyFailed, searchText: ""))
        #expect(snapshot.actionableCount == 0)
        #expect(snapshot.suggestionCount == 0)
        #expect(snapshot.applyFailedCount == 0)
        #expect(snapshot.automaticallyIgnoredCount == 1)
        #expect(snapshot.count(for: .automaticallyIgnored) == 1)
        #expect(!item.matches(filter: .ignored, searchText: ""))
        #expect(snapshot.count(for: .ignored) == 0)
        #expect(snapshot.selectedRepositoryCount == 0)
    }

    @Test("用户主动忽略与组织自动忽略分进不同 Tab")
    func userIgnoredIsSeparateFromAutomaticallyIgnored() {
        var suggested = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        suggested.status = .completed
        suggested.suggestions = [GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "Swift")]
        var restricted = GitHubStarListAIGroupingJob(repo: makeRepo(id: 2))
        restricted.status = .completed
        restricted.applyState = .ignored(
            GitHubStarListAIApplyFailure(kind: .organizationOAuthRestriction, detail: nil)
        )

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [suggested, restricted],
            availableLists: [swiftList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [:],
            ignoredRepoIDs: [1]
        )

        #expect(snapshot.count(for: .ignored) == 1)
        #expect(snapshot.count(for: .automaticallyIgnored) == 1)
        #expect(snapshot.count(for: .suggestions) == 0)
        #expect(snapshot.count(for: .actionable) == 0)
        #expect(snapshot.items.first { $0.id == 1 }?.matches(filter: .ignored, searchText: "") == true)
        #expect(snapshot.items.first { $0.id == 2 }?.matches(filter: .automaticallyIgnored, searchText: "") == true)
        #expect(snapshot.items.first { $0.id == 2 }?.matches(filter: .ignored, searchText: "") == false)
    }

    @Test("只有网络和限流错误计入可恢复失败")
    func countsOnlyRecoverableApplyFailures() {
        var retryable = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        retryable.status = .completed
        retryable.applyState = .failed(GitHubStarListAIApplyFailure(kind: .transport, detail: "offline"))
        var permanent = GitHubStarListAIGroupingJob(repo: makeRepo(id: 2))
        permanent.status = .completed
        permanent.applyState = .failed(GitHubStarListAIApplyFailure(kind: .authentication, detail: nil))

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [retryable, permanent],
            availableLists: [swiftList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [1: ["swift"], 2: ["swift"]],
            ignoredRepoIDs: []
        )

        #expect(snapshot.applyFailedCount == 2)
        #expect(snapshot.recoverableApplyFailureCount == 1)
    }

    @Test("展示快照一次统计全部状态并保留一个仓库的多个分组选择")
    func snapshotPreservesMultipleGroupSelections() {
        let databaseList = GitHubStarListAIListDisplay(
            id: "database",
            name: "Databases",
            instruction: "Database projects",
            colorHex: "#34C759"
        )
        let skillsList = GitHubStarListAIListDisplay(
            id: "skills",
            name: "Skills",
            instruction: "Agent skills",
            colorHex: "#AF52DE"
        )
        var job = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        job.status = .completed
        job.suggestions = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "Swift"),
            GitHubStarListAISuggestion(listId: "database", confidence: 0.91, reason: "Database")
        ]

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [job],
            availableLists: [swiftList, databaseList, skillsList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [1: ["swift", "database", "skills"]],
            ignoredRepoIDs: []
        )

        let item = try! #require(snapshot.items.first)
        #expect(snapshot.totalCount == 1)
        #expect(snapshot.analyzedCount == 1)
        #expect(snapshot.suggestionCount == 1)
        #expect(snapshot.actionableCount == 1)
        #expect(snapshot.selectedRepositoryCount == 1)
        #expect(snapshot.selectedListCount == 3)
        #expect(item.selectedListIDs == ["swift", "database", "skills"])
        #expect(item.actionableSuggestions.count == 2)
        #expect(item.selectedGroupSummaries.map(\.id) == ["database", "skills", "swift"])
        #expect(item.selectedGroupSummaries.map(\.confidence) == [0.91, nil, 0.96])
        #expect(item.repoDescription == "local")
    }

    @Test("应用摘要保留本次实际加入的全部分组")
    func snapshotPreservesMultipleAppliedGroups() {
        let databaseList = GitHubStarListAIListDisplay(
            id: "database",
            name: "Databases",
            instruction: "Database projects",
            colorHex: "#34C759"
        )
        var job = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        job.status = .completed
        job.suggestions = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "Swift"),
            GitHubStarListAISuggestion(listId: "database", confidence: 0.91, reason: "Database")
        ]
        job.applyState = .applied(["swift", "database"])

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [job],
            availableLists: [swiftList, databaseList],
            existingListIDsByRepo: [1: ["swift", "database"]],
            selectedListIDsByRepo: [:],
            ignoredRepoIDs: []
        )

        let item = try! #require(snapshot.items.first)
        #expect(item.appliedGroupSummaries.map(\.id) == ["database", "swift"])
        #expect(item.appliedGroupSummaries.map(\.confidence) == [0.91, 0.96])
    }

    @Test("整理前统计按仓库去重并保留一仓多组的各组计数")
    func preflightCountsOverlappingMemberships() {
        let databaseList = GitHubStarListAIListDisplay(
            id: "database",
            name: "Databases",
            instruction: "Database projects",
            colorHex: "#34C759"
        )
        let rules = [
            "swift": GitHubStarListAIRule(
                listId: "swift",
                instruction: "Native Swift developer tools",
                autoApplyEnabled: true,
                updatedAt: "2026-08-27T00:00:00Z"
            )
        ]

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [],
            availableLists: [swiftList, databaseList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [:],
            ignoredRepoIDs: [],
            preparedRepositoryCount: 3,
            ungroupedRepositoryCount: 1,
            membershipCountByListID: [
                "swift": 2,
                "database": 1
            ],
            rulesByListID: rules
        )

        #expect(snapshot.preparedRepositoryCount == 3)
        #expect(snapshot.groupedRepositoryCount == 2)
        #expect(snapshot.ungroupedRepositoryCount == 1)
        #expect(snapshot.candidateListCount == 1)
        #expect(snapshot.preflightGroups.first(where: { $0.id == "swift" })?.repositoryCount == 2)
        #expect(snapshot.preflightGroups.first(where: { $0.id == "database" })?.repositoryCount == 1)
    }

    @Test("每个 Tab 的数字等于该筛选实际结果数")
    func tabCountsMatchFilterResults() {
        var suggestionJob = GitHubStarListAIGroupingJob(repo: makeRepo(id: 1))
        suggestionJob.status = .completed
        suggestionJob.suggestions = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "Swift")
        ]
        var noMatchJob = GitHubStarListAIGroupingJob(repo: makeRepo(id: 2))
        noMatchJob.status = .completed
        var failedJob = GitHubStarListAIGroupingJob(repo: makeRepo(id: 3))
        failedJob.status = .failed
        var ignoredJob = GitHubStarListAIGroupingJob(repo: makeRepo(id: 4))
        ignoredJob.status = .completed
        ignoredJob.applyState = .ignored(
            GitHubStarListAIApplyFailure(kind: .organizationOAuthRestriction, detail: nil)
        )

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [suggestionJob, noMatchJob, failedJob, ignoredJob],
            availableLists: [swiftList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [:],
            ignoredRepoIDs: []
        )

        for filter in GitHubStarListAIResultFilter.allCases {
            let actual = snapshot.items.filter { $0.matches(filter: filter, searchText: "") }.count
            #expect(snapshot.count(for: filter) == actual)
        }
    }

    private var suggestion: GitHubStarListAISuggestionDisplay {
        GitHubStarListAISuggestionDisplay(
            list: swiftList,
            confidence: 0.96,
            reason: "Matches the group description"
        )
    }

    private func makeItem(
        id: Int64,
        status: GitHubStarListAIGroupingJobStatus,
        currentLists: [GitHubStarListAIListDisplay] = [],
        suggestions: [GitHubStarListAISuggestionDisplay] = [],
        selectedListIDs: Set<String> = [],
        applyState: GitHubStarListAIApplyState = .idle,
        finishedAt: Date? = nil
    ) -> GitHubStarListAIReviewItem {
        GitHubStarListAIReviewItem(
            id: id,
            repo: makeRepo(id: id),
            status: status,
            currentLists: currentLists,
            suggestions: suggestions,
            selectedListIDs: selectedListIDs,
            selectedGroupSummaries: [],
            appliedGroupSummaries: [],
            applyState: applyState,
            isIgnoredByUser: false,
            analysisFailureMessage: nil,
            finishedAt: finishedAt
        )
    }

    private func makeRepo(id: Int64) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            fullName: "owner/repo-\(id)",
            description: "local",
            language: "Swift",
            starsCount: 10,
            forksCount: 2,
            watchersCount: 10,
            topics: nil,
            license: "Apache-2.0",
            homepage: nil,
            htmlUrl: "https://github.com/owner/repo-\(id)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
