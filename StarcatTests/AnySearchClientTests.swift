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

    @Test("API Key 探测请求只取一条 ping 结果并发送 Bearer Key")
    func apiKeyProbeUsesMinimalSearchRequest() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer candidate-key")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["query"] as? String == "ping")
            #expect(json["max_results"] as? Int == 1)
            return Self.successResponse(for: request)
        }
        let client = AnySearchClient(
            apiKey: "candidate-key",
            anonymous: false,
            session: URLProtocolStub.ephemeralSession()
        )

        _ = try await client.search(AnySearchRequest(query: "ping", maxResults: 1))

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

    // MARK: - 错误码分类（PR-1 改造，dong4j 2026-06-14）
    //
    // AnySearchClient.perform 现在对所有 4xx/5xx 都读 body 并解析 envelope，
    // 用 HTTP status + envelope.message + anonymous 标志启发式分类成 typed
    // case。下面测试覆盖每条主路径，保证 UI 拿到的错误语义稳定。

    @Test("400 → invalidRequest 带 envelope 透传 message")
    func httpStatus400YieldsInvalidRequest() async throws {
        let client = Self.makeClient(
            statusCode: 400,
            body: #"{"code":40001,"message":"empty query","data":null}"#,
            anonymous: true
        )
        await #expect(throws: AnySearchError.invalidRequest(message: "empty query")) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("401 默认 → invalidAPIKey(.invalid)")
    func httpStatus401YieldsInvalidKey() async throws {
        let client = Self.makeClient(
            statusCode: 401,
            body: #"{"code":40101,"message":"API key not found","data":null}"#,
            anonymous: false,
            apiKey: "wrong-key"
        )
        await #expect(throws: AnySearchError.invalidAPIKey(reason: .invalid)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("401 envelope message 含 header → invalidAPIKey(.malformedHeader)")
    func httpStatus401WithHeaderKeywordYieldsMalformed() async throws {
        let client = Self.makeClient(
            statusCode: 401,
            body: #"{"code":40102,"message":"Authorization header is malformed","data":null}"#,
            anonymous: false,
            apiKey: "wrong"
        )
        await #expect(throws: AnySearchError.invalidAPIKey(reason: .malformedHeader)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("402 + 匿名模式 → anonymousQuotaExhausted")
    func httpStatus402AnonymousYieldsAnonQuota() async throws {
        let client = Self.makeClient(
            statusCode: 402,
            body: #"{"code":40202,"message":"daily free quota exhausted","data":null}"#,
            anonymous: true
        )
        await #expect(throws: AnySearchError.anonymousQuotaExhausted) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("402 + Bearer 模式 → keyQuotaExhausted 带 envelope 配额数字")
    func httpStatus402BearerYieldsKeyQuotaWithNumbers() async throws {
        let body = #"{"code":40203,"message":"quota exhausted","data":{"quota_limit":1000,"quota_used":1000,"quota_remaining":0}}"#
        let client = Self.makeClient(
            statusCode: 402,
            body: body,
            anonymous: false,
            apiKey: "valid-key"
        )
        await #expect(throws: AnySearchError.keyQuotaExhausted(limit: 1000, used: 1000)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("403 message 含 expired → invalidAPIKey(.expired)")
    func httpStatus403ExpiredYieldsExpiredKey() async throws {
        let client = Self.makeClient(
            statusCode: 403,
            body: #"{"code":40301,"message":"API key has expired","data":null}"#,
            anonymous: false,
            apiKey: "k"
        )
        await #expect(throws: AnySearchError.invalidAPIKey(reason: .expired)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("403 message 含 disabled → accountDisabled")
    func httpStatus403DisabledYieldsAccountDisabled() async throws {
        let client = Self.makeClient(
            statusCode: 403,
            body: #"{"code":40303,"message":"account is disabled","data":null}"#,
            anonymous: false,
            apiKey: "k"
        )
        await #expect(throws: AnySearchError.accountDisabled) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("403 兜底 → capabilityNotEnabled 带 message")
    func httpStatus403OtherYieldsCapabilityNotEnabled() async throws {
        let client = Self.makeClient(
            statusCode: 403,
            body: #"{"code":40302,"message":"private capability not enabled for this key","data":null}"#,
            anonymous: false,
            apiKey: "k"
        )
        await #expect(throws: AnySearchError.capabilityNotEnabled(message: "private capability not enabled for this key")) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("429 默认 → rateLimited(.key) + Retry-After header")
    func httpStatus429YieldsRateLimitedKeyWithRetry() async throws {
        let client = Self.makeClient(
            statusCode: 429,
            body: #"{"code":42902,"message":"rate limit exceeded","data":null}"#,
            anonymous: true,
            extraHeaders: ["Retry-After": "30"]
        )
        await #expect(throws: AnySearchError.rateLimited(scope: .key, retryAfter: 30)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("429 message 含 user → rateLimited(.account)")
    func httpStatus429UserScopeYieldsRateLimitedAccount() async throws {
        let client = Self.makeClient(
            statusCode: 429,
            body: #"{"code":42901,"message":"rate limit exceeded user account","data":null}"#,
            anonymous: false,
            apiKey: "k"
        )
        await #expect(throws: AnySearchError.rateLimited(scope: .account, retryAfter: nil)) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    @Test("503 → serviceUnavailable 带 envelope message")
    func httpStatus503YieldsServiceUnavailable() async throws {
        let client = Self.makeClient(
            statusCode: 503,
            body: #"{"code":50301,"message":"quota check failed","data":null}"#,
            anonymous: true
        )
        // 注：search() 顶层会对 serviceUnavailable 重试一次，URLProtocolStub 会
        // 返回同样的 503 → 第二次仍抛 serviceUnavailable，最终对用户可见。
        await #expect(throws: AnySearchError.serviceUnavailable(message: "quota check failed")) {
            _ = try await client.search(AnySearchRequest(query: "x"))
        }
    }

    /// 构造一个返回固定 status/body 的 stubbed client，便于错误码测试复用。
    /// **关键**：URLProtocolStub.requestHandler 必须 reset 后再设，防止跨用例污染。
    private static func makeClient(
        statusCode: Int,
        body: String,
        anonymous: Bool,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:]
    ) -> AnySearchClient {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            var headerFields: [String: String] = ["Content-Type": "application/json"]
            for (k, v) in extraHeaders { headerFields[k] = v }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headerFields
            )!
            return (response, Data(body.utf8))
        }
        return AnySearchClient(
            apiKey: apiKey,
            anonymous: anonymous,
            session: URLProtocolStub.ephemeralSession()
        )
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
        let rl = WebRateLimit(limit: 0, sessionUsed: 0, resetAt: Date())
        #expect(rl.fractionRemaining == 0)
    }

    @Test("fractionRemaining 正常范围比例（sessionUsed 视角）")
    func fractionWithinNormalRange() {
        // 上限 20，本地已用 2 → 剩余 18 → fractionRemaining = 0.9
        let rl = WebRateLimit(limit: 20, sessionUsed: 2, resetAt: Date())
        #expect(rl.fractionRemaining == 0.9)
        #expect(rl.sessionRemaining == 18)
        #expect(!rl.isExhausted)
    }

    @Test("fractionRemaining 在 sessionUsed > limit 时被 clamp 到 0 + isExhausted=true")
    func fractionExhaustedAndClamped() {
        // 本地计数允许超过 API 上限（user 一直点搜索），此时视为「用尽」
        let rl = WebRateLimit(limit: 10, sessionUsed: 12, resetAt: Date())
        #expect(rl.fractionRemaining == 0)
        #expect(rl.sessionRemaining == 0)
        #expect(rl.isExhausted)
    }

    @Test("sessionUsed == limit 时即视为用尽")
    func fractionExactlyExhausted() {
        let rl = WebRateLimit(limit: 10, sessionUsed: 10, resetAt: Date())
        #expect(rl.fractionRemaining == 0)
        #expect(rl.isExhausted)
    }

    @Test("sessionUsed == 0 时 fractionRemaining = 1")
    func fractionFullWhenUnused() {
        let rl = WebRateLimit(limit: 10, sessionUsed: 0, resetAt: Date())
        #expect(rl.fractionRemaining == 1)
        #expect(rl.sessionRemaining == 10)
        #expect(!rl.isExhausted)
    }
}

@Suite("AnySearch Usage Counter", .serialized)
struct AnySearchUsageCounterTests {

    @Test("初始 count 为 0")
    func initialCountIsZero() async {
        let counter = AnySearchUsageCounter()
        let count = await counter.count
        #expect(count == 0)
    }

    @Test("increment 累加并返回新值")
    func incrementAccumulates() async {
        let counter = AnySearchUsageCounter()
        let v1 = await counter.increment()
        let v2 = await counter.increment()
        let v3 = await counter.increment()
        #expect(v1 == 1)
        #expect(v2 == 2)
        #expect(v3 == 3)
        let finalCount = await counter.count
        #expect(finalCount == 3)
    }

    @Test("reset 归零")
    func resetToZero() async {
        let counter = AnySearchUsageCounter()
        _ = await counter.increment()
        _ = await counter.increment()
        await counter.reset()
        let count = await counter.count
        #expect(count == 0)
    }
}
