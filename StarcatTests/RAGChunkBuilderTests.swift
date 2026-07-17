//
//  RAGChunkBuilderTests.swift
//  StarcatTests
//
//  验证 README 结构切分、稳定 key、代码块 / 表格保护及多来源输入。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAGChunkBuilder")
struct RAGChunkBuilderTests {
    @MainActor
    @Test("分片纯计算移出主线程后保持输出一致")
    func detachedChunkBuildPreservesOutput() async throws {
        let builder = RAGChunkBuilder()
        let input = RAGChunkBuildInput(
            repo: fixtureRepo(stars: 88),
            readme: """
                # Install

                Use Swift Package Manager.

                # Usage

                ```swift
                let database = try DatabaseQueue()
                ```
                """,
            note: nil,
            summaryText: "A local-first database toolkit.",
            summarySourceID: "summary-model",
            tags: ["database", "swift"]
        )

        let expected = builder.build(input)
        let actual = try await RAGChunkBuildExecutor.build(input, using: builder)

        #expect(actual == expected)
    }

    @Test("README 按 heading 生成稳定 section parent")
    func headingsProduceStableParents() throws {
        let builder = RAGChunkBuilder(configuration: .init(
            targetTokens: 30,
            minimumTokens: 1,
            maximumTokens: 40,
            overlapTokens: 5,
            hardMaximumTokens: 80
        ))
        let original = builder.buildReadme(repoId: 1, markdown: """
            # Install

            Use Swift Package Manager to install this package.

            # Usage

            Create a database and run a query.
            """)
        let inserted = builder.buildReadme(repoId: 1, markdown: """
            # Overview

            A short overview.

            # Install

            Use Swift Package Manager to install this package.

            # Usage

            Create a database and run a query.
            """)

        let installKey = try #require(original.first { $0.sectionPath == "Install" }?.chunkKey)
        #expect(installKey == inserted.first { $0.sectionPath == "Install" }?.chunkKey)
        #expect(original.contains { $0.parentKey == "readme:usage" })
    }

    @Test("fenced code block 不在中间切断")
    func fencedCodeBlockStaysWhole() {
        let builder = RAGChunkBuilder(configuration: .init(
            targetTokens: 12,
            minimumTokens: 1,
            maximumTokens: 20,
            overlapTokens: 2,
            hardMaximumTokens: 100
        ))
        let chunks = builder.buildReadme(repoId: 1, markdown: """
            # Example

            Intro paragraph.

            ```swift
            let db = try DatabaseQueue()
            try db.write { db in
                try Player(name: "Arthur").insert(db)
            }
            ```

            Tail paragraph.
            """)
        let codeChunks = chunks.filter { $0.content.contains("```swift") }
        #expect(codeChunks.count == 1)
        #expect(codeChunks[0].content.contains("```"))
        #expect(codeChunks[0].content.contains("Player"))
    }

