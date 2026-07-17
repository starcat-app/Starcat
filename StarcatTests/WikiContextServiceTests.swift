//
//  WikiContextServiceTests.swift
//  StarcatTests
//
//  覆盖 WikiContextService SWR 编排（2026-06-15 v4.y）：
//    - cachedLinks miss → 空数组；cached hit → 派生的 [WikiLink]
//    - refresh 同步阻塞版：调 fetcher + 写盘 + 返回 indexedLinks
//    - refreshInBackground 触发后写盘成功（用 polling 等待 Task 完成）
//    - 并发去重：同一 (owner, repo) 多次 refreshInBackground 只调一次 fetcher
//    - fetcher 抛错时静默吞，cache 仍为空
//

import Foundation
import Testing
@testable import Starcat

/// 测试用 stub fetcher，可控制返回 items + 抛错 + 调用计数。
private final class StubWikiFetcher: WikiStatusFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [WikiStatusItem]
    private var _shouldThrow: Bool
    private(set) var callCount: Int = 0
    /// 模拟网络延迟（让并发去重路径有机会真的去重）。
    private let delay: TimeInterval

    init(items: [WikiStatusItem] = [], shouldThrow: Bool = false, delay: TimeInterval = 0.05) {
        self._items = items
        self._shouldThrow = shouldThrow
        self.delay = delay
    }

    func setItems(_ items: [WikiStatusItem]) {
        lock.withLock {
            _items = items
        }
    }

    func fetchStatus(owner: String, repo: String) async throws -> [WikiStatusItem] {
        let snapshot = lock.withLock {
            callCount += 1
            return (items: _items, shouldThrow: _shouldThrow)
        }

        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        if snapshot.shouldThrow {
            throw URLError(.notConnectedToInternet)
        }
        return snapshot.items
    }
}

@MainActor
@Suite("WikiContextService")
struct WikiContextServiceTests {

    private func makeIsolatedCache() -> (cache: DiskWikiCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-wiki-svc-test-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskWikiCache(rootOverride: root)
        return (cache, root)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeItem(source: WikiSource, status: WikiProbeStatus, url: String) -> WikiStatusItem {
        WikiStatusItem(
            source: source,
            status: status,
            url: URL(string: url)!,
            probeMethod: "GET",
            httpStatus: status == .indexed ? 200 : 404,
            matchedSignals: nil
        )
    }

    // MARK: - cachedLinks

    @Test("cachedLinks miss 返回空数组")
    func testCachedLinksMiss() {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let svc = WikiContextService(cache: cache, fetcher: StubWikiFetcher())

        #expect(svc.cachedLinks(owner: "no", repo: "such").isEmpty)
    }

    @Test("cachedLinks hit 返回 [WikiLink]（fresh / stale 都用）")
    func testCachedLinksHit() throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/b"),
            makeItem(source: .zread, status: .notIndexed, url: "https://zread.com/a/b")
        ]
        let snapshot = WikiCacheSnapshot(
            owner: "a",
            repo: "b",
            probedAt: Date(),
            nextProbeAt: WikiCacheSnapshot.computeNextProbeAt(items: items),
            items: items
        )
        try cache.save(snapshot: snapshot)
        let svc = WikiContextService(cache: cache, fetcher: StubWikiFetcher())

