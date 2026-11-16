//
//  RepoSkillExporterTests.swift
//  StarcatTests
//
//  固定 blob 和隔离临时目录验证导出结果及失败清理，不访问网络或用户安装目录。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repository Skill exports")
struct RepoSkillExporterTests {
    /// 文件路径同时作为夹具内容，实际 SHA 校验可发现下载内容被改变。
    private func fixture() async throws -> (Repo, RepoSkill) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        let repo = try #require(try await GRDBRepoRepository(database: database).findById(1))
        let files = ["SKILL.md", "agents/openai.yaml", "scripts/check.sh"].map { path in
            RepoSkillFile(path: path, sha: RepoFileDownloader.gitBlobSHA(Data(path.utf8)),
                          size: path.utf8.count, mode: path.hasSuffix(".sh") ? "100755" : "100644")
        }
        return (repo, RepoSkill(
            repositoryID: 1, commitSHA: "fixed", directory: "skills/engineering/ask-matt/",
            name: "ask-matt", summary: "Review", manifest: "# Review", files: files, installationIssue: nil
        ))
    }

    @Test("单文件导出保留 blob 内容和执行位，保存可替换已有文件")
    func exportOneFile() async throws {
        let (repo, skill) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = RepoSkillExporter(downloader: ExportTestDownloader(), temporaryRoot: root)
        let file = skill.files[2]
        let artifact = try await exporter.export(file: file, skill: skill, repo: repo)
        #expect(try Data(contentsOf: artifact) == Data(file.path.utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: artifact.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        let destination = root.appendingPathComponent(file.name)
        try Data("old".utf8).write(to: destination)
        try await exporter.save(artifact, to: destination)
        #expect(try Data(contentsOf: destination) == Data(file.path.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test("校验失败或下载取消不遗留半成品")
    func failureCleanup() async throws {
        let (repo, skill) = try await fixture()
        for downloader in [ExportTestDownloader(corrupted: true), ExportTestDownloader(cancelled: true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let exporter = RepoSkillExporter(downloader: downloader, temporaryRoot: root)
            await #expect(throws: (any Error).self) {
                try await exporter.export(file: skill.files[0], skill: skill, repo: repo)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test("拒绝不属于扫描清单的文件")
    func scannedBoundary() async throws {
        let (repo, skill) = try await fixture()
        let exporter = RepoSkillExporter(downloader: ExportTestDownloader())
        let foreign = RepoSkillFile(path: "../outside", sha: "bad", size: 1, mode: "100644")
        await #expect(throws: RepoSkillError.self) {
            try await exporter.export(file: foreign, skill: skill, repo: repo)
        }
    }
}

/// 模拟下载器的仓库前缀行为，确保导出器不会把下载暂存布局泄露给用户。
private struct ExportTestDownloader: RepoFileDownloading {
    var corrupted = false
    var cancelled = false

    func download(
        owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let url = root.appendingPathComponent(repo).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((corrupted ? "wrong content" : relativePath).utf8).write(to: url)
        if cancelled { throw CancellationError() }
        onProgress?(1)
        return url
    }

    func preview(owner: String, repo: String, sha: String, relativePath: String, hintedSize: Int?) async throws -> RepoFilePreview {
        .text(relativePath)
    }
}
