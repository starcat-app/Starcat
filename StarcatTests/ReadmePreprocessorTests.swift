//
//  ReadmePreprocessorTests.swift
//  StarcatTests
//
//  锁住 `ReadmePreprocessor.sanitize(markdown:)` 与 `process(markdown:)` 的行为契约
//  （2026-06-13 dong4j 拍板：`readmes.content` 落库前必须 sanitize，让向量化 / AI 摘要
//  消费方拿到纯文本，HTML 标签和 entity 都是噪声）。
//
//  关键约束（决策 A3 2026-06-13 修订版）：
//  - sanitize 必须 strip 所有 HTML 标签（含行内 `<a>` / `<details>` / 块级 `<div>` /
//    `<table>` 等），与 `process(html:)` 一刀切行为对齐；
//  - sanitize 必须解码常见 HTML entity（`&amp;` / `&lt;` / `&gt;` / `&quot;` / `&nbsp;`
//    / `&#39;` / `&apos;`）；
//  - sanitize 保留换行（`IndexedTextDiff.shouldRebuild` 依赖行级 diff），但连续 ≥3 空行
//    压成单空行（保段落界限）；
//  - sanitize **不截断**（截断是 `process` 的事），调用方按需控制长度；
//  - sanitize 必须幂等：对已 sanitize 过的字符串再调一次行为不变（标签 0 次匹配 + entity
//    已是解码态 + 空白无可压）。
//
//  覆盖场景：
//  - 纯文本（理想形态）
//  - 含行内标签（`<a>` / `<b>` / `<details>` 等）
//  - 含块级标签（`<div>` / `<table>`）
//  - 含 `<script>` / `<style>` 完整段（含内容）
//  - 含 `<img>` 与 markdown 图片语法 `![alt](url)`
//  - 含 HTML entity（`&amp;` / `&lt;` / `&gt;` / `&quot;` / `&nbsp;` / `&#39;`）
//  - 多空行压缩（≥3 连续空行 → 单空行）
//  - 行内 trim + 整体 trim
//  - 空串输入
//  - **幂等性**：sanitize(sanitize(x)) == sanitize(x)
//  - **process == truncate(sanitize)**：内部分工契约
//

import Testing
@testable import Starcat

@Suite("ReadmePreprocessor.sanitize(markdown:)")
struct ReadmePreprocessorSanitizeTests {

    // MARK: - 基础

    @Test("纯文本原样返回（trim 头尾空白）")
    func plainText() {
        let input = "  hello world  "
        #expect(ReadmePreprocessor.sanitize(markdown: input) == "hello world")
    }

    @Test("空串输入返回空串")
    func emptyInput() {
        #expect(ReadmePreprocessor.sanitize(markdown: "") == "")
    }

    // MARK: - HTML 标签 strip

