//
//  ExternalAgentProtocolAdapterTests.swift
//  StarcatTests
//
//  Codex App Server 与 DeepSeek Harness rc.8 JSON-RPC fixture 测试。
//
//  测试只驱动协议状态机，不启动真实 Provider 进程；真实 Codex smoke 作为独立 POC
//  验证执行，避免单测依赖用户登录态和网络。
//

import Foundation
import Testing
@testable import Starcat

@Suite("External Agent Protocol Adapters")
struct ExternalAgentProtocolAdapterTests {

    @Test("Codex adapter 完成 initialize、thread 与 turn 握手")
    func codexHandshakeAndDeltaMapping() throws {
        let request = fixtureRequest()
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: request)

        #expect(try driver.initialFrames().first?[external: "method"]?.stringValue == "initialize")

        let initialized = try driver.receive(response(id: 1, result: .object([:])))
        #expect(initialized.outboundFrames.map { $0[external: "method"]?.stringValue } == [
            "initialized", "thread/start"
        ])

        let threadStarted = try driver.receive(response(
            id: 2,
            result: .object(["thread": .object(["id": .string("thread-1")])])
        ))
        #expect(threadStarted.outboundFrames.first?[external: "method"]?.stringValue == "turn/start")

        let delta = try driver.receive(notification(
            method: "item/agentMessage/delta",
            params: .object(["delta": .string("hello")])
        ))
        #expect(delta.events == [.assistantDelta("hello")])

        let completed = try driver.receive(notification(
            method: "turn/completed",
            params: .object(["turn": .object(["status": .string("completed")])])
        ))
        #expect(completed.events == [.completed])
        #expect(completed.isTerminal)
    }

    @Test("DeepSeek adapter 严格过滤 session 并映射 assistant message")
    func deepSeekSessionFilteringAndMessageMapping() throws {
        #if arch(arm64)
        let fixture = try DeepSeekCarrierFixture()
        defer { fixture.cleanup() }
        let request = fixtureRequest()
        let adapter = try DeepSeekHarnessAdapter(
            executableURL: fixture.executableURL,
            provider: "deepseek-official",
            modelOverride: "deepseek-test",
            cordisConfigURL: fixture.configURL,
            environment: [:]
        )
        let driver = try adapter.makeDriver(request: request)

        let initialized = try driver.receive(response(
            id: 1,
            result: .object(["serverInfo": .object(["name": .string("deepseek-harness-sdk-runtime")])])
        ))
        #expect(initialized.outboundFrames.first?[external: "method"]?.stringValue == "session/prompt")

        let wrongSession = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string("other"),
                "event": assistantMessageEvent("wrong"),
            ])
        ))
        #expect(wrongSession.events.isEmpty)

        let sessionID = request.runID.uuidString.lowercased()
        let message = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": assistantMessageEvent("right"),
            ])
        ))
        #expect(message.events == [.assistantMessage("right", usage: nil)])

        let idle = try driver.receive(notification(
            method: "session.status",
            params: .object([
                "sessionId": .string(sessionID),
                "status": .string("idle"),
            ])
        ))
        #expect(idle.events == [.completed])
        #expect(idle.isTerminal)
        #else
        // 官方 rc.8 carrier 没有 Intel 产物；universal 构建仍需明确验证该 slice 拒绝运行。
        #expect(throws: ExternalAgentRuntimeError.unsupportedArchitecture(
            "DeepSeek Harness rc.8 carrier is arm64-only on macOS"
        )) {
            _ = try DeepSeekHarnessAdapter(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                provider: "deepseek-official",
                modelOverride: "deepseek-test",
                cordisConfigURL: URL(fileURLWithPath: "/tmp/starcat.cordis.yml"),
                environment: [:]
            )
        }
        #endif
    }

    private func fixtureRequest() -> ExternalAgentRunRequest {
        ExternalAgentRunRequest(
            runID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            prompt: "hello",
            modelName: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    private func response(id: Int, result: AgentJSONValue) -> AgentJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "result": result,
        ])
    }

    private func notification(method: String, params: AgentJSONValue) -> AgentJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
    }

    private func assistantMessageEvent(_ text: String) -> AgentJSONValue {
        .object([
            "type": .string("assistant/message"),
            "data": .object([
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(text)])
                    ]),
                ])
            ]),
        ])
    }
}

private struct DeepSeekCarrierFixture {
    let directoryURL: URL
    let executableURL: URL
    let configURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-dsh-fixture-\(UUID().uuidString)", isDirectory: true)
        executableURL = directoryURL.appendingPathComponent("dsh-jsonrpc-agent-pkg-macos-arm64")
        configURL = directoryURL.appendingPathComponent("starcat.cordis.yml")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for url in [
            executableURL,
            URL(fileURLWithPath: executableURL.path + "-rg"),
            URL(fileURLWithPath: executableURL.path + "-spawn-helper"),
        ] {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        _ = FileManager.default.createFile(atPath: configURL.path, contents: Data("plugins: []\n".utf8))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
