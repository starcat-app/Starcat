//
//  DiskIssueDraftCacheTests.swift
//  StarcatTests
//
//  新建 Issue 草稿：按仓库读写、空删、标题钳制、过期淘汰、条数上限、跨仓隔离。
//  每个用例用临时目录，不碰生产 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskIssueDraftCache")
struct DiskIssueDraftCacheTests {

    private func makeIsolatedCache(
        clock: @escaping () -> Date = Date.init
    ) -> (cache: DiskIssueDraftCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "starcat-issue-draft-test-\(UUID().uuidString)",
                isDirectory: true
            )
        return (DiskIssueDraftCache(rootOverride: root, clock: clock), root)
    }

    @Test("写入后按仓库读回同一份标题与正文")
    func roundTrip() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(repoFullName: "starcat-app/Starcat", title: "Crash on launch", body: "## Steps\n1. open app")
        let loaded = cache.load(repoFullName: "starcat-app/Starcat")
        #expect(loaded?.title == "Crash on launch")
        #expect(loaded?.body == "## Steps\n1. open app")
        #expect(cache.itemCount == 1)
        #expect(cache.totalBytes > 0)
    }

    @Test("不同仓库草稿互不干扰")
    func reposAreIsolated() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(repoFullName: "a/one", title: "title one", body: "")
        cache.upsert(repoFullName: "b/two", title: "title two", body: "body")
        #expect(cache.load(repoFullName: "a/one")?.title == "title one")
        #expect(cache.load(repoFullName: "b/two")?.title == "title two")
        #expect(cache.itemCount == 2)
    }

    @Test("标题与正文全空白删除该仓缓存")
    func emptyDraftRemoves() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(repoFullName: "a/one", title: "keep", body: "me")
        cache.upsert(repoFullName: "a/one", title: "   ", body: "")
        #expect(cache.load(repoFullName: "a/one") == nil)
        #expect(cache.itemCount == 0)
    }

    @Test("标题钳制到 256 字符，正文钳制到 64KB")
    func clampsTitleAndBody() {
        #expect(DiskIssueDraftCache.clampedTitle(String(repeating: "x", count: 300)).count == 256)
        #expect(DiskIssueDraftCache.clampedTitle("  hi  ") == "hi")

        let hugeBody = String(repeating: "字", count: DiskIssueDraftCache.maxBodyUTF8Bytes)
        let clamped = DiskIssueDraftCache.clampedBody(hugeBody)
        #expect(clamped.utf8.count <= DiskIssueDraftCache.maxBodyUTF8Bytes)
    }

    @Test("超过 30 天的草稿读取时丢掉")
    func expiredDraftIsDropped() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (cache, root) = makeIsolatedCache(clock: { now })
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(repoFullName: "a/old", title: "stale", body: "")
        now = now.addingTimeInterval(DiskIssueDraftCache.maxAge + 60)
        #expect(cache.load(repoFullName: "a/old") == nil)
    }

    @Test("超过上限时丢掉最旧的仓库草稿")
    func evictsOldestWhenOverCap() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (cache, root) = makeIsolatedCache(clock: { now })
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...DiskIssueDraftCache.maxItemCount {
            cache.upsert(repoFullName: "a/r-\(index)", title: "t\(index)", body: "")
            now = now.addingTimeInterval(1)
        }
        cache.upsert(repoFullName: "a/newest", title: "newest", body: "")
        #expect(cache.load(repoFullName: "a/r-1") == nil)
        #expect(cache.load(repoFullName: "a/r-2")?.title == "t2")
        #expect(cache.load(repoFullName: "a/newest")?.title == "newest")
        #expect(cache.itemCount == DiskIssueDraftCache.maxItemCount)
    }

    @Test("deleteEverything 清目录并归零统计")
    func deleteEverythingClears() throws {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(repoFullName: "a/one", title: "gone", body: "")
        try cache.deleteEverything()
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
        #expect(cache.load(repoFullName: "a/one") == nil)
    }

    @Test("owner 中的 / 被替换，路径组件保持安全")
    func safeRepoKey() throws {
        let key = try DiskIssueDraftCache.safeRepoKey("owner/repo")
        #expect(key == "owner-repo")
        #expect(!key.contains("/"))
    }
}
