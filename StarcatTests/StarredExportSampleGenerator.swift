//
//  StarredExportSampleGenerator.swift
//  StarcatTests
//
//  HOM-174 辅助：开发期生成 sample.md / sample.html 文件，便于在 issue 附件 / browser 里预览效果。
//
//  使用方式：
//  - 默认 skip（XCTSkip），CI 不跑。
//  - 想跑：把 `try XCTSkipIf(true...)` 改成 `false`，运行后产物落到 `/tmp/starcat-export-sample.*`。
//

import XCTest
@testable import Starcat

final class StarredExportSampleGenerator: XCTestCase {

    func testGenerateSamples() throws {
        try XCTSkipIf(true, "Sample generator: enable manually to produce /tmp/starcat-export-sample.{md,html}")

        let user = GitHubUserDTO(
            id: 1, login: "dong4j", name: "DONG Jianjun",
            avatarUrl: nil,
            publicRepos: 48, followers: 236, following: 100,
            bio: "Building Starcat — a native macOS app to manage your GitHub stars.",
            company: "@multica",
            location: "Shanghai, China", email: nil,
            blog: "dong4j.github.io",
            twitterUsername: "dong4j",
            htmlUrl: "https://github.com/dong4j"
        )

        let repos = sampleRepos()

        let md = StarredMarkdownRenderer.render(repos: repos, user: user)
        let html = StarredHTMLRenderer.render(repos: repos, user: user)

        // App 在 sandbox 下运行；写到 Container/Data/Documents 是允许的目录。
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let mdURL = docs.appendingPathComponent("starcat-export-sample.md")
        let htmlURL = docs.appendingPathComponent("starcat-export-sample.html")
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        print("Wrote sample MD: \(mdURL.path) (\(md.count) chars)")
        print("Wrote sample HTML: \(htmlURL.path) (\(html.count) chars)")
    }

    /// 一组覆盖多种语言、状态、字段缺失情况的 mock repos，让 sample 输出尽可能真实。
    private func sampleRepos() -> [Repo] {
        return [
            Repo(id: 1, owner: "vapor", name: "vapor", fullName: "vapor/vapor",
                 description: "💧 A server-side Swift HTTP web framework.",
                 language: "Swift",
                 starsCount: 24521, forksCount: 1432, watchersCount: 567,
                 topics: "[\"swift\",\"server\",\"web\",\"framework\",\"hacktoberfest\"]",
                 license: "MIT", homepage: "https://vapor.codes",
                 htmlUrl: "https://github.com/vapor/vapor",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-05-12T08:23:11Z", createdAt: "2015-09-18T12:00:00Z",
                 updatedAt: "2026-05-12T08:23:11Z", starredAt: "2025-09-12T10:00:00Z",
                 cachedAt: nil),
            Repo(id: 2, owner: "pointfreeco", name: "swift-composable-architecture",
                 fullName: "pointfreeco/swift-composable-architecture",
                 description: "A library for building applications in a consistent and understandable way.",
                 language: "Swift",
                 starsCount: 12340, forksCount: 1411, watchersCount: 220,
                 topics: "[\"swift\",\"swiftui\",\"architecture\",\"redux\"]",
                 license: "MIT", homepage: "https://pointfree.co",
                 htmlUrl: "https://github.com/pointfreeco/swift-composable-architecture",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-06-01T08:00:00Z", createdAt: "2020-05-04T12:00:00Z",
                 updatedAt: "2026-06-01T08:00:00Z", starredAt: "2024-03-20T10:00:00Z",
                 cachedAt: nil),
            Repo(id: 3, owner: "openai", name: "evals", fullName: "openai/evals",
                 description: "OpenAI Evals | A framework for evaluating LLMs.",
                 language: "Python",
                 starsCount: 14200, forksCount: 2300, watchersCount: 200,
                 topics: "[\"ai\",\"llm\",\"eval\"]",
                 license: "MIT", homepage: nil,
                 htmlUrl: "https://github.com/openai/evals",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-04-01T08:00:00Z", createdAt: "2023-03-11T08:00:00Z",
                 updatedAt: "2026-04-01T08:00:00Z", starredAt: "2024-01-08T15:00:00Z",
                 cachedAt: nil),
            Repo(id: 4, owner: "vercel", name: "next.js", fullName: "vercel/next.js",
                 description: "The React Framework",
                 language: "JavaScript",
                 starsCount: 121000, forksCount: 26000, watchersCount: 1500,
                 topics: "[\"react\",\"nextjs\",\"web\",\"framework\",\"ssr\"]",
                 license: "MIT", homepage: "https://nextjs.org",
                 htmlUrl: "https://github.com/vercel/next.js",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-06-05T08:00:00Z", createdAt: "2016-10-05T12:00:00Z",
                 updatedAt: "2026-06-05T08:00:00Z", starredAt: "2023-04-10T15:00:00Z",
                 cachedAt: nil),
            Repo(id: 5, owner: "rust-lang", name: "rust", fullName: "rust-lang/rust",
                 description: "Empowering everyone to build reliable and efficient software.",
                 language: "Rust",
                 starsCount: 95000, forksCount: 12000, watchersCount: 2400,
                 topics: "[\"rust\",\"compiler\",\"language\"]",
                 license: "Apache-2.0", homepage: "https://www.rust-lang.org",
                 htmlUrl: "https://github.com/rust-lang/rust",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-06-06T08:00:00Z", createdAt: "2010-06-16T12:00:00Z",
                 updatedAt: "2026-06-06T08:00:00Z", starredAt: "2022-08-01T10:00:00Z",
                 cachedAt: nil),
            Repo(id: 6, owner: "tldr-pages", name: "tldr", fullName: "tldr-pages/tldr",
                 description: "📚 Collaborative cheatsheets for console commands",
                 language: "Markdown",
                 starsCount: 50000, forksCount: 4200, watchersCount: 700,
                 topics: "[\"cli\",\"documentation\",\"cheatsheet\"]",
                 license: "CC-BY-4.0", homepage: "https://tldr.sh",
                 htmlUrl: "https://github.com/tldr-pages/tldr",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: false, isStarred: true,
                 pushedAt: "2026-06-04T08:00:00Z", createdAt: "2013-12-08T12:00:00Z",
                 updatedAt: "2026-06-04T08:00:00Z", starredAt: "2021-11-15T10:00:00Z",
                 cachedAt: nil),
            Repo(id: 7, owner: "old", name: "deprecated-tool", fullName: "old/deprecated-tool",
                 description: nil, language: nil,
                 starsCount: 12, forksCount: 0, watchersCount: 2,
                 topics: nil, license: nil, homepage: nil,
                 htmlUrl: "https://github.com/old/deprecated-tool",
                 cloneUrl: nil, sshUrl: nil,
                 isPrivate: false, isFork: false, isArchived: true, isStarred: true,
                 pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil)
        ]
    }
}
