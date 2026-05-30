//
//  RateLimitInfoTests.swift
//  StarcatTests
//

import Testing
import Foundation
@testable import Starcat

@Suite("RateLimitInfo")
struct RateLimitInfoTests {

    private func makeResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/test")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test("解析完整字段")
    func parseFull() {
        let now = Date().addingTimeInterval(60)
        let resp = makeResponse(headers: [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4999",
            "X-RateLimit-Reset": "\(Int(now.timeIntervalSince1970))"
        ])
        let info = RateLimitInfo.parse(resp)
        #expect(info.limit == 5000)
        #expect(info.remaining == 4999)
        #expect(info.reset != nil)
    }

    @Test("缺字段时不应 crash")
    func missingFields() {
        let resp = makeResponse(headers: [:])
        let info = RateLimitInfo.parse(resp)
        #expect(info.limit == nil)
        #expect(info.remaining == nil)
        #expect(info.reset == nil)
        #expect(info.isExhausted == false)  // nil != 0
    }

    @Test("remaining=0 时 isExhausted=true")
    func exhausted() {
        let resp = makeResponse(headers: ["X-RateLimit-Remaining": "0"])
        let info = RateLimitInfo.parse(resp)
        #expect(info.isExhausted == true)
    }

    @Test("retryAfter 应非负")
    func retryAfterIsNonNegative() {
        let pastEpoch = Int(Date().timeIntervalSince1970 - 1000)
        let resp = makeResponse(headers: ["X-RateLimit-Reset": "\(pastEpoch)"])
        let info = RateLimitInfo.parse(resp)
        #expect(info.retryAfter() == 0)
    }
}
