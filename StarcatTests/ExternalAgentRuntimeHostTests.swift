//
//  ExternalAgentRuntimeHostTests.swift
//  StarcatTests
//
//  统一外部进程 Host 的真实 Pipe / JSONL 生命周期测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("External Agent Runtime Host")
struct ExternalAgentRuntimeHostTests {

    @Test("Host 忽略 stdout 诊断文本并继续读取 JSON-RPC 事件")
    func ignoresStdoutDiagnosticsAndStreamsJSONUntilTerminalEvent() async throws {
        let collector = ExternalHostEventCollector()
        let host = ExternalAgentRuntimeHost()
        let runID = UUID()

        try await host.execute(runID: runID, driver: ExternalHostFixtureDriver()) { event in
            await collector.append(event)
        }

        assertFirstOutputLatency(
            in: await collector.events,
            followedBy: [.assistantDelta("fixture"), .completed]
        )
    }

    @Test("Host 不会把对象形态的损坏 JSON 当成诊断文本忽略")
    func rejectsMalformedJSONObjectFrame() async throws {
        let host = ExternalAgentRuntimeHost()

        await #expect(throws: ExternalAgentRuntimeError.invalidFrame) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostMalformedJSONFixtureDriver()
            ) { _ in }
        }
    }

    @Test("Host 执行动态工具并把结果写回 Provider")
    func executesDynamicToolAndReturnsResult() async throws {
        let collector = ExternalHostEventCollector()
        let host = ExternalAgentRuntimeHost()

        try await host.execute(
            runID: UUID(),
            driver: ExternalHostToolFixtureDriver(),
            toolCallHandler: { _ in
                return ExternalAgentToolExecutionResult(
                    output: .object(["summary": .string("fixture-result")]),
                    modelText: "fixture-result",
                    isError: false,
                    artifactMarkdown: nil
                )
            }
        ) { event in
            await collector.append(event)
        }

        assertFirstOutputLatency(in: await collector.events, followedBy: [
            .toolCall(
                id: "call-1",
                name: "fixture_lookup",
                input: .object(["query": .string("starcat")]),
                rawInput: nil
            ),
            .toolResult(
                id: "call-1",
                name: "fixture_lookup",
                output: .object(["summary": .string("fixture-result")]),
                isError: false
            ),
            .completed,
        ])
    }

    @Test("Host 在首个有效输出超时后终止静默进程")
    func terminatesProcessWhenFirstOutputTimesOut() async throws {
        let host = ExternalAgentRuntimeHost(firstOutputTimeout: .milliseconds(100))

        await #expect(throws: ExternalAgentRuntimeError.firstOutputTimedOut(nil)) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostSilentFixtureDriver()
            ) { _ in }
        }
    }

    @Test("合法协议活动会续期首输出看门狗")
    func protocolActivityExtendsFirstOutputWatchdog() async throws {
        let collector = ExternalHostEventCollector()
        // fixture 总时长约 240ms：旧实现会在 180ms 固定超时，新实现收到 80ms
        // 间隔的合法协议帧后会续期，并稳定等到最终可见输出。
        let host = ExternalAgentRuntimeHost(firstOutputTimeout: .milliseconds(180))

        try await host.execute(
            runID: UUID(),
            driver: ExternalHostProtocolActivityFixtureDriver()
        ) { event in
            await collector.append(event)
        }

        assertFirstOutputLatency(
            in: await collector.events,
            followedBy: [.assistantDelta("ready"), .completed]
        )
    }

    @Test("Host 在已有输出后仍会终止停止协议活动的进程")
    func terminatesProcessWhenProtocolActivityStops() async throws {
        let host = ExternalAgentRuntimeHost(firstOutputTimeout: .milliseconds(100))

        await #expect(throws: ExternalAgentRuntimeError.protocolActivityTimedOut(nil)) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostOutputThenSilentFixtureDriver()
            ) { _ in }
        }
    }

    @Test("stdout 提前关闭时等待并报告真实退出状态")
    func reportsDelayedProcessExitStatusAndSafeDiagnostic() async throws {
        let host = ExternalAgentRuntimeHost()
        let expectedDiagnostic = "Termination reason: exit. "
            + "Codex App Server stderr summary (1 lines): codex model cache."

        await #expect(throws: ExternalAgentRuntimeError.processExited(23, expectedDiagnostic)) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostDelayedExitFixtureDriver()
            ) { _ in }
        }
    }

    @Test("DeepSeek Cordis YAML 错误只暴露安全行列诊断")
    func reportsSafeYAMLConfigurationDiagnostic() async throws {
        let host = ExternalAgentRuntimeHost()
        let expectedDiagnostic = "Termination reason: exit. "
            + "DeepSeek Harness stderr summary (2 lines): "
            + "configuration parse (line 41, column 17)."

        await #expect(throws: ExternalAgentRuntimeError.processExited(1, expectedDiagnostic)) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostYAMLFailureFixtureDriver()
            ) { _ in }
        }
    }

    @Test("DeepSeek MCP 冷启动失败时重建 carrier 且不重复模型 turn")
    func retriesDeepSeekMCPStartupFailureBeforeTurn() async throws {
        let collector = ExternalHostEventCollector()
        let factory = ExternalHostRetryDriverFactory()
        let host = ExternalAgentRuntimeHost()

        try await host.execute(
            runID: UUID(),
            driverFactory: { factory.makeDriver() },
            mcpStartupRetryLimit: 1
        ) { event in
            await collector.append(event)
        }

        #expect(factory.attemptCount == 2)
        assertFirstOutputLatency(
            in: await collector.events,
            followedBy: [.completed]
        )
    }

    @Test("Provider 关闭 stdin 后写回只结束 Run，不会触发 SIGPIPE 终止 App")
    func closedProviderStdinBecomesRecoverableRuntimeError() async throws {
        let host = ExternalAgentRuntimeHost()

        await #expect(throws: ExternalAgentRuntimeError.processClosedBeforeCompletion(nil)) {
            try await host.execute(
                runID: UUID(),
                driver: ExternalHostClosedStdinFixtureDriver()
            ) { _ in }
        }
    }

    /// 首输出延迟取决于当前机器调度，测试只校验 Host 在第一个产品事件前发送非负实测值，
    /// 其余 Provider 事件仍保持原有顺序。
    private func assertFirstOutputLatency(
        in events: [ExternalAgentProtocolEvent],
        followedBy expectedEvents: [ExternalAgentProtocolEvent]
    ) {
        guard let firstEvent = events.first,
              case .firstOutputLatency(let milliseconds) = firstEvent
        else {
            Issue.record("Host 未在首个产品事件前报告 firstOutputLatency")
            return
        }
        #expect(milliseconds >= 0)
        #expect(Array(events.dropFirst()) == expectedEvents)
    }
}

