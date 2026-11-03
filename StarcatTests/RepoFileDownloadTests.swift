//
//  RepoFileDownloadTests.swift
//  StarcatTests
//
//  详情页按文件勾选下载：扁平 git tree → 嵌套节点、勾选传播、blob 落盘、路径穿越防护。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@Suite("RepoFileTreeBuilder")
struct RepoFileTreeBuilderTests {

    @Test("扁平 tree 收成目录优先的嵌套节点，并跳过子模块和符号链接")
    func buildsNestedTreeAndSkipsSubmodules() throws {
        let entries = [
            entry(path: "README.md", type: "blob", mode: "100644", sha: "readme", size: 12),
            entry(path: "src", type: "tree", mode: "040000", sha: "srcdir"),
            entry(path: "src/main.swift", type: "blob", mode: "100644", sha: "main", size: 40),
            entry(path: "src/util.swift", type: "blob", mode: "100644", sha: "util", size: 8),
            entry(path: "vendor/lib", type: "commit", mode: "160000", sha: "sub"),
            entry(path: "link", type: "blob", mode: "120000", sha: "lnk", size: 20),
            entry(path: "secret/../passwd", type: "blob", mode: "100644", sha: "bad", size: 1),
        ]

        let roots = RepoFileTreeBuilder.build(from: entries)
        #expect(roots.map(\.name) == ["src", "README.md"])

        let src = try #require(roots.first)
        #expect(src.isDirectory)
        #expect(src.children?.map(\.name) == ["main.swift", "util.swift"])
        #expect(RepoFileTreeBuilder.descendantFilePaths(of: src) == ["src/main.swift", "src/util.swift"])
        #expect(!roots.contains { $0.name == "vendor" || $0.name == "link" || $0.name == "secret" })
    }

    @Test("搜索保留命中文件，目录名命中时留下整棵子树")
    func filtersByPath() throws {
        let roots = RepoFileTreeBuilder.build(from: [
            entry(path: "README.md", type: "blob", mode: "100644", sha: "r", size: 1),
            entry(path: "src", type: "tree", mode: "040000", sha: "d"),
            entry(path: "src/main.swift", type: "blob", mode: "100644", sha: "m", size: 1),
            entry(path: "src/util.swift", type: "blob", mode: "100644", sha: "u", size: 1),
            entry(path: "docs/guide.md", type: "blob", mode: "100644", sha: "g", size: 1),
        ])

        let files = RepoFileTreeBuilder.filtered(roots, matching: "main")
        #expect(files.map(\.name) == ["src"])
        #expect(files.first?.children?.map(\.name) == ["main.swift"])

        let folderHit = RepoFileTreeBuilder.filtered(roots, matching: "src")
        #expect(folderHit.map(\.name) == ["src"])
        #expect(folderHit.first?.children?.map(\.name) == ["main.swift", "util.swift"])
    }

    @Test("Folders 页只保留目录节点")
    func foldersOnlyDropsFiles() throws {
        let roots = RepoFileTreeBuilder.build(from: [
            entry(path: "README.md", type: "blob", mode: "100644", sha: "r", size: 1),
            entry(path: "src", type: "tree", mode: "040000", sha: "d"),
            entry(path: "src/main.swift", type: "blob", mode: "100644", sha: "m", size: 1),
            entry(path: "docs", type: "tree", mode: "040000", sha: "docs"),
            entry(path: "docs/guide.md", type: "blob", mode: "100644", sha: "g", size: 1),
        ])
        let folders = RepoFileTreeBuilder.foldersOnly(roots)
        #expect(folders.map(\.name) == ["docs", "src"])
        #expect(folders.allSatisfy { $0.isDirectory })
        #expect(folders.flatMap { $0.children ?? [] }.isEmpty)
    }

    @Test("勾选文件夹会选中全部子孙文件，再点一次清空")
    func togglingDirectorySelectsDescendants() throws {
        let roots = RepoFileTreeBuilder.build(from: [
            entry(path: "src", type: "tree", mode: "040000", sha: "d"),
            entry(path: "src/a.swift", type: "blob", mode: "100644", sha: "a", size: 1),
            entry(path: "src/b.swift", type: "blob", mode: "100644", sha: "b", size: 1),
            entry(path: "README.md", type: "blob", mode: "100644", sha: "r", size: 1),
        ])
        let src = try #require(roots.first)
        var selected: Set<String> = []

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(selected == ["src/a.swift", "src/b.swift"])
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        selected.insert("README.md")
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        selected.remove("src/b.swift")
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .mixed)

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(selected.contains("src/a.swift"))
        #expect(selected.contains("src/b.swift"))
        #expect(selected.contains("README.md"))
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(!selected.contains("src/a.swift"))
        #expect(!selected.contains("src/b.swift"))
        #expect(selected.contains("README.md"))
    }

    private func entry(
        path: String,
        type: String,
        mode: String,
        sha: String,
        size: Int? = nil
    ) -> GitHubGitTreeEntryDTO {
        GitHubGitTreeEntryDTO(path: path, mode: mode, type: type, sha: sha, size: size, url: nil)
    }
}