    @Test("strip 行内标签：<a> / <b> / <i> 等")
    func stripInlineTags() {
        let input = "Visit <a href=\"https://example.com\">our site</a> and read <b>this</b> <i>too</i>."
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains("<a"))
        #expect(!result.contains("</a>"))
        #expect(!result.contains("<b>"))
        #expect(!result.contains("<i>"))
        #expect(result.contains("our site"))
        #expect(result.contains("this"))
        #expect(result.contains("too"))
    }

    @Test("strip 块级标签：<div> / <table> / <details>")
    func stripBlockTags() {
        let input = """
        <details>
          <summary>Click me</summary>
          <div class="x">Content here</div>
        </details>
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains("<details"))
        #expect(!result.contains("<summary"))
        #expect(!result.contains("<div"))
        #expect(result.contains("Click me"))
        #expect(result.contains("Content here"))
    }

    @Test("strip <script> 整段含内容（防脚本残骸污染向量）")
    func stripScriptWithContent() {
        let input = """
        Before
        <script>
          alert('xss');
          window.evil = true;
        </script>
        After
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains("alert"))
        #expect(!result.contains("window.evil"))
        #expect(!result.contains("<script"))
        #expect(result.contains("Before"))
        #expect(result.contains("After"))
    }

    @Test("strip <style> 整段含内容")
    func stripStyleWithContent() {
        let input = """
        Text
        <style>.foo { color: red; }</style>
        More
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains(".foo"))
        #expect(!result.contains("color: red"))
        #expect(!result.contains("<style"))
        #expect(result.contains("Text"))
        #expect(result.contains("More"))
    }

    @Test("strip <img> 与 markdown 图片语法 ![alt](url)")
    func stripImages() {
        let input = """
        Hero: ![Logo](https://example.com/logo.png)
        Also: <img src="x.png" alt="x">
        End.
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains("logo.png"))
        #expect(!result.contains("Logo"))
        #expect(!result.contains("<img"))
        #expect(!result.contains("x.png"))
        #expect(result.contains("Hero:"))
        #expect(result.contains("End."))
    }

    // MARK: - HTML entity 解码

    @Test("解码 &amp; / &quot; / &#39; / &apos; / &nbsp;（不带尖括号的 entity）")
    func decodeNonAngleEntities() {
        let input = "Cats &amp; Dogs &quot;test&quot; &#39;quoted&#39; &apos;apos&apos;&nbsp;end"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result.contains("Cats & Dogs"))
        #expect(result.contains("\"test\""))
        #expect(result.contains("'quoted'"))
        #expect(result.contains("'apos'"))
        #expect(!result.contains("&amp;"))
        #expect(!result.contains("&quot;"))
        #expect(!result.contains("&#39;"))
        #expect(!result.contains("&apos;"))
        #expect(!result.contains("&nbsp;"))
    }

    @Test("&lt; / &gt; 解码后形成 <...> 配对会被 strip 一刀切（语义符合 dong4j 初衷）")
    func decodeAngleEntitiesBehavior() {
        // 用户写 `&lt;br&gt;` 表达"字面量 <br> 标签名"时，解码 → strip → 标签名被删,
        // 这恰好是 dong4j 的初衷：HTML 标签字面量也是噪声，机器消费场景下应剥离。
        let input = "Use &lt;br&gt; for line break"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(!result.contains("<br>"))
        #expect(!result.contains("&lt;"))
        #expect(!result.contains("&gt;"))
        #expect(result.contains("Use"))
        #expect(result.contains("for line break"))
    }

    @Test("单独 < 不配对时，解码后保留（strip 正则 `<[^>]+>` 不匹配单 <）")
    func decodeStandaloneLt() {
        // 单独 `&lt;` 解码为 `<` 且后面没有配对 `>` 时，strip 不会删 —— 关键约束:
        // 这种"对人类有意义的不等式"（如 `value < threshold`）保留语义。
        // 注：必须确保整段 input 里 `<` 之后没有任何 `>`，否则会跨行匹配吞掉。
        let input = "Value &lt; threshold means okay"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result.contains("Value < threshold means okay"))
    }

    @Test("&nbsp; 解码为普通空格（与 process(html:) 行为对齐）")
    func decodeNbsp() {
        // 实现细节：`decodeHTMLEntities` 把 `&nbsp;` → 普通 ASCII 空格，不是 U+00A0
        // 不间断空格。理由：sanitize 的消费者是机器（向量化 / AI 摘要），普通空格和
        // 不间断空格在分词上等价，归一为普通空格更利于 IndexedTextDiff 行级比对的稳定性。
        let input = "foo&nbsp;bar"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result.contains("foo bar"))
        #expect(!result.contains("&nbsp;"))
    }

    // MARK: - 空白与段落

    @Test("≥3 连续空行压缩为单空行（保段落界限）")
    func compressMultipleBlankLines() {
        let input = """
        Para 1



        Para 2




        Para 3
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        // 期望：Para 1, "", Para 2, "", Para 3（4 个空行 → 1 个，5 个空行 → 1 个）
        #expect(lines == ["Para 1", "", "Para 2", "", "Para 3"])
    }

    @Test("单空行作段落分隔保留")
    func keepSingleBlankLine() {
        let input = "Line 1\n\nLine 2"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result == "Line 1\n\nLine 2")
    }

    @Test("每行首尾空白被 trim")
    func trimEachLine() {
        let input = "  Line 1  \n  Line 2  "
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result == "Line 1\nLine 2")
    }

    @Test("整体首尾空行 / 空白被 trim")
    func trimOverall() {
        let input = "\n\n\nContent\n\n\n"
        let result = ReadmePreprocessor.sanitize(markdown: input)
        #expect(result == "Content")
    }

    // MARK: - 幂等性（关键契约）

    @Test("sanitize 是幂等的：sanitize(sanitize(x)) == sanitize(x)")
    func idempotent() {
        let input = """
        # Hello <b>World</b>

        Visit <a href="https://example.com">link</a> &amp; check &lt;tag&gt; out.

        ![image](url.png)

        <details>
        <summary>More</summary>
        Body text here.
        </details>
        """
        let once = ReadmePreprocessor.sanitize(markdown: input)
        let twice = ReadmePreprocessor.sanitize(markdown: once)
        #expect(once == twice)
    }

    // MARK: - markdown 链接保留（不删 [text](url)）

    @Test("markdown 链接语法保留：[text](url) 不删")
    func preserveMarkdownLinks() {
        let input = "See [docs](https://example.com/docs) for details."
        let result = ReadmePreprocessor.sanitize(markdown: input)
        // 链接 text 和 url 都是有语义的，保留
        #expect(result.contains("[docs](https://example.com/docs)"))
    }

    // MARK: - 综合场景

    @Test("综合场景：复杂 README 节选")
    func realWorldExample() {
        let input = """
        # MyProject

        <p align="center">
          <img src="logo.png" alt="MyProject Logo">
          <a href="https://shields.io/badge/build-passing-green"><img src="badge.svg" alt="Build"></a>
        </p>

        > A library for handling **Cats &amp; Dogs**.

        ## Features

        - Fast response time
        - <details><summary>Click for more</summary>Detailed list here.</details>


        ## Installation

        ```bash
        npm install myproject
        ```

        See [docs](https://example.com).
        """
        let result = ReadmePreprocessor.sanitize(markdown: input)
        // HTML 标签 / entity 全清
        #expect(!result.contains("<p"))
        #expect(!result.contains("<img"))
        #expect(!result.contains("<a "))
        #expect(!result.contains("<details"))
        #expect(!result.contains("<summary"))
        #expect(!result.contains("&amp;"))
        #expect(!result.contains("&lt;"))
        // 文本内容保留
        #expect(result.contains("MyProject"))
        #expect(result.contains("Cats & Dogs"))
        #expect(result.contains("Fast response time"))
        #expect(result.contains("Click for more"))
        #expect(result.contains("Detailed list here"))
        #expect(result.contains("npm install myproject"))
        // markdown 链接保留
        #expect(result.contains("[docs](https://example.com)"))
    }
}

@Suite("ReadmePreprocessor.process(markdown:) = truncate ∘ sanitize")
struct ReadmePreprocessorProcessTests {

    @Test("process == truncate(sanitize(...)) 契约")
    func processEqualsTruncateSanitize() {
        let input = "Hello <b>World</b> &amp; Universe."
        let sanitized = ReadmePreprocessor.sanitize(markdown: input)
        let processed = ReadmePreprocessor.process(markdown: input, maxLength: 1000)
        #expect(processed == sanitized)  // sanitized 不超长，truncate 不生效 → 相等
    }

    @Test("process 按 maxLength 截断")
    func processTruncates() {
        let input = String(repeating: "a", count: 100)
        let result = ReadmePreprocessor.process(markdown: input, maxLength: 50)
        #expect(result.count == 50)
    }

    @Test("process 对已 sanitize 过的字符串再调一次幂等")
    func processIdempotentOnSanitized() {
        let raw = "Hello <b>World</b> &amp; Universe."
        let sanitized = ReadmePreprocessor.sanitize(markdown: raw)
        let processedTwice = ReadmePreprocessor.process(markdown: sanitized, maxLength: 1000)
        #expect(processedTwice == sanitized)
    }
}
