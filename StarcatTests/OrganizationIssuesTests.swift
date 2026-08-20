//
//  OrganizationIssuesTests.swift
//  StarcatTests
//
//  验证组织 Issue 端点请求契约、PR 排除，以及统一时间线的持久化去重。
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
                "url": "https://api.github.com/repos/starcat-app/starcat-pro/issues/1",
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
                "url": "https://api.github.com/repos/starcat-app/starcat-pro/issues/2",
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
        #expect(issue.subjectAPIURL == "https://api.github.com/repos/starcat-app/starcat-pro/issues/1")
        #expect(issue.number == 1)
        #expect(issue.authorLogin == "dong4j")
        #expect(issue.labels.map(\.name) == ["enhancement"])
        #expect(response.linkHeader.nextPage == 2)
    }

    @Test("组织 Issue 持久化后与同 subject 通知合并，Done 只移除通知 overlay")
    func timelinePersistenceAndSourceDeduplication() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBGitHubNotificationThreadRepository(database: database)
        let issue = makeIssue(
            id: 1,
            repository: "starcat-app/starcat-pro",
            number: 1,
            updatedAt: "2026-08-21T00:00:00Z"
        )

        try await repository.upsertOrganizationIssues(
            [issue],
            credentialSource: .projectAccess,
            fetchedAt: "2026-08-21T01:00:00Z"
        )
        var rows = try await repository.fetchAll(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].id == "organization-issue:1")
        #expect(rows[0].remoteNotificationThreadID == nil)
        #expect(rows[0].unread == false)
        #expect(rows[0].credentialSource == GitHubTimelineCredentialSource.projectAccess.rawValue)

        let notification = GitHubNotificationMapper.record(
            from: GitHubNotificationThreadDTO(
                id: "thread-1",
                unread: true,
                reason: "mention",
                updatedAt: "2026-08-21T02:00:00Z",
                subject: GitHubNotificationSubjectDTO(
                    title: "Issue #1",
                    url: issue.subjectAPIURL,
                    latestCommentUrl: nil,
                    type: "Issue"
                ),
                repository: GitHubNotificationRepositoryDTO(
                    id: 99,
                    fullName: issue.repositoryFullName,
                    name: "starcat-pro",
                    owner: GitHubNotificationOwnerDTO(login: "starcat-app")
                )
            ),
            fetchedAt: "2026-08-21T02:00:00Z",
            firstSeenAt: "2026-08-21T02:00:00Z"
        )
        try await repository.upsertMany([notification])

        rows = try await repository.fetchAll(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].id == "thread-1")
        #expect(rows[0].remoteNotificationThreadID == "thread-1")
        #expect(rows[0].organizationLogin == "starcat-app")

        try await repository.removeNotificationThread(id: "thread-1")
        rows = try await repository.fetchAll(limit: 10)
        #expect(rows.count == 1)
        #expect(rows[0].remoteNotificationThreadID == nil)
        #expect(rows[0].unread == false)

        let timelineRepository = GRDBUserRepoActivityRepository(database: database)
        let page = try await timelineRepository.fetchPage(segment: .issue, cursor: nil, limit: 20)
        #expect(page.rows.map(\.id) == ["thread-1"])
    }

    @Test("组织分页状态按凭据隔离并可恢复")
    func paginationStatePersistsPerCredential() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBGitHubNotificationThreadRepository(database: database)
        try await repository.updateOrganizationIssueSyncState(
            organization: "starcat-app",
            credentialSource: .projectAccess,
            nextPage: 4,
            watermarkUpdatedAt: "2026-08-21T02:00:00Z",
            backfillCompletedAt: nil,
            lastFetchedAt: "2026-08-21T03:00:00Z",
            lastError: nil
        )

        let state = try #require(await repository.organizationIssueSyncState(
            organization: "starcat-app",
            credentialSource: .projectAccess
        ))
        #expect(state.nextPage == 4)
        #expect(state.watermarkUpdatedAt == "2026-08-21T02:00:00Z")
        #expect(try await repository.organizationIssueSyncState(
            organization: "starcat-app",
            credentialSource: .primaryOAuth
        ) == nil)
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
            subjectAPIURL: "https://api.github.com/repos/\(repository)/issues/\(number)",
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
