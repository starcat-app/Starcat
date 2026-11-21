//
//  SkillEvaluationInputTests.swift
//  StarcatTests
//
//  验证真实快照入口、磁盘指纹及 Git blob 下载。所有路径和 HTTP 响应均为合成数据。
//

import Foundation
import Synchronization
import Testing
@testable import Starcat

/// 通过暂存库和隔离的网络 fixture 证明评估输入与显示预览、安装产物的边界。
@Suite("Skill 评估输入快照")
struct SkillEvaluationInputTests {
    @Test("受管条目只复制正文目录，原始字节进入版本指纹")
    func managedContentAndVersion() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let entry = SkillLibraryEntry(manifestName: "notes", summary: "", managementKind: .managed)
        try await fixture.store.save(entry)
        let entryDirectory = fixture.store.paths.entryDirectory(entry.id)
        let content = try fixture.directory("content/notes", in: entryDirectory)
        let asset = content.appendingPathComponent("notes.dat")
        try EvaluationBlobFixture.manifest.write(to: content.appendingPathComponent("SKILL.md"))
        try Data("Not the manifest".utf8).write(to: entryDirectory.appendingPathComponent("SKILL.md"))
        try Data("Receipt stays local".utf8).write(to: entryDirectory.appendingPathComponent("receipt.json"))
        let original = EvaluationBlobFixture.binary
        try original.write(to: asset)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: asset.path)

        let target = SkillEvaluationTarget.library(entry.id)
        let first = try await fixture.snapshotter.snapshot(target, under: fixture.output)
        #expect(first.name == "notes")
        #expect(first.root.lastPathComponent == "notes")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: first.root.path)) == ["SKILL.md", "notes.dat"])
        #expect(try Data(contentsOf: first.root.appendingPathComponent("SKILL.md")) == EvaluationBlobFixture.manifest)
        #expect(try Data(contentsOf: first.root.appendingPathComponent("notes.dat")) == original)
        #expect(!FileManager.default.isExecutableFile(atPath: first.root.appendingPathComponent("notes.dat").path))
        #expect(try await fixture.snapshotter.version(of: target) == first.version)

        // 同大小改写也应使旧报告过期，已发布的快照仍保留旧字节。
        try Data(repeating: 42, count: original.count).write(to: asset)
        let otherOutput = try fixture.directory("other-output")
        let second = try await fixture.snapshotter.snapshot(target, under: otherOutput)
        #expect(second.version != first.version)
        #expect(second.root != first.root)
        #expect(try Data(contentsOf: first.root.appendingPathComponent("notes.dat")) == original)
        try await fixture.store.close()
    }

    @Test("受管名称不能越界，正文父目录不能替换成链接")
    func managedBoundary() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        var entry = SkillLibraryEntry(manifestName: "../outside", summary: "", managementKind: .managed)
        try await fixture.store.save(entry)
        let target = SkillEvaluationTarget.library(entry.id)
        await #expect(throws: SkillContentReadError.invalidPath) {
            try await fixture.snapshotter.snapshot(target, under: fixture.output)
        }

        entry.manifestName = "notes"
        try await fixture.store.save(entry)
        let diverted = try fixture.directory("diverted")
        let external = try fixture.directory("notes", in: diverted)
        try EvaluationBlobFixture.manifest.write(to: external.appendingPathComponent("SKILL.md"))
        let entryDirectory = fixture.store.paths.entryDirectory(entry.id)
        try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: entryDirectory.appendingPathComponent("content"), withDestinationURL: diverted)
        await #expect(throws: SkillContentReadError.pathChanged) {
            try await fixture.snapshotter.snapshot(target, under: fixture.output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        try await fixture.store.close()
    }

    @Test("按扫描记录读取根上的无效清单，拒绝已改指向的发现入口")
    func discoveredSourceWithInvalidManifest() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let physical = try fixture.directory("source")
        let lexical = fixture.root.appendingPathComponent("configured-root")
        try FileManager.default.createSymbolicLink(at: lexical, withDestinationURL: physical)
        try EvaluationBlobFixture.manifest.write(to: physical.appendingPathComponent("SKILL.md"))
        let root = SkillLibraryRoot(configuredPath: lexical.path, agentIDs: [], scope: .global)
        let scanner = try LocalSkillScanner(distributionGate: .init(channel: .direct))
        let generation = await fixture.store.beginScan()
        let report = await scanner.scan(.init(generationID: generation, roots: [root]))
        #expect(try await fixture.store.apply(report))
        let library = try await fixture.store.snapshot()
        let entry = try #require(library.entries.first)
        #expect(entry.diagnostic != nil)
        let target = SkillEvaluationTarget.library(entry.id)
        let input = try await fixture.snapshotter.snapshot(target, under: fixture.output)
        #expect(input.root.lastPathComponent == physical.lastPathComponent)
        #expect(try Data(contentsOf: input.root.appendingPathComponent("SKILL.md")) == EvaluationBlobFixture.manifest)

        let outside = try fixture.directory("other-source")
        try EvaluationBlobFixture.manifest.write(to: outside.appendingPathComponent("SKILL.md"))
        try FileManager.default.removeItem(at: lexical)
        try FileManager.default.createSymbolicLink(at: lexical, withDestinationURL: outside)
        await #expect(throws: SkillContentReadError.pathChanged) { try await fixture.snapshotter.version(of: target) }

        // 即使索引真实记录了另一个入口，入口配置也不能授权读取根外内容。
        let agents = try fixture.directory("agents")
        let escaped = agents.appendingPathComponent("notes")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: physical)
        let agentsRoot = SkillLibraryRoot(configuredPath: agents.path, resolvedPath: agents.path, agentIDs: [], scope: .global)
        try await fixture.store.save(agentsRoot)
        try await fixture.store.save(SkillLibraryLocation(
            entryID: entry.id, rootID: agentsRoot.id, lexicalPath: escaped.path, resolvedPath: physical.path, kind: .symbolicLink
        ))
        await #expect(throws: SkillContentReadError.pathChanged) { try await fixture.snapshotter.version(of: target) }
        try await fixture.store.close()
    }

    @Test("拒绝符号链接和硬链接附件，失败后清理中间快照", arguments: [true, false])
    func rejectsLinkedAttachment(symbolic: Bool) async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let entry = SkillLibraryEntry(manifestName: "notes", summary: "", managementKind: .managed)
        try await fixture.store.save(entry)
        let content = try fixture.directory("content/notes", in: fixture.store.paths.entryDirectory(entry.id))
        try EvaluationBlobFixture.manifest.write(to: content.appendingPathComponent("SKILL.md"))
        let external = fixture.root.appendingPathComponent("outside.dat")
        try EvaluationBlobFixture.binary.write(to: external)
        let link = content.appendingPathComponent("attachment.dat")
        if symbolic {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        } else {
            try FileManager.default.linkItem(at: external, to: link)
        }
        let target = SkillEvaluationTarget.library(entry.id)
        await #expect(throws: RepoSkillError.unsupportedFiles) {
            try await fixture.snapshotter.snapshot(target, under: fixture.output)
        }
        await #expect(throws: RepoSkillError.unsupportedFiles) { try await fixture.snapshotter.version(of: target) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        try await fixture.store.close()
    }

    @Test("指纹与快照共用本机总字节上限")
    func localBudget() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let entry = SkillLibraryEntry(manifestName: "notes", summary: "", managementKind: .managed)
        try await fixture.store.save(entry)
        let content = try fixture.directory("content/notes", in: fixture.store.paths.entryDirectory(entry.id))
        try EvaluationBlobFixture.manifest.write(to: content.appendingPathComponent("SKILL.md"))
        let asset = content.appendingPathComponent("large.dat")
        try Data().write(to: asset)
        let handle = try FileHandle(forWritingTo: asset)
        // 使用稀疏附件，避免测试为构造预算边界分配大块内存。
        try handle.truncate(atOffset: UInt64(SkillEvaluationSnapshotter.maximumBytes))
        try handle.close()
        let target = SkillEvaluationTarget.library(entry.id)
        await #expect(throws: SkillFileTransactionError.self) { try await fixture.snapshotter.version(of: target) }
        await #expect(throws: SkillFileTransactionError.self) {
            try await fixture.snapshotter.snapshot(target, under: fixture.output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        try await fixture.store.close()
    }

    @Test("固定树的无效清单、二进制、空文件和 LFS pointer 均保留原字节")
    func scannedRepositorySnapshot() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let repo = try await fixture.repo()
        let downloader = EvaluationBlobFixture.downloader()
        let api = MockGitHubAPIClient()
        let commit = "fixture-fixed-commit"
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            GitHubCommitSummaryDTO(sha: commit, commit: GitHubCommitSummaryPayloadDTO(committer: nil, author: nil))
        }
        let blobs = [
            EvaluationBlobFixture.manifestBlob, EvaluationBlobFixture.binaryBlob,
            EvaluationBlobFixture.emptyBlob, EvaluationBlobFixture.pointerBlob,
        ]
        api.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == commit)
            return GitHubGitTreeDTO(sha: "fixture-tree", truncated: false, tree: blobs.map { blob in
                .init(path: "skills/notes/" + blob.path, mode: blob.mode, type: "blob", sha: blob.sha, size: blob.size, url: nil)
            })
        }
        let scan = try await RepoSkillScanner(api: api, downloader: downloader, cacheScope: UUID().uuidString).scan(repo)
        let skill = try #require(scan.skills.first)
        #expect(skill.installationIssue != nil)
        #expect(skill.evaluationSnapshotComplete == true)
        let snapshotter = SkillEvaluationSnapshotter(store: nil, downloader: downloader)
        let target = SkillEvaluationTarget.repository(repo, skill)
        let input = try await snapshotter.snapshot(target, under: fixture.output)
        #expect(input.version == commit)
        #expect(try await snapshotter.version(of: target) == commit)
        for blob in blobs {
            let file = input.root.appendingPathComponent(blob.path)
            let expected = try #require(EvaluationBlobFixture.body(for: blob.sha))
            #expect(try Data(contentsOf: file) == expected)
            #expect(!FileManager.default.isExecutableFile(atPath: file.path))
        }
    }

    @Test("Git 路径越界和总量超限均在下载前失败")
    func invalidRepositoryMembers() async throws {
        let fixture = try EvaluationInputFixture()
        defer { fixture.clean() }
        let repo = try await fixture.repo()
        func target(_ file: RepoSkillFile) -> SkillEvaluationTarget {
            .repository(repo, RepoSkill(
                repositoryID: repo.id, commitSHA: "fixture-fixed-commit", directory: "notes/", name: "notes",
                summary: "", manifest: "", files: [EvaluationBlobFixture.manifestBlob, file],
                installationIssue: nil, evaluationSnapshotComplete: true
            ))
        }
        // 组合字符不能盖住路径分隔斜杠。
        for path in ["../neighbor.dat", "../\u{0301}neighbor.dat"] {
            let escape = RepoSkillFile(path: path, sha: "fixture", size: 1, mode: "100644")
            await #expect(throws: RepoSkillError.unsupportedFiles) {
                try await fixture.snapshotter.snapshot(target(escape), under: fixture.output)
            }
        }
        let oversized = RepoSkillFile(path: "large.dat", sha: "fixture", size: SkillEvaluationSnapshotter.maximumBytes, mode: "100644")
        await #expect(throws: SkillFileTransactionError.self) {
            try await fixture.snapshotter.snapshot(target(oversized), under: fixture.output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
    }

    @Test("无 Content-Length 时依然拒绝超额、提前结束和同长 SHA 不符的响应", arguments: ["oversized", "truncated", "wrong-sha"])
    func streamingVerification(route: String) async throws {
        let downloader: any RepoFileDownloading = EvaluationBlobFixture.downloader()
        await #expect(throws: RepoSkillError.verification) {
            try await downloader.evaluationBlob(owner: "octo", repo: route, sha: EvaluationBlobFixture.binaryBlob.sha, size: 5)
        }
    }
}

