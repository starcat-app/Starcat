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
}
