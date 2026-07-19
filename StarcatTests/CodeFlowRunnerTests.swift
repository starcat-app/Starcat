//
//  CodeFlowRunnerTests.swift
//  StarcatTests
//
//  验证 commit 固定 ZIP、共享缓存、metadata 与 CodeFlow 输出目录，不访问真实网络。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodeFlowRunner")
@MainActor
struct CodeFlowRunnerTests {
    @Test("自定义父目录会按集成名隔离，已选目标目录时不重复追加")
    func normalizesCustomOutputRoots() {
        let parent = URL(fileURLWithPath: "/Users/test/Starcat", isDirectory: true)
        let codeFlowRoot = parent.appendingPathComponent("codeflow", isDirectory: true)
        let repoContextRoot = parent.appendingPathComponent("repocontext", isDirectory: true)

        #expect(CodeFlowStorage.customOutputRoot(for: parent) == codeFlowRoot)
        #expect(CodeFlowStorage.customOutputRoot(for: codeFlowRoot) == codeFlowRoot)
        #expect(RepoContextStorage.customOutputRoot(for: parent) == repoContextRoot)
        #expect(RepoContextStorage.customOutputRoot(for: repoContextRoot) == repoContextRoot)
    }

    @Test("首次下载使用固定 commit zipball 并写入共享快照")
    func downloadsFixedCommitZipball() async throws {
        let downloader = RecordingArchiveDownloader(data: Data("zip-data".utf8))
        let github = StubCodeFlowGitHubProvider()
        let runner = CodeFlowRunner(downloader: downloader, github: github)
        let repo = makeRepo(owner: "starcat-download-\(UUID().uuidString)", name: "codeflow")
        let sha = "51ab9708841e14258bebfb5fb326e8b37782d193"
        let archiveURL = try runner.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: sha)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await runner.archiveIfNeeded(
            repo: repo,
            commitSHA: sha,
            maximumBytes: SharedSnapshotService.maximumArchiveBytes
        )

