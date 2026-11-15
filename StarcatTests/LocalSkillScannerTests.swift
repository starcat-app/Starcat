//
//  LocalSkillScannerTests.swift
//  StarcatTests
//
//  扫描与索引对账的文件系统回归。夹具全部位于临时根，
//  通过真实目录、链接和权限验证边界，不扫描用户 Home。
//

import Darwin
import Foundation
import Testing
@testable import Starcat

/// 每个测试独占临时目录，权限测试在清理前恢复模式。
@Suite("Skill 本机受控扫描")
struct LocalSkillScannerTests {
    @Test("App Store 不能构造本机扫描器")
    func rejectsAppStore() {
        #expect(throws: DistributionGateError.self) {
            _ = try LocalSkillScanner(distributionGate: DistributionGate(channel: .appStore))
        }
    }

    @Test("同名不同物理副本不合并，重扫保留身份")
    func preservesDistinctCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("agents/one/foo", name: "foo")
        try fixture.skill("agents/two/foo", name: "foo")
        let root = fixture.scanRoot("agents")
        let store = try fixture.store()
        let report = try await scan([root], store: store)
        #expect(report.results.first?.coverage == .complete)
        #expect(try await store.apply(report))
        let before = try await store.snapshot()
        #expect(before.entries.count == 2)
        #expect(Set(before.entries.map(\.manifestName)) == ["foo"])
        let second = try await scan([root], store: store)
        #expect(try await store.apply(second))
        #expect(Set(try await store.snapshot().entries.map(\.id)) == Set(before.entries.map(\.id)))
        try await store.close()
    }

    @Test("多个链接入口折叠物理内容，保留每条词法位置")
    func reconcilesAliases() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("outside/foo", name: "foo")
        try fixture.directory("agents")
        for name in ["first", "second"] {
            try FileManager.default.createSymbolicLink(
                at: fixture.url("agents/\(name)"), withDestinationURL: fixture.url("outside/foo")
            )
        }
        let store = try fixture.store()
        let report = try await scan([fixture.scanRoot("agents")], store: store)
        #expect(report.results.first?.candidates.count == 2)
        #expect(try await store.apply(report))
        let snapshot = try await store.snapshot()
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.locations.count == 2)
        #expect(Set(snapshot.locations.map(\.resolvedPath)).count == 1)
        #expect(snapshot.locations.allSatisfy { $0.kind == .symbolicLink })
        try await store.close()
    }

    @Test("解析诊断保留候选，不把附件中的示例作为嵌套安装")
    func preservesInvalidManifestEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("agents/foo", name: "foo")
        try fixture.skill("agents/foo/references/example", name: "example")
        try fixture.directory("agents/broken")
        let original = Data("---\nname: broken\n---\n\nOriginal\n".utf8)
        try original.write(to: fixture.url("agents/broken/SKILL.md"))
        let store = try fixture.store()
        let report = try await scan([fixture.scanRoot("agents")], store: store)
        #expect(report.results.first?.coverage == .complete)
        #expect(report.results.first?.candidates.count == 2)
        #expect(report.results.first?.candidates.filter { $0.diagnostic != nil }.count == 1)
        #expect(try Data(contentsOf: fixture.url("agents/broken/SKILL.md")) == original)
        #expect(try await store.apply(report))
        #expect(try await store.snapshot().entries.count == 2)
        try await store.close()
    }

    @Test("预算截断不确认消失", arguments: [
        SkillScanLimits(maxDepth: 0), SkillScanLimits(maxDirectories: 1),
        SkillScanLimits(maxEntries: 1), SkillScanLimits(maxManifestBytes: 16)
    ])
    func preservesEntriesWhenTruncated(limits: SkillScanLimits) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("agents/one", name: "one")
        try fixture.skill("agents/two", name: "two")
        let store = try fixture.store()
        let root = fixture.scanRoot("agents")
        let full = try await scan([root], store: store)
        #expect(try await store.apply(full))
        let partial = try await scan([root], store: store, limits: limits)
        #expect(partial.results.first?.coverage == .partial)
        #expect(try await store.apply(partial))
        let snapshot = try await store.snapshot()
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.locations.allSatisfy { $0.scanState != .missing })
        #expect(snapshot.entries.allSatisfy { $0.summary == "Fixture description." })
        try await store.close()
    }

    @Test("权限失败根保留旧位置，正常根独立更新")
    func isolatesInaccessibleRoots() async throws {
        let fixture = try Fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.url("blocked").path)
            fixture.cleanup()
        }
        try fixture.skill("blocked/foo", name: "foo")
        try fixture.skill("healthy/bar", name: "bar")
        let blocked = fixture.scanRoot("blocked")
        let healthy = fixture.scanRoot("healthy")
        let store = try fixture.store()
        let before = try await scan([blocked, healthy], store: store)
        #expect(try await store.apply(before))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.url("blocked").path)
        try #require(access(fixture.url("blocked").path, R_OK) != 0)
        let after = try await scan([blocked, healthy], store: store)
        #expect(after.results.first { $0.root.id == blocked.id }?.coverage == .inaccessible)
        #expect(after.results.first { $0.root.id == healthy.id }?.coverage == .complete)
        #expect(try await store.apply(after))
        let locations = try await store.snapshot().locations
        #expect(locations.first { $0.rootID == blocked.id }?.scanState == .stale)
        #expect(locations.first { $0.rootID == healthy.id }?.scanState == .present)
        try await store.close()
    }

    @Test("缺失根与损坏链接区分，循环有界终止")
    func distinguishesMissingAndCycles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.directory("cycle")
        try FileManager.default.createSymbolicLink(
            at: fixture.url("cycle/self"), withDestinationURL: fixture.url("cycle")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.url("dangling"), withDestinationURL: fixture.url("absent-target")
        )
        let missing = fixture.scanRoot("missing")
        let dangling = fixture.scanRoot("dangling")
        let cycle = fixture.scanRoot("cycle")
        let store = try fixture.store()
        let report = try await scan([missing, dangling, cycle], store: store)
        #expect(report.results.first { $0.root.id == missing.id }?.coverage == .missing)
        #expect(report.results.first { $0.root.id == dangling.id }?.coverage == .unavailable)
        #expect(report.results.first { $0.root.id == cycle.id }?.coverage == .partial)
        #expect(report.results.first { $0.root.id == cycle.id }?.directoryCount == 2)
        try await store.close()
    }

    @Test("完整扫描确认消失但保留条目，重新出现沿用身份")
    func preservesMissingEntryIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("agents/foo", name: "foo")
        let root = fixture.scanRoot("agents")
        let store = try fixture.store()
        let initial = try await scan([root], store: store)
        #expect(try await store.apply(initial))
        let entryID = try #require(try await store.snapshot().entries.first?.id)
        try FileManager.default.removeItem(at: fixture.url("agents/foo"))
        let missing = try await scan([root], store: store)
        #expect(try await store.apply(missing))
        let absent = try await store.snapshot()
        #expect(absent.entries.first?.id == entryID)
        #expect(absent.locations.first?.scanState == .missing)
        try fixture.skill("agents/foo", name: "foo")
        let restored = try await scan([root], store: store)
        #expect(try await store.apply(restored))
        let present = try await store.snapshot()
        #expect(present.entries.first?.id == entryID)
        #expect(present.locations.first?.scanState == .present)
        try await store.close()
    }

    @Test("旧代次拒绝落库，取消不报告完整覆盖")
    func rejectsSupersededScans() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.skill("agents/foo", name: "foo")
        let root = fixture.scanRoot("agents")
        let store = try fixture.store()
        let old = try await scan([root], store: store)
        let generation = await store.beginScan()
        #expect(try await store.apply(old) == false)
        #expect(try await store.snapshot().entries.isEmpty)
        let scanner = try LocalSkillScanner(distributionGate: DistributionGate(channel: .direct))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.scan(SkillScanRequest(generationID: generation, roots: [root]))
        }
        let cancelled = await task.value
        #expect(cancelled.results.first?.coverage == .cancelled)
        #expect(try await store.apply(cancelled))
        #expect(try await store.snapshot().roots.first?.coverage == .cancelled)
        try await store.close()
    }

    @Test("环境覆盖与共享根复用现有目录表，根 ID 不随重建变化")
    func profilesPreserveRootIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let environment = [
            "CLAUDE_CONFIG_DIR": fixture.url("claude-config").path,
            "CODEX_HOME": fixture.url("codex-config").path
        ]
        let first = SkillAgentProfile.roots(
            home: fixture.base, environment: environment, detectedPresets: [.codex, .openCode],
            previous: [], managed: fixture.url("private-managed")
        )
        let shared = try #require(first.first { $0.configuredPath == fixture.url(".agents/skills").path })
        #expect(Set(shared.agentIDs) == [RepoSkillTargetPreset.codex.rawValue, RepoSkillTargetPreset.openCode.rawValue])
        #expect(first.contains { $0.configuredPath == fixture.url("claude-config/skills").path })
        #expect(first.contains { $0.configuredPath == fixture.url("codex-config/skills/.system").path })
        let second = SkillAgentProfile.roots(
            home: fixture.base, environment: environment, detectedPresets: [.codex, .openCode],
            previous: first, managed: fixture.url("private-managed")
        )
        #expect(second.map(\.id) == first.map(\.id))
    }

    private func scan(
        _ roots: [SkillLibraryRoot], store: SkillLibraryStore, limits: SkillScanLimits = SkillScanLimits()
    ) async throws -> SkillScanReport {
        let scanner = try LocalSkillScanner(distributionGate: DistributionGate(channel: .direct))
        return await scanner.scan(SkillScanRequest(
            generationID: await store.beginScan(), roots: roots, limits: limits
        ))
    }

    private struct Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SkillScannerTests-\(UUID())")

        init() throws {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }

        func url(_ path: String) -> URL { base.appendingPathComponent(path).standardizedFileURL }

        func directory(_ path: String) throws {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
        }

        func skill(_ path: String, name: String) throws {
            try directory(path)
            try Data("---\nname: \(name)\ndescription: Fixture description.\n---\n\nBody.\n".utf8)
                .write(to: url(path + "/SKILL.md"))
        }

        func scanRoot(_ path: String) -> SkillLibraryRoot {
            SkillLibraryRoot(configuredPath: url(path).path, agentIDs: ["fixture"], scope: .global)
        }

        func store() throws -> SkillLibraryStore {
            try SkillLibraryStore(
                distributionGate: DistributionGate(channel: .direct), paths: SkillLibraryPaths(root: url("library"))
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }
}
