//
//  RAGQueryGuidance.swift
//  Starcat
//
//  RAG 的确定性闲聊分流与无证据引导。这里不做知识问答，只负责避免无意义检索和给出
//  可以继续执行的示例问题。
//

import Foundation

enum RAGQueryGuidance {
    private static let socialInputs: Set<String> = [
        "你好", "您好", "嗨", "哈喽", "hello", "hi", "hey",
        "谢谢", "感谢", "thanks", "thank you", "再见", "bye",
    ]

    /// 只对不携带仓库、链接和附件的纯社交短句做本地短路。稍有知识意图的输入仍交给
    /// Planner，避免规则表抢走“你好，介绍一下 @repo”这类合法问题。
    static func pureSocialResponse(
        question: String,
        composerContext: RAGComposerContext
    ) -> RAGTerminalResponse? {
        guard composerContext.explicitRepoIDs.isEmpty,
              composerContext.attachments.isEmpty,
              composerContext.pastedGitHubLinks.isEmpty else { return nil }
        let normalized = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased()
        guard socialInputs.contains(normalized) else { return nil }
        return RAGTerminalResponse(
            answer: String.l10n("rag.workspace.guidance.socialReply"),
            suggestedActions: defaultActions()
        )
    }

    static func guidedResponse(plan: RAGQueryPlan, composerContext: RAGComposerContext) -> RAGTerminalResponse {
        let questions = normalizedQuestions(plan.fallbackQuestions)
        return RAGTerminalResponse(
            answer: String.l10n("rag.workspace.guidance.outOfScopeReply"),
            suggestedActions: actions(
                questions: questions.isEmpty ? defaultQuestions(for: composerContext) : questions,
                composerContext: composerContext
            )
        )
    }

    static func noEvidenceResponse(
        plan: RAGQueryPlan,
        composerContext: RAGComposerContext,
        answerKey: String
    ) -> RAGTerminalResponse {
        let questions = normalizedQuestions(plan.fallbackQuestions)
        return RAGTerminalResponse(
            answer: String.l10n(answerKey),
            suggestedActions: actions(
                questions: questions.isEmpty ? defaultQuestions(for: composerContext) : questions,
                composerContext: composerContext
            )
        )
    }

    private static func defaultQuestions(for context: RAGComposerContext) -> [String] {
        [
            String.l10n("rag.workspace.guidance.question.overview"),
            String.l10n("rag.workspace.guidance.question.compare"),
            String.l10n(context.explicitRepoIDs.isEmpty
                        ? "rag.workspace.guidance.question.recentlyUpdated"
                        : "rag.workspace.guidance.question.latestIssues"),
        ]
    }

    private static func defaultActions() -> [RAGSuggestedQuestionAction] {
        defaultQuestions(for: RAGComposerContext()).map { RAGSuggestedQuestionAction(question: $0) }
    }

    private static func actions(
        questions: [String],
        composerContext: RAGComposerContext
    ) -> [RAGSuggestedQuestionAction] {
        Array(questions.prefix(3)).map { question in
            RAGSuggestedQuestionAction(
                question: question,
                repoIDs: composerContext.explicitRepoIDs,
                explicitRepoMode: composerContext.explicitRepoMode
            )
        }
    }

    private static func normalizedQuestions(_ questions: [String]) -> [String] {
        var seen: Set<String> = []
        return questions.compactMap { rawQuestion in
            let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty, question.count <= 120, seen.insert(question).inserted else { return nil }
            return question
        }
    }
}
