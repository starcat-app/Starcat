//
//  SharedSnapshotService.swift
//  Starcat
//
//  CodeFlow 与 RepoContextPacker 共用的 GitHub 源码 ZIP 下载层（W1，2026-06-13）。
//
//  设计目标：把"按 commit SHA 拉取 + 缓存仓库源码 ZIP"这件事从 `CodeFlowRunner`
//  抽出来，让两条 pipeline（CodeFlow 代码图谱 / RepoContextPacker AI 上下文）共用
//  同一份 ZIP 缓存目录、同款上限、同款错误分类。
//
//  关键不变量（与 §0.2 W1/W2 决议对齐）：
//    1. ZIP 缓存统一复用 CodeFlow 旧目录：
//       `Application Support/Starcat/archives/github.com/<owner>/<repo>.zip`。
//       RepoContextPacker 不再维护第二份 `repository-snapshots` 下载缓存。
//    2. 默认 100MB 安全上限不变；AI 代码上下文可为单次请求传入更低的用户阈值。
//    3. 错误自治：`SharedSnapshotError` 与 `CodeFlowError` 各自独立，CodeFlowRunner
//       在 catch SharedSnapshotError 时映射成 CodeFlowError 保持现有文案不变。
//    4. 私有仓库：`repo.isPrivate` 时**直接抛** `.privateRepository`——这是 GitHub
//       OAuth scope 限制（`public_repo`），上层应在调用前做开关 / scope 检查。
//
//  关键设计选择（已踩过的坑级）：
//    - **协议复用而不是改名**：内部继续用 `CodeFlowGitHubProviding` /
//      `CodeFlowArchiveDownloading`（保留在 CodeFlowRunner.swift 内定义），避免一次
//      大改名引入大量 mock 重写。两套协议都是"抽象 ZIP 下载 / 拉分支"，名字带 CodeFlow
//      只是历史原因，等后续 V2 再统一改名（技术债 D-?）。
//    - **error mapping 在 SharedSnapshotService 内做**：协议层抛的是 CodeFlowError，
//      service 内部 catch 后映射成 SharedSnapshotError，对外只暴露 SharedSnapshotError；
//      让 CodeFlowRunner 这层（W2）做反向映射回 CodeFlowError 保持现有 UI 文案。
//    - **archiveFileURL 是 throws 而不是 throws SharedSnapshotError**：路径生成只会失败
//       于 application support directory 不可用（极少触发的 macOS 异常），这种情况让
//       FileManager 自身错误冒出来即可，不需要硬塞进 SharedSnapshotError 5 个 case 里。
//

import Foundation

/// 共享 ZIP 下载层的错误。
///
/// 与 `CodeFlowError` 一一对齐（除掉 CodeFlow 特有的 templateMissing / invalidTemplate /
/// branchMissing），让 `CodeFlowRunner` 在 catch SharedSnapshotError 时能直接 1:1 映射。
enum SharedSnapshotError: LocalizedError, Sendable {
    case privateRepository
    case invalidGitHubURL
    case requestFailed(statusCode: Int)
    case archiveTooLarge
    case emptyArchive
    case branchNotFound(String)

    var errorDescription: String? {
        switch self {
        case .privateRepository:
            return String.l10n("snapshot.error.privateRepository")
        case .invalidGitHubURL:
            return String.l10n("snapshot.error.invalidGitHubURL")
        case .requestFailed(let statusCode):
            return String(format: String.l10n("snapshot.error.requestFailedFormat"), statusCode)
        case .archiveTooLarge:
            return String.l10n("snapshot.error.archiveTooLarge")
        case .emptyArchive:
            return String.l10n("snapshot.error.emptyArchive")
        case .branchNotFound(let name):
            return String(format: String.l10n("snapshot.error.branchNotFoundFormat"), name)
        }
    }
}

/// CodeFlow / RepoContextPacker 共用的"GitHub 源码 ZIP"下载缓存层。
///
/// 用法：
/// ```swift
/// let service = SharedSnapshotService()
/// let branch = try await service.resolveBranch(repo: repo, name: "main")
/// let archive = try await service.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)
/// // archive.url → 给 RepoContextPacker 当 zipURL
/// ```
/// `FileManager` 只是不可变依赖入口；调用方可能把本服务保存在 MainActor ViewModel 中，
/// Swift 6 需要它能跨 async 边界传递，因此在服务边界局部声明 unchecked Sendable。
struct SharedSnapshotService: @unchecked Sendable {

