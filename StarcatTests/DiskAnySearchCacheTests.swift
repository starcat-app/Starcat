//
//  DiskAnySearchCacheTests.swift
//  StarcatTests
//
//  覆盖 DiskAnySearchCache 全路径（HOM-69 / 2026-06-15）：
//    - global 路径：save / load / TTL 过期 / rateLimit 写盘时清空 / sha 稳定性 / 路径分桶
//    - ai-summary 路径：save / load / TTL 过期 / ephemeral repo (id=0) 跳过
//    - 损坏 JSON 兜底 / deleteEverything / observable 派生量 / LRU sweep
//
//  关键约束：
//  - 每个用例用 `rootOverride: tempDir` 注入隔离目录，绝不污染 production
//    `~/Library/Application Support/com.starcat.app/anysearch-cache/`；
//  - DiskAnySearchCache 是 `@MainActor`，整个 Suite 标 `@MainActor` 简化签名。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskAnySearchCache")
struct DiskAnySearchCacheTests {

    /// 创建一份隔离的 cache 实例 + 它的临时 root。测试结束后调用方负责删 root。
    private func makeIsolatedCache() -> (cache: DiskAnySearchCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-anysearch-test-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskAnySearchCache(rootOverride: root)
        return (cache, root)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRequest(query: String = "swift concurrency") -> AnySearchRequest {
        AnySearchRequest(
            query: query,
            maxResults: 10,
            domain: "code",
            tag: nil,
            contentTypes: ["web", "doc"],
            zone: nil,
            language: "en",
            params: nil
        )
    }

    private func makeResponse(
        resultCount: Int = 2,
        withRateLimit: Bool = true
    ) -> AnySearchResponse {
        let results = (0..<resultCount).map { i in
            AnySearchResult(
                title: "Result \(i)",
                url: URL(string: "https://example.com/r\(i)")!,
                normalizedURL: URL(string: "https://example.com/r\(i)")!,
                snippet: "snippet \(i)",
                content: nil,
                sourceDomain: "example.com"
            )
        }
        let metadata = AnySearchMetadata(requestId: "req-1", totalResults: resultCount, searchTimeMs: 123)
        let rateLimit: AnySearchRateLimit? = withRateLimit
            ? AnySearchRateLimit(limit: 100, remaining: 80, resetAt: Date(timeIntervalSinceNow: 60))
            : nil
        return AnySearchResponse(results: results, metadata: metadata, rateLimit: rateLimit)
    }

    private func makeAIContext(sources: Int = 2) -> AIExternalContext {
        let urls = (0..<sources).map { URL(string: "https://docs.example.com/p\($0)")! }
        return AIExternalContext(
            markdown: "<external_context>\n- [doc](https://docs.example.com)\n</external_context>",
            sources: urls
        )
    }

    // MARK: - global 路径

    @Test("loadGlobal 未命中返回 nil")
    func globalMissReturnsNil() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let result = try await cache.loadGlobal(request: makeRequest())
        #expect(result == nil)
    }

    @Test("saveGlobal + loadGlobal 同请求往返")
    func globalRoundTrip() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let request = makeRequest()
        let response = makeResponse(resultCount: 3)

        try await cache.saveGlobal(request: request, response: response)
        let fetched = try await cache.loadGlobal(request: request)

