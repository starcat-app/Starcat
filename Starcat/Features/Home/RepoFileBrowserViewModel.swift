//
//  RepoFileBrowserViewModel.swift
//  Starcat
//
//  详情页「下载文件」Sheet 的状态机：拉树、勾选、预览、切分支、按 blob SHA 并发下载。
//
//  关键约束：
//  - 树请求和下载都挂在 View 的 `.task` / 本类 Task 上，关 Sheet 必须取消，避免写到已失效的安全作用域目录；
//  - 并发上限 4：GitHub 对 raw/blob 也计 REST 配额，不能按文件数无界 fan-out；
//  文件树走进程内缓存：关 Sheet 再开不重复打 Trees API；刷新按钮才强制拉网。
//

import AppKit
import Foundation
import SwiftUI

protocol RepoFileFolderPicking: Sendable {
    @MainActor func pickFolder() -> URL?
}

struct NSOpenPanelRepoFileFolderPicker: RepoFileFolderPicking {
    @MainActor
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String.l10n("repo.files.chooseFolder.prompt")
        panel.message = String.l10n("repo.files.chooseFolder.message")
        panel.title = String.l10n("repo.files.chooseFolder.title")
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }
}

@MainActor
@Observable
final class RepoFileBrowserViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        case downloading(completed: Int, total: Int)
        case finished(saved: Int, failed: Int, folder: URL)
    }

    let target: RepoFileBrowserTarget
    private(set) var currentRef: String
    private(set) var phase: Phase = .loading
    private(set) var nodes: [RepoFileNode] = []
    private(set) var isTruncated = false
    private(set) var branches: [String] = []
    private(set) var previewedPath: String?
    private(set) var preview: PreviewPhase = .idle
    private(set) var previewCommit: GitHubCommitSummaryDTO?
    private(set) var isRefreshing = false
    var selectedPaths: Set<String> = []
    var searchQuery: String = ""
    var sidebarTab: SidebarTab = .files
    var toastMessage: String?
    var toastFileURL: URL?

    private let apiClient: any GitHubAPIClientProtocol
    private let downloader: any RepoFileDownloading
    private let folderPicker: any RepoFileFolderPicking
    private let treeCache: RepoFileTreeSessionCache
    private var downloadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    enum SidebarTab: Hashable {
        case files
        case folders
    }

    enum PreviewPhase: Equatable {
        case idle
        case loading
        case text(String)
        case image(Data)
        case binary
        case tooLarge(Int)
        case gitLFS(Int)
        case failed(String)
    }

    var displayedNodes: [RepoFileNode] {
        let filtered = RepoFileTreeBuilder.filtered(nodes, matching: searchQuery)
        switch sidebarTab {
        case .files: return filtered
        case .folders: return RepoFileTreeBuilder.foldersOnly(filtered)
        }
    }

    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var branchPickerNames: [String] {
        if branches.contains(currentRef) { return branches }
        return [currentRef] + branches
    }

    var previewedFile: RepoFileNode? {
        guard let previewedPath else { return nil }
        return RepoFileTreeBuilder.find(path: previewedPath, in: nodes)
    }

    var previewLineCount: Int? {
        if case .text(let content) = preview {
            return content.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        return nil
    }

    var previewText: String? {
        if case .text(let content) = preview { return content }
        return nil
    }

    var previewImageData: Data? {
        if case .image(let data) = preview { return data }
        return nil
    }

    var githubBlobURL: URL? {
        fileWebURL(kind: .blob)
    }

    var githubRawURL: URL? {
        fileWebURL(kind: .raw)
    }

    var selectedCount: Int { selectedPaths.count }

    var canDownload: Bool {
        switch phase {
        case .ready, .finished: return !selectedPaths.isEmpty
        default: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    init(
        target: RepoFileBrowserTarget,
        apiClient: any GitHubAPIClientProtocol,
        downloader: (any RepoFileDownloading)? = nil,
        folderPicker: any RepoFileFolderPicking = NSOpenPanelRepoFileFolderPicker(),
        treeCache: RepoFileTreeSessionCache = .shared
    ) {
        self.target = target
        self.currentRef = target.ref
        self.apiClient = apiClient
        self.downloader = downloader ?? RepoFileDownloader()
        self.folderPicker = folderPicker
        self.treeCache = treeCache
    }

    func loadTree() async {
        resetPreviewAndSelection()
        await fetchTree(force: false)
    }

    /// 用户点刷新：必须打网并写回缓存。已有列表时不整页 loading，避免把预览栏收掉。
    func refreshTree() async {
        guard !isDownloading, !isRefreshing else { return }
        await fetchTree(force: true)
    }

    func loadBranches() async {
        do {
            let names = try await apiClient.repositoryBranches(
                owner: target.owner,
                repo: target.name
            ).map(\.name)
            branches = names
        } catch is CancellationError {
            return
        } catch {
            branches = []
        }
    }

    func selectBranch(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentRef, !isDownloading, !isRefreshing else { return }
        currentRef = trimmed
        await loadTree()
    }

    func reveal(_ node: RepoFileNode) {
        guard !node.isDirectory, let sha = node.blobSHA else { return }
        previewTask?.cancel()
        previewedPath = node.path
        preview = .loading
        previewCommit = nil
        previewTask = Task { [weak self] in
            await self?.loadPreview(path: node.path, sha: sha, hintedSize: node.size)
        }
    }

    func toggle(_ node: RepoFileNode) {
        guard !isDownloading else { return }
        RepoFileTreeBuilder.toggle(node, in: &selectedPaths)
    }

    func selectAll() {
        guard !isDownloading else { return }
        selectedPaths = Set(displayedNodes.flatMap(RepoFileTreeBuilder.descendantFilePaths(of:)))
    }

    func deselectAll() {
        guard !isDownloading else { return }
        selectedPaths = []
    }

    func startDownload() {
        guard canDownload, downloadTask == nil else { return }
        let files = selectedFiles()
        guard !files.isEmpty else { return }
        beginDownload(files)
    }

    func startDownloadPreviewed() {
        guard !isDownloading, downloadTask == nil else { return }
        guard let file = previewedFile, let sha = file.blobSHA else { return }
        beginDownload([PendingFile(path: file.path, sha: sha)])
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = phase {
            phase = .ready
        }
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
        previewTask?.cancel()
        previewTask = nil
    }

    private func fetchTree(force: Bool) async {
        let showFullLoading = nodes.isEmpty
        if showFullLoading {
            phase = .loading
        } else {
            isRefreshing = true
        }

        do {
            let cacheGeneration = await treeCache.currentGeneration()
            let commit = try await apiClient.repositoryLatestCommit(
                owner: target.owner, repo: target.name, path: "", ref: currentRef
            )
            let dto = try await treeCache.load(
                owner: target.owner, repo: target.name, ref: commit?.sha ?? currentRef,
                scope: apiClient.fileTreeCacheScope, api: apiClient, force: force,
                expectedGeneration: cacheGeneration
            )
            apply(dto)
            pruneSelectionAndPreview()
        } catch is CancellationError {
            isRefreshing = false
            return
        } catch let error as NetworkError {
            if showFullLoading {
                phase = .failed(Self.message(for: error))
            } else {
                toastFileURL = nil
                toastMessage = Self.message(for: error)
            }
        } catch {
            if showFullLoading {
                phase = .failed(String.l10n("repo.files.failed"))
            } else {
                toastFileURL = nil
                toastMessage = String.l10n("repo.files.failed")
            }
        }
        isRefreshing = false
    }

    private func apply(_ dto: GitHubGitTreeDTO) {
        nodes = RepoFileTreeBuilder.build(from: dto.tree)
        isTruncated = dto.truncated
        if !isDownloading {
            phase = .ready
        }
    }

    private func resetPreviewAndSelection() {
        previewTask?.cancel()
        previewTask = nil
        previewedPath = nil
        preview = .idle
        previewCommit = nil
        selectedPaths = []
    }

    /// 刷新后丢掉已经不存在的勾选和预览，剩下的勾选继续有效。
    private func pruneSelectionAndPreview() {
        let valid = Set(nodes.flatMap(RepoFileTreeBuilder.descendantFilePaths(of:)))
        selectedPaths = selectedPaths.intersection(valid)
        if let path = previewedPath, !valid.contains(path) {
            previewTask?.cancel()
            previewTask = nil
            previewedPath = nil
            preview = .idle
            previewCommit = nil
        }
    }

    private func loadPreview(path: String, sha: String, hintedSize: Int?) async {
        do {
            let result = try await downloader.preview(
                owner: target.owner,
                repo: target.name,
                sha: sha,
                relativePath: path,
                hintedSize: hintedSize
            )
            guard !Task.isCancelled, previewedPath == path else { return }
            switch result {
            case .text(let text):
                preview = .text(text)
            case .image(let data):
                preview = .image(data)
            case .binary:
                preview = .binary
            case .tooLarge(let byteCount):
                preview = .tooLarge(byteCount)
            case .gitLFS(let byteCount):
                preview = .gitLFS(byteCount)
            }
            await loadCommit(for: path)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, previewedPath == path else { return }
            preview = .failed(error.localizedDescription)
        }
    }

    private func loadCommit(for path: String) async {
        do {
            let commit = try await apiClient.repositoryLatestCommit(
                owner: target.owner,
                repo: target.name,
                path: path,
                ref: currentRef
            )
            guard !Task.isCancelled, previewedPath == path else { return }
            previewCommit = commit
        } catch {
            guard previewedPath == path else { return }
            previewCommit = nil
        }
    }

    private func beginDownload(_ files: [PendingFile]) {
        guard let folder = folderPicker.pickFolder() else { return }
        downloadTask = Task { [weak self] in
            await self?.runDownload(files: files, folder: folder)
        }
    }

    private enum FileWebKind { case blob, raw }

    private func fileWebURL(kind: FileWebKind) -> URL? {
        guard let path = previewedPath, RepoFileTreeBuilder.isSafeRelativePath(path) else { return nil }
        let encodedRef = currentRef
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        switch kind {
        case .blob:
            return URL(string: "https://github.com/\(target.owner)/\(target.name)/blob/\(encodedRef)/\(encodedPath)")
        case .raw:
            return URL(string: "https://raw.githubusercontent.com/\(target.owner)/\(target.name)/\(encodedRef)/\(encodedPath)")
        }
    }

    private struct PendingFile {
        let path: String
        let sha: String
    }

    private func selectedFiles() -> [PendingFile] {
        nodes.flatMap(RepoFileTreeBuilder.descendantFilePaths(of:)).compactMap { path in
            guard selectedPaths.contains(path) else { return nil }
            guard let sha = blobSHA(path: path, in: nodes) else { return nil }
            return PendingFile(path: path, sha: sha)
        }
    }

    private func blobSHA(path: String, in nodes: [RepoFileNode]) -> String? {
        for node in nodes {
            if node.path == path { return node.blobSHA }
            if let children = node.children, let sha = blobSHA(path: path, in: children) {
                return sha
            }
        }
        return nil
    }

    private func runDownload(files: [PendingFile], folder: URL) async {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                folder.stopAccessingSecurityScopedResource()
            }
            downloadTask = nil
        }

        phase = .downloading(completed: 0, total: files.count)
        let destinationRoot = folder
        var saved = 0
        var failed = 0
        var firstSavedURL: URL?

        await withTaskGroup(of: FileOutcome.self) { group in
            var nextIndex = 0
            let limit = min(4, files.count)

            func enqueue() {
                guard nextIndex < files.count else { return }
                let file = files[nextIndex]
                nextIndex += 1
                let owner = target.owner
                let repo = target.name
                let downloader = downloader
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let url = try await downloader.download(
                            owner: owner,
                            repo: repo,
                            sha: file.sha,
                            relativePath: file.path,
                            toRoot: destinationRoot
                        )
                        return FileOutcome.saved(url)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed
                    }
                }
            }

            for _ in 0..<limit {
                enqueue()
            }

            for await outcome in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                switch outcome {
                case .saved(let url):
                    saved += 1
                    if firstSavedURL == nil { firstSavedURL = url }
                case .failed:
                    failed += 1
                case .cancelled:
                    group.cancelAll()
                    phase = .ready
                    return
                }
                phase = .downloading(completed: saved + failed, total: files.count)
                enqueue()
            }
        }

        if Task.isCancelled {
            phase = .ready
            return
        }

        let folderURL = destinationRoot.appendingPathComponent(target.name, isDirectory: true)
        phase = .finished(saved: saved, failed: failed, folder: folderURL)
        if saved > 0 {
            toastFileURL = firstSavedURL ?? folderURL
            if failed > 0 {
                toastMessage = String(format: String.l10n("repo.files.partialFailedFormat"), saved, failed)
            } else {
                let displayPath = (folderURL.path as NSString).abbreviatingWithTildeInPath
                toastMessage = String(format: String.l10n("repo.files.savedToFormat"), displayPath)
            }
        } else {
            toastFileURL = nil
            toastMessage = String.l10n("repo.files.downloadFailed")
        }
    }

    private enum FileOutcome {
        case saved(URL)
        case failed
        case cancelled
    }

    private static func message(for error: NetworkError) -> String {
        switch error {
        case .unauthorized:
            return String.l10n("repo.files.error.unauthorized")
        case .rateLimited:
            return String.l10n("repo.files.error.rateLimited")
        case .notFound:
            return String.l10n("repo.files.error.notFound")
        case .cancelled:
            return String.l10n("repo.files.cancelled")
        default:
            return error.localizedDescription
        }
    }
}
