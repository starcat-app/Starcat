//
//  SkillUpdateServiceTests.swift
//  StarcatTests
//
//  使用固定 Git 树与真实独立库验证更新证据，不请求远端或写入 Agent 目录。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Skill 更新发现")
struct SkillUpdateServiceTests {
    static let base = String(repeating: "a", count: 40)
    static let latest = String(repeating: "b", count: 40)

    @Test("同仓多 Skill 与并发检查共享 ref 和固定树请求")
    func aggregatesRequests() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one", "two"])
        let count = UpdateRequestCounter()
        let api = api()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            await count.hit("head")
            await Task.yield()
            return .init(sha: Self.latest, commit: .init(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, ref in
            await count.hit(ref)
            return .init(sha: ref, truncated: false, tree: Self.tree(changed: ref == Self.latest))
        }
        let service = try service(fixture, api)
        async let first: Void = service.check()
        async let second: Void = service.check()
        _ = try await (first, second)
        #expect(await count.value("head") == 1)
        #expect(await count.value(Self.base) == 1)
        #expect(await count.value(Self.latest) == 1)
        let checks = try await fixture.store.snapshot().updateChecks
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { $0.hasUpdate && $0.state == .available })
        try await service.check()
        #expect(await count.value("head") == 1)
    }

    @Test("仓库其他路径变化不表示 Skill 更新")
    func ignoresOtherChanges() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        let api = api()
        api.repositoryGitTreeHandler = { _, _, ref in
            .init(sha: ref, truncated: false, tree: Self.tree(changed: false) + [
                .init(path: "other.txt", mode: "100644", type: "blob", sha: ref, size: 1, url: nil)
            ])
        }
        try await service(fixture, api).check()
        #expect(try await fixture.store.snapshot().updateChecks.first?.state == .upToDate)
    }

    @Test("离线与重新打开保留之前已发现的更新证据")
    func preservesFailedEvidence() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        try await service(fixture, api()).check()
        let failed = api()
        failed.repositoryLatestCommitHandler = { _, _, _, _ in throw NetworkError.unauthorized }
        try await service(fixture, failed).check()
        let reopened = try SkillLibraryStore(distributionGate: DistributionGate(channel: .direct), paths: fixture.store.paths)
        let check = try #require(try await reopened.snapshot().updateChecks.first)
        #expect(check.state == .stale)
        #expect(check.hasUpdate)
        #expect(check.availableCommit == Self.latest)
        #expect(check.message != nil)
    }

    @Test("乱序失败不能覆盖数据库中已经发现的更新", arguments: [false, true])
    func preservesEvidenceAcrossOutOfOrderFailure(failureIsNewer: Bool) async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        let entry = try #require(try await fixture.store.snapshot().entries.first)
        let success = SkillUpdateCheck(
            entryID: entry.id, revisionID: entry.currentRevisionID, state: .available,
            hasUpdate: true, availableCommit: Self.latest, attemptedAt: 200, succeededAt: 220
        )
        // 模拟两个请求都从尚无更新证据的旧快照出发，失败响应在成功之后才落库。
        let failure = SkillUpdateCheck(
            entryID: entry.id, revisionID: entry.currentRevisionID, state: .unavailable,
            attemptedAt: failureIsNewer ? 300 : 100, message: "offline"
        )
        try await fixture.store.save(success)
        try await fixture.store.save(failure)
        let saved = try #require(try await fixture.store.snapshot().updateChecks.first)
        #expect(saved.hasUpdate)
        #expect(saved.availableCommit == Self.latest)
        #expect(saved.succeededAt == 220)
        #expect(saved.attemptedAt == (failureIsNewer ? 300 : 200))
        #expect(saved.state == (failureIsNewer ? .stale : .available))
        #expect(saved.message == (failureIsNewer ? "offline" : nil))
    }

    @Test("三次响应任意落库顺序保留最新尝试与最新成功证据", arguments: [false, true])
    func mergesAllResponseOrders(newerHasUpdate: Bool) async throws {
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            let fixture = try SkillOperationFixture()
            defer { fixture.remove() }
            try await entries(fixture.store, directories: ["one"])
            let entry = try #require(try await fixture.store.snapshot().entries.first)
            let responses = [
                SkillUpdateCheck(
                    entryID: entry.id, revisionID: entry.currentRevisionID, state: .available,
                    hasUpdate: true, availableCommit: Self.base, attemptedAt: 100, succeededAt: 400
                ),
                SkillUpdateCheck(
                    entryID: entry.id, revisionID: entry.currentRevisionID,
                    state: newerHasUpdate ? .available : .upToDate,
                    hasUpdate: newerHasUpdate, availableCommit: Self.latest, attemptedAt: 200, succeededAt: 250
                ),
                SkillUpdateCheck(
                    entryID: entry.id, revisionID: entry.currentRevisionID, state: .unavailable,
                    attemptedAt: 300, message: "latest attempt failed"
                )
            ]
            for index in order { try await fixture.store.save(responses[index]) }
            let reopened = try SkillLibraryStore(distributionGate: DistributionGate(channel: .direct), paths: fixture.store.paths)
            let saved = try #require(try await reopened.snapshot().updateChecks.first)
            #expect(saved.attemptedAt == 300)
            #expect(saved.evidenceAttemptedAt == 200)
            #expect(saved.succeededAt == 250)
            #expect(saved.availableCommit == Self.latest)
            #expect(saved.hasUpdate == newerHasUpdate)
            #expect(saved.state == (newerHasUpdate ? .stale : .unavailable))
            #expect(saved.message == "latest attempt failed")
        }
    }

    @Test("v4 独立库升级保留已知更新，后续请求使用准确证据顺序")
    func migratesExistingEvidence() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        let entry = try #require(try await fixture.store.snapshot().entries.first)
        try await fixture.store.save(SkillUpdateCheck(
            entryID: entry.id, revisionID: entry.currentRevisionID, state: .available,
            hasUpdate: true, availableCommit: Self.latest, attemptedAt: 200, succeededAt: 220
        ))
        try await fixture.store.close()
        // 只在临时数据库还原 v4 的真实列与迁移账本，验证追加迁移，不复制另一套建库 SQL。
        let db = try DatabaseQueue(path: fixture.store.paths.database.path)
        try await db.write {
            try $0.execute(sql: """
                ALTER TABLE skill_update_checks DROP COLUMN evidence_attempted_at;
                DELETE FROM grdb_migrations WHERE identifier = 'v5-skill-update-evidence';
                UPDATE skill_update_checks SET state = 'stale', attempted_at = 300, message = 'offline';
                """)
        }
        try db.close()
        let migrated = try #require(try await fixture.store.snapshot().updateChecks.first)
        #expect(migrated.hasUpdate && migrated.state == .stale)
        #expect(migrated.availableCommit == Self.latest)
        #expect(migrated.evidenceAttemptedAt == 220)
        try await fixture.store.save(SkillUpdateCheck(
            entryID: entry.id, revisionID: entry.currentRevisionID, state: .upToDate,
            availableCommit: Self.base, attemptedAt: 400, succeededAt: 450
        ))
        let refreshed = try #require(try await fixture.store.snapshot().updateChecks.first)
        #expect(!refreshed.hasUpdate && refreshed.state == .upToDate)
        #expect(refreshed.evidenceAttemptedAt == 400)
    }

    @Test("本地快照不冒充可自动检查来源")
    func marksUnsupported() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        #expect(try await fixture.coordinator().execute(fixture.plan()).isSuccess)
        try await service(fixture, api()).check()
        #expect(try await fixture.store.snapshot().updateChecks.first?.state == .unsupported)
    }

    @Test("检查期间安装基线变化，旧响应不会落库")
    func ignoresOldRevision() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        var entry = try #require(try await fixture.store.snapshot().entries.first)
        let stale = SkillUpdateCheck(entryID: entry.id, revisionID: entry.currentRevisionID, state: .available, hasUpdate: true)
        entry.currentRevisionID = UUID()
        try await fixture.store.save(entry)
        try await fixture.store.save(stale)
        #expect(try await fixture.store.snapshot().updateChecks.isEmpty)
    }

    @Test("授权变化不能发布本轮成功证据")
    func rejectsAuthorizationChange() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        let token = ImportTestToken()
        let api = api()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            await token.change()
            return .init(sha: Self.latest, commit: .init(committer: nil, author: nil))
        }
        try await service(fixture, api, token: token).check()
        let check = try #require(try await fixture.store.snapshot().updateChecks.first)
        #expect(check.state == .unavailable)
        #expect(!check.hasUpdate)
        #expect(check.availableCommit == nil)
    }

    @Test("限流冷却在同轮其他来源生效，不逐条继续请求")
    func respectsCooldown() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one", "two"])
        let count = UpdateRequestCounter()
        let api = api()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            await count.hit("head")
            throw NetworkError.rateLimited(retryAfter: 60)
        }
        try await service(fixture, api).check()
        #expect(await count.value("head") == 1)
        #expect(try await fixture.store.snapshot().updateChecks.allSatisfy { $0.state == .unavailable })
    }

    @Test("不完整、链接及子目录消失不清除已知更新", arguments: [0, 1, 2])
    func rejectsUnsafeTree(kind: Int) async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        try await service(fixture, api()).check()
        let api = api()
        api.repositoryGitTreeHandler = { _, _, ref in
            .init(sha: ref, truncated: false, tree: kind == 0 ? [] : [
                .init(path: "one/SKILL.md", mode: kind == 1 ? "120000" : "160000",
                      type: kind == 1 ? "blob" : "commit", sha: "x", size: 1, url: nil)
            ])
        }
        try await service(fixture, api).check()
        #expect(try await fixture.store.snapshot().updateChecks.first?.state == .stale)
        #expect(try await fixture.store.snapshot().updateChecks.first?.hasUpdate == true)
    }

    @Test("父仓库递归树截断时只读目标子树")
    func handlesTruncatedRoot() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        try await entries(fixture.store, directories: ["one"])
        let api = api()
        api.repositoryGitTreeHandler = { _, _, ref in
            if !ref.hasPrefix("subtree-") { return .init(sha: ref, truncated: true, tree: []) }
            return .init(sha: ref, truncated: false, tree: [
                .init(path: "SKILL.md", mode: "100644", type: "blob", sha: ref, size: 1, url: nil)
            ])
        }
        api.repositoryGitTreeLevelHandler = { _, _, ref in
            .init(sha: ref, truncated: false, tree: [
                .init(path: "one", mode: "040000", type: "tree", sha: "subtree-\(ref)", size: nil, url: nil)
            ])
        }
        try await service(fixture, api).check()
        #expect(try await fixture.store.snapshot().updateChecks.first?.state == .available)
    }

    @Test("App Store 不创建库或网络客户端")
    func rejectsAppStore() throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillUpdateService(store: fixture.store, distributionGate: DistributionGate(channel: .appStore))
        }
        #expect(!SkillFilePrimitives.exists(fixture.store.paths.database))
    }

    private func service(
        _ fixture: SkillOperationFixture, _ api: MockGitHubAPIClient, token: ImportTestToken = ImportTestToken()
    ) throws -> SkillUpdateService {
        try SkillUpdateService(
            store: fixture.store, distributionGate: DistributionGate(channel: .direct), tokenProvider: token,
            makeClients: { _ in SkillGitHubClients(api: api, downloader: ImportTestDownloader()) }
        )
    }

    private func api() -> MockGitHubAPIClient {
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            .init(sha: Self.latest, commit: .init(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, ref in
            .init(sha: ref, truncated: false, tree: Self.tree(changed: ref == Self.latest))
        }
        return api
    }

    private func entries(_ store: SkillLibraryStore, directories: [String]) async throws {
        for directory in directories {
            let source = SkillLibrarySource(kind: .github, canonicalLocator: "owner/repo", subdirectory: directory)
            var entry = SkillLibraryEntry(sourceID: source.id, manifestName: directory, summary: "", managementKind: .managed, trackingRef: "main")
            let revision = SkillLibraryRevision(entryID: entry.id, contentDigest: directory, manifestDigest: directory, upstreamCommit: Self.base)
            entry.currentRevisionID = revision.id
            try await store.save(source)
            try await store.save(entry)
            try await store.save(revision)
        }
    }

    private static func tree(changed: Bool) -> [GitHubGitTreeEntryDTO] {
        ["one", "two"].map {
            .init(path: "\($0)/SKILL.md", mode: "100644", type: "blob",
                  sha: changed ? latest : base, size: 1, url: nil)
        }
    }
}

/// Actor 计数器让并发请求合并测试不依赖非隔离可变闭包。
actor UpdateRequestCounter {
    private var values: [String: Int] = [:]
    func hit(_ key: String) { values[key, default: 0] += 1 }
    func value(_ key: String) -> Int { values[key, default: 0] }
}
