//
//  DiskNotificationCommentDraftCacheTests.swift
//  StarcatTests
//
//  未提交评论草稿：读写、空删、过期淘汰、条数上限、生成中不落半截稿。
//  每个用例用临时目录，不碰生产 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskNotificationCommentDraftCache")
struct DiskNotificationCommentDraftCacheTests {

    private func makeIsolatedCache(
        clock: @escaping () -> Date = Date.init
    ) -> (cache: DiskNotificationCommentDraftCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "starcat-issue-comment-draft-test-\(UUID().uuidString)",
                isDirectory: true
            )
        return (DiskNotificationCommentDraftCache(rootOverride: root, clock: clock), root)
    }

    @Test("写入后按 threadId 读回同一份正文")
    func roundTrip() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(threadId: "12345", draft: "please take a look")
        let loaded = cache.load(threadId: "12345")
        #expect(loaded?.draft == "please take a look")
        #expect(cache.itemCount == 1)
        #expect(cache.totalBytes > 0)
    }

    @Test("空正文删除该帖缓存")
    func emptyDraftRemoves() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(threadId: "12345", draft: "keep me")
        cache.upsert(threadId: "12345", draft: "   ")
        #expect(cache.load(threadId: "12345") == nil)
        #expect(cache.itemCount == 0)
    }

    @Test("超过 30 天的草稿读取时丢掉")
    func expiredDraftIsDropped() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (cache, root) = makeIsolatedCache(clock: { now })
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(threadId: "old", draft: "stale reply")
        now = now.addingTimeInterval(DiskNotificationCommentDraftCache.maxAge + 60)
        #expect(cache.load(threadId: "old") == nil)
    }

    @Test("超过 50 帖时丢掉最旧的")
    func evictsOldestWhenOverCap() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let (cache, root) = makeIsolatedCache(clock: { now })
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...DiskNotificationCommentDraftCache.maxItemCount {
            cache.upsert(threadId: "t-\(index)", draft: "draft \(index)")
            now = now.addingTimeInterval(1)
        }
        cache.upsert(threadId: "t-newest", draft: "newest")
        #expect(cache.load(threadId: "t-1") == nil)
        #expect(cache.load(threadId: "t-2")?.draft == "draft 2")
        #expect(cache.load(threadId: "t-newest")?.draft == "newest")
        #expect(cache.itemCount == DiskNotificationCommentDraftCache.maxItemCount)
    }

    @Test("生成中只保留点 AI 之前的原文")
    func persistableDraftSkipsPartialGeneration() {
        #expect(
            DiskNotificationCommentDraftCache.persistableDraft(
                current: "partial stream",
                previous: "typed earlier",
                isGenerating: true
            ) == "typed earlier"
        )
        #expect(
            DiskNotificationCommentDraftCache.persistableDraft(
                current: "AI finished reply",
                previous: "typed earlier",
                isGenerating: false
            ) == "AI finished reply"
        )
    }

    @Test("deleteEverything 清目录并归零统计")
    func deleteEverythingClears() throws {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.upsert(threadId: "12345", draft: "gone")
        try cache.deleteEverything()
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
        #expect(cache.load(threadId: "12345") == nil)
    }
}
