//
//  GitHubNotificationInboxTests.swift
//  StarcatTests
//
//  通知 inbox：解析、回填 300、水位、已读 dwell、hydrate、403 缺 scope。
//

import Foundation
import Observation
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
        #expect(
            GitHubNotificationMapper.issueResourcePath(
                subjectType: "Issue",
                subjectApiURL: "https://api.github.com/repos/o/r/issues/30"
            ) == "/repos/o/r/issues/30"
        )
        #expect(
            GitHubNotificationMapper.issueResourcePath(
                subjectType: "PullRequest",
                subjectApiURL: "https://api.github.com/repos/o/r/pulls/9"
            ) == "/repos/o/r/issues/9"
        )
    }

    @Test("Issue 标签按顺序保留多个，缺色用 GitHub 默认灰")
    func issueLabelsParseMultipleAndRoundTrip() {
        let raw: [Any] = [
            ["name": "bug", "color": "d73a4a"],
            ["name": "ci", "color": "#ededed"],
            "docs",
            ["name": "  "],
            ["color": "000000"]
        ]
        let labels = GitHubNotificationMapper.labels(from: raw)
        #expect(labels.map(\.name) == ["bug", "ci", "docs"])
        #expect(labels.map(\.colorHex) == ["d73a4a", "ededed", "6e7781"])

        let encoded = GitHubNotificationMapper.encodeLabels(labels)
        let decoded = GitHubNotificationMapper.decodeLabels(encoded)
        #expect(decoded == labels)
        #expect(GitHubNotificationMapper.decodeLabels(nil).isEmpty)
        #expect(GitHubNotificationMapper.decodeLabels("[]").isEmpty)
    }

    @Test("列表摘录把 markdown 链接收成可见文字")
    func listSnippetStripsLinks() {
        #expect(
            GitHubNotificationMapper.listSnippet("[Starcat](https://github.com/starcat-app/Starcat) is native")
            == "Starcat is native"
        )
    }

    @Test("中栏面包屑副标题拼总数和未读")
    func listCountSubtitle() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        #expect(
            GitHubNotificationMapper.listCountSubtitle(total: 42, unread: 3, locale: zh)
            == "42 条事件 · 3 未读"
        )
        #expect(
            GitHubNotificationMapper.listCountSubtitle(total: 42, unread: 0, locale: en)
            == "42 events · 0 unread"
        )
    }

    @Test("账本分段不匹配 GitHub 通知行")
    func ledgerSegmentsDoNotMatchNotifications() {
        let record = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "n-1",
                unread: true,
                reason: "mention",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Hello",
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
            ),
            fetchedAt: "2026-08-19T10:00:00Z",
            firstSeenAt: "2026-08-19T10:00:00Z"
        )
        #expect(GitHubNotificationMapper.matchesSegment(record, segment: .all))
        #expect(GitHubNotificationMapper.matchesSegment(record, segment: .mention))
        #expect(GitHubNotificationMapper.matchesSegment(record, segment: .issue))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .pullRequest))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .discussion))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .release))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .star))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .unstar))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .fork))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .open))
        #expect(!GitHubNotificationMapper.matchesSegment(record, segment: .inLibrary))
    }

    @Test("Issue / PR 分段按 subject_type 匹配")
    func issueAndPullRequestSegmentsMatchSubjectType() {
        let issue = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "n-issue",
                unread: false,
                reason: "subscribed",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Bug",
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
            ),
            fetchedAt: "2026-08-19T10:00:00Z",
            firstSeenAt: "2026-08-19T10:00:00Z"
        )
        let pull = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "n-pr",
                unread: false,
                reason: "comment",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Fix",
                    url: "https://api.github.com/repos/o/r/pulls/2",
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
            fetchedAt: "2026-08-19T10:00:00Z",
            firstSeenAt: "2026-08-19T10:00:00Z"
        )
        #expect(GitHubNotificationMapper.matchesSegment(issue, segment: .issue))
        #expect(!GitHubNotificationMapper.matchesSegment(issue, segment: .pullRequest))
        #expect(GitHubNotificationMapper.matchesSegment(pull, segment: .pullRequest))
        #expect(!GitHubNotificationMapper.matchesSegment(pull, segment: .issue))
        #expect(!GitHubNotificationMapper.matchesSegment(issue, segment: .discussion))
        #expect(!GitHubNotificationMapper.matchesSegment(issue, segment: .release))

        let discussion = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "n-disc",
                unread: false,
                reason: "subscribed",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "RFC",
                    url: "https://api.github.com/repos/o/r/discussions/3",
                    latestCommentUrl: nil,
                    type: "Discussion"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 1,
                    fullName: "o/r",
                    name: "r",
                    owner: GitHubNotificationOwnerDTO(login: "o")
                )
            ),
            fetchedAt: "2026-08-19T10:00:00Z",
            firstSeenAt: "2026-08-19T10:00:00Z"
        )
        let release = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "n-rel",
                unread: false,
                reason: "subscribed",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "v1.0",
                    url: "https://api.github.com/repos/o/r/releases/4",
                    latestCommentUrl: nil,
                    type: "Release"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 1,
                    fullName: "o/r",
                    name: "r",
                    owner: GitHubNotificationOwnerDTO(login: "o")
                )
            ),
            fetchedAt: "2026-08-19T10:00:00Z",
            firstSeenAt: "2026-08-19T10:00:00Z"
        )
        #expect(GitHubNotificationMapper.matchesSegment(discussion, segment: .discussion))
        #expect(!GitHubNotificationMapper.matchesSegment(discussion, segment: .release))
        #expect(!GitHubNotificationMapper.matchesSegment(discussion, segment: .issue))
        #expect(GitHubNotificationMapper.matchesSegment(release, segment: .release))
        #expect(!GitHubNotificationMapper.matchesSegment(release, segment: .discussion))
        #expect(!GitHubNotificationMapper.matchesSegment(release, segment: .issue))
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

    @Test("GitHub 状态按钮文案：关闭 / 重新打开，有评论时带评论")
    func issueStateActionTitle() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        #expect(
            GitHubNotificationMapper.issueStateActionTitle(
                isClosed: false, isPullRequest: false, hasComment: false, locale: zh
            ) == "关闭问题"
        )
        #expect(
            GitHubNotificationMapper.issueStateActionTitle(
                isClosed: true, isPullRequest: false, hasComment: false, locale: zh
            ) == "重新打开问题"
        )
        #expect(
            GitHubNotificationMapper.issueStateActionTitle(
                isClosed: true, isPullRequest: false, hasComment: true, locale: zh
            ) == "评论并重新打开"
        )
        #expect(
            GitHubNotificationMapper.issueStateActionTitle(
                isClosed: true, isPullRequest: true, hasComment: false, locale: en
            ) == "Reopen pull request"
        )
        #expect(
            GitHubNotificationMapper.issueStateActionTitle(
                isClosed: true, isPullRequest: false, hasComment: true, locale: en
            ) == "Reopen with comment"
        )
    }

    @Test("PR 的 closed+merged 收成 merged；普通 Issue 只认 open/closed")
    func resolvedIssueStatePrefersMerged() {
        #expect(
            GitHubNotificationMapper.resolvedIssueState(
                rawState: "closed",
                merged: true,
                mergedAt: nil
            ) == "merged"
        )
        #expect(
            GitHubNotificationMapper.resolvedIssueState(
                rawState: "closed",
                merged: false,
                mergedAt: "2026-08-22T04:00:00Z"
            ) == "merged"
        )
        #expect(
            GitHubNotificationMapper.resolvedIssueState(
                rawState: "closed",
                merged: false,
                mergedAt: nil
            ) == "closed"
        )
        #expect(GitHubNotificationMapper.normalizedIssueState("OPEN") == "open")
        #expect(GitHubNotificationMapper.normalizedIssueState("draft") == nil)
        let zh = Locale(identifier: "zh-Hans")
        #expect(GitHubNotificationMapper.issueStateTitle(state: "merged", locale: zh) == "已合并")
        #expect(
            GitHubNotificationMapper.issueStateTitle(state: "open", locale: Locale(identifier: "en"))
            == "Open"
        )
        #expect(
            GitHubNotificationMapper.libraryStateStampTitle(state: .inLibrary, locale: zh) == "已入库"
        )
        #expect(
            GitHubNotificationMapper.libraryStateStampTitle(state: .outsideLibrary, locale: Locale(identifier: "en"))
            == "Out"
        )
        #expect(GitHubNotificationSegment.open.issueStateFilter == "open")
        #expect(GitHubNotificationSegment.closed.issueStateFilter == "closed")
        #expect(GitHubNotificationSegment.inLibrary.libraryStateFilter == .inLibrary)
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
        let expectedTime = DateFormatter()
        expectedTime.locale = posix
        expectedTime.timeZone = TimeZone.current
        expectedTime.dateFormat = "HH:mm"
        #expect(stamp == expectedTime.string(from: date))
        #expect(!stamp.contains("-"))

        let expectedDate = DateFormatter()
        expectedDate.locale = posix
        expectedDate.timeZone = TimeZone.current
        expectedDate.dateFormat = "yyyy-MM-dd"
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

    @Test("列表 chip 用主体类型，mention/review 不盖过 Issue/PR")
    func subjectChipPrefersTypeOverReason() {
        let mentionIssue = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "3",
                unread: true,
                reason: "mention",
                updatedAt: "2026-08-19T14:32:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Mention me",
                    url: "https://api.github.com/repos/o/r/issues/1",
                    latestCommentUrl: nil,
                    type: "Issue"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 3,
                    fullName: "o/r",
                    name: "r",
                    owner: GitHubNotificationOwnerDTO(login: "o")
                )
            ),
            fetchedAt: "2026-08-19T14:32:00Z",
            firstSeenAt: "2026-08-19T14:32:00Z"
        )
        #expect(GitHubNotificationMapper.chip(for: mentionIssue) == .mention)
        #expect(GitHubNotificationMapper.subjectChip(for: mentionIssue) == .issue)
        #expect(GitHubNotificationMapper.subjectChip(type: "PullRequest", reason: "review_requested") == .pullRequest)
        #expect(GitHubNotificationMapper.subjectChip(type: "Release", reason: "comment") == .release)
        #expect(GitHubNotificationMapper.subjectChip(type: "Discussion", reason: "comment") == .discussion)
        #expect(GitHubNotificationMapper.subjectChip(type: "Issue", reason: "security_alert") == .security)
        #expect(
            GitHubNotificationMapper.chipTitle(for: .discussion, locale: Locale(identifier: "zh-Hans")) == "讨论"
        )
    }

    @Test("账本事件句与 chip：Star / Unstar / Fork")
    func userRepoActivityCopy() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        #expect(GitHubNotificationMapper.userRepoActivityHeadline(kind: .star, locale: zh) == "你 Star 了这个项目")
        #expect(GitHubNotificationMapper.userRepoActivityHeadline(kind: .fork, locale: en) == "You forked this repository")
        #expect(GitHubNotificationMapper.userRepoActivityHeadline(kind: .unstar, locale: zh) == "你 Unstar 了这个项目")
        #expect(GitHubNotificationMapper.userRepoActivityChip(kind: .star) == .star)
        #expect(GitHubNotificationMapper.userRepoActivityChip(kind: .unstar) == .unstar)
        #expect(GitHubNotificationMapper.userRepoActivityChip(kind: .fork) == .fork)
        #expect(GitHubNotificationMapper.chipTitle(for: .star, locale: zh) == "Star")
        #expect(GitHubNotificationMapper.chipTitle(for: .unstar, locale: zh) == "Unstar")
        #expect(
            GitHubNotificationMapper.userRepoActivityBanner(
                kind: .star,
                relativeTime: "2 小时前",
                locale: zh
            ) == "你 Star 了 · 2 小时前"
        )
    }

    @Test("合法 GitHub login 才生成用户主页 URL")
    func profileHTMLURLRejectsPlaceholders() {
        #expect(
            GitHubNotificationMapper.profileHTMLURL(login: "dong4j")?.absoluteString
                == "https://github.com/dong4j"
        )
        #expect(
            GitHubNotificationMapper.profileHTMLURL(login: "493505110")?.absoluteString
                == "https://github.com/493505110"
        )
        #expect(GitHubNotificationMapper.profileHTMLURL(login: "有人") == nil)
        #expect(GitHubNotificationMapper.profileHTMLURL(login: "") == nil)
        #expect(GitHubNotificationMapper.profileHTMLURL(login: "-bot") == nil)
        #expect(
            GitHubNotificationMapper.profileHTMLURL(login: "dependabot[bot]")?.absoluteString
                == "https://github.com/apps/dependabot"
        )
        #expect(GitHubNotificationMapper.actorAvatarAssetName(login: "dependabot[bot]") == "DependabotMark")
        #expect(GitHubNotificationMapper.actorAvatarURL(login: "dependabot[bot]") == nil)
        #expect(
            GitHubNotificationMapper.actorAvatarURL(login: "renovate[bot]")
                == "https://github.com/renovate.png?size=80"
        )
        #expect(GitHubNotificationMapper.githubAppSlug(login: "dependabot[bot]") == "dependabot")
        #expect(GitHubNotificationMapper.isGitHubLogin("dependabot[bot]") == false)
        let zh = Locale(identifier: "zh-Hans")
        #expect(
            GitHubNotificationMapper.commentCardHeader(
                login: "dong4j",
                isOpeningPost: true,
                locale: zh
            ) == "dong4j 发布了这条"
        )
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

    @Test("引用回复给每行加 >，空行写成 >")
    func quotedMarkdownPrefixesEveryLine() {
        #expect(GitHubNotificationMapper.quotedMarkdown("  hello\n\nworld  ") == "> hello\n>\n> world")
        #expect(GitHubNotificationMapper.quotedMarkdown("   ") == "")
        #expect(
            GitHubNotificationMapper.prependQuotedReply(quote: "hi", onto: "") == "> hi\n\n"
        )
        #expect(
            GitHubNotificationMapper.prependQuotedReply(quote: "hi", onto: "draft") == "> hi\n\ndraft"
        )
        #expect(GitHubNotificationMapper.prependQuotedReply(quote: "  ", onto: "keep") == "keep")
    }

    @Test("评论 permalink 优先 html_url，否则拼 issuecomment")
    func commentPermalinkPrefersHTMLURLThenFragment() {
        #expect(
            GitHubNotificationMapper.commentPermalink(
                htmlURL: "https://github.com/o/r/issues/1#issuecomment-9",
                issueHTMLURL: "https://github.com/o/r/issues/1",
                commentID: 9
            ) == "https://github.com/o/r/issues/1#issuecomment-9"
        )
        #expect(
            GitHubNotificationMapper.commentPermalink(
                htmlURL: nil,
                issueHTMLURL: "https://github.com/o/r/issues/1",
                commentID: 42
            ) == "https://github.com/o/r/issues/1#issuecomment-42"
        )
        #expect(
            GitHubNotificationMapper.commentPermalink(
                htmlURL: " ",
                issueHTMLURL: "https://github.com/o/r/issues/1#discussion_r1",
                commentID: 7
            ) == "https://github.com/o/r/issues/1#issuecomment-7"
        )
        #expect(
            GitHubNotificationMapper.issueCommentResourcePath(
                repositoryFullName: "o/r",
                commentID: 88
            ) == "/repos/o/r/issues/comments/88"
        )
        #expect(GitHubNotificationMapper.issueCommentResourcePath(repositoryFullName: "o", commentID: 1) == nil)
        #expect(GitHubNotificationMapper.isSameGitHubLogin("Dong4j", "dong4j"))
        #expect(!GitHubNotificationMapper.isSameGitHubLogin("dong4j", "tasselx"))
        #expect(!GitHubNotificationMapper.isSameGitHubLogin("", "dong4j"))
    }

    @Test("评论卡只给作者显示编辑")
    func commentCardActionsEditOnlyForAuthor() {
        let payload = ActivityNotificationPayload(
            threadId: "t1",
            reason: "comment",
            chip: .comment,
            subjectType: "Issue",
            subjectNumber: 1,
            repositoryFullName: "o/r",
            actorLogin: "alice",
            authorLogin: "alice",
            authorCreatedAt: nil,
            excerpt: "hello",
            comments: [],
            people: []
        )
        let comment = GitHubNotificationComment(
            id: 3,
            login: "bob",
            body: "reply",
            htmlURL: nil,
            createdAt: nil
        )
        let opening = GitHubNotificationCommentCardActions.make(
            payload: payload,
            issueHTMLURL: "https://github.com/o/r/issues/1",
            authorLogin: "alice",
            comment: nil,
            markdown: "hello",
            currentLogin: "Alice"
        )
        #expect(opening.canEdit)
        #expect(opening.canQuote)
        #expect(opening.commentID == nil)
        #expect(opening.permalink == "https://github.com/o/r/issues/1")

        let other = GitHubNotificationCommentCardActions.make(
            payload: payload,
            issueHTMLURL: "https://github.com/o/r/issues/1",
            authorLogin: comment.login,
            comment: comment,
            markdown: comment.body,
            currentLogin: "alice"
        )
        #expect(!other.canEdit)
        #expect(other.canQuote)
        #expect(other.permalink == "https://github.com/o/r/issues/1#issuecomment-3")
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

@Suite("GitHubNotificationTimelinePaging")
struct GitHubNotificationTimelinePagingTests {

    @Test("未到倒数窗口不翻页，进入窗口才翻页")
    func prefetchesWithinLastWindowNotOnlyLastRow() {
        let count = 40
        let window = GitHubNotificationTimelinePaging.prefetchRowCount
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: count - window - 1,
                rowCount: count,
                hasMore: true,
                isLoading: false
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: count - window,
                rowCount: count,
                hasMore: true,
                isLoading: false
            )
        )
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: count - 1,
                rowCount: count,
                hasMore: true,
                isLoading: false
            )
        )
    }

    @Test("没有更多、正在加载或索引越界时不翻页")
    func skipsWhenExhaustedLoadingOrIndexOutOfBounds() {
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: 39,
                rowCount: 40,
                hasMore: false,
                isLoading: false
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: 39,
                rowCount: 40,
                hasMore: true,
                isLoading: true
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: -1,
                rowCount: 40,
                hasMore: true,
                isLoading: false
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: 40,
                rowCount: 40,
                hasMore: true,
                isLoading: false
            ) == false
        )
    }

    @Test("不足一窗口时出现任意行就翻页")
    func prefetchesEntireShortList() {
        #expect(
            GitHubNotificationTimelinePaging.shouldPrefetchNextPage(
                rowIndex: 0,
                rowCount: 3,
                hasMore: true,
                isLoading: false
            )
        )
    }

    @Test("只接受 generation、筛选和游标都仍匹配的分页响应")
    func acceptsOnlyCurrentPageRequest() {
        let cursor = GitHubInboxTimelineCursor(
            occurredAt: "2026-08-21T00:00:00Z",
            id: "40"
        )
        let anotherCursor = GitHubInboxTimelineCursor(
            occurredAt: "2026-08-20T00:00:00Z",
            id: "80"
        )

        #expect(
            GitHubNotificationTimelinePaging.isCurrentPageRequest(
                requestedGeneration: 3,
                currentGeneration: 3,
                requestedSegment: .all,
                currentSegment: .all,
                requestedCursor: cursor,
                currentCursor: cursor
            )
        )
        #expect(
            GitHubNotificationTimelinePaging.isCurrentPageRequest(
                requestedGeneration: 2,
                currentGeneration: 3,
                requestedSegment: .all,
                currentSegment: .all,
                requestedCursor: cursor,
                currentCursor: cursor
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.isCurrentPageRequest(
                requestedGeneration: 3,
                currentGeneration: 3,
                requestedSegment: .all,
                currentSegment: .unread,
                requestedCursor: cursor,
                currentCursor: cursor
            ) == false
        )
        #expect(
            GitHubNotificationTimelinePaging.isCurrentPageRequest(
                requestedGeneration: 3,
                currentGeneration: 3,
                requestedSegment: .all,
                currentSegment: .all,
                requestedCursor: cursor,
                currentCursor: anotherCursor
            ) == false
        )
    }
}