/// 独立的 SQLite 库和输出目录。未注入 Git 下载器的用例无法触达真实网络。
private struct EvaluationInputFixture {
    let root: URL
    let output: URL
    let store: SkillLibraryStore
    var snapshotter: SkillEvaluationSnapshotter { .init(store: store, downloader: EvaluationNoDownload()) }

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("starcat-skill-evaluation-" + UUID().uuidString)
        output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        store = try SkillLibraryStore(distributionGate: .init(channel: .direct), paths: .init(root: root.appendingPathComponent("library")))
    }

    func directory(_ name: String, in parent: URL? = nil) throws -> URL {
        let directory = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func repo() async throws -> Repo {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, name: "notes-fixture")
        return try #require(try await GRDBRepoRepository(database: database).findById(1))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

/// 评估 blob 使用协议默认错误，确保预检用例若进入下载会以错误类型不符失败。
private struct EvaluationNoDownload: RepoFileDownloading {
    func download(owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
                  onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw RepoSkillError.incomplete
    }
}

/// 当前 session 拦截每个请求。固定 SHA 独立计算，避免用被测实现生成期望值。
private final class EvaluationBlobFixture: URLProtocol, @unchecked Sendable {
    private let deferredFailure = Mutex<Task<Void, Never>?>(nil)
    static let manifest = Data("# Fixture without frontmatter\r\n".utf8)
    static let binary = Data([0, 255, 13, 10, 128])
    static let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(String(repeating: "0", count: 64))\nsize 123456789\n".utf8)
    static let manifestBlob = RepoSkillFile(path: "SKILL.md", sha: "a42793316843297a42aa0eb41d0151f0399af2b4", size: manifest.count, mode: "100644")
    static let binaryBlob = RepoSkillFile(path: "assets/notes.dat", sha: "ae5d7476257130a0c0360ea80423718e2e45a077", size: binary.count, mode: "100755")
    static let emptyBlob = RepoSkillFile(path: "empty.txt", sha: "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", size: 0, mode: "100644")
    static let pointerBlob = RepoSkillFile(path: "assets/archive.dat", sha: "e5dc7be26cec9cf29e3967a40beae0700133a2a2", size: pointer.count, mode: "100644")

    static func downloader() -> RepoFileDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return RepoFileDownloader(session: URLSession(configuration: configuration), tokenProvider: StubTokenProvider(token: nil))
    }

    static func body(for sha: String) -> Data? {
        switch sha {
        case manifestBlob.sha: manifest
        case binaryBlob.sha: binary
        case emptyBlob.sha: Data()
        case pointerBlob.sha: pointer
        default: nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              url.deletingLastPathComponent().path.hasSuffix("/git/blobs"),
              let body = Self.body(for: url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let repo = url.pathComponents.dropLast(3).last
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // 分段交付且省略 Content-Length，不能依赖响应头发现越界。
        switch repo {
        case "oversized":
            // 刻意不发送 EOF。若实现等到响应完整才检查大小，只会先收到这个传输错误。
            let failure = Task { @Sendable [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            deferredFailure.withLock { $0 = failure }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 32_768))
            return
        case "truncated": client?.urlProtocol(self, didLoad: Data(body.dropLast()))
        case "wrong-sha": client?.urlProtocol(self, didLoad: Data([0, 255, 13, 10, 129]))
        default:
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { deferredFailure.withLock { $0?.cancel() } }
}
