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
            let body = try #require(request.httpBody)
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

    private static func jsonResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
