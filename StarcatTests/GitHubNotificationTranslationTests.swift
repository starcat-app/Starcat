//
//  GitHubNotificationTranslationTests.swift
//  StarcatTests
//
//  通知详情翻译：Markdown 按块切开、代码围栏不送 AI、缓存路径与 README 隔离。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubNotificationTranslation")
struct GitHubNotificationTranslationTests {

    @Test("空行切开段落，围栏代码保持整块")
    func splitKeepsFencedCodeAtomic() {
        let markdown = """
        Hello world.

        ```swift
        let x = 1

        let y = 2
        ```

        Second paragraph.
        """
        let blocks = GitHubNotificationTranslation.splitBlocks(markdown)
        #expect(blocks.count == 3)
        #expect(blocks[0] == "Hello world.")
        #expect(blocks[1].hasPrefix("```swift"))
        #expect(blocks[1].hasSuffix("```"))
        #expect(blocks[1].contains("let y = 2"))
        #expect(blocks[2] == "Second paragraph.")
    }

    @Test("代码围栏不进翻译段落")
    func fencedCodeIsNotTranslatable() {
        let markdown = """
        Intro text.

        ```
        npm install
        ```
        """
        let document = GitHubNotificationTranslation.makeDocument(
            opening: markdown,
            comments: []
        )
        #expect(document.segments.count == 1)
        #expect(document.segments[0].id == "o:0")
        #expect(document.segments[0].text == "Intro text.")
    }

    @Test("开贴和评论各自编号，拼成一份文档指纹")
    func openingAndCommentsGetDistinctSegmentIds() {
        let comments = [
            GitHubNotificationComment(
                id: 9,
                login: "octo",
                body: "First comment.\n\nSecond line of comment.",
                htmlURL: nil,
                createdAt: nil
            )
        ]
        let document = GitHubNotificationTranslation.makeDocument(
            opening: "Issue body.",
            comments: comments
        )
        #expect(document.segments.map(\.id) == ["o:0", "c:9:0", "c:9:1"])
        #expect(document.sourceText.contains("Issue body."))
        #expect(document.sourceText.contains("First comment."))
        #expect(document.blocks.filter { $0.kind == .opening }.count == 1)
        #expect(document.blocks.filter { $0.kind == .comment(id: 9) }.count == 2)
    }

    @Test("inbox 缓存路径不占用真实 owner/repo")
    func inboxCacheKeyDoesNotUseGitHubRepo() {
        #expect(GitHubNotificationTranslation.cacheOwner == "_starcat-inbox")
        #expect(GitHubNotificationTranslation.cacheRepo(threadId: "12345") == "12345")
        #expect(GitHubNotificationTranslation.cacheRepo(threadId: "a/b") == "a-b")
        #expect(GitHubNotificationTranslation.cacheRepo(threadId: ".") == "unknown")
        #expect(GitHubNotificationTranslation.cacheRepo(threadId: "  ") == "unknown")
        #expect(GitHubNotificationTranslation.identity(threadId: "12345") == "inbox:12345")
    }
}

@MainActor
@Suite("GitHubNotificationTranslation cache isolation")
struct GitHubNotificationTranslationCacheTests {

    @Test("写入 inbox 译文不会覆盖同名仓库 README 缓存")
    func inboxUpsertDoesNotClobberReadmeCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-inbox-translation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DiskReadmeTranslationCache(rootOverride: root)

        let readme = ReadmeTranslation(
            repoId: 1,
            targetLanguage: "zh-Hans",
            model: "test",
            sourceHash: "readme-hash",
            segments: [
                ReadmeTranslatedSegment(sourceHash: "seg-readme", translatedText: "README 译文")
            ],
            isComplete: true,
            size: 12,
            createdAt: "2026-08-20T00:00:00Z"
        )
        try await cache.upsert(readme, owner: "Mubelotix", repo: "SimRepo")

        let inbox = ReadmeTranslation(
            repoId: nil,
            targetLanguage: "zh-Hans",
            model: "test",
            sourceHash: "inbox-hash",
            segments: [
                ReadmeTranslatedSegment(sourceHash: "seg-inbox", translatedText: "Issue 译文")
            ],
            isComplete: true,
            size: 11,
            createdAt: "2026-08-20T00:00:00Z"
        )
        try await cache.upsert(
            inbox,
            owner: GitHubNotificationTranslation.cacheOwner,
            repo: GitHubNotificationTranslation.cacheRepo(threadId: "999")
        )

        let readmeHit = try #require(
            try await cache.find(owner: "Mubelotix", repo: "SimRepo", targetLanguage: "zh-Hans")
        )
        #expect(readmeHit.segments.first?.translatedText == "README 译文")

        let inboxHit = try #require(
            try await cache.find(
                owner: GitHubNotificationTranslation.cacheOwner,
                repo: GitHubNotificationTranslation.cacheRepo(threadId: "999"),
                targetLanguage: "zh-Hans"
            )
        )
        #expect(inboxHit.segments.first?.translatedText == "Issue 译文")
    }
}
