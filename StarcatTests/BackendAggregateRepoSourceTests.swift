//
//  BackendAggregateRepoSourceTests.swift
//  StarcatTests
//
//  R-01 v1.2 BackendAggregateRepoSource 单元测试。
//
//  覆盖：
//  - 200 命中：weekly 后端 envelope 正常返回 → toEphemeralRepo 后给 chain
//  - 401 鉴权失败：catch 错误后返 nil（让 chain 继续询问 GitHubFallback）
//  - 404 项目不在周刊：catch 后返 nil
//  - 网络错误：catch 后返 nil
//

import Testing
import Foundation
@testable import Starcat

private func aggResp(_ status: Int, _ url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

@Suite("BackendAggregateRepoSource")
struct BackendAggregateRepoSourceTests {

    @Test("200 envelope 命中 → 转 ephemeral Repo 返回")
    func resolves200Envelope() async throws {
        URLProtocolStub.reset()
        let weeklyAPI = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            apiKey: "test-key",
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            // 验证 path = /api/v1/weekly/alice/foo（v0.5.2 dong4j 重命名从 /api/v1/projects/）
            #expect(request.url?.path == "/api/v1/weekly/alice/foo")
            // 验证 Bearer header
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

            let body = #"""
            {
              "schema_version": 1,
              "data": {
                "gh_repo_id": 42,
                "full_name": "alice/foo",
                "owner": "alice",
                "repo": "foo",
                "description": "Aggregated by weekly",
                "language": "Swift",
                "stars": 100,
                "forks": 10,
                "watchers": 100,
                "subscribers": 5,
                "topics": ["ai"],
                "is_archived": false,
                "is_fork": false,
                "is_private": false,
                "open_issues": 1,
                "html_url": "https://github.com/alice/foo",
                "weekly": {
                  "first_issue": 380,
                  "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-380.md"
                }
              }
            }
            """#.data(using: .utf8)!
            return (aggResp(200, request.url!), body)
        }

        let source = BackendAggregateRepoSource(weeklyAPI: weeklyAPI)
        let repo = try await source.tryResolve(owner: "alice", name: "foo", hint: nil)

        let r = try #require(repo)
        #expect(r.id == 42)
        #expect(r.fullName == "alice/foo")
        #expect(r.starsCount == 100)
        #expect(r.isStarred == false, "ephemeral repo 永远 isStarred = false（StarredRegistry 才是真相）")
    }

    @Test("404 错误 → 返 nil（让 chain 继续）")
    func returns404AsNil() async throws {
        URLProtocolStub.reset()
        let weeklyAPI = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            apiKey: "test-key",
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            { "schema_version": 1, "error": { "code": "NOT_FOUND", "message": "project not found" } }
            """#.data(using: .utf8)!
            return (aggResp(404, request.url!), body)
        }

        let source = BackendAggregateRepoSource(weeklyAPI: weeklyAPI)
        let repo = try await source.tryResolve(owner: "ghost", name: "x", hint: nil)
        #expect(repo == nil, "404 应当 catch 后返 nil，让 chain 继续询问下一个 source")
    }

    @Test("401 鉴权失败 → 返 nil（不抛错击穿 chain）")
    func returns401AsNil() async throws {
        URLProtocolStub.reset()
        let weeklyAPI = WeeklyAPI(
            baseURL: URL(string: "https://weekly.test.invalid")!,
            // apiKey 故意为 nil 模拟未配置场景
            session: URLProtocolStub.ephemeralSession()
        )

        URLProtocolStub.requestHandler = { request in
            let body = #"""
            { "schema_version": 1, "error": { "code": "UNAUTHORIZED", "message": "missing Authorization header" } }
            """#.data(using: .utf8)!
            return (aggResp(401, request.url!), body)
        }

        let source = BackendAggregateRepoSource(weeklyAPI: weeklyAPI)
        let repo = try await source.tryResolve(owner: "alice", name: "foo", hint: nil)
        #expect(repo == nil, "401 应当 catch 后返 nil")
    }
}
