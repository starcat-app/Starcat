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

    private static func successResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(#"{"code":0,"message":"ok","data":{"results":[],"metadata":null}}"#.utf8)
        return (response, data)
    }
}
