//
//  SkillEvaluationInstaller.swift
//  Starcat
//
//  为 Direct 版准备独立的 SkillEvaluator 运行环境。只有版本探测通过才发布入口。
//

import CryptoKit
import Foundation

/// 安装目录随 CLI 版本隔离，让 Python 虚拟环境的绝对路径在安装后保持有效。
struct SkillEvaluationInstaller: Sendable {
    enum Stage: Equatable, Sendable {
        case downloading, preparingPython, installingPackage, verifying
    }

    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)

    private static let uvVersion = "0.13.9"
    private static let pythonVersion = "3.13.18"
    private static let downloadLimit = 64 * 1_024 * 1_024
    private let root: URL
    private let download: Download

    init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Starcat/SkillEvaluator", isDirectory: true),
        download: @escaping Download = { url in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 180
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            return try await session.download(from: url)
        }
    ) {
        self.root = root
        self.download = download
    }

    private var versionDirectory: URL {
        root.appendingPathComponent("v\(SkillEvaluationRunner.version)", isDirectory: true)
    }

    /// 这个链接是就绪标记。上次异常退出留下的半成品不会进入自动探测。
    var executable: URL { versionDirectory.appendingPathComponent("skillevaluator") }

    /// 安装失败只清理 CLI 目录。扫描器缓存也能用于手动安装的同版本 CLI。
    var scannerRuntime: URL {
        root.appendingPathComponent("scanners-v\(SkillEvaluationRunner.version)", isDirectory: true)
    }

    @concurrent
    func install(
        progress: @MainActor @Sendable (Stage) -> Void,
        onLog: @escaping SkillEvaluationInstallLog.Sink
    ) async throws -> URL {
        let manager = FileManager.default
        let version = versionDirectory
        await onLog(.detail("Install directory: \(version.path)"))
        try Task.checkCancellation()
        // 浏览期间其他方式已完成受管安装时，不覆盖可用入口。
        if manager.isExecutableFile(atPath: executable.path) {
            await onLog(.detail("Checking existing installation"))
            do {
                try await SkillEvaluationRunner.verifyExecutable(executable, onLog: onLog)
                try Task.checkCancellation()
                return executable
            } catch {
                try Task.checkCancellation()
                await onLog(.detail("Existing installation could not be verified; reinstalling"))
            }
        }
        try Task.checkCancellation()

        if manager.fileExists(atPath: version.path) {
            await onLog(.detail("Removing incomplete installation: \(version.path)"))
            try Task.checkCancellation()
            try manager.removeItem(at: version)
        }
        try manager.createDirectory(at: version, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        do {
            return try await installFresh(in: version, progress: progress, onLog: onLog)
        } catch {
            // 子进程执行器返回前已收完输出和退出状态。此处报告清理结果，保留原始失败原因。
            do {
                try manager.removeItem(at: version)
                await onLog(.detail("Removed incomplete installation: \(version.path)"))
            } catch let cleanupError {
                await onLog(.detail("Cleanup failed: \(cleanupError.localizedDescription)"))
            }
            throw error
        }
    }

    @concurrent
    private func installFresh(
        in version: URL, progress: @MainActor @Sendable (Stage) -> Void,
        onLog: @escaping SkillEvaluationInstallLog.Sink
    ) async throws -> URL {
        let manager = FileManager.default
        let work = version.appendingPathComponent(".setup", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: false)
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": work.path,
            "TMPDIR": work.path,
            "UV_CACHE_DIR": work.appendingPathComponent("cache").path,
            "UV_PYTHON_INSTALL_DIR": version.appendingPathComponent("python").path,
            "UV_NO_CONFIG": "1",
            "UV_NO_PROGRESS": "1",
            "UV_SYSTEM_CERTS": "1",
            "UV_HTTP_TIMEOUT": "45",
        ]

        await progress(.downloading)
        let uv = try await prepareUV(in: work, environment: environment, onLog: onLog)
        await progress(.preparingPython)
        await onLog(.detail("Preparing Python \(Self.pythonVersion)"))
        try await run(uv, ["python", "install", Self.pythonVersion, "--no-bin"], work, environment,
                      timeout: .seconds(240), onLog: onLog)
        let venv = version.appendingPathComponent("venv", isDirectory: true)
        try await run(uv, ["venv", "--managed-python", "--no-python-downloads", "--python", Self.pythonVersion, venv.path],
                      work, environment, timeout: .seconds(30), onLog: onLog)

        await progress(.installingPackage)
        await onLog(.detail("Installing SkillEvaluator \(SkillEvaluationRunner.version)"))
        let interpreter = venv.appendingPathComponent("bin/python").path
        // SkillSpector 由虚拟环境里的 uv 启动。与安装器固定到同一版本，避免后续安装引入未经验证的 CLI。
        try await run(uv, ["pip", "install", "--python", interpreter, "--default-index", "https://pypi.org/simple",
                           "--no-python-downloads", "--only-binary", ":all:",
                           "uv==\(Self.uvVersion)",
                           "skillevaluator[tier2]==\(SkillEvaluationRunner.version)"], work, environment,
                      timeout: .seconds(420), onLog: onLog)
        await progress(.verifying)
        // 先清理临时缓存，再验证和发布，避免在用户仍可取消时长时间清理已提交的安装。
        try Task.checkCancellation()
        do {
            try manager.removeItem(at: work)
            await onLog(.detail("Removed temporary installation files: \(work.path)"))
        } catch {
            await onLog(.detail("Temporary file cleanup failed: \(error.localizedDescription)"))
        }
        let entry = "venv/bin/skillevaluator"
        await onLog(.detail("Verifying installed executable"))
        try await SkillEvaluationRunner.verifyExecutable(version.appendingPathComponent(entry), onLog: onLog)
        await onLog(.detail("Publishing executable: \(executable.path) -> \(entry)"))
        // 链接是提交点。校验失败或发布前取消时，由外层清理整个版本目录。
        try Task.checkCancellation()
        try manager.createSymbolicLink(atPath: executable.path, withDestinationPath: entry)
        return executable
    }

    /// 校验 Astral 发布的固定架构归档；验证通过前不解包，也不执行安装脚本。
    @concurrent
    private func prepareUV(in work: URL, environment: [String: String],
                           onLog: @escaping SkillEvaluationInstallLog.Sink) async throws -> URL {
        #if arch(arm64)
        let platform = "aarch64-apple-darwin"
        let sha256 = "5aeca67f2283f75235de40d0bd9c0a5bbc5fce23b6d48b3bf9fa1b2db08382ca"
        #else
        let platform = "x86_64-apple-darwin"
        let sha256 = "617a3211261b0fc739562f0071aa34e9739797c510208ede8e2977c30903d041"
        #endif
        let archiveURL = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-\(platform).tar.gz")!
        await onLog(.detail("GET \(archiveURL.absoluteString)"))
        try Task.checkCancellation()
        let (archive, response) = try await download(archiveURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        let status = (response as? HTTPURLResponse)?.statusCode
        await onLog(.detail(status.map { "HTTP \($0)" } ?? "Missing HTTP status"))
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        await onLog(.detail("Downloaded \(size) bytes"))
        try Task.checkCancellation()
        guard status == 200, response.url?.scheme == "https", (1...Self.downloadLimit).contains(size) else {
            throw SkillEvaluationFailure("installDownload")
        }
        await onLog(.detail("SHA-256 expected: \(sha256)"))
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        await onLog(.detail("SHA-256 actual:   \(actual)"))
        guard actual == sha256 else {
            throw SkillEvaluationFailure("installChecksum")
        }
        await onLog(.detail("SHA-256 verified"))
        // 只需要已校验归档里的 uv。本次安装用完即清理，不替换本机已有的 uv。
        let member = "uv-\(platform)/uv"
        try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, member],
                      work, environment, timeout: .seconds(30), onLog: onLog)
        return work.appendingPathComponent(member)
    }

    /// 用安排评估时的同一进程组执行器。取消或超时必须等子进程退出，才能删除工作目录。
    @concurrent
    private func run(_ executable: URL, _ arguments: [String], _ work: URL, _ environment: [String: String],
                     timeout: Duration, onLog: @escaping SkillEvaluationInstallLog.Sink) async throws {
        let status = try await SkillEvaluationChild.run(executable, arguments: arguments, environment: environment,
                                                        cwd: work, timeout: timeout, onLog: onLog)
        guard status == 0 else { throw SkillEvaluationFailure("installCommand") }
    }
}
