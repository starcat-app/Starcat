//
//  DailyRadarMarkdownRendererTests.swift
//  StarcatTests
//
//  日报截图问题的离线回归：短指标列、HTML 折叠标题和上游错误嵌套链接。
//  验证白名单重建的 HTML，不加载远程内容或操作实际应用窗口。
//

import Foundation
import Testing
@testable import Starcat

/// 只扩展日报需要的展示语义，避免修复格式时把来源 HTML 的执行能力一起放开。
struct DailyRadarMarkdownRendererTests {
    /// 仅验证可选委托方法的 Objective-C 注册，不创建 WebView 或读取应用窗口。
    @Test @MainActor func linkPolicyCallbackIsRegisteredWithWebKit() {
        let view = DailyRadarMarkdownView(
            markdown: "", identity: "link-policy", onLink: { _ in }, height: .constant(1)
        )
        #expect(view.makeCoordinator().responds(
            to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        ))
    }

    @Test func screenshotTableHeadersUseMetadataLayout() {
        let headers = [
            "Product | Votes | Comments | Summary",
            "Story | Score | Comments | Summary",
            "Title | Score | Comments | Summary",
            "产品 | 票数 | 评论 | 摘要"
        ]
        for header in headers {
            let markdown = """
            | \(header) |
            |---|---|---|---|
            | Example | 548 | 302 | A long summary |
            """
            let html = DailyRadarMarkdownRenderer.render(markdown)
            #expect(html.contains("<table class=\"metadata\">"))
            #expect(html.contains("<td class=\"numeric\">548</td>"))
            #expect(html.contains("<td class=\"numeric\">302</td>"))
        }
    }

    @Test func genericTablesAlsoProtectNumericValues() {
        let html = DailyRadarMarkdownRenderer.render("""
        | Name | Value |
        |---|---|
        | Count | 3,599 |
        | Range | 10–20 |
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<td class=\"numeric\">3,599</td>"))
        #expect(html.contains("<td>10–20</td>"))
    }

    @Test func summaryRendersBoldAndSafeLinksInsteadOfHTMLSource() {
        let html = DailyRadarMarkdownRenderer.render("""
        <details>
        <summary><strong>Hermes Agent</strong> — <a href="https://github.com/NousResearch/Hermes-Agent">NousResearch/Hermes-Agent</a></summary>

        **Report**

        </details>
        """)
        #expect(html.contains("<summary><strong>Hermes Agent</strong>"))
        #expect(html.contains("<a href=\"https://github.com/NousResearch/Hermes-Agent\">"))
        #expect(!html.contains("&lt;strong"))
        #expect(!html.contains("&lt;a href"))
        #expect(html.contains("<p><strong>Report</strong></p>"))
        #expect(html.contains("</details>"))
    }

    @Test func summaryAttributesAreRebuiltRatherThanCopied() {
        let html = DailyRadarMarkdownRenderer.render("""
        <details open ontoggle="alert(1)">
        <summary onclick="alert(2)"><strong style="color:red">Safe</strong> <a href='https://example.com/Case?q=1&amp;page=2' onmouseover='alert(3)' target='_blank'>Link</a></summary>
        </details>
        """)
        #expect(html.contains("<details open>"))
        #expect(html.contains("<summary><strong>Safe</strong>"))
        #expect(html.contains("<a href=\"https://example.com/Case?q=1&amp;page=2\">"))
        #expect(!html.contains("ontoggle"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("onmouseover"))
        #expect(!html.contains("target="))
        #expect(!html.contains("style="))
    }

    @Test func unsafeAndDisguisedHTMLDestinationsNeverBecomeLinks() {
        for destination in ["javascript:alert(1)", "java&#115;cript:alert(1)", "data:text/html,test",
                            "file:///etc/passwd", "https://user:pass@example.com/"] {
            let html = DailyRadarMarkdownRenderer.render("""
            <summary><a href="\(destination)">Unsafe</a></summary>
            """)
            #expect(!html.contains("<a href="))
            #expect(html.contains("Unsafe"))
        }
        let disguised = DailyRadarMarkdownRenderer.render("""
        <summary><a title="href='https://unrelated.example/'" href="javascript:alert(1)">Unsafe</a></summary>
        """)
        #expect(!disguised.contains("<a href="))
    }

    @Test func unknownHTMLAndEscapedEntitiesStayInert() {
        let html = DailyRadarMarkdownRenderer.render("""
        <summary><strong>&lt;script&gt; &amp; Safe</strong><svg onload="alert(1)"></svg></summary>

        <script>alert(1)</script>
        """)
        #expect(html.contains("<strong>&lt;script&gt; &amp; Safe</strong>"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<svg"))
        #expect(html.contains("&lt;svg"))
    }

    @Test func quotedAttributesCannotSmuggleExtraLinks() {
        let html = DailyRadarMarkdownRenderer.render("""
        <summary><a title="> <a href='https://unrelated.example/'>" href="javascript:alert(1)">Unsafe</a></summary>
        """)
        #expect(html.contains("<summary><a>Unsafe</a></summary>"))
        #expect(!html.contains("<a href="))

        let duplicate = DailyRadarMarkdownRenderer.render("""
        <summary><a href="https://example.com/first" href="https://example.com/second">Duplicate</a></summary>
        """)
        #expect(duplicate.contains("<summary><a>Duplicate</a></summary>"))
        #expect(!duplicate.contains("<a href="))
    }

    @Test func inlineHTMLUsesTheSameSafeFormattingRules() {
        let html = DailyRadarMarkdownRenderer.render("""
        A <strong onclick="alert(1)">bold</strong> and <a href="https://example.com/">linked</a> report.
        """)
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<a href=\"https://example.com/\">linked</a>"))
        #expect(!html.contains("onclick"))
    }

    @Test func malformedDiscussionLinkIsRecoveredOnlyInsideTableCells() {
        let source = "[Qwenputer: CPU](https://divgarg.com/blog/qwenputer · [discuss](https://lobste.rs/s/example))"
        let html = DailyRadarMarkdownRenderer.render("""
        | Story | Score | Comments | Summary |
        |---|---|---|---|
        | \(source) | 44 | 9 | Description |
        """)
        #expect(html.contains("<a href=\"https://divgarg.com/blog/qwenputer\">Qwenputer: CPU</a>"))
        #expect(html.contains(" · <a href=\"https://lobste.rs/s/example\">discuss</a>"))
        #expect(!html.contains("[Qwenputer"))
        let literal = DailyRadarMarkdownRenderer.render("`\(source)`\n\n\(source)")
        #expect(literal.contains("<code>\(source)</code>"))
        // 普通段落保留解析器的结果；不能为修日报表格而全局替换来源文本。
        #expect(!literal.contains("<a href=\"https://divgarg.com/blog/qwenputer\">"))
    }

    @Test func normalLinksAndParenthesesAreUnchanged() {
        let html = DailyRadarMarkdownRenderer.render("""
        | Story | Score | Comments | Summary |
        |---|---|---|---|
        | [A title](https://example.com/a_(b)) · [discuss](https://example.com/thread) | 44 | 9 | Description |
        """)
        #expect(html.contains("<a href=\"https://example.com/a_(b)\">A title</a>"))
        #expect(html.contains("<a href=\"https://example.com/thread\">discuss</a>"))
    }
}
