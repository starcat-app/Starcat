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

        #expect(await collector.events == [.assistantDelta("fixture"), .completed])
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
            toolCallHandler: { request in
                #expect(request.name == "fixture_lookup")
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

        #expect(await collector.events == [
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
