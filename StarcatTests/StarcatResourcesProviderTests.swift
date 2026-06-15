//
//  StarcatResourcesProviderTests.swift
//  StarcatTests
//
//  覆盖 StarcatResourcesProvider markdown 渲染（2026-06-15 v4.y）：
//    - 全空（无 wiki + 无 codeflow）→ 空字符串
//    - 只有 wiki / 只有 codeflow / 两者都有 → 对应 section + 使用指引
//    - wiki 源用硬编码英文名而非 `displayName`（避免 i18n 翻译进入 prompt）
//    - file:// codeflow URL 原样输出
//    - 未知源（unknown(raw)）输出 raw value
//

import Foundation
import Testing
@testable import Starcat

@Suite("StarcatResourcesProvider")
struct StarcatResourcesProviderTests {

    private func makeLink(source: WikiSource, url: String) -> WikiLink {
        WikiLink(source: source, url: URL(string: url)!)
    }

    @Test("全空时返回空字符串（让 chat template 空 section 自然被 LLM 忽略）")
    func testEmptyReturnsEmptyString() {
        let result = StarcatResourcesProvider.snapshot(wikiLinks: [], codeFlowPageURL: nil)
        #expect(result.isEmpty)
    }

    @Test("只有 wiki：列出链接 + 使用指引；不出现 CodeFlow 行")
    func testWikiOnly() {
        let links = [
            makeLink(source: .deepWiki, url: "https://deepwiki.com/facebook/react"),
            makeLink(source: .zread, url: "https://zread.com/facebook/react")
        ]
        let result = StarcatResourcesProvider.snapshot(wikiLinks: links, codeFlowPageURL: nil)

        #expect(result.contains("External wiki indexes"))
        #expect(result.contains("- DeepWiki: https://deepwiki.com/facebook/react"))
        #expect(result.contains("- ZRead: https://zread.com/facebook/react"))
        #expect(!result.contains("CodeFlow"))
        #expect(result.contains("recommend the relevant link"), "应包含使用指引")
    }

    @Test("只有 codeflow：file:// 链接 + 指引；不出现 wiki 行")
    func testCodeFlowOnly() {
        let pageURL = URL(string: "file:///Users/foo/codeflow/owner/repo/index.html")!
        let result = StarcatResourcesProvider.snapshot(wikiLinks: [], codeFlowPageURL: pageURL)

        #expect(result.contains("Local CodeFlow visualization"))
        #expect(result.contains("- file:///Users/foo/codeflow/owner/repo/index.html"))
        #expect(!result.contains("External wiki indexes"))
        #expect(result.contains("recommend the relevant link"))
    }

    @Test("两者都有：wiki 段在前 + CodeFlow 段在后 + 末尾指引")
    func testBothWikiAndCodeFlow() {
        let links = [makeLink(source: .codeWiki, url: "https://codewiki.com/a/b")]
        let pageURL = URL(string: "file:///tmp/codeflow/a/b/index.html")!
        let result = StarcatResourcesProvider.snapshot(wikiLinks: links, codeFlowPageURL: pageURL)

        let wikiIdx = result.range(of: "External wiki indexes")?.lowerBound
        let cfIdx = result.range(of: "Local CodeFlow")?.lowerBound
        let guideIdx = result.range(of: "recommend the relevant link")?.lowerBound
        #expect(wikiIdx != nil)
        #expect(cfIdx != nil)
        #expect(guideIdx != nil)
        if let wikiIdx, let cfIdx, let guideIdx {
            #expect(wikiIdx < cfIdx, "wiki 段在前")
            #expect(cfIdx < guideIdx, "使用指引在最后")
        }
        #expect(result.contains("- CodeWiki: https://codewiki.com/a/b"))
        #expect(result.contains("- file:///tmp/codeflow/a/b/index.html"))
    }

    @Test("wiki 源名是硬编码英文(不是 displayName i18n 翻译值)")
    func testEnglishHardcodedNames() {
        let links = [
            makeLink(source: .deepWiki, url: "https://x/1"),
            makeLink(source: .zread, url: "https://x/2"),
            makeLink(source: .codeWiki, url: "https://x/3")
        ]
        let result = StarcatResourcesProvider.snapshot(wikiLinks: links, codeFlowPageURL: nil)

        #expect(result.contains("- DeepWiki:"))
        #expect(result.contains("- ZRead:"))
        #expect(result.contains("- CodeWiki:"))
    }

    @Test("未知源（unknown(raw)）输出 raw value 不崩")
    func testUnknownSource() {
        let links = [makeLink(source: .unknown("brand-x"), url: "https://brand-x.com/a/b")]
        let result = StarcatResourcesProvider.snapshot(wikiLinks: links, codeFlowPageURL: nil)

        #expect(result.contains("- brand-x: https://brand-x.com/a/b"))
    }
}
