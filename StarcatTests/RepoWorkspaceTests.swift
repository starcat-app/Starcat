//
//  RepoWorkspaceTests.swift
//  StarcatTests
//
//  验证共享屏幕预算、阅读布局恢复和笔记查询与保存通知的交错顺序。
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
