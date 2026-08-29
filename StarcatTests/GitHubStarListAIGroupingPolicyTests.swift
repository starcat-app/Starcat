//
//  GitHubStarListAIGroupingPolicyTests.swift
//  StarcatTests
//
//  验证 GitHub Lists AI 分组的封闭候选集与自动应用双重门控。
//

import Testing
@testable import Starcat

@Suite("GitHubStarListAISuggestionPolicy")
struct GitHubStarListAIGroupingPolicyTests {

    private let candidates = [
        GitHubStarListAIContext(
            listId: "swift",
            name: "Swift",
            instruction: "Native Swift tools only",
            autoApplyEnabled: true
        ),
        GitHubStarListAIContext(
            listId: "manual",
            name: "Manual Review",
            instruction: "Projects requiring manual review",
            autoApplyEnabled: false
        ),
        GitHubStarListAIContext(
            listId: "empty",
            name: "No Rule",
            instruction: "   ",
            autoApplyEnabled: true
        )
    ]

    @Test("未知、空规则、非法置信度和已有 membership 都被拒绝")
    func rejectsOutOfScopeSuggestions() {
        let input = [
            GitHubStarListAISuggestion(listId: "unknown", confidence: 0.99, reason: "unknown"),
            GitHubStarListAISuggestion(listId: "empty", confidence: 0.99, reason: "empty rule"),
            GitHubStarListAISuggestion(listId: "swift", confidence: .nan, reason: "invalid"),
            GitHubStarListAISuggestion(listId: "manual", confidence: 0.95, reason: "already exists")
        ]

        let result = GitHubStarListAISuggestionPolicy.validatedSuggestions(
            input,
            candidates: candidates,
            existingListIDs: ["manual"]
        )
        #expect(result.isEmpty)
    }

    @Test("一个仓库可保留多个合法建议，重复 List 取最高置信度")
    func keepsMultipleListsAndDeduplicates() {
        let input = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.72, reason: "first"),
            GitHubStarListAISuggestion(listId: "manual", confidence: 0.83, reason: "manual"),
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.96, reason: "better")
        ]

        let result = GitHubStarListAISuggestionPolicy.validatedSuggestions(
            input,
            candidates: candidates,
            existingListIDs: []
        )
        #expect(result.map(\.listId) == ["swift", "manual"])
        #expect(result.first?.reason == "better")
    }

    @Test("自动应用必须同时满足 List 开关与置信度阈值")
    func automaticApplyRequiresListOptInAndThreshold() {
        let validated = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.91, reason: "allowed"),
            GitHubStarListAISuggestion(listId: "manual", confidence: 0.99, reason: "list switch off"),
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.70, reason: "too low")
        ]

        let result = GitHubStarListAISuggestionPolicy.automaticSuggestions(
            from: validated,
            candidates: candidates,
            confidenceThreshold: 0.90
        )
        #expect(result.map(\.reason) == ["allowed"])
    }

    @Test("审核建议未确认时不生成写入计划，确认后仍限制在建议闭集")
    func previewRequiresExplicitConfirmation() {
        let suggestions = [
            GitHubStarListAISuggestion(listId: "swift", confidence: 0.95, reason: "match"),
            GitHubStarListAISuggestion(listId: "manual", confidence: 0.88, reason: "review")
        ]

        let unconfirmed = GitHubStarListAISuggestionPolicy.confirmedListIDs(
            from: suggestions,
            selectedListIDs: ["swift", "unknown"],
            confirmationGranted: false
        )
        #expect(unconfirmed.isEmpty)

        let confirmed = GitHubStarListAISuggestionPolicy.confirmedListIDs(
            from: suggestions,
            selectedListIDs: ["swift", "unknown"],
            confirmationGranted: true
        )
        #expect(confirmed == ["swift"])
    }

    @Test("人工改选允许现有分组，但拒绝未知分组、已有 membership 和未确认请求")
    func manualCorrectionStaysInsideExistingLists() {
        let unconfirmed = GitHubStarListAISuggestionPolicy.confirmedExistingListIDs(
            selectedListIDs: ["swift", "manual"],
            availableListIDs: ["swift", "manual"],
            existingListIDs: [],
            confirmationGranted: false
        )
        #expect(unconfirmed.isEmpty)

        let confirmed = GitHubStarListAISuggestionPolicy.confirmedExistingListIDs(
            selectedListIDs: ["swift", "manual", "unknown"],
            availableListIDs: ["swift", "manual"],
            existingListIDs: ["manual"],
            confirmationGranted: true
        )
        #expect(confirmed == ["swift"])
    }
}

@Suite("GitHub Star List 自动分组候选")
struct GitHubStarListAutoGroupingCandidateTests {
    @Test("截取批量前排除已有分组、v34 自动忽略和当前规则已尝试仓库")
    func excludesResolvedRepositoriesBeforeApplyingLimit() {
        let repos = (1...10).map { makeRepo(id: Int64($0), starredAt: "2026-08-\($0)") }

        let picked = GitHubStarListAIGroupingSession.automaticRepositories(
            from: repos,
            existingListIDsByRepo: [10: ["group"]],
            automaticallyIgnoredRepoIDs: [9],
            attemptedRepositoryIDs: [8],
            sortOrder: .recentlyStarred,
            limit: 5
        )

        #expect(picked.map(\.id) == [7, 6, 5, 4, 3])
    }

    @Test("规则顺序不改变指纹，规则内容或阈值变化会改变指纹")
    func fingerprintTracksOnlyDecisionConfiguration() {
        let first = GitHubStarListAIContext(
            listId: "ai",
            name: "AI",
            instruction: "AI repositories",
            autoApplyEnabled: true
        )
        let second = GitHubStarListAIContext(
            listId: "skills",
            name: "Skills",
            instruction: "Agent skills",
            autoApplyEnabled: true
        )
        let baseline = GitHubStarListAIGroupingSession.automaticConfigurationFingerprint(
            candidates: [first, second],
            confidenceThreshold: 0.9
        )
        let reordered = GitHubStarListAIGroupingSession.automaticConfigurationFingerprint(
            candidates: [second, first],
            confidenceThreshold: 0.9
        )
        let changedThreshold = GitHubStarListAIGroupingSession.automaticConfigurationFingerprint(
            candidates: [first, second],
            confidenceThreshold: 0.85
        )
        let changedRule = GitHubStarListAIGroupingSession.automaticConfigurationFingerprint(
            candidates: [
                GitHubStarListAIContext(
                    listId: first.listId,
                    name: first.name,
                    instruction: "Only local AI repositories",
                    autoApplyEnabled: true
                ),
                second
            ],
            confidenceThreshold: 0.9
        )

        #expect(baseline == reordered)
        #expect(baseline != changedThreshold)
        #expect(baseline != changedRule)
    }

    private func makeRepo(id: Int64, starredAt: String? = nil) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            fullName: "owner/repo-\(id)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
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
            starredAt: starredAt,
            cachedAt: nil
        )
    }
}
