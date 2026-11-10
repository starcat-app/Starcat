//
//  DirectLicenseAPITests.swift
//  StarcatTests
//
//  Direct License API 网络契约测试。
//

import Foundation
import Testing
@testable import Starcat

/// 覆盖 Direct 分发授权后端的请求边界。
///
/// 这些测试只验证 Starcat 客户端与自家 License API 的 HTTP 契约，不直接碰 Creem。
/// Creem API Key、产品映射和 webhook 校验都属于 `supports/starcat-license-api` 服务端责任。
@Suite("Direct License API", .serialized)
struct DirectLicenseAPITests {

    @Test("checkout 带 Bearer 并命中 Direct checkout 路径")
    func checkoutSendsBearerHeader() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/direct/checkout")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer license-api-key")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            return Self.jsonResponse(for: request, body: """
            {
              "provider": "creem",
              "url": "https://checkout.creem.io/pay/test",
              "id": "chk_test"
            }
            """)
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: " license-api-key ",
            urlSession: URLProtocolStub.ephemeralSession()
        )
        let response = try await api.checkout(DirectCheckoutRequest(
            plan: .monthly,
            customerEmail: nil,
            successURL: nil,
            requestID: "request-1"
        ))

        #expect(response.provider == .creem)
        #expect(response.url == "https://checkout.creem.io/pay/test")
        #expect(response.id == "chk_test")
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("未配置 Direct API Key 时不发送 Authorization")
    func omitsAuthorizationWhenAPIKeyMissing() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return Self.jsonResponse(for: request, body: """
            {
              "provider": "creem",
              "url": "https://checkout.creem.io/pay/test"
            }
            """)
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: " ",
            urlSession: URLProtocolStub.ephemeralSession()
        )
        _ = try await api.checkout(DirectCheckoutRequest(
            plan: .lifetime,
            customerEmail: nil,
            successURL: nil,
            requestID: "request-2"
        ))

        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("cancelSubscription 命中 Direct 取消订阅路径")
    func cancelSubscriptionUsesDirectEndpoint() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/direct/subscriptions/cancel")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer license-api-key")
            return Self.jsonResponse(for: request, body: """
            {
              "provider": "creem",
              "subscriptionID": "sub_123",
              "status": "active",
              "productID": "prod_monthly",
              "currentPeriodEnd": "2026-08-08T00:00:00Z"
            }
            """)
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )
        let response = try await api.cancelSubscription(DirectCancelSubscriptionRequest(
            subscriptionID: "sub_123",
            mode: "scheduled",
            onExecute: "cancel"
        ))

        #expect(response.provider == .creem)
        #expect(response.subscriptionID == "sub_123")
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("账单管理只提交已激活授权码与实例")
    func customerPortalUsesLicenseContextInsteadOfCustomerID() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/direct/customer-portal")
            let body = try #require(Self.bodyData(from: request))
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
            #expect(payload?["licenseKey"] == "STARCAT-TEST-KEY")
            #expect(payload?["instanceID"] == "inst_123")
            #expect(payload?["customerID"] == nil)
            return Self.jsonResponse(for: request, body: """
            {
              "provider": "creem",
              "url": "https://creem.io/portal/cust_123"
            }
            """)
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )
        let response = try await api.customerPortal(DirectCustomerPortalRequest(
            licenseKey: "STARCAT-TEST-KEY",
            instanceID: "inst_123"
        ))

        #expect(response.url == "https://creem.io/portal/cust_123")
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("账单映射尚未同步时返回可重试提示")
    func customerPortalReportsBillingNotReady() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"code\":\"BILLING_NOT_READY\"}".utf8))
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )

        await #expect(throws: DirectLicenseAPIError.billingNotReady) {
            _ = try await api.customerPortal(DirectCustomerPortalRequest(
                licenseKey: "STARCAT-TEST-KEY",
                instanceID: "inst_123"
            ))
        }
    }

    @Test("激活席位已满时优先认 ACTIVATION_LIMIT_REACHED，不被 403 误判成鉴权失败")
    func activateReportsActivationLimitReached() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/v1/direct/licenses/activate")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"code\":\"ACTIVATION_LIMIT_REACHED\",\"message\":\"activation limit reached\"}".utf8))
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )

        await #expect(throws: DirectLicenseAPIError.activationLimitReached) {
            _ = try await api.activate(DirectLicenseActivationRequest(
                licenseKey: "STARCAT-TEST-KEY",
                deviceID: "Mac · Starcat ABCD",
                appVersion: "1.0.0"
            ))
        }
    }

    @Test("无限席位保留 Creem 的 null 限制")
    func activatePreservesUnlimitedActivationLimit() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active",
              "provider": "creem",
              "activationUsed": 5,
              "activationLimit": null,
              "validatedAt": "2026-07-12T00:00:00Z"
            }
            """)
        }

        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )
        let snapshot = try await api.activate(DirectLicenseActivationRequest(
            licenseKey: "STARCAT-TEST-KEY",
            deviceID: "Mac · Starcat ABCD",
            appVersion: "1.0.0"
        ))

        #expect(snapshot.activationUsed == 5)
        #expect(snapshot.activationLimit == nil)
    }

    @Test("限流业务码和无 JSON 的 429 均使用固定诊断码且只请求一次", arguments: [
        (429, #"{"code":"RATE_LIMITED","message":"SENSITIVE-LICENSE-KEY"}"#),
        (429, "<html>Too many requests</html>"),
        (429, #"{"code":"SENSITIVE-LICENSE-KEY"}"#),
        (503, #"{"code":"RATE_LIMITED"}"#)
    ])
    func recognizesRateLimit(status: Int, body: String) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Retry-After": "7"]
            )!
            return (response, Data(body.utf8))
        }
        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: nil,
            urlSession: URLProtocolStub.ephemeralSession()
        )
        do {
            _ = try await api.activate(DirectLicenseActivationRequest(licenseKey: "KEY", deviceID: "Mac", appVersion: "1.9.4"))
            Issue.record("Expected rate limit")
        } catch let error as DirectLicenseAPIError {
            #expect(error == .rateLimited(retryAfter: 7))
            #expect(error.diagnosticCode == "rate_limit_reached")
            #expect(error.preservesLocalEntitlement)
            #expect(error.errorDescription == String(format: String.l10n("settings.pro.direct.error.rateLimitedFormat"), 7))
        }
        #expect(DirectLicenseAPIError.safeServerCode(" RATE_LIMITED ") == "rate_limit_reached")
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("Retry-After 秒数与缺失/无效值", arguments: [
        (nil, 60), ("", 60), (" 7 ", 7), ("0", 0), ("-1", 60),
        ("1.5", 60), ("not-a-date", 60), ("99999999999999999999", 60)
    ] as [(String?, Int)])
    func parsesRetryDelay(header: String?, expected: Int) {
        #expect(DirectLicenseAPI.retryAfterSeconds(header) == expected)
    }

    @Test("Retry-After HTTP 日期向上取整，过期日期不再等待", arguments: [
        "Wed, 21 Oct 2015 07:28:00 GMT",
        "Wednesday, 21-Oct-15 07:28:00 GMT",
        "Wed Oct 21 07:28:00 2015"
    ])
    func parsesRetryDate(header: String) throws {
        let deadline = try #require(ISO8601DateFormatter().date(from: "2015-10-21T07:28:00Z"))
        #expect(DirectLicenseAPI.retryAfterSeconds(header, now: deadline.addingTimeInterval(-7.2)) == 8)
        #expect(DirectLicenseAPI.retryAfterSeconds(header, now: deadline) == 0)
        #expect(DirectLicenseAPI.retryAfterSeconds(header, now: deadline.addingTimeInterval(1)) == 0)
    }

    @Test("限流提示直接存在于全部支持语言的编译资源中")
    @MainActor
    func rateLimitMessageCoversSupportedLocales() throws {
        let key = "settings.pro.direct.error.rateLimitedFormat"
        for locale in AppLocale.allCases where locale != .system {
            let path = try #require(Bundle.main.path(forResource: locale.rawValue, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let format = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
            #expect(format != "__MISSING__", "Missing \(locale.rawValue)")
            #expect(format.components(separatedBy: "%d").count == 2)
            let message = String(format: format, 60)
            #expect(message.contains("60"))
            #expect(!message.contains("%"))
        }
    }

    @Test("2xx 解码失败转换为受控错误，不重试已可能生效的激活", arguments: [
        #"{"status":"active","provider":"creem","validatedAt":"SENSITIVE-LICENSE-KEY"}"#,
        #"{"status":"active","provider":"creem"}"#,
        #"{"status":"SENSITIVE-LICENSE-KEY","provider":"creem","validatedAt":"2026-11-10T00:00:00Z"}"#,
        #"{"status":"active","provider":"creem","validatedAt":null}"#,
        #"{"status":"active","provider":"creem","validatedAt":"2026-11-10T00:00:00Z","activationUsed":"SENSITIVE-LICENSE-KEY"}"#,
        "<html>SENSITIVE-LICENSE-KEY</html>"
    ])
    func decodingFailuresUseSafeError(body: String) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: body)
        }
        let api = DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: nil,
            urlSession: URLProtocolStub.ephemeralSession()
        )
        await #expect(throws: DirectLicenseAPIError.responseDecodingFailed) {
            _ = try await api.activate(DirectLicenseActivationRequest(
                licenseKey: "SENSITIVE-LICENSE-KEY", deviceID: "Mac", appVersion: "1.9.4"
            ))
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
        let error = DirectLicenseAPIError.responseDecodingFailed
        #expect(error.diagnosticCode == "response_decoding_failed")
        #expect(error.preservesLocalEntitlement)
        #expect(error.errorDescription == String.l10n("settings.pro.direct.error.responseDecodingFailed"))
        #expect(!error.localizedDescription.contains("SENSITIVE-LICENSE-KEY"))
    }

    @Test("解码诊断保留错误类别与安全字段，不输出值、动态键或底层描述")
    func decodingDiagnosticsRedactPayload() {
        let dateKey = DiagnosticKey(stringValue: "validatedAt")!
        let sensitiveKey = DiagnosticKey(stringValue: "SENSITIVE-LICENSE-KEY\nFORGED-LOG")!
        let context = DecodingError.Context(
            codingPath: [dateKey],
            debugDescription: "SENSITIVE-LICENSE-KEY",
            underlyingError: NSError(domain: "SENSITIVE-LICENSE-KEY", code: 1)
        )
        #expect(DirectLicenseAPI.decodingDiagnostic(DecodingError.dataCorrupted(context))
            == "reason=data_corrupted field_path=$.validatedAt")
        #expect(DirectLicenseAPI.decodingDiagnostic(DecodingError.typeMismatch(Int.self, context))
            == "reason=type_mismatch field_path=$.validatedAt")
        #expect(DirectLicenseAPI.decodingDiagnostic(DecodingError.valueNotFound(Date.self, context))
            == "reason=value_not_found field_path=$.validatedAt")
        #expect(DirectLicenseAPI.decodingDiagnostic(DecodingError.keyNotFound(sensitiveKey, context))
            == "reason=key_not_found field_path=$.validatedAt.<field>")
        let deviceContext = DecodingError.Context(
            codingPath: [DiagnosticKey(stringValue: "devices")!, DiagnosticKey(intValue: 2)!, sensitiveKey],
            debugDescription: "SENSITIVE-LICENSE-KEY"
        )
        #expect(DirectLicenseAPI.decodingDiagnostic(DecodingError.dataCorrupted(deviceContext))
            == "reason=data_corrupted field_path=$.devices.[].<field>")
        #expect(DirectLicenseAPI.decodingDiagnostic(NSError(domain: "SENSITIVE-LICENSE-KEY", code: 1))
            == "reason=other field_path=$")
    }

    @Test("激活阶段失败提示存在于全部支持语言的编译资源中")
    @MainActor
    func activationFailureMessagesCoverSupportedLocales() throws {
        for locale in AppLocale.allCases where locale != .system {
            let path = try #require(Bundle.main.path(forResource: locale.rawValue, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for suffix in ["responseDecodingFailed", "credentialSaveFailed"] {
                let key = "settings.pro.direct.error.\(suffix)"
                let message = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                #expect(message != "__MISSING__", "Missing \(locale.rawValue): \(key)")
                #expect(!message.isEmpty)
                #expect(!message.contains("%"))
            }
        }
    }

    /// 模拟 JSON 动态键；诊断不能假设所有 CodingKey 都是编译期字段。
    private struct DiagnosticKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = "Index \(intValue)"
            self.intValue = intValue
        }
    }

    private static func jsonResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// `URLSession` 转交给 `URLProtocol` 时可能把 `httpBody` 改放到 stream。
    /// 测试必须同时读取两种承载方式，才能验证实际发送的 JSON 契约。
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