@Suite("GitHubNotificationTimelineLibraryState")
struct GitHubNotificationTimelineLibraryStateTests {

    @Test("入库只改匹配账本行的知识库徽章，不改 id 和顺序")
    func patchesMatchingActivityLibraryStateWithoutReordering() {
        let selectedID = "star:starcat:42:2026-08-22T12:00:00Z"
        let otherID = "star:starcat:99:2026-08-22T11:00:00Z"
        let rows: [GitHubInboxTimelineRow] = [
            activityRow(id: selectedID, repoId: 42, state: .outsideLibrary),
            activityRow(id: otherID, repoId: 99, state: .outsideLibrary)
        ]

        let patched = GitHubNotificationTimelineLibraryState.apply(
            rows: rows,
            repoId: 42,
            state: .inLibrary
        )

        #expect(patched.map(\.id) == [selectedID, otherID])
        #expect(libraryState(of: patched[0]) == .inLibrary)
        #expect(libraryState(of: patched[1]) == .outsideLibrary)
    }

    @Test("同一仓库的多条账本行一起改徽章；未命中时列表原样返回")
    func patchesEveryMatchingRepoRowAndIgnoresUnknownRepo() {
        let first = activityRow(id: "star:starcat:7:2026-08-22T10:00:00Z", repoId: 7, state: .outsideLibrary)
        let second = activityRow(id: "unstar:starcat:7:2026-08-22T09:00:00Z", repoId: 7, state: .outsideLibrary)
        let other = activityRow(id: "star:starcat:8:2026-08-22T08:00:00Z", repoId: 8, state: .inLibrary)
        let rows = [first, second, other]

        let patched = GitHubNotificationTimelineLibraryState.apply(
            rows: rows,
            repoId: 7,
            state: .inLibrary
        )
        #expect(libraryState(of: patched[0]) == .inLibrary)
        #expect(libraryState(of: patched[1]) == .inLibrary)
        #expect(libraryState(of: patched[2]) == .inLibrary)

        let unchanged = GitHubNotificationTimelineLibraryState.apply(
            rows: rows,
            repoId: 100,
            state: .inLibrary
        )
        #expect(unchanged == rows)
    }

