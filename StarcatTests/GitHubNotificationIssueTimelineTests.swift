//
//  GitHubNotificationIssueTimelineTests.swift
//  StarcatTests
//
//  Issue 事件流解析。不碰 comments_json / hydrate。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubNotificationIssueTimeline")
struct GitHubNotificationIssueTimelineTests {

    @Test("timeline 路径走 issues，不走 pulls")
    func resourcePathUsesIssues() {
        #expect(
            GitHubNotificationIssueTimelineParser.resourcePath(
                repositoryFullName: "octo/hello",
                number: 3
            ) == "/repos/octo/hello/issues/3/timeline"
        )
    }

    @Test("交叉引用标题把数字收成字符串，避免 %@ 吃 Int 崩溃")
    func crossRefTitleStringifiesNumber() {
        let pull = GitHubNotificationIssueTimelineParser.crossRefTitle(
            number: 4,
            isPullRequest: true
        )
        let issue = GitHubNotificationIssueTimelineParser.crossRefTitle(
            number: 12,
            isPullRequest: false
        )
        #expect(!pull.isEmpty)
        #expect(!issue.isEmpty)
        #expect(pull.contains("4") || pull.contains("crossRefPR"))
        #expect(issue.contains("12") || issue.contains("crossRefIssue"))
    }

    @Test("commit 只显示短 SHA")
    func shortSHAUsesFirstSeven() {
        #expect(
            GitHubNotificationIssueTimelineParser.shortSHA(
                "6dcb09b5b57875f334f61aebed695e2e4193db5e"
            ) == "6dcb09b"
        )
        #expect(GitHubNotificationIssueTimelineParser.shortSHA("abc") == "abc")
        #expect(
            GitHubNotificationIssueTimelineParser.commitHTMLURL(
                repositoryFullName: "octo/hello",
                sha: "6dcb09b5b57875f334f61aebed695e2e4193db5e"
            )?.absoluteString == "https://github.com/octo/hello/commit/6dcb09b5b57875f334f61aebed695e2e4193db5e"
        )
    }

    @Test("白名单 event 按原序留下，未知 event 丢掉")
    func parseKeepsWhitelistAndDropsUnknown() throws {
        let items = GitHubNotificationIssueTimelineParser.parse(try fixtureJSON())
        #expect(items.count == 8)

        guard case .event(let labeled) = items[0] else {
            Issue.record("expected labeled")
            return
        }
        #expect(labeled.kind == .labeled)
        #expect(labeled.actorLogin == "dong4j")
        #expect(labeled.label?.name == "bug")
        #expect(labeled.label?.colorHex == "d73a4a")

        guard case .comment(let comment) = items[1] else {
            Issue.record("expected comment")
            return
        }
        #expect(comment.id == 99)
        #expect(comment.login == "octocat")
        #expect(comment.body == "please take a look")

        guard case .event(let referenced) = items[2] else {
            Issue.record("expected referenced")
            return
        }
        #expect(referenced.kind == .referenced)
        #expect(referenced.commitSHA == "6dcb09b5b57875f334f61aebed695e2e4193db5e")
        #expect(
            GitHubNotificationIssueTimelineParser.shortSHA(referenced.commitSHA ?? "") == "6dcb09b"
        )

        guard case .event(let crossIssue) = items[3] else {
            Issue.record("expected cross-referenced issue")
            return
        }
        #expect(crossIssue.kind == .crossReferenced)
        #expect(crossIssue.crossRefNumber == 12)
        #expect(crossIssue.isCrossRefPullRequest == false)

        guard case .event(let crossPR) = items[4] else {
            Issue.record("expected cross-referenced PR")
            return
        }
        #expect(crossPR.isCrossRefPullRequest == true)
        #expect(crossPR.crossRefNumber == 8)

        guard case .event(let renamed) = items[5] else {
            Issue.record("expected renamed")
            return
        }
        #expect(renamed.renameFrom == "old")
        #expect(renamed.renameTo == "new")

        guard case .event(let closed) = items[6] else {
            Issue.record("expected closed")
            return
        }
        #expect(closed.kind == .closed)

        guard case .event(let reopened) = items[7] else {
            Issue.record("expected reopened")
            return
        }
        #expect(reopened.kind == .reopened)
    }

    @Test("GitHub 大整数 id 仍能解析 labeled / referenced")
    func parseKeepsLargeGitHubEventIDs() throws {
        let json = """
        [
          {
            "id": 29835927043,
            "event": "labeled",
            "actor": {"login": "dong4j"},
            "created_at": "2026-08-22T02:11:00Z",
            "label": {"name": "bug", "color": "d73a4a"}
          },
          {
            "id": 29836249630,
            "event": "referenced",
            "actor": {"login": "dong4j"},
            "commit_id": "fc6fb64209a2c22fc6db6aaa4fb68baafe2e1f30",
            "created_at": "2026-08-22T02:20:00Z"
          }
        ]
        """.data(using: .utf8)!
        let items = GitHubNotificationIssueTimelineParser.parse(json)
        #expect(items.count == 2)
        guard case .event(let labeled) = items[0] else {
            Issue.record("expected labeled")
            return
        }
        #expect(labeled.label?.name == "bug")
        guard case .event(let referenced) = items[1] else {
            Issue.record("expected referenced")
            return
        }
        #expect(
            GitHubNotificationIssueTimelineParser.shortSHA(referenced.commitSHA ?? "") == "fc6fb64"
        )
    }

    @Test("缺 SHA 的 referenced 与缺标签的 labeled 丢掉")
    func parseDropsIncompleteEvents() throws {
        let json = """
        [
          {"id": 1, "event": "referenced", "actor": {"login": "a"}, "created_at": "2026-01-01T00:00:00Z"},
          {"id": 2, "event": "labeled", "actor": {"login": "a"}, "created_at": "2026-01-01T00:00:00Z"},
          {"id": 3, "event": "subscribed", "actor": {"login": "a"}, "created_at": "2026-01-01T00:00:00Z"}
        ]
        """.data(using: .utf8)!
        #expect(GitHubNotificationIssueTimelineParser.parse(json).isEmpty)
    }

    private func fixtureJSON() throws -> Data {
        let json = """
        [
          {
            "id": 1,
            "event": "labeled",
            "actor": {"login": "dong4j"},
            "created_at": "2026-01-01T00:00:00Z",
            "label": {"name": "bug", "color": "d73a4a"}
          },
          {
            "id": 99,
            "event": "commented",
            "actor": {"login": "octocat"},
            "user": {"login": "octocat"},
            "body": "please take a look",
            "html_url": "https://github.com/octo/hello/issues/3#issuecomment-99",
            "created_at": "2026-01-01T00:01:00Z"
          },
          {
            "id": 2,
            "event": "referenced",
            "actor": {"login": "dong4j"},
            "commit_id": "6dcb09b5b57875f334f61aebed695e2e4193db5e",
            "created_at": "2026-01-01T00:02:00Z"
          },
          {
            "id": 3,
            "event": "cross-referenced",
            "actor": {"login": "octocat"},
            "created_at": "2026-01-01T00:03:00Z",
            "source": {
              "type": "issue",
              "issue": {
                "number": 12,
                "html_url": "https://github.com/octo/hello/issues/12"
              }
            }
          },
          {
            "id": 4,
            "event": "cross-referenced",
            "actor": {"login": "octocat"},
            "created_at": "2026-01-01T00:04:00Z",
            "source": {
              "type": "issue",
              "issue": {
                "number": 8,
                "html_url": "https://github.com/octo/hello/pull/8",
                "pull_request": {
                  "html_url": "https://github.com/octo/hello/pull/8"
                }
              }
            }
          },
          {
            "id": 5,
            "event": "renamed",
            "actor": {"login": "dong4j"},
            "created_at": "2026-01-01T00:05:00Z",
            "rename": {"from": "old", "to": "new"}
          },
          {
            "id": 6,
            "event": "added_to_project_v2",
            "actor": {"login": "dong4j"},
            "created_at": "2026-01-01T00:06:00Z"
          },
          {
            "id": 7,
            "event": "closed",
            "actor": {"login": "dong4j"},
            "created_at": "2026-01-01T00:07:00Z"
          },
          {
            "id": 8,
            "event": "reopened",
            "actor": {"login": "dong4j"},
            "created_at": "2026-01-01T00:08:00Z"
          }
        ]
        """
        return try #require(json.data(using: .utf8))
    }
}
