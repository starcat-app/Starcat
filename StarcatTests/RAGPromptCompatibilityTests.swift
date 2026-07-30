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
        #expect(!repaired.userPromptTemplate.contains(
            "{repositoryInsightsSection}: {repositoryInsightsSection}"
        ))
        #expect(repairedAgain == repaired)
        #expect(result.state == .customized)
    }

    @Test("补齐后的运行时 Section 只渲染一次")
    func repairedUserSectionsRenderOnlyOnce() {
        let current = AIPromptConfiguration(
            systemPrompt: RAGDefaultPrompts.generator.systemPrompt,
            userPromptTemplate: "{questionSection}"
        )

        let repaired = RAGPromptCompatibilityAnalyzer.repairing(
            current: current,
            reference: RAGDefaultPrompts.generator
        )
        let rendered = repaired.renderedUserPrompt(placeholders: [
            "questionSection": "QUESTION_VALUE",
            "evidenceSection": "EVIDENCE_VALUE",
            "repositoryInsightsSection": "INSIGHTS_VALUE",
            "repoContextSection": "REPO_CONTEXT_VALUE",
            "remoteSection": "REMOTE_VALUE",
            "attachmentSection": "ATTACHMENT_VALUE",
        ])

        #expect(rendered.components(separatedBy: "INSIGHTS_VALUE").count == 2)
        #expect(rendered.components(separatedBy: "REPO_CONTEXT_VALUE").count == 2)
        #expect(rendered.contains("# Starcat runtime context"))
    }

    @Test("已保存的旧重复补齐格式自动规范化")
    func legacyDuplicatedRepairBlockIsNormalized() {
        let legacy = AIPromptConfiguration(
            systemPrompt: """
            CUSTOM

            Starcat runtime variables:
            {outputLanguage}: {outputLanguage}
            """,
            userPromptTemplate: """
            CUSTOM USER

            Starcat runtime context:
            {questionSection}: {questionSection}
            {repositoryInsightsSection}: {repositoryInsightsSection}
            """
        )

        let normalized = RAGPromptCompatibilityAnalyzer.normalizingLegacyRepairArtifacts(
            in: legacy
        )

        #expect(normalized.systemPrompt.contains("outputLanguage: {outputLanguage}"))
        #expect(!normalized.systemPrompt.contains("{outputLanguage}: {outputLanguage}"))
        #expect(normalized.userPromptTemplate.contains("# Starcat runtime context"))
        #expect(!normalized.userPromptTemplate.contains("{questionSection}: {questionSection}"))
        #expect(
            normalized.userPromptTemplate.components(
                separatedBy: "{repositoryInsightsSection}"
            ).count == 2
        )
    }

    @Test("占位符提取保持顺序并忽略普通花括号")
    func placeholderExtractionIsStable() {
        let result = RAGPromptCompatibilityAnalyzer.placeholders(
            in: "{question} JSON: {\"mode\": true} {question} {repoContextSection}"
        )

        #expect(result == ["{question}", "{repoContextSection}"])
    }
}
