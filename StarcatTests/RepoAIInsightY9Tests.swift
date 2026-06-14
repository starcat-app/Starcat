//
//  RepoAIInsightY9Tests.swift
//  StarcatTests
//
//  Y9（2026-06-14）对话上下文增强相关单元测试。
//
//  测试目标：
//   1. **Codable 向后兼容**：旧缓存 JSON 缺 `externalContextMarkdown` 字段时反序列化为 nil，
//      不抛错。这是避免本次 model 变更让用户的 ai_summaries 旧缓存失效的核心保护。
//   2. **assembleChatSystemPrompt 拼接正确性**：在「摘要 / 外部材料 / allowExternal 开关」
//      不同组合下，输出顺序与拼接逻辑符合 grill-me 决议 A=a2 + B=b2 + F1=f1b。
//
//  为什么不测 chatStream 整链路：链路依赖 OpenAIClient + Keychain + AISummaryRepository
//  （SQLite），mock 工作量大且超出本次任务范围。把核心拼接逻辑抽成 internal static 纯函数
//  后做单测，与现有项目"AnySearchClientTests 测 wire 路径 + AnySearchContextProviderTests
//  测组装路径"的分层风格一致。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoAIInsight Y9 — chat context enrichment")
struct RepoAIInsightY9Tests {

    // MARK: - Codable 兼容性

    @Test("旧缓存 JSON 缺 externalContextMarkdown 字段时反序列化为 nil 不抛错")
    func decodesLegacyJsonWithoutExternalField() throws {
        // 模拟 Y9 之前的 ai_summaries.summary_json 写入：没有 externalContextMarkdown 也没有
        // contextMetadata（contextMetadata 是 Y2 引入的，更早的缓存连这个都没有）。
        let legacyJson = """
        {
          "oneLiner": "A library for X.",
          "summary": "## 摘要\\n这是一个测试摘要",
          "summaryMarkdown": "## 摘要\\n这是一个测试摘要",
          "platforms": [],
          "suitableFor": [],
          "strengths": [],
          "risks": [],
          "suggestedTags": [],
          "model": "gpt-test",
          "generatedAt": "2026-05-30T00:00:00Z"
        }
        """

        let data = try #require(legacyJson.data(using: .utf8))
        let insight = try JSONDecoder().decode(RepoAIInsight.self, from: data)

        #expect(insight.oneLiner == "A library for X.")
        #expect(insight.summaryMarkdown == "## 摘要\n这是一个测试摘要")
        #expect(insight.contextMetadata == nil)
        #expect(insight.externalContextMarkdown == nil)
    }

    @Test("含 externalContextMarkdown 的 JSON 序列化往返一致")
    func roundTripsExternalContextMarkdown() throws {
        let original = RepoAIInsight(
            oneLiner: "Test",
            summary: "summary",
            summaryMarkdown: "## summary",
            platforms: [],
            suitableFor: [],
            strengths: [],
            risks: [],
            minimalExample: nil,
            suggestedTags: [],
            model: "gpt-test",
            generatedAt: "2026-06-14T00:00:00Z",
            contextMetadata: nil,
            externalContextMarkdown: "<external_context>linked</external_context>",
            generationContextSettings: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoAIInsight.self, from: data)

        #expect(decoded.externalContextMarkdown == "<external_context>linked</external_context>")
        #expect(decoded.summaryMarkdown == "## summary")
    }

    // MARK: - Y9.1 generationContextSettings 快照（修 stale banner 误报）

