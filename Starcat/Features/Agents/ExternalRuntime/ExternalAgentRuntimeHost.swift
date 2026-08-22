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

    init(firstOutputTimeout: Duration = .seconds(180)) {
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
    private var firstOutputDeadline: ContinuousClock.Instant?
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

        // macOS 默认会把“写入已关闭 pipe”升级为 SIGPIPE，信号会直接终止整个
        // Starcat 进程，Swift 的 throws 根本没有机会接管。只在当前 Runtime stdin
        // descriptor 上启用 F_SETNOSIGPIPE，把该场景降级为可恢复的 EPIPE 错误；
        // 不能全局忽略 SIGPIPE，否则会改变 App 内其它子进程和网络栈的信号语义。
        let stdinDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        guard Darwin.fcntl(stdinDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try process.run()
        // spawn 完成后父进程必须立即关闭三条 pipe 的 child-side endpoint。否则父进程
        // 自己仍持有 stdin read / stdout write / stderr write，Provider 退出后 EOF、EPIPE
        // 都无法可靠传播，短生命周期的连续 Run 还可能出现上一条 pipe 干扰下一条 Run。
        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
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
                for try await line in ExternalAgentLineReader.lines(
                    from: stderrPipe.fileHandleForReading
                ) {
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
            for try await line in ExternalAgentLineReader.lines(
                from: stdoutPipe.fileHandleForReading
            ) {
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
                // initialize/config/thread/reasoning 等协议活动虽然尚未形成用户可见文本，
                // 但足以证明 Runtime 仍在工作。每个合法 JSON-RPC 对象都会续期看门狗，
                // 避免 Codex 长握手或长推理被固定的墙钟超时误杀。
                noteProtocolActivity()
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
                if isStopping {
                    throw CancellationError()
                }
                // stdout EOF 可能早于 Foundation 更新 Process 的退出状态。短暂等待 reaping，
                // 才能把真实 status/signal 交给 UI，而不是一律报“提前关闭”。
                await waitForProcessExit(process, timeout: .milliseconds(400))
                let diagnostic = await processDiagnostic(process)
                if !process.isRunning, process.terminationStatus != 0 {
                    throw ExternalAgentRuntimeError.processExited(
                        process.terminationStatus,
                        diagnostic
                    )
                }
                throw ExternalAgentRuntimeError.processClosedBeforeCompletion(diagnostic)
            }
            await shutdownGracefully()
        } catch {
            await terminateIfNeeded()
            if let runtimeError = error as? ExternalAgentRuntimeError,
               case .processClosedBeforeCompletion(nil) = runtimeError {
                throw ExternalAgentRuntimeError.processClosedBeforeCompletion(
                    await stderrSummary.diagnostic()
                )
            }
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

    /// Codex App Server 的握手、配置读取和首轮推理都可能没有可见消息。看门狗限制的
    /// 是“连续无协议活动”时间；只要收到合法 JSON-RPC 就重新计时。真正开始流式输出
    /// 后立即解除，不限制后续工具链或报告生成时长。
    private func startFirstOutputWatchdog() {
        firstOutputDeadline = ContinuousClock.now + firstOutputTimeout
        guard firstOutputWatchdogTask == nil else { return }
        firstOutputWatchdogTask = Task { [weak self] in
            await self?.runFirstOutputWatchdog()
        }
    }

    private func noteProtocolActivity() {
        guard !didReceiveFirstOutput, !isStopping else { return }
        // 只推进 deadline，不为每个高频 JSON-RPC 帧反复取消和创建 Task；Codex
        // reasoning/token 事件密集时也只保留一个轻量看门狗。
        firstOutputDeadline = ContinuousClock.now + firstOutputTimeout
    }

    private func runFirstOutputWatchdog() async {
        while !didReceiveFirstOutput, !isStopping {
            guard let deadline = firstOutputDeadline else { return }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
                continue
            }
            handleFirstOutputTimeout()
            return
        }
    }

    private func markFirstOutputReceived() {
        guard !didReceiveFirstOutput else { return }
        didReceiveFirstOutput = true
        firstOutputDeadline = nil
        firstOutputWatchdogTask?.cancel()
        firstOutputWatchdogTask = nil
    }

    private func handleFirstOutputTimeout() {
        guard !didReceiveFirstOutput, !isStopping else { return }
        // 先封住 cancel/shutdown 的 JSON-RPC 写入，再终止子进程。否则 AsyncStream
        // onTermination 可能在 pipe 已关闭后继续发送 turn/interrupt。
        isStopping = true
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
            throw ExternalAgentRuntimeError.processClosedBeforeCompletion(nil)
        }
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            guard Self.isBrokenPipe(error) else {
                throw error
            }
            // 对端关闭 stdin 是 Runtime 生命周期错误，不允许冒泡为宿主进程信号。
            throw ExternalAgentRuntimeError.processClosedBeforeCompletion(nil)
        }
    }

    private func waitForProcessExit(_ process: Process, timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func processDiagnostic(_ process: Process) async -> String? {
        let termination: String?
        if process.isRunning {
            termination = "Process stdout closed while the process was still running."
        } else {
            switch process.terminationReason {
            case .exit:
                termination = "Termination reason: exit."
            case .uncaughtSignal:
                termination = "Termination reason: uncaught signal \(process.terminationStatus)."
            @unknown default:
                termination = "Termination reason: unknown."
            }
        }
        let stderr = await stderrSummary.diagnostic()
        return [termination, stderr].compactMap { $0 }.joined(separator: " ")
    }

    private static func isBrokenPipe(_ error: Error) -> Bool {
        var currentError = error as NSError
        while true {
            if currentError.domain == NSPOSIXErrorDomain,
               currentError.code == Int(EPIPE) {
                return true
            }
            // FileHandle 会把 EPIPE 包进 NSCocoaErrorDomain Code 512；必须沿着
            // NSUnderlyingErrorKey 解包，不能只检查最外层 NSError。
            guard let underlyingError = currentError.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlyingError !== currentError else {
                return false
            }
            currentError = underlyingError
        }
    }

    private func terminateIfNeeded() async {
        firstOutputWatchdogTask?.cancel()
        firstOutputWatchdogTask = nil
        firstOutputDeadline = nil
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

/// Foundation 的 `AsyncBytes.lines` / `read(upToCount:)` 在 App-hosted Process pipe 上
/// 可能等到请求长度或 EOF 才交付数据。Provider 发出 tool call 后会等待 Host 回包，
/// Host 又等不到尚未 EOF 的这一行，最终形成双向死锁。这里在独立 Dispatch worker
/// 上直接使用 POSIX `read`：pipe 一有字节就返回，再通过 AsyncThrowingStream 切行。
/// 阻塞 read 不能放进 Swift cooperative executor，否则 stdout/stderr reader 会占满
/// 可用线程，让等待 stream 的 Host actor 永远得不到调度。
private enum ExternalAgentLineReader {
    static func lines(from handle: FileHandle) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = Data()
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                do {
                    while true {
                        let count = Darwin.read(
                            handle.fileDescriptor,
                            &bytes,
                            bytes.count
                        )
                        if count > 0 {
                            buffer.append(contentsOf: bytes.prefix(count))
                            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                                let lineData = buffer[..<newlineIndex]
                                buffer.removeSubrange(...newlineIndex)
                                continuation.yield(String(decoding: lineData, as: UTF8.self))
                            }
                            continue
                        }
                        if count == 0 { break }
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(decoding: buffer, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                try? handle.close()
            }
        }
    }
}

private extension ExternalAgentProtocolEvent {
    var countsAsFirstOutput: Bool {
        switch self {
        case .trace, .assistantDelta, .reasoningDelta, .assistantMessage, .toolCall, .toolResult,
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
        else {
            // Codex 默认 tracing 输出包含 ANSI 颜色而不是 JSON。这里只匹配稳定 target，
            // 不保存 message 原文，既能定位模型缓存/MCP/panic，也不会泄露 prompt。
            if line.contains("codex_models_manager::cache") { return "codex model cache" }
            if line.contains("codex_models_manager::manager") { return "codex model manager" }
            if line.localizedCaseInsensitiveContains("panic") { return "runtime panic" }
            if line.localizedCaseInsensitiveContains("mcp") { return "mcp runtime" }
            return "unstructured"
        }
        let level = (object["level"] as? String)?.uppercased() ?? "LOG"
        let fields = object["fields"] as? [String: Any]
        let target = fields?["target"] as? String ?? object["target"] as? String ?? "unknown"
        return "\(level) \(target)"
    }
}
