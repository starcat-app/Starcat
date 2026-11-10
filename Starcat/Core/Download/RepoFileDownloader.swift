//
//  RepoFileDownloader.swift
//  Starcat
//
//  按 git blob SHA 把仓库文件写到用户选中的目录。
//
//  与 Release 资产下载器同构：`URLSession.downloadTask` 落临时文件再 move，
//  避免大文件整包进内存。必须挂 `GitHubAuthRedirectDelegate`，否则 GitHub 301
//  改名仓库时会丢掉 Authorization，被 AuthSession 误判成 token 失效。
//
//  下载走 `GET /repos/{owner}/{repo}/git/blobs/{sha}` + raw Accept，而不是
//  Contents JSON：后者对超过 1MB 的文件会截断 content 字段。
//

import Foundation
import AppKit
import Synchronization
import CryptoKit

enum RepoFileDownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsafePath
    case httpStatus(Int)
    case emptyResponse
    case moveFailed
    case lfsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("repo.files.error.invalidURL")
        case .unsafePath:
            return String.l10n("repo.files.error.unsafePath")
        case .httpStatus(let code):
            return String(format: String.l10n("repo.files.error.httpFormat"), code)
        case .emptyResponse:
            return String.l10n("repo.files.error.empty")
        case .moveFailed:
            return String.l10n("repo.files.error.moveFailed")
        case .lfsUnavailable:
            return String.l10n("repo.files.error.lfs")
        }
    }
}

/// 文本 / 图片预览结果。大文件和 LFS 实物不能整包进内存。
enum RepoFilePreview: Equatable, Sendable {
    case text(String)
    case image(Data)
    case binary
    case tooLarge(byteCount: Int)
    case gitLFS(byteCount: Int)
}

protocol RepoFileDownloading: Sendable {
    /// 普通文件校验 Git blob SHA，LFS 实物还需对应原 pointer 的 SHA256 与大小。
    func verifyDownloadedFile(owner: String, repo: String, sha: String, fileURL: URL) async throws -> Bool
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL

    func preview(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        hintedSize: Int?
    ) async throws -> RepoFilePreview
}

extension RepoFileDownloading {
    func verifyDownloadedFile(owner: String, repo: String, sha: String, fileURL: URL) async throws -> Bool {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return RepoFileDownloader.gitBlobSHA(data) == sha
    }
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL
    ) async throws -> URL {
        try await download(
            owner: owner,
            repo: repo,
            sha: sha,
            relativePath: relativePath,
            toRoot: root,
            onProgress: nil
        )
    }

    func preview(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        hintedSize: Int?
    ) async throws -> RepoFilePreview {
        throw RepoFileDownloadError.emptyResponse
    }
}