    private func activityRow(id: String, repoId: Int64, state: LibraryState) -> GitHubInboxTimelineRow {
        let record = UserRepoActivityRecord(
            id: id,
            kind: id.hasPrefix("unstar") ? .unstar : .star,
            source: .starcat,
            repoId: repoId,
            fullName: "octo/repo-\(repoId)",
            htmlUrl: "https://github.com/octo/repo-\(repoId)",
            occurredAt: "2026-08-22T12:00:00Z",
            createdAt: "2026-08-22T12:00:00Z",
            userId: 1,
            userName: "tester"
        )
        return .activity(
            UserRepoActivityListItem(
                record: record,
                snippet: "desc",
                ownerLogin: "tester",
                language: "Swift",
                libraryState: state
            )
        )
    }

    private func libraryState(of row: GitHubInboxTimelineRow) -> LibraryState? {
        guard case .activity(let item) = row else { return nil }
        return item.libraryState
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

    @Test("synced 后 GitHub 仍 unread 且 updated_at 没变，不能把蓝点打回去")
    func upsertPreservesSyncedUnreadWhenGitHubLags() async throws {
        let env = try makeEnv()
        let first = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-sync", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-01T00:00:00Z",
            firstSeenAt: "2026-08-01T00:00:00Z"
        )
        try await env.threads.upsertMany([first])
        try await env.threads.updateLocalUnread(
            id: "t-sync",
            unread: false,
            markReadState: .synced,
            githubUnread: false
        )

        let incoming = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-sync", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([incoming])

        let stored = try #require(try await env.threads.fetch(id: "t-sync"))
        #expect(stored.unread == false)
        #expect(stored.markReadStateValue == .synced)
    }

    @Test("failed 后 GitHub 仍 unread 且 updated_at 没变，保持已读等重试")
    func upsertPreservesFailedUnreadWhenGitHubStillUnread() async throws {
        let env = try makeEnv()
        let first = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-fail", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-01T00:00:00Z",
            firstSeenAt: "2026-08-01T00:00:00Z"
        )
        try await env.threads.upsertMany([first])
        try await env.threads.updateLocalUnread(id: "t-fail", unread: false, markReadState: .failed)

        let incoming = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-fail", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([incoming])

