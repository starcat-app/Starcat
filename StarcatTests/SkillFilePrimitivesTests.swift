//
//  SkillFilePrimitivesTests.swift
//  StarcatTests
//
//  用临时目录与 rename 故障注入验证文件集合、权限、同卷暂存和回滚现场。
//

import Foundation
import Testing
@testable import Starcat

struct SkillFilePrimitivesTests {
    @Test("完整指纹识别内容、隐藏附件、空目录与执行位，忽略 mtime")
    func completeFingerprint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let initial = try await SkillFilePrimitives.fingerprint(fixture.source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: fixture.source.path)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.source) == initial)
        try Data("changed".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
        let changed = try await SkillFilePrimitives.fingerprint(fixture.source)
        #expect(changed.digest != initial.digest)
        try Data("script".utf8).write(to: fixture.source.appendingPathComponent(".hidden"))
        let hidden = try await SkillFilePrimitives.fingerprint(fixture.source)
        #expect(hidden.digest != changed.digest)
        try FileManager.default.createDirectory(at: fixture.source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let directory = try await SkillFilePrimitives.fingerprint(fixture.source)
        #expect(directory.digest != hidden.digest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.source.appendingPathComponent(".hidden").path)
        let executable = try await SkillFilePrimitives.fingerprint(fixture.source)
        #expect(executable.digest != directory.digest)
        #expect(executable.members.contains { $0.path == "empty" && $0.kind == .directory })
    }

    @Test("符号链接与遍历预算阻断完整校验")
    func rejectsUnsupportedTree() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: SkillFileTransactionError.self) {
            try await SkillFilePrimitives.fingerprint(fixture.source, maximumBytes: 1)
        }
        await #expect(throws: SkillFileTransactionError.self) {
            try await SkillFilePrimitives.fingerprint(fixture.source, maximumEntries: 0)
        }
        let nested = fixture.source.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        await #expect(throws: SkillFileTransactionError.self) {
            try await SkillFilePrimitives.fingerprint(fixture.source, maximumDepth: 1)
        }
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("linked"), withDestinationURL: fixture.target
        )
        await #expect(throws: RepoSkillError.self) {
            try await SkillFilePrimitives.fingerprint(fixture.source)
        }
    }

    @Test("同父目录暂存保留源与文件权限")
    func stagePreservesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o751], ofItemAtPath: fixture.source.appendingPathComponent("SKILL.md").path
        )
        let expected = try await SkillFilePrimitives.fingerprint(fixture.source)
        let paths = SkillStagingPaths(parent: fixture.target)
        try await SkillFilePrimitives.stageCopy(from: fixture.source, expected: expected, paths: paths)
        #expect(try await SkillFilePrimitives.fingerprint(paths.payload) == expected)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.source) == expected)
        #expect(paths.stage.deletingLastPathComponent().path == fixture.target.path)
        #expect(paths.backup.deletingLastPathComponent().path == fixture.target.path)
    }

    @Test("预览后源变化不能通过暂存复核")
    func stalePlan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = try await SkillFilePrimitives.fingerprint(fixture.source)
        try Data("new".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
        await #expect(throws: RepoSkillError.self) {
            try await SkillFilePrimitives.stageCopy(
                from: fixture.source, expected: expected, paths: SkillStagingPaths(parent: fixture.target)
            )
        }
        #expect(!SkillFilePrimitives.exists(fixture.destination))
    }

    @Test("首次发布与替换分别保留明确结果和旧备份")
    func publishesAndKeepsBackup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.stage()
        #expect(try SkillFilePrimitives.publish(paths: first, destination: fixture.destination, replacing: false) == false)
        #expect(try fixture.text(fixture.destination) == "original")
        try Data("new".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
        let next = try await fixture.stage()
        #expect(try SkillFilePrimitives.publish(paths: next, destination: fixture.destination, replacing: true))
        #expect(try fixture.text(fixture.destination) == "new")
        #expect(try fixture.text(next.backup) == "original")
    }

    @Test("外部同名目标与断链都不能被默认覆盖")
    func refusesConflicts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try await fixture.stage()
        try FileManager.default.createSymbolicLink(
            at: fixture.destination, withDestinationURL: fixture.base.appendingPathComponent("missing")
        )
        #expect(throws: RepoSkillError.self) {
            try SkillFilePrimitives.publish(paths: paths, destination: fixture.destination, replacing: false)
        }
        #expect(SkillFilePrimitives.isSymbolicLink(fixture.destination))
        #expect(SkillFilePrimitives.exists(paths.payload))
    }

    @Test("发布 rename 失败恢复旧内容与权限")
    func rollsBack() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        let before = try await SkillFilePrimitives.fingerprint(fixture.destination)
        try Data("new".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
        let paths = try await fixture.stage()
        var moves = 0
        #expect(throws: InjectedFailure.self) {
            try SkillFilePrimitives.publish(paths: paths, destination: fixture.destination, replacing: true) { source, target in
                moves += 1
                if moves == 2 { throw InjectedFailure.rename }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
        #expect(moves == 3)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.destination) == before)
        #expect(!SkillFilePrimitives.exists(paths.backup))
    }

    @Test("回滚也失败时保留备份和新 payload 供恢复")
    func retainsRecoveryEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        let paths = try await fixture.stage()
        var moves = 0
        #expect(throws: SkillFileTransactionError.self) {
            try SkillFilePrimitives.publish(paths: paths, destination: fixture.destination, replacing: true) { source, target in
                moves += 1
                if moves >= 2 { throw InjectedFailure.rename }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
        #expect(try fixture.text(paths.backup) == "original")
        #expect(SkillFilePrimitives.exists(paths.payload))
        #expect(!SkillFilePrimitives.exists(fixture.destination))
    }

    @Test("不同父目录或已占用备份路径不进入 rename")
    func verifiesBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = try await fixture.stage()
        #expect(throws: SkillFileTransactionError.self) {
            try SkillFilePrimitives.publish(
                paths: paths, destination: fixture.base.appendingPathComponent("elsewhere/skill"), replacing: false
            )
        }
        try FileManager.default.createDirectory(at: paths.backup, withIntermediateDirectories: false)
        #expect(throws: SkillFileTransactionError.self) {
            try SkillFilePrimitives.publish(paths: paths, destination: fixture.destination, replacing: false)
        }
        #expect(SkillFilePrimitives.exists(paths.payload))
    }

    @Test("已取消的完整校验不会读取目录")
    func cancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SkillFilePrimitives.fingerprint(URL(fileURLWithPath: "/does-not-exist"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private enum InjectedFailure: Error { case rename }

    /// fixture 的所有写入都在同一个临时文件系统目录，失败后也由测试清理。
    private struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        var destination: URL { target.appendingPathComponent("sample", isDirectory: true) }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            source = base.appendingPathComponent("source", isDirectory: true)
            target = base.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        }

        func stage() async throws -> SkillStagingPaths {
            let paths = SkillStagingPaths(parent: target)
            let expected = try await SkillFilePrimitives.fingerprint(source)
            try await SkillFilePrimitives.stageCopy(from: source, expected: expected, paths: paths)
            return paths
        }

        func text(_ folder: URL) throws -> String {
            try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
