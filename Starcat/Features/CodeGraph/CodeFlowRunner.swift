//
//  CodeFlowRunner.swift
//  Starcat
//
//  CodeFlow 集成流水线：解析 GitHub 分支 HEAD、复用或下载 commit 固定 ZIP，
//  再把 ZIP 注入 vendored CodeFlow HTML，并通过 CodeFlowStorage 原子保存生成物。
//

import Foundation

enum CodeFlowError: LocalizedError, Sendable {
    case privateRepository
    case invalidGitHubURL
    case requestFailed(statusCode: Int)
    case archiveTooLarge
    case emptyArchive
    case templateMissing
    case invalidTemplate
    case branchMissing
    case branchNotFound(String)

    var errorDescription: String? {
        switch self {
        case .privateRepository:
            return String.l10n("codeFlow.error.privateRepository")
        case .invalidGitHubURL:
            return String.l10n("codeFlow.error.invalidGitHubURL")
        case .requestFailed(let statusCode):
            return String(format: String.l10n("codeFlow.error.requestFailedFormat"), statusCode)
        case .archiveTooLarge:
            return String.l10n("codeFlow.error.archiveTooLarge")
        case .emptyArchive:
            return String.l10n("codeFlow.error.emptyArchive")
        case .templateMissing:
            return String.l10n("codeFlow.error.templateMissing")
        case .invalidTemplate:
            return String.l10n("codeFlow.error.invalidTemplate")
        case .branchMissing:
            return String.l10n("codeFlow.error.branchMissing")
        case .branchNotFound(let name):
            return String(format: String.l10n("codeFlow.error.branchNotFoundFormat"), name)
        }
    }
}

protocol CodeFlowArchiveDownloading: Sendable {
    func download(from url: URL) async throws -> (Data, HTTPURLResponse)
}

protocol CodeFlowGitHubProviding: Sendable {
    func branches(owner: String, repo: String) async throws -> [CodeFlowBranch]
    func branch(owner: String, repo: String, name: String) async throws -> CodeFlowBranch
}

/// CodeFlow 使用独立轻量请求器，避免扩大 GitHubAPIClientProtocol 后让全部测试 mock 跟着改。
struct URLSessionCodeFlowGitHubClient: CodeFlowArchiveDownloading, CodeFlowGitHubProviding {
    private struct BranchDTO: Decodable {
        struct CommitDTO: Decodable { let sha: String }
        let name: String
        let commit: CommitDTO
    }

    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding

    init(
        session: URLSession = .shared,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func branches(owner: String, repo: String) async throws -> [CodeFlowBranch] {
        var page = 1
        var result: [CodeFlowBranch] = []
        while true {
            let url = try apiURL(owner: owner, repo: repo, suffix: "branches", queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ])
            let (data, response) = try await request(url: url)
            guard (200...299).contains(response.statusCode) else {
                throw CodeFlowError.requestFailed(statusCode: response.statusCode)
            }
            let values = try JSONDecoder().decode([BranchDTO].self, from: data)
            result.append(contentsOf: values.map { CodeFlowBranch(name: $0.name, commitSHA: $0.commit.sha) })
            guard values.count == 100 else { break }
            page += 1
        }
        return result
    }

    func branch(owner: String, repo: String, name: String) async throws -> CodeFlowBranch {
        let encodedBranch = Self.encodePathComponent(name)
        let url = try apiURL(owner: owner, repo: repo, suffix: "branches/\(encodedBranch)")
        let (data, response) = try await request(url: url)
        if response.statusCode == 404 { throw CodeFlowError.branchNotFound(name) }
        guard (200...299).contains(response.statusCode) else {
            throw CodeFlowError.requestFailed(statusCode: response.statusCode)
        }
        let value = try JSONDecoder().decode(BranchDTO.self, from: data)
        return CodeFlowBranch(name: value.name, commitSHA: value.commit.sha)
    }

    func download(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await request(url: url)
    }

