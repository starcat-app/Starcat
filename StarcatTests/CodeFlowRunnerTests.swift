//
//  CodeFlowRunnerTests.swift
//  StarcatTests
//
//  验证 GitHub ZIP 下载、缓存复用和 CodeFlow 页面注入，不访问真实网络。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CodeFlowRunner")
struct CodeFlowRunnerTests {
    @Test("首次下载使用 GitHub zipball API 并写入缓存")
    func downloadsGitHubZipball() async throws {
        let downloader = RecordingArchiveDownloader(data: Data("zip-data".utf8))
        let runner = CodeFlowRunner(downloader: downloader)
        let repo = makeRepo(owner: "braedonsaunders", name: "codeflow")
        let archiveURL = try runner.archiveFileURL(owner: repo.owner, name: repo.name)
        try? FileManager.default.removeItem(at: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await runner.archiveIfNeeded(repo: repo)

        #expect(result.wasDownloaded)
        #expect(try Data(contentsOf: result.0) == Data("zip-data".utf8))
        let requestedURLs = await downloader.requestedURLs
        #expect(requestedURLs == [URL(string: "https://api.github.com/repos/braedonsaunders/codeflow/zipball")!])
    }

    @Test("已有 ZIP 时跳过网络下载")
    func reusesCachedArchive() async throws {
        let downloader = RecordingArchiveDownloader(data: Data("new-data".utf8))
        let runner = CodeFlowRunner(downloader: downloader)
        let repo = makeRepo(owner: "starcat-cache-\(UUID().uuidString)", name: "demo")
        let archiveURL = try runner.archiveFileURL(owner: repo.owner, name: repo.name)
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await runner.archiveIfNeeded(repo: repo)

        #expect(!result.wasDownloaded)
        #expect(await downloader.requestedURLs.isEmpty)
    }

    @Test("生成页面注入 ZIP 并移除占位 token")
    func generatedPageContainsInjectedArchive() throws {
        let fileManager = FileManager.default
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("starcat-codeflow-\(UUID().uuidString).zip")
        try Data("zip-data".utf8).write(to: archiveURL)
        defer { try? fileManager.removeItem(at: archiveURL) }

        let owner = "starcat-page-test-\(UUID().uuidString)"
        let runner = CodeFlowRunner(fileManager: fileManager)
        let pageURL = try runner.makeVisualizationPage(archiveURL: archiveURL, owner: owner, name: "Demo")
        defer { try? fileManager.removeItem(at: pageURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let html = try String(contentsOf: pageURL, encoding: .utf8)
        #expect(!html.contains("__STARCAT_CODEFLOW_ZIP_PAYLOAD_TOKEN__"))
        #expect(html.contains("window.__STARCAT_CODEFLOW_ZIP_BASE64__ = \""))
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
            cachedAt: nil
        )
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
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}
