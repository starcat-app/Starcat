//
//  OrganizationIssuesTests.swift
//  StarcatTests
//
//  验证组织 Issue 端点请求契约、PR 排除，以及双凭据结果的稳定去重排序。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Organization Issues", .serialized)
struct OrganizationIssuesTests {

    @Test("组织端点使用 filter=all，排除 Pull Request，并保留分页")
    func endpointExcludesPullRequests() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(request.url?.path == "/orgs/starcat-app/issues")
            #expect(query["filter"] == "all")
            #expect(query["state"] == "open")
            #expect(query["sort"] == "updated")
            #expect(query["direction"] == "desc")
            #expect(query["page"] == "1")
            #expect(query["per_page"] == "100")

            let body = #"""
            [
              {
                "id": 101,
                "number": 1,
                "title": "Organization inbox",
                "state": "open",
                "body": "Issue body",
                "html_url": "https://github.com/starcat-app/starcat-pro/issues/1",
                "repository_url": "https://api.github.com/repos/starcat-app/starcat-pro",
                "user": { "login": "dong4j" },
                "assignees": [{ "login": "dong4j" }],
                "labels": [{ "name": "enhancement", "color": "a2eeef" }],
                "comments": 2,
                "created_at": "2026-08-20T00:00:00Z",
                "updated_at": "2026-08-21T00:00:00Z",
                "closed_at": null
              },
              {
                "id": 102,
                "number": 2,
                "title": "A pull request",
                "state": "open",
                "body": null,
                "html_url": "https://github.com/starcat-app/starcat-pro/pull/2",
                "repository_url": "https://api.github.com/repos/starcat-app/starcat-pro",
                "user": { "login": "dong4j" },
                "assignees": [],
                "labels": [],
                "comments": 0,
                "created_at": "2026-08-20T00:00:00Z",
                "updated_at": "2026-08-21T00:00:00Z",
                "closed_at": null,
                "pull_request": { "url": "https://api.github.com/repos/starcat-app/starcat-pro/pulls/2" }
              }
            ]
            """#.data(using: .utf8)!
            let headers = [
                "Link": "<https://api.test.invalid/orgs/starcat-app/issues?page=2&per_page=100>; rel=\"next\""
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: headers
                )!,
                body
            )
        }

        let client = GitHubAPIClient(
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "gh-test")
        )
        let response = try await client.organizationIssues(
            organization: "starcat-app",
            state: .open,
            page: 1,
            perPage: 100
        )

        #expect(response.value.count == 1)
        let issue = try #require(response.value.first)
        #expect(issue.repositoryFullName == "starcat-app/starcat-pro")
        #expect(issue.number == 1)
        #expect(issue.authorLogin == "dong4j")
        #expect(issue.labels.map(\.name) == ["enhancement"])
        #expect(response.linkHeader.nextPage == 2)
    }

    @Test("主 OAuth 与 GitHub App 的重复 Issue 只保留一条并按更新时间倒序")
    func mergedResultsDeduplicateAndSort() throws {
        let old = makeIssue(id: 1, repository: "starcat-app/starcat-pro", number: 1, updatedAt: "2026-08-20T00:00:00Z")
        let refreshed = makeIssue(id: 1, repository: "starcat-app/starcat-pro", number: 1, updatedAt: "2026-08-21T00:00:00Z")
        let another = makeIssue(id: 2, repository: "starcat-app/Starcat", number: 63, updatedAt: "2026-08-20T12:00:00Z")

        let merged = OrganizationIssueInboxService.mergedAndSorted([old, another, refreshed])

        #expect(merged.count == 2)
        #expect(merged[0].deduplicationKey == "starcat-app/starcat-pro#1")
        #expect(merged[0].updatedAt == refreshed.updatedAt)
        #expect(merged[1].deduplicationKey == "starcat-app/starcat#63")
    }

    private func makeIssue(
        id: Int64,
        repository: String,
        number: Int,
        updatedAt: String
    ) -> GitHubOrganizationIssue {
        let formatter = ISO8601DateFormatter()
        return GitHubOrganizationIssue(
            id: id,
            organization: "starcat-app",
            repositoryFullName: repository,
            number: number,
            title: "Issue #\(number)",
            state: .open,
            body: nil,
            htmlURL: URL(string: "https://github.com/\(repository)/issues/\(number)")!,
            authorLogin: "dong4j",
            assigneeLogins: [],
            labels: [],
            commentsCount: 0,
            createdAt: formatter.date(from: "2026-08-19T00:00:00Z"),
            updatedAt: formatter.date(from: updatedAt),
            closedAt: nil
        )
    }
}
