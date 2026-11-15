//
//  RepoWorkspaceTests.swift
//  StarcatTests
//
//  验证共享屏幕预算、阅读布局、Markdown 元数据预览与笔记查询的交错顺序。
//  不打开窗口，真实外观仍需人工验收。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("RepoWorkspace")
struct RepoWorkspaceTests {
    @Test("三窗共用预算，较小屏幕不会被最小尺寸撑出可见区")
    func windowBudgets() {
        #expect(RepoWorkspaceWindowController.contentSize(available: NSSize(width: 1440, height: 900))
                == NSSize(width: 1180, height: 720))
        #expect(RepoWorkspaceWindowController.contentSize(available: NSSize(width: 1024, height: 680))
                == NSSize(width: 960, height: 600))
        #expect(RepoWorkspaceWindowController.contentSize(available: NSSize(width: 700, height: 500))
                == NSSize(width: 636, height: 420))
    }

    @Test("放大和 Escape 保留信息栏偏好，窄宽度使用覆盖式信息栏")
    func readingLayoutRestoration() {
        var layout = RepoFileReadingLayout()
        #expect(!layout.showsInspector)
        layout.showsInspector = true
        layout.isExpanded = true
        let exitedReading = layout.handleEscape()
        #expect(exitedReading)
        #expect(!layout.isExpanded && layout.showsInspector)
        #expect(layout.usesInspectorOverlay(availableWidth: 960))
        #expect(!layout.usesInspectorOverlay(availableWidth: 1180))
        let hidInspector = layout.handleEscape()
        #expect(hidInspector)
        #expect(!layout.showsInspector)
        let needsWindowDismissal = !layout.handleEscape()
        #expect(needsWindowDismissal)
    }

    @Test("只将 Markdown 文本交给渲染器")
    func markdownTypes() {
        #expect(RepoFileMarkdownRenderer.supports(fileName: "docs/README.MD"))
        #expect(RepoFileMarkdownRenderer.supports(fileName: "guide.markdown"))
        #expect(!RepoFileMarkdownRenderer.supports(fileName: "guide.md.png"))
        #expect(!RepoFileMarkdownRenderer.supports(fileName: "README"))
        #expect(!RepoFileMarkdownRenderer.supports(fileName: "main.swift"))
    }

    @Test("Skill 元数据按键值展示，折叠描述不会变成标题，正文资源仍绑定提交")
    func markdownFrontMatter() async throws {
        let document = try await renderMarkdown("""
        ---
        name: "config"
        description: >
          Show or change TokenEconomizer's settings:
          turn micro-skills on or off.
        ---
        # Configuration

        ![Logo](../logo.png)

        ---

        Body after separator.
        """)
        #expect(document.html.contains("class=\"starcat-front-matter\""))
        #expect(document.html.contains(">name</th>"))
        #expect(document.html.contains(">config</td>"))
        #expect(document.html.contains("Show or change TokenEconomizer&#39;s settings: turn micro-skills on or off."))
        #expect(document.html.contains("<h1>Configuration</h1>"))
        #expect(!document.html.contains("<h2>name:"))
        #expect(document.html.contains("Body after separator."))
        #expect(document.html.contains("https://raw.githubusercontent.com/owner/repo/tree-commit/logo.png"))
        #expect(document.id == "owner/repo:tree-commit:docs/SKILL.md:blob")
        #expect(document.baseURL?.absoluteString == "https://github.com/owner/repo/blob/tree-commit/docs/SKILL.md")
    }

    @Test("字面量描述保留换行，嵌套元数据和列表保留原有结构")
    func markdownStructuredMetadata() async throws {
        let document = try await renderMarkdown("""
        ---
        description: |-
          First line.
          Second line.
        metadata:
          author: dong4j
          tags:
            - swift
            - markdown
        ---
        Body.
        """)
        #expect(document.html.contains("First line.\nSecond line."))
        #expect(document.html.contains("author: dong4j\ntags:\n  - swift\n  - markdown"))
        #expect(document.html.contains("<p>Body.</p>"))
    }

    @Test("折叠描述保留段落和额外缩进，不连成一整段")
    func markdownFoldedMetadataParagraphs() async throws {
        let document = try await renderMarkdown("""
        ---
        description: >-
          First line.
          Continued.

          Next paragraph.
            Indented example.
        ---
        """)
        #expect(document.html.contains("First line. Continued.\n\nNext paragraph.\n  Indented example."))
    }

    @Test("支持 BOM、CRLF 和 YAML 文档结束标记")
    func markdownFrontMatterLineEndings() async throws {
        let document = try await renderMarkdown("\u{feff}---\r\nname: config\r\n...\r\n# Body\r\n")
        #expect(document.html.contains(">config</td>"))
        #expect(document.html.contains("<h1>Body</h1>"))
        #expect(!document.html.contains("\u{feff}"))
    }

    @Test("常见引号字符串解码，元数据中的 HTML 和 Markdown 保持文本")
    func markdownMetadataEscaping() async throws {
        let document = try await renderMarkdown("""
        ---
        name: 'config''s'
        description: "Use \\"config\\""
        example: '<img src="https://example.com/metadata.png"> & **plain**'
        ---
        Body.
        """)
        #expect(document.html.contains("config&#39;s"))
        #expect(document.html.contains("Use &quot;config&quot;"))
        #expect(document.html.contains("&lt;img src=&quot;https://example.com/metadata.png&quot;&gt; &amp; **plain**"))
        #expect(!document.html.contains("<img"))
        #expect(!document.html.contains("<strong>plain</strong>"))
    }

    @Test("未闭合和非开头的元数据不剥离，普通 Markdown 分隔线不误判",
          arguments: [
            "---\nname: config\n\n# Body",
            "# Body\n\n---\nname: config\n---",
            "---\nA normal paragraph.\n---"
          ])
    func markdownPreservesOrdinaryContent(text: String) async throws {
        let document = try await renderMarkdown(text)
        #expect(!document.html.contains("class=\"starcat-front-matter\""))
        #expect(document.html.contains(text.contains("name: config") ? "name: config" : "A normal paragraph."))
    }

    @Test("超出键值展示子集的元数据回退为文本，不丢失字段")
    func markdownUnsupportedMetadata() async throws {
        let document = try await renderMarkdown("---\nname: config\n? [complex, key]\n: value\n---\n# Body")
        #expect(document.html.contains("<code class=\"language-yaml\">"))
        #expect(document.html.contains("name: config\n? [complex, key]\n: value"))
        #expect(document.html.contains("<h1>Body</h1>"))
    }

    /// 直接验证最终 HTML 管线，无需加载 WebView 或联网，避免把解析测试变成界面测试。
    private func renderMarkdown(_ text: String) async throws -> RepoFileMarkdownDocument {
        try await RepoFileMarkdownRenderer().prepare(
            text: text,
            target: RepoFileBrowserTarget(owner: "owner", name: "repo", fullName: "owner/repo", ref: "main"),
            commit: "tree-commit", path: "docs/SKILL.md", blobSHA: "blob"
        )
    }

    @Test("页内锚点保留在当前文档，其他文件仍然外跳")
    func sameDocumentAnchors() throws {
        let current = try #require(URL(string: "https://github.com/o/r/blob/commit/docs/guide.md"))
        let anchor = try #require(URL(string: current.absoluteString + "#section"))
        #expect(ReadmeWebView.isSameDocumentAnchor(anchor, currentURL: current))
        #expect(!ReadmeWebView.isSameDocumentAnchor(
            try #require(URL(string: "https://github.com/o/r/blob/commit/docs/other.md#section")), currentURL: current
        ))
        #expect(!ReadmeWebView.isSameDocumentAnchor(current, currentURL: current))
    }

    @Test("批量结果与增删通知合并，不复活已清空的笔记")
    func noteChangesDuringQuery() async throws {
        let availability = RepoListNoteAvailability()
        let gate = NoteQueryGate()
        let query = Task { await availability.reload(using: gate.fetch) }
        while gate.continuation == nil { await Task.yield() }
        availability.apply(repoID: 1, content: "\n\t\u{3000}")
        availability.apply(repoID: 2, content: "saved")
        gate.continuation?.resume(returning: [1, 3])
        await query.value
        #expect(availability.repoIDs == [2, 3])
        await availability.reload { [3] }
        #expect(availability.repoIDs == [3])
    }

    @Test("切库后旧账号晚到结果不能回填")
    func rejectsPreviousAccountQuery() async {
        let availability = RepoListNoteAvailability()
        let gate = NoteQueryGate()
        let query = Task { await availability.reload(using: gate.fetch) }
        while gate.continuation == nil { await Task.yield() }
        availability.resetForDatabaseChange()
        availability.apply(repoID: 9, content: "new account")
        gate.continuation?.resume(returning: [1, 2])
        await query.value
        #expect(availability.repoIDs == [9])
    }
}

/// 用显式 continuation 控制异步返回，不依赖固定 sleep 猜测数据库执行顺序。
@MainActor
private final class NoteQueryGate {
    var continuation: CheckedContinuation<Set<Int64>, Never>?

    func fetch() async -> Set<Int64> {
        await withCheckedContinuation { continuation = $0 }
    }
}
