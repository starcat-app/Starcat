//
//  SkillUpdateServiceTests.swift
//  StarcatTests
//
//  使用固定 Git 树与真实独立库验证更新证据，不请求远端或写入 Agent 目录。
//

import Foundation
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
