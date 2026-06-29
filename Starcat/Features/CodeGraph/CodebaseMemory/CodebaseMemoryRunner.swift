//
//  CodebaseMemoryRunner.swift
//  Starcat
//
//  CodebaseMemory 子进程管理：负责 Process spawn + CLI 调用 + UI 子进程生命周期。
//
//  关键约束：
//  - 永远不调用 codebase update 子命令（沙盒 + App Store 禁忌）
//  - CBM_CACHE_DIR 环境变量注入为 container 内路径
//  - Process.environment 不继承父进程 PATH（纯二进制路径 spawn）
//  - 所有子进程生命周期由本 runner 统一管理（activeProcesses 数组 + terminationHandler）

import Darwin
import Foundation

// MARK: - IndexResult

/// cli index_repository 的 stdout JSON 解析结果。
struct CodebaseMemoryIndexResult: Sendable, Equatable {
    let nodeCount: Int
    let edgeCount: Int
    let durationMs: Int
    let errors: [String]

    /// 从 stdout JSON 解析（宽松提取，只取需要的字段）。
    static func parse(stdout: Data, stderr: Data) -> CodebaseMemoryIndexResult {
        let decoder = JSONDecoder()
        struct RawResult: Decodable {
            let node_count: Int?
            let edge_count: Int?
            let duration_ms: Int?
        }
        let raw = (try? decoder.decode(RawResult.self, from: stdout))
        let stderrLines = String(data: stderr, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init) ?? []
        return CodebaseMemoryIndexResult(
            nodeCount: raw?.node_count ?? 0,
            edgeCount: raw?.edge_count ?? 0,
            durationMs: raw?.duration_ms ?? 0,
            errors: stderrLines.filter { !$0.isEmpty }
        )
    }
}

/// `cli list_projects` 返回的最小项。
///
/// 这里只保留 Starcat 需要做隔离校验的字段：project name 和 root_path。
/// UI 前端必须使用这个 name 进入 Graph，root_path 则用于确认当前 cache
/// 没有误读到其他 repo 的 db。
struct CodebaseMemoryCLIProject: Sendable, Equatable {
    let name: String
    let rootPath: String
}

/// 已通过启动前/启动后校验的 UI 进程上下文。
struct CodebaseMemoryUIProcess {
    let process: Process
    let pageURL: URL
}

// MARK: - CodebaseMemoryRunner

/// CodebaseMemory 进程管理器。
///
/// 线程安全：所有 `activeProcesses` 访问仅在 Process.terminationHandler 修改。
/// spawnIndex / spawnUI 在调用线程执行 `process.run()`。
final class CodebaseMemoryRunner {

    /// 活跃 UI 子进程追踪。
    ///
    /// 这里必须强持有 `stdinPipe`：codebase-memory-mcp 的 UI server 只会在 MCP
    /// stdio 长进程里启动，如果 stdin pipe 被 ARC 释放，子进程会收到 EOF 并正常退出。
    private var activeProcesses: [ManagedUIProcess] = []

    init() {}

    // MARK: - 进程隔离

    /// 清理 Starcat 旧版本遗留的 codebase UI 进程。
    ///
    /// codebase-memory-mcp 的 UI 配置由 `--ui=true --port=N` 持久化，旧实现残留的长
    /// 进程可能继续服务上一个 repo。这里限定只清理 Starcat bundle/container 里的
    /// codebase 二进制，避免误杀用户自己在终端启动的全局 codebase-memory-mcp。
    func terminateStaleStarcatUIProcesses(binaryURL: URL) {
        let currentPID = Int(ProcessInfo.processInfo.processIdentifier)
        let knownPIDs = Set(activeProcesses.map { Int($0.process.processIdentifier) })

        for entry in Self.runningCodebaseProcesses() {
            guard entry.pid != currentPID, !knownPIDs.contains(entry.pid) else { continue }
            guard Self.isStarcatCodebaseCommand(entry.command, binaryURL: binaryURL) else { continue }
            kill(pid_t(entry.pid), SIGTERM)
        }
    }

