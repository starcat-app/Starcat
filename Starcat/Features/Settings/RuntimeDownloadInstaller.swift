//
//  RuntimeDownloadInstaller.swift
//  Starcat
//
//  Direct 外部 Runtime 的固定版本安装入口。下载物先在独立目录完成校验，
//  成功后才交给设置页提交路径；不覆盖全局工具、旧安装或用户索引。
//

import CryptoKit
import Foundation

/// 清单只引用实际验证过的完整官方发布物，不在客户端解析浮动 latest。
enum DownloadableRuntime: String, CaseIterable, Sendable {
    case codex, deepSeek, codebaseMemory

    var displayName: String {
        switch self {
        case .codex: "Codex App Server"
        case .deepSeek: "DeepSeek Harness"
        case .codebaseMemory: "CodebaseMemory"
        }
    }

    var version: String {
        switch self {
        case .codex: "0.167.0"
        case .deepSeek: "0.2.1rc2"
        case .codebaseMemory: "0.12.1"
        }
    }

    var asset: (url: URL, sha256: String) {
        let address: String
        let digest: String
        switch self {
        case .codex:
            #if arch(arm64)
            let target = "aarch64"
            digest = "d9c8a3efdaa422fc2bc7d7bef65cdb9cc04bfbb818a36bbf3ecb70a71ee755eb"
            #else
            let target = "x86_64"
            digest = "392255425f0afe44fad86b7f51b23ecb7a507f8c08c5e5ee616e543de6f9d0db"
            #endif
            address = "https://github.com/openai/codex/releases/download/rust-v0.167.0/codex-app-server-package-\(target)-apple-darwin.tar.gz"
        case .deepSeek:
            // Adapter 仍只在 arm64 开放；不得仅凭上游存在 Intel wheel 就开放产品入口。
            address = "https://files.pythonhosted.org/packages/10/99/723905c63929056e05494e8a659bc8eb9adf671ee6712fb4316930b97ac8/deepseek_harness_runtime_bin-0.2.1rc2-py3-none-macosx_14_0_arm64.whl"
            digest = "96a173abd14141d5328a78791b69729cbfe22fa3e9daf1dc2600d0daa4d6bb28"
        case .codebaseMemory:
            #if arch(arm64)
            let target = "arm64"
            digest = "9bfcbe38414b47969a3e1d1c1999f5357409387c86fa3d24221b5458267660d2"
            #else
            let target = "amd64"
            digest = "ca6e64397a8ae80cec898a8205a6aa16750ac798acc05a0c3ed983837944a581"
            #endif
            address = "https://github.com/DeusData/codebase-memory-mcp/releases/download/v0.12.1/codebase-memory-mcp-ui-darwin-\(target).tar.gz"
        }
        return (URL(string: address)!, digest)
    }

    /// PyPI 文件站在部分网络实测仅约 12 KB/s，90 MB 归档会长时间无反馈
    /// TUNA 只镜像同一固定文件，仍须通过官方 SHA256；不可用时回退官方源
    var downloadURLs: [URL] {
        guard self == .deepSeek else { return [asset.url] }
        var mirror = URLComponents(url: asset.url, resolvingAgainstBaseURL: false)!
        mirror.host = "pypi.tuna.tsinghua.edu.cn"
        return [mirror.url!, asset.url]
    }

    var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        self != .deepSeek
        #endif
    }

    var executableVersion: String {
        self == .deepSeek ? "0.2.1-rc.2" : version
    }
}

/// 安装结果中的路径均指向保留完整资源树的独立目录。
struct RuntimeDownloadInstallation: Sendable {
    let runtime: DownloadableRuntime
    let directory: URL
    let executable: URL
    let configuration: URL?
    let reportedVersion: String
}

enum RuntimeDownloadError: LocalizedError {
    case unavailable, busy, invalidDownload, checksum, invalidLayout(String), process(String), download(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: String.l10n("settings.integration.runtimeDownload.unavailable")
        case .busy: String.l10n("settings.integration.runtimeDownload.busy")
        case .invalidDownload: String.l10n("settings.integration.runtimeDownload.invalidDownload")
        case .checksum: String.l10n("settings.integration.runtimeDownload.checksum")
        case .invalidLayout(let detail), .process(let detail), .download(let detail):
            "\(String.l10n("settings.integration.runtimeDownload.failed"))\n\(detail)"
        }
    }
}

