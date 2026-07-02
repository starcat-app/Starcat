//
//  SharedSnapshotServiceTests.swift
//  StarcatTests
//
//  W5（2026-06-13）：验证抽出来的共享 ZIP 下载层关键行为。
//
//  覆盖 6 个 case：
//    1. 私有仓库直接抛 `.privateRepository`，不走网络
//    2. 已有 ZIP 缓存时复用，不重新下载
//    3. 首次下载并写盘成功
//    4. 100MB 上限时抛 `.archiveTooLarge`
//    5. 空 response 抛 `.emptyArchive`
//    6. 仓库级旧 ZIP 的 SHA 不匹配时重新下载
//
//  关键约束：不接触真实网络；用 fileManager 临时目录做磁盘 IO。
//

import Foundation
import Testing
@testable import Starcat

@Suite("SharedSnapshotService")
struct SharedSnapshotServiceTests {

    @Test("私有仓库直接抛 privateRepository 错误，不发起任何下载")
    func privateRepositoryShortCircuits() async throws {
        let downloader = SnapshotRecordingDownloader(data: Data())
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makePrivateRepo()

        await #expect(throws: SharedSnapshotError.self) {
            _ = try await service.archiveIfNeeded(repo: repo, commitSHA: "abc")
        }
        #expect(await downloader.requestedURLs.isEmpty)
    }

    @Test("ZIP 已缓存时不发起网络请求 + wasDownloaded == false")
    func reusesExistingArchive() async throws {
        let downloader = SnapshotRecordingDownloader(data: Data("new".utf8))
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-reuse-\(UUID().uuidString)", name: "demo")
        let archiveURL = try service.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: "deadbeef")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeZipHeader(firstEntry: "starcat-reuse-demo-deadbee/").write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await service.archiveIfNeeded(repo: repo, commitSHA: "deadbeef")

        #expect(!result.wasDownloaded)
        #expect(await downloader.requestedURLs.isEmpty)
    }

    @Test("仓库级 ZIP 对应旧 commit 时重新下载并替换")
    func replacesArchiveForDifferentCommit() async throws {
        let downloader = SnapshotRecordingDownloader(data: Data("new-zip".utf8))
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-stale-\(UUID().uuidString)", name: "demo")
        let archiveURL = try service.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: "2222222")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeZipHeader(firstEntry: "starcat-stale-demo-1111111/").write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await service.archiveIfNeeded(repo: repo, commitSHA: "2222222abcdef")

        #expect(result.wasDownloaded)
        #expect(try Data(contentsOf: archiveURL) == Data("new-zip".utf8))
        #expect(await downloader.requestedURLs.count == 1)
    }

    @Test("首次下载写盘并返回 wasDownloaded == true")
    func downloadsFirstTime() async throws {
        let downloader = SnapshotRecordingDownloader(data: Data("zip-payload".utf8))
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-download-\(UUID().uuidString)", name: "demo")
        let sha = "51ab9708841e14258bebfb5fb326e8b37782d193"
        let archiveURL = try service.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: sha)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        let result = try await service.archiveIfNeeded(repo: repo, commitSHA: sha)

        #expect(result.wasDownloaded)
        #expect(try Data(contentsOf: result.url) == Data("zip-payload".utf8))
        let urls = await downloader.requestedURLs
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString.contains("zipball/\(sha)") == true)
    }

    @Test("清理下载临时文件只删除 .tmp，不删除正式 ZIP 缓存")
    func cleanupTemporaryArchivePreservesCompletedArchive() async throws {
        let service = SharedSnapshotService(downloader: SnapshotRecordingDownloader(data: Data()), github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-cleanup-\(UUID().uuidString)", name: "demo")
        let archiveURL = try service.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: "deadbeef")
        let temporaryURL = archiveURL.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("complete-zip".utf8).write(to: archiveURL)
        try Data("partial-download".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        service.cleanupTemporaryArchive(owner: repo.owner, name: repo.name)

        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test("ZIP 超过 100MB 上限时抛 archiveTooLarge")
    func rejectsOversizedArchive() async throws {
        // 构造一个超过 maximumArchiveBytes 1 字节的 payload
        let payload = Data(count: SharedSnapshotService.maximumArchiveBytes + 1)
        let downloader = SnapshotRecordingDownloader(data: payload)
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-toolarge-\(UUID().uuidString)", name: "demo")
        let archiveURL = try service.archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: "deadbeef")
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

        await #expect(throws: SharedSnapshotError.self) {
            _ = try await service.archiveIfNeeded(repo: repo, commitSHA: "deadbeef")
        }
    }

    @Test("空 response 抛 emptyArchive 错误")
    func rejectsEmptyArchive() async throws {
        let downloader = SnapshotRecordingDownloader(data: Data())
        let service = SharedSnapshotService(downloader: downloader, github: SnapshotStubGitHubProvider())
        let repo = makeRepo(owner: "starcat-empty-\(UUID().uuidString)", name: "demo")

        await #expect(throws: SharedSnapshotError.self) {
            _ = try await service.archiveIfNeeded(repo: repo, commitSHA: "deadbeef")
        }
    }

    // MARK: - 辅助

    private func makePrivateRepo() -> Repo {
        makeRepo(owner: "private-org", name: "secret", isPrivate: true)
    }

    private func makeRepo(owner: String, name: String, isPrivate: Bool = false) -> Repo {
        Repo(
            id: 1,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(owner)/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
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

    /// 构造只包含首个 local file header 的最小测试数据；缓存校验不需要完整解压 ZIP。
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
}

// MARK: - 本地 mock（与 CodeFlowRunnerTests 等价但作用域隔离）

private actor SnapshotRecordingDownloader: CodeFlowArchiveDownloading {
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

private struct SnapshotStubGitHubProvider: CodeFlowGitHubProviding {
    func branches(owner: String, repo: String) async throws -> [CodeFlowBranch] {
        [CodeFlowBranch(name: "main", commitSHA: "abc123")]
    }
    func branch(owner: String, repo: String, name: String) async throws -> CodeFlowBranch {
        CodeFlowBranch(name: name, commitSHA: "abc123")
    }
}
