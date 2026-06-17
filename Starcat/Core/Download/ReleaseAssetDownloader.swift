//
//  ReleaseAssetDownloader.swift
//  Starcat
//
//  Release 资产应用内下载（HOM-47 第 9 子项）。
//
//  职责：
//  - 从 GitHub `browser_download_url` 或 REST Asset API 拉取二进制并写入调用方指定路径
//  - 大文件走 `URLSession.download` 落临时文件再 move，避免整包进内存
//
//  关键约束：
//  - 必须挂 `GitHubAuthRedirectDelegate`：api.github.com 301 时保留 Authorization（D-25）
//  - Asset API 需 `Accept: application/octet-stream`；browser URL 不加该头
//  - 403/404 时按顺序尝试下一数据源（browser → apiUrl）
//

import Foundation

// MARK: - Errors

enum ReleaseAssetDownloadError: LocalizedError, Equatable {
    case invalidURL
    case httpStatus(Int)
    case emptyResponse
    case moveFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("releases.download.error.invalidURL")
        case .httpStatus(let code):
            return String(format: String.l10n("releases.download.error.httpFormat"), code)
        case .emptyResponse:
            return String.l10n("releases.download.error.empty")
        case .moveFailed:
            return String.l10n("releases.download.error.moveFailed")
        }
    }
}

// MARK: - Protocol

/// 下载抽象，单测注入 fake 实现。
protocol ReleaseAssetDownloading: Sendable {
    func download(asset: ReleaseAsset, to destination: URL) async throws
}

// MARK: - Downloader

/// GitHub Release 资产下载器。无状态 actor，每次调用独立。
actor ReleaseAssetDownloader: ReleaseAssetDownloading {

    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding

    init(
        session: URLSession? = nil,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.session = session ?? Self.makeDefaultSession()
        self.tokenProvider = tokenProvider
    }

    func download(asset: ReleaseAsset, to destination: URL) async throws {
        let token = await tokenProvider.currentToken()
        var lastError: Error?

        for source in Self.downloadSources(for: asset) {
            do {
                try await download(from: source, token: token, to: destination)
                return
            } catch {
                lastError = error
                AppLog.network.debug(
                    "Release asset download fallback: \(source.label, privacy: .public) failed — \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw lastError ?? ReleaseAssetDownloadError.emptyResponse
    }

    // MARK: - Internal

    private struct DownloadSource: Sendable {
        let url: URL
        let useOctetStreamAccept: Bool
        let label: String
    }

    private static func makeDefaultSession() -> URLSession {
        URLSession(
            configuration: .default,
            delegate: GitHubAuthRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private static func downloadSources(for asset: ReleaseAsset) -> [DownloadSource] {
        var sources: [DownloadSource] = []
        if let browser = URL(string: asset.browserDownloadUrl) {
            sources.append(DownloadSource(url: browser, useOctetStreamAccept: false, label: "browser"))
        }
        if let api = asset.apiUrl.flatMap(URL.init(string:)) {
            sources.append(DownloadSource(url: api, useOctetStreamAccept: true, label: "api"))
        }
        return sources
    }

    private func download(
        from source: DownloadSource,
        token: String?,
        to destination: URL
    ) async throws {
        var request = URLRequest(url: source.url)
        request.httpMethod = "GET"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        if source.useOctetStreamAccept {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request)
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
            throw ReleaseAssetDownloadError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ReleaseAssetDownloadError.httpStatus(http.statusCode)
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            AppLog.network.error("Release asset move failed: \(error.localizedDescription, privacy: .public)")
            throw ReleaseAssetDownloadError.moveFailed
        }

        AppLog.network.info(
            "Release asset saved: \(destination.lastPathComponent, privacy: .public) (\(http.statusCode, privacy: .public))"
        )
    }
}
