//
//  RAGComposerContextUsageCalculator.swift
//  Starcat
//
//  Composer 上下文占用的纯值计算器，供 ViewModel 在后台线程生成展示快照。
//

import Foundation

/// 把完整历史映射、Prompt 模板渲染和 token 估算移出 MainActor。
///
/// `Input` 只包含 `Sendable` 值，后台任务不会读取仍在变化的 ViewModel 或 AppSettings；
/// 连续输入、切换模型或切换会话时，调用方可安全取消旧结果并只提交最新快照。
enum RAGComposerContextUsageCalculator {
    struct Input: Sendable {
        let question: String
        let messages: [RAGStoredMessage]
        let contextSummary: RAGConversationContextSummary?
        let attachmentNames: [String]
        let contextWindowTokens: Int
        let maximumOutputTokens: Int
        let maxEvidenceTokens: Int
        let promptConfiguration: AIPromptConfiguration
        let outputLanguage: String
        let lastContextUsage: RAGContextUsage?
    }

    nonisolated static func calculate(_ input: Input) -> RAGContextUsage {
        if input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lastContextUsage = input.lastContextUsage {
            return lastContextUsage
        }

        return KnowledgeRAGPromptBuilder(
            maxEvidenceTokens: input.maxEvidenceTokens,
            promptConfiguration: input.promptConfiguration,
            outputLanguage: input.outputLanguage
        ).preview(
            question: input.question,
            history: RAGConversationHistoryBuilder.build(
                from: input.messages,
                contextSummary: input.contextSummary
            ),
            attachmentNames: input.attachmentNames,
            contextWindowTokens: input.contextWindowTokens,
            maximumOutputTokens: input.maximumOutputTokens
        )
    }
}
