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

/// 已通过文件属性、`--version` 与 Graph UI 能力探测的 CodebaseMemory 可执行文件。
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

    typealias ExecutableProbe = @Sendable (URL, TimeInterval) async throws -> String

    /// UI 能力探测会启动一次上游进程。用路径、大小和修改时间缓存成功结果，
    /// 避免每次打开图谱都重复承担启动成本；二进制被替换后指纹会自然失效。
    private struct ProbeCacheRecord: Codable {
        let path: String
        let fileSize: UInt64
        let modificationTime: TimeInterval
        let version: String

        func matches(path: String, fileSize: UInt64, modificationTime: TimeInterval) -> Bool {
            self.path == path
                && self.fileSize == fileSize
                && self.modificationTime == modificationTime
        }
    }

    static let selectedExecutablePathKey = "codebaseMemory.selectedExecutablePath"
    private static let probeCacheKey = "codebaseMemory.graphUIProbeCache"
    static let installationURL = URL(
        string: "https://github.com/DeusData/codebase-memory-mcp#graph-visualization-ui"
    )!

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let channel: DistributionChannel
    private let environment: [String: String]
    private let homeDirectory: URL
    private let commonExecutableDirectories: [URL]
    private let probeTimeout: TimeInterval
    private let injectedBundleCodebaseURL: URL?
    private let executableProbe: ExecutableProbe

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
        probeTimeout: TimeInterval = 12,
        bundledExecutableURL: URL? = nil,
        executableProbe: ExecutableProbe? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.channel = channel
        self.environment = environment
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.commonExecutableDirectories = commonExecutableDirectories
        self.probeTimeout = probeTimeout
        self.injectedBundleCodebaseURL = bundledExecutableURL
        self.executableProbe = executableProbe ?? Self.runExecutableProbe
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
            if case .graphUIUnavailable = error {
                throw error
            }
            throw error == .binaryNotExecutable ? error : CodebaseMemoryError.binaryNotExecutable
        }
    }

    private func resolveDirectExecutable() async throws -> CodebaseMemoryExecutable {
        var selectedFailure: CodebaseMemoryError?
        var automaticCapabilityFailure: CodebaseMemoryError?
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
            } catch let error as CodebaseMemoryError {
                // 自动检测会枚举多个位置；单个无效候选只进入诊断，不提前终止。
                AppLog.ui.debug("CodebaseMemory automatic candidate rejected path=\(candidate.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                if case .graphUIUnavailable = error,
                   automaticCapabilityFailure == nil {
                    automaticCapabilityFailure = error
                }
            }
        }

        if let automaticCapabilityFailure {
            recordFailure(
                "Detected CodebaseMemory executable does not include Graph UI",
                context: ["error": automaticCapabilityFailure.localizedDescription]
            )
            throw automaticCapabilityFailure
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

        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let version: String
        if let cached = cachedProbeRecord(),
           cached.matches(
               path: resolvedURL.path,
               fileSize: fileSize,
               modificationTime: modificationTime
           ) {
            version = cached.version
        } else {
            version = try await executableProbe(resolvedURL, probeTimeout)
            storeProbeRecord(
                ProbeCacheRecord(
                    path: resolvedURL.path,
                    fileSize: fileSize,
                    modificationTime: modificationTime,
                    version: version
                )
            )
        }
        AppLog.ui.info("CodebaseMemory executable resolved source=\(String(describing: source), privacy: .public) path=\(resolvedURL.path, privacy: .public) version=\(version, privacy: .public)")
        return CodebaseMemoryExecutable(url: resolvedURL, version: version, source: source)
    }

    private func cachedProbeRecord() -> ProbeCacheRecord? {
        guard let data = defaults.data(forKey: Self.probeCacheKey) else { return nil }
        return try? JSONDecoder().decode(ProbeCacheRecord.self, from: data)
    }

    private func storeProbeRecord(_ record: ProbeCacheRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.probeCacheKey)
    }

    /// `--version` 不能区分 standard 与 UI variant。这里在隔离缓存目录中执行一次
    /// `--ui=true`，只接受没有返回 upstream headless 警告的二进制。真实用户配置、
    /// 索引和端口不会被这次探测修改。
    private static func runExecutableProbe(
        at executableURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let versionResult = try await runProbeCommand(
            executableURL: executableURL,
            arguments: ["--version"],
            timeout: min(timeout, 2),
            environment: nil,
            currentDirectoryURL: nil
        )
        let versionText = versionResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionResult.terminationStatus == 0, versionText.isEmpty == false else {
            let detail = versionText.isEmpty
                ? String(
                    format: String.l10n("codebaseMemory.error.versionExitStatusFormat"),
                    versionResult.terminationStatus
                )
                : versionText
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: detail
            )
        }

        let probeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Starcat-CodebaseMemory-UIProbe-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: probeDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: error.localizedDescription
            )
        }
        defer { try? FileManager.default.removeItem(at: probeDirectory) }

        let environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": probeDirectory.path
        ]) { _, new in new }
        let uiResult = try await runProbeCommand(
            executableURL: executableURL,
            arguments: ["--ui=true", "--port=\(Int.random(in: 49_152...65_535))"],
            timeout: timeout,
            environment: environment,
            currentDirectoryURL: probeDirectory
        )
        if CodebaseMemoryGraphUICapability.reportsUnavailable(uiResult.text) {
            throw CodebaseMemoryError.graphUIUnavailable(path: executableURL.path)
        }
        guard uiResult.terminationStatus == 0 else {
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: uiResult.text.isEmpty
                    ? "UI capability probe exited with \(uiResult.terminationStatus)"
                    : uiResult.text
            )
        }

        return versionText.split(whereSeparator: \.isNewline).first.map(String.init) ?? versionText
    }

    private struct ProbeCommandResult {
        let terminationStatus: Int32
        let text: String
    }

    /// `Process.waitUntilExit()` 没有 timeout；短轮询建立硬边界，超时后先 TERM，
    /// 再在宽限期后 KILL，避免异常的第三方二进制残留后台进程。
    private static func runProbeCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        currentDirectoryURL: URL?
    ) async throws -> ProbeCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        do {
            try process.run()
        } catch {
            throw CodebaseMemoryError.executableValidationFailed(
                path: executableURL.path,
                underlying: error.localizedDescription
            )
        }

        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
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
        return ProbeCommandResult(
            terminationStatus: process.terminationStatus,
            text: text
        )
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
