//
//  SkillBatchUpdateTests.swift
//  StarcatTests
//
//  批量测试观察真实文件与每项结果，确保失败和取消不掩盖部分成功。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 批量安全更新")
struct SkillBatchUpdateTests {
    @Test("成功、修改保护与无效条目分别保留，重复选择只执行一次")
    func preservesPartialResults() async throws {
        let fixture = try BatchUpdateFixture()
        defer { fixture.base.remove() }
        let good = try await fixture.add("good")
        let modified = try await fixture.add("modified")
        try fixture.write("remote", at: good.source)
        try fixture.write("remote", at: modified.source)
        try fixture.write("local", at: fixture.content(modified.id))
        let rows = try await fixture.batch.prepare(entryIDs: [good.id, modified.id, UUID(), good.id])
        #expect(rows.count == 3)
        #expect(rows.filter(\.isReady).count == 1)
        let completed = await fixture.batch.execute(rows)
        #expect(completed.map { $0.result?.status } == [.succeeded, .conflict, .conflict])
        #expect(try fixture.text(good.id).contains("remote"))
        #expect(try fixture.text(modified.id).contains("local"))
    }

    @Test("失败重试重新冻结来源，成功项不重复执行")
    func retriesFreshPreview() async throws {
        let fixture = try BatchUpdateFixture()
        defer { fixture.base.remove() }
        let good = try await fixture.add("good")
        let later = try await fixture.add("later")
        try fixture.write("remote", at: good.source)
        try fixture.write("remote", at: later.source)
        let rows = try await fixture.batch.prepare(entryIDs: [good.id, later.id])
        try fixture.write("newer", at: later.source)
        let completed = await fixture.batch.execute(rows)
        #expect(completed.map { $0.result?.status } == [.succeeded, .conflict])
        let retried = try await fixture.batch.retryPreview(completed)
        #expect(retried[0].result?.id == completed[0].result?.id)
        #expect(retried[1].preview?.id != rows[1].preview?.id)
        #expect(retried[1].preview?.remoteManifest.contains("newer") == true)
        #expect(await fixture.batch.execute(retried).allSatisfy { $0.result?.isSuccess == true })
        #expect(try fixture.text(later.id).contains("newer"))
    }

    @Test("批量取消逐项保留 cancelled，不修改原内容")
    func cancelsPendingItems() async throws {
        let fixture = try BatchUpdateFixture()
        defer { fixture.base.remove() }
        let item = try await fixture.add("first")
        try fixture.write("remote", at: item.source)
        let rows = try await fixture.batch.prepare(entryIDs: [item.id])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.batch.execute(rows)
        }
        #expect(await task.value.map { $0.result?.status } == [.cancelled])
        #expect(try fixture.text(item.id).contains("original"))
    }

    @Test("整体审核预算超限产生可见结果，不持有超额预览")
    func limitsReviewBytes() async throws {
        let fixture = try BatchUpdateFixture(maximumBytes: 1)
        defer { fixture.base.remove() }
        let item = try await fixture.add("first")
        let rows = try await fixture.batch.prepare(entryIDs: [item.id])
        #expect(rows.first?.preview == nil)
        #expect(rows.first?.result?.status == .conflict)
        #expect(rows.first?.result?.message == String.l10n("skills.update.batch.limit"))
    }

    @Test("App Store 批量服务在打开数据库前拒绝")
    func rejectsAppStore() throws {
        let fixture = try BatchUpdateFixture()
        defer { fixture.base.remove() }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillBatchUpdateService(
                store: fixture.base.store, updates: fixture.updates,
                distributionGate: DistributionGate(channel: .appStore)
            )
        }
        #expect(!SkillFilePrimitives.exists(fixture.base.store.paths.database))
    }

    @Test("同授权相同 blob 仅下载一次，另一授权独立下载，关闭不删除预览")
    func sharesVerifiedPayloads() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let cache = SkillImportPayloadCache()
        let downloader = ImportTestDownloader()
        let selection = SkillGitHubSelection(owner: "owner", repository: "repo", ref: "main", directory: "")
        let file = try #require(SkillImportServiceTests.files.first { $0.path == "SKILL.md" })
        let first = fixture.root.appendingPathComponent("one/SKILL.md")
        let second = fixture.root.appendingPathComponent("two/SKILL.md")
        for target in [first, second] {
            try await cache.copy(file: file, selection: selection, authorizationID: "first", downloader: downloader, destination: target)
        }
        #expect(await downloader.downloadCount == 1)
        try await cache.copy(
            file: file, selection: selection, authorizationID: "second", downloader: downloader,
            destination: fixture.root.appendingPathComponent("three/SKILL.md")
        )
        #expect(await downloader.downloadCount == 2)
        let root = try #require(await downloader.lastRoot)
        await cache.close()
        #expect(!SkillFilePrimitives.exists(root))
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }

    @Test("下载缓存不接受校验失败的 blob")
    func rejectsCorruptPayloads() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let cache = SkillImportPayloadCache()
        let file = try #require(SkillImportServiceTests.files.first)
        let target = fixture.root.appendingPathComponent("result")
        await #expect(throws: RepoSkillError.verification) {
            try await cache.copy(
                file: file, selection: .init(owner: "owner", repository: "repo", ref: "main", directory: ""),
                authorizationID: "first", downloader: ImportTestDownloader(corrupt: true), destination: target
            )
        }
        await cache.close()
        #expect(!SkillFilePrimitives.exists(target))
    }
}

/// 多个来源共享一个真实独立库与一个内容协调器，模拟同一窗口的提交范围。
struct BatchUpdateFixture: Sendable {
    let base: SkillOperationFixture
    let imports: SkillImportService
    let updates: SkillContentUpdateService
    let batch: SkillBatchUpdateService

    init(maximumBytes: Int64 = 268_435_456) throws {
        let base = try SkillOperationFixture()
        let operations = try base.coordinator()
        let imports = try SkillImportService(
            store: base.store, operations: operations, distributionGate: DistributionGate(channel: .direct),
            tokenProvider: ImportTestToken()
        )
        let updates = try SkillContentUpdateService(
            store: base.store, imports: imports, operations: operations, distributionGate: DistributionGate(channel: .direct)
        )
        self.base = base
        self.imports = imports
        self.updates = updates
        self.batch = try SkillBatchUpdateService(
            store: base.store, updates: updates, distributionGate: DistributionGate(channel: .direct), maximumBytes: maximumBytes
        )
    }

    func add(_ name: String) async throws -> (id: UUID, source: URL) {
        let directory = base.root.appendingPathComponent("sources/\(name)/sample")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("original", at: directory)
        let preview = try await imports.prepareLocal(directory)
        #expect(await imports.execute(preview).isSuccess)
        return (preview.plan.entry.id, directory)
    }

    func write(_ text: String, at directory: URL) throws {
        try Data("---\nname: sample\ndescription: Sample\n---\n\(text)\n".utf8)
            .write(to: directory.appendingPathComponent("SKILL.md"))
    }
    func content(_ id: UUID) -> URL { base.store.paths.entryDirectory(id).appendingPathComponent("content/sample") }
    func text(_ id: UUID) throws -> String { try String(contentsOf: content(id).appendingPathComponent("SKILL.md"), encoding: .utf8) }
}
