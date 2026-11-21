//
//  SmartCollectionPerformanceTests.swift
//  StarcatTests
//
//  覆盖 Smart Collections 一致性计数快照与进程内 SWR 缓存隔离。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Smart Collection performance")
struct SmartCollectionPerformanceTests {
    @Test("系统计数输入在同一快照中保留 starred、状态、知识库与未分类事实")
    func systemCountSnapshotKeepsConsistentFacts() async throws {
        let database = try InMemoryDatabaseManager()
        let starredFixture = makeRepo(id: 1, name: "starred", isStarred: true)
        let unstarredFixture = makeRepo(id: 2, name: "unstarred", isStarred: false)
        try await database.writer.write { db in
            var starred = starredFixture
            var unstarred = unstarredFixture
            try starred.save(db)
            try unstarred.save(db)
        }
        try await GRDBRepoNoteRepository(database: database).updateStatus(repoId: 1, status: .using)

        let snapshot = try await SmartCollectionSystemCountsLoader.load(database: database)

        #expect(snapshot.starredRepos.map(\.id) == [1])
        #expect(snapshot.statusByRepoID[1] == .using)
        #expect(snapshot.libraryStateByRepoID[1] == .inLibrary)
        #expect(snapshot.knowledgeCount == 1)
        #expect(snapshot.noTagsCount == 1)
    }

