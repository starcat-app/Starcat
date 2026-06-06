//
//  StarredExportRendererTests.swift
//  StarcatTests
//
//  HOM-174：StarredMarkdownRenderer / StarredHTMLRenderer 烟测。
//
//  目的：保证 v1 渲染器在常见输入下不 crash，且关键 anchor / 结构出现在输出里。
//  不是覆盖率追求，仅作"未来无意中改坏"的最低防线（snapshot 风格 + 关键字断言）。
//

import XCTest
@testable import Starcat

final class StarredExportRendererTests: XCTestCase {

    private func makeUser() -> GitHubUserDTO {
        GitHubUserDTO(
            id: 1, login: "dong4j", name: "DONG Jianjun",
            avatarUrl: "https://avatars.githubusercontent.com/u/3380083?v=4",
            publicRepos: 48, followers: 236, following: 100,
            bio: "用代码解决真正的问题。", company: "@multica",
            location: "Shanghai", email: nil,
            blog: "dong4j.github.io",
            twitterUsername: "dong4j",
            htmlUrl: "https://github.com/dong4j"
        )
    }

    private func makeRepos() -> [Repo] {
        return [
            Repo(
                id: 1, owner: "vapor", name: "vapor", fullName: "vapor/vapor",
                description: "A server-side Swift HTTP web framework.",
                language: "Swift",
                starsCount: 24521, forksCount: 1432, watchersCount: 567,
                topics: "[\"swift\",\"server\",\"web\",\"framework\"]",
                license: "MIT", homepage: "https://vapor.codes",
                htmlUrl: "https://github.com/vapor/vapor",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                pushedAt: "2026-05-12T08:23:11Z",
                createdAt: "2015-09-18T12:00:00Z",
                updatedAt: "2026-05-12T08:23:11Z",
                starredAt: "2025-09-12T10:00:00Z",
                cachedAt: nil
            ),
            Repo(
                id: 2, owner: "openai", name: "evals", fullName: "openai/evals",
                description: "OpenAI Evals | A framework for evaluating LLMs.",
                language: "Python",
                starsCount: 14200, forksCount: 2300, watchersCount: 200,
                topics: "[\"ai\",\"llm\",\"eval\"]",
                license: "MIT", homepage: nil,
                htmlUrl: "https://github.com/openai/evals",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                pushedAt: "2026-04-01T08:00:00Z",
                createdAt: "2023-03-11T08:00:00Z",
                updatedAt: "2026-04-01T08:00:00Z",
                starredAt: "2024-01-08T15:00:00Z",
                cachedAt: nil
            ),
            Repo(
                id: 3, owner: "x", name: "archived-experiment", fullName: "x/archived-experiment",
                description: nil,
                language: nil,
                starsCount: 12, forksCount: 0, watchersCount: 2,
                topics: nil,
                license: nil, homepage: nil,
                htmlUrl: "https://github.com/x/archived-experiment",
                cloneUrl: nil, sshUrl: nil,
                isPrivate: false, isFork: false, isArchived: true, isStarred: true,
                pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
            )
        ]
    }

    // MARK: - Markdown

    func testMarkdownContainsTitleAndOverviewAndLanguageSections() {
        let md = StarredMarkdownRenderer.render(repos: makeRepos(), user: makeUser())

        XCTAssertTrue(md.contains("⭐ Starred Repositories by DONG Jianjun"), "应包含 hero 标题")
        XCTAssertTrue(md.contains("**[@dong4j](https://github.com/dong4j)**"), "应包含用户链接")
        XCTAssertTrue(md.contains("📊 Overview"), "应包含 Overview 段")
        XCTAssertTrue(md.contains("📚 Table of Contents"), "应包含语言 TOC")
        XCTAssertTrue(md.contains("Swift"), "应包含语言段标题")
        XCTAssertTrue(md.contains("Python"), "应包含 Python 段")
        XCTAssertTrue(md.contains("[vapor/vapor](https://github.com/vapor/vapor)"), "应包含 repo 链接")
        XCTAssertTrue(md.contains("`swift`"), "应包含 topic 行内代码")
        XCTAssertTrue(md.contains("Other"), "无语言 repo 应归入 Other 段")
        XCTAssertTrue(md.contains("🗄 Archived"), "归档 repo 应显示 Archived")
    }