    private func request(url: URL) async throws -> (Data, HTTPURLResponse) {
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

    private func apiURL(
        owner: String,
        repo: String,
        suffix: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents(string: "https://api.github.com")!
        components.percentEncodedPath = "/repos/\(Self.encodePathComponent(owner))/\(Self.encodePathComponent(repo))/\(suffix)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw CodeFlowError.invalidGitHubURL }
        return url
    }

    /// 分支名允许包含 `/`，必须按单个 path component 编码，不能直接拼进 URL path。
    private static func encodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

struct CodeFlowArchiveResult: Sendable {
    let url: URL
    let wasDownloaded: Bool
    let bytes: Int64
}

@MainActor
struct CodeFlowRunner {

    /// W2 改造（2026-06-13）：分支查询 / ZIP 下载逻辑全部委托给共享服务。
    /// CodeFlowRunner 本身只保留：HTML 模板注入 + storage 写盘 + 业务级 metadata 拼装。
    private let snapshotService: SharedSnapshotService
    private let storage: CodeFlowStorage

    init(
        downloader: (any CodeFlowArchiveDownloading)? = nil,
        github: (any CodeFlowGitHubProviding)? = nil,
        storage: CodeFlowStorage = .shared,
        snapshotService: SharedSnapshotService? = nil,
        fileManager: FileManager = .default
    ) {
        // snapshotService 优先注入；否则用 downloader/github 创建一个新的（向后兼容现有测试的 mock 注入方式）。
        self.snapshotService = snapshotService ?? SharedSnapshotService(
            downloader: downloader,
            github: github,
            fileManager: fileManager
        )
        self.storage = storage
    }

    func branches(repo: Repo) async throws -> [CodeFlowBranch] {
        do {
            return try await snapshotService.branches(repo: repo)
        } catch let error as SharedSnapshotError {
            throw Self.mapSnapshotError(error)
        }
    }

    func resolveBranch(repo: Repo, name: String) async throws -> CodeFlowBranch {
        do {
            return try await snapshotService.resolveBranch(repo: repo, name: name)
        } catch let error as SharedSnapshotError {
            throw Self.mapSnapshotError(error)
        }
    }

    /// 共享源码快照按不可变 commit SHA 命名，CodeFlow 删除或重新生成不得删除它。
    func archiveIfNeeded(
        repo: Repo,
        commitSHA: String,
        maximumBytes: Int
    ) async throws -> CodeFlowArchiveResult {
        do {
            return try await snapshotService.archiveIfNeeded(
                repo: repo,
                commitSHA: commitSHA,
                maximumBytes: maximumBytes
            )
        } catch let error as SharedSnapshotError {
            throw Self.mapSnapshotError(error)
        }
    }

    func makeVisualizationPage(
        archive: CodeFlowArchiveResult,
        repo: Repo,
        branch: CodeFlowBranch,
        startedAt: Date,
        steps: [CodeFlowExecutionStep],
        previousGenerationCount: Int? = nil,
        maximumBytes: Int
    ) throws -> CodeFlowStoredProject {
        guard let templateURL = Bundle.main.url(forResource: "codeflow", withExtension: "html", subdirectory: "CodeFlow")
            ?? Bundle.main.url(forResource: "codeflow", withExtension: "html") else {
            throw CodeFlowError.templateMissing
        }
        let archiveData = try Data(contentsOf: archive.url, options: .mappedIfSafe)
        guard !archiveData.isEmpty else { throw CodeFlowError.emptyArchive }
        guard archiveData.count <= maximumBytes else { throw CodeFlowError.archiveTooLarge }

        var html = try String(contentsOf: templateURL, encoding: .utf8)
        let token = "__STARCAT_CODEFLOW_ZIP_PAYLOAD_TOKEN__"
        guard html.contains(token) else { throw CodeFlowError.invalidTemplate }
        html = html.replacingOccurrences(of: token, with: archiveData.base64EncodedString())

        let storedGenerationCount = try storage.existingProject(owner: repo.owner, name: repo.name)?
            .metadata.generation.generationCount
        let previousCount = previousGenerationCount ?? storedGenerationCount ?? 0
        let finishedAt = Date()
        let pageBytes = Int64(html.utf8.count)
        let metadata = CodeFlowMetadata(
            schemaVersion: 1,
            repository: .init(
                githubID: repo.id,
                owner: repo.owner,
                name: repo.name,
                fullName: repo.fullName,
                htmlURL: repo.htmlUrl
            ),
            artifact: .init(
                page: "index.html",
                pageBytes: pageBytes,
                sourceArchiveBytes: archive.bytes,
                sourceArchiveKey: "github.com/\(repo.owner)/\(repo.name).zip"
            ),
            generation: .init(
                generatedAt: finishedAt,
                generationCount: previousCount + 1,
                lastDurationMilliseconds: Self.milliseconds(from: startedAt, to: finishedAt)
            ),
            sourceRevision: .init(
                branch: branch.name,
                commitSHA: branch.commitSHA,
                commitURL: "https://github.com/\(repo.owner)/\(repo.name)/commit/\(branch.commitSHA)"
            ),
            lastExecution: .init(startedAt: startedAt, finishedAt: finishedAt, steps: steps),
            generator: .init(
                codeFlowCommit: "51ab9708841e14258bebfb5fb326e8b37782d193",
                integrationVersion: 1
            )
        )
        return try storage.write(pageHTML: html, metadata: metadata, owner: repo.owner, name: repo.name)
    }

    func existingProject(owner: String, name: String) throws -> CodeFlowStoredProject? {
        try storage.existingProject(owner: owner, name: name)
    }

    func deleteVisualization(owner: String, name: String) throws {
        try storage.deleteProject(owner: owner, name: name)
    }

    func openVisualization(_ pageURL: URL) throws -> Bool {
        try storage.openPage(pageURL)
    }

    func updateExecution(
        project: CodeFlowStoredProject,
        startedAt: Date,
        steps: [CodeFlowExecutionStep]
    ) throws -> CodeFlowStoredProject {
        let old = project.metadata
        let metadata = CodeFlowMetadata(
            schemaVersion: old.schemaVersion,
            repository: old.repository,
            artifact: old.artifact,
            generation: old.generation,
            sourceRevision: old.sourceRevision,
            lastExecution: .init(startedAt: startedAt, finishedAt: Date(), steps: steps),
            generator: old.generator
        )
        return try storage.updateMetadata(metadata, owner: old.repository.owner, name: old.repository.name)
    }

    func archiveFileURL(owner: String, name: String, commitSHA: String) throws -> URL {
        try snapshotService.archiveFileURL(owner: owner, name: name, commitSHA: commitSHA)
    }

    /// SharedSnapshotError → CodeFlowError 一一映射，保留 CodeFlow UI 现有文案。
    private static func mapSnapshotError(_ error: SharedSnapshotError) -> CodeFlowError {
        switch error {
        case .privateRepository: return .privateRepository
        case .invalidGitHubURL: return .invalidGitHubURL
        case .requestFailed(let statusCode): return .requestFailed(statusCode: statusCode)
        case .archiveTooLarge: return .archiveTooLarge
        case .emptyArchive: return .emptyArchive
        case .branchNotFound(let name): return .branchNotFound(name)
        }
    }

    static func milliseconds(from start: Date, to end: Date = Date()) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}
