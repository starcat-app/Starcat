//
//  GitHubNotificationInboxTests.swift
//  StarcatTests
//
//  通知 inbox：解析、回填 300、水位、已读 dwell、hydrate、403 缺 scope。
//

import Foundation
import Testing
import UserNotifications
import os.lock
@testable import Starcat

@Suite("GitHubNotificationMapper")
struct GitHubNotificationMapperTests {

    @Test("reason 映射到 chip")
    func chipMapping() {
        #expect(GitHubNotificationMapper.chip(forReason: "mention") == .mention)
        #expect(GitHubNotificationMapper.chip(forReason: "team_mention") == .mention)
        #expect(GitHubNotificationMapper.chip(forReason: "review_requested") == .review)
        #expect(GitHubNotificationMapper.chip(forReason: "assign") == .assign)
        #expect(GitHubNotificationMapper.chip(forReason: "security_alert") == .security)
        #expect(GitHubNotificationMapper.chip(forReason: "comment") == .comment)
    }

    @Test("subject.url 解析 number 并生成降级 GitHub Web URL")
    func fallbackHTMLURL() {
        let issue = "https://api.github.com/repos/octo/hello/issues/12"
        #expect(GitHubNotificationMapper.subjectNumber(fromApiURL: issue) == 12)
        #expect(
            GitHubNotificationMapper.fallbackHTMLURL(
                fullName: "octo/hello",
                subjectType: "Issue",
                apiURL: issue
            ) == "https://github.com/octo/hello/issues/12"
        )
        #expect(
            GitHubNotificationMapper.fallbackHTMLURL(
                fullName: "octo/hello",
                subjectType: "PullRequest",
                apiURL: "https://api.github.com/repos/octo/hello/pulls/9"
            ) == "https://github.com/octo/hello/pull/9"
        )
    }

    @Test("时间线次行拼 full_name · PR #n · 相对时间")
    func timelineCaption() {
        #expect(
            GitHubNotificationMapper.timelineCaption(
                fullName: "octo/hello",
                subjectType: "PullRequest",
                number: 9,
                relativeTime: "2 小时前"
            ) == "octo/hello · PR #9 · 2 小时前"
        )
        #expect(
            GitHubNotificationMapper.timelineCaption(
                fullName: "octo/hello",
                subjectType: "Release",
                number: nil,
                relativeTime: "昨天"
            ) == "octo/hello · 昨天"
        )
    }

    @Test("正文入库不截断；Issue / PR 评论走 issues comments path")
    func bodyMarkdownAndCommentsPath() {
        let long = String(repeating: "a", count: 800)
        #expect(GitHubNotificationMapper.bodyMarkdown(long) == long)
        #expect(
            GitHubNotificationMapper.issueCommentsPath(
                subjectType: "Issue",
                subjectApiURL: "https://api.github.com/repos/o/r/issues/30"
            ) == "/repos/o/r/issues/30/comments"
        )
        #expect(
            GitHubNotificationMapper.issueCommentsPath(
                subjectType: "PullRequest",
                subjectApiURL: "https://api.github.com/repos/o/r/pulls/9"
            ) == "/repos/o/r/issues/9/comments"
        )
        #expect(
            GitHubNotificationMapper.issueCommentsPath(
                subjectType: "Release",
                subjectApiURL: "https://api.github.com/repos/o/r/releases/1"
            ) == nil
        )
    }

    @Test("列表摘录把 markdown 链接收成可见文字")
    func listSnippetStripsLinks() {
        #expect(
            GitHubNotificationMapper.listSnippet("[Starcat](https://github.com/starcat-app/Starcat) is native")
            == "Starcat is native"
        )
    }

    @Test("评论里的 #20 和 owner/repo#20 收成 GitHub 链接")
    func autolinkIssueReferences() {
        let fullName = "octo/hello"
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "Hi, this is a follow-up to #20.",
                repositoryFullName: fullName
            ) == "Hi, this is a follow-up to [#20](https://github.com/octo/hello/issues/20)."
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "see starcat-app/Starcat#7 and #20",
                repositoryFullName: fullName
            ) == "see [starcat-app/Starcat#7](https://github.com/starcat-app/Starcat/issues/7) and [#20](https://github.com/octo/hello/issues/20)"
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "use `#20` in code",
                repositoryFullName: fullName
            ) == "use `#20` in code"
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "```\n#20\n```",
                repositoryFullName: fullName
            ) == "```\n#20\n```"
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "[#20](https://example.test/20)",
                repositoryFullName: fullName
            ) == "[#20](https://example.test/20)"
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "C#20 is a language version",
                repositoryFullName: fullName
            ) == "C#20 is a language version"
        )
        #expect(
            GitHubNotificationMapper.autolinkIssueReferences(
                "see https://example.test/foo#20",
                repositoryFullName: fullName
            ) == "see https://example.test/foo#20"
        )
    }

    @Test("时钟格式 HH:mm")
    func clockLabel() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 14, minute: 32))!
        let label = GitHubNotificationMapper.clockLabel(date: date, locale: Locale(identifier: "en_US_POSIX"))
        #expect(label.contains(":"))
        #expect(label.count == 5)

        let posix = Locale(identifier: "en_US_POSIX")
        let stamp = GitHubNotificationMapper.timelineStamp(date: date, locale: posix)
        let expectedDate = DateFormatter()
        expectedDate.locale = posix
        expectedDate.timeZone = TimeZone.current
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone.current
        expectedDate.calendar = gregorian
        expectedDate.dateFormat = "yyyy-MM-dd"
        let expectedTime = DateFormatter()
        expectedTime.locale = posix
        expectedTime.timeZone = TimeZone.current
        expectedTime.dateFormat = "HH:mm"
        #expect(stamp.date == expectedDate.string(from: date))
        #expect(stamp.time == expectedTime.string(from: date))

        let commentTime = GitHubNotificationMapper.commentTimeLabel(date: date, locale: posix)
        #expect(commentTime.contains(expectedDate.string(from: date)))
        #expect(commentTime.contains(expectedTime.string(from: date)))
    }

    @Test("事件句按 reason 生成，不用 GitHub title")
    func eventHeadlineUsesReason() {
        let record = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "1",
                unread: true,
                reason: "review_requested",
                updatedAt: "2026-08-19T00:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Ignore this title",
                    url: "https://api.github.com/repos/o/r/pulls/9",
                    latestCommentUrl: nil,
                    type: "PullRequest"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 1,
                    fullName: "o/r",
                    name: "r",
                    owner: GitHubNotificationOwnerDTO(login: "o")
                )
            ),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        let zh = GitHubNotificationMapper.eventHeadline(for: record, locale: Locale(identifier: "zh-Hans"))
        #expect(zh.contains("Review"))
        #expect(!zh.contains("Ignore this title"))
    }

    @Test("PR 评论的 chip / 事件句用 PR，不用 Issue 或评论")
    func pullRequestCommentUsesPRChip() {
        let record = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "2",
                unread: true,
                reason: "comment",
                updatedAt: "2026-08-19T14:32:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Add notifications",
                    url: "https://api.github.com/repos/starcat-app/starcat-api/pulls/2",
                    latestCommentUrl: nil,
                    type: "PullRequest"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 2,
                    fullName: "starcat-app/starcat-api",
                    name: "starcat-api",
                    owner: GitHubNotificationOwnerDTO(login: "starcat-app")
                )
            ),
            fetchedAt: "2026-08-19T14:32:00Z",
            firstSeenAt: "2026-08-19T14:32:00Z"
        )
        #expect(GitHubNotificationMapper.chip(for: record) == .pullRequest)
        let zh = GitHubNotificationMapper.eventHeadline(for: record, locale: Locale(identifier: "zh-Hans"))
        #expect(zh.contains("PR"))
        #expect(!zh.contains("Issue"))
        #expect(GitHubNotificationMapper.chipTitle(for: .pullRequest, locale: Locale(identifier: "zh-Hans")) == "PR")
    }

    @Test("GitHub 无毫秒的 ISO8601 能解析，时钟和相对时间才有值")
    func parseGitHubDateWithoutFractionalSeconds() {
        let date = GitHubNotificationMapper.parseDate("2026-08-19T14:32:00Z")
        #expect(date != nil)
        #expect(GitHubNotificationMapper.parseDate("2026-08-19T14:32:00.123Z") != nil)
        #expect(GitHubNotificationMapper.parseDate(nil) == nil)
    }

    @Test("HTML img 收成 Markdown 图片语法")
    func prepareMarkdownConvertsHTMLImages() {
        let html = """
        historically accurate.

        <img width="3104" height="1854" alt="Image" src="https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e" />

        I noticed your work.
        """
        let markdown = GitHubNotificationMapper.prepareMarkdown(html)
        #expect(markdown.contains("![Image](https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e)"))
        #expect(!markdown.contains("<img"))
        #expect(
            GitHubNotificationMapper.listSnippet(html) == "historically accurate."
        )
        let wrapped = #"<a href="https://github.com/user-attachments/assets/abc"><img alt="shot" src="https://github.com/user-attachments/assets/abc" /></a>"#
        let unwrapped = GitHubNotificationMapper.prepareMarkdown(wrapped)
        #expect(unwrapped.contains("![shot](https://github.com/user-attachments/assets/abc)"))
        #expect(!unwrapped.contains("<a"))
        #expect(!unwrapped.contains("<img"))
    }

    @Test("Issue / PR 才能在详情里回复")
    func canReplyOnlyIssueAndPullRequest() {
        #expect(GitHubNotificationMapper.canReply(subjectType: "Issue", number: 182))
        #expect(GitHubNotificationMapper.canReply(subjectType: "PullRequest", number: 2))
        #expect(!GitHubNotificationMapper.canReply(subjectType: "Release", number: 1))
        #expect(!GitHubNotificationMapper.canReply(subjectType: "Issue", number: nil))
    }

    @Test("Issue 开帖人是 subject.user，不是最后一条评论")
    func openingPostAuthorIsNotLastCommenter() {
        var record = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "issue-1",
                unread: true,
                reason: "comment",
                updatedAt: "2026-08-19T14:32:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "npm package name",
                    url: "https://api.github.com/repos/dong4j/hexo-plugin-llms/issues/1",
                    latestCommentUrl: nil,
                    type: "Issue"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 1,
                    fullName: "dong4j/hexo-plugin-llms",
                    name: "hexo-plugin-llms",
                    owner: GitHubNotificationOwnerDTO(login: "dong4j")
                )
            ),
            fetchedAt: "2026-08-19T14:32:00Z",
            firstSeenAt: "2026-08-19T14:32:00Z"
        )
        record.actorLogin = "493505110"
        record.commentsJson = GitHubNotificationMapper.encodeComments([
            GitHubNotificationComment(
                id: 88,
                login: "dong4j",
                body: "感谢提醒 晚点改一下",
                htmlURL: nil,
                createdAt: "2026-08-19T14:32:00Z"
            )
        ])
        #expect(GitHubNotificationMapper.openingPostAuthor(for: record) == "493505110")
        #expect(GitHubNotificationMapper.eventActor(for: record) == "dong4j")
    }

    @Test("仓库 owner 用于 logo URL")
    func repositoryAvatarURLFromFullName() {
        #expect(
            GitHubNotificationMapper.repositoryAvatarURL(fromFullName: "nguyenphutrong/quotio")
            == "https://github.com/nguyenphutrong.png?size=80"
        )
        #expect(GitHubNotificationMapper.repositoryOwner(fromFullName: "o/r") == "o")
    }

    @Test("绝对 API URL 转成 client path")
    func pathFromAbsoluteAPIURL() {
        #expect(
            GitHubNotificationMapper.path(fromAbsoluteAPIURL: "https://api.github.com/repos/o/r/issues/1")
            == "/repos/o/r/issues/1"
        )
    }
}

