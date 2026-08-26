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
}
