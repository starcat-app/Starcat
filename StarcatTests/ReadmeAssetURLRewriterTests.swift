//
//  ReadmeAssetURLRewriterTests.swift
//  StarcatTests
//
//  HOM-201 P1-2 配套（2026-06-14）：`<img>` 相对路径重写工具单测。
//
//  本文件继承原 `ReadmeWebViewTests` 中关于 `rewriteAssetURLs` / `rewriteOneAssetURL`
//  的 8 个用例（逻辑没改、仅是函数从 UI 层 ReadmeWebView 迁到 IO 层
//  ReadmeAssetURLRewriter）。新增没有，因为本步是纯位置迁移。
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeAssetURLRewriter")
struct ReadmeAssetURLRewriterTests {

    // MARK: - rewrite (HTML 整体扫描)

    @Test("相对路径图片重写为 raw.githubusercontent.com")
    func rewrite_relativePath() {
        let html = #"<img src="./logo.png" alt="logo">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://raw.githubusercontent.com/alice/foo/HEAD/logo.png"))
    }

    @Test("绝对 URL 图片不重写")
    func rewrite_absoluteURL() {
        let html = #"<img src="https://example.com/logo.png" alt="logo">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("https://example.com/logo.png"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("协议相对 // URL 不重写")
    func rewrite_protocolRelative() {
        let html = #"<img src="//avatars.githubusercontent.com/u/1234" alt="avatar">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("//avatars.githubusercontent.com"))
        #expect(!result.contains("raw.githubusercontent.com"))
    }

    @Test("data: URI 不重写")
    func rewrite_dataURI() {
        let html = #"<img src="data:image/png;base64,abc123" alt="badge">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: "foo")
        #expect(result.contains("data:image/png;base64,abc123"))
    }

    @Test("无 owner/repo 时不重写（保守策略）")
    func rewrite_nilOwner() {
        let html = #"<img src="./logo.png" alt="logo">"#
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: nil, repo: "foo") == html)
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "alice", repo: nil) == html)
        #expect(ReadmeAssetURLRewriter.rewrite(in: html, owner: "", repo: "foo") == html)
    }

    @Test("多张图片全部重写")
    func rewrite_multipleImages() {
        let html = """
        <img src="./a.png">
        <img src="./b.png">
        <img src="https://example.com/c.png">
        """
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "bob", repo: "bar")
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/a.png"))
        #expect(result.contains("raw.githubusercontent.com/bob/bar/HEAD/b.png"))
        #expect(result.contains("https://example.com/c.png"))
    }

    @Test("嵌套属性 img 标签也能匹配")
    func rewrite_imgWithOtherAttrs() {
        let html = #"<img class="badge" src="./shield.svg" loading="lazy" alt="build">"#
        let result = ReadmeAssetURLRewriter.rewrite(in: html, owner: "carol", repo: "baz")
        #expect(result.contains("raw.githubusercontent.com/carol/baz/HEAD/shield.svg"))
    }

    // MARK: - rewriteOne (单个 src)

    @Test("不带 ./ 前缀的相对路径也能正确处理")
    func rewriteOne_withoutDotSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("logo.png", rawBase: rawBase) == rawBase + "logo.png")
        #expect(ReadmeAssetURLRewriter.rewriteOne("./logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("前导斜杠被去掉以与仓库根对齐")
    func rewriteOne_leadingSlash() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("/logo.png", rawBase: rawBase) == rawBase + "logo.png")
    }

    @Test("GitHub 根路径 raw 图片重写为 raw.githubusercontent.com")
    func rewriteOne_githubRootRawPath() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        let src = "/javalin/javalin/raw/master/.github/img/javalin.png"
        let expected = "https://raw.githubusercontent.com/javalin/javalin/master/.github/img/javalin.png"

        #expect(ReadmeAssetURLRewriter.rewriteOne(src, rawBase: rawBase) == expected)
    }

    @Test("普通前导斜杠路径不误判为 GitHub raw 路径")
    func rewriteOne_leadingSlashWithoutRawKeepsCurrentRepoRoot() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"

        #expect(ReadmeAssetURLRewriter.rewriteOne("/javalin/javalin/logo.png", rawBase: rawBase)
            == rawBase + "javalin/javalin/logo.png")
    }

    @Test("mailto: 和 javascript: 不重写")
    func rewriteOne_mailtoJS() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("mailto:alice@example.com", rawBase: rawBase)
            == "mailto:alice@example.com")
        #expect(ReadmeAssetURLRewriter.rewriteOne("javascript:void(0)", rawBase: rawBase)
            == "javascript:void(0)")
    }

    @Test("空白和换行被 trim")
    func rewriteOne_whitespace() {
        let rawBase = "https://raw.githubusercontent.com/alice/foo/HEAD/"
        #expect(ReadmeAssetURLRewriter.rewriteOne("  ./logo.png  \n", rawBase: rawBase)
            == rawBase + "logo.png")
    }
}
