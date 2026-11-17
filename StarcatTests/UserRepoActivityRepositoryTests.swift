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
        let page = try await env.activity.fetchPage(filter: .all, cursor: nil, limit: 10)
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

        let first = try await env.activity.fetchPage(filter: .all, cursor: nil, limit: 2)
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
            filter: .all,
            cursor: first.rows.last?.cursor,
            limit: 2
        )
        #expect(!second.hasMore)
        #expect(second.rows.map(\.id) == ["n-old"])

        let unread = try await env.activity.fetchPage(filter: .init(readState: .unread), cursor: nil, limit: 10)
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

        let stars = try await env.activity.fetchPage(filter: .init(eventTypes: [.star]), cursor: nil, limit: 10)
        #expect(stars.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .star,
                source: .starcat,
                repoID: 1,
                occurredAt: "2026-08-19T12:00:00Z"
            )
        ])

        let unstars = try await env.activity.fetchPage(filter: .init(eventTypes: [.unstar]), cursor: nil, limit: 10)
        #expect(unstars.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .unstar,
                source: .starcat,
                repoID: 1,
                occurredAt: "2026-08-19T13:00:00Z"
            )
        ])

        let forks = try await env.activity.fetchPage(filter: .init(eventTypes: [.fork]), cursor: nil, limit: 10)
        #expect(forks.rows.map(\.id) == [
            UserRepoActivityRecord.makeID(
                kind: .fork,
                source: .githubSync,
                repoID: 2,
                occurredAt: "2026-08-19T11:00:00Z"
            )
        ])

        let mention = try await env.activity.fetchPage(filter: .init(reasons: [.mention]), cursor: nil, limit: 10)
        #expect(mention.rows.map(\.id) == ["n-1"])
        let issues = try await env.activity.fetchPage(filter: .init(eventTypes: [.issue]), cursor: nil, limit: 10)
        #expect(issues.rows.map(\.id) == ["n-1"])
        let pulls = try await env.activity.fetchPage(filter: .init(eventTypes: [.pullRequest]), cursor: nil, limit: 10)
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
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-disc", updatedAt: "2026-08-19T13:00:00Z", type: "Discussion"),
                fetchedAt: "2026-08-19T16:00:00Z",
                firstSeenAt: "2026-08-19T16:00:00Z"
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n-rel", updatedAt: "2026-08-19T12:00:00Z", type: "Release"),
                fetchedAt: "2026-08-19T16:00:00Z",
                firstSeenAt: "2026-08-19T16:00:00Z"
            )
        ])

        let issues = try await env.activity.fetchPage(filter: .init(eventTypes: [.issue]), cursor: nil, limit: 10)
        #expect(issues.rows.map(\.id) == ["n-issue"])
        #expect(issues.rows.allSatisfy {
            if case .notification = $0 { return true }
            return false
        })

        let pulls = try await env.activity.fetchPage(filter: .init(eventTypes: [.pullRequest]), cursor: nil, limit: 10)
        #expect(pulls.rows.map(\.id) == ["n-pr"])
        #expect(pulls.rows.allSatisfy {
            if case .notification = $0 { return true }
            return false
        })

        let discussions = try await env.activity.fetchPage(filter: .init(eventTypes: [.discussion]), cursor: nil, limit: 10)
        #expect(discussions.rows.map(\.id) == ["n-disc"])
        let releases = try await env.activity.fetchPage(filter: .init(eventTypes: [.release]), cursor: nil, limit: 10)
        #expect(releases.rows.map(\.id) == ["n-rel"])
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
        let page = try await env.activity.fetchPage(filter: .init(eventTypes: [.star]), cursor: nil, limit: 1)
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
        let stamped = try await env.activity.fetchPage(filter: .init(eventTypes: [.star]), cursor: nil, limit: 1)
        guard case .activity(let restored) = stamped.rows.first else {
            Issue.record("回填后仍应有 star 账本行")
            return
        }
        #expect(restored.record.userId == 1)
        #expect(restored.record.userName == "tester")
    }

    @Test("事件与原因组内 OR，跨组 AND；先筛选再分页与计数")
    func combinedNotificationFiltersAndPagination() async throws {
        let env = try makeEnv()
        try await env.threads.upsertMany([
            Self.makeThread(id: "match-z", type: "Issue", reason: "team_mention"),
            Self.makeThread(id: "match-m", type: "PullRequest", reason: "review_requested"),
            Self.makeThread(id: "match-a", type: "PullRequest", reason: "review_submitted"),
            Self.makeThread(id: "skip-reason", type: "Issue", reason: "comment"),
            Self.makeThread(id: "skip-read", type: "Issue", unread: false),
            Self.makeThread(id: "skip-type", type: "Discussion")
        ])
        let filter = GitHubNotificationFilter(
            eventTypes: [.issue, .pullRequest], readState: .unread, reasons: [.mention, .review]
        )
        let first = try await env.activity.fetchPage(filter: filter, cursor: nil, limit: 2)
        #expect(first.rows.map(\.id) == ["match-z", "match-m"])
        #expect(first.hasMore)
        let second = try await env.activity.fetchPage(filter: filter, cursor: first.rows.last?.cursor, limit: 2)
        #expect(second.rows.map(\.id) == ["match-a"])
        #expect(!second.hasMore)
        #expect(try await env.activity.timelineCount(filter: filter) == 3)
        #expect(try await env.activity.adjacentNotificationID(after: "match-z", delta: 1, filter: filter) == "match-m")
        #expect(try await env.activity.adjacentNotificationID(after: "match-a", delta: -1, filter: filter) == "match-m")
        #expect(try await env.activity.adjacentNotificationID(after: "match-a", delta: 1, filter: filter) == nil)
    }

    @Test("入库条件同时筛通知和账本，通知支持 fullName 回退与无缓存项目")
    func libraryFiltersAcrossSources() async throws {
        let env = try makeEnv()
        let inRepo = try await env.seedStarredRepo(id: 11, name: "in-lib", starredAt: Self.filterTime)
        let outRepo = try await env.seedStarredRepo(id: 12, name: "out-lib", starredAt: Self.filterTime)
        try await GRDBRepoNoteRepository(database: env.db).updateLibraryState(repoId: inRepo.id, state: .inLibrary)
        try await env.activity.recordStar(repo: inRepo, source: .starcat, actor: Self.actor, occurredAt: Self.filterTime)
        try await env.activity.recordStar(repo: outRepo, source: .starcat, actor: Self.actor, occurredAt: Self.filterTime)
        try await env.activity.recordFork(repo: outRepo, source: .starcat, actor: Self.actor, occurredAt: Self.filterTime)
        try await env.threads.upsertMany([
            Self.makeThread(id: "n-in", repositoryID: 999, fullName: inRepo.fullName.uppercased()),
            Self.makeThread(id: "n-out", repositoryID: outRepo.id, fullName: outRepo.fullName),
            Self.makeThread(id: "n-uncached", repositoryID: 998, fullName: "other/missing")
        ])
        let outside = GitHubNotificationFilter(eventTypes: [.issue, .star, .fork], libraryState: .outsideLibrary)
        var collected: [String] = []
        var cursor: GitHubInboxTimelineCursor?
        var hasMore = true
        while hasMore {
            let page = try await env.activity.fetchPage(filter: outside, cursor: cursor, limit: 2)
            collected.append(contentsOf: page.rows.map(\.id))
            cursor = page.rows.last?.cursor
            hasMore = page.hasMore
        }
        #expect(collected.count == 4)
        #expect(Set(collected).count == 4)
        #expect(collected.contains("n-out"))
        #expect(collected.contains("n-uncached"))
        #expect(!collected.contains("n-in"))
        #expect(try await env.activity.timelineCount(filter: outside) == 4)
        let inside = GitHubNotificationFilter(eventTypes: [.issue, .star, .fork], libraryState: .inLibrary)
        let page = try await env.activity.fetchPage(filter: inside, cursor: nil, limit: 10)
        #expect(page.rows.count == 2)
        #expect(page.rows.contains { $0.id == "n-in" })
        #expect(try await env.activity.timelineCount(filter: inside) == 2)
    }

    @Test("已合并 PR 与入库取交集，矛盾组合返回空而非忽略条件")
    func combinedIssueStateAndContradictions() async throws {
        let env = try makeEnv()
        let repo = try await env.seedStarredRepo(id: 1, name: "in-lib", starredAt: Self.filterTime)
        try await GRDBRepoNoteRepository(database: env.db).updateLibraryState(repoId: repo.id, state: .inLibrary)
        try await env.activity.recordStar(repo: repo, source: .starcat, actor: Self.actor, occurredAt: Self.filterTime)
        try await env.threads.upsertMany([
            Self.makeThread(id: "merged", type: "PullRequest", state: "merged"),
            Self.makeThread(id: "closed", type: "PullRequest", state: "closed"),
            Self.makeThread(id: "unknown", type: "PullRequest"),
            Self.makeThread(id: "release", type: "Release", state: "merged"),
            Self.makeThread(id: "outside", type: "PullRequest", repositoryID: 2, state: "merged")
        ])
        let filter = GitHubNotificationFilter(eventTypes: [.pullRequest], issueState: .merged, libraryState: .inLibrary)
        #expect(try await env.activity.fetchPage(filter: filter, cursor: nil, limit: 10).rows.map(\.id) == ["merged"])
        for impossible in [
            GitHubNotificationFilter(eventTypes: [.star], readState: .unread),
            GitHubNotificationFilter(eventTypes: [.star], reasons: [.mention]),
            GitHubNotificationFilter(eventTypes: [.star], issueState: .open),
            GitHubNotificationFilter(eventTypes: [.release], issueState: .merged)
        ] {
            let page = try await env.activity.fetchPage(filter: impossible, cursor: nil, limit: 10)
            #expect(page.rows.isEmpty)
            #expect(!page.hasMore)
            #expect(try await env.activity.timelineCount(filter: impossible) == 0)
        }
    }

    @Test("详情导航越过 300 条不匹配通知，仍遵循全部组合条件")
    func navigationBeyondCachedWindow() async throws {
        let env = try makeEnv()
        var records = (0..<305).map { index in
            Self.makeThread(id: String(format: "n-%03d", index), reason: "comment")
        }
        records.append(Self.makeThread(id: "z-newest"))
        records.append(Self.makeThread(id: "a-oldest"))
        try await env.threads.upsertMany(records)
        let filter = GitHubNotificationFilter(eventTypes: [.issue], readState: .unread, reasons: [.mention])
        #expect(try await env.activity.adjacentNotificationID(after: "z-newest", delta: 1, filter: filter) == "a-oldest")
        #expect(try await env.activity.adjacentNotificationID(after: "a-oldest", delta: -1, filter: filter) == "z-newest")
        #expect(try await env.activity.timelineCount(filter: filter) == 2)
    }

    // MARK: - Harness

    private static let filterTime = "2026-11-17T10:00:00Z"

    /// 使用相同时间检验 id 游标，同时允许明确构造每个筛选维度。
    private static func makeThread(
        id: String,
        type: String = "Issue",
        reason: String = "mention",
        unread: Bool = true,
        repositoryID: Int64 = 1,
        fullName: String = "o/r",
        state: String? = nil
    ) -> GitHubNotificationThreadRecord {
        var record = GitHubNotificationMapper.record(
            from: makeDTO(id: id, updatedAt: filterTime, type: type),
            fetchedAt: filterTime, firstSeenAt: filterTime
        )
        record.reason = reason
        record.unread = unread
        record.repositoryId = repositoryID
        record.repositoryFullName = fullName
        record.issueState = state
        return record
    }

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
        let subjectURL: String
        switch type {
        case "PullRequest":
            subjectURL = "https://api.github.com/repos/o/r/pulls/2"
        case "Discussion":
            subjectURL = "https://api.github.com/repos/o/r/discussions/3"
        case "Release":
            subjectURL = "https://api.github.com/repos/o/r/releases/4"
        default:
            subjectURL = "https://api.github.com/repos/o/r/issues/1"
        }
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
