//
//  DiskWikiCacheTests.swift
//  StarcatTests
//
//  覆盖 DiskWikiCache 全路径（2026-06-15 v4.y）：
//    - save / load round-trip（WikiStatusItem Codable + Snapshot Codable）
//    - load miss / load 损坏 JSON 兜底（删文件 + 返回 nil）
//    - 路径段安全校验（`..` / `/` / 空串 → 抛 unsafePathComponent）
//    - WikiCacheSnapshot.computeNextProbeAt 分层 TTL（indexed 30d / notIndexed 3d /
//      unknown 6h / error 30m）
//    - freshness 判定（now < nextProbeAt = fresh）
//    - observable 派生量 itemCount / totalBytes 随 save / delete 更新
//    - deleteEverything 全清 + reload 归零
//
//  关键约束：
//  - 每个用例用 `rootOverride: tempDir` 注入隔离目录，绝不污染 production
//    `~/Library/Application Support/com.starcat.app/wiki-cache/`；
//  - DiskWikiCache 是 `@MainActor`，整个 Suite 标 `@MainActor` 简化签名。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskWikiCache")
struct DiskWikiCacheTests {

    private func makeIsolatedCache() -> (cache: DiskWikiCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-wiki-test-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskWikiCache(rootOverride: root)
        return (cache, root)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeItem(
        source: WikiSource,
        status: WikiProbeStatus,
        url: String = "https://example.com/foo/bar"
    ) -> WikiStatusItem {
        WikiStatusItem(
            source: source,
            status: status,
            url: URL(string: url)!,
            probeMethod: "GET",
            httpStatus: status == .indexed ? 200 : 404,
            matchedSignals: nil
        )
    }

    private func makeSnapshot(
        owner: String = "facebook",
        repo: String = "react",
        items: [WikiStatusItem]? = nil
    ) -> WikiCacheSnapshot {
        let actualItems = items ?? [
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/facebook/react"),
            makeItem(source: .zread, status: .indexed, url: "https://zread.com/facebook/react"),
            makeItem(source: .codeWiki, status: .indexed, url: "https://codewiki.com/facebook/react")
        ]
        // 用整数秒构造,避免 JSONEncoder.dateEncodingStrategy = .iso8601 在
        // round-trip 时丢小数秒精度导致 `WikiCacheSnapshot ==` 比较失败。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return WikiCacheSnapshot(
            owner: owner,
            repo: repo,
            probedAt: now,
            nextProbeAt: WikiCacheSnapshot.computeNextProbeAt(items: actualItems, now: now),
            items: actualItems
        )
    }

    // MARK: - save / load round-trip

    @Test("save 后 load 拿回同一份 snapshot（含 indexed / not_indexed / error 混合状态）")
    func testRoundTrip() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        let mixedItems = [
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/foo/bar"),
            makeItem(source: .zread, status: .notIndexed, url: "https://zread.com/foo/bar"),
            makeItem(source: .codeWiki, status: .error, url: "https://codewiki.com/foo/bar"),
            makeItem(source: .unknown("brand-x"), status: .unknown("probing"), url: "https://brand-x.com/foo/bar")
        ]
        let snapshot = makeSnapshot(owner: "foo", repo: "bar", items: mixedItems)
        try cache.save(snapshot: snapshot)