        let stored = try #require(try await env.threads.fetch(id: "t-fail"))
        #expect(stored.unread == false)
        #expect(stored.markReadStateValue == .failed)
    }

    @Test("synced 后 subject 有新 updated_at，GitHub unread 才重新亮蓝点")
    func upsertResetsSyncedWhenThreadUpdatedAgain() async throws {
        let env = try makeEnv()
        let first = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-new", unread: true, updatedAt: "2026-08-01T00:00:00Z"),
            fetchedAt: "2026-08-01T00:00:00Z",
            firstSeenAt: "2026-08-01T00:00:00Z"
        )
        try await env.threads.upsertMany([first])
        try await env.threads.updateLocalUnread(
            id: "t-new",
            unread: false,
            markReadState: .synced,
            githubUnread: false
        )
        try await env.threads.markNotified(
            ids: ["t-new"],
            notifiedAt: "2026-08-01T00:00:00Z"
        )

        let incoming = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "t-new", unread: true, updatedAt: "2026-08-19T12:00:00Z"),
            fetchedAt: "2026-08-19T12:00:00Z",
            firstSeenAt: "2026-08-19T12:00:00Z"
        )
        try await env.threads.upsertMany([incoming])

        let stored = try #require(try await env.threads.fetch(id: "t-new"))
        #expect(stored.unread == true)
        #expect(stored.markReadStateValue == .idle)
        #expect(stored.notifiedAt == nil)
    }

    @Test("totalCount 是全部 thread，unreadCount 只计未读")
    func totalCountSeparateFromUnread() async throws {
        let env = try makeEnv()
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "u1", unread: true),
                fetchedAt: "2026-08-19T00:00:00Z",
                firstSeenAt: "2026-08-19T00:00:00Z"
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "r1", unread: false),
                fetchedAt: "2026-08-19T00:00:00Z",
                firstSeenAt: "2026-08-19T00:00:00Z"
            )
        ])
        #expect(try await env.threads.totalCount() == 2)
        #expect(try await env.threads.unreadCount() == 1)
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

    @Test("历史重拉清游标但保留已有 thread 和本地已读状态")
    func historyResyncPreservesThreadsAndLocalReadState() async throws {
        let env = try makeEnv()
        var phase = 0
        var requests: [(since: String?, ifModifiedSince: String?)] = []
        env.mock.listNotificationsHandler = { _, since, _, _, ifModifiedSince in
            requests.append((since, ifModifiedSince))
            if phase == 0 {
                return Self.listResponse([
                    Self.makeDTO(id: "existing", updatedAt: "2026-08-01T00:00:00Z")
                ])
            }
            return Self.listResponse([
                Self.makeDTO(id: "existing", updatedAt: "2026-08-01T00:00:00Z"),
                Self.makeDTO(id: "organization", updatedAt: "2026-07-01T00:00:00Z")
            ])
        }

        await env.inbox.sync()
        try await env.threads.updateLocalUnread(
            id: "existing",
            unread: false,
            markReadState: .synced,
            githubUnread: false
        )

        phase = 1
        await env.inbox.resyncHistory()

        #expect(requests.count == 2)
        #expect(requests[1].since == nil)
        #expect(requests[1].ifModifiedSince == nil)
        let existing = try #require(try await env.threads.fetch(id: "existing"))
        #expect(existing.unread == false)
        #expect(existing.markReadStateValue == .synced)
        #expect(try await env.threads.fetch(id: "organization") != nil)
        #expect(try await env.syncState.current()?.backfillCompletedAt != nil)
    }

    /// SyncIconButton 只认 `isRefreshing`。服务若不走 Observation，
    /// `isSyncing` 变 true 时视图收不到，图标就不会转圈。
    @Test("isSyncing 对 Observation 可见，手动刷新才能驱动 SyncIconButton 转圈")
    @MainActor
    func isSyncingIsObservableForRefreshButton() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return Self.listResponse([Self.makeDTO(id: "obs")])
        }

        let observedChange = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = env.inbox.isSyncing
        } onChange: {
            observedChange.withLock { $0 = true }
        }

        #expect(env.inbox.isSyncing == false)

        let syncTask = Task { await env.inbox.sync() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(env.inbox.isSyncing)
        #expect(observedChange.withLock { $0 })

        await syncTask.value
        #expect(env.inbox.isSyncing == false)
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
        #expect(stored.githubUnread == false)
    }

    @Test("已 synced 的已读行再选中不重复 PATCH，划走也不回未读")
    func syncedDwellDoesNotPatchOrRestore() async throws {
        let env = try makeEnv(dwellNanoseconds: 20_000_000)
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "ok")])
        }
        env.mock.markNotificationThreadReadHandler = { _ in }

        await env.inbox.sync()
        await env.inbox.beginDwell(id: "ok")
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(env.mock.markNotificationThreadReadCalls == ["ok"])

        await env.inbox.beginDwell(id: "ok")
        await env.inbox.cancelDwell(id: "ok")
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(env.mock.markNotificationThreadReadCalls == ["ok"])
        let stored = try #require(try await env.threads.fetch(id: "ok"))
        #expect(stored.unread == false)
        #expect(stored.markReadStateValue == .synced)
        #expect(stored.githubUnread == false)
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
                createdAt: "2026-07-19T00:00:00Z",
                state: "open",
                labels: [
                    GitHubNotificationIssueLabel(name: "bug", colorHex: "d73a4a"),
                    GitHubNotificationIssueLabel(name: "ci", colorHex: "ededed")
                ]
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
        #expect(stored.issueState == "open")
        #expect(env.inbox.cachedIssueState(threadId: "h1") == "open")
        let comments = GitHubNotificationMapper.decodeComments(stored.commentsJson)
        #expect(comments.count == 1)
        #expect(comments.first?.login == "bob")
        #expect(comments.first?.body == "full **markdown** comment")
        let labels = GitHubNotificationMapper.decodeLabels(stored.labelsJson)
        #expect(labels.map(\.name) == ["bug", "ci"])
        #expect(labels.map(\.colorHex) == ["d73a4a", "ededed"])
    }

    @Test("事件流打开时 hydrate 只补 subject，不拉 comments")
    func hydrateSkipsCommentsWhenIssueEventsEnabled() async throws {
        let env = try makeEnv()
        env.settings.githubIssueEventTimelineEnabled = true
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "ev1")])
        }
        var hydrateCalls = 0
        var commentCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "hello body",
                createdAt: "2026-07-19T00:00:00Z",
                state: "open",
                labels: [GitHubNotificationIssueLabel(name: "bug", colorHex: "d73a4a")]
            )
        }
        env.mock.listNotificationIssueCommentsHandler = { _ in
            commentCalls += 1
            return []
        }
        env.mock.listNotificationIssueTimelineHandler = { path in
            #expect(path == "/repos/o/r/issues/1/timeline")
            return [
                .comment(
                    GitHubNotificationComment(
                        id: 77,
                        login: "bob",
                        body: "from timeline",
                        htmlURL: "https://github.com/o/r/issues/1#issuecomment-77",
                        createdAt: "2026-08-19T00:00:00Z"
                    )
                )
            ]
        }

        await env.inbox.sync()
        await env.inbox.hydrate(id: "ev1")
        await env.inbox.hydrate(id: "ev1")
        let cached = try await env.inbox.loadIssueTimeline(threadId: "ev1")

        #expect(hydrateCalls == 1)
        #expect(commentCalls == 0)
        #expect(env.mock.listNotificationIssueTimelineCalls.count == 1)
        #expect(cached.count == 1)
        let stored = try #require(try await env.threads.fetch(id: "ev1"))
        #expect(stored.commentsJson == nil)
        #expect(stored.excerpt == "hello body")
        #expect(GitHubNotificationMapper.decodeLabels(stored.labelsJson).map(\.name) == ["bug"])
    }

    @Test("事件流关掉后，只补过 subject 的帖会再拉 comments")
    func hydrateFetchesCommentsAfterDisablingIssueEvents() async throws {
        let env = try makeEnv()
        env.settings.githubIssueEventTimelineEnabled = true
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "ev2")])
        }
        env.mock.hydrateNotificationSubjectHandler = { _ in
            GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "hello body",
                createdAt: "2026-07-19T00:00:00Z",
                state: "open",
                labels: []
            )
        }
        var commentCalls = 0
        env.mock.listNotificationIssueCommentsHandler = { _ in
            commentCalls += 1
            return [
                GitHubNotificationComment(
                    id: 88,
                    login: "bob",
                    body: "after toggle off",
                    htmlURL: "https://github.com/o/r/issues/1#issuecomment-88",
                    createdAt: "2026-08-19T00:00:00Z"
                )
            ]
        }
        env.mock.listNotificationIssueTimelineHandler = { _ in [] }

        await env.inbox.sync()
        await env.inbox.hydrate(id: "ev2")
        #expect(commentCalls == 0)
        #expect(try await env.threads.fetch(id: "ev2")?.commentsJson == nil)

        env.settings.githubIssueEventTimelineEnabled = false
        await env.inbox.hydrate(id: "ev2")

        #expect(commentCalls == 1)
        let stored = try #require(try await env.threads.fetch(id: "ev2"))
        let comments = GitHubNotificationMapper.decodeComments(stored.commentsJson)
        #expect(comments.map(\.id) == [88])
    }

    @Test("事件流打开时发评不写 comments_json，并强制重拉 timeline")
    func postCommentWhileIssueEventsEnabledRefetchesTimeline() async throws {
        let env = try makeEnv()
        env.settings.githubIssueEventTimelineEnabled = true
        let record = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "ev3"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([record])
        try await env.threads.updateHydration(
            id: "ev3",
            actorLogin: "alice",
            excerpt: "opening",
            commentsJson: GitHubNotificationMapper.encodeComments([
                GitHubNotificationComment(
                    id: 1,
                    login: "old",
                    body: "stale",
                    htmlURL: nil,
                    createdAt: "2026-08-18T00:00:00Z"
                )
            ]),
            htmlUrl: "https://github.com/o/r/issues/1",
            subjectCreatedAt: "2026-07-19T00:00:00Z",
            hydratedAt: "2026-08-19T00:00:00Z",
            labelsJson: nil
        )
        var timelineCalls = 0
        env.mock.listNotificationIssueTimelineHandler = { _ in
            timelineCalls += 1
            return [
                .comment(
                    GitHubNotificationComment(
                        id: 501,
                        login: "dong4j",
                        body: "hello from starcat",
                        htmlURL: "https://github.com/o/r/issues/1#issuecomment-501",
                        createdAt: "2026-08-19T14:32:00Z"
                    )
                )
            ]
        }
        env.mock.createNotificationIssueCommentHandler = { _, body in
            GitHubNotificationComment(
                id: 501,
                login: "dong4j",
                body: body,
                htmlURL: "https://github.com/o/r/issues/1#issuecomment-501",
                createdAt: "2026-08-19T14:32:00Z"
            )
        }

        _ = try await env.inbox.loadIssueTimeline(threadId: "ev3")
        #expect(timelineCalls == 1)
        try await env.inbox.postComment(threadId: "ev3", body: "hello from starcat")
        #expect(timelineCalls == 2)
        #expect(env.inbox.issueTimelineRevision(threadId: "ev3") >= 2)

        let stored = try #require(try await env.threads.fetch(id: "ev3"))
        #expect(stored.commentsJson == nil)

        env.settings.githubIssueEventTimelineEnabled = false
        var commentCalls = 0
        env.mock.listNotificationIssueCommentsHandler = { _ in
            commentCalls += 1
            return [
                GitHubNotificationComment(
                    id: 501,
                    login: "dong4j",
                    body: "hello from starcat",
                    htmlURL: "https://github.com/o/r/issues/1#issuecomment-501",
                    createdAt: "2026-08-19T14:32:00Z"
                )
            ]
        }
        await env.inbox.hydrate(id: "ev3")
        #expect(commentCalls == 1)
    }

    @Test("事件流冷启动读文件缓存，不再打 timeline API")
    func issueTimelineDiskCacheSurvivesNewInbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-timeline-disk-\(UUID().uuidString)", isDirectory: true)
        let disk = DiskIssueTimelineCache(rootOverride: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = { Date(timeIntervalSince1970: 1_800_000_000) }

        let env = try makeEnv(clock: clock, issueTimelineDiskCache: disk)
        env.settings.githubIssueEventTimelineEnabled = true
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "disk1")])
        }
        env.mock.listNotificationIssueTimelineHandler = { _ in
            [
                .comment(
                    GitHubNotificationComment(
                        id: 11,
                        login: "bob",
                        body: "cached comment",
                        htmlURL: nil,
                        createdAt: "2026-08-19T00:00:00Z"
                    )
                )
            ]
        }

        await env.inbox.sync()
        await env.inbox.hydrate(id: "disk1")
        #expect(env.mock.listNotificationIssueTimelineCalls.count == 1)
        #expect(disk.itemCount == 1)

        let inbox2 = GitHubNotificationInboxService(
            apiClient: env.mock,
            threadRepository: env.threads,
            syncStateRepository: env.syncState,
            notificationService: AppNotificationService(
                dispatcher: env.dispatcher,
                settings: env.settings
            ),
            settings: env.settings,
            activityRepository: env.activity,
            clock: clock,
            issueTimelineDiskCache: disk
        )
        let items = try await inbox2.loadIssueTimeline(threadId: "disk1")
        #expect(env.mock.listNotificationIssueTimelineCalls.count == 1)
        #expect(items.count == 1)
        if case .comment(let comment) = items.first {
            #expect(comment.body == "cached comment")
        } else {
            Issue.record("expected cached comment")
        }
    }

    @Test("通知 updated_at 新于文件缓存时会重拉 timeline")
    func issueTimelineDiskCacheRefetchesWhenThreadNewer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-timeline-stale-\(UUID().uuidString)", isDirectory: true)
        let disk = DiskIssueTimelineCache(rootOverride: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldClock = { Date(timeIntervalSince1970: 1_700_000_000) }

        let env = try makeEnv(clock: oldClock, issueTimelineDiskCache: disk)
        env.settings.githubIssueEventTimelineEnabled = true
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "stale1")])
        }
        var timelineCalls = 0
        env.mock.listNotificationIssueTimelineHandler = { _ in
            timelineCalls += 1
            return []
        }

        await env.inbox.sync()
        _ = try await env.inbox.loadIssueTimeline(threadId: "stale1")
        #expect(timelineCalls == 1)

        let inbox2 = GitHubNotificationInboxService(
            apiClient: env.mock,
            threadRepository: env.threads,
            syncStateRepository: env.syncState,
            notificationService: AppNotificationService(
                dispatcher: env.dispatcher,
                settings: env.settings
            ),
            settings: env.settings,
            activityRepository: env.activity,
            clock: oldClock,
            issueTimelineDiskCache: disk
        )
        _ = try await inbox2.loadIssueTimeline(threadId: "stale1")
        #expect(timelineCalls == 2)
    }

    @Test("已 hydrate 但缺 labels_json 的 Issue 会再拉一次 subject")
    func hydrateRefetchesWhenLabelsMissing() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "h-labels")])
        }
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: nil,
                createdAt: "2026-07-19T00:00:00Z",
                state: "open",
                labels: [GitHubNotificationIssueLabel(name: "bug", colorHex: "d73a4a")]
            )
        }
        env.mock.listNotificationIssueCommentsHandler = { _ in [] }

        await env.inbox.sync()
        await env.inbox.hydrate(id: "h-labels")
        let first = try #require(try await env.threads.fetch(id: "h-labels"))
        try await env.threads.updateHydration(
            id: "h-labels",
            actorLogin: first.actorLogin,
            excerpt: first.excerpt,
            commentsJson: first.commentsJson,
            htmlUrl: first.htmlUrl,
            subjectCreatedAt: first.subjectCreatedAt,
            hydratedAt: first.hydratedAt ?? "2026-08-19T00:00:00Z",
            labelsJson: nil
        )
        await env.inbox.hydrate(id: "h-labels")

        #expect(hydrateCalls == 2)
        let stored = try #require(try await env.threads.fetch(id: "h-labels"))
        #expect(GitHubNotificationMapper.decodeLabels(stored.labelsJson).map(\.name) == ["bug"])
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
            hydratedAt: "2026-08-19T00:00:00Z",
            labelsJson: nil
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

    @Test("编辑评论会 PATCH 并回写 comments_json")
    func updateCommentPatchesLocally() async throws {
        let env = try makeEnv()
        let record = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "c-edit"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([record])
        let existing = GitHubNotificationComment(
            id: 501,
            login: "dong4j",
            body: "old",
            htmlURL: "https://github.com/o/r/issues/1#issuecomment-501",
            createdAt: "2026-08-19T14:32:00Z"
        )
        try await env.threads.updateHydration(
            id: "c-edit",
            actorLogin: "alice",
            excerpt: "opening",
            commentsJson: GitHubNotificationMapper.encodeComments([existing]),
            htmlUrl: "https://github.com/o/r/issues/1",
            subjectCreatedAt: "2026-07-19T00:00:00Z",
            hydratedAt: "2026-08-19T00:00:00Z",
            labelsJson: nil
        )
        env.mock.updateNotificationIssueCommentHandler = { path, body in
            #expect(path == "/repos/o/r/issues/comments/501")
            #expect(body == "new body")
        }

        try await env.inbox.updateComment(threadId: "c-edit", commentId: 501, body: "  new body  ")

        #expect(env.mock.updateNotificationIssueCommentCalls.count == 1)
        let stored = try #require(try await env.threads.fetch(id: "c-edit"))
        let comments = GitHubNotificationMapper.decodeComments(stored.commentsJson)
        #expect(comments.map(\.id) == [501])
        #expect(comments.first?.body == "new body")
        #expect(comments.first?.login == "dong4j")
    }

    @Test("编辑开帖会 PATCH issue body 并回写 excerpt")
    func updateOpeningBodyPatchesExcerpt() async throws {
        let env = try makeEnv()
        let record = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "open-edit"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([record])
        try await env.threads.updateHydration(
            id: "open-edit",
            actorLogin: "alice",
            excerpt: "old opening",
            commentsJson: "[]",
            htmlUrl: "https://github.com/o/r/issues/1",
            subjectCreatedAt: "2026-07-19T00:00:00Z",
            hydratedAt: "2026-08-19T00:00:00Z",
            labelsJson: nil
        )
        env.mock.updateNotificationIssueBodyHandler = { path, body in
            #expect(path == "/repos/o/r/issues/1")
            #expect(body == "new opening")
        }

        try await env.inbox.updateOpeningBody(threadId: "open-edit", body: " new opening ")

        #expect(env.mock.updateNotificationIssueBodyCalls.count == 1)
        let stored = try #require(try await env.threads.fetch(id: "open-edit"))
        #expect(stored.excerpt == "new opening")
    }

    @Test("编辑评论 403 收成 cannotEdit；演示帖拒绝")
    func updateCommentForbiddenAndDemoRejected() async throws {
        let env = try makeEnv()
        let record = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "c-403"),
            fetchedAt: "2026-08-19T00:00:00Z",
            firstSeenAt: "2026-08-19T00:00:00Z"
        )
        try await env.threads.upsertMany([record])
        env.mock.updateNotificationIssueCommentHandler = { _, _ in
            throw NetworkError.clientError(statusCode: 403, message: "Resource not accessible")
        }
        await #expect(throws: GitHubNotificationInboxError.cannotEdit) {
            try await env.inbox.updateComment(threadId: "c-403", commentId: 9, body: "nope")
        }
        await #expect(throws: GitHubNotificationInboxError.cannotEdit) {
            try await env.inbox.updateComment(
                threadId: "\(GitHubNotificationMapper.demoThreadIDPrefix)x",
                commentId: 1,
                body: "nope"
            )
        }
        #expect(env.mock.updateNotificationIssueCommentCalls.count == 1)
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
        #expect(env.dispatcher.requestIdentifiers.contains("github-inbox-new-2026-08-19T00:00:00Z"))
        #expect(!env.dispatcher.requestIdentifiers.contains { $0.contains("github-inbox-old-") })
    }

    @Test("不进入时间线时，Issue 关闭也会由增量同步发系统通知")
    func incrementalIssueClosedNotifies() async throws {
        let env = try makeEnv()
        var round = 0
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            round += 1
            let updatedAt = round == 1 ? "2026-08-19T00:00:00Z" : "2026-08-19T01:00:00Z"
            return Self.listResponse([
                Self.makeDTO(
                    id: "issue-closed",
                    reason: "subscribed",
                    updatedAt: updatedAt
                )
            ])
        }
        env.mock.hydrateNotificationSubjectHandler = { _ in
            GitHubNotificationSubjectHydration(
                htmlURL: nil,
                actorLogin: nil,
                excerpt: nil,
                createdAt: nil,
                state: "closed"
            )
        }

        await env.inbox.sync()
        try await env.threads.updatePersistedIssueState(id: "issue-closed", state: "open")
        await env.inbox.sync()

        let request = try #require(env.dispatcher.requests.last)
        #expect(request.identifier == "github-inbox-issue-closed-2026-08-19T01:00:00Z")
        #expect(request.body.contains("已关闭") || request.body.contains("closed"))
        #expect(request.threadID == "issue-closed")
    }

    @Test("不进入时间线时，PR 合并会通知且同一远端版本不重复")
    func incrementalPullRequestMergedNotifiesOnce() async throws {
        let env = try makeEnv()
        var round = 0
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            round += 1
            let updatedAt = round == 1 ? "2026-08-19T00:00:00Z" : "2026-08-19T02:00:00Z"
            return Self.listResponse([
                Self.makeDTO(
                    id: "pr-merged",
                    reason: "subscribed",
                    updatedAt: updatedAt,
                    subjectType: "PullRequest"
                )
            ])
        }
        env.mock.hydrateNotificationSubjectHandler = { _ in
            GitHubNotificationSubjectHydration(
                htmlURL: nil,
                actorLogin: nil,
                excerpt: nil,
                createdAt: nil,
                state: "merged"
            )
        }

        await env.inbox.sync()
        try await env.threads.updatePersistedIssueState(id: "pr-merged", state: "open")
        await env.inbox.sync()
        await env.inbox.sync()

        #expect(env.dispatcher.requests.count == 1)
        let request = try #require(env.dispatcher.requests.first)
        #expect(request.identifier == "github-inbox-pr-merged-2026-08-19T02:00:00Z")
        #expect(request.body.contains("已合并") || request.body.contains("merged"))
        #expect(request.threadID == "pr-merged")
    }

    @Test("Discussion 更新直接通知，不额外请求 Issue 状态")
    func incrementalDiscussionUpdateNotifiesWithoutHydration() async throws {
        let env = try makeEnv()
        let hydrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        var round = 0
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            round += 1
            let updatedAt = round == 1 ? "2026-08-19T00:00:00Z" : "2026-08-19T03:00:00Z"
            return Self.listResponse([
                Self.makeDTO(
                    id: "discussion-updated",
                    reason: "subscribed",
                    updatedAt: updatedAt,
                    subjectType: "Discussion"
                )
            ])
        }
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrationCalls.withLock { $0 += 1 }
            return GitHubNotificationSubjectHydration(
                htmlURL: nil,
                actorLogin: nil,
                excerpt: nil,
                createdAt: nil,
                state: nil
            )
        }

        await env.inbox.sync()
        await env.inbox.sync()

        #expect(hydrationCalls.withLock { $0 } == 0)
        let request = try #require(env.dispatcher.requests.last)
        #expect(request.identifier == "github-inbox-discussion-updated-2026-08-19T03:00:00Z")
        #expect(request.body.contains("讨论已更新") || request.body.contains("Discussion updated"))
        #expect(request.threadID == "discussion-updated")
    }

    @Test("残留演示 thread 能按前缀删掉")
    func leftoverDemoThreadsClearByPrefix() async throws {
        let env = try makeEnv()
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "\(GitHubNotificationMapper.demoThreadIDPrefix)left", reason: "mention"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])
        await env.inbox.clearDemoThreads()
        let cleared = try await env.threads.fetchAll(limit: 20)
        #expect(cleared.isEmpty)
    }

    @Test("关闭 Issue 走 issues path；演示 id 拒绝；已关闭可 reopen")
    func closeIssuePatchesState() async throws {
        let env = try makeEnv()
        let lock = OSAllocatedUnfairLock<[(String, String)]>(initialState: [])
        env.mock.updateNotificationIssueStateHandler = { path, state in
            lock.withLock { $0.append((path, state)) }
        }
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "issue-1", reason: "comment"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])
        try await env.inbox.closeIssue(threadId: "issue-1")
        var patched = lock.withLock { $0 }
        #expect(patched.count == 1)
        #expect(patched.first?.0 == "/repos/o/r/issues/1")
        #expect(patched.first?.1 == "closed")
        #expect(env.inbox.cachedIssueState(threadId: "issue-1") == "closed")
        #expect(try await env.threads.fetch(id: "issue-1")?.issueState == "closed")

        try await env.inbox.reopenIssue(threadId: "issue-1")
        patched = lock.withLock { $0 }
        #expect(patched.count == 2)
        #expect(patched.last?.1 == "open")
        #expect(env.inbox.cachedIssueState(threadId: "issue-1") == "open")
        #expect(try await env.threads.fetch(id: "issue-1")?.issueState == "open")

        await #expect(throws: GitHubNotificationInboxError.cannotClose) {
            try await env.inbox.closeIssue(threadId: "\(GitHubNotificationMapper.demoThreadIDPrefix)x")
        }
        await #expect(throws: GitHubNotificationInboxError.cannotClose) {
            try await env.inbox.updateIssueState(threadId: "issue-1", state: "merged")
        }
    }

    @Test("缺状态的可见 Issue 会补 GET 并落库；已有 issue_state 不再打网")
    func prefetchMissingIssueStatesPersistsAndSkipsKnown() async throws {
        let env = try makeEnv()
        let fetchedAt = "2026-08-19T00:00:00Z"
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/pull/2",
                actorLogin: "alice",
                excerpt: "pr body",
                createdAt: "2026-07-19T00:00:00Z",
                state: "merged"
            )
        }
        var missing = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "need-state",
                unread: false,
                reason: "comment",
                updatedAt: "2026-08-19T10:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Fix",
                    url: "https://api.github.com/repos/o/r/pulls/2",
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
            fetchedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
        var known = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "already-known", reason: "comment"),
            fetchedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
        known.issueState = "open"
        try await env.threads.upsertMany([missing, known])
        missing = try #require(try await env.threads.fetch(id: "need-state"))
        known = try #require(try await env.threads.fetch(id: "already-known"))

        await env.inbox.prefetchMissingIssueStates(from: [
            .notification(missing, language: nil),
            .notification(known, language: nil)
        ])

        #expect(hydrateCalls == 1)
        #expect(env.inbox.cachedIssueState(threadId: "need-state") == "merged")
        #expect(try await env.threads.fetch(id: "need-state")?.issueState == "merged")
        #expect(env.inbox.cachedIssueState(threadId: "already-known") == "open")
        #expect(env.inbox.resolvedIssueState(threadId: "already-known", persisted: "open") == "open")
    }

    @Test("缺失 issue_state 同一会话只补一轮，再切打开/关闭不再打网")
    func missingIssueStateBackfillRunsOncePerSession() async throws {
        let env = try makeEnv()
        env.inbox.listSegment = .open
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "body",
                createdAt: "2026-07-19T00:00:00Z",
                state: "open"
            )
        }
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "missing-a", reason: "comment", updatedAt: "2026-08-19T02:00:00Z"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            ),
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "missing-b", reason: "comment", updatedAt: "2026-08-19T01:00:00Z"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])

        await env.inbox.startMissingIssueStateBackfillIfNeeded()
        #expect(hydrateCalls == 2)
        #expect(try await env.threads.fetch(id: "missing-a")?.issueState == "open")
        #expect(try await env.threads.fetch(id: "missing-b")?.issueState == "open")

        env.inbox.listSegment = .closed
        await env.inbox.startMissingIssueStateBackfillIfNeeded()
        #expect(hydrateCalls == 2)

        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "missing-c", reason: "comment", updatedAt: "2026-08-19T03:00:00Z"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])
        env.inbox.listSegment = .merged
        await env.inbox.startMissingIssueStateBackfillIfNeeded()
        #expect(hydrateCalls == 2)
        #expect(try await env.threads.fetch(id: "missing-c")?.issueState == nil)
    }

    @Test("还没有缺失状态时不锁定本轮补齐，等同步落库后再补")
    func missingIssueStateBackfillDoesNotLatchWhenEmpty() async throws {
        let env = try makeEnv()
        env.inbox.listSegment = .open
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "body",
                createdAt: "2026-07-19T00:00:00Z",
                state: "closed"
            )
        }
        await env.inbox.startMissingIssueStateBackfillIfNeeded()
        #expect(hydrateCalls == 0)

        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "after-sync", reason: "comment"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])
        await env.inbox.startMissingIssueStateBackfillIfNeeded()
        #expect(hydrateCalls == 1)
        #expect(try await env.threads.fetch(id: "after-sync")?.issueState == "closed")
    }

    @Test("已 hydrate 的 thread 打开详情仍会 GET state；closed 不当成可关闭")
    func refreshIssueStateAfterHydrateCache() async throws {
        let env = try makeEnv()
        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: "https://github.com/o/r/issues/1",
                actorLogin: "alice",
                excerpt: "hello body",
                createdAt: "2026-07-19T00:00:00Z",
                state: hydrateCalls == 1 ? "open" : "closed"
            )
        }
        env.mock.listNotificationIssueCommentsHandler = { _ in [] }
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "stale-open", reason: "comment"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])

        await env.inbox.hydrate(id: "stale-open")
        #expect(env.inbox.cachedIssueState(threadId: "stale-open") == "open")
        await env.inbox.hydrate(id: "stale-open")
        #expect(hydrateCalls == 1)

        await env.inbox.refreshIssueState(threadId: "stale-open")
        #expect(hydrateCalls == 2)
        #expect(env.inbox.cachedIssueState(threadId: "stale-open") == "closed")
        #expect(try await env.threads.fetch(id: "stale-open")?.issueState == "closed")

        let callsBeforeDemo = hydrateCalls
        await env.inbox.refreshIssueState(threadId: "\(GitHubNotificationMapper.demoThreadIDPrefix)x")
        #expect(hydrateCalls == callsBeforeDemo)
        #expect(env.inbox.cachedIssueState(threadId: "\(GitHubNotificationMapper.demoThreadIDPrefix)x") == nil)
    }

    @Test("完成只 DELETE 当前 thread，成功后删本地行")
    func markThreadDoneDeletesOnlyThatRow() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([
                Self.makeDTO(id: "keep", updatedAt: "2026-08-19T01:00:00Z"),
                Self.makeDTO(id: "done", updatedAt: "2026-08-19T00:00:00Z")
            ])
        }
        env.mock.markNotificationThreadDoneHandler = { _ in }

        await env.inbox.sync()
        try await env.inbox.markThreadDone(id: "done")

        #expect(env.mock.markNotificationThreadDoneCalls == ["done"])
        #expect(try await env.threads.fetch(id: "done") == nil)
        #expect(try await env.threads.fetch(id: "keep") != nil)
        #expect(try await env.threads.totalCount() == 1)
    }

    @Test("完成遇到 404 仍清掉本地行")
    func markThreadDoneTreats404AsAlreadyDone() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([Self.makeDTO(id: "gone")])
        }
        env.mock.markNotificationThreadDoneHandler = { _ in
            throw NetworkError.notFound
        }

        await env.inbox.sync()
        try await env.inbox.markThreadDone(id: "gone")

        #expect(env.mock.markNotificationThreadDoneCalls == ["gone"])
        #expect(try await env.threads.fetch(id: "gone") == nil)
    }

    @Test("完成失败时保留本地行，也不 PATCH 其它 thread")
    func markThreadDoneFailureKeepsRow() async throws {
        let env = try makeEnv()
        env.mock.listNotificationsHandler = { _, _, _, _, _ in
            Self.listResponse([
                Self.makeDTO(id: "keep"),
                Self.makeDTO(id: "fail")
            ])
        }
        env.mock.markNotificationThreadDoneHandler = { id in
            if id == "fail" {
                throw NetworkError.serverError(statusCode: 500)
            }
        }

        await env.inbox.sync()
        await #expect(throws: NetworkError.self) {
            try await env.inbox.markThreadDone(id: "fail")
        }

        #expect(env.mock.markNotificationThreadDoneCalls == ["fail"])
        #expect(try await env.threads.fetch(id: "fail") != nil)
        #expect(try await env.threads.fetch(id: "keep") != nil)
        #expect(env.mock.markNotificationThreadReadCalls.isEmpty)
    }

    @Test("演示 thread 完成只删本地，不打 GitHub")
    func markDemoThreadDoneSkipsAPI() async throws {
        let env = try makeEnv()
        let demoID = "\(GitHubNotificationMapper.demoThreadIDPrefix)local"
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: demoID),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])

        try await env.inbox.markThreadDone(id: demoID)

        #expect(env.mock.markNotificationThreadDoneCalls.isEmpty)
        #expect(try await env.threads.fetch(id: demoID) == nil)
    }

    @Test("账本行进时间线，GitHub thread API 仍只对通知 id")
    func ledgerMergesIntoTimelineAndSkipsGitHubThreadAPIs() async throws {
        let env = try makeEnv()
        let fetchedAt = "2026-08-19T00:00:00Z"
        try await env.threads.upsertMany([
            GitHubNotificationMapper.record(
                from: Self.makeDTO(id: "n1", updatedAt: "2026-08-19T00:00:00Z"),
                fetchedAt: fetchedAt,
                firstSeenAt: fetchedAt
            )
        ])
        try await env.repos.upsertStarred(
            [Self.makeStarredDTO(id: 42, name: "hello", starredAt: "2026-08-19T12:00:00Z")],
            userID: 1,
            syncedAt: Date()
        )
        await env.inbox.backfillUserRepoActivity(userID: 1, login: "tester")

        var hydrateCalls = 0
        env.mock.hydrateNotificationSubjectHandler = { _ in
            hydrateCalls += 1
            return GitHubNotificationSubjectHydration(
                htmlURL: nil,
                actorLogin: nil,
                excerpt: nil,
                createdAt: nil,
                state: nil
            )
        }
        env.mock.markNotificationThreadDoneHandler = { _ in }

        env.inbox.listSegment = .all
        let page = await env.inbox.fetchTimelinePage(cursor: nil)
        #expect(page.rows.contains(where: { $0.id.hasPrefix("star:github_sync:42:") }))
        #expect(page.rows.contains(where: { $0.id == "n1" }))
        #expect(page.rows.first?.id.hasPrefix("star:github_sync:42:") == true)

        let starID = page.rows.first { $0.id.hasPrefix("star:") }!.id
        await env.inbox.hydrate(id: starID)
        await env.inbox.beginDwell(id: starID)
        #expect(hydrateCalls == 0)
        #expect(env.mock.markNotificationThreadReadCalls.isEmpty)

        try await env.inbox.markThreadDone(id: "n1")
        #expect(env.mock.markNotificationThreadDoneCalls == ["n1"])
        #expect(try await env.threads.fetch(id: "n1") == nil)
    }

    @Test("打开 / 关闭 / 已合并筛选只看 issue_state；closed 不含 merged")
    func issueStateSegmentsFilterPersistedState() async throws {
        let env = try makeEnv()
        let fetchedAt = "2026-08-19T00:00:00Z"
        var open = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "open-1", reason: "comment", updatedAt: "2026-08-19T03:00:00Z"),
            fetchedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
        open.issueState = "open"
        var closed = GitHubNotificationMapper.record(
            from: Self.makeDTO(id: "closed-1", reason: "comment", updatedAt: "2026-08-19T02:00:00Z"),
            fetchedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
        closed.issueState = "closed"
        var merged = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "merged-1",
                unread: false,
                reason: "comment",
                updatedAt: "2026-08-19T01:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Fix",
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
            fetchedAt: fetchedAt,
            firstSeenAt: fetchedAt
        )
        merged.issueState = "merged"
        try await env.threads.upsertMany([open, closed, merged])

        #expect(GitHubNotificationMapper.matchesSegment(open, segment: .open))
        #expect(!GitHubNotificationMapper.matchesSegment(merged, segment: .closed))
        #expect(GitHubNotificationMapper.matchesSegment(merged, segment: .merged))

        env.inbox.listSegment = .open
        var page = await env.inbox.fetchTimelinePage(cursor: nil)
        #expect(page.rows.map(\.id) == ["open-1"])

        env.inbox.listSegment = .closed
        page = await env.inbox.fetchTimelinePage(cursor: nil)
        #expect(page.rows.map(\.id) == ["closed-1"])

        env.inbox.listSegment = .merged
        page = await env.inbox.fetchTimelinePage(cursor: nil)
        #expect(page.rows.map(\.id) == ["merged-1"])
    }

    @Test("已入库 / 未入库筛选只看账本当前知识库状态")
    func libraryStateSegmentsFilterActivityRows() async throws {
        let env = try makeEnv()
        try await env.repos.upsertStarred(
            [
                Self.makeStarredDTO(id: 11, name: "in-lib", starredAt: "2026-08-19T12:00:00Z"),
                Self.makeStarredDTO(id: 12, name: "out-lib", starredAt: "2026-08-19T11:00:00Z")
            ],
            userID: 1,
            syncedAt: Date()
        )
        await env.inbox.backfillUserRepoActivity(userID: 1, login: "tester")
        let notes = GRDBRepoNoteRepository(database: env.db)
        try await notes.updateLibraryState(repoId: 11, state: .inLibrary)

        env.inbox.listSegment = .inLibrary
        var page = await env.inbox.fetchTimelinePage(cursor: nil)
        let inIDs = page.rows.compactMap { row -> Int64? in
            guard case .activity(let item) = row else { return nil }
            return item.record.repoId
        }
        #expect(inIDs == [11])
        if case .activity(let item) = page.rows.first {
            #expect(item.libraryState == .inLibrary)
        } else {
            Issue.record("expected an activity row")
        }

        env.inbox.listSegment = .outsideLibrary
        page = await env.inbox.fetchTimelinePage(cursor: nil)
        let outIDs = page.rows.compactMap { row -> Int64? in
            guard case .activity(let item) = row else { return nil }
            return item.record.repoId
        }
        #expect(outIDs == [12])
        if case .activity(let item) = page.rows.first {
            #expect(item.libraryState == .outsideLibrary)
        } else {
            Issue.record("expected an activity row")
        }
    }

    // MARK: - Harness

    private struct Env {
        let db: InMemoryDatabaseManager
        let threads: GRDBGitHubNotificationThreadRepository
        let syncState: GRDBGitHubNotificationSyncStateRepository
        let repos: GRDBRepoRepository
        let activity: GRDBUserRepoActivityRepository
        let mock: MockGitHubAPIClient
        let dispatcher: RecordingNotificationDispatcher
        let settings: AppSettings
        let inbox: GitHubNotificationInboxService
        let issueTimelineDiskCache: DiskIssueTimelineCache
    }

    private func makeEnv(
        dwellNanoseconds: UInt64 = 1_000,
        clock: @escaping () -> Date = Date.init,
        issueTimelineDiskCache: DiskIssueTimelineCache? = nil
    ) throws -> Env {
        let db = try InMemoryDatabaseManager()
        let threads = GRDBGitHubNotificationThreadRepository(database: db)
        let syncState = GRDBGitHubNotificationSyncStateRepository(database: db)
        let repos = GRDBRepoRepository(database: db)
        let activity = GRDBUserRepoActivityRepository(database: db)
        let mock = MockGitHubAPIClient()
        mock.markNotificationThreadReadHandler = { _ in }
        mock.hydrateNotificationSubjectHandler = { _ in
            GitHubNotificationSubjectHydration(htmlURL: nil, actorLogin: nil, excerpt: nil, createdAt: nil, state: nil)
        }
        let defaults = UserDefaults(suiteName: "test.starcat.github-inbox.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        let dispatcher = RecordingNotificationDispatcher()
        let notifications = AppNotificationService(dispatcher: dispatcher, settings: settings)
        let disk = issueTimelineDiskCache ?? DiskIssueTimelineCache(
            rootOverride: FileManager.default.temporaryDirectory
                .appendingPathComponent("starcat-inbox-timeline-\(UUID().uuidString)", isDirectory: true)
        )
        let inbox = GitHubNotificationInboxService(
            apiClient: mock,
            threadRepository: threads,
            syncStateRepository: syncState,
            notificationService: notifications,
            settings: settings,
            activityRepository: activity,
            clock: clock,
            dwellNanoseconds: dwellNanoseconds,
            issueTimelineDiskCache: disk
        )
        return Env(
            db: db,
            threads: threads,
            syncState: syncState,
            repos: repos,
            activity: activity,
            mock: mock,
            dispatcher: dispatcher,
            settings: settings,
            inbox: inbox,
            issueTimelineDiskCache: disk
        )
    }

    private static func makeDTO(
        id: String,
        unread: Bool = true,
        reason: String = "mention",
        updatedAt: String = "2026-08-19T00:00:00Z",
        subjectType: String = "Issue"
    ) -> GitHubNotificationThreadDTO {
        let subjectURL: String
        switch subjectType {
        case "PullRequest":
            subjectURL = "https://api.github.com/repos/o/r/pulls/1"
        case "Discussion":
            subjectURL = "https://api.github.com/repos/o/r/discussions/1"
        default:
            subjectURL = "https://api.github.com/repos/o/r/issues/1"
        }
        return GitHubNotificationThreadDTO(
            id: id,
            unread: unread,
            reason: reason,
            updatedAt: updatedAt,
            subject: GitHubNotificationSubjectDTO(
                title: "Issue \(id)",
                url: subjectURL,
                latestCommentUrl: nil,
                type: subjectType
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

    private static func makeStarredDTO(
        id: Int64,
        name: String,
        starredAt: String,
        fork: Bool = false,
        createdAt: String? = nil
    ) -> StarredRepoDTO {
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
            fork: fork,
            archived: false,
            pushedAt: nil,
            createdAt: createdAt,
            updatedAt: starredAt,
            openIssuesCount: nil,
            defaultBranch: nil,
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: starredAt, repo: repo)
    }
}

private struct RecordedNotification: Sendable {
    let identifier: String
    let title: String
    let body: String
    let threadID: String?
}

private final class RecordingNotificationDispatcher: NotificationDispatching, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[RecordedNotification]>(initialState: [])

    func requestAuthorization() async throws -> Bool { true }

    func add(request: UNNotificationRequest) async throws {
        let snapshot = RecordedNotification(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            threadID: request.content.userInfo["threadId"] as? String
        )
        lock.withLock { $0.append(snapshot) }
    }

    var requestIdentifiers: [String] {
        lock.withLock { $0.map(\.identifier) }
    }

    var requests: [RecordedNotification] {
        lock.withLock { $0 }
    }
}