/// 无状态 actor：每次调用独立，进度回调可能来自 URLSession 私有队列。
actor RepoFileDownloader: RepoFileDownloading {

    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding

    init(
        session: URLSession? = nil,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.session = session ?? Self.makeDefaultSession()
        self.tokenProvider = tokenProvider
    }

    /// 已有下载器会把 LFS pointer 展开为实物；不能拿 pointer 的 Git SHA 与实物直接比较。
    func verifyDownloadedFile(owner: String, repo: String, sha: String, fileURL: URL) async throws -> Bool {
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if Self.gitBlobSHA(bytes) == sha { return true }
        let blob = try await fetchBlobBytes(owner: owner, repo: repo, sha: sha)
        guard Self.gitBlobSHA(blob) == sha, let pointer = GitLFSPointer.parse(blob), pointer.size == bytes.count else { return false }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return digest == pointer.oid
    }

    nonisolated static func gitBlobSHA(_ data: Data) -> String {
        // 分段输入避免为了 Git header 额外复制整个大文件。
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard RepoFileTreeBuilder.isSafeRelativePath(relativePath) else {
            throw RepoFileDownloadError.unsafePath
        }
        guard let destination = Self.destinationURL(root: root, repoName: repo, relativePath: relativePath) else {
            throw RepoFileDownloadError.unsafePath
        }
        let url = AppEndpoints.GitHubREST.url(
            AppEndpoints.GitHubREST.Paths.repoGitBlob(owner: owner, repo: repo, sha: sha)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if tokenProvider.requiresAuthentication {
            throw NetworkError.unauthorized
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await downloadFile(for: request, onProgress: onProgress)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            throw NetworkError.transport(underlying: error)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse else {
            throw RepoFileDownloadError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RepoFileDownloadError.httpStatus(http.statusCode)
        }

        try Task.checkCancellation()
        let sourceURL = try await resolveLFSIfNeeded(tempURL: tempURL, owner: owner, repo: repo)
        try Task.checkCancellation()
        if sourceURL != tempURL {
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            try moveDownloadedFile(from: sourceURL, to: destination)
        } else {
            try moveDownloadedFile(from: tempURL, to: destination)
        }

        onProgress?(1)
        return destination
    }

    /// 文本预览 512KB。图片可到 8MB：banner / screenshot 经常超过半兆，但整图仍小于一次 blob 下载。
    static let previewByteLimit = 512 * 1024
    static let imagePreviewByteLimit = 8 * 1024 * 1024

    func preview(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        hintedSize: Int?
    ) async throws -> RepoFilePreview {
        let limit = Self.previewLimit(forPath: relativePath)
        if let hintedSize, hintedSize > limit {
            return .tooLarge(byteCount: hintedSize)
        }

        let data = try await fetchBlobBytes(owner: owner, repo: repo, sha: sha)
        if data.count > limit, GitLFSPointer.parse(data) == nil {
            return .tooLarge(byteCount: data.count)
        }
        if let pointer = GitLFSPointer.parse(data) {
            if pointer.size > limit {
                return .gitLFS(byteCount: pointer.size)
            }
            let object = try await fetchLFSBytes(owner: owner, repo: repo, pointer: pointer)
            return Self.classifyPreview(object)
        }
        return Self.classifyPreview(data)
    }

    static func destinationURL(root: URL, repoName: String, relativePath: String) -> URL? {
        guard RepoFileTreeBuilder.isSafeRelativePath(relativePath) else { return nil }
        let trimmedName = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              trimmedName != "." && trimmedName != ".." else {
            return nil
        }
        var url = root.appendingPathComponent(trimmedName, isDirectory: true)
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(component)
            guard part != ".." && part != "." else { return nil }
            url.appendPathComponent(part)
        }
        return url
    }

    private static func makeDefaultSession() -> URLSession {
        URLSession(
            configuration: .default,
            delegate: GitHubAuthRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private func downloadFile(
        for request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        // 取消必须传到 URLSession，且在 task 注册前取消时也不能漏掉。
        let taskSlot = Mutex<URLSessionDownloadTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            final class ObservationBox: @unchecked Sendable {
                var observation: NSKeyValueObservation?
            }
            let box = ObservationBox()

            let task = session.downloadTask(with: request) { tempURL, response, error in
                box.observation?.invalidate()
                box.observation = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL, let response else {
                    continuation.resume(throwing: RepoFileDownloadError.emptyResponse)
                    return
                }
                let ownedTemp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("starcat-repo-file-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: ownedTemp)
                    continuation.resume(returning: (ownedTemp, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let onProgress {
                onProgress(0)
                box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    onProgress(min(1, max(0, progress.fractionCompleted)))
                }
            }

                taskSlot.withLock { $0 = task }
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            taskSlot.withLock { $0?.cancel() }
        }
    }

    private func moveDownloadedFile(from source: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            AppLog.network.error("Repo file move failed: \(error.localizedDescription, privacy: .public)")
            throw RepoFileDownloadError.moveFailed
        }
    }

    /// blob 若是 LFS pointer，换成真实对象再交给调用方落盘。
    private func resolveLFSIfNeeded(tempURL: URL, owner: String, repo: String) async throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 1024 else { return tempURL }
        let data = try Data(contentsOf: tempURL)
        guard let pointer = GitLFSPointer.parse(data) else { return tempURL }
        return try await downloadLFSObject(owner: owner, repo: repo, pointer: pointer)
    }

    private func fetchBlobBytes(owner: String, repo: String, sha: String) async throws -> Data {
        let url = AppEndpoints.GitHubREST.url(
            AppEndpoints.GitHubREST.Paths.repoGitBlob(owner: owner, repo: repo, sha: sha)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if tokenProvider.requiresAuthentication {
            throw NetworkError.unauthorized
        }
        return try await data(for: request)
    }

    private func fetchLFSBytes(owner: String, repo: String, pointer: GitLFSPointer) async throws -> Data {
        let action = try await lfsDownloadAction(owner: owner, repo: repo, pointer: pointer)
        var request = URLRequest(url: action.url)
        request.httpMethod = "GET"
        for (key, value) in action.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await data(for: request)
    }

    private func downloadLFSObject(owner: String, repo: String, pointer: GitLFSPointer) async throws -> URL {
        let action = try await lfsDownloadAction(owner: owner, repo: repo, pointer: pointer)
        var request = URLRequest(url: action.url)
        request.httpMethod = "GET"
        for (key, value) in action.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (tempURL, response) = try await downloadFile(for: request, onProgress: nil)
        guard let http = response as? HTTPURLResponse else {
            throw RepoFileDownloadError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RepoFileDownloadError.httpStatus(http.statusCode)
        }
        return tempURL
    }

    private struct LFSDownloadAction {
        let url: URL
        let headers: [String: String]
    }

    private func lfsDownloadAction(
        owner: String,
        repo: String,
        pointer: GitLFSPointer
    ) async throws -> LFSDownloadAction {
        guard let url = GitLFSBatch.batchURL(owner: owner, repo: repo) else {
            throw RepoFileDownloadError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if tokenProvider.requiresAuthentication {
            throw NetworkError.unauthorized
        }
        let body = GitLFSBatch.Request(objects: [
            GitLFSBatch.Request.Object(oid: pointer.oid, size: pointer.size)
        ])
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await data(for: request)
        let decoded = try JSONDecoder().decode(GitLFSBatch.Response.self, from: data)
        guard let object = decoded.objects.first(where: { $0.oid == pointer.oid }) else {
            throw RepoFileDownloadError.lfsUnavailable
        }
        if object.error != nil {
            throw RepoFileDownloadError.lfsUnavailable
        }
        guard let href = object.actions?.download?.href, let downloadURL = URL(string: href) else {
            throw RepoFileDownloadError.lfsUnavailable
        }
        return LFSDownloadAction(url: downloadURL, headers: object.actions?.download?.header ?? [:])
    }

    private func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            throw NetworkError.transport(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RepoFileDownloadError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RepoFileDownloadError.httpStatus(http.statusCode)
        }
        return data
    }

    static func previewLimit(forPath path: String) -> Int {
        isImagePath(path) ? imagePreviewByteLimit : previewByteLimit
    }

    static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imagePathExtensions.contains(ext)
    }

    /// PNG / JPEG / GIF / WebP 等都带 NUL，不能再用 `data.contains(0)` 一刀切成 binary。
    static func classifyPreview(_ data: Data) -> RepoFilePreview {
        if data.count > imagePreviewByteLimit {
            return .tooLarge(byteCount: data.count)
        }
        if looksLikeImage(data), NSImage(data: data)?.isValid == true {
            return .image(data)
        }
        if data.count > previewByteLimit {
            return .tooLarge(byteCount: data.count)
        }
        if data.contains(0) {
            return .binary
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .binary
        }
        return .text(text)
    }

    private static let imagePathExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "tif", "tiff", "heic", "heif", "avif"
    ]

    private static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return true }
        if data.starts(with: Array("BM".utf8)) { return true }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        if data.prefix(4) == Data("RIFF".utf8), data.dropFirst(8).prefix(4) == Data("WEBP".utf8) {
            return true
        }
        if data.dropFirst(4).prefix(4) == Data("ftyp".utf8) {
            let brand = data.dropFirst(8).prefix(4)
            return ["heic", "heif", "mif1", "msf1", "avif"].contains { brand == Data($0.utf8) }
        }
        return false
    }
}
