//
//  RepoIssuesSharedStoreTests.swift
//  StarcatTests
//
//  Issues 共享缓存：首屏 / 计数读写、TTL 过期标记、owner/repo 大小写归一、
//  超限 LRU 淘汰。VM 侧 SWR 行为见 RepoIssuesViewModelTests。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoIssuesSharedStore")
struct RepoIssuesSharedStoreTests {

    private func makeIssue(id: Int64, number: Int) -> GitHubRepoIssue {
        GitHubRepoIssue(
            id: id,
            number: number,
            title: "issue \(number)",
            state: .open,
            body: nil,
            htmlURL: URL(string: "https://github.com/starcat-app/Starcat/issues/\(number)")!,
            authorLogin: nil,
            labels: [],
            commentsCount: 0,
            createdAt: nil,
            updatedAt: nil,
            closedAt: nil
        )
    }

    @Test("首屏快照写入后可读回，未过期不带 stale 标记")
    func pageRoundTripFresh() async {
        let store = RepoIssuesSharedStore()
        let snapshot = RepoIssuesPageSnapshot(
            issues: [makeIssue(id: 1, number: 7)],
            nextPage: 2,
            fetchedAt: Date()
        )
        await store.storePage(snapshot, owner: "starcat-app", repo: "Starcat", state: .open)

        let hit = await store.page(owner: "starcat-app", repo: "Starcat", state: .open)
        #expect(hit?.value == snapshot)
        #expect(hit?.isStale == false)
    }

    @Test("TTL 归零时命中带 stale 标记（调用方据此后台校准）")
    func pageStaleAfterTTL() async {
        let store = RepoIssuesSharedStore(timeToLive: 0)
        let snapshot = RepoIssuesPageSnapshot(issues: [], nextPage: nil, fetchedAt: Date())
        await store.storePage(snapshot, owner: "starcat-app", repo: "Starcat", state: .closed)

        let hit = await store.page(owner: "starcat-app", repo: "Starcat", state: .closed)
        #expect(hit?.value == snapshot)
        #expect(hit?.isStale == true)
    }

    @Test("未写入的状态返回 nil，不误命中其它状态")
    func pageMissReturnsNil() async {
        let store = RepoIssuesSharedStore()
        let snapshot = RepoIssuesPageSnapshot(issues: [], nextPage: nil, fetchedAt: Date())
        await store.storePage(snapshot, owner: "starcat-app", repo: "Starcat", state: .open)

        let closedHit = await store.page(owner: "starcat-app", repo: "Starcat", state: .closed)
        #expect(closedHit == nil)
    }

    @Test("owner/repo 大小写不敏感，同一仓库只算一份缓存")
    func repoKeyIsCaseInsensitive() async {
        let store = RepoIssuesSharedStore()
        let counts = RepoIssuesCountSnapshot(openCount: 3, closedCount: 9, fetchedAt: Date())
        await store.storeCounts(counts, owner: "Starcat-App", repo: "STARCAT")

        let hit = await store.counts(owner: "starcat-app", repo: "starcat")
        #expect(hit?.value == counts)
    }

    @Test("计数快照写入后可读回")
    func countsRoundTrip() async {
        let store = RepoIssuesSharedStore()
        let counts = RepoIssuesCountSnapshot(openCount: 12, closedCount: 38, fetchedAt: Date())
        await store.storeCounts(counts, owner: "starcat-app", repo: "Starcat")

        let hit = await store.counts(owner: "starcat-app", repo: "Starcat")
        #expect(hit?.value == counts)
        #expect(hit?.isStale == false)
    }

    @Test("超过仓库上限时淘汰最久未触碰仓库的全部条目")
    func evictsLeastRecentlyTouchedRepo() async {
        let store = RepoIssuesSharedStore(maxRepos: 2)

        await store.storeCounts(
            RepoIssuesCountSnapshot(openCount: 1, closedCount: 1, fetchedAt: Date()),
            owner: "a", repo: "one"
        )
        try? await Task.sleep(nanoseconds: 5_000_000)
        await store.storeCounts(
            RepoIssuesCountSnapshot(openCount: 2, closedCount: 2, fetchedAt: Date()),
            owner: "b", repo: "two"
        )
        try? await Task.sleep(nanoseconds: 5_000_000)
        await store.storeCounts(
            RepoIssuesCountSnapshot(openCount: 3, closedCount: 3, fetchedAt: Date()),
            owner: "c", repo: "three"
        )

        // a 最久未触碰 → 计数与首屏一并淘汰；b / c 保留。
        let aCounts = await store.counts(owner: "a", repo: "one")
        let bCounts = await store.counts(owner: "b", repo: "two")
        let cCounts = await store.counts(owner: "c", repo: "three")
        #expect(aCounts == nil)
        #expect(bCounts != nil)
        #expect(cCounts != nil)

        await store.storePage(
            RepoIssuesPageSnapshot(issues: [], nextPage: nil, fetchedAt: Date()),
            owner: "a", repo: "one", state: .open
        )
        let aPage = await store.page(owner: "a", repo: "one", state: .open)
        #expect(aPage != nil)
    }
}
