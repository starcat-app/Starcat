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

    @Test("Host 逐行读取事件并在终态回收进程")
    func streamsJSONLinesUntilTerminalEvent() async throws {
        let collector = ExternalHostEventCollector()
        let host = ExternalAgentRuntimeHost()
        let runID = UUID()

        try await host.execute(runID: runID, driver: ExternalHostFixtureDriver()) { event in
            await collector.append(event)
        }

        #expect(await collector.events == [.assistantDelta("fixture"), .completed])
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
            "read line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/delta\",\"params\":{\"delta\":\"fixture\"}}' '{\"jsonrpc\":\"2.0\",\"method\":\"fixture/completed\",\"params\":{}}'; sleep 2",
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
