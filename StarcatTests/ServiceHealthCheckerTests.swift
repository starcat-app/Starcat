//
//  ServiceHealthCheckerTests.swift
//  StarcatTests
//
//  覆盖 R-01 v1.2 双 step 测试连接：/healthz + /api/v1 鉴权探测。
//  对应实现：`Starcat/Core/Network/ServiceHealthChecker.swift`
//
//  关键路径：
//   - healthz 通 + 鉴权 200 → ok
//   - healthz 通 + 鉴权 401 → unauthorized
//   - healthz 通 + 鉴权 5xx → authProbeError
//   - healthz 通 + 鉴权 404/405（路由 miss 但 middleware 通过）→ ok
//   - healthz 非 2xx → reachableButError（不进鉴权 step）
//   - healthz 网络错 → unreachable
//   - 鉴权 step 是否带 Authorization: Bearer 头由 apiKey 参数决定
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

    /// 构造一个 stub handler，按 URL 路径返回响应。
    private func stubResponses(_ map: [(pathSuffix: String, statusCode: Int, body: Data)]) {
        URLProtocolStub.requestHandler = { request in
            let path = request.url?.path ?? ""
            // 找第一个路径匹配后缀的 stub
            if let entry = map.first(where: { path.hasSuffix($0.pathSuffix) }) {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: entry.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, entry.body)
            }
            // 没匹配到当成 404
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
    }

    // MARK: - 双 step 状态机

    @Test("healthz 200 + auth-probe 200 → ok")
    func healthzOkAndAuthOk() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 200, body: "[]".data(using: .utf8)!)
        ])
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-real")
        guard case .ok(let code) = outcome else {
            #expect(Bool(false), "Expected .ok, got \(outcome)")
            return
        }
        #expect(code == 200)
    }

    @Test("healthz 200 + auth-probe 401 → unauthorized（API Key 错）")
    func healthzOkAndAuthUnauthorized() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 401, body: Data())
        ])
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-bad")
        #expect(outcome == .unauthorized)
    }

    @Test("healthz 200 + auth-probe 5xx → authProbeError")
    func healthzOkAndAuthServerError() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 503, body: Data())
        ])
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-any")
        #expect(outcome == .authProbeError(statusCode: 503))
    }

    @Test("sharing 鉴权探测：404 / 405（路由 miss）也算 ok（因为 middleware 已放行）")
    func sharingAuthProbe404AlsoOk() async {
        let checker = makeChecker()
        // sharing 的 baseURL 含 /api 后缀（与生产语义一致）
        let sharingBase = URL(string: "https://share.test.invalid/api")!
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            // sharing GET /api/v1/share 业务是 POST，路由 miss → 404
            (pathSuffix: "/api/v1/share", statusCode: 404, body: Data())
        ])
        let outcome = await checker.check(service: .sharing, baseURL: sharingBase, apiKey: "sk-good")
        guard case .ok(let code) = outcome else {
            #expect(Bool(false), "Expected .ok for 404 router miss with valid auth, got \(outcome)")
            return
        }
        #expect(code == 404)
    }

    @Test("healthz 503 → reachableButError，**不**进入鉴权 step")
    func healthzNon2xxShortCircuits() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 503, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 200, body: Data())
        ])
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-any")
        #expect(outcome == .reachableButError(statusCode: 503))
        // 验证不发起 auth probe（仅 1 个请求）
        #expect(URLProtocolStub.receivedRequests.count == 1)
        #expect(URLProtocolStub.receivedRequests.first?.url?.path.hasSuffix("/healthz") == true)
    }

    @Test("healthz 网络错 → unreachable")
    func healthzNetworkErrorReturnsUnreachable() async {
        let checker = makeChecker()
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let outcome = await checker.check(service: .weekly, baseURL: fakeBaseURL, apiKey: nil)
        guard case .unreachable = outcome else {
            #expect(Bool(false), "Expected .unreachable, got \(outcome)")
            return
        }
    }

    // MARK: - Authorization 头注入

    @Test("apiKey 非 nil → 第二步请求带 Authorization: Bearer <key>")
    func authProbeIncludesBearerHeader() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 200, body: Data())
        ])
        _ = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "sk-test-key")

        // 第一个请求是 healthz（不应带 Bearer）
        let healthRequest = URLProtocolStub.receivedRequests.first { $0.url?.path.hasSuffix("/healthz") == true }
        #expect(healthRequest?.value(forHTTPHeaderField: "Authorization") == nil)

        // 第二个请求是 auth probe（应带 Bearer）
        let probeRequest = URLProtocolStub.receivedRequests.first { $0.url?.path.hasSuffix("/api/v1/languages") == true }
        #expect(probeRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
    }

    @Test("apiKey 为 nil → 第二步请求**不**带 Authorization 头（让后端必返 401 → unauthorized 引导填 Key）")
    func authProbeOmitsAuthorizationWhenNil() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 401, body: Data())
        ])
        let outcome = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: nil)

        let probeRequest = URLProtocolStub.receivedRequests.first { $0.url?.path.hasSuffix("/api/v1/languages") == true }
        #expect(probeRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(outcome == .unauthorized)
    }

    @Test("apiKey 为空字符串 → 等价 nil（不发 Authorization 头）")
    func authProbeOmitsAuthorizationWhenEmpty() async {
        let checker = makeChecker()
        stubResponses([
            (pathSuffix: "/healthz", statusCode: 200, body: Data()),
            (pathSuffix: "/api/v1/languages", statusCode: 401, body: Data())
        ])
        _ = await checker.check(service: .trending, baseURL: fakeBaseURL, apiKey: "")

        let probeRequest = URLProtocolStub.receivedRequests.first { $0.url?.path.hasSuffix("/api/v1/languages") == true }
        #expect(probeRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