    @Test("Y9.1：缺 generationContextSettings 字段反序列化为 nil（老 insight 兼容）")
    func decodesLegacyJsonWithoutGenerationContextSettings() throws {
        // 模拟 Y9 时代缓存：含 externalContextMarkdown 但没有 generationContextSettings
        // —— 这是 Y9.1 修复的核心场景。
        let json = """
        {
          "oneLiner": "test",
          "summary": "s",
          "platforms": [],
          "suitableFor": [],
          "strengths": [],
          "risks": [],
          "suggestedTags": [],
          "model": "gpt-test",
          "generatedAt": "2026-06-14T00:00:00Z",
          "externalContextMarkdown": "<external_context>x</external_context>"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let insight = try JSONDecoder().decode(RepoAIInsight.self, from: data)

        #expect(insight.externalContextMarkdown != nil)
        #expect(insight.generationContextSettings == nil)
    }

    @Test("Y9.1：generationContextSettings 序列化往返一致（双布尔字段）")
    func roundTripsGenerationContextSettings() throws {
        let snap = GenerationContextSettings(
            codeContextEnabled: true,
            externalContextAllowed: false
        )
        let original = RepoAIInsight(
            oneLiner: "t",
            summary: "s",
            summaryMarkdown: nil,
            platforms: [],
            suitableFor: [],
            strengths: [],
            risks: [],
            minimalExample: nil,
            suggestedTags: [],
            model: "gpt-test",
            generatedAt: "2026-06-14T00:00:00Z",
            contextMetadata: nil,
            externalContextMarkdown: nil,
            generationContextSettings: snap
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoAIInsight.self, from: data)

        #expect(decoded.generationContextSettings?.codeContextEnabled == true)
        #expect(decoded.generationContextSettings?.externalContextAllowed == false)
    }

    // MARK: - assembleChatSystemPrompt

    @Test("最小输入：仅 sourceText，无摘要无外部材料")
    func assembleMinimal() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar\nDescription: hi",
            cachedSummaryMarkdown: nil,
            cachedExternalMarkdown: nil,
            allowExternal: false
        )

        #expect(result.contains("You are Starcat's repository chat assistant"))
        #expect(result.contains("Repository context:"))
        #expect(result.contains("Repository: foo/bar"))
        #expect(!result.contains("Previous AI summary"))
        #expect(!result.contains("<external_context"))
    }

    @Test("含摘要：fenced markdown 块按 f1b 自然语言段插入到 sourceText 之前")
    func assembleWithSummary() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar",
            cachedSummaryMarkdown: "## 一句话\nThis is a test summary.",
            cachedExternalMarkdown: nil,
            allowExternal: true
        )

        // 关键断言：摘要必须出现在 sourceText 之前（决议 A=a2 + F1=f1b 顺序）
        let summaryRange = try? #require(result.range(of: "Previous AI summary"))
        let sourceRange = try? #require(result.range(of: "Repository context:"))
        if let s = summaryRange, let r = sourceRange {
            #expect(s.lowerBound < r.lowerBound)
        }
        // fenced markdown 包裹
        #expect(result.contains("```markdown"))
        #expect(result.contains("This is a test summary."))
    }

    @Test("含外部材料 + allowExternal=true：markdown 拼到末尾")
    func assembleWithExternalAllowed() {
        let externalMd = "<external_context trust=\"untrusted\">\n- [doc](https://x.com)\n</external_context>"
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar",
            cachedSummaryMarkdown: nil,
            cachedExternalMarkdown: externalMd,
            allowExternal: true
        )

        #expect(result.contains("<external_context"))
        #expect(result.contains("- [doc](https://x.com)"))

        // 关键断言：external 必须出现在 sourceText 之后
        let sourceRange = try? #require(result.range(of: "Repository context:"))
        let externalRange = try? #require(result.range(of: "<external_context"))
        if let s = sourceRange, let e = externalRange {
            #expect(s.lowerBound < e.lowerBound)
        }
    }

    @Test("allowExternal=false 时即便缓存里有 markdown 也不拼（用户实时意图优先）")
    func assembleSkipsExternalWhenDisallowed() {
        let externalMd = "<external_context trust=\"untrusted\">\n- [doc](https://x.com)\n</external_context>"
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar",
            cachedSummaryMarkdown: nil,
            cachedExternalMarkdown: externalMd,
            allowExternal: false
        )

        #expect(!result.contains("<external_context"))
        #expect(!result.contains("https://x.com"))
    }

    @Test("摘要全空白字符不拼：避免无意义的空 fenced 块")
    func assembleSkipsBlankSummary() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar",
            cachedSummaryMarkdown: "   \n\n   ",
            cachedExternalMarkdown: nil,
            allowExternal: false
        )

        #expect(!result.contains("Previous AI summary"))
        #expect(!result.contains("```markdown"))
    }

    @Test("全要素拼接：摘要 + sourceText + 外部材料 顺序正确")
    func assembleFullStack() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            sourceText: "Repository: foo/bar",
            cachedSummaryMarkdown: "summary content",
            cachedExternalMarkdown: "<external_context>e</external_context>",
            allowExternal: true
        )

        let summaryIdx = result.range(of: "Previous AI summary")?.lowerBound
        let sourceIdx = result.range(of: "Repository context:")?.lowerBound
        let externalIdx = result.range(of: "<external_context")?.lowerBound

        // 三段都必须存在
        #expect(summaryIdx != nil)
        #expect(sourceIdx != nil)
        #expect(externalIdx != nil)

        // 顺序断言：摘要 < sourceText < external
        if let s = summaryIdx, let r = sourceIdx, let e = externalIdx {
            #expect(s < r)
            #expect(r < e)
        }
    }
}