    /// 启动一个经过完整隔离校验的 UI 进程。
    ///
    /// 这是 Starcat 管控内置二进制进程的唯一推荐入口：
    /// 1. 停止本 Runner 仍持有的旧 UI 进程。
    /// 2. 清理 Starcat 旧版本遗留的 bundle/container 二进制进程。
    /// 3. 检查端口可用后启动 UI。
    /// 4. 等待 HTTP server 响应。浏览器打开必须在端口可连通后立刻发生，
    ///    不能再被后续 CLI 校验挡住，否则用户会看到“启动 UI”长期卡住。
    func startVerifiedUI(
        binaryURL: URL,
        port: Int,
        cacheDir: URL,
        repositoryFullName: String
    ) async throws -> CodebaseMemoryUIProcess {
        stopAll()
        terminateStaleStarcatUIProcesses(binaryURL: binaryURL)

        if CodebaseMemoryPortAvailability.unavailableMessage(for: port) != nil {
            throw CodebaseMemoryError.portExhausted
        }

        let process = try startUI(
            binaryURL: binaryURL,
            port: port,
            cacheDir: cacheDir,
            repositoryFullName: repositoryFullName
        )
        let pageURL = URL(string: "http://127.0.0.1:\(port)/")!

        do {
            guard process.isRunning else {
                throw CodebaseMemoryError.uiStartFailed(
                    underlying: processStartupFailureMessage(
                        process: process,
                        fallback: "process exited before server became ready"
                    )
                )
            }
            try await waitForServer(process: process, port: port, timeout: 8)
            return CodebaseMemoryUIProcess(process: process, pageURL: pageURL)
        } catch {
            stopUI(process)
            throw error
        }
    }

    /// 判断指定 repo 独立 cache 里是否已有项目 DB。
    ///
    /// 串台的根因是多个 repo 共用同一个 `.internal-cache`。现在隔离边界是
    /// `<root>/<owner>/<repo>/.internal-cache`，这里不再启动前跑 CLI 校验阻塞 UI；
    /// 只在 cached 快路径确认该目录里确实有项目 DB，缺失则回完整索引流程重建。
    func hasIndexedProjectCache(cacheDir: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return contents.contains {
            $0.pathExtension == "db" && $0.lastPathComponent != "_config.db"
        }
    }

    // MARK: - 索引入口

    /// 用 `cli index_repository` 子命令索引一个 repo 目录。
    ///
    /// - Parameters:
    ///   - binaryURL: container 内可执行文件路径
    ///   - repoPath: 持久解压后的项目 source 目录（绝对路径）
    ///   - cacheDir: CBM_CACHE_DIR 指向的目录（container 内）
    ///
    /// - Returns: 解析后的 IndexResult（nodeCount / edgeCount / durationMs / errors）
    ///
    /// 索引可能耗时数秒，已在 detached 任务中 await stdout。
    func runIndex(
        binaryURL: URL,
        repoPath: URL,
        cacheDir: URL
    ) async throws -> CodebaseMemoryIndexResult {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let output = try await runCLI(
            binaryURL: binaryURL,
            arguments: [
                "cli", "index_repository",
                "{\"repo_path\": \"\(repoPath.path)\"}"
            ],
            cacheDir: cacheDir,
            timeout: 120,
            failureContext: "index_repository"
        )
        return CodebaseMemoryIndexResult.parse(stdout: output.stdout, stderr: output.stderr)
    }

    /// 读取指定 cache 下的已索引项目。
    ///
    /// 这是 UI 打开前的硬校验来源：如果 cache 中的 root_path 不是当前 repo 的
    /// source 目录，说明即将打开的是旧 repo 的 graph，必须阻止。
    func listProjects(binaryURL: URL, cacheDir: URL) async throws -> [CodebaseMemoryCLIProject] {
        let output = try await runCLI(
            binaryURL: binaryURL,
            arguments: ["cli", "list_projects", "{}"],
            cacheDir: cacheDir,
            timeout: 8,
            failureContext: "list_projects"
        )
        return try Self.parseProjects(stdout: output.stdout)
    }