    @Test("大表格切分时重复表头")
    func largeTableRepeatsHeader() {
        let rows = (1...20).map { "| row-\($0) | value-\($0) |" }.joined(separator: "\n")
        let builder = RAGChunkBuilder(configuration: .init(
            targetTokens: 20,
            minimumTokens: 1,
            maximumTokens: 25,
            overlapTokens: 0,
            hardMaximumTokens: 100
        ))
        let chunks = builder.buildReadme(repoId: 1, markdown: """
            # Matrix

            | Name | Value |
            | --- | --- |
            \(rows)
            """)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.content.contains("| Name | Value |") })
    }

    @Test("metadata 保留动态事实原值并省略缺失字段")
    func metadataIncludesRepoFacts() {
        let repo = fixtureRepo(stars: 12_345)
        let chunks = RAGChunkBuilder().buildMetadata(
            repo: repo,
            note: nil,
            tags: ["database", "swift"],
            snapshot: nil
        )
        let content = chunks[0].content
        #expect(content.contains("Repository: octo/demo"))
        #expect(content.contains("GitHub URL: https://github.com/octo/demo"))
        #expect(content.contains("Stars: 12345"))
        #expect(content.contains("Homepage: https://example.com/demo"))
        #expect(content.contains("Tags: database, swift"))
        #expect(!content.contains("Unknown"))
    }

    @Test("metadata 按固定顺序追加有效 Wiki 链接")
    func metadataIncludesWikiLinksInStableOrder() throws {
        let repo = fixtureRepo(stars: 1)
        let links = RepoWikiMenuState.make(items: [
            WikiStatusItem(
                source: .codeWiki,
                status: .indexed,
                url: try #require(URL(string: "https://codewiki.example/octo/demo")),
                probeMethod: nil,
                httpStatus: 200,
                matchedSignals: nil
            ),
            WikiStatusItem(
                source: .deepWiki,
                status: .indexed,
                url: try #require(URL(string: "https://deepwiki.com/octo/demo")),
                probeMethod: nil,
                httpStatus: 200,
                matchedSignals: nil
            ),
            WikiStatusItem(
                source: .zread,
                status: .notIndexed,
                url: try #require(URL(string: "https://zread.ai/octo/demo")),
                probeMethod: nil,
                httpStatus: 404,
                matchedSignals: nil
            )
        ])
        let content = try #require(RAGChunkBuilder().buildMetadata(
            repo: repo,
            note: nil,
            tags: [],
            snapshot: RAGMetadataSnapshot(
                latestRelease: nil,
                health: nil,
                openSSF: nil,
                wikiLinks: links
            )
        ).first?.content)

        let deepWikiRange = try #require(content.range(of: "Wiki DeepWiki: https://deepwiki.com/octo/demo"))
        let codeWikiRange = try #require(content.range(of: "Wiki CodeWiki: https://codewiki.example/octo/demo"))
        #expect(deepWikiRange.lowerBound < codeWikiRange.lowerBound)
        #expect(!content.contains("Wiki ZRead"))
    }

    @Test("重复 heading 使用 occurrence 消歧稳定 key")
    func duplicateHeadingsHaveUniqueKeys() {
        let body = String(repeating: "This section contains meaningful setup details. ", count: 24)
        let chunks = RAGChunkBuilder().buildReadme(repoId: 1, markdown: """
            # Setup
            \(body)

            # Setup
            \(body)
            """)
        #expect(chunks.count >= 2)
        #expect(Set(chunks.map(\.chunkKey)).count == chunks.count)
        #expect(chunks.contains { $0.parentKey == "readme:setup-2" })
    }

    @Test("Wiki cache change 只路由通知中的单个仓库 identity")
    func wikiCacheChangeRoutesOneRepository() {
        let notification = Notification(
            name: .wikiCacheDidChange,
            userInfo: ["owner": "octo", "repo": "demo"]
        )

        #expect(
            RAGWikiMetadataRefreshRoute.changedRepository(from: notification)
                == WikiRepoKey(owner: "octo", repo: "demo")
        )
    }

    @Test("Wiki cache reset 保留全部受影响仓库并忽略非法 payload")
    func wikiCacheResetRoutesAffectedRepositories() {
        let keys = [
            WikiRepoKey(owner: "octo", repo: "one"),
            WikiRepoKey(owner: "swiftlang", repo: "two")
        ]
        let reset = Notification(
            name: .wikiCacheDidReset,
            userInfo: ["repositoryKeys": keys]
        )

        #expect(RAGWikiMetadataRefreshRoute.resetRepositories(from: reset) == keys)
        #expect(RAGWikiMetadataRefreshRoute.resetRepositories(
            from: Notification(name: .wikiCacheDidReset, userInfo: ["repositoryKeys": "invalid"])
        ).isEmpty)
        #expect(RAGWikiMetadataRefreshRoute.changedRepository(
            from: Notification(name: .wikiCacheDidChange, userInfo: ["owner": "octo"])
        ) == nil)
    }

    @Test("超长单行按字符预算截断到 hard max")
    func veryLongSingleLineIsHardTruncated() throws {
        let chunks = RAGChunkBuilder().buildReadme(
            repoId: 1,
            markdown: "# Payload\n" + String(repeating: "x", count: 40_000)
        )
        let chunk = try #require(chunks.first)
        #expect(chunk.isTruncated)
        #expect(chunk.tokenCount <= RAGChunkingConfiguration.default.hardMaximumTokens)
        #expect(chunk.content.contains("content truncated by Starcat RAG"))
    }

    @Test("README 独立 Markdown 图片不进入检索正文")
    func standaloneMarkdownImagesAreRemoved() throws {
        let chunks = RAGChunkBuilder().buildReadme(repoId: 1, markdown: """
            # Preview

            ![Product screenshot](https://example.com/screenshot.png)

            The workspace supports repository comparison.
            """)
        let chunk = try #require(chunks.first)
        #expect(!chunk.content.contains("screenshot.png"))
        #expect(chunk.content.contains("repository comparison"))
    }

    private func fixtureRepo(stars: Int) -> Repo {
        Repo(
            id: 1,
            owner: "octo",
            name: "demo",
            fullName: "octo/demo",
            description: "Demo database",
            language: "Swift",
            starsCount: stars,
            forksCount: 120,
            watchersCount: 10,
            topics: "[\"database\",\"swift\"]",
            license: "MIT",
            homepage: "https://example.com/demo",
            htmlUrl: "https://github.com/octo/demo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: "2026-07-10T00:00:00Z",
            starredAt: nil,
            cachedAt: nil,
            defaultBranch: "main",
            openIssuesCount: 7
        )
    }
}
