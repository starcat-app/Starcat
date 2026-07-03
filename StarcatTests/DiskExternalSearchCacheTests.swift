//
//  DiskExternalSearchCacheTests.swift
//  StarcatTests
//
//  覆盖 External Search 磁盘缓存的 provider 隔离、TTL 与写入边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DiskExternalSearchCache")
@MainActor
struct DiskExternalSearchCacheTests {
    @Test("global cache key 稳定且包含 provider")
    func globalCacheKeyIsStableAndProviderScoped() throws {
        let encoder = makeKeyEncoder()
        let request = ExternalSearchRequest(query: "swift", purpose: .globalSearch, maxResults: 3)

        let tavily1 = try DiskExternalSearchCache.globalCacheKey(provider: .tavily, request: request, encoder: encoder)
        let tavily2 = try DiskExternalSearchCache.globalCacheKey(provider: .tavily, request: request, encoder: encoder)
        let exa = try DiskExternalSearchCache.globalCacheKey(provider: .exa, request: request, encoder: encoder)

        #expect(tavily1 == tavily2)
        #expect(tavily1 != exa)
        #expect(tavily1.count == 64)
    }

    @Test("global cache 按 provider 隔离读写")
    func globalCacheIsProviderScoped() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ExternalSearchRequest(query: "swift", purpose: .globalSearch)
        let response = makeResponse(provider: .tavily, title: "Tavily")

        try await cache.saveGlobal(provider: .tavily, request: request, response: response)

        let tavily = try await cache.loadGlobal(provider: .tavily, request: request)
        let exa = try await cache.loadGlobal(provider: .exa, request: request)
        #expect(tavily?.hits.first?.title == "Tavily")
        #expect(exa == nil)
    }

    @Test("credentialTest 和 0 命中不写 global cache")
    func credentialTestAndEmptyResponseAreNotSaved() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }

        let credentialRequest = ExternalSearchRequest(query: "who is dong4j", purpose: .credentialTest, maxResults: 1)
        try await cache.saveGlobal(provider: .exa, request: credentialRequest, response: makeResponse(provider: .exa, title: "x"))
        #expect(try await cache.loadGlobal(provider: .exa, request: credentialRequest) == nil)

        let emptyRequest = ExternalSearchRequest(query: "empty", purpose: .globalSearch)
        try await cache.saveGlobal(
            provider: .exa,
            request: emptyRequest,
            response: ExternalSearchResponse(hits: [], metadata: ExternalSearchMetadata(provider: .exa))
        )
        #expect(try await cache.loadGlobal(provider: .exa, request: emptyRequest) == nil)
        #expect(cache.itemCount == 0)
    }

    @Test("global cache 超过 TTL 后返回 nil 并删除文件")
    func globalCacheExpiresByTTL() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ExternalSearchRequest(query: "old", purpose: .globalSearch)

        try await cache.saveGlobal(provider: .braveLLMContext, request: request, response: makeResponse(provider: .braveLLMContext, title: "Old"))
        let files = jsonFiles(under: root)
        let file = try #require(files.first)
        let oldDate = Date(timeIntervalSinceNow: -(DiskExternalSearchCache.globalTTL + 60))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let cached = try await cache.loadGlobal(provider: .braveLLMContext, request: request)

        #expect(cached == nil)
        #expect(jsonFiles(under: root).isEmpty)
    }

    private func makeCache() -> (DiskExternalSearchCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskExternalSearchCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (DiskExternalSearchCache(rootOverride: root), root)
    }

    private func makeResponse(provider: ExternalSearchProviderID, title: String) -> ExternalSearchResponse {
        ExternalSearchResponse(
            hits: [
                ExternalSearchHit(
                    title: title,
                    url: URL(string: "https://example.com/\(title.lowercased())")!,
                    snippet: "snippet",
                    extractedText: "text"
                )
            ],
            metadata: ExternalSearchMetadata(provider: provider, totalResults: 1)
        )
    }

    private func makeKeyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func jsonFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "json" else { return nil }
            return url
        }
    }
}
