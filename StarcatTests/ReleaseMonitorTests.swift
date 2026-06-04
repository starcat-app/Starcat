//
//  ReleaseMonitorTests.swift
//  StarcatTests
//
//  HOM-47：ReleaseMonitor 单测。
//
//  覆盖：
//  - 首次轮询：cursor=nil → 不计为新（priming 已在订阅时完成）
//  - 第二次轮询：cursor 之后的 release 全部计为新，notifyEnabled=true 才进 notifications
//  - notifyEnabled=false：仍写库 + 推进 cursor，但 notifications 空
//  - 单 repo 失败不打断整体（404 / 网络错误均不抛 + 推进 lastPolledAt）
//  - 数据一致性：游标推进后再轮询，相同 release 不会被重复识别为新
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("ReleaseMonitor")
struct ReleaseMonitorTests {

    // MARK: - 工具：搭一套 in-memory 全栈

    @MainActor
    private struct Stack {
        let mock: MockGitHubAPIClient
        let monitor: ReleaseMonitor
        let releaseRepo: GRDBReleaseRepository
        let subRepo: GRDBReleaseSubscriptionRepository
        let repoRepo: GRDBRepoRepository
        let db: any DatabaseManaging
    }

    @MainActor
    private func makeStack() throws -> Stack {
        let db = try InMemoryDatabaseManager()
        let mock = MockGitHubAPIClient()
        let releaseRepo = GRDBReleaseRepository(database: db)
        let subRepo = GRDBReleaseSubscriptionRepository(database: db)
        let repoRepo = GRDBRepoRepository(database: db)
        let monitor = ReleaseMonitor(
            apiClient: mock,
            subscriptionRepo: subRepo,
            releaseRepo: releaseRepo,
            repoRepo: repoRepo,
            perPage: 10
        )
        return Stack(
            mock: mock,
            monitor: monitor,
            releaseRepo: releaseRepo,
            subRepo: subRepo,
            repoRepo: repoRepo,
            db: db
        )
    }

    /// 构造一组 GitHub Releases DTO（默认 desc 排），便于覆盖游标递进逻辑。
    private func makeDTOs(ids: [Int64]) -> [GitHubReleaseDTO] {
        ids.map { id in
            GitHubReleaseDTO(
                id: id,
                tagName: "v\(id)",
                name: "Release v\(id)",
                body: nil,
                htmlUrl: "https://x/y/releases/tag/v\(id)",
                prerelease: false,
                draft: false,
                publishedAt: "2026-06-\(String(format: "%02d", id))T00:00:00Z",
                createdAt: "2026-06-\(String(format: "%02d", id))T00:00:00Z",
                assets: nil
            )
        }
    }

    private func okResponse<T>(_ value: T) -> APIResponse<T> {
        APIResponse(
            value: value,
            linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
            rateLimit: .empty,
            statusCode: 200,
            etag: nil
        )
    }

    // MARK: - 测试

    @Test("首次轮询：cursor 已 priming 至最新 → 无新 Release，不发通知")
    @MainActor
    func firstPollWithPrimingFindsNoNew() async throws {
        let s = try makeStack()
        try await s.db.insertRepoFixture(id: 42)
        // 订阅时 priming 到最新 id=3
        try await s.subRepo.subscribe(repoId: 42, primingReleaseId: 3, primingTagName: "v3")

        s.mock.releasesHandler = { _, _, _ in
            self.okResponse(self.makeDTOs(ids: [3, 2, 1]))
        }

        let report = await s.monitor.runOnce()
        #expect(report.hasNewReleases == false)
        #expect(report.notifications.isEmpty)
        #expect(s.mock.releasesCalls.count == 1)
        // 入库：3 条历史 release 已 upsert
        let stored = try await s.releaseRepo.fetch(forRepo: 42, limit: 50)
        #expect(stored.count == 3)
    }

    @Test("第二次轮询：cursor 之后新增 → notifications 命中且 notify_enabled=true")
    @MainActor
    func secondPollDetectsNewWithNotify() async throws {
        let s = try makeStack()
        try await s.db.insertRepoFixture(id: 42)
        try await s.subRepo.subscribe(repoId: 42, primingReleaseId: 3, primingTagName: "v3")

        // 先模拟一次空闲轮询不变：cursor 仍是 3
        s.mock.releasesHandler = { _, _, _ in
            self.okResponse(self.makeDTOs(ids: [5, 4, 3, 2, 1]))
        }

        let report = await s.monitor.runOnce()
        #expect(report.newReleasesByRepo[42] == 2) // id 4 + 5
        #expect(report.notifications.count == 2)
        #expect(report.notifications.map(\.release.id).sorted() == [4, 5])

        // 游标推进：再轮询一次，无新增
        let report2 = await s.monitor.runOnce()
        #expect(report2.hasNewReleases == false)
        #expect(report2.notifications.isEmpty)

        let updated = try #require(try await s.subRepo.find(repoId: 42))
        #expect(updated.lastKnownReleaseId == 5)
        #expect(updated.lastKnownTagName == "v5")
    }

