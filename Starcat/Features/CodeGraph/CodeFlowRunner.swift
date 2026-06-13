//
//  CodeFlowRunner.swift
//  Starcat
//
//  CodeFlow 集成流水线：URLSession 下载 GitHub ZIP archive，缓存到应用容器，
//  再把 ZIP 注入 vendored CodeFlow HTML，由页面内置 JSZip 自动解压和分析。
//

import Foundation

enum CodeFlowError: LocalizedError, Sendable {
    case privateRepository
    case invalidArchiveURL
    case downloadFailed(statusCode: Int)
    case archiveTooLarge
    case emptyArchive
    case templateMissing
    case invalidTemplate

    var errorDescription: String? {
        switch self {
        case .privateRepository: return "首版代码图谱仅支持公开仓库。"
        case .invalidArchiveURL: return "无法生成 GitHub ZIP 下载地址。"
        case .downloadFailed(let statusCode): return "下载仓库 ZIP 失败（HTTP \(statusCode)）。"
        case .archiveTooLarge: return "仓库 ZIP 超过当前 100 MB 下载上限。"
        case .emptyArchive: return "GitHub 返回了空的 ZIP 文件。"
        case .templateMissing: return "Starcat 安装包中缺少 CodeFlow 页面。"
        case .invalidTemplate: return "CodeFlow 页面缺少 Starcat ZIP 注入入口。"
        }
    }
}

protocol CodeFlowArchiveDownloading: Sendable {
    func download(from url: URL) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionCodeFlowArchiveDownloader: CodeFlowArchiveDownloading {
    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding

    init(
        session: URLSession = .shared,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func download(from url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}

struct CodeFlowRunner {
    static let maximumArchiveBytes = 100_000_000

    private let downloader: any CodeFlowArchiveDownloading
    private let fileManager: FileManager

    init(
        downloader: any CodeFlowArchiveDownloading = URLSessionCodeFlowArchiveDownloader(),
        fileManager: FileManager = .default
    ) {
        self.downloader = downloader
        self.fileManager = fileManager
    }

    /// 下载公开仓库 ZIP。已有缓存时直接复用，保持“不判断分支和更新”的最短链路。
    func archiveIfNeeded(repo: Repo) async throws -> (URL, wasDownloaded: Bool) {
        guard !repo.isPrivate else { throw CodeFlowError.privateRepository }
        let archiveURL = try archiveFileURL(owner: repo.owner, name: repo.name)
        if fileManager.fileExists(atPath: archiveURL.path) {
            return (archiveURL, false)
        }

        guard let encodedOwner = repo.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedName = repo.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let downloadURL = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedName)/zipball") else {
            throw CodeFlowError.invalidArchiveURL
        }
        let (data, response) = try await downloader.download(from: downloadURL)
        guard (200...299).contains(response.statusCode) else {
            throw CodeFlowError.downloadFailed(statusCode: response.statusCode)
        }
        guard !data.isEmpty else { throw CodeFlowError.emptyArchive }
        guard data.count <= Self.maximumArchiveBytes else { throw CodeFlowError.archiveTooLarge }

        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: archiveURL, options: .atomic)
        return (archiveURL, true)
    }

    func makeVisualizationPage(archiveURL: URL, owner: String, name: String) throws -> URL {
        guard let templateURL = Bundle.main.url(forResource: "codeflow", withExtension: "html", subdirectory: "CodeFlow")
            ?? Bundle.main.url(forResource: "codeflow", withExtension: "html") else {
            throw CodeFlowError.templateMissing
        }
        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        guard !archiveData.isEmpty else { throw CodeFlowError.emptyArchive }
        guard archiveData.count <= Self.maximumArchiveBytes else { throw CodeFlowError.archiveTooLarge }

        var html = try String(contentsOf: templateURL, encoding: .utf8)
        let token = "__STARCAT_CODEFLOW_ZIP_PAYLOAD_TOKEN__"
        guard html.contains(token) else { throw CodeFlowError.invalidTemplate }
        html = html.replacingOccurrences(of: token, with: archiveData.base64EncodedString())

        let outputURL = try visualizationDirectory(owner: owner, name: name)
            .appendingPathComponent("index.html", isDirectory: false)
        try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    func archiveFileURL(owner: String, name: String) throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("archives/github.com", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("\(name).zip", isDirectory: false)
    }

    private func visualizationDirectory(owner: String, name: String) throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("codeflow", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func applicationSupportDirectory() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Starcat", isDirectory: true)
    }
}
