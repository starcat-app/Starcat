//
//  GitHubAPIClientTests.swift
//  StarcatTests
//
//  GitHubAPIClient 网络路径分支单测（D-14）。
//
//  覆盖目标：
//  - `perform<T>`（GET + JSON 解码路径）：200 / 401 / 403 rateLimited / 403 client error /
//    404 / 500 / 200+invalid JSON / transport error
//  - `performNoBody`（DELETE / PUT 路径，D-03 引入）：200 / 404
//  - `performBytes`（README 字节路径）：200 + headers / 304 notModified / 404
//  - 业务端点封装：starredRepos 解析 Link 头 / 注入 Accept + Authorization
//
//  测试基础设施：
//  - `URLProtocolStub`（同目录新建）：拦截 URLSession 请求并返回测试响应
//  - `StubTokenProvider`：固定 token 不碰 Keychain
//  - Suite 用 `.serialized` 串行化，避免共享 URLProtocolStub 静态状态
//

import Testing
import Foundation
@testable import Starcat

// MARK: - File-level helpers

/// 构造 HTTPURLResponse 的便利函数（文件级，闭包内直接调用不需 capture self）。
/// Swift 闭包 capture list 会丢 default value，所以 helper 必须是 top-level function。
private func httpResponse(
    _ statusCode: Int,
    _ url: URL,
    _ headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

@Suite("GitHubAPIClient 网络路径分支", .serialized)
struct GitHubAPIClientTests {

    // MARK: - Helpers

    private let baseURL = URL(string: "https://api.test.invalid")!

    private func makeClient(token: String? = "test-token") -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: token)
        )
    }

    // MARK: - perform<T> 成功路径

    @Test("get<T>: 200 + valid JSON → 解码成功 + Bearer 注入")
    func get200Success() async throws {
        let client = makeClient(token: "abc123")
        URLProtocolStub.requestHandler = { request in
            let body = #"{"id":42,"login":"alice"}"#.data(using: .utf8)!
            let response = httpResponse(200, request.url!, [:])
            return (response, body)
        }

        let user = try await client.getCurrentUser()
        #expect(user.id == 42)
        #expect(user.login == "alice")

        // 验证 Bearer 头注入
        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(req.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("get<T>: token 为 nil → 不注入 Authorization")
    func get200NoToken() async throws {
        let client = makeClient(token: nil)
        URLProtocolStub.requestHandler = { request in
            let body = #"{"id":1,"login":"anon"}"#.data(using: .utf8)!
            return (httpResponse(200, request.url!), body)
        }

        _ = try await client.getCurrentUser()
        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - perform<T> 错误路径

    @Test("get<T>: 401 → NetworkError.unauthorized")
    func get401Unauthorized() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(401, request.url!), Data())
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 unauthorized 但成功返回")
        } catch NetworkError.unauthorized {
            // 通过
        } catch {
            Issue.record("期望 unauthorized，实际: \(error)")
        }
    }

    @Test("get<T>: 403 + remaining=0 + 消息含'rate limit' → NetworkError.rateLimited")
    func get403RateLimited() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // 真实 GitHub rate limit 响应会包含 "rate limit" 关键词
            let body = #"{"message":"You have exceeded a secondary rate limit. Please wait before retrying."}"#.data(using: .utf8)!
            let response = httpResponse(403, request.url!, [
                "X-RateLimit-Limit": "5000",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "\(Int(Date().addingTimeInterval(60).timeIntervalSince1970))"
            ])
            return (response, body)
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 rateLimited 但成功返回")
        } catch let NetworkError.rateLimited(retryAfter) {
            #expect(retryAfter > 0)
        } catch {
            Issue.record("期望 rateLimited，实际: \(error)")
        }
    }

    @Test("get<T>: 403 + remaining=0 + 消息不含'rate limit' → NetworkError.unauthorized")
    func get403UnauthorizedWithoutRateLimitMessage() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // 未登录/无效 token 时 GitHub 返回 403 + remaining=0，但消息是 "Forbidden"
            let body = #"{"message":"Forbidden"}"#.data(using: .utf8)!
            let response = httpResponse(403, request.url!, [
                "X-RateLimit-Limit": "5000",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "\(Int(Date().addingTimeInterval(60).timeIntervalSince1970))"
            ])
            return (response, body)
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 unauthorized 但成功返回")
        } catch NetworkError.unauthorized {
            // 通过
        } catch {
            Issue.record("期望 unauthorized，实际: \(error)")
        }
    }

    @Test("get<T>: 403 + remaining>0 → NetworkError.clientError(403)")
    func get403ClientError() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let body = #"{"message":"forbidden by ACL"}"#.data(using: .utf8)!
            let response = httpResponse(403, request.url!, [
                "X-RateLimit-Remaining": "1000"
            ])
            return (response, body)
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 clientError 但成功返回")
        } catch let NetworkError.clientError(statusCode, message) {
            #expect(statusCode == 403)
            #expect(message == "forbidden by ACL")
        } catch {
            Issue.record("期望 clientError(403)，实际: \(error)")
        }
    }

    @Test("get<T>: 404 → NetworkError.notFound")
    func get404NotFound() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(404, request.url!), Data())
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 notFound 但成功返回")
        } catch NetworkError.notFound {
            // 通过
        } catch {
            Issue.record("期望 notFound，实际: \(error)")
        }
    }

    @Test("get<T>: 500 → NetworkError.serverError(500)")
    func get500ServerError() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(503, request.url!), Data())
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 serverError 但成功返回")
        } catch let NetworkError.serverError(statusCode) {
            #expect(statusCode == 503)
        } catch {
            Issue.record("期望 serverError(503)，实际: \(error)")
        }
    }

    @Test("get<T>: 200 但 JSON 无法解码 → NetworkError.decodingError")
    func get200DecodingError() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // 缺少必填字段 id / login
            let body = #"{"foo":"bar"}"#.data(using: .utf8)!
            return (httpResponse(200, request.url!), body)
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 decodingError 但成功返回")
        } catch NetworkError.decodingError {
            // 通过
        } catch {
            Issue.record("期望 decodingError，实际: \(error)")
        }
    }

    @Test("get<T>: transport error → NetworkError.transport")
    func getTransportError() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.getCurrentUser()
            Issue.record("期望抛 transport 但成功返回")
        } catch NetworkError.transport {
            // 通过
        } catch {
            Issue.record("期望 transport，实际: \(error)")
        }
    }

    // MARK: - performNoBody（DELETE / PUT，D-03 引入）

    @Test("unstar: 204 → 无 body 正常返回（performNoBody 200~ 路径）")
    func unstar204Success() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(204, request.url!), Data())
        }

        try await client.unstar(owner: "alice", repo: "foo")

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.path == "/user/starred/alice/foo")
    }

    @Test("unstar: 404 → NetworkError.notFound（performNoBody 错误路径）")
    func unstar404NotFound() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(404, request.url!), Data())
        }

        do {
            try await client.unstar(owner: "alice", repo: "missing")
            Issue.record("期望抛 notFound 但成功返回")
        } catch NetworkError.notFound {
            // 通过
        } catch {
            Issue.record("期望 notFound，实际: \(error)")
        }
    }

    @Test("star: 204 → PUT 正常返回")
    func star204Success() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(204, request.url!), Data())
        }

        try await client.star(owner: "alice", repo: "foo")

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.httpMethod == "PUT")
    }

    // MARK: - performBytes（README 字节路径）

    @Test("readmeHTML: 200 → BytesResponse(data, etag, lastModified)")
    func readmeHTML200() async throws {
        let client = makeClient()
        let html = "<h1>Hello</h1>".data(using: .utf8)!
        URLProtocolStub.requestHandler = { request in
            let response = httpResponse(200, request.url!, [
                "ETag": "\"abc123\"",
                "Last-Modified": "Sat, 30 May 2026 12:00:00 GMT"
            ])
            return (response, html)
        }

        let bytes = try await client.readmeHTML(owner: "alice", repo: "foo")
        #expect(bytes.statusCode == 200)
        #expect(bytes.notModified == false)
        #expect(bytes.data == html)
        #expect(bytes.etag == "\"abc123\"")
        #expect(bytes.lastModified == "Sat, 30 May 2026 12:00:00 GMT")

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.url?.path == "/repos/alice/foo/readme")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github.html")
    }

    @Test("readmeHTML: 304 → BytesResponse(notModified: true) 不抛错")
    func readmeHTML304NotModified() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(304, request.url!, ["ETag": "\"abc\""]), Data())
        }

        let bytes = try await client.readmeHTML(
            owner: "alice", repo: "foo",
            ifNoneMatch: "\"abc\""
        )
        #expect(bytes.statusCode == 304)
        #expect(bytes.notModified == true)
        #expect(bytes.data.isEmpty)

        // If-None-Match 头被注入
        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test("readmeHTML: 404 → NetworkError.notFound")
    func readmeHTML404() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(404, request.url!), Data())
        }

        do {
            _ = try await client.readmeHTML(owner: "alice", repo: "no-readme")
            Issue.record("期望抛 notFound 但成功返回")
        } catch NetworkError.notFound {
            // 通过
        } catch {
            Issue.record("期望 notFound，实际: \(error)")
        }
    }

    @Test("readmeHTML: 注入 If-Modified-Since 头")
    func readmeHTMLIfModifiedSince() async throws {
        let client = makeClient()
        let lastMod = "Sat, 30 May 2026 12:00:00 GMT"
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(200, request.url!), Data())
        }

        _ = try await client.readmeHTML(
            owner: "alice", repo: "foo",
            ifModifiedSince: lastMod
        )

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "If-Modified-Since") == lastMod)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    // MARK: - 业务端点封装：starredRepos

    @Test("starredRepos: 200 + JSON → 解析 + Link 头 + Accept=star+json")
    func starredRepos200WithLink() async throws {
        let client = makeClient()
        let json = """
        [
          {
            "starred_at": "2026-05-30T00:00:00Z",
            "repo": {
              "id": 1, "name": "foo", "full_name": "alice/foo",
              "owner": {"id": 10, "login": "alice"},
              "description": null, "language": "Swift",
              "stargazers_count": 100, "forks_count": 5, "watchers_count": 7,
              "topics": null, "license": null, "homepage": null,
              "html_url": "https://github.com/alice/foo",
              "clone_url": null, "ssh_url": null,
              "private": false, "fork": false, "archived": false,
              "pushed_at": null, "created_at": null, "updated_at": null
            }
          }
        ]
        """.data(using: .utf8)!

        URLProtocolStub.requestHandler = { request in
            let response = httpResponse(200, request.url!, [
                "Link": "<https://api.test.invalid/user/starred?page=2>; rel=\"next\", <https://api.test.invalid/user/starred?page=10>; rel=\"last\""
            ])
            return (response, json)
        }

        let result = try await client.starredRepos(page: 1, perPage: 100, ifNoneMatch: nil)
        #expect(result.value.count == 1)
        #expect(result.value.first?.repo.fullName == "alice/foo")
        #expect(result.linkHeader.lastPage == 10)
        #expect(result.linkHeader.nextPage == 2)

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github.star+json")
        // query 参数
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let queryItems = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(queryItems["page"] == "1")
        #expect(queryItems["per_page"] == "100")
    }
}
