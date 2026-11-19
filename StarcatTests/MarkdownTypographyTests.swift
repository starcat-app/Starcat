//
//  MarkdownTypographyTests.swift
//  StarcatTests
//
//  锁住跨渲染器的阅读偏好契约：四档只缩放一次，历史偏移越界时统一钳制。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@Suite("Markdown 阅读字号")
@MainActor
struct MarkdownTypographyTests {
    @Test("输入字号变化同步正文与后续键入字体，保留草稿和选择", arguments: InterfaceScale.allCases)
    func editorFontPreservesDraft(scale: InterfaceScale) {
        let editor = NSTextView()
        editor.isRichText = false
        editor.string = "中文 draft"
        editor.font = .systemFont(ofSize: 13)
        let selection = NSRange(location: 1, length: 2)
        editor.setSelectedRange(selection)
        let font = MarkdownTypography.nativeFont(scale: scale, adjustment: 2)

        #expect(MarkdownTypography.applyEditorFont(font, to: editor))
        #expect(editor.string == "中文 draft")
        #expect(editor.selectedRange() == selection)
        #expect(abs((editor.font?.pointSize ?? 0) - 18 * scale.multiplier) < 0.01)
        #expect((editor.typingAttributes[.font] as? NSFont)?.pointSize == font.pointSize)
        #expect((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == font.pointSize)
        #expect(!MarkdownTypography.applyEditorFont(font, to: editor))
    }

    @Test("四档倍率与阅读偏移共用同一公式", arguments: InterfaceScale.allCases)
    func readingSize(scale: InterfaceScale) {
        #expect(MarkdownTypography.bodyFontSize(scale: scale) == 16 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: 2) == 18 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: -99) == 14 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: 99) == 20 * scale.multiplier)
    }

    @Test("HTML 与原生标题和代码使用同一层级")
    func hierarchy() {
        #expect(MarkdownTypography.Heading.allCases.map(\.ratio) == [1.8, 1.45, 1.2, 1, 0.9, 0.85])
        #expect(MarkdownTypography.inlineCodeRatio == 0.85)
        #expect(MarkdownTypography.codeBlockRatio == 1)
    }

    @Test("本机 Skill 的共享阅读器继续禁止自动资源及命令链接")
    func localSkillResourcePolicy() throws {
        let html = ReadmeWebView.assembleDocument(
            fragment: "<img src='https://example.com/image.png'><iframe src='file:///tmp/a'></iframe>",
            isDark: false, resourcePolicy: .localTextOnly
        )
        #expect(html.contains("default-src 'none'; style-src 'unsafe-inline'; img-src 'none';"))
        #expect(html.contains("frame-src 'none';"))
        for value in ["file:///tmp/a", "data:text/html,a", "shortcuts://run-shortcut?name=a", "javascript:alert(1)"] {
            #expect(!ReadmeResourcePolicy.localTextOnly.allowsUserLink(try #require(URL(string: value))))
        }
        #expect(ReadmeResourcePolicy.localTextOnly.allowsUserLink(try #require(URL(string: "https://github.com/a/b"))))
        #expect(ReadmeResourcePolicy.localTextOnly.allowsUserLink(try #require(URL(string: "http://example.com"))))
        #expect(!html.contains("media-src https:;"))
    }
}
