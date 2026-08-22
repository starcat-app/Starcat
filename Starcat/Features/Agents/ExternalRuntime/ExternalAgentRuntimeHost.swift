//
//  ExternalAgentRuntimeHost.swift
//  Starcat
//
//  外部 Agent 子进程的统一生命周期与 newline-delimited JSON-RPC Host。
//
//  所有 Process、Pipe 和协议状态都封装在 actor 内，避免 stdout 回调、取消命令与
//  SwiftUI 主线程争用同一状态。Host 不理解 Provider 方法名，只转发 adapter 事件。
//

import Darwin
import Foundation

actor ExternalAgentRuntimeHost {
    typealias EventSink = @Sendable (ExternalAgentProtocolEvent) async -> Void
    typealias ToolCallHandler = @Sendable (
        ExternalAgentToolRequest
    ) async -> ExternalAgentToolExecutionResult

    private var sessions: [UUID: ExternalAgentProcessSession] = [:]
    private let firstOutputTimeout: Duration

    init(firstOutputTimeout: Duration = .seconds(90)) {
        self.firstOutputTimeout = firstOutputTimeout
    }

    func execute(
        runID: UUID,
        driver: any ExternalAgentProtocolDriver,
        toolCallHandler: ToolCallHandler? = nil,
        onEvent: @escaping EventSink
    ) async throws {
        let session = ExternalAgentProcessSession(
            driver: driver,
            firstOutputTimeout: firstOutputTimeout
        )
        sessions[runID] = session
        defer { sessions.removeValue(forKey: runID) }
        try await session.run(toolCallHandler: toolCallHandler, onEvent: onEvent)
    }

    func cancel(runID: UUID) async {
        await sessions[runID]?.cancel()
    }
}

