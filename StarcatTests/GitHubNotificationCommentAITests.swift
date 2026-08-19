//
//  GitHubNotificationCommentAITests.swift
//  StarcatTests
//
//  GitHub 通知 AI 评论：输出语言跟帖子走、截断保开帖和近评、空箱 vs 润色、关 thinking。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub 通知 AI 评论")
struct GitHubNotificationCommentAITests {

    @Test("输出语言跟帖子走，不跟中文草稿走")
    func outputLanguageFollowsThreadNotDraft() {
        let english = GitHubNotificationCommentAI.pack(
            title: "Please review the cache invalidation",
            payload: makePayload(
                excerpt: "The cache still returns stale README after a force push. Please take a look."
            ),
            repo: nil,
            summaryMarkdown: nil,
            currentUserLogin: "dong4j",
            draft: "我觉得应该先清缓存再重试。"
        )
        #expect(english.outputLanguage == "English")

        let chinese = GitHubNotificationCommentAI.pack(
            title: "请帮忙看一下缓存失效",
            payload: makePayload(
                excerpt: "强制推送之后 README 缓存还是旧的，麻烦看一下。"
            ),
            repo: nil,
            summaryMarkdown: nil,
            currentUserLogin: "dong4j",
            draft: "Looks fine to me."
        )
        #expect(chinese.outputLanguage == "Simplified Chinese")
    }

    @Test("超过 15 条时旧评论只留作者和 200 字预览，最近评论保留全文")
    func truncatesOlderCommentsAndKeepsRecentBodies() {
        let longBody = String(repeating: "x", count: 300)
        let comments = (1...20).map { index in
            GitHubNotificationComment(
                id: Int64(index),
                login: "user\(index)",
                body: "comment-\(index)-\(longBody)",
                htmlURL: nil,
                createdAt: nil
            )
        }
        let pack = GitHubNotificationCommentAI.pack(
            title: "Keep recent comments",
            payload: makePayload(
                excerpt: "Opening post about notification comments.",
                comments: comments
            ),
            repo: nil,
            summaryMarkdown: nil,
            currentUserLogin: "dong4j",
            draft: ""
        )

        #expect(pack.thread.contains("- @user1: comment-1-"))
        #expect(pack.thread.contains("…"))
        #expect(!pack.thread.contains("comment-1-\(longBody)"))
        #expect(pack.thread.contains("comment-20-\(longBody)"))
        #expect(pack.thread.contains("Opening post about notification comments."))
    }

    @Test("空箱写新评论，有草稿则润色并翻译意图")
    func emptyDraftWritesNewCommentAndExistingDraftPolishes() {
        let empty = GitHubNotificationCommentAI.makeRequest(
            pack: GitHubNotificationCommentAI.pack(
                title: "Please review",
                payload: makePayload(excerpt: "Please take a look at this issue."),
                repo: nil,
                summaryMarkdown: nil,
                currentUserLogin: "dong4j",
                draft: "   "
            ),
            model: "test-model",
            parameters: .summaryDefault
        )
        #expect(empty.userPrompt.contains("Write a new comment that fits the thread"))
        #expect(empty.userPrompt.contains("(empty)"))
        #expect(empty.disableThinking)
        #expect(empty.usageContext?.feature == .repoChat)
        #expect(empty.usageContext?.phase == "github_comment")
        #expect(empty.systemPrompt.contains("Do NOT output reasoning"))

        let polish = GitHubNotificationCommentAI.makeRequest(
            pack: GitHubNotificationCommentAI.pack(
                title: "Please review",
                payload: makePayload(excerpt: "Please take a look at this issue."),
                repo: nil,
                summaryMarkdown: nil,
                currentUserLogin: "dong4j",
                draft: "先看缓存。"
            ),
            model: "test-model",
            parameters: .summaryDefault
        )
        #expect(polish.userPrompt.contains("The user already started a draft"))
        #expect(polish.userPrompt.contains("先看缓存。"))
        #expect(!polish.userPrompt.contains("(empty)"))
        #expect(polish.disableThinking)
    }

    @Test("上下文带上仓库描述、语言、缓存摘要和当前用户")
    func packIncludesRepoFactsAndCurrentUser() {
        let pack = GitHubNotificationCommentAI.pack(
            title: "Cache bug",
            payload: makePayload(excerpt: "README is stale."),
            repo: Repo(
                id: 1,
                owner: "octo",
                name: "hello",
                fullName: "octo/hello",
                description: "A local-first GitHub star manager",
                language: "Swift",
                starsCount: 0,
                forksCount: 0,
                watchersCount: 0,
                topics: nil,
                license: nil,
                homepage: nil,
                htmlUrl: "https://github.com/octo/hello",
                cloneUrl: nil,
                sshUrl: nil,
                isPrivate: false,
                isFork: false,
                isArchived: false,
                isStarred: true,
                pushedAt: nil,
                createdAt: nil,
                updatedAt: nil,
                starredAt: nil,
                cachedAt: nil
            ),
            summaryMarkdown: "Keeps starred repos searchable.",
            currentUserLogin: "dong4j",
            draft: ""
        )

        #expect(pack.currentUserLogin == "dong4j")
        #expect(pack.thread.contains("Primary language: Swift"))
        #expect(pack.thread.contains("A local-first GitHub star manager"))
        #expect(pack.thread.contains("Cached AI summary: Keeps starred repos searchable."))
        #expect(pack.thread.contains("Notification reason: mention"))
    }

    @Test("sanitize 去掉整篇外层代码围栏")
    func sanitizeStripsOuterFence() {
        let raw = """
        ```markdown
        Looks good to me.
        ```
        """
        #expect(GitHubNotificationCommentAI.sanitizeComment(raw) == "Looks good to me.")
    }

    private func makePayload(
        excerpt: String?,
        comments: [GitHubNotificationComment] = []
    ) -> ActivityNotificationPayload {
        ActivityNotificationPayload(
            threadId: "1",
            reason: "mention",
            chip: .mention,
            subjectType: "Issue",
            subjectNumber: 12,
            repositoryFullName: "octo/hello",
            actorLogin: "reviewer",
            authorLogin: "octocat",
            authorCreatedAt: nil,
            excerpt: excerpt,
            comments: comments,
            people: []
        )
    }
}
