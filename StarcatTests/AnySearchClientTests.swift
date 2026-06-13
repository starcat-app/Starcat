//
//  AnySearchClientTests.swift
//  StarcatTests
//
//  覆盖 AnySearch URL 规范化和请求边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnySearch Client")
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
}
