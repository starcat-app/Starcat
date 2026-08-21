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

    func execute(
        runID: UUID,
        driver: any ExternalAgentProtocolDriver,
        toolCallHandler: ToolCallHandler? = nil,
        onEvent: @escaping EventSink
    ) async throws {
        let session = ExternalAgentProcessSession(driver: driver)
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
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrDrainTask: Task<Void, Never>?
    private var processGroupID: pid_t?
    private var isStopping = false

    init(driver: any ExternalAgentProtocolDriver) {
        self.driver = driver
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
        stderrDrainTask = Task.detached(priority: .utility) {
            // stderr 必须持续排空，否则长日志会填满 pipe 并反向卡住 Runtime。
            // POC 不记录原文，避免 Provider 错误把 prompt 或凭据带进统一日志。
            do {
                for try await _ in stderrPipe.fileHandleForReading.bytes.lines {}
            } catch {
                // 进程终止时关闭 pipe 属于正常清理路径。
            }
        }

        do {
            for frame in try driver.initialFrames() {
                try write(frame)
            }

            var reachedTerminal = false
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let frame = try? JSONDecoder().decode(AgentJSONValue.self, from: data)
                else {
                    throw ExternalAgentRuntimeError.invalidFrame
                }
                let output = try driver.receive(frame)
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

    private func write(_ frame: AgentJSONValue) throws {
        guard let stdinHandle else {
            throw ExternalAgentRuntimeError.processClosedBeforeCompletion
        }
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    private func terminateIfNeeded() async {
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
