//
//  MarkdownHeadingDemoterTests.swift
//  StarcatTests
//
//  锁住 `MarkdownHeadingDemoter.demoteToH3(_:)` 的行为契约
//  （HOM-150 dong4j 2026-06-04 16:05 反馈："不是简单的降级, 是要先判断"）。
//
//  覆盖核心规则：
//  - 没标题 / 已是 H3+：原样返回
//  - H1 起步：整体平移 +2，所有标题 H{n} → H{n+2}，上限 H6
//  - H2 起步：整体平移 +1
//  - fenced code block 内的 `#` 行不被误判为标题
//  - `#tag` / `#!shebang` 这类 # 后无空白不算 ATX 标题
//  - 行首允许 0~3 空白，4 空白进入代码块缩进区
//  - 7 个 `#` 起步不是 ATX
//

import Testing
@testable import Starcat

@Suite("MarkdownHeadingDemoter.demoteToH3")
struct MarkdownHeadingDemoterTests {

    // MARK: - 不需要降级

    @Test("空字符串原样返回")
    func emptyString() {
        #expect(MarkdownHeadingDemoter.demoteToH3("") == "")
    }

    @Test("无标题原样返回")
    func noHeadings() {
        let input = "just some text\nwith **bold** and `code`\nbut no headings"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("最高级别已是 H3 不动")
    func minLevelIsH3() {
        let input = "### Section\n\nbody\n\n#### Sub\n\nmore body"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("最高级别 H4 / H5 / H6 全不动")
    func minLevelIsDeeper() {
        let input = "#### Deep\n##### Deeper\n###### Deepest"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    // MARK: - H1 起步 → 整体 +2

    @Test("H1 起步：H1→H3, H2→H4, H3→H5")
    func startsAtH1() {
        let input = "# Title\n\n## Section\n\n### Sub"
        let expected = "### Title\n\n#### Section\n\n##### Sub"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    @Test("H1 起步：H5/H6 平移后封顶 H6")
    func startsAtH1ClampsToH6() {
        let input = "# T\n##### Deep\n###### Deepest"
        let expected = "### T\n###### Deep\n###### Deepest"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    // MARK: - H2 起步 → 整体 +1

    @Test("H2 起步：H2→H3, H3→H4, H4→H5")
    func startsAtH2() {
        let input = "## A\n\n### B\n\n#### C"
        let expected = "### A\n\n#### B\n\n##### C"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    @Test("H2 起步：H6 封顶 H6 不变")
    func startsAtH2ClampsToH6() {
        let input = "## A\n###### Z"
        let expected = "### A\n###### Z"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    // MARK: - fenced code block 不参与

    @Test("代码块内 # 不算标题，外面 H1 仍触发降级")
    func skipsFencedCodeBlock() {
        let input = """
        # Real Title

        ```bash
        # this is a shell comment, not a heading
        ## also not a heading
        ```

        body
        """
        let expected = """
        ### Real Title

        ```bash
        # this is a shell comment, not a heading
        ## also not a heading
        ```

        body
        """
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    @Test("Pass1 不把代码块里的 # 误当最高级")
    func codeBlockHashIgnoredForMinScan() {
        // 代码块外只有 H3，外面看就是"最高 H3"，不该降级
        let input = """
        ### Outer Heading

        ```python
        # comment in code
        ```

        body
        """
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("~~~ 围栏同 ``` 一样跳过")
    func tildeFenceWorks() {
        let input = """
        ## Real

        ~~~ruby
        # comment
        ~~~
        """
        let expected = """
        ### Real

        ~~~ruby
        # comment
        ~~~
        """
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    // MARK: - 边界：什么不算 ATX 标题

    @Test("# 后无空白不算标题（#tag / #!shebang）")
    func hashWithoutSpaceIsNotHeading() {
        let input = "#tag should-stay\n#!/usr/bin/env zsh"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("7+ 个 # 不算 ATX，原样保留")
    func sevenHashesNotAtx() {
        let input = "####### Not a heading"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("4 个前导空白属代码块缩进，不算 ATX")
    func fourSpaceIndentIsCodeBlock() {
        let input = "    # indented as code"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == input)
    }

    @Test("1~3 个前导空白的 ATX 仍参与降级")
    func leadingSpacesUpToThreeAllowed() {
        let input = "  ## Two-Space-Indent"
        let expected = "  ### Two-Space-Indent"
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }

    // MARK: - 综合场景

    @Test("典型 AI 回复：H2 概述 + H3 子节，整体降一级")
    func realisticAIResponse() {
        let input = """
        ## 总览

        这个项目是 ...

        ### 安装

        ```bash
        # install
        brew install foo
        ```

        ### 用法

        基本用法见下。

        #### 高级

        ...
        """
        let expected = """
        ### 总览

        这个项目是 ...

        #### 安装

        ```bash
        # install
        brew install foo
        ```

        #### 用法

        基本用法见下。

        ##### 高级

        ...
        """
        #expect(MarkdownHeadingDemoter.demoteToH3(input) == expected)
    }
}
