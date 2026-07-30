//
//  RAGPromptCompatibilityTests.swift
//  StarcatTests
//
//  验证 RAG 自定义 Prompt 的默认、自定义、能力受限和非破坏性补齐语义。
//

import Testing
@testable import Starcat

@Suite("RAG Prompt 兼容性")
struct RAGPromptCompatibilityTests {
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

    @Test("补齐操作保留自定义正文且不会重复添加")
    func repairPreservesCustomizationAndIsIdempotent() {
        let current = AIPromptConfiguration(
            systemPrompt: "CUSTOM",
            userPromptTemplate: "{questionSection}{evidenceSection}{repoContextSection}"
        )

        let repaired = RAGPromptCompatibilityAnalyzer.repairing(
            current: current,
            reference: RAGDefaultPrompts.generator
        )
        let repairedAgain = RAGPromptCompatibilityAnalyzer.repairing(
            current: repaired,
            reference: RAGDefaultPrompts.generator
        )
        let result = RAGPromptCompatibilityAnalyzer.analyze(
            current: repaired,
            reference: RAGDefaultPrompts.generator
        )

        #expect(repaired.systemPrompt.hasPrefix("CUSTOM"))
        #expect(repaired.userPromptTemplate.hasPrefix(current.userPromptTemplate))
        #expect(repaired.userPromptTemplate.contains("{repositoryInsightsSection}"))
        #expect(repairedAgain == repaired)
        #expect(result.state == .customized)
    }

    @Test("占位符提取保持顺序并忽略普通花括号")
    func placeholderExtractionIsStable() {
        let result = RAGPromptCompatibilityAnalyzer.placeholders(
            in: "{question} JSON: {\"mode\": true} {question} {repoContextSection}"
        )

        #expect(result == ["{question}", "{repoContextSection}"])
    }
}
