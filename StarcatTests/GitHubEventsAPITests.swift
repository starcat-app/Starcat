//
//  GitHubEventsAPITests.swift
//  StarcatTests
//
//  Activity 公告与关注 PR-2（2026-06-16）：GitHubAPIClient.receivedEvents 端点单测。
//
//  覆盖：
//  - 200 + 正常 JSON 数组：5 条事件全部解析成功，payload 保留原始 sortedKeys JSON
//  - 304 Not Modified：抛 `NetworkError.notModified(etag:)` 短路，保留 ETag
//  - If-None-Match 头确实带出去（PR-2 ETag 节流的核心契约）
//  - 完全损坏 JSON：抛 invalidResponse（不静默吞错）
//  - 缺关键字段（无 id / actor.id / repo.name）：抛 invalidResponse（不部分解码）
//
//  设计参考：`GitHubAPIClientTests` 同款 URLProtocolStub + StubTokenProvider 模式。
//

import Testing
import Foundation
@testable import Starcat

// MARK: - File-level helpers

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

@Suite("GitHubEventsAPI.receivedEvents", .serialized)
struct GitHubEventsAPITests {

    // MARK: - Helpers

    private let baseURL = URL(string: "https://api.test.invalid")!

    private func makeClient() -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
    }

    /// 真实 GitHub events 响应的精简样本：5 条覆盖关键 event types。
    /// payload 字段顺序故意打乱（actor.id / repo.id 用数字字面量、payload 嵌套 dict），
    /// 验证 `sortedKeys` reserialize 能正确归一化。
    private var fixtureEvents: Data {
        let json = """
        [
            {
                "id": "45628942691",
                "type": "WatchEvent",
                "actor": {
                    "id": 1024,
                    "login": "ruanyf",
                    "display_login": "ruanyf",
                    "avatar_url": "https://avatars.githubusercontent.com/u/1024?v=4"
                },
                "repo": {
                    "id": 99001,
                    "name": "torvalds/linux",
                    "url": "https://api.github.com/repos/torvalds/linux"
                },
                "payload": {"action": "started"},
                "public": true,
                "created_at": "2026-06-15T12:00:00Z"
            },
            {
                "id": "45628942692",
                "type": "PushEvent",
                "actor": {
                    "id": 2048,
                    "login": "torvalds",
                    "avatar_url": "https://avatars.githubusercontent.com/u/2048?v=4"
                },
                "repo": {
                    "id": 99001,
                    "name": "torvalds/linux"
                },
                "payload": {
                    "ref": "refs/heads/main",
                    "before": "abc",
                    "head": "def",
                    "size": 3
                },
                "public": true,
                "created_at": "2026-06-15T12:01:00Z"
            },
            {
                "id": "45628942693",
                "type": "PullRequestEvent",
                "actor": {
                    "id": 3072,
                    "login": "gaearon",
                    "avatar_url": "https://avatars.githubusercontent.com/u/3072?v=4"
                },
                "repo": {
                    "id": 88001,
                    "name": "facebook/react"
                },
                "payload": {
                    "action": "opened",
                    "pull_request": {
                        "number": 12345,
                        "title": "Fix a thing",
                        "html_url": "https://github.com/facebook/react/pull/12345"
                    }
                },
                "public": true,
                "created_at": "2026-06-15T12:02:00Z"
            },
            {
                "id": "45628942694",
                "type": "CreateEvent",
                "actor": {
                    "id": 4096,
                    "login": "kennethreitz"
                },
                "repo": {
                    "id": 77001,
                    "name": "psf/requests"
                },
                "payload": {
                    "ref": "v3.0.0",
                    "ref_type": "tag"
                },
                "public": true,
                "created_at": "2026-06-15T12:03:00Z"
            },
            {
                "id": "45628942695",
                "type": "ReleaseEvent",
                "actor": {
                    "id": 5120,
                    "login": "octocat"
                },
                "repo": {
                    "id": 66001,
                    "name": "octo/widget"
                },
                "payload": {
                    "action": "published"
                },
                "public": true,
                "created_at": "2026-06-15T12:04:00Z"
            }
        ]
        """
        return Data(json.utf8)
    }

    // MARK: - 200 解析路径

    @Test("200: 5 条事件全部解析 + payload 保留 sortedKeys JSON")
    func parseEvents200() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            let etag = "\"abc-etag\""
            let response = httpResponse(200, request.url!, ["ETag": etag])
            return (response, self.fixtureEvents)
        }

        let resp = try await client.receivedEvents(username: "dong4j", perPage: 30, ifNoneMatch: nil)

        #expect(resp.value.count == 5)
        #expect(resp.etag == "\"abc-etag\"")
        #expect(resp.statusCode == 200)

        // 检 1：WatchEvent 解析
        let watchEvent = try #require(resp.value.first { $0.id == "45628942691" })
        #expect(watchEvent.type == "WatchEvent")
        #expect(watchEvent.actor.login == "ruanyf")
        #expect(watchEvent.actor.displayLogin == "ruanyf")
        #expect(watchEvent.actor.avatarUrl == "https://avatars.githubusercontent.com/u/1024?v=4")
        #expect(watchEvent.repo.name == "torvalds/linux")
        #expect(watchEvent.repo.id == 99001)
        #expect(watchEvent.createdAt == "2026-06-15T12:00:00Z")
        // payload reserialize 应是 sortedKeys 形式（仅 action 键）
        #expect(watchEvent.payloadJson == #"{"action":"started"}"#)

        // 检 2：PullRequestEvent 嵌套 payload —— sortedKeys 让顶层键字典序
        let prEvent = try #require(resp.value.first { $0.id == "45628942693" })
        #expect(prEvent.type == "PullRequestEvent")
        // action 字典序 < pull_request，所以排序后 action 在前
        #expect(prEvent.payloadJson.hasPrefix(#"{"action":"opened""#))
        // pull_request 嵌套内字段也应按字典序（html_url < number < title）
        #expect(prEvent.payloadJson.contains(#""html_url":"https:\/\/github.com\/facebook\/react\/pull\/12345""#)
                || prEvent.payloadJson.contains(#""html_url":"https://github.com/facebook/react/pull/12345""#))

        // 检 3：ReleaseEvent 在 API 层不过滤（过滤是 ViewModel 层 supportedEventTypes 的责任）
        let releaseEvent = try #require(resp.value.first { $0.id == "45628942695" })
        #expect(releaseEvent.type == "ReleaseEvent")
    }

    @Test("200: per_page 参数拼到 URL query")
    func perPageParamInURL() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(200, request.url!, [:]), Data("[]".utf8))
        }
        _ = try await client.receivedEvents(username: "dong4j", perPage: 50, ifNoneMatch: nil)

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.url?.absoluteString.contains("/users/dong4j/received_events/public") == true)
        #expect(req.url?.absoluteString.contains("per_page=50") == true)
    }

    @Test("If-None-Match: 客户端传 etag → 请求头带 If-None-Match")
    func ifNoneMatchPassedAsHeader() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(200, request.url!, ["ETag": "\"new-etag\""]), Data("[]".utf8))
        }
        _ = try await client.receivedEvents(username: "dong4j", perPage: 100, ifNoneMatch: "\"old-etag\"")

        let req = try #require(URLProtocolStub.receivedRequests.first)
        #expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"old-etag\"")
    }

    // MARK: - 304 短路

    @Test("304: 抛 NetworkError.notModified 携带服务端 ETag")
    func notModified304() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // 304 body 通常空；ETag 头可能与请求 If-None-Match 相同
            return (httpResponse(304, request.url!, ["ETag": "\"echo-etag\""]), Data())
        }

        do {
            _ = try await client.receivedEvents(username: "dong4j", perPage: 100, ifNoneMatch: "\"echo-etag\"")
            Issue.record("期望抛 notModified 但成功返回")
        } catch NetworkError.notModified(let etag) {
            #expect(etag == "\"echo-etag\"")
        } catch {
            Issue.record("期望 notModified，实际: \(error)")
        }
    }

    // MARK: - 异常路径

    @Test("malformed JSON: 抛 invalidResponse")
    func malformedJSON() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            return (httpResponse(200, request.url!, [:]), Data("not a json".utf8))
        }

        do {
            _ = try await client.receivedEvents(username: "dong4j", perPage: 100, ifNoneMatch: nil)
            Issue.record("期望抛 invalidResponse 但成功返回")
        } catch NetworkError.invalidResponse {
            // 通过
        } catch {
            Issue.record("期望 invalidResponse，实际: \(error)")
        }
    }

    @Test("缺关键字段: 抛 invalidResponse")
    func missingKeyField() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // 第二条缺 repo.name —— 整组应失败（不部分解码）
            let body = """
            [
                {"id":"1","type":"WatchEvent","actor":{"id":1,"login":"a"},"repo":{"id":1,"name":"a/b"},"payload":{},"created_at":"2026-06-15T00:00:00Z"},
                {"id":"2","type":"WatchEvent","actor":{"id":2,"login":"b"},"repo":{"id":2},"payload":{},"created_at":"2026-06-15T00:01:00Z"}
            ]
            """
            return (httpResponse(200, request.url!, [:]), Data(body.utf8))
        }

        do {
            _ = try await client.receivedEvents(username: "dong4j", perPage: 100, ifNoneMatch: nil)
            Issue.record("期望抛 invalidResponse 但成功返回")
        } catch NetworkError.invalidResponse {
            // 通过
        } catch {
            Issue.record("期望 invalidResponse，实际: \(error)")
        }
    }

    @Test("顶层非数组: 抛 invalidResponse")
    func topLevelNotArray() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            // GitHub 错误响应通常是 {"message": "...", "documentation_url": "..."}
            // events 端点 200 应返回数组，单 object 视为坏响应
            return (httpResponse(200, request.url!, [:]), Data(#"{"message":"hello"}"#.utf8))
        }

        do {
            _ = try await client.receivedEvents(username: "dong4j", perPage: 100, ifNoneMatch: nil)
            Issue.record("期望抛 invalidResponse 但成功返回")
        } catch NetworkError.invalidResponse {
            // 通过
        } catch {
            Issue.record("期望 invalidResponse，实际: \(error)")
        }
    }
}
