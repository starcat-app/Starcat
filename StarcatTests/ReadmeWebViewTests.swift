//
//  ReadmeWebViewTests.swift
//  StarcatTests
//
//  HOM-146 配套单测：README WebView 相对链接解析修复。
//
//  测试内容：
//  1. rewriteAssetURLs：图片相对路径重写（已知 working-case）
//  2. rewriteOneAssetURL：单图 URL 各种输入的边界条件
//
//  注：链接（<a href>）的相对路径解析由 WKWebView 的 baseURL 机制处理，
//  属于集成层面行为，不适合在纯 Swift 单测中覆盖（需要真实 WKWebView 环境）。
//  详情页 baseURL 统一由 repositoryContentBaseURL(from:) 构造为 `/blob/HEAD/` 目录，
//  保证相对链接在 WebView 中解析时不会把 HEAD 当作文件名丢掉。
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

    // MARK: - rewriteAssetURLs

    @Test("相对路径图片重写为 raw.githubusercontent.com")
    func rewriteAssetURLs_relativePath() {
        let html = #"<img src="./logo.png" alt="logo">"#
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://raw.githubusercontent.com/alice/foo/HEAD/logo.png"))
    }

    @Test("绝对 URL 图片不重写")
    func rewriteAssetURLs_absoluteURL() {
        let html = #"<img src="https://example.com/logo.png" alt="logo">"#
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://example.com/logo.png"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("协议相对 // URL 不重写")
    func rewriteAssetURLs_protocolRelative() {
        let html = #"<img src="//avatars.githubusercontent.com/u/1234" alt="avatar">"#
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("//avatars.githubusercontent.com"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("data: URI 不重写")
    func rewriteAssetURLs_dataURI() {
        let html = #"<img src="data:image/png;base64,abc123" alt="badge">"#
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("data:image/png;base64,abc123"))
    }

    @Test("无 owner/repo 时不重写（保守策略）")
    func rewriteAssetURLs_nilOwner() {
        let html = #"<img src="./logo.png" alt="logo">"#
        #expect(ReadmeWebView.rewriteAssetURLs(in: html, owner: nil, repo: "foo") == html)
        #expect(ReadmeWebView.rewriteAssetURLs(in: html, owner: "alice", repo: nil) == html)
        #expect(ReadmeWebView.rewriteAssetURLs(in: html, owner: "", repo: "foo") == html)
    }

    @Test("多张图片全部重写")
    func rewriteAssetURLs_multipleImages() {
        let html = """
        <img src="./a.png">
        <img src="./b.png">
        <img src="https://example.com/c.png">
        """
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "bob", repo: "bar")
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/a.png"))
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/b.png"))
        #expect(result.contains("https://example.com/c.png"))
    }

    @Test("嵌套属性 img 标签也能匹配")
    func rewriteAssetURLs_imgWithOtherAttrs() {
        let html = #"<img class="badge" src="./shield.svg" loading="lazy" alt="build">"#
        let result = ReadmeWebView.rewriteAssetURLs(in: html, owner: "carol", repo: "baz")
        #expect(result.contains("raw.githubusercontent.com/carol/baz/HEAD/shield.svg"))
    }

    // MARK: - rewriteOneAssetURL

    @Test("不带 ./ 前缀的相对路径也能正确处理")
    func rewriteOneAssetURL_withoutDotSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeWebView.rewriteOneAssetURL("logo.png", rawBase: rawBase) == rawBase + "logo.png")
        #expect(ReadmeWebView.rewriteOneAssetURL("./logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("前导斜杠被去掉以与仓库根对齐")
    func rewriteOneAssetURL_leadingSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        // 单层斜杠：典型真实路径，如 /images/logo.png
        #expect(ReadmeWebView.rewriteOneAssetURL("/logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("mailto: 和 javascript: 不重写")
    func rewriteOneAssetURL_mailtoJS() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeWebView.rewriteOneAssetURL("mailto:alice@example.com", rawBase: rawBase)
            == "mailto:alice@example.com")
        #expect(ReadmeWebView.rewriteOneAssetURL("javascript:void(0)", rawBase: rawBase)
            == "javascript:void(0)")
    }

    @Test("空白和换行被 trim")
    func rewriteOneAssetURL_whitespace() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeWebView.rewriteOneAssetURL("  ./logo.png  \n", rawBase: rawBase)
            == rawBase + "logo.png")
    }
}