/// 用同步锁保护 factory 计数，因为 Host 的 driverFactory 是同步 `@Sendable` 闭包；
/// 测试必须证明第一次 Cordis MCP 激活失败后确实创建了全新的 carrier driver。
private final class ExternalHostRetryDriverFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func makeDriver() -> any ExternalAgentProtocolDriver {
        let shouldFail = lock.withLock {
            attempts += 1
            return attempts == 1
        }
        return ExternalHostDeepSeekRetryFixtureDriver(shouldFail: shouldFail)
    }
}

private final class ExternalHostDeepSeekRetryFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessPOC
    let processConfiguration: ExternalAgentProcessConfiguration

    init(shouldFail: Bool) {
        let command: String
        if shouldFail {
            command = "read first; printf '%s\\n' 'mcp-client(starcat): initial connection or tool synchronization failed' >&2; exit 1"
        } else {
            command = "read first; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\"}'"
        }
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            environment: ExternalAgentProcessEnvironment.filtered(),
            currentDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard frame[external: "method"]?.stringValue == "fixture/completed" else {
            return ExternalAgentProtocolOutput()
        }
        return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private actor ExternalHostEventCollector {
    private(set) var events: [ExternalAgentProtocolEvent] = []

    func append(_ event: ExternalAgentProtocolEvent) {
        events.append(event)
    }
}

private final class ExternalHostFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read line; printf '%s\\n' 'codex startup diagnostic' '' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/delta\",\"params\":{\"delta\":\"fixture\"}}' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\",\"params\":{}}'; sleep 2",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        switch frame[external: "method"]?.stringValue {
        case "fixture/delta":
            return ExternalAgentProtocolOutput(events: [
                .assistantDelta(frame[external: "params"]?[external: "delta"]?.stringValue ?? "")
            ])
        case "fixture/completed":
            return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostYAMLFailureFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; printf '%s\\n' "
                + "'Error: plugin tree failed to load: failed to parse config file /private/secret.yml' "
                + "'YAMLException: bad indentation of a mapping entry (41:17)' >&2; exit 1",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput()
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostMalformedJSONFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "read first; printf '%s\\n' '{\"jsonrpc\":'"],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput()
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostToolFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"fixture/tool\",\"params\":{}}'; read result; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\",\"params\":{}}'",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        switch frame[external: "method"]?.stringValue {
        case "fixture/tool":
            return ExternalAgentProtocolOutput(toolRequests: [ExternalAgentToolRequest(
                requestID: .number(42),
                callID: "call-1",
                name: "fixture_lookup",
                input: .object(["query": .string("starcat")]),
                rawInput: nil
            )])
        case "fixture/completed":
            return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    func toolResponseFrame(
        for request: ExternalAgentToolRequest,
        result: ExternalAgentToolExecutionResult
    ) -> AgentJSONValue? {
        .object([
            "jsonrpc": .string("2.0"),
            "id": request.requestID,
            "result": .object(["success": .bool(!result.isError)]),
        ])
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostSilentFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "read first; sleep 10"],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput()
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostProtocolActivityFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; sleep 0.08; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/progress\"}'; sleep 0.08; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/progress\"}'; sleep 0.08; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/delta\",\"params\":{\"delta\":\"ready\"}}' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\"}'",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        switch frame[external: "method"]?.stringValue {
        case "fixture/delta":
            return ExternalAgentProtocolOutput(events: [
                .assistantDelta(frame[external: "params"]?[external: "delta"]?.stringValue ?? "")
            ])
        case "fixture/completed":
            return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostOutputThenSilentFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/delta\",\"params\":{\"delta\":\"started\"}}'; sleep 10",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard frame[external: "method"]?.stringValue == "fixture/delta" else {
            return ExternalAgentProtocolOutput()
        }
        return ExternalAgentProtocolOutput(events: [
            .assistantDelta(frame[external: "params"]?[external: "delta"]?.stringValue ?? "")
        ])
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostDelayedExitFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; printf '%s\\n' 'ERROR codex_models_manager::cache: stale cache' >&2; exec 1>&-; sleep 0.08; exit 23",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput()
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}

private final class ExternalHostClosedStdinFixtureDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration = ExternalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "read first; exec 0<&-; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/respond\",\"params\":{}}'; sleep 2",
        ],
        environment: ExternalAgentProcessEnvironment.filtered(),
        currentDirectoryURL: FileManager.default.temporaryDirectory
    )

    func initialFrames() throws -> [AgentJSONValue] {
        [.jsonRPCRequest(id: 1, method: "fixture/start")]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard frame[external: "method"]?.stringValue == "fixture/respond" else {
            return ExternalAgentProtocolOutput()
        }
        return ExternalAgentProtocolOutput(outboundFrames: [
            .jsonRPCRequest(id: 2, method: "fixture/response")
        ])
    }

    func cancellationFrame() -> AgentJSONValue? { nil }
    func shutdownFrame() -> AgentJSONValue? { nil }
}
