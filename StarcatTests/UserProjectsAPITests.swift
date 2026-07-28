//
//  UserProjectsAPITests.swift
//  StarcatTests
//
//  验证 /user/repos 的查询边界、DTO、分页元数据、ETag 和关键错误分类。
//

import Foundation
import Testing
@testable import Starcat

@Suite("UserProjectsAPI", .serialized)
struct UserProjectsAPITests {
    private let baseURL = URL(string: "https://api.test.invalid")!

    private func makeClient() -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "project-token")
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

    private var projectJSON: Data {
        Data(
            """
            [{
              "id": 88,
              "name": "private-tool",
              "full_name": "Acme/private-tool",
              "owner": {"id": 9, "login": "Acme", "type": "Organization"},
              "description": "internal",
              "language": "Swift",
              "stargazers_count": 12,
              "forks_count": 1,
              "watchers_count": 12,
              "topics": ["swift"],
              "license": null,
              "homepage": null,
              "html_url": "https://github.com/Acme/private-tool",
              "clone_url": "https://github.com/Acme/private-tool.git",
              "ssh_url": "git@github.com:Acme/private-tool.git",
              "private": true,
              "visibility": "internal",
              "fork": false,
              "archived": false,
              "pushed_at": "2026-07-01T00:00:00Z",
              "created_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-07-01T00:00:00Z",
              "permissions": {
                "admin": false,
                "maintain": true,
                "push": true,
                "triage": true,
                "pull": true
              }
            }]
            """.utf8
        )
    }

    @Test("组织项目请求携带完整查询、条件头并解析 DTO 与分页")
    func requestAndDecode() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let headers = [
                "ETag": "\"projects-v1\"",
                "Link": "<https://api.test.invalid/user/repos?page=2&per_page=100>; rel=\"next\""
            ]
            return (response(200, url: request.url!, headers: headers), projectJSON)
        }

        let result = try await client.userProjects(
            affiliation: .organizationMember,
            visibility: .all,
            page: 1,
            perPage: 100,
            ifNoneMatch: "\"old\""
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(request.url?.path == "/user/repos")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"old\"")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer project-token")
        #expect(values["affiliation"] == "organization_member")
        #expect(values["visibility"] == "all")
        #expect(values["sort"] == "updated")
        #expect(values["direction"] == "desc")
        #expect(values["page"] == "1")
        #expect(values["per_page"] == "100")
        #expect(result.etag == "\"projects-v1\"")
        #expect(result.linkHeader.nextPage == 2)

        let project = try #require(result.value.first)
        #expect(project.repo.id == 88)
        #expect(project.ownerType == .organization)
        #expect(project.visibility == .internal)
        #expect(project.permission == .maintain)
        #expect(project.remoteProject(affiliation: .organizationMember).affiliation == .organizationMember)
    }

    @Test("OAuth fallback 固定 public 且不包含 collaborator")
    func oauthFallbackQuery() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            (response(200, url: request.url!), Data("[]".utf8))
        }

        _ = try await client.userProjects(
            affiliation: .owner,
            visibility: .publicOnly,
            page: 1,
            perPage: 50,
            ifNoneMatch: nil
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first(where: { $0.name == "affiliation" })?.value == "owner")
        #expect(query.first(where: { $0.name == "visibility" })?.value == "public")
        #expect(request.url?.absoluteString.contains("collaborator") == false)
    }

    @Test("304 条件命中保留 ETag")
    func notModified() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            (response(304, url: request.url!, headers: ["ETag": "\"same\""]), Data())
        }

        do {
            _ = try await client.userProjects(
                affiliation: .owner,
                visibility: .publicOnly,
                page: 1,
                perPage: 100,
                ifNoneMatch: "\"same\""
            )
            Issue.record("期望 304 被映射为 notModified")
        } catch NetworkError.notModified(let etag) {
            #expect(etag == "\"same\"")
        }
    }

    @Test(arguments: [401, 403])
    func authenticationErrors(statusCode: Int) async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            (response(statusCode, url: request.url!), Data(#"{"message":"denied"}"#.utf8))
        }

        do {
            _ = try await client.userProjects(
                affiliation: .owner,
                visibility: .all,
                page: 1,
                perPage: 100,
                ifNoneMatch: nil
            )
            Issue.record("期望请求失败")
        } catch NetworkError.unauthorized where statusCode == 401 {
            // 通过
        } catch NetworkError.clientError(let code, _) where statusCode == 403 {
            #expect(code == 403)
        } catch {
            Issue.record("错误分类不匹配: \(error)")
        }
    }

    @Test("403 且 remaining=0 映射 Rate Limit")
    func rateLimit() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let headers = [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": String(Int(Date().timeIntervalSince1970) + 60)
            ]
            return (
                response(403, url: request.url!, headers: headers),
                Data(#"{"message":"API rate limit exceeded"}"#.utf8)
            )
        }

        do {
            _ = try await client.userProjects(
                affiliation: .owner,
                visibility: .all,
                page: 1,
                perPage: 100,
                ifNoneMatch: nil
            )
            Issue.record("期望 rateLimited")
        } catch NetworkError.rateLimited(let retryAfter) {
            #expect(retryAfter > 0)
        }
    }
}
