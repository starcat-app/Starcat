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

        let failure = GitHubStarListAIApplyFailure(
            kind: .organizationOAuthRestriction,
            detail: nil
        )
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

        let transport = GitHubStarListAIApplyFailure.classify(NetworkError.transport(
            underlying: URLError(.networkConnectionLost)
        ))
        #expect(transport.kind == .transport)
        #expect(transport.isRetryable)
    }

    @Test("展示快照一次统计全部状态并保留一个仓库的多个分组选择")
    func snapshotPreservesMultipleGroupSelections() {
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

        let snapshot = GitHubStarListAIGroupingPresentationSnapshot(
            jobs: [job],
            availableLists: [swiftList, databaseList],
            existingListIDsByRepo: [:],
            selectedListIDsByRepo: [1: ["swift", "database"]],
            ignoredRepoIDs: []
        )

        #expect(snapshot.totalCount == 1)
        #expect(snapshot.analyzedCount == 1)
        #expect(snapshot.suggestionCount == 1)
        #expect(snapshot.actionableCount == 1)
        #expect(snapshot.selectedRepositoryCount == 1)
        #expect(snapshot.selectedListCount == 2)
        #expect(snapshot.items.first?.selectedListIDs == ["swift", "database"])
        #expect(snapshot.items.first?.actionableSuggestions.count == 2)
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
        applyState: GitHubStarListAIApplyState = .idle
    ) -> GitHubStarListAIReviewItem {
        GitHubStarListAIReviewItem(
            id: id,
            repo: makeRepo(id: id),
            status: status,
            currentLists: currentLists,
            suggestions: suggestions,
            selectedListIDs: selectedListIDs,
            applyState: applyState,
            isIgnoredByUser: false,
            analysisFailureMessage: nil,
            finishedAt: nil
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