    /// ZIP 单文件大小上限（与 CodeFlow `CodeFlowRunner.maximumArchiveBytes` 保持一致）。
    static let maximumArchiveBytes = 100_000_000

    private let downloader: any CodeFlowArchiveDownloading
    private let github: any CodeFlowGitHubProviding
    private let fileManager: FileManager

    init(
        downloader: (any CodeFlowArchiveDownloading)? = nil,
        github: (any CodeFlowGitHubProviding)? = nil,
        fileManager: FileManager = .default
    ) {
        let client = URLSessionCodeFlowGitHubClient()
        self.downloader = downloader ?? client
        self.github = github ?? client
        self.fileManager = fileManager
    }

    // MARK: - 分支接口（GitHub API 透传 + 错误映射）

    func branches(repo: Repo) async throws -> [CodeFlowBranch] {
        guard !repo.isPrivate else { throw SharedSnapshotError.privateRepository }
        do {
            return try await github.branches(owner: repo.owner, repo: repo.name)
        } catch let error as CodeFlowError {
            throw Self.mapCodeFlowError(error)
        }
    }

    func resolveBranch(repo: Repo, name: String) async throws -> CodeFlowBranch {
        guard !repo.isPrivate else { throw SharedSnapshotError.privateRepository }
        do {
            return try await github.branch(owner: repo.owner, repo: repo.name, name: name)
        } catch let error as CodeFlowError {
            throw Self.mapCodeFlowError(error)
        }
    }

    // MARK: - ZIP 下载（仓库级路径 + commit 内容校验）

    /// 共享源码快照沿用 CodeFlow 的仓库级 ZIP 路径。
    ///
    /// 旧缓存只按 `<owner>/<repo>.zip` 命名，因此不能只凭“文件存在”判断命中。GitHub
    /// zipball 的首个目录名包含 7 位 commit SHA；只有它与请求 SHA 匹配时才复用，避免
    /// 分支 HEAD 更新后把旧源码误标成新提交。任何下游都不得主动删除这个共享 ZIP。
    func archiveIfNeeded(
        repo: Repo,
        commitSHA: String,
        maximumBytes: Int = Self.maximumArchiveBytes,
        beforeDownload: (@Sendable () async throws -> Void)? = nil
    ) async throws -> CodeFlowArchiveResult {
        guard !repo.isPrivate else { throw SharedSnapshotError.privateRepository }
        let archiveURL = try archiveFileURL(owner: repo.owner, name: repo.name, commitSHA: commitSHA)
        if fileManager.fileExists(atPath: archiveURL.path) {
            let bytes = try fileSize(archiveURL)
            guard bytes > 0 else { throw SharedSnapshotError.emptyArchive }
            if try archiveMatchesCommit(at: archiveURL, commitSHA: commitSHA) {
                // 阈值也必须约束缓存命中。否则用户降低设置后，同一个大 ZIP 会绕过下载后校验，
                // 继续进入解压和打包，造成“设置已改但没有生效”的错觉。
                guard bytes <= Int64(maximumBytes) else { throw SharedSnapshotError.archiveTooLarge }
                return CodeFlowArchiveResult(url: archiveURL, wasDownloaded: false, bytes: bytes)
            }
        }

        // 只有确认本地 ZIP 不可复用后才进入门控。单仓摘要在这里展示下载步骤并提供
        // 3 秒取消缓冲；CodeFlow / RAG 等调用方不传闭包，行为与性能保持不变。
        try await beforeDownload?()

        let encodedOwner = Self.encodePathComponent(repo.owner)
        let encodedName = Self.encodePathComponent(repo.name)
        let encodedSHA = Self.encodePathComponent(commitSHA)
        guard let downloadURL = URL(string: "https://api.github.com/repos/\(encodedOwner)/\(encodedName)/zipball/\(encodedSHA)") else {
            throw SharedSnapshotError.invalidGitHubURL
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await downloader.download(from: downloadURL)
        } catch let error as CodeFlowError {
            throw Self.mapCodeFlowError(error)
        }
        guard (200...299).contains(response.statusCode) else {
            throw SharedSnapshotError.requestFailed(statusCode: response.statusCode)
        }
        guard !data.isEmpty else { throw SharedSnapshotError.emptyArchive }
        guard data.count <= maximumBytes else { throw SharedSnapshotError.archiveTooLarge }

        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = archiveURL.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporaryURL)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        // 旧仓库级缓存可能属于另一个 commit。新 ZIP 完整落到临时文件后再替换，
        // 避免下载失败时提前丢掉仍可供旧产物使用的缓存。
        if fileManager.fileExists(atPath: archiveURL.path) {
            _ = try fileManager.replaceItemAt(archiveURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        }
        return CodeFlowArchiveResult(url: archiveURL, wasDownloaded: true, bytes: Int64(data.count))
    }

