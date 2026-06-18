//
//  ServiceHealthCheckerTests.swift
//  StarcatTests
//
//  覆盖 R-03（2026-06-11）单步探测：`GET /api/v1/ping` + Bearer Auth。
//  对应实现：`Starcat/Core/Network/ServiceHealthChecker.swift`
//
//  关键路径：
//   - 200 → ok(200)
//   - 401 → unauthorized(401)
//   - 4xx 非 401（如 404 / 405 / 400）→ serverError(code)
//   - 5xx → serverError(code)
//   - 网络错（DNS / refused / timeout）→ networkError(reason)
//   - apiKey 注入：非 nil 非空 → Authorization: Bearer <key>；nil / 空串 → 不带头
//   - URL 路径正确性：4 个服务（含 sharing）**统一**命中 `/api/v1/ping`（R-03.1 起 sharing
//     也走绝对路径，不再有 `/v1/ping` 特例）；sharing 历史 baseURL 末尾 `/api` 会被
//     `ThirdPartyService.normalizedBaseURL` 剥除，向后兼容
//   - URL 末尾 `/` 防御编程：`https://x.test/` 与 `https://x.test` 都必须命中 `/api/v1/ping`
//
//  历史 baggage：v1.2 旧版有 healthz + auth probe 两步，状态机 5 态。
//  R-03 后端加了专用 /api/v1/ping，客户端简化为单步探测、状态机 4 态。
//  R-03.1（2026-06-11，dong4j 反馈）撤掉 sharing 的 /v1/ping 特例，所有服务统一 `/api/v1/ping`。
//

import Testing
import Foundation
@testable import Starcat

@Suite("ServiceHealthChecker")
struct ServiceHealthCheckerTests {

    // MARK: - Fixtures

    /// 构造一个 ServiceHealthChecker，注入 URLProtocolStub session。
    private func makeChecker() -> ServiceHealthChecker {
        URLProtocolStub.reset()
        return ServiceHealthChecker(session: URLProtocolStub.ephemeralSession())
    }

    /// 构造测试用的 fake baseURL（指向 invalid host，配合 stub 使用）。
    private let fakeBaseURL = URL(string: "https://api.test.invalid")!

    /// 注册一个统一的 stub：所有请求都返回指定 status 与 body，方便单步探测验证。
    private func stubAll(statusCode: Int, body: Data = Data()) {
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
    }

    /// 构造 ping 200 的标准 envelope body（`data.service` 与探测目标一致）。
    private func pingOKBody(for service: ThirdPartyService) -> Data {
        let json = #"{"schema_version":1,"data":{"service":"\#(service.rawValue)","ok":true}}"#
        return Data(json.utf8)
    }

    private func stubPingOK(service: ThirdPartyService, statusCode: Int = 200) {
        stubAll(statusCode: statusCode, body: pingOKBody(for: service))
    }

    // MARK: - 单步探测状态机（R-03 2026-06-11）

    @Test("200 + service 匹配 → ok(200)")
    func ping200ReturnsOk() async {
        let checker = makeChecker()
        stubPingOK(service: .trending)
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-real")
        #expect(outcome == .ok(statusCode: 200))
    }

    @Test("200 但 service 不匹配 → serviceMismatch（典型：地址填错端口 / 服务）")
    func ping200WrongServiceReturnsMismatch() async {
        let checker = makeChecker()
        stubPingOK(service: .sharing)
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-real")
        #expect(outcome == .serviceMismatch)
    }

    @Test("401 → unauthorized(401)：缺 Authorization / 错 token 都走这里")
    func ping401ReturnsUnauthorized() async {
        let checker = makeChecker()
        stubAll(statusCode: 401)
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-bad")
        #expect(outcome == .unauthorized(statusCode: 401))
    }

    @Test("4xx 非 401（404 / 405 / 400）→ serverError(code)")
    func pingNon401ClientErrorReturnsServerError() async {
        for code in [400, 403, 404, 405, 429] {
            let checker = makeChecker()
            stubAll(statusCode: code)
            let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-any")
            #expect(outcome == .serverError(statusCode: code), "code=\(code) should map to serverError, got \(outcome)")
        }
    }

    @Test("5xx → serverError(code)")
    func ping5xxReturnsServerError() async {
        for code in [500, 502, 503, 504] {
            let checker = makeChecker()
            stubAll(statusCode: code)
            let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-any")
            #expect(outcome == .serverError(statusCode: code), "code=\(code) should map to serverError, got \(outcome)")
        }
    }