    @Test("SWR 计数缓存按账号和用户规则版本隔离")
    func countCacheSeparatesAccountAndRuleRevision() {
        let cache = SmartCollectionOverviewCountCache()
        let collection = makeCollection(updatedAt: "2026-09-05T10:00:00Z")
        cache.store(
            systemCounts: [.library: 3],
            userCounts: [collection.id: 2],
            accountID: 42,
            collections: [collection]
        )

        #expect(cache.snapshot(accountID: 42, collections: [collection])?.systemCounts[.library] == 3)
        #expect(cache.snapshot(accountID: 7, collections: [collection]) == nil)
        #expect(cache.snapshot(
            accountID: 42,
            collections: [makeCollection(updatedAt: "2026-09-05T11:00:00Z")]
        ) == nil)
    }

    /// 计数语义回归：`SmartCollectionSystemCountsLoader.counts(from:)` 从视图迁移到
    /// `@concurrent` 求值后，各系统集合的命中规则必须与既有一致。三个 fixture 分别
    /// 覆盖「在用·高分」「失修·库外」「高星·无 health」三类路径，固定基准日期
    /// 让 recentlyActive（≤30 天）/ unmaintained（>365 天）边界可断言。
    @Test("系统计数求值按快照事实命中各系统集合")
    func countsSnapshotProducesExpectedSystemCounts() async throws {
        let database = try InMemoryDatabaseManager()
        // 基准日约 2026-10-14；pushedAt 用与 matchesSmartCollection 相同的 shared formatter 生成，
        // 保证生成 → 解析格式对称（withInternetDateTime + fractionalSeconds）。
        let referenceDate = Date(timeIntervalSince1970: 1_792_000_000)
        let pushedBefore = { (days: Int) in
            ISO8601DateFormatter.shared.string(from: referenceDate.addingTimeInterval(Double(-days) * 86_400))
        }
        // repo 1：in_library note(.using)、health 80、stars 1500、topics/license 齐全、pushed 5 天前
        //   → library / using / highValue（有 health：stars>=1000 且 score>=75）/ recentlyActive
        let usingHighScore = makeRepo(
            id: 1,
            name: "using-high-score",
            isStarred: true,
            starsCount: 1_500,
            topics: "[\"swift\"]",
            license: "mit",
            pushedAt: pushedBefore(5)
        )
        // repo 2：无 note（默认 outsideLibrary）、health 50、topics/license 缺失、pushed 400 天前
        //   → outsideLibraryStars / needsReview / unmaintained
        let staleOutside = makeRepo(
            id: 2,
            name: "stale-outside",
            isStarred: true,
            starsCount: 200,
            topics: "[]",
            license: nil,
            pushedAt: pushedBefore(400)
        )
        // repo 3：无 note、无 health 快照、stars 6000、pushed 10 天前
        //   → outsideLibraryStars / highValue（无 health 的星数兜底路径）/ recentlyActive
        let highStarsNoHealth = makeRepo(
            id: 3,
            name: "high-stars-no-health",
            isStarred: true,
            starsCount: 6_000,
            topics: "[\"tools\"]",
            license: "mit",
            pushedAt: pushedBefore(10)
        )

        // health fixture 在 write 闭包外构造：套件是 @MainActor，而 GRDB write 闭包
        // 是 nonisolated 同步上下文，不能在闭包内调用 MainActor 隔离的实例方法；
        // 且 @Sendable 闭包只能捕获 let，mutating save 由闭包内副本承接。
        let healthHigh = makeHealth(repoId: 1, score: 80)
        let healthStale = makeHealth(repoId: 2, score: 50)
        try await database.writer.write { db in
            var repos = [usingHighScore, staleOutside, highStarsNoHealth]
            for index in repos.indices {
                try repos[index].save(db)
            }
            var highCopy = healthHigh
            try highCopy.save(db)
            var staleCopy = healthStale
            try staleCopy.save(db)
        }
        // updateStatus 建 note 行并默认 library_state = in_library（既有快照用例已验证该默认值）。
        try await GRDBRepoNoteRepository(database: database).updateStatus(repoId: 1, status: .using)

        let snapshot = try await SmartCollectionSystemCountsLoader.load(database: database)
        let counts = await SmartCollectionSystemCountsLoader.counts(from: snapshot, now: referenceDate)

        #expect(counts[.library] == 1)
        #expect(counts[.outsideLibraryStars] == 2)
        #expect(counts[.noTags] == 3)
        #expect(counts[.using] == 1)
        #expect(counts[.needsReview] == 1)
        #expect(counts[.unmaintained] == 1)
        #expect(counts[.highValue] == 2)
        #expect(counts[.recentlyActive] == 2)
    }

    private func makeCollection(updatedAt: String) -> UserSmartCollection {
        UserSmartCollection(
            id: "collection-1",
            name: "Swift",
            icon: "folder",
            color: nil,
            ruleJSON: "{}",
            sortOrder: 0,
            createdAt: "2026-09-05T10:00:00Z",
            updatedAt: updatedAt
        )
    }

    /// 计数语义用例的 repo fixture：在基础字段上叠加影响系统集合命中的字段。
    /// 默认值保持既有调用点行为不变（starsCount: 10、无 topics/license/pushedAt）。
    private func makeRepo(
        id: Int64,
        name: String,
        isStarred: Bool,
        starsCount: Int = 10,
        topics: String = "[]",
        license: String? = nil,
        pushedAt: String? = nil
    ) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: name,
            fullName: "owner/\(name)",
            description: "fixture",
            language: "Swift",
            starsCount: starsCount,
            forksCount: 1,
            watchersCount: 2,
            topics: topics,
            license: license,
            homepage: nil,
            htmlUrl: "https://github.com/owner/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: pushedAt,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    /// health fixture：只关心 `overallScore`（needsReview < 60 / highValue >= 75 阈值），
    /// 其余维度分与 payload 不参与计数判定，填同值占位即可。
    private func makeHealth(repoId: Int64, score: Double) -> RepoHealthSnapshot {
        RepoHealthSnapshot(
            repoId: repoId,
            overallScore: score,
            grade: score >= 75 ? "A" : "C",
            maintenanceScore: score,
            popularityScore: score,
            qualityScore: score,
            securityScore: score,
            payloadJSON: "{}",
            computedAt: "2026-10-14T00:00:00.000Z",
            staleAfter: "2027-10-14T00:00:00.000Z",
            fetchStatus: .success,
            lastError: nil
        )
    }
}
