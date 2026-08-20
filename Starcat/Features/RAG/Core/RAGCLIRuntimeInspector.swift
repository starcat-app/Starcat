//
//  RAGCLIRuntimeInspector.swift
//  Starcat
//
//  Direct 版 RAG 设置页的本机 CLI 可用性探测。
//
//  探测边界：
//  - 只解析可执行文件并运行 `--version`，不发送 Prompt、不读取项目、不加载 MCP。
//  - 探测在后台线程执行，并设置短超时；损坏或卡住的 CLI 不能阻塞设置页主线程。
//  - “已安装”只代表二进制可执行，不推断登录状态；真实鉴权仍由首次 RAG 调用验证。
//

import Darwin
import Foundation

/// 设置页展示的 CLI 运行时状态。
enum RAGCLIRuntimeInspection: Equatable, Sendable {
    case checking
    case available(executableURL: URL, version: String)
    case notInstalled
    case failed(detail: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 组合二进制解析与版本探测；闭包注入仅用于覆盖状态转换，不把真实进程带进单测。
struct RAGCLIRuntimeInspector: Sendable {
    typealias Resolver = @Sendable (RAGCLIProvider) throws -> URL
    typealias VersionReader = @Sendable (URL, RAGCLIProvider) async throws -> String

    private let resolver: Resolver
    private let versionReader: VersionReader

    init(timeout: TimeInterval = 3) {
        resolver = { try RAGCLIExecutableResolver().resolve($0) }
        versionReader = { executableURL, provider in
            try await RAGCLIVersionProbe(timeout: timeout).readVersion(
                executableURL: executableURL,
                provider: provider
            )
        }
    }

    init(
        resolver: @escaping Resolver,
        versionReader: @escaping VersionReader
    ) {
        self.resolver = resolver
        self.versionReader = versionReader
    }

    func inspect(_ provider: RAGCLIProvider) async -> RAGCLIRuntimeInspection {
        do {
            let executableURL = try resolver(provider)
            let version = try await versionReader(executableURL, provider)
            return .available(executableURL: executableURL, version: version)
        } catch RAGCLIRuntimeError.executableNotFound(_) {
            return .notInstalled
        } catch is CancellationError {
            return .failed(detail: "cancelled")
        } catch {
            let detail = (error as? RAGCLIRuntimeError)?.diagnosticDetail
                ?? error.localizedDescription
            return .failed(detail: String(detail.prefix(512)))
        }
    }
}

/// 受限的 `--version` 进程读取器。
private struct RAGCLIVersionProbe: Sendable {
    let timeout: TimeInterval

    func readVersion(
        executableURL: URL,
        provider: RAGCLIProvider
    ) async throws -> String {
        let session = RAGCLIVersionProbeSession(
            executableURL: executableURL,
            provider: provider,
            timeout: max(timeout, 0.5)
        )
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try session.run()
            }.value
        } onCancel: {
            session.cancel()
        }
    }
}

/// `Process` 不是 Sendable；锁只保护取消标记与终止动作，实际读写全部发生在后台任务。
private final class RAGCLIVersionProbeSession: @unchecked Sendable {
    private let lock = NSLock()
    private let executableURL: URL
    private let provider: RAGCLIProvider
    private let timeout: TimeInterval
    private let process = Process()
    private var cancelled = false

    init(
        executableURL: URL,
        provider: RAGCLIProvider,
        timeout: TimeInterval
    ) {
        self.executableURL = executableURL
        self.provider = provider
        self.timeout = timeout
    }

    func run() throws -> String {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let terminated = DispatchSemaphore(value: 0)

        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in terminated.signal() }
        lock.unlock()

        do {
            try process.run()
        } catch {
            throw RAGCLIRuntimeError.launchFailed(error.localizedDescription)
        }

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            terminateAndWait(using: terminated)
            throw RAGCLIRuntimeError.timedOut(
                provider: provider.rawValue,
                seconds: Int(timeout.rounded(.up))
            )
        }

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RAGCLIRuntimeError.processFailed(
                provider: provider.rawValue,
                status: process.terminationStatus,
                detail: detail.isEmpty ? "version probe failed" : String(detail.prefix(512))
            )
        }

        let preferred = stdout.isEmpty ? stderr : stdout
        let raw = String(decoding: preferred, as: UTF8.self)
        guard let firstLine = raw.split(whereSeparator: { $0.isNewline }).first else {
            throw RAGCLIRuntimeError.invalidOutput("empty --version output")
        }
        let version = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw RAGCLIRuntimeError.invalidOutput("empty --version output")
        }
        return String(version.prefix(160))
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = process.isRunning
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    private func terminateAndWait(using semaphore: DispatchSemaphore) {
        if process.isRunning { process.terminate() }
        if semaphore.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + 0.25)
        }
    }
}