        #expect(fetched?.results.count == 3)
        #expect(fetched?.results.first?.title == "Result 0")
        #expect(fetched?.metadata?.requestId == "req-1")
    }

    @Test("saveGlobal 写盘时清空 rateLimit")
    func globalSaveStripsRateLimit() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let request = makeRequest()
        let response = makeResponse(withRateLimit: true)
        #expect(response.rateLimit != nil) // 前置：原 response 带 rateLimit

        try await cache.saveGlobal(request: request, response: response)
        let fetched = try await cache.loadGlobal(request: request)

        // 写盘前 rateLimit 应被清空（cache 命中时旧的 remaining/resetAt 已无意义）
        #expect(fetched?.rateLimit == nil)
    }

    @Test("不同 query 互不命中")
    func differentQueriesIsolated() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let r1 = makeRequest(query: "swift")
        let r2 = makeRequest(query: "rust")
        try await cache.saveGlobal(request: r1, response: makeResponse(resultCount: 1))
        try await cache.saveGlobal(request: r2, response: makeResponse(resultCount: 5))

        let f1 = try await cache.loadGlobal(request: r1)
        let f2 = try await cache.loadGlobal(request: r2)
        #expect(f1?.results.count == 1)
        #expect(f2?.results.count == 5)
    }

    @Test("global TTL 过期 → loadGlobal 返 nil 并自动删文件")
    func globalTTLExpiry() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let request = makeRequest()
        try await cache.saveGlobal(request: request, response: makeResponse())

        // 找到该 request 对应的 sha256 文件，手动把 mtime 调到 7 小时前（超过 6h TTL）
        let key = try DiskAnySearchCache.cacheKey(
            forRequest: request,
            encoder: makeStableEncoder()
        )
        let fileURL = root
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).json")
        let agedDate = Date(timeIntervalSinceNow: -7 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: agedDate], ofItemAtPath: fileURL.path)

        let result = try await cache.loadGlobal(request: request)
        #expect(result == nil)
        // load 过期路径会删文件，下次写入不会被旧文件挡
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("cacheKey 对同输入跨次调用稳定（sortedKeys）")
    func cacheKeyIsStable() throws {
        let request = makeRequest()
        let encoder = makeStableEncoder()
        let key1 = try DiskAnySearchCache.cacheKey(forRequest: request, encoder: encoder)
        let key2 = try DiskAnySearchCache.cacheKey(forRequest: request, encoder: encoder)
        #expect(key1 == key2)
        #expect(key1.count == 64)
        #expect(key1.allSatisfy { $0.isHexDigit })
    }

    @Test("路径分桶：global 文件落在 <sha256[:2]>/<sha256>.json")
    func globalUsesShardedBucket() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let request = makeRequest()
        try await cache.saveGlobal(request: request, response: makeResponse())

        let key = try DiskAnySearchCache.cacheKey(
            forRequest: request,
            encoder: makeStableEncoder()
        )
        let expected = root
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).json")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    // MARK: - ai-summary 路径

    @Test("loadAISummary 未命中返回 nil")
    func aiSummaryMissReturnsNil() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let result = try await cache.loadAISummary(repoId: 42)
        #expect(result == nil)
    }

    @Test("saveAISummary + loadAISummary 同 repoId 往返")
    func aiSummaryRoundTrip() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let context = makeAIContext(sources: 3)
        try await cache.saveAISummary(repoId: 1001, context: context)

        let fetched = try await cache.loadAISummary(repoId: 1001)
        #expect(fetched?.sources.count == 3)
        #expect(fetched?.markdown == context.markdown)
    }

    @Test("ephemeral repo (id=0) 既不写也不读")
    func aiSummarySkipsEphemeralRepo() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let context = makeAIContext()
        // save with id=0 应该被 cache 内部跳过，不写任何文件
        try await cache.saveAISummary(repoId: 0, context: context)
        #expect(cache.itemCount == 0)

        // load with id=0 应直接返 nil
        let result = try await cache.loadAISummary(repoId: 0)
        #expect(result == nil)
    }

    @Test("ai-summary TTL 过期（>24h） → loadAISummary 返 nil 并自动删文件")
    func aiSummaryTTLExpiry() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.saveAISummary(repoId: 7, context: makeAIContext())

        let fileURL = root
            .appendingPathComponent("ai-summary", isDirectory: true)
            .appendingPathComponent("7.json")
        let agedDate = Date(timeIntervalSinceNow: -25 * 60 * 60) // 25h 前 > 24h TTL
        try FileManager.default.setAttributes([.modificationDate: agedDate], ofItemAtPath: fileURL.path)

        let result = try await cache.loadAISummary(repoId: 7)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - 损坏 JSON 兜底

    @Test("损坏 JSON → loadGlobal 返 nil 并删文件")
    func corruptedGlobalJSONHandled() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let request = makeRequest()
        try await cache.saveGlobal(request: request, response: makeResponse())

        let key = try DiskAnySearchCache.cacheKey(
            forRequest: request,
            encoder: makeStableEncoder()
        )
        let fileURL = root
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).json")
        try Data("not-json".utf8).write(to: fileURL, options: .atomic)

        let result = try await cache.loadGlobal(request: request)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Observable + deleteEverything

    @Test("写入后 Observable itemCount / totalBytes 同步更新")
    func observablePropertiesUpdateOnWrite() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)

        try await cache.saveGlobal(request: makeRequest(), response: makeResponse())
        #expect(cache.itemCount == 1)
        #expect(cache.totalBytes > 0)

        try await cache.saveAISummary(repoId: 99, context: makeAIContext())
        #expect(cache.itemCount == 2)
    }

    @Test("deleteEverything 清空整个搜索缓存")
    func deleteEverythingWipesAll() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.saveGlobal(request: makeRequest(query: "a"), response: makeResponse())
        try await cache.saveGlobal(request: makeRequest(query: "b"), response: makeResponse())
        try await cache.saveAISummary(repoId: 1, context: makeAIContext())

        try await cache.deleteEverything()

        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
        #expect(try await cache.loadGlobal(request: makeRequest(query: "a")) == nil)
        #expect(try await cache.loadAISummary(repoId: 1) == nil)
    }

    // MARK: - LRU sweep

    @Test("LRU sweep：global TTL 过期条目被删；fresh 保留")
    func lruSweepRemovesAgedGlobal() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let aged = makeRequest(query: "aged-one")
        let fresh = makeRequest(query: "fresh-one")
        try await cache.saveGlobal(request: aged, response: makeResponse())
        try await cache.saveGlobal(request: fresh, response: makeResponse())

        // 把 aged 的 mtime 调到 7 小时前
        let agedKey = try DiskAnySearchCache.cacheKey(
            forRequest: aged,
            encoder: makeStableEncoder()
        )
        let agedFile = root
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent(String(agedKey.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(agedKey).json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7 * 60 * 60)],
            ofItemAtPath: agedFile.path
        )

        try cache.lruSweep()

        #expect(!FileManager.default.fileExists(atPath: agedFile.path))
        #expect(try await cache.loadGlobal(request: fresh) != nil)
    }

    @Test("LRU sweep：ai-summary 25h 前条目被删；fresh 保留")
    func lruSweepRemovesAgedAISummary() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.saveAISummary(repoId: 100, context: makeAIContext())
        try await cache.saveAISummary(repoId: 200, context: makeAIContext())

        let agedFile = root
            .appendingPathComponent("ai-summary", isDirectory: true)
            .appendingPathComponent("100.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -25 * 60 * 60)],
            ofItemAtPath: agedFile.path
        )

        try cache.lruSweep()

        #expect(try await cache.loadAISummary(repoId: 100) == nil)
        #expect(try await cache.loadAISummary(repoId: 200) != nil)
    }

    @Test("reload 不删任何文件，纯刷新派生量")
    func reloadIsReadonly() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.saveGlobal(request: makeRequest(), response: makeResponse())
        let before = cache.itemCount
        cache.reload()
        cache.reload()
        #expect(cache.itemCount == before)
        #expect(try await cache.loadGlobal(request: makeRequest()) != nil)
    }

    // MARK: - 辅助

    /// 与 `DiskAnySearchCache` 内部 keyEncoder 同款配置，给测试算预期 sha256 用。
    private func makeStableEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.keyEncodingStrategy = .convertToSnakeCase
        return enc
    }
}
