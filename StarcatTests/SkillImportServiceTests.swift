//
//  SkillImportServiceTests.swift
//  StarcatTests
//
//  导入测试只使用临时目录、内存授权和固定 Git 树，验证用户预览的内容
//  与最终受管副本一致；不访问真实 GitHub 或用户 Agent 目录。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Skill 本地与 GitHub 导入")
struct SkillImportServiceTests {
    @Test("App Store 在创建目录与请求网络前拒绝")
    func rejectsAppStore() throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        #expect(throws: DistributionGateError.self) {
            _ = try SkillImportService(
                store: fixture.store, operations: fixture.coordinator(),
                distributionGate: DistributionGate(channel: .appStore)
            )
        }
        #expect(!SkillFilePrimitives.exists(fixture.store.paths.database))
    }

    @Test("本地导入保留原目录、空目录与附件，重复来源引导更新")
    func importsLocalDirectory() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.plan()
        let service = try makeService(fixture)
        let preview = try await service.prepareLocal(fixture.incoming)
        #expect(await service.execute(preview).status == .succeeded)
        let target = fixture.store.paths.entryDirectory(preview.plan.entry.id)
            .appendingPathComponent("content/sample")
        #expect(try await SkillFilePrimitives.fingerprint(target) == preview.plan.fingerprint)
        #expect(try await SkillFilePrimitives.fingerprint(fixture.incoming) == preview.plan.fingerprint)
        await #expect(throws: SkillImportError.existing) { try await service.prepareLocal(fixture.incoming) }
        #expect(await service.execute(preview).status == .alreadySatisfied)
        #expect(try await fixture.store.snapshot().entries.count == 1)
    }

    @Test("预览期间原目录改变则拒绝提交，原文保持可用")
    func rejectsSourceChanges() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.plan()
        let service = try makeService(fixture)
        let preview = try await service.prepareLocal(fixture.incoming)
        try Data("user edit".utf8).write(to: fixture.incoming.appendingPathComponent("assets/data.txt"))
        #expect(await service.execute(preview).status == .conflict)
        #expect(try await fixture.store.snapshot().entries.isEmpty)
    }

    @Test("同名但不同来源保留独立身份")
    func keepsDifferentSources() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.plan()
        let second = fixture.root.appendingPathComponent("second/sample")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.incoming, to: second)
        let service = try makeService(fixture)
        let firstPreview = try await service.prepareLocal(fixture.incoming)
        let secondPreview = try await service.prepareLocal(second)
        #expect(await service.execute(firstPreview).isSuccess)
        #expect(await service.execute(secondPreview).isSuccess)
        #expect(try await fixture.store.snapshot().entries.count == 2)
    }

    @Test("固定 commit 与执行位入库，临时缓存随成功清理")
    func importsFrozenGitHubTree() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let api = githubAPI()
        let service = try makeService(fixture, api: api)
        let preview = try await service.prepareGitHub(.init(repository: "https://github.com/Owner/Repo.git"))
        #expect(preview.plan.source.canonicalLocator == "owner/repo")
        #expect(preview.plan.revision.upstreamCommit == Self.commit)
        #expect(preview.plan.fingerprint.members.first { $0.path == "scripts/check.sh" }?.mode == 0o755)
        let temporary = try #require(preview.temporaryRoot)
        #expect(await service.execute(preview).status == .succeeded)
        #expect(!SkillFilePrimitives.exists(temporary))
        #expect(try await fixture.store.snapshot().entries.first?.trackingRef == "HEAD")
    }

    @Test("slash 分支依证据拆分，歧义要求显式 ref")
    func resolvesSlashRefs() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let api = githubAPI()
        api.repositoryBranchesHandler = { _, _ in [.init(name: "feature/beta")] }
        api.repositoryGitTreeLevelHandler = { _, _, ref in
            #expect(ref == Self.commit)
            return .init(sha: ref, truncated: false, tree: [
                .init(path: "sample", mode: "040000", type: "tree", sha: "subtree", size: nil, url: nil)
            ])
        }
        let service = try makeService(fixture, api: api)
        let request = SkillGitHubImportRequest(repository: "https://github.com/owner/repo/tree/feature/beta/sample")
        let preview = try await service.prepareGitHub(request)
        #expect(preview.plan.entry.trackingRef == "feature/beta")
        #expect(preview.plan.source.subdirectory == "sample")
        await service.discard(preview)
        api.repositoryBranchesHandler = { _, _ in [.init(name: "feature"), .init(name: "feature/beta")] }
        await #expect(throws: SkillImportError.ref) { try await service.prepareGitHub(request) }
        let explicit = try await service.prepareGitHub(.init(repository: request.repository, ref: "feature/beta"))
        await service.discard(explicit)
    }

    @Test("不完整树与非法文件类型不进入下载", arguments: [0, 1, 2, 3])
    func rejectsUnsafeTrees(kind: Int) async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let api = githubAPI()
        api.repositoryGitTreeHandler = { _, _, _ in
            var files = Self.files
            if kind == 1 {
                files.append(.init(path: "../escape", mode: "100644", type: "blob", sha: "x", size: 1, url: nil))
            } else if kind == 2 {
                files.append(.init(path: "link", mode: "120000", type: "blob", sha: "x", size: 1, url: nil))
            } else if kind == 3 {
                files.append(.init(path: "module", mode: "160000", type: "commit", sha: "x", size: nil, url: nil))
            }
            return .init(sha: Self.commit, truncated: kind == 0, tree: files)
        }
        let service = try makeService(fixture, api: api)
        await #expect(throws: (any Error).self) { try await service.prepareGitHub(.init(repository: "owner/repo")) }
        #expect(try await fixture.store.snapshot().entries.isEmpty)
    }

    @Test("blob 校验失败清理下载现场")
    func rejectsCorruptDownloads() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let downloader = ImportTestDownloader(corrupt: true)
        let service = try makeService(fixture, downloader: downloader)
        await #expect(throws: RepoSkillError.verification) {
            try await service.prepareGitHub(.init(repository: "owner/repo"))
        }
        let root = try #require(await downloader.lastRoot)
        #expect(!SkillFilePrimitives.exists(root.deletingLastPathComponent()))
    }

    @Test("换账号后旧预览取消，不保留私有下载")
    func rejectsAuthorizationChange() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let token = ImportTestToken()
        let service = try makeService(fixture, token: token)
        let preview = try await service.prepareGitHub(.init(repository: "owner/repo"))
        await token.change()
        #expect(await service.execute(preview).status == .cancelled)
        #expect(try await fixture.store.snapshot().entries.isEmpty)
        #expect(!SkillFilePrimitives.exists(try #require(preview.temporaryRoot)))
    }

    @Test("预览取消不写库且可显式释放缓存")
    func discardsPreview() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        let service = try makeService(fixture)
        let preview = try await service.prepareGitHub(.init(repository: "owner/repo"))
        await service.discard(preview)
        #expect(!SkillFilePrimitives.exists(try #require(preview.temporaryRoot)))
        #expect(try await fixture.store.snapshot().entries.isEmpty)
    }

    @Test("库不可用报告失败，不伪装为用户取消")
    func reportsDatabaseFailure() async throws {
        let fixture = try SkillOperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.plan()
        let service = try makeService(fixture)
        let preview = try await service.prepareLocal(fixture.incoming)
        try await fixture.store.close()
        try FileManager.default.removeItem(at: fixture.store.paths.database)
        try FileManager.default.createDirectory(at: fixture.store.paths.database, withIntermediateDirectories: true)
        #expect(await service.execute(preview).status == .failed)
        #expect(SkillFilePrimitives.exists(fixture.incoming.appendingPathComponent("SKILL.md")))
    }

    /// 注入客户端后依然执行真实目录、manifest、blob 与事务验证。
    private func makeService(
        _ fixture: SkillOperationFixture, api: MockGitHubAPIClient? = nil,
        downloader: ImportTestDownloader = ImportTestDownloader(),
        token: ImportTestToken = ImportTestToken()
    ) throws -> SkillImportService {
        let api = api ?? githubAPI()
        return try SkillImportService(
            store: fixture.store, operations: fixture.coordinator(),
            distributionGate: DistributionGate(channel: .direct), tokenProvider: token,
            makeClients: { _ in SkillGitHubClients(api: api, downloader: downloader) }
        )
    }

    private func githubAPI() -> MockGitHubAPIClient {
        let api = MockGitHubAPIClient()
        api.repositoryLatestCommitHandler = { _, _, _, _ in
            .init(sha: Self.commit, commit: .init(committer: nil, author: nil))
        }
        api.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == Self.commit || ref == "subtree")
            return .init(sha: ref, truncated: false, tree: Self.files)
        }
        return api
    }

    static let commit = String(repeating: "a", count: 40)
    static let contents: [String: Data] = [
        "SKILL.md": Data("---\nname: sample\ndescription: Sample\n---\n# Sample\n".utf8),
        "scripts/check.sh": Data("echo sample\n".utf8)
    ]
    static var files: [GitHubGitTreeEntryDTO] {
        contents.sorted { $0.key < $1.key }.map { path, data in
            .init(path: path, mode: path.hasSuffix(".sh") ? "100755" : "100644", type: "blob",
                  sha: RepoFileDownloader.gitBlobSHA(data), size: data.count, url: nil)
        }
    }
}

/// actor 让下载路径和可变授权在并行测试中有明确隔离。
actor ImportTestDownloader: RepoFileDownloading {
    let corrupt: Bool
    private(set) var lastRoot: URL?
    init(corrupt: Bool = false) { self.corrupt = corrupt }

    func download(
        owner: String, repo: String, sha: String, relativePath: String, toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws -> URL {
        lastRoot = root
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (corrupt ? Data("corrupt".utf8) : SkillImportServiceTests.contents[relativePath] ?? Data())
            .write(to: destination)
        return destination
    }
}

actor ImportTestToken: GitHubTokenProviding {
    private var value = "first-test-identity"
    func currentToken() -> String? { value }
    func change() { value = "second-test-identity" }
}
