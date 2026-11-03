//
//  RepoIssuesAPITests.swift
//  StarcatTests
//
//  验证 /repos/{owner}/{repo}/issues（列表 + 新建）与 /search/issues 的请求参数、
//  DTO 解析边界：PR 排除、label 映射、ISO8601 时间、Link 分页。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoIssuesAPI", .serialized)
struct RepoIssuesAPITests {
    private let baseURL = URL(string: "https://api.test.invalid")!

    private func makeClient() -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "issues-token")
        )
    }

    private func response(
        _ statusCode: Int,
        url: URL,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    /// 两条 issue + 一条 PR 混入，覆盖 label / 时间 / state 字段。
    private var issueListJSON: Data {
        Data(
            """
            [
              {
                "id": 1001,
                "number": 12,
                "title": "支持按仓库保存 Issue 草稿",
                "state": "open",
                "body": "切换仓库时保留未提交内容。",
                "html_url": "https://github.com/starcat-app/Starcat/issues/12",
                "user": {"login": "dong4j"},
                "labels": [{"name": "enhancement", "color": "0e8a16"}],
                "comments": 3,
                "created_at": "2026-10-30T08:00:00Z",
                "updated_at": "2026-10-31T09:30:00Z",
                "closed_at": null
              },
              {
                "id": 1002,
                "number": 13,
                "title": "切仓库后阅读位置丢失",
                "state": "open",
                "body": null,
                "html_url": "https://github.com/starcat-app/Starcat/issues/13",
                "user": {"login": "alex"},
                "labels": [{"name": "bug", "color": "d73a4a"}, {"name": "needs-triage", "color": null}],
                "comments": 0,
                "created_at": "2026-10-29T10:00:00Z",
                "updated_at": "2026-10-30T12:00:00Z",
                "closed_at": null
              },
              {
                "id": 1003,
                "number": 14,
                "title": "PR 标题混进列表",
                "state": "open",
                "body": null,
                "html_url": "https://github.com/starcat-app/Starcat/pull/14",
                "user": {"login": "mia"},
                "labels": [],
                "comments": 1,
                "created_at": "2026-10-28T10:00:00Z",
                "updated_at": "2026-10-29T12:00:00Z",
                "closed_at": null,
                "pull_request": {"merged_at": null}
              }
            ]
            """.utf8
        )
    }

    @Test("列表请求携带查询参数并解析，PR 在 API 边界被排除")
    func listParsesAndExcludesPullRequests() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let headers = [
                "Link": "<https://api.test.invalid/repos/starcat-app/Starcat/issues?page=2&per_page=30>; rel=\"next\""
            ]
            return (self.response(200, url: request.url!, headers: headers), self.issueListJSON)
        }

        let result = try await client.repoIssues(
            owner: "starcat-app",
            repo: "Starcat",
            state: .open,
            page: 1,
            perPage: 30
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/repos/starcat-app/Starcat/issues")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer issues-token")
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(values["state"] == "open")
        #expect(values["sort"] == "updated")
        #expect(values["direction"] == "desc")
        #expect(values["page"] == "1")
        #expect(values["per_page"] == "30")

        #expect(result.linkHeader.nextPage == 2)
        // PR 混入条目必须在 API 边界被丢掉；空名 label 也要被过滤。
        #expect(result.value.count == 2)
        let first = try #require(result.value.first)
        #expect(first.number == 12)
        #expect(first.state == .open)
        #expect(first.authorLogin == "dong4j")
        #expect(first.labels == [GitHubRepoIssueLabel(name: "enhancement", colorHex: "0e8a16")])
        #expect(first.commentsCount == 3)
        let second = try #require(result.value.last)
        #expect(second.labels.count == 2)
        #expect(second.labels.first?.colorHex == "d73a4a")
        // color 缺失时回退中性灰。
        #expect(second.labels.last?.colorHex == "6e7781")
        #expect(second.updatedAt != nil)
    }

    @Test("search 请求携带 q 并解析 total_count")
    func searchParsesTotalCount() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let json = Data(
                """
                {
                  "total_count": 12,
                  "incomplete_results": false,
                  "items": [
                    {
                      "id": 2001,
                      "number": 7,
                      "title": "MCP 服务启动状态未更新",
                      "state": "open",
                      "html_url": "https://github.com/starcat-app/Starcat/issues/7",
                      "user": {"login": "sam"},
                      "labels": [],
                      "comments": 1,
                      "created_at": "2026-10-01T00:00:00Z",
                      "updated_at": "2026-10-02T00:00:00Z"
                    }
                  ]
                }
                """.utf8
            )
            return (self.response(200, url: request.url!), json)
        }

        let result = try await client.searchIssues(
            query: "repo:starcat-app/Starcat is:issue is:open 草稿",
            page: 1,
            perPage: 1
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/search/issues")
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(values["q"] == "repo:starcat-app/Starcat is:issue is:open 草稿")
        #expect(values["per_page"] == "1")

        #expect(result.value.totalCount == 12)
        #expect(result.value.items.count == 1)
        #expect(result.value.items.first?.number == 7)
    }

    @Test("连续纯 PR 页会继续读取到 Issue，并保留实际下一页游标")
    func skipsPullRequestOnlyPages() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let page = query?.first(where: { $0.name == "page" })?.value ?? "1"
            let nextPage = page == "1" ? 2 : page == "2" ? 3 : 4
            let headers = ["Link": "<https://api.test.invalid/repos/example/repo/issues?page=\(nextPage)>; rel=\"next\""]
            let body = page == "3" ? self.issueListJSON : self.pullRequestOnlyJSON
            return (self.response(200, url: request.url!, headers: headers), body)
        }

        let result = try await client.repoIssues(owner: "example", repo: "repo", state: .open, page: 1, perPage: 30)

        #expect(result.value.map(\.number) == [12, 13])
        #expect(result.linkHeader.nextPage == 4)
        #expect(URLProtocolStub.receivedRequests.count == 3)
    }

    @Test("只有 PR 且到达末页时才返回真正的空 Issue 列表")
    func pullRequestOnlyLastPageEndsPagination() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let page = query?.first(where: { $0.name == "page" })?.value
            let headers = page == "1"
                ? ["Link": "<https://api.test.invalid/repos/example/repo/issues?page=2>; rel=\"next\""]
                : [:]
            return (self.response(200, url: request.url!, headers: headers), self.pullRequestOnlyJSON)
        }

        let result = try await client.repoIssues(owner: "example", repo: "repo", state: .open, page: 1, perPage: 30)

        #expect(result.value.isEmpty)
        #expect(result.linkHeader.nextPage == nil)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }

    /// 最小的纯 PR 原始响应，保留真实端点会返回的 pull_request 标识。
    private var pullRequestOnlyJSON: Data {
        Data(#"[{"id":1003,"number":14,"title":"Pull request","state":"open","html_url":"https://github.com/example/repo/pull/14","labels":[],"comments":0,"pull_request":{}}]"#.utf8)
    }

    @Test("新建 Issue 走 POST 到仓库 issues 路径并解析返回的 issue")
    func createPostsAndParses() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let json = Data(
                """
                {
                  "id": 3001,
                  "number": 99,
                  "title": "增加快捷说明",
                  "state": "open",
                  "body": "## 使用场景",
                  "html_url": "https://github.com/starcat-app/Starcat/issues/99",
                  "user": {"login": "dong4j"},
                  "labels": [],
                  "comments": 0,
                  "created_at": "2026-11-01T00:00:00Z",
                  "updated_at": "2026-11-01T00:00:00Z"
                }
                """.utf8
            )
            return (self.response(201, url: request.url!), json)
        }

        let issue = try await client.createRepoIssue(
            owner: "starcat-app",
            repo: "Starcat",
            title: "增加快捷说明",
            body: "## 使用场景"
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/repos/starcat-app/Starcat/issues")
        #expect(request.httpMethod == "POST")
        // Apple 的 URLSession 会把 httpBody 内化到 task 缓冲区，URLProtocol 看不到
        // body（见 AnySearchClientTests 注释）；body 编码契约由 `Payload` 结构体的
        // 类型系统保证，这里只断言 URLProtocol 真能看到的部分。
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer issues-token")

        #expect(issue.number == 99)
        #expect(issue.title == "增加快捷说明")
        #expect(issue.state == .open)
        #expect(issue.authorLogin == "dong4j")
    }
}