    func testMarkdownEmptyReposGracefulFallback() {
        let md = StarredMarkdownRenderer.render(repos: [], user: makeUser())
        XCTAssertTrue(md.contains("⭐ Starred Repositories by DONG Jianjun"))
        XCTAssertTrue(md.contains("No starred repositories yet"))
    }

    func testMarkdownEscapesPipeInDescription() {
        let weirdRepo = Repo(
            id: 99, owner: "evil", name: "pipes", fullName: "evil/pipes",
            description: "Description with | pipe character that would break tables.",
            language: "Swift",
            starsCount: 1, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/evil/pipes",
            cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
        let md = StarredMarkdownRenderer.render(repos: [weirdRepo], user: makeUser())
        XCTAssertTrue(md.contains("\\|"), "管道字符应被转义为 \\|")
    }

    // MARK: - HTML

    func testHTMLContainsAllRequiredSections() {
        let html = StarredHTMLRenderer.render(repos: makeRepos(), user: makeUser())

        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), "应是合法 HTML5 文档")
        XCTAssertTrue(html.contains("DONG Jianjun"), "应包含用户名")
        XCTAssertTrue(html.contains("class=\"hero\""), "应包含 hero 段")
        XCTAssertTrue(html.contains("class=\"toolbar\""), "应包含 toolbar")
        XCTAssertTrue(html.contains("id=\"search-input\""), "应包含搜索框")
        XCTAssertTrue(html.contains("id=\"sort-select\""), "应包含排序选择")
        XCTAssertTrue(html.contains("id=\"language-select\""), "应包含语言筛选")
        XCTAssertTrue(html.contains("id=\"starred-data\""), "应嵌入数据 JSON")
        XCTAssertTrue(html.contains("Starcat"), "应有 Powered by Starcat")
        XCTAssertTrue(html.contains("vapor/vapor"), "数据 JSON 应包含 repo")
    }

    func testHTMLDoesNotBreakOnScriptTagInDescription() {
        let evilRepo = Repo(
            id: 99, owner: "evil", name: "xss", fullName: "evil/xss",
            description: "</script><script>alert(1)</script>",
            language: "Swift",
            starsCount: 1, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/evil/xss",
            cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false, isStarred: true,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
        let html = StarredHTMLRenderer.render(repos: [evilRepo], user: makeUser())
        // 关键安全断言：原始 `</script>` 不能在 inline JSON 里以未转义形态出现
        // （会提前关闭 <script id="starred-data">）
        XCTAssertFalse(html.contains("</script><script>alert"), "脚本注入应被转义")
    }

    func testHTMLEscapesHeroFields() {
        let user = GitHubUserDTO(
            id: 1, login: "evil<x", name: "Tag<er>",
            avatarUrl: nil,
            publicRepos: nil, followers: nil, following: nil,
            bio: "<img onerror=alert(1) src=x>",
            company: nil, location: nil, email: nil, blog: nil,
            twitterUsername: nil, htmlUrl: "https://github.com/evil"
        )
        let html = StarredHTMLRenderer.render(repos: [], user: user)
        XCTAssertFalse(html.contains("<img onerror=alert(1) src=x>"),
                       "用户字段必须 HTML 转义，避免 XSS")
        XCTAssertTrue(html.contains("&lt;img onerror=alert(1) src=x&gt;"))
    }

    // MARK: - HTML v2（AI 摘要 + 标签筛选 + 头像 base64 + toolbar 对齐）

    /// supplements 全空时，AI 模态框 DOM 仍渲染但默认 hidden；卡片中不应出现 AI 按钮；
    /// Tags 下拉容器仍渲染但 hidden。给 v1 兼容路径兜底，保证旧调用方零回归。
    func testHTMLSupplementsEmptyDoesNotAddAIButtonsOrTagFilter() {
        let html = StarredHTMLRenderer.render(repos: makeRepos(), user: makeUser())
        XCTAssertTrue(html.contains("id=\"ai-modal\""), "模态框 DOM 必须存在（JS 端按需 show/hide）")
        XCTAssertFalse(html.contains("class=\"ai-summary-btn\""), "无摘要时卡片不应渲染 AI 按钮")
        XCTAssertTrue(html.contains("id=\"tag-select-wrapper\" hidden"), "无标签时 Tags 下拉应默认隐藏")
    }

    /// 提供 AI 摘要 + 标签 + 头像 base64 时，HTML 应正确把数据嵌入 JSON、显示 Tags 下拉、
    /// 在 hero 段渲染 <img> 头像而不是 initials 文字。
    func testHTMLSupplementsPopulatesAIAndTagsAndAvatar() {
        let repos = makeRepos()
        let dataURI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let supplements = StarredHTMLRenderer.ExportSupplements(
            aiSummaries: [1: "## Vapor 概览\n\n- 服务端 Swift 框架。"],
            repoTags: [1: ["server", "swift"], 2: ["llm"]],
            avatarDataURI: dataURI,
            ownerAvatars: [:]
        )
        let html = StarredHTMLRenderer.render(repos: repos, user: makeUser(), supplements: supplements)

        XCTAssertTrue(html.contains("\"aiSummary\""),
                      "JSON payload 应包含 aiSummary 字段")
        XCTAssertTrue(html.contains("\"## Vapor 概览"),
                      "AI 摘要 markdown 应嵌入到 JSON 中（JSONEncoder 自动转义）")
        XCTAssertTrue(html.contains("\"allTags\""),
                      "JSON payload 应包含 allTags 列表")
        XCTAssertTrue(html.contains("\"server\""),
                      "Tags 数据应嵌入 JSON")
        XCTAssertTrue(html.contains("id=\"ai-modal\""),
                      "AI 模态框 DOM 应存在")
        XCTAssertTrue(html.contains("data:image/png;base64,iVBORw0"),
                      "头像 base64 data URI 应内联到 hero 段")
        XCTAssertTrue(html.contains("class=\"avatar has-image\""),
                      "hero 头像应附加 has-image class 以切换样式")
    }

    /// v3：repo 卡片 head 区在标题左侧新增 owner 头像 logo 位。
    /// - 没有 ownerAvatar 数据时：用首字母占位（DOM 中应能找到 `.repo-logo` class）
    /// - 提供 ownerAvatars 字典时：JSON payload 应携带 `ownerAvatar` 字段（base64 data URI）
    func testHTMLOwnerAvatarsEmbedsDataURIInJSON() {
        let repos = makeRepos()
        let dataURI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let supplements = StarredHTMLRenderer.ExportSupplements(
            aiSummaries: [:],
            repoTags: [:],
            avatarDataURI: nil,
            ownerAvatars: ["vapor": dataURI]
        )
        let html = StarredHTMLRenderer.render(repos: repos, user: makeUser(), supplements: supplements)

        XCTAssertTrue(html.contains("\"ownerAvatar\""),
                      "JSON payload 应包含 ownerAvatar 字段")
        // 同时验证 CSS（.repo-logo）和 JS（'repo-logo'）两处都引用了该 class
        XCTAssertTrue(html.contains(".repo-logo"),
                      "CSS 应定义 .repo-logo 样式")
        XCTAssertTrue(html.contains("'repo-logo'"),
                      "renderCard JS 应通过 el() 创建 .repo-logo 元素")
        XCTAssertTrue(html.contains(dataURI),
                      "vapor 的 ownerAvatar 应原样嵌入 JSON")
    }

    /// toolbar 对齐修复：v2 把 `.select` label 从"上下两行"改成"水平 row"，并加 `.select-label` class。
    func testHTMLToolbarUsesHorizontalSelectLayout() {
        let html = StarredHTMLRenderer.render(repos: makeRepos(), user: makeUser())
        XCTAssertTrue(html.contains("class=\"select-label\""),
                      "v2 toolbar 的 select label 必须用 .select-label 横向布局类")
        XCTAssertTrue(html.contains("id=\"tag-select\""),
                      "v2 toolbar 必须有 Tag 下拉控件（即使初始隐藏）")
    }

    // MARK: - Format helpers

    func testDefaultFileNameContainsLoginAndDate() {
        let name = StarredExportFormat.markdown.defaultFileName(userLogin: "dong4j")
        XCTAssertTrue(name.hasPrefix("starcat-dong4j-starred-"))
        XCTAssertTrue(name.hasSuffix(".md"))
        let htmlName = StarredExportFormat.html.defaultFileName(userLogin: "dong4j")
        XCTAssertTrue(htmlName.hasSuffix(".html"))
    }
}
