//
//  SkillLibraryDatabaseTests.swift
//  StarcatTests
//
//  独立本机库的真实 SQLite 回归。全部路径由测试创建，
//  不打开生产 Application Support 或任何实际 Agent 目录。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

/// 重开、唯一键和回执测试证明持久身份，不用内存模拟替代磁盘生命周期。
@Suite("Skill 独立本机库")
struct SkillLibraryDatabaseTests {
    @Test("App Store 在目录创建前拒绝内部库入口")
    func rejectsAppStoreWithoutSideEffects() throws {
        let root = temporaryRoot()
        #expect(throws: DistributionGateError.self) {
            _ = try SkillLibraryStore(
                distributionGate: DistributionGate(channel: .appStore),
                paths: SkillLibraryPaths(root: root)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Direct 构造保持惰性，首次读取才建库")
    func opensLazily() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let snapshot = try await store.snapshot()
        #expect(snapshot.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.paths.database.path))
        try await store.close()
    }

    @Test("同名不同来源重开后保持独立，位置与版本关联不丢失")
    func roundTripsIndependentIdentities() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)
        let source = SkillLibrarySource(kind: .github, canonicalLocator: "owner/one", subdirectory: "skills/foo")
        let otherSource = SkillLibrarySource(kind: .github, canonicalLocator: "owner/two", subdirectory: "skills/foo")
        try await store.save(source)
        try await store.save(otherSource)
        var entry = SkillLibraryEntry(
            sourceID: source.id, manifestName: "foo", summary: "first", managementKind: .managed
        )
        let other = SkillLibraryEntry(
            sourceID: otherSource.id, manifestName: "foo", summary: "second", managementKind: .external
        )
        try await store.save(entry)
        try await store.save(other)
        let revision = SkillLibraryRevision(
            entryID: entry.id, contentDigest: "content", manifestDigest: "manifest", upstreamCommit: "commit"
        )
        try await store.save(revision)
        entry.currentRevisionID = revision.id
        try await store.save(entry)
        let scanRoot = SkillLibraryRoot(
            configuredPath: root.appendingPathComponent("shared").path,
            agentIDs: ["codex", "opencode"], scope: .global
        )
        try await store.save(scanRoot)
        let location = SkillLibraryLocation(
            entryID: entry.id, rootID: scanRoot.id, lexicalPath: scanRoot.configuredPath + "/foo",
            resolvedPath: "/example/physical/foo", kind: .symbolicLink
        )
        try await store.save(location)
        try await store.close()

        let reopened = try makeStore(root)
        let snapshot = try await reopened.snapshot()
        #expect(Set(snapshot.entries.map(\.id)) == [entry.id, other.id])
        #expect(snapshot.revisions == [revision])
        #expect(snapshot.locations == [location])
        #expect(snapshot.roots == [scanRoot])
        #expect(snapshot.entries.first { $0.id == entry.id }?.currentRevisionID == revision.id)
        #expect(!reopened.paths.database.path.contains("/users/"))
        try await reopened.close()
    }

    @Test("来源唯一键拒绝相同来源重复身份，ref 不创建新来源")
    func enforcesSourceIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)
        var source = SkillLibrarySource(kind: .github, canonicalLocator: "owner/repo", subdirectory: "foo")
        try await store.save(source)
        source.defaultRef = "develop"
        try await store.save(source)
        let duplicate = SkillLibrarySource(kind: .github, canonicalLocator: "owner/repo", subdirectory: "foo")
        await #expect(throws: GRDB.DatabaseError.self) { try await store.save(duplicate) }
        #expect(try await store.snapshot().sources == [source])
        try await store.close()
    }

    @Test("主库登录、换账号与登出不改变本机库")
    func accountChangesPreserveLibrary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root.appendingPathComponent("skill-library"))
        let entry = SkillLibraryEntry(
            manifestName: "local-skill", summary: "local", managementKind: .external
        )
        try await store.save(entry)
        let accountDatabase = try DatabaseManager(
            userId: nil, basePathOverride: root.appendingPathComponent("accounts")
        )
        try await accountDatabase.reopen(userId: 101)
        try await accountDatabase.reopen(userId: 202)
        try await accountDatabase.reopen(userId: nil)
        #expect(try await store.snapshot().entries == [entry])
        try await store.close()
    }

    @Test("回执读取区分缺失、有效、外来和损坏")
    func readsReceiptsWithoutGrantingOwnership() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)
        let entryID = UUID()
        #expect(try await store.receipt(for: entryID) == nil)
        let directory = store.paths.entryDirectory(entryID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("receipt.json")
        let fingerprint = SkillDirectoryFingerprint(digest: "digest", rootMode: 0o755, members: [])
        let receipt = SkillLibraryReceipt(
            entryID: entryID, revisionID: UUID(), contentDigest: "digest", installedAt: 123, fingerprint: fingerprint
        )
        try JSONEncoder().encode(receipt).write(to: url)
        #expect(try await store.receipt(for: entryID) == receipt)
        let foreign = SkillLibraryReceipt(
            entryID: UUID(), revisionID: UUID(), contentDigest: "digest", installedAt: 123, fingerprint: fingerprint
        )
        try JSONEncoder().encode(foreign).write(to: url)
        await #expect(throws: CocoaError.self) { try await store.receipt(for: entryID) }
        try Data("invalid".utf8).write(to: url)
        await #expect(throws: DecodingError.self) { try await store.receipt(for: entryID) }
    }

    private func makeStore(_ root: URL) throws -> SkillLibraryStore {
        try SkillLibraryStore(
            distributionGate: DistributionGate(channel: .direct), paths: SkillLibraryPaths(root: root)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SkillLibraryTests-\(UUID().uuidString)")
    }
}
