//
//  RepositoryMarkdownLinkTests.swift
//  StarcatTests
//
//  同仓 Markdown 链接分类。覆盖相对解析后的 blob URL、raw、其它仓和应回退浏览器的路径。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepositoryMarkdownLink")
struct RepositoryMarkdownLinkTests {

    @Test("blob HEAD 下的相对 README 语言文件")
    func classifiesBlobHeadReadme() throws {
        let url = try #require(URL(string: "https://github.com/MartinDelophy/ai-video-editor/blob/HEAD/README.zh-CN.md"))
        let target = try #require(RepositoryMarkdownLink.classify(
            url,
            owner: "MartinDelophy",
            repo: "ai-video-editor"
        ))
        #expect(target.path == "README.zh-CN.md")
        #expect(target.ref == "HEAD")
        #expect(target.windowTitle == "MartinDelophy/ai-video-editor · README.zh-CN.md")
    }

    @Test("子目录 markdown 与 owner 大小写不敏感")
    func classifiesNestedMarkdownIgnoringOwnerCase() throws {
        let url = try #require(URL(string: "https://github.com/octocat/Hello-World/blob/main/docs/zh/guide.md"))
        let target = try #require(RepositoryMarkdownLink.classify(url, owner: "Octocat", repo: "hello-world"))
        #expect(target.path == "docs/zh/guide.md")
        #expect(target.ref == "main")
        #expect(target.contentBaseURL.absoluteString == "https://github.com/octocat/Hello-World/blob/main/docs/zh/")
    }

    @Test("raw.githubusercontent.com 也识别")
    func classifiesRawURL() throws {
        let url = try #require(URL(string: "https://raw.githubusercontent.com/alice/foo/HEAD/CONTRIBUTING.md"))
        let target = try #require(RepositoryMarkdownLink.classify(url, owner: "alice", repo: "foo"))
        #expect(target.path == "CONTRIBUTING.md")
        #expect(target.ref == "HEAD")
    }

    @Test("github raw 路径与 .markdown 扩展名")
    func classifiesGitHubRawMarkdownAlias() throws {
        let url = try #require(URL(string: "https://www.github.com/alice/foo/raw/master/notes.markdown"))
        let target = try #require(RepositoryMarkdownLink.parse(url))
        #expect(target.repo == "foo")
        #expect(target.path == "notes.markdown")
    }

    @Test("锚点不影响分类")
    func ignoresFragment() throws {
        let url = try #require(URL(string: "https://github.com/alice/foo/blob/HEAD/README.md#中文"))
        let target = try #require(RepositoryMarkdownLink.classify(url, owner: "alice", repo: "foo"))
        #expect(target.path == "README.md")
    }

    @Test("其它仓库不拦截")
    func rejectsOtherRepository() throws {
        let url = try #require(URL(string: "https://github.com/other/repo/blob/HEAD/README.md"))
        #expect(RepositoryMarkdownLink.classify(url, owner: "alice", repo: "foo") == nil)
    }

    @Test("Issue / tree / 图片回退浏览器")
    func rejectsNonMarkdownGitHubPages() throws {
        let issue = try #require(URL(string: "https://github.com/alice/foo/issues/1"))
        let tree = try #require(URL(string: "https://github.com/alice/foo/tree/HEAD/docs"))
        let image = try #require(URL(string: "https://github.com/alice/foo/blob/HEAD/docs/logo.png"))
        let mdx = try #require(URL(string: "https://github.com/alice/foo/blob/HEAD/page.mdx"))
        #expect(RepositoryMarkdownLink.classify(issue, owner: "alice", repo: "foo") == nil)
        #expect(RepositoryMarkdownLink.classify(tree, owner: "alice", repo: "foo") == nil)
        #expect(RepositoryMarkdownLink.classify(image, owner: "alice", repo: "foo") == nil)
        #expect(RepositoryMarkdownLink.classify(mdx, owner: "alice", repo: "foo") == nil)
    }

    @Test("相对链接经 blob/HEAD 基址解析后可分类")
    func classifiesRelativeLinkResolvedAgainstHeadBase() throws {
        let repositoryURL = try #require(URL(string: "https://github.com/alice/foo"))
        let baseURL = ReadmeWebView.repositoryContentBaseURL(from: repositoryURL)
        let resolved = try #require(URL(string: "README.ja.md", relativeTo: baseURL)?.absoluteURL)
        let target = try #require(RepositoryMarkdownLink.classify(resolved, owner: "alice", repo: "foo"))
        #expect(target.path == "README.ja.md")
        #expect(target.ref == "HEAD")
    }
}