        let loaded = cache.load(owner: "foo", repo: "bar")
        #expect(loaded == snapshot)
        #expect(loaded?.items.count == 4)
    }

    @Test("indexedLinks 派生属性只保留 .indexed + http(s) 源,且固定排序")
    func testIndexedLinksFilter() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        let items = [
            makeItem(source: .zread, status: .indexed, url: "https://zread.com/foo/bar"),
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/foo/bar"),
            makeItem(source: .codeWiki, status: .notIndexed, url: "https://codewiki.com/foo/bar")
        ]
        try cache.save(snapshot: makeSnapshot(items: items))
        let loaded = cache.load(owner: "facebook", repo: "react")
        let links = loaded?.indexedLinks ?? []

        #expect(links.count == 2, "notIndexed 必须被滤掉")
        #expect(links[0].source == .deepWiki, "排序按 sortOrder")
        #expect(links[1].source == .zread)
    }

    @Test("批量 availability 在后台读取，并保留 available / missing / unknown 三态")
    func batchAvailabilityKeepsUnknownDistinct() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let threadRecorder = WikiReadThreadRecorder()

        try cache.save(snapshot: makeSnapshot(owner: "foo", repo: "available"))
        try cache.save(snapshot: makeSnapshot(
            owner: "foo",
            repo: "missing",
            items: [makeItem(source: .deepWiki, status: .notIndexed)]
        ))

        let result = await WikiAvailabilitySnapshotLoader.load(
            requests: [
                WikiAvailabilityRequest(id: 1, owner: "foo", repo: "available"),
                WikiAvailabilityRequest(id: 2, owner: "foo", repo: "missing"),
                WikiAvailabilityRequest(id: 3, owner: "foo", repo: "never-probed")
            ],
            rootOverride: root,
            readObserverForTesting: { isMainThread in
                threadRecorder.record(isMainThread: isMainThread)
            }
        )

        #expect(result[1] == true)
        #expect(result[2] == false)
        #expect(result[3] == nil, "没有缓存必须保持 unknown，不能误归类为 missing")
        #expect(threadRecorder.observations == [false, false, false],
                "每个 JSON 文件检查都必须在 MainActor / 主线程之外执行")
    }

    @Test("批量 availability 遇到损坏文件只返回 unknown，不在后台线程改缓存统计")
    func batchAvailabilityTreatsCorruptionAsUnknownWithoutMutation() async throws {
        let (_, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let directory = root.appendingPathComponent("foo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupted = directory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: corrupted)

        let result = await WikiAvailabilitySnapshotLoader.load(
            requests: [WikiAvailabilityRequest(id: 9, owner: "foo", repo: "broken")],
            rootOverride: root
        )

        #expect(result[9] == nil)
        #expect(FileManager.default.fileExists(atPath: corrupted.path),
                "批量只读加载器不能越过 DiskWikiCache 的 @MainActor CRUD 边界删文件")
    }

    // MARK: - miss / 损坏兜底

    @Test("load 未命中返回 nil")
    func testLoadMiss() {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        let loaded = cache.load(owner: "no", repo: "such")
        #expect(loaded == nil)
    }

    @Test("load 遇到损坏 JSON 返回 nil 且删掉损坏文件")
    func testCorruptedJSONFallback() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        // 手工写一段非法 JSON 到 cache 路径
        let dir = root.appendingPathComponent("foo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("bar.json")
        try Data("not a valid json".utf8).write(to: file)

        #expect(FileManager.default.fileExists(atPath: file.path))
        let loaded = cache.load(owner: "foo", repo: "bar")
        #expect(loaded == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path), "损坏文件应被删掉")
    }

    // MARK: - 路径安全校验

    @Test("path traversal / 空段 / 路径分隔符 → 抛 unsafePathComponent")
    func testUnsafePathComponent() {
        let dangerous = ["", ".", "..", "foo/bar", "back\\slash", "with\0null"]
        for input in dangerous {
            #expect(throws: DiskWikiCacheError.self) {
                try DiskWikiCache.assertSafePathComponent(input)
            }
        }
        let safe = ["facebook", "swift-package-manager", "abc.def", "_underscore"]
        for input in safe {
            #expect(throws: Never.self) {
                try DiskWikiCache.assertSafePathComponent(input)
            }
        }
    }

    // MARK: - 分层 TTL 计算

    @Test("全部 indexed → 长 TTL = 30 天")
    func testLongTTLAllIndexed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            makeItem(source: .deepWiki, status: .indexed),
            makeItem(source: .zread, status: .indexed),
            makeItem(source: .codeWiki, status: .indexed)
        ]
        let next = WikiCacheSnapshot.computeNextProbeAt(items: items, now: now)
        let expected = now.addingTimeInterval(WikiCacheSnapshot.longTTL)
        #expect(abs(next.timeIntervalSince(expected)) < 0.001)
    }

    @Test("任一明确未收录 → 短 TTL = 3 天")
    func testShortTTLAnyNotIndexed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            makeItem(source: .deepWiki, status: .indexed),
            makeItem(source: .zread, status: .notIndexed)
        ]
        let next = WikiCacheSnapshot.computeNextProbeAt(items: items, now: now)
        let expected = now.addingTimeInterval(WikiCacheSnapshot.shortTTL)
        #expect(abs(next.timeIntervalSince(expected)) < 0.001)
    }

    @Test("任一错误 → 错误 TTL = 30 分钟")
    func testErrorTTL() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            makeItem(source: .deepWiki, status: .indexed),
            makeItem(source: .zread, status: .error)
        ]
        let next = WikiCacheSnapshot.computeNextProbeAt(items: items, now: now)
        let expected = now.addingTimeInterval(WikiCacheSnapshot.errorTTL)
        #expect(abs(next.timeIntervalSince(expected)) < 0.001)
    }

    @Test("未知或空结果 → 未知 TTL = 6 小时")
    func testUnknownTTL() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let unknownItems = [makeItem(source: .codeWiki, status: .unknown("probing"))]
        for items in [unknownItems, []] {
            let next = WikiCacheSnapshot.computeNextProbeAt(items: items, now: now)
            let expected = now.addingTimeInterval(WikiCacheSnapshot.unknownTTL)
            #expect(abs(next.timeIntervalSince(expected)) < 0.001)
        }
    }

    @Test("freshness now < nextProbeAt = fresh,否则 stale")
    func testFreshness() {
        let now = Date()
        let fresh = WikiCacheSnapshot(
            owner: "a",
            repo: "b",
            probedAt: now,
            nextProbeAt: now.addingTimeInterval(60),
            items: []
        )
        #expect(fresh.freshness(at: now) == .fresh)

        let stale = WikiCacheSnapshot(
            owner: "a",
            repo: "b",
            probedAt: now.addingTimeInterval(-3600),
            nextProbeAt: now.addingTimeInterval(-60),
            items: []
        )
        #expect(stale.freshness(at: now) == .stale)
    }

    // MARK: - observable 派生量

    @Test("save / delete 之后 itemCount + totalBytes 同步更新")
    func testObservableCounters() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)

        try cache.save(snapshot: makeSnapshot(owner: "a", repo: "b"))
        try cache.save(snapshot: makeSnapshot(owner: "c", repo: "d"))
        #expect(cache.itemCount == 2)
        #expect(cache.totalBytes > 0)

        try cache.deleteEverything()
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
    }

    @Test("deleteEverything 删干净后再 save 仍能工作（cache 可重新初始化）")
    func testDeleteEverythingIdempotent() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }

        try cache.deleteEverything() // 空目录 delete 不抛
        try cache.save(snapshot: makeSnapshot(owner: "x", repo: "y"))
        #expect(cache.load(owner: "x", repo: "y") != nil)
    }

    // MARK: - Metadata 增量重建通知

    @Test("save 通知携带 owner/repo，供索引器精确重建 Metadata")
    func savePostsRepositoryIdentity() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let recorder = WikiCacheNotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .wikiCacheDidChange,
            object: cache,
            queue: nil
        ) { notification in
            recorder.recordChange(
                owner: notification.userInfo?["owner"] as? String,
                repo: notification.userInfo?["repo"] as? String
            )
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try cache.save(snapshot: makeSnapshot(owner: "octo", repo: "demo"))

        #expect(recorder.changedKey == WikiRepoKey(owner: "octo", repo: "demo"))
    }

    @Test("deleteEverything 通知保留清空前的全部仓库 identity")
    func deleteEverythingPostsAffectedRepositoryKeys() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        try cache.save(snapshot: makeSnapshot(owner: "octo", repo: "one"))
        try cache.save(snapshot: makeSnapshot(owner: "swiftlang", repo: "two"))

        let recorder = WikiCacheNotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .wikiCacheDidReset,
            object: cache,
            queue: nil
        ) { notification in
            recorder.recordReset(keys: notification.userInfo?["repositoryKeys"] as? [WikiRepoKey])
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try cache.deleteEverything()

        #expect(recorder.resetKeys == Set([
            WikiRepoKey(owner: "octo", repo: "one"),
            WikiRepoKey(owner: "swiftlang", repo: "two")
        ]))
    }
}

/// Sendable 测试记录器：只记录读盘线程，不参与生产路径。
private final class WikiReadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var observations: [Bool] {
        lock.withLock { values }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            values.append(isMainThread)
        }
    }
}

/// NotificationCenter 的回调没有 actor 隔离；通过锁记录 payload，避免测试本身产生数据竞争。
private final class WikiCacheNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedChangedKey: WikiRepoKey?
    private var storedResetKeys: Set<WikiRepoKey> = []

    var changedKey: WikiRepoKey? {
        lock.withLock { storedChangedKey }
    }

    var resetKeys: Set<WikiRepoKey> {
        lock.withLock { storedResetKeys }
    }

    func recordChange(owner: String?, repo: String?) {
        lock.withLock {
            guard let owner, let repo else { return }
            storedChangedKey = WikiRepoKey(owner: owner, repo: repo)
        }
    }

    func recordReset(keys: [WikiRepoKey]?) {
        lock.withLock {
            storedResetKeys = Set(keys ?? [])
        }
    }
}
