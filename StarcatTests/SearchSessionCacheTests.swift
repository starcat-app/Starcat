//
//  SearchSessionCacheTests.swift
//  StarcatTests
//
//  验证短期缓存命中与过期清理。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Session Cache")
struct SearchSessionCacheTests {
    @Test("TTL 内命中，过期后清理")
    func expiry() async {
        let cache = SearchSessionCache<String>(ttl: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        await cache.insert("value", for: "key", now: now)
        #expect(await cache.value(for: "key", now: now.addingTimeInterval(59)) == "value")
        #expect(await cache.value(for: "key", now: now.addingTimeInterval(61)) == nil)
    }
}
