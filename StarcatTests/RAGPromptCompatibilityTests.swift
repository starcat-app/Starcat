//
//  RAGPromptCompatibilityTests.swift
//  StarcatTests
//
//  验证 RAG 自定义 Prompt 的默认、自定义、缺失与重复占位符诊断语义。
//

import Testing
@testable import Starcat

@Suite("RAG Prompt 兼容性")
struct RAGPromptCompatibilityTests {
    @Test("问答和压缩默认用户模板使用可读 Markdown 分区")
    func defaultUserTemplatesUseReadableMarkdownSections() {
        #expect(RAGDefaultPrompts.generator.userPromptTemplate == """
        # Runtime context

        {questionSection}

        {evidenceSection}

        {repositoryInsightsSection}

        {repoContextSection}

        {remoteSection}

        {attachmentSection}

        # Task

        Answer the user question using only the available context above.
        """)
        #expect(RAGDefaultPrompts.compressor.userPromptTemplate == """
        # Conversation context

        {existingSummarySection}

        {newMessagesSection}

        # Task

        Merge the conversation context above into a concise factual digest.
        Output the updated digest only.
        """)
    }

    @Test("默认 Prompt 不产生兼容性提示")
    func defaultPromptIsRecognized() {
        let result = RAGPromptCompatibilityAnalyzer.analyze(
            current: RAGDefaultPrompts.generator,
            reference: RAGDefaultPrompts.generator
        )

        #expect(result.state == .defaultValue)
        #expect(result.missingPlaceholders.isEmpty)
    }

    @Test("保留全部占位符的自定义 Prompt 仍然兼容")
    func customizedPromptCanRemainCompatible() {
        var current = RAGDefaultPrompts.generator
        current.systemPrompt += "\nPrefer concise answers."

        let result = RAGPromptCompatibilityAnalyzer.analyze(
            current: current,
            reference: RAGDefaultPrompts.generator
        )

        #expect(result.state == .customized)
        #expect(result.missingPlaceholders.isEmpty)
    }

    @Test("缺失的系统和用户占位符分别报告")
    func missingPlaceholdersAreReportedByField() {
        let current = AIPromptConfiguration(
            systemPrompt: "Answer concisely.",
            userPromptTemplate: "{questionSection}{evidenceSection}{repoContextSection}"
        )

        let result = RAGPromptCompatibilityAnalyzer.analyze(
            current: current,
            reference: RAGDefaultPrompts.generator
        )

        #expect(result.state == .limited)
        #expect(result.missingSystemPlaceholders.contains("{outputLanguage}"))
        #expect(result.missingUserPlaceholders.contains("{repositoryInsightsSection}"))
        #expect(result.missingUserPlaceholders.contains("{remoteSection}"))
        #expect(result.missingUserPlaceholders.contains("{attachmentSection}"))
    }

    @Test("重复占位符会报告但不会修改用户正文")
    func duplicatedPlaceholdersAreReportedWithoutMutation() {
        let current = AIPromptConfiguration(
            systemPrompt: """
            Answer in {outputLanguage}.
            Keep technical terms in {outputLanguage}.
            """,
            userPromptTemplate: """
            {questionSection}
            {evidenceSection}
            {repositoryInsightsSection}: {repositoryInsightsSection}
            {repoContextSection}
            {remoteSection}
            {attachmentSection}
            """
        )

        let result = RAGPromptCompatibilityAnalyzer.analyze(
            current: current,
            reference: RAGDefaultPrompts.generator
        )

        #expect(result.state == .limited)
        #expect(result.missingPlaceholders.isEmpty)
        #expect(result.duplicatedSystemPlaceholders == ["{outputLanguage}"])
        #expect(result.duplicatedUserPlaceholders == ["{repositoryInsightsSection}"])
        #expect(current.userPromptTemplate.contains(
            "{repositoryInsightsSection}: {repositoryInsightsSection}"
        ))
    }

    @Test("占位符提取保持顺序并忽略普通花括号")
    func placeholderExtractionIsStable() {
        let result = RAGPromptCompatibilityAnalyzer.placeholders(
            in: "{question} JSON: {\"mode\": true} {question} {repoContextSection}"
        )

        #expect(result == ["{question}", "{repoContextSection}"])
    }
}
