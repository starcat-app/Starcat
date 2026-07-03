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
//  后做单测，与现有项目"AnySearchClientTests 测 wire 路径 + ExternalSearchContextProviderTests
//  测组装路径"的分层风格一致。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoAIInsight Y9 — chat context enrichment")
struct RepoAIInsightY9Tests {

    /// 2026-06-15 v4.x：`assembleChatSystemPrompt` 加了 `runtimeContext` 必填参数。
    /// 本套测试不关心运行环境字段的精确渲染（那是 `RuntimeContextProviderTests` 的事），
    /// 只需要给个稳定 mock 值塞进调用，让现有 7 个 case 编译通过；
    /// 各 case 内的 `#expect` 也不断言这个值——只关心其它占位符的拼接逻辑没回归。
    private static let testRuntimeContext = "(runtime-context-mock)"
    private static let testStarcatResources = "(starcat-resources-mock)"

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
        #expect(insight.externalContextSources == nil)
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
            externalContextSources: [
                AIExternalContextSource(
                    title: "Doc",
                    url: URL(string: "https://example.com/doc")!,
                    host: "example.com",
                    provider: .exa,
                    fetchedAt: "2026-07-03T00:00:00Z"
                )
            ],
            generationContextSettings: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoAIInsight.self, from: data)

        #expect(decoded.externalContextMarkdown == "<external_context>linked</external_context>")
        #expect(decoded.externalContextSources?.first?.provider == .exa)
        #expect(decoded.externalContextSources?.first?.host == "example.com")
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

    // MARK: - assembleChatSystemPrompt（v4 占位符渲染版本）

    /// v4 重构后 assembleChatSystemPrompt 是纯模板渲染：6 占位符无脑替换，没有内部
    /// 条件判断逻辑（旧版的 allowExternal / blank summary 检测都移到了 caller
    /// `buildChatSystemPrompt` 那一层 + nil-coalesce + 私仓门控）。
    /// 这些测试用 `AIDefaultPrompts.chat.systemPrompt` 当 template，验证占位符替换 +
    /// section 顺序 + 默认 prompt 包含的关键短语。

    @Test("最小输入：metadata/readme 必填，其它占位符为空字符串 → section header 仍渲染")
    func assembleMinimal() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "English",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar\nDescription: hi",
            readme: "# Hello",
            codeContext: "",
            summary: "",
            externalContext: "",
            previousSessionCarryOver: ""
        )

        // identity / output format / factual / style 4 段都在
        #expect(result.contains("You are Starcat's repository chat assistant"))
        #expect(result.contains("# Output Format (STRICT)"))
        #expect(result.contains("# Factual Constraints"))
        #expect(result.contains("# Reply Style"))

        // 5 个 input section 标题都在（即便对应占位符为空）
        #expect(result.contains("## Metadata"))
        #expect(result.contains("## README"))
        #expect(result.contains("## Code Structure"))
        #expect(result.contains("## AI Summary"))
        #expect(result.contains("## External References"))

        // 实际数据被替换了
        #expect(result.contains("Repository: foo/bar"))
        #expect(result.contains("# Hello"))

        // outputLanguage 占位符被替换
        #expect(result.contains("Output language: English"))
        #expect(!result.contains("{outputLanguage}"))
    }

    @Test("summary 非空 → 渲染到 ## AI Summary section")
    func assembleWithSummary() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "Simplified Chinese",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar",
            readme: "README body",
            codeContext: "",
            summary: "## 一句话\nThis is a test summary.",
            externalContext: "",
            previousSessionCarryOver: ""
        )

        #expect(result.contains("## 一句话"))
        #expect(result.contains("This is a test summary."))

        // 顺序断言：## AI Summary 必须出现在 ## Metadata 之后
        let metadataIdx = try? #require(result.range(of: "## Metadata")).lowerBound
        let summaryIdx = try? #require(result.range(of: "## AI Summary")).lowerBound
        if let m = metadataIdx, let s = summaryIdx {
            #expect(m < s)
        }
    }

    @Test("externalContext 非空 → 渲染到 ## External References section（末尾）")
    func assembleWithExternalContext() {
        let externalMd = "<external_context source=\"AnySearch\">\n- [doc](https://x.com)\n</external_context>"
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "English",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar",
            readme: "",
            codeContext: "",
            summary: "",
            externalContext: externalMd,
            previousSessionCarryOver: ""
        )

        #expect(result.contains("<external_context"))
        #expect(result.contains("https://x.com"))

        // 顺序断言：## External References 必须出现在 ## AI Summary 之后（v4 模板章节顺序）
        let summaryIdx = try? #require(result.range(of: "## AI Summary")).lowerBound
        let externalIdx = try? #require(result.range(of: "## External References")).lowerBound
        if let s = summaryIdx, let e = externalIdx {
            #expect(s < e)
        }
    }

    @Test("空 externalContext → section header 渲染但下面没内容")
    func assembleEmptyExternalRendersHeaderOnly() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "English",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar",
            readme: "body",
            codeContext: "",
            summary: "",
            externalContext: "",
            previousSessionCarryOver: ""
        )

        // section header 在
        #expect(result.contains("## External References"))
        // 没有任何 external_context XML 包裹
        #expect(!result.contains("<external_context"))
    }

    @Test("全要素拼接：5 个 input section 顺序为 metadata → readme → codeContext → summary → externalContext")
    func assembleFullStack() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "Simplified Chinese",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "M-DATA",
            readme: "R-DATA",
            codeContext: "C-DATA",
            summary: "S-DATA",
            externalContext: "E-DATA",
            previousSessionCarryOver: ""
        )

        let metaIdx = result.range(of: "M-DATA")?.lowerBound
        let readmeIdx = result.range(of: "R-DATA")?.lowerBound
        let codeIdx = result.range(of: "C-DATA")?.lowerBound
        let summaryIdx = result.range(of: "S-DATA")?.lowerBound
        let externalIdx = result.range(of: "E-DATA")?.lowerBound

        // 5 个 section 内容都必须出现
        #expect(metaIdx != nil)
        #expect(readmeIdx != nil)
        #expect(codeIdx != nil)
        #expect(summaryIdx != nil)
        #expect(externalIdx != nil)

        // 顺序断言：metadata < readme < codeContext < summary < externalContext
        if let m = metaIdx, let r = readmeIdx, let c = codeIdx, let s = summaryIdx, let e = externalIdx {
            #expect(m < r)
            #expect(r < c)
            #expect(c < s)
            #expect(s < e)
        }
    }

    /// HOM-70 v2：carry-over 占位符渲染 + section 顺序 + 空字符串不出现 carry-over 内容。
    @Test("previousSessionCarryOver 非空 → 渲染到 # Previous Session Carry-over section（末尾）")
    func assembleWithCarryOver() {
        let carry = """
        - 上一轮我们聊了项目的 CLI 入口；
        - 然后讨论了如何 mock URLSession 做单测。
        """
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "Simplified Chinese",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar",
            readme: "README body",
            codeContext: "",
            summary: "",
            externalContext: "",
            previousSessionCarryOver: carry
        )

        // 内容被正确替换
        #expect(result.contains("- 上一轮我们聊了项目的 CLI 入口"))
        #expect(result.contains("如何 mock URLSession"))
        // 占位符已被消耗，不应再出现字面量
        #expect(!result.contains("{previousSessionCarryOver}"))
        // section 标题在
        #expect(result.contains("# Previous Session Carry-over"))

        // 顺序断言：carry-over section 必须出现在 External References 之后（v2 模板末尾）
        let externalIdx = try? #require(result.range(of: "## External References")).lowerBound
        let carryIdx = try? #require(result.range(of: "# Previous Session Carry-over")).lowerBound
        if let e = externalIdx, let c = carryIdx {
            #expect(e < c)
        }
    }

    /// HOM-70 v2：普通 session 传空字符串 → section header 仍渲染、但不出现承接段实际内容。
    /// 这是默认行为（绝大多数 session 都不是承接来的），重要的是确认不会有"漏掉空替换
    /// 留下 {previousSessionCarryOver} 字面量泄漏给 LLM"的回归。
    @Test("空 previousSessionCarryOver → section header 渲染但下面没承接内容 + 占位符被替换")
    func assembleEmptyCarryOverRendersHeaderOnly() {
        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: AIDefaultPrompts.chat.systemPrompt,
            outputLanguage: "English",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "Repository: foo/bar",
            readme: "body",
            codeContext: "",
            summary: "",
            externalContext: "",
            previousSessionCarryOver: ""
        )

        // section header 在
        #expect(result.contains("# Previous Session Carry-over"))
        // 占位符被消耗了不再泄漏字面量
        #expect(!result.contains("{previousSessionCarryOver}"))
    }

    @Test("占位符 dict 找不到 key → 保留 {key} 字面量（让 LLM 看到便于排错）")
    func assembleUnknownPlaceholderPreserved() {
        // 用户改过 prompt 模板，引入了 dict 没有的占位符（比如 {fooBar}）
        let customTemplate = """
        Hello {outputLanguage}.
        Custom field: {fooBar}
        Metadata: {metadata}
        """

        let result = RepoAIInsightService.assembleChatSystemPrompt(
            template: customTemplate,
            outputLanguage: "English",
            runtimeContext: Self.testRuntimeContext,
            starcatResources: Self.testStarcatResources,
            metadata: "M-DATA",
            readme: "",
            codeContext: "",
            summary: "",
            externalContext: "",
            previousSessionCarryOver: ""
        )

        #expect(result.contains("Hello English."))
        #expect(result.contains("Metadata: M-DATA"))
        // 关键：{fooBar} 不在 dict 里，必须保留字面量而非被替换为空
        #expect(result.contains("{fooBar}"))
    }
}
