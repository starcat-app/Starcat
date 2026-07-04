//
//  ReadmeWebViewTests.swift
//  StarcatTests
//
//  HOM-146 配套单测：README WebView 相对链接解析修复。
//  HOM-201 P1-2（2026-06-14）：`<img>` 相对路径重写已从 `ReadmeWebView` 迁出到
//  独立工具 `ReadmeAssetURLRewriter`，相关测试也同步搬移；本文件仅保留与
//  `ReadmeWebView` 直接绑定的 baseURL 测试。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("ReadmeWebView")
struct ReadmeWebViewTests {

    // MARK: - repositoryContentBaseURL

    @Test("README 相对链接保留 blob/HEAD 分支段")
    func repositoryContentBaseURL_resolvesRelativeLinkUnderHead() throws {
        let repositoryURL = try #require(URL(string: "https://github.com/alice/foo"))
        let baseURL = ReadmeWebView.repositoryContentBaseURL(from: repositoryURL)

        #expect(baseURL.absoluteString == "https://github.com/alice/foo/blob/HEAD/")
        #expect(URL(string: "docs/guide.md", relativeTo: baseURL)?.absoluteURL.absoluteString
            == "https://github.com/alice/foo/blob/HEAD/docs/guide.md")
    }

    @Test("README 文档包含图片预览样式且继续禁止页面脚本")
    func assembleDocument_includesImagePreviewStylesAndKeepsPageScriptBlocked() {
        let html = ReadmeWebView.assembleDocument(
            fragment: #"<p><img src="https://example.com/logo.png" alt="Logo"></p>"#,
            isDark: false
        )

        // 图片交互靠 app-owned WKUserScript 注入；README 页面自己的脚本仍由 CSP 禁止。
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains(".readme-image-preview"))
        #expect(html.contains("body.readme-js-ready .markdown-body img:not(.readme-image-loaded)"))
    }

    @Test("README 正文字号接入界面倍率")
    func assembleDocument_injectsReadableFontSizeFromInterfaceScale() {
        let standardHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false
        )
        let largeHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false,
            interfaceScale: .large
        )
        let adjustedHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false,
            readmeFontSizeAdjustment: 2
        )

        #expect(standardHTML.contains("--readme-body-font-size: 16.00px;"))
        #expect(largeHTML.contains("--readme-body-font-size: 18.56px;"))
        #expect(adjustedHTML.contains("--readme-body-font-size: 18.00px;"))
        #expect(standardHTML.contains("font-size: var(--readme-body-font-size, 16px);"))
        #expect(standardHTML.contains("line-height: var(--readme-line-height, 1.62);"))
    }
}