    @Test("notifyEnabled=false：仍识别新 Release + 入库，但 notifications 空")
    @MainActor
    func newButSilent() async throws {
        let s = try makeStack()
        try await s.db.insertRepoFixture(id: 42)
        try await s.subRepo.subscribe(repoId: 42, primingReleaseId: 1, primingTagName: "v1")
        try await s.subRepo.setNotifyEnabled(repoId: 42, enabled: false)

        s.mock.releasesHandler = { _, _, _ in
            self.okResponse(self.makeDTOs(ids: [3, 2, 1]))
        }

        let report = await s.monitor.runOnce()
        #expect(report.newReleasesByRepo[42] == 2) // 计数仍统计
        #expect(report.notifications.isEmpty) // 但不进通知队列
    }

    @Test("404：仓库无 release → 不抛错 + 推进 lastPolledAt")
    @MainActor
    func notFoundDoesNotBreakLoop() async throws {
        let s = try makeStack()
        try await s.db.insertRepoFixture(id: 42)
        try await s.subRepo.subscribe(repoId: 42, primingReleaseId: nil, primingTagName: nil)

        s.mock.releasesHandler = { _, _, _ in
            throw NetworkError.notFound
        }

        let report = await s.monitor.runOnce()
        #expect(report.hasNewReleases == false)
        #expect(report.perRepoErrors.isEmpty) // 404 是合法状态，不计为错误

        let sub = try #require(try await s.subRepo.find(repoId: 42))
        #expect(sub.lastPolledAt != nil)
    }

    @Test("单 repo 抛错：errors 记录，但其他 repo 仍继续巡检")
    @MainActor
    func errorOnOneRepoDoesNotStop() async throws {
        let s = try makeStack()
        try await s.db.insertRepoFixture(id: 1)
        try await s.db.insertRepoFixture(id: 2)
        try await s.subRepo.subscribe(repoId: 1, primingReleaseId: 1, primingTagName: "v1")
        try await s.subRepo.subscribe(repoId: 2, primingReleaseId: 1, primingTagName: "v1")

        s.mock.releasesHandler = { owner, repoName, _ in
            // repo 1（owner=octo, name=demo-1）失败；repo 2 成功
            if repoName == "demo-1" {
                throw URLError(.timedOut)
            }
            return self.okResponse(self.makeDTOs(ids: [3, 2, 1]))
        }

        let report = await s.monitor.runOnce()
        #expect(report.perRepoErrors.keys.contains(1))
        // repo 2 走完整流程
        #expect(report.newReleasesByRepo[2] == 2)
        #expect(s.mock.releasesCalls.count == 2)
    }

    @Test("订阅指向不存在的 repo：跳过本次，不抛错")
    @MainActor
    func missingRepoSkipped() async throws {
        let s = try makeStack()
        // 没插 repos.id=999；直接手工写 release_subscriptions 行（绕开外键）
        // 实际生产中外键 ON DELETE CASCADE 会删掉订阅，这里只是测兜底分支
        try await s.db.writer.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
        }
        defer {
            // 测试结束恢复，避免影响其他 suite
            // 注意：InMemoryDatabaseManager 每次 makeStack 都新建，无需手动恢复
        }
        try await s.db.insertRepoFixture(id: 1)
        try await s.subRepo.subscribe(repoId: 1, primingReleaseId: 1, primingTagName: "v1")

        // 删 repos.id=1 但 subscriptions 行仍在（模拟数据不一致）
        try await s.db.writer.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE id = 1")
        }

        s.mock.releasesHandler = { _, _, _ in
            self.okResponse(self.makeDTOs(ids: [2, 1]))
        }

        let report = await s.monitor.runOnce()
        // missing repo → scanRepo 返回 (0, []) → 不计错误
        #expect(report.perRepoErrors.isEmpty)
        #expect(report.hasNewReleases == false)
    }
}