    /// 共享 ZIP 缓存路径：`Application Support/Starcat/archives/github.com/<owner>/<name>.zip`。
    /// `commitSHA` 保留在签名中，避免改动现有 caller；提交一致性由 ZIP 内容校验保证。
    func archiveFileURL(owner: String, name: String, commitSHA: String) throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("archives/github.com", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("\(name).zip", isDirectory: false)
    }

    /// 清理当前仓库 ZIP 下载的未完成临时文件。
    ///
    /// `archiveIfNeeded` 只有在完整响应通过校验后才会把 `<repo>.zip.tmp` 替换成正式
    /// `<repo>.zip`。用户点击「停止」时只删除 `.tmp`，明确不碰正式 ZIP：正式文件可能
    /// 是上一次成功生成留下的共享缓存，CodeFlow / RepoContextPacker 后续仍可复用。
    func cleanupTemporaryArchive(owner: String, name: String) {
        guard let archiveURL = try? archiveFileURL(owner: owner, name: name, commitSHA: "") else { return }
        try? fileManager.removeItem(at: archiveURL.appendingPathExtension("tmp"))
    }

    // MARK: - 内部工具

    private func applicationSupportDirectory() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Starcat", isDirectory: true)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// 读取 ZIP 第一个 local file header 的文件名，判断 GitHub 根目录中的短 SHA。
    ///
    /// GitHub zipball 的第一项形如 `owner-repo-d187883/`。这里只解析 ZIP 固定头部，
    /// 不解压仓库，也不引入新的 ZIP 依赖。无法识别的旧缓存按未命中处理并重新下载。
    private func archiveMatchesCommit(at url: URL, commitSHA: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4_096) ?? Data()

        guard header.count >= 30,
              Array(header.prefix(4)) == [0x50, 0x4B, 0x03, 0x04] else {
            return false
        }

        let fileNameLength = Int(header[26]) | (Int(header[27]) << 8)
        guard fileNameLength > 0, 30 + fileNameLength <= header.count else { return false }
        let fileNameData = header.subdata(in: 30..<(30 + fileNameLength))
        guard let firstEntry = String(data: fileNameData, encoding: .utf8) else { return false }

        let shortSHA = String(commitSHA.prefix(7)).lowercased()
        return firstEntry.lowercased().contains("-\(shortSHA)/")
    }

    private static func encodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// CodeFlowError → SharedSnapshotError 一一映射。
    ///
    /// 注意：`CodeFlowGitHubProviding` 自身只抛 5 种 CodeFlowError case
    /// （`privateRepository` 不会从 client 抛，service 自己抛；`templateMissing` /
    /// `invalidTemplate` / `branchMissing` 是 CodeFlow 业务层独有）。所以 default 分支
    /// 理论上不会触发，给 .requestFailed(statusCode: -1) 做兜底（说明上游 client 有
    /// 未预期的错误类型，需要后续排查）。
    private static func mapCodeFlowError(_ error: CodeFlowError) -> SharedSnapshotError {
        switch error {
        case .privateRepository: return .privateRepository
        case .invalidGitHubURL: return .invalidGitHubURL
        case .requestFailed(let statusCode): return .requestFailed(statusCode: statusCode)
        case .archiveTooLarge: return .archiveTooLarge
        case .emptyArchive: return .emptyArchive
        case .branchNotFound(let name): return .branchNotFound(name)
        case .templateMissing, .invalidTemplate, .branchMissing:
            // CodeFlow 业务层独有的错误不应从 client 抛出来；兜底成 -1 让上游能定位异常。
            return .requestFailed(statusCode: -1)
        }
    }
}