@Suite("RepoFileTypeIcon")
struct RepoFileTypeIconTests {

    private static let code = "chevron.left.forwardslash.chevron.right"

    @Test("常见扩展名映射到对应类型图标，大小写不敏感")
    func mapsCommonExtensions() {
        #expect(RepoFileTypeIcon.symbolName(forFileName: "eslint.config.js") == Self.code)
        #expect(RepoFileTypeIcon.symbolName(forFileName: "main.SWIFT") == Self.code)
        #expect(RepoFileTypeIcon.symbolName(forFileName: "README.md") == "doc.richtext")
        #expect(RepoFileTypeIcon.symbolName(forFileName: "logo.png") == "photo")
        #expect(RepoFileTypeIcon.symbolName(forFileName: "dist.tar.gz") == "doc.zipper")
        #expect(RepoFileTypeIcon.symbolName(forFileName: "alert.mp3") == "waveform")
        #expect(RepoFileTypeIcon.symbolName(forFileName: "demo.mov") == "film")
    }

    @Test("dotfile 取点号后的整段当扩展名，无扩展名走整名匹配")
    func mapsDotfilesAndBareNames() {
        #expect(RepoFileTypeIcon.symbolName(forFileName: ".gitignore") == Self.code)
        #expect(RepoFileTypeIcon.symbolName(forFileName: "Makefile") == Self.code)
        #expect(RepoFileTypeIcon.symbolName(forFileName: "Dockerfile") == Self.code)
        #expect(RepoFileTypeIcon.symbolName(forFileName: "LICENSE") == "doc.richtext")
    }

    @Test("未知类型退回默认 doc 图标")
    func fallsBackToDefault() {
        #expect(RepoFileTypeIcon.symbolName(forFileName: "data.unknownext") == "doc.text")
        #expect(RepoFileTypeIcon.symbolName(forFileName: "") == "doc.text")
    }
}

@Suite("GitLFSPointer")
struct GitLFSPointerTests {
    @Test("标准 pointer 解析 oid 和 size")
    func parsesPointer() {
        let data = Data("""
        version https://git-lfs.github.com/spec/v1
        oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393
        size 12345
        """.utf8)
        let pointer = GitLFSPointer.parse(data)
        #expect(pointer?.oid == "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393")
        #expect(pointer?.size == 12345)
    }

    @Test("普通文本不是 LFS pointer")
    func rejectsPlainText() {
        #expect(GitLFSPointer.parse(Data("hello".utf8)) == nil)
        #expect(GitLFSPointer.parse(Data("version 1\noid sha256:abc\nsize 1".utf8)) == nil)
    }
}

@Suite("GitHubGitTreeDTO 解码")
struct GitHubGitTreeDTOTests {
    @Test("recursive tree 响应解码 truncated 与 blob size")
    func decodesTree() throws {
        let json = #"""
        {
            "sha": "abc123",
            "url": "https://api.github.com/repos/o/r/git/trees/abc123",
            "tree": [
                {
                    "path": "README.md",
                    "mode": "100644",
                    "type": "blob",
                    "sha": "def",
                    "size": 42,
                    "url": "https://api.github.com/repos/o/r/git/blobs/def"
                }
            ],
            "truncated": true
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dto = try decoder.decode(GitHubGitTreeDTO.self, from: json)
        #expect(dto.sha == "abc123")
        #expect(dto.truncated)
        #expect(dto.tree.count == 1)
        #expect(dto.tree[0].path == "README.md")
        #expect(dto.tree[0].size == 42)
    }
}

@Suite("RepoFileDownloader", .serialized)
struct RepoFileDownloaderTests {

    @Test("blob 200：按相对路径写入仓库子目录")
    func writesRelativePath() async throws {
        URLProtocolStub.reset()
        let payload = Data("hello files".utf8)
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloader = RepoFileDownloader(
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        let saved = try await downloader.download(
            owner: "octocat",
            repo: "Hello-World",
            sha: "abc",
            relativePath: "src/hello.txt",
            toRoot: root
        )
        #expect(saved.lastPathComponent == "hello.txt")
        #expect(try Data(contentsOf: saved) == payload)
        #expect(saved.path.hasSuffix("Hello-World/src/hello.txt"))
    }

    @Test("拒绝路径穿越")
    func rejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp")
        #expect(RepoFileDownloader.destinationURL(root: root, repoName: "repo", relativePath: "../secret") == nil)
        #expect(RepoFileDownloader.destinationURL(root: root, repoName: "repo/../x", relativePath: "a.swift") == nil)
        #expect(RepoFileTreeBuilder.isSafeRelativePath("src/../main.swift") == false)
    }