    /// 校验 cache 中的项目确实属于当前 repo，并返回 UI 前端需要的 project name。
    func verifiedProjectName(
        binaryURL: URL,
        cacheDir: URL,
        expectedSourceURL: URL,
        repositoryFullName: String
    ) async throws -> String {
        let projects = try await listProjects(binaryURL: binaryURL, cacheDir: cacheDir)
        return try Self.verifiedProjectName(
            projects: projects,
            expectedSourceURL: expectedSourceURL,
            repositoryFullName: repositoryFullName
        )
    }

    /// 纯函数版校验，方便单测覆盖 root_path mismatch 这类串台场景。
    static func verifiedProjectName(
        projects: [CodebaseMemoryCLIProject],
        expectedSourceURL: URL,
        repositoryFullName: String
    ) throws -> String {
        let expectedRoot = expectedSourceURL.standardizedFileURL.path
        guard projects.count == 1, let project = projects.first else {
            throw CodebaseMemoryError.uiStartFailed(
                underlying: "expected one indexed project for \(repositoryFullName), got \(projects.count)"
            )
        }
        let actualRoot = URL(fileURLWithPath: project.rootPath).standardizedFileURL.path
        guard actualRoot == expectedRoot else {
            throw CodebaseMemoryError.uiStartFailed(
                underlying: "indexed project root mismatch: expected \(expectedRoot), got \(actualRoot)"
            )
        }
        return project.name
    }

    // MARK: - UI 子进程入口

    /// 先写 config（`--ui=true --port=N`），再启动 MCP 长进程（不带参数），
    /// 长进程会从 config.json 读取 `ui_enabled`/`ui_port` 并自动启动 HTTP UI。
    ///
    /// 分成两步是因为 `--ui=true` 只持久化配置然后退出，HTTP 服务器只在 MCP
    /// stdio 长进程里启动。
    func startUI(
        binaryURL: URL,
        port: Int,
        cacheDir: URL,
        repositoryFullName: String
    ) throws -> Process {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Step 1: 写入 ui 配置（一次性，立即退出）
        let configProcess = Process()
        configProcess.executableURL = binaryURL
        configProcess.arguments = ["--ui=true", "--port=\(port)"]
        configProcess.currentDirectoryURL = cacheDir
        configProcess.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }
        // stdin = /dev/null → 立即退出
        configProcess.standardInput = FileHandle.nullDevice
        let configStderrPipe = Pipe()
        configProcess.standardError = configStderrPipe
        try configProcess.run()
        configProcess.waitUntilExit()
        if configProcess.terminationStatus != 0 {
            let stderrData = configStderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = Self.processErrorMessage(
                stderr: stderrData,
                fallback: "ui config process exited with \(configProcess.terminationStatus)"
            )
            throw CodebaseMemoryError.uiStartFailed(underlying: message)
        }

