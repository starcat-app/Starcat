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

// MARK: - CodebaseMemoryRunner

/// CodebaseMemory 进程管理器。
///
/// 线程安全：所有 `activeProcesses` 访问仅在 Process.terminationHandler 修改。
/// spawnIndex / spawnUI 在调用线程执行 `process.run()`。
final class CodebaseMemoryRunner {

    /// 活跃子进程追踪：(process, (repositoryFullName, startedAt))
    private var activeProcesses: [(Process, String, Date)] = []

    init() {}

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
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "cli", "index_repository",
            "{\"repo_path\": \"\(repoPath.path)\"}"
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0 {
                    let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
                    // 不抛错到 continuation，只将 stderr 记入 IndexResult.errors
                }
                continuation.resume(
                    returning: CodebaseMemoryIndexResult.parse(stdout: stdoutData, stderr: stderrData)
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CodebaseMemoryError.indexFailed(underlying: error.localizedDescription))
            }
        }
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
        // Step 1: 写入 ui 配置（一次性，立即退出）
        let configProcess = Process()
        configProcess.executableURL = binaryURL
        configProcess.arguments = ["--ui=true", "--port=\(port)"]
        configProcess.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }
        // stdin = /dev/null → 立即退出
        configProcess.standardInput = FileHandle.nullDevice
        try configProcess.run()
        configProcess.waitUntilExit()

        // Step 2: 启动 MCP 长进程（stdin 通过 Pipe 保持打开）
        let process = Process()
        process.executableURL = binaryURL
        // 不带 --ui 参数 — 从 config.json 自动读取
        process.arguments = []
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CBM_CACHE_DIR": cacheDir.path
        ]) { _, new in new }

        // stdin Pipe 保持打开，防止进程因 EOF 退出
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            if proc.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: stderrData, encoding: .utf8) ?? ""
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
        activeProcesses.append((process, repositoryFullName, Date()))
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
        for (process, _, _) in activeProcesses where process.isRunning {
            process.terminate()
        }
        activeProcesses.removeAll()
    }

    /// 活跃 UI 子进程数量（供 UI 显示状态指示）。
    var activeUICount: Int {
        activeProcesses.count
    }

    // MARK: - Private

    private func pruneProcess(_ process: Process) {
        activeProcesses.removeAll { $0.0 === process }
    }
}