    @Test("blob 是 LFS pointer 时改走 batch 再写下真实内容")
    func resolvesLFSPointer() async throws {
        URLProtocolStub.reset()
        let oid = String(repeating: "ab", count: 32)
        let pointer = Data("""
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size 5
        """.utf8)
        let payload = Data("hello".utf8)
        URLProtocolStub.requestHandler = { request in
            let url = request.url!
            if url.path.contains("/git/blobs/") {
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, pointer)
            }
            if url.path.contains("/info/lfs/objects/batch") {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.git-lfs+json")
                let json = """
                {"objects":[{"oid":"\(oid)","size":5,"actions":{"download":{"href":"https://media.example.test/lfs-object","header":{"Authorization":"RemoteAuth test"}}}}]}
                """
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(json.utf8))
            }
            if url.host == "media.example.test" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "RemoteAuth test")
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, payload)
            }
            Issue.record("unexpected URL \(url.absoluteString)")
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-lfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloader = RepoFileDownloader(
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        let saved = try await downloader.download(
            owner: "octocat",
            repo: "Hello-World",
            sha: "blob",
            relativePath: "weights.bin",
            toRoot: root
        )
        #expect(try Data(contentsOf: saved) == payload)
    }

    @Test("超过预览上限的文件不发起网络请求")
    func skipsLargePreview() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Issue.record("preview should not fetch large files")
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let downloader = RepoFileDownloader(
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        let preview = try await downloader.preview(
            owner: "octocat",
            repo: "Hello-World",
            sha: "big",
            relativePath: "weights.bin",
            hintedSize: RepoFileDownloader.previewByteLimit + 1
        )
        #expect(preview == .tooLarge(byteCount: RepoFileDownloader.previewByteLimit + 1))
    }

    @Test("PNG 按魔数识别为图片，不被 NUL 判成 binary")
    func classifiesPNGAsImage() throws {
        let png = try #require(Self.onePixelPNG())
        let preview = RepoFileDownloader.classifyPreview(png)
        guard case .image(let data) = preview else {
            Issue.record("expected image, got \(String(describing: preview))")
            return
        }
        #expect(data == png)
    }

    @Test("含 NUL 的非图片仍是 binary")
    func classifiesNULPayloadAsBinary() {
        #expect(RepoFileDownloader.classifyPreview(Data([0x00, 0x01, 0x02, 0x03])) == .binary)
    }

    @Test("图片扩展名使用更大的预览上限")
    func imagePathUsesLargerPreviewLimit() {
        #expect(RepoFileDownloader.previewLimit(forPath: "banner.webp") == RepoFileDownloader.imagePreviewByteLimit)
        #expect(RepoFileDownloader.previewLimit(forPath: "src/main.swift") == RepoFileDownloader.previewByteLimit)
    }

    private static func onePixelPNG() -> Data? {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }
}

@Suite("RepoFileBrowserViewModel")
@MainActor
struct RepoFileBrowserViewModelTests {

    @Test("loadTree 成功后可以勾选并下载到指定目录")
    func loadAndDownload() async throws {
        let mock = MockGitHubAPIClient()
        mock.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == "main")
            return GitHubGitTreeDTO(
                sha: "tree",
                truncated: false,
                tree: [
                    GitHubGitTreeEntryDTO(
                        path: "README.md",
                        mode: "100644",
                        type: "blob",
                        sha: "blob1",
                        size: 4,
                        url: nil
                    )
                ]
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: InlineRepoFileDownloader(),
            folderPicker: FixedFolderPicker(url: root),
            treeCache: RepoFileTreeSessionCache()
        )
        await viewModel.loadTree()
        #expect(viewModel.nodes.map(\.name) == ["README.md"])

        viewModel.selectAll()
        #expect(viewModel.selectedCount == 1)
        viewModel.startDownload()
        try await waitUntilFinished(viewModel)

