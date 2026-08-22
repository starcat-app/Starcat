//
//  DiskIssueTimelineCacheTests.swift
//  StarcatTests
//
//  Issue 事件流文件缓存：读写、损坏删除、路径校验、清除全部。
//  每个用例用临时目录，不碰生产 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskIssueTimelineCache")
struct DiskIssueTimelineCacheTests {

    private func makeIsolatedCache() -> (cache: DiskIssueTimelineCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-issue-timeline-test-\(UUID().uuidString)", isDirectory: true)
        return (DiskIssueTimelineCache(rootOverride: root), root)
    }

    private func makeSnapshot(
        owner: String = "octo",
        repo: String = "hello",
        number: Int = 3
    ) -> IssueTimelineCacheSnapshot {
        IssueTimelineCacheSnapshot(
            formatVersion: IssueTimelineCacheSnapshot.currentFormatVersion,
            owner: owner,
            repo: repo,
            number: number,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: [
                .comment(
                    GitHubNotificationComment(
                        id: 99,
                        login: "dong4j",
                        body: "please take a look",
                        htmlURL: "https://github.com/octo/hello/issues/3#issuecomment-99",
                        createdAt: "2026-08-19T00:00:00Z"
                    )
                )
            ]
        )
    }

    @Test("save 后 load 拿回同一份 snapshot")
    func roundTrip() throws {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = makeSnapshot()
        try cache.save(snapshot: snapshot)
        let loaded = try #require(cache.load(owner: "octo", repo: "hello", number: 3))
        #expect(loaded == snapshot)
        #expect(cache.itemCount == 1)
        #expect(cache.totalBytes > 0)
    }

    @Test("损坏 JSON 会删文件并 miss")
    func corruptFileIsRemoved() throws {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.save(snapshot: makeSnapshot())
        let file = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("hello", isDirectory: true)
            .appendingPathComponent("3.json")
        try Data("not-json".utf8).write(to: file)
        #expect(cache.load(owner: "octo", repo: "hello", number: 3) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("路径段非法会抛 unsafePathComponent")
    func rejectsUnsafePath() {
        #expect(throws: DiskIssueTimelineCacheError.self) {
            try DiskIssueTimelineCache.assertSafePathComponent("..")
        }
        #expect(throws: DiskIssueTimelineCacheError.self) {
            try DiskIssueTimelineCache.assertSafePathComponent("octo/hello")
        }
    }

    @Test("deleteEverything 清目录并归零统计")
    func deleteEverythingClears() throws {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        try cache.save(snapshot: makeSnapshot())
        try cache.deleteEverything()
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
        #expect(cache.load(owner: "octo", repo: "hello", number: 3) == nil)
    }
}
