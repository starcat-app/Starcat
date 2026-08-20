//
//  UserRepoActivityRepositoryTests.swift
//  StarcatTests
//
//  当前用户 Star / Unstar / Fork 账本：去重、追加、通知时间线 UNION 游标翻页。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("UserRepoActivityRepository")
struct UserRepoActivityRepositoryTests {

    @Test("v24 建 user_repo_activity 表")
    func migrationCreatesTable() throws {
        let db = try InMemoryDatabaseManager()
        try db.writer.read { db in
            #expect(try db.tableExists("user_repo_activity"))
            let columns = try db.columns(in: "user_repo_activity").map(\.name)
            #expect(columns.contains("kind"))
            #expect(columns.contains("source"))
            #expect(columns.contains("occurred_at"))
            #expect(columns.contains("user_id"))
            #expect(columns.contains("user_name"))
        }
    }

    @Test("最新已是 star 时，同步再写 github_sync 不插第二行")
    func starThenSyncDoesNotDuplicate() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 42, name: "hello", starredAt: "2026-08-19T12:00:00Z")

        try await env.activity.recordStar(
            repo: repo,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T12:05:00Z"
        )
        try await env.activity.recordSyncedStars(
            [
                UserRepoActivityStarDraft(
                    repoID: repo.id,
                    fullName: repo.fullName,
                    htmlURL: repo.htmlUrl,
                    occurredAt: "2026-08-19T12:00:00Z"
                )
            ],
            actor: Self.actor
        )

        #expect(try await env.activity.count() == 1)
    }

    @Test("Unstar 后再 Star 会追加两行不同 kind")
    func unstarThenStarAppends() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 7, name: "tool", starredAt: "2026-08-19T10:00:00Z")

        try await env.activity.recordStar(
            repo: repo,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T10:00:00Z"
        )
        try await env.activity.recordUnstar(
            repoID: repo.id,
            fullName: repo.fullName,
            htmlURL: repo.htmlUrl,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T11:00:00Z"
        )
        try await env.activity.recordStar(
            repo: repo,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T12:00:00Z"
        )

        #expect(try await env.activity.count() == 3)
        let page = try await env.activity.fetchPage(segment: .all, cursor: nil, limit: 10)
        let kinds = page.rows.compactMap { row -> String? in
            if case .activity(let item) = row { return item.record.kind.rawValue }
            return nil
        }
        #expect(kinds == ["star", "unstar", "star"])
    }

    @Test("全部时间线 UNION 按时间倒序翻页；未读分段不含账本")
    func unionPageOrdersAndUnreadSkipsLedger() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 42, name: "hello", starredAt: "2026-08-19T12:00:00Z")
        try await env.activity.recordStar(
            repo: repo,
            source: .githubSync,
            actor: Self.actor,
            occurredAt: "2026-08-19T12:00:00Z"
        )
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-mid", updatedAt: "2026-08-19T10:00:00Z"),
                fetchedAt: "2026-08-19T13:00:00Z",
                firstSeenAt: "2026-08-19T13:00:00Z"
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-old", updatedAt: "2026-08-19T08:00:00Z"),
                fetchedAt: "2026-08-19T13:00:00Z",
                firstSeenAt: "2026-08-19T13:00:00Z"
            )
        ])

        let first = try await env.activity.fetchPage(segment: .all, cursor: nil, limit: 2)
        #expect(first.hasMore)
        #expect(first.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .star,
                source: .githubSync,
                repoID: 42,
                occurredAt: "2026-08-19T12:00:00Z"
            ),
            "n-mid"
        ])

        let second = try await env.activity.fetchPage(
            segment: .all,
            cursor: first.rows.last?.cursor,
            limit: 2
        )
        #expect(!second.hasMore)
        #expect(second.rows.map(\.id) == ["n-old"])

        let unread = try await env.activity.fetchPage(segment: .unread, cursor: nil, limit: 10)
        #expect(unread.rows.allSatisfy {
            if case .notification = $0 { return true }
            return false
        })
        #expect(unread.rows.map(\.id) == ["n-mid", "n-old"])
    }

    @Test("Star / Unstar / Fork 分段只含对应账本行，不含 GitHub 通知")
    func ledgerSegmentsFilterByKind() async throws {
        let env = try makeEnv()
        let starred = try await env.seedStarredRepo(id: 1, name: "starred", starredAt: "2026-08-19T12:00:00Z")
        let forked = try await env.seedStarredRepo(id: 2, name: "forked", starredAt: "2026-08-19T11:00:00Z")
        try await env.activity.recordStar(
            repo: starred,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T12:00:00Z"
        )
        try await env.activity.recordUnstar(
            repoID: starred.id,
            fullName: starred.fullName,
            htmlURL: starred.htmlUrl,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T13:00:00Z"
        )
        try await env.activity.recordFork(
            repo: forked,
            source: .githubSync,
            actor: Self.actor,
            occurredAt: "2026-08-19T11:00:00Z"
        )
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-1", updatedAt: "2026-08-19T14:00:00Z"),
                fetchedAt: "2026-08-19T15:00:00Z",
                firstSeenAt: "2026-08-19T15:00:00Z"
            )
        ])

        let stars = try await env.activity.fetchPage(segment: .star, cursor: nil, limit: 10)
        #expect(stars.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .star,
                source: .starcat,
                repoID: 1,
                occurredAt: "2026-08-19T12:00:00Z"
            )
        ])

        let unstars = try await env.activity.fetchPage(segment: .unstar, cursor: nil, limit: 10)
        #expect(unstars.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .unstar,
                source: .starcat,
                repoID: 1,
                occurredAt: "2026-08-19T13:00:00Z"
            )
        ])

        let forks = try await env.activity.fetchPage(segment: .fork, cursor: nil, limit: 10)
        #expect(forks.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .fork,
                source: .githubSync,
                repoID: 2,
                occurredAt: "2026-08-19T11:00:00Z"
            )
        ])

        let mention = try await env.activity.fetchPage(segment: .mention, cursor: nil, limit: 10)
        #expect(mention.rows.map(\.id) == ["n-1"])
        let issues = try await env.activity.fetchPage(segment: .issue, cursor: nil, limit: 10)
        #expect(issues.rows.map(\.id) == ["n-1"])
        let pulls = try await env.activity.fetchPage(segment: .pullRequest, cursor: nil, limit: 10)
        #expect(pulls.rows.isEmpty)
        if case .notification(_, let language) = mention.rows.first {
            #expect(language == "Swift")
        } else {
            Issue.record("mention 行应带上本地仓库语言")
        }

        if case .activity(let item) = stars.rows.first {
            #expect(item.language == "Swift")
        } else {
            Issue.record("Star 账本行应带上本地仓库语言")
        }
    }

    @Test("Issue / PR 分段按 subject_type 只含对应 GitHub 通知，不含账本")
    func subjectTypeSegmentsFilterNotifications() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 1, name: "starred", starredAt: "2026-08-19T12:00:00Z")
        try await env.activity.recordStar(
            repo: repo,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T16:00:00Z"
        )
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-issue", updatedAt: "2026-08-19T15:00:00Z", type: "Issue"),
                fetchedAt: "2026-08-19T16:00:00Z",
                firstSeenAt: "2026-08-19T16:00:00Z"
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-pr", updatedAt: "2026-08-19T14:00:00Z", type: "PullRequest"),
                fetchedAt: "2026-08-19T16:00:00Z",
                firstSeenAt: "2026-08-19T16:00:00Z"
            )
        ])

        let issues = try await env.activity.fetchPage(segment: .issue, cursor: nil, limit: 10)
        #expect(issues.rows.map(\.id) == ["n-issue"])
        #expect(issues.rows.allSatisfy {
            if case .notification = $0 { return true }
            return false
        })

        let pulls = try await env.activity.fetchPage(segment: .pullRequest, cursor: nil, limit: 10)
        #expect(pulls.rows.map(\.id) == ["n-pr"])
        #expect(pulls.rows.allSatisfy {
            if case .notification = $0 { return true }
            return false
        })
    }

    @Test("账本写入 user_id / user_name，回填能补 v24 空身份")
    func storesActorAndBackfillStampsLegacyRows() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 42, name: "hello", starredAt: "2026-08-19T12:00:00Z")
        try await env.activity.recordStar(
            repo: repo,
            source: .starcat,
            actor: Self.actor,
            occurredAt: "2026-08-19T12:05:00Z"
        )
        let page = try await env.activity.fetchPage(segment: .star, cursor: nil, limit: 1)
        guard case .activity(let item) = page.rows.first else {
            Issue.record("应有 star 账本行")
            return
        }
        #expect(item.record.userId == 1)
        #expect(item.record.userName == "tester")

        try await env.db.writer.write { db in
            try db.execute(sql: "UPDATE user_repo_activity SET user_id = NULL, user_name = NULL")
        }
        try await env.activity.backfillFromLocalCaches(actor: Self.actor)
        let stamped = try await env.activity.fetchPage(segment: .star, cursor: nil, limit: 1)
        guard case .activity(let restored) = stamped.rows.first else {
            Issue.record("回填后仍应有 star 账本行")
            return
        }
        #expect(restored.record.userId == 1)
        #expect(restored.record.userName == "tester")
    }

    // MARK: - Harness

    private struct Env {
        let db: InMemoryDatabaseManager
        let repos: GRDBRepoRepository
        let threads: GRDBGitHubNotificationThreadRepository
        let activity: GRDBUserRepoActivityRepository

        func seedStarredRepo(id: Int64, name: String, starredAt: String) async throws -> Repo {
            try await repos.upsertStarred(
                [Self.makeStarredDTO(id: id, name: name, starredAt: starredAt)],
                userID: 1,
                syncedAt: Date()
            )
            let repo = try #require(try await repos.findById(id))
            return repo
        }

        private static func makeStarredDTO(id: Int64, name: String, starredAt: String) -> StarredRepoDTO {
            UserRepoActivityRepositoryTests.makeStarredDTO(id: id, name: name, starredAt: starredAt)
        }
    }

    private func makeEnv() throws -> Env {
        let db = try InMemoryDatabaseManager()
        return Env(
            db: db,
            repos: GRDBRepoRepository(database: db),
            threads: GRDBGitHubNotificationThreadRepository(database: db),
            activity: GRDBUserRepoActivityRepository(database: db)
        )
    }

    private static let actor = UserRepoActivityActor(userID: 1, userName: "tester")

    private static func makeStarredDTO(id: Int64, name: String, starredAt: String) -> StarredRepoDTO {
        let user = GitHubUserDTO(
            id: 1,
            login: "tester",
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
        let repo = GitHubRepoDTO(
            id: id,
            name: name,
            fullName: "tester/\(name)",
            owner: user,
            description: "desc \(name)",
            language: "Swift",
            stargazersCount: 10,
            forksCount: 1,
            watchersCount: 2,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tester/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: starredAt,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: starredAt, repo: repo)
    }

    private static func makeDTO(
        id: String,
        updatedAt: String,
        type: String = "Issue"
    ) -> GitHubNotificationThreadDTO {
        let subjectURL = type == "PullRequest"
            ? "https://api.github.com/repos/o/r/pulls/2"
            : "https://api.github.com/repos/o/r/issues/1"
        return GitHubNotificationThreadDTO(
            id: id,
            unread: true,
            reason: "mention",
            updatedAt: updatedAt,
            subject: GitHubNotificationSubjectDTO(
                title: "\(type) \(id)",
                url: subjectURL,
                latestCommentUrl: nil,
                type: type
            ),
            repository: GitHubNotificationRepositoryDTO(
                id: 1,
                fullName: "o/r",
                name: "r",
                owner: GitHubNotificationOwnerDTO(login: "o")
            )
        )
    }
}