        if case .finished(let saved, let failed, let folder) = viewModel.phase {
            #expect(saved == 1)
            #expect(failed == 0)
            #expect(folder.lastPathComponent == "demo")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        } else {
            Issue.record("expected finished phase, got \(String(describing: viewModel.phase))")
        }
    }

    @Test("切分支会按新 ref 重新拉树并清空勾选")
    func switchingBranchReloadsTree() async throws {
        let mock = MockGitHubAPIClient()
        mock.repositoryGitTreeHandler = { _, _, ref in
            let path = ref == "dev" ? "dev.md" : "README.md"
            return GitHubGitTreeDTO(
                sha: ref,
                truncated: false,
                tree: [
                    GitHubGitTreeEntryDTO(path: path, mode: "100644", type: "blob", sha: "s", size: 1, url: nil)
                ]
            )
        }
        mock.repositoryBranchesHandler = { _, _ in
            [GitHubRepoBranchDTO(name: "main"), GitHubRepoBranchDTO(name: "dev")]
        }

        let viewModel = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: InlineRepoFileDownloader(),
            folderPicker: FixedFolderPicker(url: nil),
            treeCache: RepoFileTreeSessionCache()
        )
        await viewModel.loadTree()
        await viewModel.loadBranches()
        viewModel.selectAll()
        #expect(viewModel.selectedCount == 1)
        #expect(viewModel.nodes.map(\.name) == ["README.md"])

        await viewModel.selectBranch("dev")
        #expect(viewModel.currentRef == "dev")
        #expect(viewModel.nodes.map(\.name) == ["dev.md"])
        #expect(viewModel.selectedCount == 0)
        #expect(viewModel.branches == ["main", "dev"])
    }

    @Test("点文件会写入预览文本")
    func previewsSelectedFile() async throws {
        let mock = MockGitHubAPIClient()
        mock.repositoryGitTreeHandler = { _, _, _ in
            GitHubGitTreeDTO(
                sha: "tree",
                truncated: false,
                tree: [
                    GitHubGitTreeEntryDTO(
                        path: "README.md",
                        mode: "100644",
                        type: "blob",
                        sha: "blob1",
                        size: 4,
                        url: nil
                    )
                ]
            )
        }
        let viewModel = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: PreviewStubDownloader(preview: .text("# hi")),
            folderPicker: FixedFolderPicker(url: nil),
            treeCache: RepoFileTreeSessionCache()
        )
        await viewModel.loadTree()
        let file = try #require(viewModel.nodes.first)
        viewModel.reveal(file)
        for _ in 0..<50 {
            if case .text = viewModel.preview { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(viewModel.previewedPath == "README.md")
        #expect(viewModel.preview == .text("# hi"))
    }

    @Test("同一仓库 ref 再次打开走缓存，刷新才重新拉树")
    func reusesCachedTreeUntilRefresh() async throws {
        let mock = MockGitHubAPIClient()
        let counter = TreeCallCounter()
        mock.repositoryGitTreeHandler = { _, _, _ in
            counter.count += 1
            return GitHubGitTreeDTO(
                sha: "tree-\(counter.count)",
                truncated: false,
                tree: [
                    GitHubGitTreeEntryDTO(
                        path: "README.md",
                        mode: "100644",
                        type: "blob",
                        sha: "blob1",
                        size: 4,
                        url: nil
                    )
                ]
            )
        }
        let cache = RepoFileTreeSessionCache()
        let first = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: InlineRepoFileDownloader(),
            folderPicker: FixedFolderPicker(url: nil),
            treeCache: cache
        )
        await first.loadTree()
        #expect(counter.count == 1)

        let second = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: InlineRepoFileDownloader(),
            folderPicker: FixedFolderPicker(url: nil),
            treeCache: cache
        )
        await second.loadTree()
        #expect(counter.count == 1)
        #expect(second.nodes.map(\.name) == ["README.md"])

        await second.refreshTree()
        #expect(counter.count == 2)
    }

    private func waitUntilFinished(_ viewModel: RepoFileBrowserViewModel) async throws {
        for _ in 0..<50 {
            if case .finished = viewModel.phase { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("download did not finish")
    }
}

private final class TreeCallCounter: @unchecked Sendable {
    var count = 0
}

private struct FixedFolderPicker: RepoFileFolderPicking {
    let url: URL?
    @MainActor func pickFolder() -> URL? { url }
}

private struct InlineRepoFileDownloader: RepoFileDownloading {
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard let destination = RepoFileDownloader.destinationURL(
            root: root,
            repoName: repo,
            relativePath: relativePath
        ) else {
            throw RepoFileDownloadError.unsafePath
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: destination)
        onProgress?(1)
        return destination
    }
}

private struct PreviewStubDownloader: RepoFileDownloading {
    let preview: RepoFilePreview

    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        throw RepoFileDownloadError.emptyResponse
    }

    func preview(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        hintedSize: Int?
    ) async throws -> RepoFilePreview {
        preview
    }
}