        // Step 2: 启动 MCP 长进程（stdin 通过 Pipe 保持打开）
        let process = Process()
        process.executableURL = binaryURL
        // 不带 --ui 参数 — 从 config.json 自动读取
        process.arguments = []
        process.currentDirectoryURL = cacheDir
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }

        // stdin Pipe 保持打开，防止进程因 EOF 退出
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        // stdout/stderr 必须持续 drain：MCP 长进程可能在 stdout 输出协议消息，
        // 如果没人读 pipe，缓冲区写满后进程会卡住，UI server 也可能无法完成启动。
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(stdout: handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(stderr: handle.availableData)
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if proc.terminationStatus != 0 {
                let message = outputBuffer.diagnosticText()
                if !message.isEmpty {
                    FileHandle.standardError.write(
                        Data("[CodebaseMemory UI] exit=\(proc.terminationStatus): \(message)\n".utf8)
                    )
                }
            }
            Task { @MainActor in
                self?.pruneProcess(process)
            }
        }

        try process.run()
        activeProcesses.append(
            ManagedUIProcess(
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                outputBuffer: outputBuffer,
                repositoryFullName: repositoryFullName,
                startedAt: Date()
            )
        )
        return process
    }

    // MARK: - 停止

    /// 停止指定 UI 子进程。
    func stopUI(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        pruneProcess(process)
    }

    /// App 退出前调用 — 杀死所有活跃子进程。
    func stopAll() {
        for managed in activeProcesses where managed.process.isRunning {
            managed.process.terminate()
        }
        activeProcesses.removeAll()
    }

    /// 活跃 UI 子进程数量（供 UI 显示状态指示）。
    var activeUICount: Int {
        activeProcesses.count
    }

    // MARK: - Private

    private func pruneProcess(_ process: Process) {
        activeProcesses.removeAll { $0.process === process }
    }

    private struct ManagedUIProcess {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let outputBuffer: ProcessOutputBuffer
        let repositoryFullName: String
        let startedAt: Date
    }

    private struct CLIOutput {
        let stdout: Data
        let stderr: Data
    }

    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }

    /// UI 长进程输出缓存。
    ///
    /// Process 的 readabilityHandler 在系统后台队列回调，不能直接改 Swift 数组。
    /// 用一个小锁保护最近输出，既能持续 drain pipe，又能在启动失败时给 UI
    /// 返回可诊断的 stderr/stdout，而不是让用户只看到“启动中”。
    private final class ProcessOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private let maxBytes = 64 * 1024

        func append(stdout data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            stdout.append(data)
            trimIfNeeded(&stdout)
            lock.unlock()
        }

        func append(stderr data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            stderr.append(data)
            trimIfNeeded(&stderr)
            lock.unlock()
        }

        func outputData() -> CLIOutput {
            lock.lock()
            let output = CLIOutput(stdout: stdout, stderr: stderr)
            lock.unlock()
            return output
        }

        func diagnosticText() -> String {
            lock.lock()
            let stdoutText = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderrText = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lock.unlock()

            if !stderrText.isEmpty, !stdoutText.isEmpty {
                return "stderr: \(stderrText)\nstdout: \(stdoutText)"
            }
            if !stderrText.isEmpty { return stderrText }
            if !stdoutText.isEmpty { return stdoutText }
            return ""
        }

        private func trimIfNeeded(_ target: inout Data) {
            if target.count > maxBytes {
                target.removeFirst(target.count - maxBytes)
            }
        }
    }

    private struct RunningProcess {
        let pid: Int
        let command: String
    }

    private static func runningCodebaseProcesses() -> [RunningProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int(trimmed[..<spaceIndex]) else {
                return nil
            }
            let command = trimmed[spaceIndex...].trimmingCharacters(in: .whitespaces)
            guard command.contains("codebase") else { return nil }
            return RunningProcess(pid: pid, command: command)
        }
    }

    private static func isStarcatCodebaseCommand(_ command: String, binaryURL: URL) -> Bool {
        if command.contains(binaryURL.path) {
            return true
        }
        return command.contains("/Starcat/")
            && command.contains("/Resources/Codebase/")
            && command.contains("codebase")
    }

    private static func parseProjects(stdout: Data) throws -> [CodebaseMemoryCLIProject] {
        struct Response: Decodable {
            struct Project: Decodable {
                let name: String
                let root_path: String
            }
            let projects: [Project]
        }

        let decoder = JSONDecoder()
        let decoded: Response
        do {
            decoded = try decoder.decode(Response.self, from: stdout)
        } catch {
            // codebase-memory-mcp 可能在 stdout 的 JSON 前先写一行启动日志
            // (`level=info msg=mem.init ...`)。CLI 合约对 Starcat 有用的部分
            // 仍是 `{"projects": ...}`，这里只剥离前导日志，不做旧格式兼容。
            guard let text = String(data: stdout, encoding: .utf8),
                  let jsonStart = text.range(of: "{\"projects\"")?.lowerBound else {
                throw error
            }
            let jsonText = String(text[jsonStart...])
            decoded = try decoder.decode(Response.self, from: Data(jsonText.utf8))
        }
        return decoded.projects.map {
            CodebaseMemoryCLIProject(name: $0.name, rootPath: $0.root_path)
        }
    }

    private static func processErrorMessage(stderr: Data, fallback: String) -> String {
        let message = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? fallback : message
    }

    /// 执行一次性 CLI 子命令并带超时兜底。
    ///
    /// 这里不用 `readDataToEndOfFile()` 等 pipe EOF：codebase CLI 可能间接留下
    /// 继承 pipe 的内部任务，导致进程已退出但读取端一直等 EOF。持续 drain + 超时
    /// 能保证 ViewModel 状态机一定返回成功或失败。
    private func runCLI(
        binaryURL: URL,
        arguments: [String],
        cacheDir: URL,
        timeout: TimeInterval,
        failureContext: String
    ) async throws -> CLIOutput {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        process.currentDirectoryURL = cacheDir
        process.standardInput = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(stdout: handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            outputBuffer.append(stderr: handle.availableData)
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate()
            let finish: @Sendable (Result<CLIOutput, Error>) -> Void = { result in
                guard gate.claim() else { return }
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                switch result {
                case .success(let output):
                    continuation.resume(returning: output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { proc in
                let output = outputBuffer.outputData()
                if proc.terminationStatus == 0 {
                    finish(.success(output))
                    return
                }
                let message = Self.processErrorMessage(
                    stderr: output.stderr,
                    fallback: "\(failureContext) process exited with \(proc.terminationStatus)"
                )
                finish(.failure(CodebaseMemoryError.indexFailed(underlying: message)))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(CodebaseMemoryError.indexFailed(underlying: error.localizedDescription)))
                return
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(for: .milliseconds(500))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                let diagnostic = outputBuffer.diagnosticText()
                let suffix = diagnostic.isEmpty ? "" : ": \(diagnostic)"
                finish(.failure(
                    CodebaseMemoryError.indexFailed(
                        underlying: "\(failureContext) timed out after \(Int(timeout))s\(suffix)"
                    )
                ))
            }
        }
    }

    /// 轮询等待 HTTP server 监听端口。
    ///
    /// 这里故意不用 `URLSession` 请求 `http://127.0.0.1:<port>/`：
    /// macOS Debug 环境里 URLSession 可能继承系统代理，localhost 探测会被代理层影响，
    /// 导致 UI 进程已经退出但状态还长时间停在“启动 UI 服务”。用 POSIX socket
    /// 直接连 127.0.0.1 可以避开代理，并且每轮都检查子进程是否已经退出。
    private func waitForServer(process: Process, port: Int, timeout: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            guard process.isRunning else {
                throw CodebaseMemoryError.uiStartFailed(
                    underlying: processStartupFailureMessage(
                        process: process,
                        fallback: "process exited before server became ready"
                    )
                )
            }
            if Self.canConnectToLocalhost(port: port) {
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw CodebaseMemoryError.uiStartFailed(
            underlying: processStartupFailureMessage(
                process: process,
                fallback: "server did not listen on port \(port)"
            )
        )
    }

    private func processStartupFailureMessage(process: Process, fallback: String) -> String {
        guard let managed = activeProcesses.first(where: { $0.process === process }) else {
            return fallback
        }
        let diagnostic = managed.outputBuffer.diagnosticText()
        return diagnostic.isEmpty ? fallback : "\(fallback): \(diagnostic)"
    }

    private static func canConnectToLocalhost(port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        } == 0
    }
}