@MainActor
@Suite("GitHubNotificationInbox")
struct GitHubNotificationInboxTests {

    @Test("回填最多 300 条，不发系统通知，不 PATCH")
    func backfillCapsAt300WithoutNotifyOrPatch() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, page, _, _ in
            let start = (page - 1) * 50
            let threads = (start..<(start + 50)).map { Self.makeDTO(id: "\($0 + 1)") }
            return GitHubNotificationsListResponse(
                threads: threads,
                lastModified: "Wed, 19 Aug 2026 00:00:00 GMT",
                pollIntervalSeconds: 60,
                nextPage: page < 6 ? page + 1 : nil,
                notModified: false
            )
        }

        await env.inbox.sync()

        #expect(env.mock.listNotificationsCalls.count == 6)
        let stored = try await env.threads.fetchAll(limit: 400)
        #expect(stored.count == 300)
        #expect(env.mock.markNotificationThreadReadCalls.isEmpty)
        #expect(env.dispatcher.requestIdentifiers.isEmpty)
        let state = try #require(try await env.syncState.current())
        #expect(state.backfillCompletedAt != nil)
    }

    @Test("upsert 保留 first_seen_at；pending 时 GitHub unread 不能把蓝点打回去")
    func upsertPreservesFirstSeenAndPendingUnread() async throws {
        let env = try makeEnv()
        let first = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t1", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-01T00:00:00Z",
            firstSeenAt: "2026-08-01T00:00:00Z"
        )
        try await env.threads.upsertMany([first])
        try await env.threads.updateLocalUnread(id: "t1", unread: false, markReadState: .pending)

        let incoming = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t1", unread: true, updatedAt: "2026-08-02T00:00:00Z"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([incoming])

        let stored = try #require(try await env.threads.fetch(id: "t1"))
        #expect(stored.firstSeenAt == "2026-08-01T00:00:00Z")
        #expect(stored.unread == false)
        #expect(stored.markReadStateValue == .pending)
        #expect(stored.githubUnread == true)
    }

    @Test("304 增量不改本地 thread")
    func notModifiedSkipsUpsert() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, page, _, ifModifiedSince in
            if ifModifiedSince != nil {
                return GitHubNotificationsListResponse(
                    threads: [],
                    lastModified: "Wed, 19 Aug 2026 00:00:00 GMT",
                    pollIntervalSeconds: 60,
                    nextPage: nil,
                    notModified: true
                )
            }
            #expect(page == 1)
            return Self.listResponse([Self.makeDTO(id: "only")])
        }

        await env.inbox.sync()
        await env.inbox.sync()

        let stored = try await env.threads.fetchAll(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.id == "only")
    }

    @Test("400ms 内划走不 PATCH")
    func cancelDwellDoesNotPatch() async throws {
        let env = try makeEnv(dwellNanoseconds: 200_000_000)
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "dwell")])
        }
        env.mock.markNotificationThreadReadHandler = { _ in }

        await env.inbox.sync()
        await env.inbox.beginDwell(id: "dwell")
        await env.inbox.cancelDwell(id: "dwell")

        #expect(env.mock.markNotificationThreadReadCalls.isEmpty)
        let stored = try #require(try await env.threads.fetch(id: "dwell"))
        #expect(stored.unread == true)
    }

    @Test("停满 dwell 后 PATCH 一次")
    func dwellCompletesWithSinglePatch() async throws {
        let env = try makeEnv(dwellNanoseconds: 20_000_000)
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "ok")])
        }
        env.mock.markNotificationThreadReadHandler = { _ in }

        await env.inbox.sync()
        await env.inbox.beginDwell(id: "ok")
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(env.mock.markNotificationThreadReadCalls == ["ok"])
        let stored = try #require(try await env.threads.fetch(id: "ok"))
        #expect(stored.unread == false)
        #expect(stored.markReadStateValue == .synced)
    }

    @Test("hydrate 命中缓存后不再请求 subject.url")
    func hydrateCachesSubject() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "h1")])
        }
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "hello body",
                createdAt: "2026-07-19T00:00:00Z"
            )
        }
        env.mock.listNotificationIssueCommentsHandler = { path in
            #expect(path == "/repos/o/r/issues/1/comments" || path.hasPrefix("/repos/o/r/issues/1/comments"))
            return [
                GitHubNotificationComment(
                    id: 99,
                    login: "bob",
                    body: "full **markdown** comment",
                    htmlURL: "https://github.com/o/r/issues/1#issuecomment-99",
                    createdAt: "2026-08-19T00:00:00Z"
                )
            ]
        }

        await env.inbox.sync()
        await env.inbox.hydrate(id: "h1")
        await env.inbox.hydrate(id: "h1")

        #expect(hydrateCalls == 1)
        let stored = try #require(try await env.threads.fetch(id: "h1"))
        #expect(stored.actorLogin == "alice")
        #expect(stored.excerpt == "hello body")
        #expect(stored.htmlUrl == "https://github.com/o/r/issues/1")
        #expect(stored.subjectCreatedAt == "2026-07-19T00:00:00Z")
        let comments = GitHubNotificationMapper.decodeComments(stored.commentsJson)
        #expect(comments.count == 1)
        #expect(comments.first?.login == "bob")
        #expect(comments.first?.body == "full **markdown** comment")
    }

    @Test("发表评论会 POST 并追加到本地 comments_json")
    func postCommentAppendsLocally() async throws {
        let env = try makeEnv()
        let record = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "c1"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([record])
        try await env.threads.updateHydration(
            id: "c1",
            actorLogin: "alice",
            excerpt: "opening",
            commentsJson: nil,
            htmlUrl: "https://github.com/o/r/issues/1",
            subjectCreatedAt: "2026-07-19T00:00:00Z",
            hydratedAt: "2026-08-19T00:00:00Z"
        )
        env.mock.createNotificationIssueCommentHandler = { path, body in
            #expect(path == "/repos/o/r/issues/1/comments")
            #expect(body == "hello from starcat")
            return GitHubNotificationComment(
                id: 501,
                login: "dong4j",
                body: body,
                htmlURL: "https://github.com/o/r/issues/1#issuecomment-501",
                createdAt: "2026-08-19T14:32:00Z"
            )
        }

        try await env.inbox.postComment(threadId: "c1", body: "  hello from starcat  ")

        #expect(env.mock.createNotificationIssueCommentCalls.count == 1)
        let stored = try #require(try await env.threads.fetch(id: "c1"))
        let comments = GitHubNotificationMapper.decodeComments(stored.commentsJson)
        #expect(comments.map(\.id) == [501])
        #expect(comments.first?.body == "hello from starcat")
    }

    @Test("403 视为缺 notifications scope")
    func forbiddenBecomesMissingScope() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            throw NetworkError.clientError(statusCode: 403, message: "Resource not accessible")
        }

        await env.inbox.sync()
        #expect(env.inbox.missingScope)
        #expect(try await env.threads.fetchAll(limit: 10).isEmpty)
    }

    @Test("回填完成后的新 mention 才发系统通知")
    func incrementalMentionNotifies() async throws {
        let env = try makeEnv()
        var round = 0
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            round += 1
            if round == 1 {
                return Self.listResponse([Self.makeDTO(id: "old", reason: "mention")])
            }
            return Self.listResponse([Self.makeDTO(id: "new", reason: "mention")])
        }

        await env.inbox.sync()
        #expect(env.dispatcher.requestIdentifiers.isEmpty)

        await env.inbox.sync()
        #expect(env.dispatcher.requestIdentifiers.contains("github-inbox-new"))
        #expect(!env.dispatcher.requestIdentifiers.contains("github-inbox-old"))
    }

    // MARK: - Harness

    private struct Env {
        let db: InMemoryDatabaseManager
        let threads: GRDBGitHubNotificationThreadRepository
        let syncState: GRDBGitHubNotificationSyncStateRepository
        let mock: MockGitHubAPIClient
        let dispatcher: RecordingNotificationDispatcher
        let inbox: GitHubNotificationInboxService
    }

    private func makeEnv(dwellNanoseconds: UInt64 = 1_000) throws -> Env {
        let db = try InMemoryDatabaseManager()
        let threads = GRDBGitHubNotificationThreadRepository(database: db)
        let syncState = GRDBGitHubNotificationSyncStateRepository(database: db)
        let mock = MockGitHubAPIClient()
        mock.markNotificationThreadReadHandler = { _ in }
        mock.hydrateNotificationSubjectHandler = { _ in
            GitHubNotificationSubjectHydration(htmlURL: nil, actorLogin: nil, excerpt: nil, createdAt: nil)
        }
        let defaults = UserDefaults(suiteName: "test.starcat.github-inbox.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        let dispatcher = RecordingNotificationDispatcher()
        let notifications = AppNotificationService(dispatcher: dispatcher, settings: settings)
        let inbox = GitHubNotificationInboxService(
            apiClient: mock,
            threadRepository: threads,
            syncStateRepository: syncState,
            notificationService: notifications,
            settings: settings,
            dwellNanoseconds: dwellNanoseconds
        )
        return Env(db: db, threads: threads, syncState: syncState, mock: mock, dispatcher: dispatcher, inbox: inbox)
    }

    private static func makeDTO(
        id: String,
        unread: Bool = true,
        reason: String = "mention",
        updatedAt: String = "2026-08-19T00:00:00Z"
    ) -> GitHubNotificationThreadDTO {
        GitHubNotificationThreadDTO(
            id: id,
            unread: unread,
            reason: reason,
            updatedAt: updatedAt,
            subject: GitHubNotificationSubjectDTO(
                title: "Issue \(id)",
                url: "https://api.github.com/repos/o/r/issues/1",
                latestCommentUrl: nil,
                type: "Issue"
            ),
            repository: GitHubNotificationRepositoryDTO(
                id: 1,
                fullName: "o/r",
                name: "r",
                owner: GitHubNotificationOwnerDTO(login: "o")
            )
        )
    }

    private static func listResponse(_ threads: [GitHubNotificationThreadDTO]) -> GitHubNotificationsListResponse {
        GitHubNotificationsListResponse(
            threads: threads,
            lastModified: "Wed, 19 Aug 2026 00:00:00 GMT",
            pollIntervalSeconds: 60,
            nextPage: threads.count < 50 ? nil : 2,
            notModified: false
        )
    }
}

private final class RecordingNotificationDispatcher: NotificationDispatching, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    func requestAuthorization() async throws -> Bool { true }

    func add(request: UNNotificationRequest) async throws {
        let identifier = request.identifier
        lock.withLock { $0.append(identifier) }
    }

    var requestIdentifiers: [String] {
        lock.withLock { $0 }
    }
}
