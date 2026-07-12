//
//  RAGChunkBuilderTests.swift
//  StarcatTests
//
//  验证 README 结构切分、稳定 key、代码块 / 表格保护及多来源输入。
//

import Testing
@testable import Starcat

@Suite("RAGChunkBuilder")
struct RAGChunkBuilderTests {
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

    @Test("metadata 包含基础信息并对波动数字分桶")
    func metadataIncludesRepoFacts() {
        let repo = fixtureRepo(stars: 12_345)
        let chunks = RAGChunkBuilder().buildMetadata(repo: repo, note: nil, tags: ["database", "swift"])
        let content = chunks[0].content
        #expect(content.contains("Repository: octo/demo"))
        #expect(content.contains("Stars bucket: 12000-12999"))
        #expect(content.contains("Tags: database, swift"))
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
            homepage: nil,
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
            cachedAt: nil
        )
    }
}