    @Test("网络错（DNS / refused / timeout / SSL）→ networkError(reason)")
    func networkErrorReturnsNetworkError() async {
        let checker = makeChecker()
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let outcome = await checker.check(service: .weekly, baseURL: fakeBaseURL, apiKey: nil)
        guard case .networkError = outcome else {
            #expect(Bool(false), "Expected .networkError, got \(outcome)")
            return
        }
    }

    // MARK: - Authorization 头注入

    @Test("apiKey 非 nil 非空 → 请求带 Authorization: Bearer <key>")
    func pingIncludesBearerHeaderWhenKeyPresent() async {
        let checker = makeChecker()
        stubPingOK(service: .trending)
        _ = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-test-key")

        #expect(URLProtocolStub.receivedRequests.count == 1)
        let pingRequest = URLProtocolStub.receivedRequests.first
        #expect(pingRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
    }

    @Test("apiKey 为 nil → 请求**不**带 Authorization 头（让后端必返 401 → unauthorized）")
    func pingOmitsAuthorizationWhenNil() async {
        let checker = makeChecker()
        stubAll(statusCode: 401)
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: nil)

        #expect(URLProtocolStub.receivedRequests.count == 1)
        let pingRequest = URLProtocolStub.receivedRequests.first
        #expect(pingRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(outcome == .unauthorized(statusCode: 401))
    }

    @Test("apiKey 为空字符串 → 等价 nil（不发 Authorization 头）")
    func pingOmitsAuthorizationWhenEmpty() async {
        let checker = makeChecker()
        stubAll(statusCode: 401)
        _ = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "")

        let pingRequest = URLProtocolStub.receivedRequests.first
        #expect(pingRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - URL 路径拼接（R-03.1：4 个服务一视同仁）

    @Test("trending / weekly / wiki / sharing 都命中 /api/v1/ping")
    func pingURLPathForAllServices() async {
        for service in ThirdPartyService.allCases {
            let checker = makeChecker()
            stubPingOK(service: service)
            _ = await checker.check(service: service, baseURL: fakeBaseURL, apiKey: "sk-any")

            let request = URLProtocolStub.receivedRequests.first
            #expect(request?.url?.path == "/api/v1/ping",
                    "service=\(service.rawValue) should hit /api/v1/ping, got \(request?.url?.path ?? "<nil>")")
        }
    }

    @Test("sharing 历史持久化的 `/api` 后缀 baseURL 也命中 /api/v1/ping（不是 /api/api/v1/ping）")
    func pingURLPathForLegacySharingWithApiSuffix() async {
        // 模拟 R-03 之前用户持久化的 `https://share.test.invalid/api` 形态。
        // pingURL 内部 normalizedBaseURL 会剥末尾 `/api`，最终命中标准路径。
        let checker = makeChecker()
        let legacySharingBase = URL(string: "https://share.test.invalid/api")!
        stubPingOK(service: .sharing)
        _ = await checker.check(service: .sharing, baseURL: legacySharingBase, apiKey: "sk-any")

        let request = URLProtocolStub.receivedRequests.first
        #expect(request?.url?.path == "/api/v1/ping",
                "legacy sharing /api suffix should be stripped, got \(request?.url?.path ?? "<nil>")")
    }

    @Test("baseURL 末尾 `/` 不影响 ping 路径（防御编程，R-03.1）")
    func pingURLPathTolerantToTrailingSlash() async {
        // 模拟用户在设置页填了 `http://127.0.0.1:5004/`，setServiceURL 落盘的 absoluteString
        // 应该是规范化后的（无尾斜杠），但万一中间环节漏了归一化，pingURL 内部也兜底。
        for service in ThirdPartyService.allCases {
            let checker = makeChecker()
            let baseWithSlash = URL(string: "http://127.0.0.1:5004/")!
            stubPingOK(service: service)
            _ = await checker.check(service: service, baseURL: baseWithSlash, apiKey: "sk-any")

            let request = URLProtocolStub.receivedRequests.first
            #expect(request?.url?.path == "/api/v1/ping",
                    "service=\(service.rawValue) trailing-slash base should hit /api/v1/ping, got \(request?.url?.path ?? "<nil>")")
        }
    }
}