/// Actor 只管理安装，不写 UserDefaults。跨窗口重复点击同一工具也只能有一个安装任务。
actor RuntimeDownloadInstaller {
    typealias Download = @Sendable (URLRequest, any URLSessionTaskDelegate) async throws -> (URL, URLResponse)
    static let shared = RuntimeDownloadInstaller()
    private var installing = Set<DownloadableRuntime>()
    private let download: Download

    init(download: @escaping Download = { request, delegate in
        // shared 的资源超时可能持续数天；固定总时限才能让失败源真正回退
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.download(for: request, delegate: delegate)
    }) {
        self.download = download
    }

    /// 版本目录带唯一后缀，失败或取消只删除本次目录，绝不替换正在使用的 Runtime。
    func install(
        _ runtime: DownloadableRuntime,
        channel: DistributionChannel = .current,
        root: URL? = nil,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> RuntimeDownloadInstallation {
        guard channel.isDirect, runtime.isSupported else { throw RuntimeDownloadError.unavailable }
        guard installing.insert(runtime).inserted else { throw RuntimeDownloadError.busy }
        defer { installing.remove(runtime) }

        let manager = FileManager.default
        let destinationRoot = root ?? manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Starcat/Runtimes", isDirectory: true)
        try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let workspace = destinationRoot.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }

        let download = try await downloadArchive(runtime, progress: progress)
        defer { try? manager.removeItem(at: download) }
        try Task.checkCancellation()
        progress(nil)
        let payload = workspace.appendingPathComponent("payload", isDirectory: true)
        try manager.createDirectory(at: payload, withIntermediateDirectories: true)
        if runtime == .deepSeek {
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                   ["-x", "-k", download.path, payload.path], timeout: 120)
        } else {
            _ = try await Self.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                   ["-xzf", download.path, "-C", payload.path], timeout: 120)
        }
        let checked = try await Self.validate(runtime, directory: payload)
        try Task.checkCancellation()
        let installed = destinationRoot.appendingPathComponent(
            "\(runtime.rawValue)-\(runtime.version)-\(UUID().uuidString)", isDirectory: true
        )
        try manager.moveItem(at: payload, to: installed)
        return RuntimeDownloadInstallation(
            runtime: runtime, directory: installed,
            executable: installed.appendingPathComponent(checked.executable.path.replacingOccurrences(of: payload.path + "/", with: "")),
            configuration: checked.configuration.map { installed.appendingPathComponent($0.lastPathComponent) },
            reportedVersion: checked.reportedVersion
        )
    }

    /// 每个来源单独校验、清理；主动取消立即退出，不能误触发另一个来源继续下载
    func downloadArchive(
        _ runtime: DownloadableRuntime,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        var failures: [String] = []
        for url in runtime.downloadURLs {
            try Task.checkCancellation()
            progress(0)
            do {
                let delegate = RuntimeDownloadProgress(report: progress)
                let (archive, response) = try await download(
                    URLRequest(url: url, timeoutInterval: 45), delegate
                )
                do {
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw RuntimeDownloadError.download("HTTP \(status)")
                    }
                    try Self.verifyChecksum(at: archive, expected: runtime.asset.sha256)
                    return archive
                } catch {
                    try? FileManager.default.removeItem(at: archive)
                    throw error
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failures.append("\(url.host ?? ""): \(error.localizedDescription)")
            }
        }
        throw RuntimeDownloadError.download(failures.joined(separator: "\n"))
    }

    /// 流式哈希避免把 100+ MB 的归档复制进主进程内存。
    static func verifyChecksum(at url: URL, expected: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw RuntimeDownloadError.checksum
        }
    }

    /// 用真实入口验证版本与配套文件；DeepSeek 的 profile home 只落在临时目录中。
    static func validate(_ runtime: DownloadableRuntime, directory: URL) async throws -> RuntimeDownloadInstallation {
        let manager = FileManager.default
        let executable: URL
        let helpers: [URL]
        var configuration: URL?
        switch runtime {
        case .codex:
            executable = directory.appendingPathComponent("bin/codex-app-server")
            helpers = ["bin/codex-code-mode-host", "bin/codex-exec-server", "codex-path/rg"]
                .map { directory.appendingPathComponent($0) }
            for path in ["codex-package.json", "codex-resources"] {
                guard manager.fileExists(atPath: directory.appendingPathComponent(path).path) else {
                    throw RuntimeDownloadError.invalidLayout(path)
                }
            }
        case .deepSeek:
            executable = directory.appendingPathComponent(
                "deepseek_harness_runtime/runtime/deepseek-harness-sdk-runtime-macos-arm64"
            )
            helpers = ["-rg", "-spawn-helper"].map { URL(fileURLWithPath: executable.path + $0) }
            for path in ["macos-arm64/downloads.json", "macos-arm64/office-skills"] {
                guard manager.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent(path).path) else {
                    throw RuntimeDownloadError.invalidLayout(path)
                }
            }
            configuration = directory.appendingPathComponent("starcat.cordis.yml")
            try Data(DeepSeekHarnessRuntime.configurationPatch.utf8).write(to: configuration!, options: .atomic)
        case .codebaseMemory:
            executable = directory.appendingPathComponent("codebase-memory-mcp")
            helpers = []
        }
        for file in [executable] + helpers {
            guard manager.fileExists(atPath: file.path) else { throw RuntimeDownloadError.invalidLayout(file.lastPathComponent) }
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            _ = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", file.path])
        }
        let home = directory.appendingPathComponent(".probe-home", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        // CBM_CACHE_DIR 不隔离 daemon rendezvous。使用上游支持的 CBM_RUNTIME_DIR，
        // 且保持路径足够短，避免 Unix socket 路径长度限制；不触碰当前 Agent 的 daemon。
        let runtimeParent = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("cbm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        if runtime == .codebaseMemory {
            try manager.createDirectory(at: runtimeParent, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        }
        defer { if runtime == .codebaseMemory { try? manager.removeItem(at: runtimeParent) } }
        let environment = [
            "HOME": home.path, "DSH_HOME": home.path, "CODEX_HOME": home.path,
            "CBM_CACHE_DIR": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DEEPSEEK_API_KEY": "starcat-installation-probe",
            "DSH_PRIMARY_RUNTIME": "",
            "CBM_RUNTIME_DIR": runtimeParent.path,
        ]
        let version = try await run(executable, ["--version"], environment: environment,
                                    timeout: 15).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.split(whereSeparator: \.isWhitespace).contains(Substring(runtime.executableVersion)) else {
            throw RuntimeDownloadError.invalidLayout(version)
        }
        // initialize 不发送模型请求，也不使用真实用户凭据。设置写入前必须证明协议能启动。
        let arguments: [String]
        let params: [String: Any]
        switch runtime {
        case .codex:
            arguments = ["--listen", "stdio://"]
            params = ["clientInfo": ["name": "starcat_install_probe", "version": "2.0.0"],
                      "capabilities": ["experimentalApi": true]]
        case .deepSeek:
            arguments = ["--profile", "sdk-minimal", "--patch", configuration!.path]
            params = ["cwd": home.path, "provider": DeepSeekHarnessRuntime.defaultProvider,
                      "model": DeepSeekHarnessRuntime.defaultModel, "maxTokens": 64]
        case .codebaseMemory:
            arguments = []
            params = ["protocolVersion": "2024-11-05", "capabilities": [:],
                      "clientInfo": ["name": "starcat_install_probe", "version": "2.0.0"]]
        }
        var frame = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": params,
        ])
        frame.append(0x0A)
        _ = try await run(executable, arguments, environment: environment, timeout: 30,
                          input: frame, responseID: 1)
        return RuntimeDownloadInstallation(runtime: runtime, directory: directory,
                                           executable: executable, configuration: configuration, reportedVersion: version)
    }

    /// 输出写临时文件而非未消费的 Pipe，防止解压/诊断输出填满管道后永远无法退出。
    /// 取消和超时都回收进程；不能让失败的检测在后台继续运行。
    static func run(
        _ executable: URL, _ arguments: [String],
        environment: [String: String]? = nil, timeout: TimeInterval = 15,
        input: Data? = nil, responseID: Int? = nil
    ) async throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let home = environment?["HOME"] {
            process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        }
        let inputPipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = handle
        process.standardError = handle
        try Task.checkCancellation()
        try process.run()
        defer { try? inputPipe.fileHandleForWriting.close() }
        let deadline = Date().addingTimeInterval(timeout)
        var protocolResponse: String?
        do {
            if let input { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
            while process.isRunning {
                try Task.checkCancellation()
                if let responseID {
                    let data = try Data(contentsOf: output)
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              json["id"] as? Int == responseID else { continue }
                        guard json["result"] != nil, json["error"] == nil else {
                            throw RuntimeDownloadError.process(String(line))
                        }
                        protocolResponse = String(line)
                        break
                    }
                    if protocolResponse != nil {
                        try inputPipe.fileHandleForWriting.close()
                        stop(process)
                        break
                    }
                }
                guard Date() < deadline else { throw RuntimeDownloadError.process("Process timed out: \(executable.lastPathComponent)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            stop(process)
            throw error
        }
        if let protocolResponse { return protocolResponse }
        let input = try FileHandle(forReadingFrom: output)
        defer { try? input.close() }
        let text = String(decoding: try input.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0, responseID == nil else { throw RuntimeDownloadError.process(text) }
        return text
    }

    /// 同步收尾只在进程结束或协议探测完成后执行，宽限期严格有界。
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = Date().addingTimeInterval(0.3)
        while process.isRunning, Date() < grace { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

/// URLSession 的委托可能在任意队列回调；闭包只发送数值，由 UI 切回 MainActor。
private final class RuntimeDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double?) -> Void
    init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }
}
