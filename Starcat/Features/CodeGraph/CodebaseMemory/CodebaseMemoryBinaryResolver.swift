//
//  CodebaseMemoryBinaryResolver.swift
//  Starcat
//
//  按分发渠道解析 CodebaseMemory 可执行文件。
//
//  App Store 继续只执行随 App 签名的 bundle 资源；Direct 不再携带 258 MiB
//  二进制，优先使用用户选择，其次检测标准安装位置与 PATH。Direct 没有 sandbox，
//  因此可以直接执行用户拥有的绝对路径，但 Starcat 不下载、不改权限、不移除
//  quarantine，也不重签该文件。
//

import Darwin
import Foundation

/// 已通过文件属性与 `--version` 探测的 CodebaseMemory 可执行文件。
struct CodebaseMemoryExecutable: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case bundled
        case automatic
        case userSelected
    }

    let url: URL
    let version: String
    let source: Source
}

actor CodebaseMemoryBinaryResolver {

    typealias VersionProbe = @Sendable (URL, TimeInterval) async throws -> String

    static let selectedExecutablePathKey = "codebaseMemory.selectedExecutablePath"
    static let installationURL = URL(string: "https://github.com/DeusData/codebase-memory-mcp")!

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let channel: DistributionChannel
    private let environment: [String: String]
    private let homeDirectory: URL
    private let commonExecutableDirectories: [URL]
    private let probeTimeout: TimeInterval
    private let injectedBundleCodebaseURL: URL?
    private let versionProbe: VersionProbe

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        channel: DistributionChannel = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        commonExecutableDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        ],
        probeTimeout: TimeInterval = 2,
        bundledExecutableURL: URL? = nil,
        versionProbe: VersionProbe? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.channel = channel
        self.environment = environment
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.commonExecutableDirectories = commonExecutableDirectories
        self.probeTimeout = probeTimeout
        self.injectedBundleCodebaseURL = bundledExecutableURL
        self.versionProbe = versionProbe ?? Self.runVersionProbe
    }

    // MARK: - Public API

    /// 兼容现有索引与 UI 启动链路，只把已验证的绝对路径交给 `Process.executableURL`。
    func resolveExecutable() async throws -> URL {
        try await resolveExecutableInfo().url
    }

    /// 返回路径、版本和来源，供设置页展示当前实际使用的可执行文件。
    func resolveExecutableInfo() async throws -> CodebaseMemoryExecutable {
        if channel.isAppStore {
            return try await resolveBundledExecutable()
        }
        return try await resolveDirectExecutable()
    }

    /// 验证成功后才持久化用户选择，避免一次误选覆盖仍可工作的自动检测结果。
    func selectExecutable(_ url: URL) async throws -> CodebaseMemoryExecutable {
        guard channel.isDirect else {
            throw CodebaseMemoryError.externalExecutableUnavailable
        }

        let executable = try await validateCandidate(url, source: .userSelected)
        defaults.set(executable.url.path, forKey: Self.selectedExecutablePathKey)
        return executable
    }

    func restoreAutomaticDetection() {
        defaults.removeObject(forKey: Self.selectedExecutablePathKey)
    }

    func hasUserSelectedExecutable() -> Bool {
        selectedExecutableURL != nil
    }

    // MARK: - Channel resolution

    private func resolveBundledExecutable() async throws -> CodebaseMemoryExecutable {
        let bundleURL = injectedBundleCodebaseURL ?? Bundle.main.url(
            forResource: "codebase",
            withExtension: "bin",
            subdirectory: nil
        )

        guard let bundleURL else {
            recordFailure("Bundled CodebaseMemory executable is missing")
            throw CodebaseMemoryError.binaryMissing
        }

        do {
            return try await validateCandidate(bundleURL, source: .bundled)
        } catch let error as CodebaseMemoryError {
            recordFailure(
                "Bundled CodebaseMemory executable validation failed",
                context: ["path": bundleURL.path, "error": error.localizedDescription]
            )
            throw error == .binaryNotExecutable ? error : CodebaseMemoryError.binaryNotExecutable
        }
    }

    private func resolveDirectExecutable() async throws -> CodebaseMemoryExecutable {
        var selectedFailure: CodebaseMemoryError?
        if let selectedExecutableURL {
            do {
                return try await validateCandidate(selectedExecutableURL, source: .userSelected)
            } catch let error as CodebaseMemoryError {
                // 失效的持久化路径不能永久阻断功能；保留选择供设置页展示和替换，
                // 同时继续尝试标准安装位置与 PATH。
                selectedFailure = error
                AppLog.ui.warning("CodebaseMemory selected executable is invalid path=\(selectedExecutableURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        var seenPaths = Set<String>()
        for candidate in automaticCandidates() {
            let standardizedPath = candidate.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            do {
                return try await validateCandidate(candidate, source: .automatic)
            } catch {
                // 自动检测会枚举多个位置；单个无效候选只进入诊断，不提前终止。
                AppLog.ui.debug("CodebaseMemory automatic candidate rejected path=\(candidate.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        if let selectedFailure {
            recordFailure(
                "Selected CodebaseMemory executable is invalid and automatic detection failed",
                context: ["error": selectedFailure.localizedDescription]
            )
            throw selectedFailure
        }

        recordFailure("No external CodebaseMemory executable was detected")
        throw CodebaseMemoryError.externalExecutableUnavailable
    }

    private var selectedExecutableURL: URL? {
        guard let path = defaults.string(forKey: Self.selectedExecutablePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// 顺序与 #58 契约一致：upstream 默认目录 → 进程 PATH → Homebrew 常见目录。
    private func automaticCandidates() -> [URL] {
        let executableName = "codebase-memory-mcp"
        var candidates = [
            homeDirectory
                .appendingPathComponent(".local/bin", isDirectory: true)
                .appendingPathComponent(executableName, isDirectory: false)
        ]

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        candidates.append(contentsOf: pathDirectories.map {
            $0.appendingPathComponent(executableName, isDirectory: false)
        })
        candidates.append(contentsOf: commonExecutableDirectories.map {
            $0.appendingPathComponent(executableName, isDirectory: false)
        })
        return candidates
    }

    // MARK: - Validation

    private func validateCandidate(
        _ candidate: URL,
        source: CodebaseMemoryExecutable.Source
    ) async throws -> CodebaseMemoryExecutable {
        let resolvedURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
        } catch {
            throw CodebaseMemoryError.executableValidationFailed(
                path: resolvedURL.path,
                underlying: error.localizedDescription
            )
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: resolvedURL.path) else {
            throw CodebaseMemoryError.executableValidationFailed(
                path: resolvedURL.path,
                underlying: String.l10n("codebaseMemory.error.notRegularExecutable")
            )
        }

        let version = try await versionProbe(resolvedURL, probeTimeout)
        AppLog.ui.info("CodebaseMemory executable resolved source=\(String(describing: source), privacy: .public) path=\(resolvedURL.path, privacy: .public) version=\(version, privacy: .public)")
        return CodebaseMemoryExecutable(url: resolvedURL, version: version, source: source)
    }

    /// `Process.waitUntilExit()` 没有 timeout；这里用短轮询建立 2 秒硬边界。
    /// 超时后先 TERM，再在短宽限期后 KILL，避免用户选中的异常程序残留后台进程。
    private static func runVersionProbe(
        at executableURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: error.localizedDescription
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning, Date() < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch {
            terminate(process)
            throw error
        }

        if process.isRunning {
            terminate(process)
            throw CodebaseMemoryError.executableProbeTimedOut(path: executableURL.path)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: output.prefix(8_192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, text.isEmpty == false else {
            let detail = text.isEmpty
                ? String(format: String.l10n("codebaseMemory.error.versionExitStatusFormat"), process.terminationStatus)
                : text
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: detail
            )
        }

        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let graceDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < graceDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    // MARK: - Diagnostics

    private func recordFailure(_ message: String, context: [String: String] = [:]) {
        DiagnosticLogStore.record(
            level: .critical,
            visibility: .issue,
            category: "codebase-memory",
            operation: "codebaseMemory.resolveBinary",
            message: message,
            context: context
        )
    }
}