        #expect(result.wasDownloaded)
        #expect(try Data(contentsOf: result.url) == Data("zip-data".utf8))
        let requestedURLs = await downloader.requestedURLs
        #expect(requestedURLs == [URL(string: "https://api.github.com/repos/\(repo.owner)/codeflow/zipball/\(sha)")!])
    }

    @Test("CodeFlow 下载使用调用方传入的仓库 ZIP 上限")
    func rejectsArchiveAboveConfiguredLimit() async throws {
        let downloader = RecordingArchiveDownloader(data: Data("zip-data".utf8))
        let runner = CodeFlowRunner(downloader: downloader, github: StubCodeFlowGitHubProvider())
        let repo = makeRepo(owner: "starcat-limit-\(UUID().uuidString)", name: "codeflow")

        do {
            _ = try await runner.archiveIfNeeded(
                repo: repo,
                commitSHA: "configured-limit",
                maximumBytes: 4
            )
            Issue.record("Expected configured archive limit to reject the download")
        } catch CodeFlowError.archiveTooLarge {
            // Expected.
        }
    }

    @Test("同一 commit 已有 ZIP 时跳过网络下载")
    func reusesCommitArchive() async throws {
        let downloader = RecordingArchiveDownloader(data: Data("new-data".utf8))
        let runner = CodeFlowRunner(downloader: downloader, github: StubCodeFlowGitHubProvider())
        let repo = makeRepo(owner: "starcat-cache-\(UUID().uuidString)", name: "demo")
        let archiveURL = try runner.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: "abc123")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeZipHeader(firstEntry: "starcat-cache-demo-abc123/").write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await runner.archiveIfNeeded(
            repo: repo,
            commitSHA: "abc123",
            maximumBytes: SharedSnapshotService.maximumArchiveBytes
        )

        #expect(!result.wasDownloaded)
        #expect(await downloader.requestedURLs.isEmpty)
    }

    @Test("生成页面同时写入 metadata 并可从文件系统恢复")
    func generatedPageContainsMetadata() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("starcat-codeflow-output-\(UUID().uuidString)")
        let storage = CodeFlowStorage(fileManager: fileManager, defaults: isolatedDefaults(), fixedRootURL: root)
        let runner = CodeFlowRunner(
            downloader: RecordingArchiveDownloader(data: Data()),
            github: StubCodeFlowGitHubProvider(),
            storage: storage,
            fileManager: fileManager
        )
        let archiveURL = fileManager.temporaryDirectory.appendingPathComponent("starcat-codeflow-\(UUID().uuidString).zip")
        try Data("zip-data".utf8).write(to: archiveURL)
        defer {
            try? fileManager.removeItem(at: archiveURL)
            try? fileManager.removeItem(at: root)
        }

        let repo = makeRepo(owner: "braedonsaunders", name: "codeflow")
        let branch = CodeFlowBranch(name: "main", commitSHA: "51ab9708841e14258bebfb5fb326e8b37782d193")
        let project = try runner.makeVisualizationPage(
            archive: CodeFlowArchiveResult(url: archiveURL, wasDownloaded: true, bytes: 8),
            repo: repo,
            branch: branch,
            startedAt: Date(),
            steps: [],
            previousGenerationCount: 2,
            maximumBytes: SharedSnapshotService.maximumArchiveBytes
        )

        let html = try String(contentsOf: project.pageURL, encoding: .utf8)
        #expect(!html.contains("__STARCAT_CODEFLOW_ZIP_PAYLOAD_TOKEN__"))
        #expect(project.metadata.sourceRevision.branch == "main")
        #expect(project.metadata.sourceRevision.commitSHA == branch.commitSHA)
        #expect(project.metadata.generation.generationCount == 3)
        #expect(try runner.existingProject(owner: repo.owner, name: repo.name)?.pageURL == project.pageURL)
    }

    @Test("CodeFlow HTML 注入阶段再次执行配置上限")
    func pageGenerationRespectsConfiguredLimit() throws {
        let fileManager = FileManager.default
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("starcat-codeflow-page-limit-\(UUID().uuidString).zip")
        try Data("zip-data".utf8).write(to: archiveURL)
        defer { try? fileManager.removeItem(at: archiveURL) }

        do {
            _ = try CodeFlowRunner().makeVisualizationPage(
                archive: CodeFlowArchiveResult(url: archiveURL, wasDownloaded: false, bytes: 8),
                repo: makeRepo(owner: "starcat-limit", name: "codeflow"),
                branch: CodeFlowBranch(name: "main", commitSHA: "configured-limit"),
                startedAt: Date(),
                steps: [],
                maximumBytes: 4
            )
            Issue.record("Expected HTML generation to enforce the configured archive limit")
        } catch CodeFlowError.archiveTooLarge {
            // Expected.
        }
    }

    @Test("CodeFlow 清理只删除生成物，不删除共享 ZIP")
    func deletingProjectPreservesSharedArchive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("starcat-codeflow-delete-\(UUID().uuidString)")
        let storage = CodeFlowStorage(fileManager: fileManager, defaults: isolatedDefaults(), fixedRootURL: root)
        let downloader = RecordingArchiveDownloader(data: Data("zip-data".utf8))
        let runner = CodeFlowRunner(downloader: downloader, github: StubCodeFlowGitHubProvider(), storage: storage)
        let repo = makeRepo(owner: "starcat-delete-\(UUID().uuidString)", name: "demo")
        let sha = "abc123"
        let archive = try await runner.archiveIfNeeded(
            repo: repo,
            commitSHA: sha,
            maximumBytes: SharedSnapshotService.maximumArchiveBytes
        )
        let project = try runner.makeVisualizationPage(
            archive: archive,
            repo: repo,
            branch: CodeFlowBranch(name: "main", commitSHA: sha),
            startedAt: Date(),
            steps: [],
            maximumBytes: SharedSnapshotService.maximumArchiveBytes
        )
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: archive.url.deletingLastPathComponent())
        }

        try runner.deleteVisualization(owner: repo.owner, name: repo.name)

        #expect(!fileManager.fileExists(atPath: project.directoryURL.path))
        #expect(fileManager.fileExists(atPath: archive.url.path))
    }

    @Test("切换输出目录会迁移 CodeFlow 项目并保留无关文件")
    func migratesProjectsBetweenOutputRoots() throws {
        let fileManager = FileManager.default
        let sourceRoot = fileManager.temporaryDirectory.appendingPathComponent("starcat-codeflow-source-\(UUID().uuidString)")
        let destinationRoot = fileManager.temporaryDirectory.appendingPathComponent("starcat-codeflow-destination-\(UUID().uuidString)")
        let storage = CodeFlowStorage(fileManager: fileManager, defaults: isolatedDefaults(), fixedRootURL: sourceRoot)
        let unrelated = sourceRoot.appendingPathComponent("keep-me.txt")
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        defer {
            try? fileManager.removeItem(at: sourceRoot)
            try? fileManager.removeItem(at: destinationRoot)
        }

        let now = Date()
        let metadata = CodeFlowMetadata(
            schemaVersion: 1,
            repository: .init(githubID: 1, owner: "owner", name: "repo", fullName: "owner/repo", htmlURL: "https://github.com/owner/repo"),
            artifact: .init(page: "index.html", pageBytes: 13, sourceArchiveBytes: 8, sourceArchiveKey: "github.com/owner/repo/abc.zip"),
            generation: .init(generatedAt: now, generationCount: 1, lastDurationMilliseconds: 12),
            sourceRevision: .init(branch: "main", commitSHA: "abc", commitURL: "https://github.com/owner/repo/commit/abc"),
            lastExecution: .init(startedAt: now, finishedAt: now, steps: []),
            generator: .init(codeFlowCommit: "51ab970", integrationVersion: 1)
        )
        let project = try storage.write(pageHTML: "<html></html>", metadata: metadata, owner: "owner", name: "repo")

        try storage.migrateProjects(
            from: (sourceRoot, false),
            to: (destinationRoot, false)
        )

        #expect(!fileManager.fileExists(atPath: project.directoryURL.path))
        #expect(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("owner/repo/index.html").path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    private func makeRepo(owner: String, name: String) -> Repo {
        Repo(
            id: 99_001,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: "HTML",
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil,
            defaultBranch: "main"
        )
    }

    /// 构造包含 GitHub zipball 首目录名的最小 ZIP header，供共享缓存 SHA 校验使用。
    private func makeZipHeader(firstEntry: String) -> Data {
        let name = Data(firstEntry.utf8)
        var header = Data([0x50, 0x4B, 0x03, 0x04])
        header.append(Data(repeating: 0, count: 22))
        header.append(UInt8(name.count & 0xFF))
        header.append(UInt8((name.count >> 8) & 0xFF))
        header.append(contentsOf: [0, 0])
        header.append(name)
        return header
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodeFlowRunnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor RecordingArchiveDownloader: CodeFlowArchiveDownloading {
    private(set) var requestedURLs: [URL] = []
    private let data: Data
    private let statusCode: Int

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func download(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requestedURLs.append(url)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}

private struct StubCodeFlowGitHubProvider: CodeFlowGitHubProviding {
    func branches(owner: String, repo: String) async throws -> [CodeFlowBranch] {
        [CodeFlowBranch(name: "main", commitSHA: "abc123")]
    }

    func branch(owner: String, repo: String, name: String) async throws -> CodeFlowBranch {
        CodeFlowBranch(name: name, commitSHA: "abc123")
    }
}
