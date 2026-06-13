//
//  AnySearchClientTests.swift
//  StarcatTests
//
//  覆盖 AnySearch URL 规范化和请求边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnySearch Client", .serialized)
struct AnySearchClientTests {
    @Test("移除 fragment 与常见 tracking 参数")
    func normalizeURL() throws {
        let raw = try #require(URL(string: "HTTPS://Example.COM/doc?utm_source=x&id=42#part"))
        let normalized = try #require(AnySearchClient.normalize(raw))
        #expect(normalized.absoluteString == "https://example.com/doc?id=42")
    }

    @Test("请求数量被限制在 1 到 100")
    func clampsResultCount() {
        #expect(AnySearchRequest(query: "swift", maxResults: 0).maxResults == 1)
        #expect(AnySearchRequest(query: "swift", maxResults: 200).maxResults == 100)
    }

    @Test("Bearer 模式发送用户自定义 API Key")
    func bearerModeSendsCustomAPIKey() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-anysearch-key")
            return Self.successResponse(for: request)
        }
        let client = AnySearchClient(
            apiKey: " user-anysearch-key ",
            anonymous: false,
            session: URLProtocolStub.ephemeralSession()
        )

        _ = try await client.search(AnySearchRequest(query: "swift"))

        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("匿名模式不发送已保存的 API Key")
    func anonymousModeOmitsSavedAPIKey() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return Self.successResponse(for: request)
        }
        let client = AnySearchClient(
            apiKey: "saved-but-disabled-key",
            anonymous: true,
            session: URLProtocolStub.ephemeralSession()
        )

        _ = try await client.search(AnySearchRequest(query: "swift"))

        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    // MARK: - Rate limit header parsing
    //
    // Rate limit 解析逻辑见 `AnySearchClient.parseRateLimit(from:)`，关键约束：
    // 三字段（x-ratelimit-limit / -remaining / -reset）缺一不全 → 返回 nil。
    // 下面的测试用 fixture 化的 reset 时间戳（1781365701，对应 2026-06-13 UTC），
    // 用 `Date(timeIntervalSince1970:)` 等值比较即可，无需做时区处理。

    @Test("成功响应解析 x-ratelimit-* 三字段")
    func parsesRateLimitFromHeaders() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.successResponse(
                for: request,
                extraHeaders: [
                    "x-ratelimit-limit": "20",
                    "x-ratelimit-remaining": "18",
                    "x-ratelimit-reset": "1781365701"
                ]
            )
        }
        let client = AnySearchClient(
            apiKey: nil,
            anonymous: true,
            session: URLProtocolStub.ephemeralSession()
        )

        let response = try await client.search(AnySearchRequest(query: "swift"))

        let rateLimit = try #require(response.rateLimit)
        #expect(rateLimit.limit == 20)
        #expect(rateLimit.remaining == 18)
        #expect(rateLimit.resetAt == Date(timeIntervalSince1970: 1781365701))
    }

    @Test("header 大小写无关（HTTPURLResponse 系统行为）")
    func parsesRateLimitCaseInsensitively() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.successResponse(
                for: request,
                extraHeaders: [
                    "X-RateLimit-Limit": "10",
                    "X-RateLimit-Remaining": "3",
                    "X-RateLimit-Reset": "1781365701"
                ]
            )
        }
        let client = AnySearchClient(
            apiKey: nil,
            anonymous: true,
            session: URLProtocolStub.ephemeralSession()
        )

        let response = try await client.search(AnySearchRequest(query: "swift"))

        let rateLimit = try #require(response.rateLimit)
        #expect(rateLimit.limit == 10)
        #expect(rateLimit.remaining == 3)
    }

    @Test("缺少 limit header 时整体降级为 nil")
    func missingLimitHeaderYieldsNil() async throws {
        try await assertRateLimitNil(headers: [
            "x-ratelimit-remaining": "18",
            "x-ratelimit-reset": "1781365701"
        ])
    }

    @Test("缺少 remaining header 时整体降级为 nil")
    func missingRemainingHeaderYieldsNil() async throws {
        try await assertRateLimitNil(headers: [
            "x-ratelimit-limit": "20",
            "x-ratelimit-reset": "1781365701"
        ])
    }

    @Test("缺少 reset header 时整体降级为 nil")
    func missingResetHeaderYieldsNil() async throws {
        try await assertRateLimitNil(headers: [
            "x-ratelimit-limit": "20",
            "x-ratelimit-remaining": "18"
        ])
    }

    @Test("limit 非数字时整体降级为 nil")
    func nonNumericLimitYieldsNil() async throws {
        try await assertRateLimitNil(headers: [
            "x-ratelimit-limit": "abc",
            "x-ratelimit-remaining": "18",
            "x-ratelimit-reset": "1781365701"
        ])
    }

    @Test("reset 非数字时整体降级为 nil")
    func nonNumericResetYieldsNil() async throws {
        try await assertRateLimitNil(headers: [
            "x-ratelimit-limit": "20",
            "x-ratelimit-remaining": "18",
            "x-ratelimit-reset": "not-a-timestamp"
        ])
    }

    @Test("完全不返回 header 时 rateLimit 为 nil（向后兼容旧 API）")
    func noHeadersYieldsNilRateLimit() async throws {
        try await assertRateLimitNil(headers: [:])
    }

    /// 复用断言：给定 header 集合调一次 search，验证 `response.rateLimit == nil`。
    private func assertRateLimitNil(headers: [String: String]) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.successResponse(for: request, extraHeaders: headers)
        }
        let client = AnySearchClient(
            apiKey: nil,
            anonymous: true,
            session: URLProtocolStub.ephemeralSession()
        )

        let response = try await client.search(AnySearchRequest(query: "swift"))

        #expect(response.rateLimit == nil)
    }

    private static func successResponse(
        for request: URLRequest,
        extraHeaders: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        var headerFields: [String: String] = ["Content-Type": "application/json"]
        for (k, v) in extraHeaders { headerFields[k] = v }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headerFields
        )!
        let data = Data(#"{"code":0,"message":"ok","data":{"results":[],"metadata":null}}"#.utf8)
        return (response, data)
    }
}

@Suite("Web Rate Limit", .serialized)
struct WebRateLimitTests {

    @Test("fractionRemaining 在 limit==0 时返回 0")
    func fractionWhenLimitIsZero() {
        let rl = WebRateLimit(limit: 0, remaining: 0, resetAt: Date())
        #expect(rl.fractionRemaining == 0)
    }

    @Test("fractionRemaining 正常范围比例")
    func fractionWithinNormalRange() {
        let rl = WebRateLimit(limit: 20, remaining: 18, resetAt: Date())
        #expect(rl.fractionRemaining == 0.9)
    }

    @Test("fractionRemaining 在 remaining 超过 limit 时被 clamp 到 1")
    func fractionClampedAboveOne() {
        // 边界情况：上游 bug 时可能返回 remaining > limit，UI 不能因此画出"110%"色带
        let rl = WebRateLimit(limit: 10, remaining: 11, resetAt: Date())
        #expect(rl.fractionRemaining == 1)
    }

    @Test("fractionRemaining 在 remaining 为负时被 clamp 到 0")
    func fractionClampedBelowZero() {
        let rl = WebRateLimit(limit: 10, remaining: -3, resetAt: Date())
        #expect(rl.fractionRemaining == 0)
    }
}