        let links = svc.cachedLinks(owner: "a", repo: "b")
        #expect(links.count == 1)
        #expect(links.first?.source == .deepWiki)
    }

    @Test("cache-first fresh 不发网络，stale 与 miss 进入后台队列")
    func testCacheFirstFreshnessRouting() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/b")]
        try cache.save(snapshot: WikiCacheSnapshot(
            owner: "fresh",
            repo: "repo",
            probedAt: Date(),
            nextProbeAt: Date().addingTimeInterval(60),
            items: items
        ))
        try cache.save(snapshot: WikiCacheSnapshot(
            owner: "stale",
            repo: "repo",
            probedAt: Date().addingTimeInterval(-120),
            nextProbeAt: Date().addingTimeInterval(-60),
            items: items
        ))
        let fetcher = StubWikiFetcher(items: items, delay: 0.01)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        #expect(svc.cacheFirstLinks(owner: "fresh", repo: "repo", isPrivate: false).count == 1)
        #expect(svc.cacheFirstLinks(owner: "stale", repo: "repo", isPrivate: false).count == 1)
        #expect(svc.cacheFirstLinks(owner: "miss", repo: "repo", isPrivate: false).isEmpty)
        try await pollUntil(timeoutMs: 2000) { fetcher.callCount == 2 }
        #expect(fetcher.callCount == 2)
    }

    @Test("私有仓库不读出外部链接也不发网络")
    func testPrivateRepositoryNeverRefreshes() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let fetcher = StubWikiFetcher(delay: 0)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        #expect(svc.cacheFirstLinks(owner: "private", repo: "repo", isPrivate: true).isEmpty)
        svc.refreshInBackground(owner: "private", repo: "repo", isPrivate: true)
        #expect(try await svc.refresh(owner: "private", repo: "repo", isPrivate: true).isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fetcher.callCount == 0)
    }

    @Test("后台队列限制最大并发并对排队请求去重")
    func testBoundedQueueAndPendingDeduplication() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/b")]
        let fetcher = StubWikiFetcher(items: items, delay: 0.1)
        let svc = WikiContextService(cache: cache, fetcher: fetcher, maximumConcurrentRefreshes: 1)

        svc.refreshInBackground(owner: "a", repo: "one")
        svc.refreshInBackground(owner: "a", repo: "two")
        svc.refreshInBackground(owner: "a", repo: "two")
        try await pollUntil(timeoutMs: 3000) {
            svc.cachedSnapshot(owner: "a", repo: "two") != nil
        }
        #expect(fetcher.callCount == 2)
    }

    @Test("后台补齐启动扫描跳过 fresh 与私有仓库")
    func testKnowledgeBackfillStartupScan() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/miss")]
        try cache.save(snapshot: WikiCacheSnapshot(
            owner: "a",
            repo: "fresh",
            probedAt: Date(),
            nextProbeAt: Date().addingTimeInterval(60),
            items: items
        ))
        let fetcher = StubWikiFetcher(items: items, delay: 0.01)
        let service = WikiContextService(cache: cache, fetcher: fetcher, maximumConcurrentRefreshes: 1)
        let repos = [
            makeRepo(id: 1, owner: "a", name: "fresh"),
            makeRepo(id: 2, owner: "a", name: "miss"),
            makeRepo(id: 3, owner: "secret", name: "private", isPrivate: true)
        ]
        let coordinator = WikiKnowledgeBackfillCoordinator(
            wikiContextService: service,
            fetchKnowledgeRepos: { repos },
            findRepo: { id in repos.first { $0.id == id } }
        )

        coordinator.start()
        try await pollUntil(timeoutMs: 2000) {
            service.cachedSnapshot(owner: "a", repo: "miss") != nil
        }
        #expect(fetcher.callCount == 1)
        #expect(service.cachedSnapshot(owner: "secret", repo: "private") == nil)
        await coordinator.suspendForUserDatabaseChange()
    }

    @Test("后台补齐切库会取消旧 generation 写盘")
    func testKnowledgeBackfillCancellationPreventsOldWrite() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/old/repo")]
        let fetcher = StubWikiFetcher(items: items, delay: 0.4)
        let service = WikiContextService(cache: cache, fetcher: fetcher)
        let repo = makeRepo(id: 1, owner: "old", name: "repo")
        let coordinator = WikiKnowledgeBackfillCoordinator(
            wikiContextService: service,
            fetchKnowledgeRepos: { [repo] },
            findRepo: { _ in repo }
        )

        coordinator.start()
        try await pollUntil(timeoutMs: 1000) { fetcher.callCount == 1 }
        await coordinator.suspendForUserDatabaseChange()
        try await Task.sleep(for: .milliseconds(450))
        #expect(service.cachedSnapshot(owner: "old", repo: "repo") == nil)
    }

    @Test("仓库新加入知识库后通过通知进入统一补齐队列")
    func testKnowledgeBackfillEnqueuesNewLibraryRepository() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(
            source: .deepWiki,
            status: .indexed,
            url: "https://deepwiki.com/new/repo"
        )]
        let fetcher = StubWikiFetcher(items: items, delay: 0.01)
        let service = WikiContextService(cache: cache, fetcher: fetcher)
        let repo = makeRepo(id: 77, owner: "new", name: "repo")
        let coordinator = WikiKnowledgeBackfillCoordinator(
            wikiContextService: service,
            fetchKnowledgeRepos: { [] },
            findRepo: { id in id == repo.id ? repo : nil }
        )

        coordinator.start()
        // 先让 AsyncSequence 完成 observer 注册，避免测试把通知发在监听任务启动之前。
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        NotificationCenter.default.post(
            name: .repoLibraryStateDidChange,
            object: nil,
            userInfo: [
                "repoId": repo.id,
                "libraryState": LibraryState.inLibrary.rawValue
            ]
        )

        try await pollUntil(timeoutMs: 2000) {
            service.cachedSnapshot(owner: repo.owner, repo: repo.name) != nil
        }
        #expect(fetcher.callCount == 1)
        await coordinator.suspendForUserDatabaseChange()
    }

    // MARK: - refresh 同步路径

    @Test("refresh 调 fetcher + 写盘 + 返回 indexedLinks")
    func testRefreshHappyPath() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/x/y"),
            makeItem(source: .zread, status: .indexed, url: "https://zread.com/x/y")
        ]
        let fetcher = StubWikiFetcher(items: items, delay: 0)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        let links = try await svc.refresh(owner: "x", repo: "y")
        #expect(fetcher.callCount == 1)
        #expect(links.count == 2)
        // 写盘已生效，下次 cachedLinks 立刻命中
        #expect(svc.cachedLinks(owner: "x", repo: "y").count == 2)
    }

    @Test("refresh 抛错时不写盘且把错误传出去")
    func testRefreshPropagatesError() async {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let fetcher = StubWikiFetcher(shouldThrow: true, delay: 0)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        await #expect(throws: Error.self) {
            _ = try await svc.refresh(owner: "x", repo: "y")
        }
        #expect(svc.cachedLinks(owner: "x", repo: "y").isEmpty)
    }

    // MARK: - refreshInBackground

    @Test("refreshInBackground 完成后 cache 命中新结果")
    func testRefreshInBackgroundWritesCache() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [
            makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/bg/test")
        ]
        let fetcher = StubWikiFetcher(items: items, delay: 0.01)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        svc.refreshInBackground(owner: "bg", repo: "test")

        // 轮询等 task 完成（最多 2s）。生产代码 fire-and-forget,
        // 测试里用 polling 而不暴露 Task 句柄,保持 API 表面干净。
        try await pollUntil(timeoutMs: 2000) {
            svc.cachedLinks(owner: "bg", repo: "test").count == 1
        }
        #expect(svc.cachedLinks(owner: "bg", repo: "test").count == 1)
    }

    @Test("refreshInBackground 抛错时静默吞,cache 保持空")
    func testRefreshInBackgroundSwallowsError() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let fetcher = StubWikiFetcher(shouldThrow: true, delay: 0.01)
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        svc.refreshInBackground(owner: "fail", repo: "test")
        // 等一段时间让 task 跑完
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(svc.cachedLinks(owner: "fail", repo: "test").isEmpty)
    }

    @Test("并发去重：同一 (owner,repo) 多次触发 refreshInBackground 只调一次 fetcher")
    func testInFlightDeduplication() async throws {
        let (cache, root) = makeIsolatedCache()
        defer { cleanup(root) }
        let items = [makeItem(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/d/e")]
        let fetcher = StubWikiFetcher(items: items, delay: 0.1) // 100ms 延迟,留出去重窗口
        let svc = WikiContextService(cache: cache, fetcher: fetcher)

        // 在 fetcher 还在 sleep 时连续触发 5 次
        for _ in 0..<5 {
            svc.refreshInBackground(owner: "d", repo: "e")
        }
        // 等首轮 task 完成
        try await pollUntil(timeoutMs: 2000) {
            svc.cachedLinks(owner: "d", repo: "e").count == 1
        }
        #expect(fetcher.callCount == 1, "5 次触发只算 1 次 fetcher 调用")
    }

    // MARK: - helpers

    /// 轮询直到 condition 返回 true 或超时（每 20 ms 检查一次）。
    private func pollUntil(timeoutMs: Int, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeRepo(
        id: Int64,
        owner: String,
        name: String,
        isPrivate: Bool = false
    ) -> Repo {
        Repo(
            id: id,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