/// 一个 run 一个子进程。POC 不复用跨 run Session，先证明协议隔离与停止语义可靠。
private actor ExternalAgentProcessSession {
    private let driver: any ExternalAgentProtocolDriver
    private let firstOutputTimeout: Duration
    private let stderrSummary = ExternalAgentStderrSummary()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrDrainTask: Task<Void, Never>?
    private var firstOutputWatchdogTask: Task<Void, Never>?
    private var processGroupID: pid_t?
    private var isStopping = false
    private var didReceiveFirstOutput = false
    private var didFirstOutputTimeout = false

    init(driver: any ExternalAgentProtocolDriver, firstOutputTimeout: Duration) {
        self.driver = driver
        self.firstOutputTimeout = firstOutputTimeout
    }

    func run(
        toolCallHandler: ExternalAgentRuntimeHost.ToolCallHandler?,
        onEvent: @escaping ExternalAgentRuntimeHost.EventSink
    ) async throws {
        let configuration = driver.processConfiguration
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        self.process = process
        // Foundation.Process 没有“新建进程组”选项。父进程在 spawn 返回后立即尝试把
        // Sidecar 设为组长；若系统因 exec 竞态拒绝，清理会安全降级到只终止主进程。
        let pid = process.processIdentifier
        if Darwin.setpgid(pid, pid) == 0 {
            processGroupID = pid
        }
        stdinHandle = stdinPipe.fileHandleForWriting
        stderrDrainTask = Task.detached(priority: .utility) { [stderrSummary] in
            // stderr 必须持续排空，否则长日志会填满 pipe 并反向卡住 Runtime。
            // 只保存日志级别与 target，不保存原文，避免 Provider 把 prompt 或凭据
            // 带进诊断信息；有限摘要仍能区分 Codex、MCP 与模型缓存故障。
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    await stderrSummary.record(line)
                }
            } catch {
                // 进程终止时关闭 pipe 属于正常清理路径。
            }
        }
        startFirstOutputWatchdog()

        do {
            for frame in try driver.initialFrames() {
                try write(frame)
            }

            var reachedTerminal = false
            var stdoutLineNumber = 0
            var ignoredStdoutDiagnosticCount = 0
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                stdoutLineNumber += 1
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { continue }

                let data = Data(trimmedLine.utf8)
                guard let frame = try? JSONDecoder().decode(AgentJSONValue.self, from: data) else {
                    // 外部 CLI 或包装脚本可能把启动提示写到 stdout，而 JSON-RPC transport
                    // 又与它共用同一条 pipe。普通诊断文本不应中断整个 Run；但对象形态的
                    // 损坏帧必须继续失败，避免吞掉真正的协议错误并拖成首输出超时。
                    if trimmedLine.first == "{" {
                        throw ExternalAgentRuntimeError.invalidFrame
                    }
                    ignoredStdoutDiagnosticCount += 1
                    if ignoredStdoutDiagnosticCount <= 3 {
                        let firstScalar = trimmedLine.unicodeScalars.first?.value ?? 0
                        let byteCount = data.count
                        AppLog.ai.warning("External Agent Runtime ignored non-JSON stdout diagnostic (line: \(stdoutLineNumber, privacy: .public), bytes: \(byteCount, privacy: .public), firstScalar: \(firstScalar, privacy: .public)).")
                    }
                    continue
                }
                guard frame.externalObject != nil else {
                    // JSON-RPC 顶层只能是对象；合法 JSON 的数组、字符串或数字不是日志，
                    // 不能按普通 stdout 杂讯忽略。
                    throw ExternalAgentRuntimeError.invalidFrame
                }
                let output = try driver.receive(frame)
                if output.events.contains(where: \.countsAsFirstOutput)
                    || !output.toolRequests.isEmpty {
                    markFirstOutputReceived()
                }
                for frame in output.outboundFrames {
                    try write(frame)
                }
                for event in output.events {
                    await onEvent(event)
                }
                for request in output.toolRequests {
                    try Task.checkCancellation()
                    await onEvent(.toolCall(
                        id: request.callID,
                        name: request.name,
                        input: request.input,
                        rawInput: request.rawInput
                    ))
                    guard let toolCallHandler else {
                        throw ExternalAgentRuntimeError.protocolError(
                            "External runtime requested an unavailable Starcat tool: \(request.name)."
                        )
                    }
                    let result = await toolCallHandler(request)
                    await onEvent(.toolResult(
                        id: request.callID,
                        name: request.name,
                        output: result.output,
                        isError: result.isError
                    ))
                    if let markdown = result.artifactMarkdown, !result.isError {
                        await onEvent(.artifactMarkdown(markdown, toolCallID: request.callID))
                    }
                    guard let response = driver.toolResponseFrame(for: request, result: result) else {
                        throw ExternalAgentRuntimeError.protocolError(
                            "External runtime cannot return the Starcat tool result to its Provider."
                        )
                    }
                    try write(response)
                }
                if output.isTerminal {
                    reachedTerminal = true
                    break
                }
            }

            if !reachedTerminal {
                if didFirstOutputTimeout {
                    throw ExternalAgentRuntimeError.firstOutputTimedOut(await stderrSummary.diagnostic())
                }
                if !process.isRunning, process.terminationStatus != 0 {
                    throw ExternalAgentRuntimeError.processExited(process.terminationStatus)
                }
                throw ExternalAgentRuntimeError.processClosedBeforeCompletion
            }
            await shutdownGracefully()
        } catch {
            await terminateIfNeeded()
            throw error
        }
    }

    func cancel() async {
        guard !isStopping else { return }
        isStopping = true
        if let frame = driver.cancellationFrame() {
            try? write(frame)
            try? await Task.sleep(for: .milliseconds(250))
        }
        await terminateIfNeeded()
    }

    private func shutdownGracefully() async {
        guard !isStopping else { return }
        isStopping = true
        if let frame = driver.shutdownFrame() {
            try? write(frame)
            try? await Task.sleep(for: .milliseconds(150))
        }
        await terminateIfNeeded()
    }

    /// Codex App Server 的握手、MCP 初始化和首轮推理都可能没有可见消息。看门狗只管
    /// “首个回答/工具事件”，一旦真正开始流式输出就立即解除，不限制后续长任务时长。
    private func startFirstOutputWatchdog() {
        firstOutputWatchdogTask = Task { [weak self, firstOutputTimeout] in
            do {
                try await Task.sleep(for: firstOutputTimeout)
            } catch {
                return
            }
            await self?.handleFirstOutputTimeout()
        }
    }

    private func markFirstOutputReceived() {
        guard !didReceiveFirstOutput else { return }
        didReceiveFirstOutput = true
        firstOutputWatchdogTask?.cancel()
        firstOutputWatchdogTask = nil
    }

    private func handleFirstOutputTimeout() {
        guard !didReceiveFirstOutput, !isStopping else { return }
        didFirstOutputTimeout = true
        // 终止进程让 AsyncBytes 退出；run 的统一 catch 随后负责回收整个进程组。
        if let processGroupID {
            Darwin.kill(-processGroupID, SIGTERM)
        } else {
            process?.terminate()
        }
    }

    private func write(_ frame: AgentJSONValue) throws {
        guard let stdinHandle else {
            throw ExternalAgentRuntimeError.processClosedBeforeCompletion
        }
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private func terminateIfNeeded() async {
        firstOutputWatchdogTask?.cancel()
        firstOutputWatchdogTask = nil
        stdinHandle?.closeFile()
        stdinHandle = nil
        guard let process else {
            stderrDrainTask?.cancel()
            stderrDrainTask = nil
            return
        }

        if process.isRunning {
            if let processGroupID {
                Darwin.kill(-processGroupID, SIGTERM)
            } else {
                process.terminate()
            }
            let deadline = ContinuousClock.now + .milliseconds(600)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                // Foundation.Process 没有 kill API；有界 SIGKILL 防止 Sidecar 残留。
                if let processGroupID {
                    Darwin.kill(-processGroupID, SIGKILL)
                } else {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        stderrDrainTask?.cancel()
        stderrDrainTask = nil
        self.process = nil
        processGroupID = nil
    }
}

private extension ExternalAgentProtocolEvent {
    var countsAsFirstOutput: Bool {
        switch self {
        case .assistantDelta, .reasoningDelta, .assistantMessage, .toolCall, .toolResult,
             .artifactMarkdown, .completed, .cancelled, .failed:
            return true
        case .usage:
            return false
        }
    }
}

/// 有界、非原文的 stderr 摘要。这里只保留结构化日志的 level/target；普通文本只记
/// “unstructured”，因此错误展示不会意外泄露用户 prompt、认证头或环境变量值。
private actor ExternalAgentStderrSummary {
    private let maximumEntries = 8
    private var entries: [String] = []
    private var lineCount = 0

    func record(_ line: String) {
        lineCount += 1
        let entry = Self.classification(for: line)
        if entries.last != entry {
            entries.append(entry)
            if entries.count > maximumEntries {
                entries.removeFirst(entries.count - maximumEntries)
            }
        }
    }

    func diagnostic() -> String? {
        guard lineCount > 0 else { return nil }
        let categories = entries.joined(separator: ", ")
        return "Codex stderr summary (\(lineCount) lines): \(categories)."
    }

    private static func classification(for line: String) -> String {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "unstructured" }
        let level = (object["level"] as? String)?.uppercased() ?? "LOG"
        let fields = object["fields"] as? [String: Any]
        let target = fields?["target"] as? String ?? object["target"] as? String ?? "unknown"
        return "\(level) \(target)"
    }
}
