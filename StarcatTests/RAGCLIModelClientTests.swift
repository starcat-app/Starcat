//
//  RAGCLIModelClientTests.swift
//  StarcatTests
//
//  验证知识库 RAG 的 CLI 隔离参数、JSONL 协议边界和后端偏好持久化。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAG CLI model client")
struct RAGCLIModelClientTests {

    @Test("Codex 调用忽略用户配置、关闭工具，并只从 stdin 接收 RAG 内容")
    func codexInvocationUsesIsolatedTextOnlyMode() throws {
        let secret = "rag-private-question-\(UUID().uuidString)"
        let invocation = try RAGCLIInvocationFactory().make(
            provider: .codex,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            request: makeRequest(userPrompt: secret),
            workingDirectory: URL(fileURLWithPath: "/tmp/starcat-rag-cli-test", isDirectory: true)
        )

        #expect(invocation.arguments.contains("--ignore-user-config"))
        #expect(invocation.arguments.contains("--ignore-rules"))
        #expect(invocation.arguments.contains("--ephemeral"))
        #expect(invocation.arguments.contains("read-only"))
        #expect(invocation.arguments.contains("shell_tool"))
        #expect(invocation.arguments.contains("multi_agent"))
        #expect(invocation.arguments.contains(secret) == false)
        #expect(String(decoding: invocation.standardInput, as: UTF8.self).contains(secret))
    }

    @Test("Claude 调用启用 safe mode、空工具集和无会话持久化")
    func claudeInvocationUsesIsolatedTextOnlyMode() throws {
        let invocation = try RAGCLIInvocationFactory().make(
            provider: .claude,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            request: makeRequest(userPrompt: "question"),
            workingDirectory: URL(fileURLWithPath: "/tmp/starcat-rag-cli-test", isDirectory: true)
        )

        #expect(invocation.arguments.contains("--safe-mode"))
        #expect(invocation.arguments.contains("--no-session-persistence"))
        #expect(invocation.arguments.contains("--permission-mode"))
        let toolsIndex = try #require(invocation.arguments.firstIndex(of: "--tools"))
        #expect(invocation.arguments[toolsIndex + 1].isEmpty)
    }

    @Test("Codex JSONL 只接受文本与 usage，工具事件立即拒绝")
    func codexParserEnforcesTextOnlyBoundary() {
        let parser = RAGCLIJSONLineParser(provider: .codex)

        #expect(parser.parse(#"{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}"#) == [.delta("answer")])
        #expect(parser.parse(#"{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3,"cached_input_tokens":4}}"#) == [
            .usage(AIChatUsage(
                inputTokens: 12,
                outputTokens: 3,
                cachedTokens: 4,
                reasoningTokens: 0,
                totalTokens: 15
            )),
        ])
        #expect(parser.parse(#"{"type":"item.started","item":{"type":"command_execution","command":"pwd"}}"#) == [
            .prohibitedTool("command_execution"),
        ])
    }

    @Test("Claude stream-json 转换增量文本，并拒绝非空工具集与 tool_use")
    func claudeParserEnforcesTextOnlyBoundary() {
        let parser = RAGCLIJSONLineParser(provider: .claude)

        #expect(parser.parse(#"{"type":"system","subtype":"init","model":"claude-sonnet","tools":[]}"#) == [
            .model("claude-sonnet"),
        ])
        #expect(parser.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}"#) == [
            .delta("hello"),
        ])
        #expect(parser.parse(#"{"type":"system","subtype":"init","tools":["Read"]}"#) == [
            .prohibitedTool("Claude initialized with 1 tools"),
        ])
        #expect(parser.parse(#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read"}}}"#) == [
            .prohibitedTool("tool_use"),
        ])
    }

    @Test("App Store 只暴露 API，Direct 才暴露两个 CLI")
    func inferenceBackendRespectsDistributionChannel() {
        #expect(RAGInferenceBackend.available(using: DistributionGate(channel: .appStore)) == [.api])
        #expect(RAGInferenceBackend.available(using: DistributionGate(channel: .direct)) == [
            .api,
            .codexCLI,
            .claudeCLI,
        ])
    }

    @Test("CLI 探测返回可执行路径和版本")
    func runtimeInspectorReportsAvailableRuntime() async {
        let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let inspector = RAGCLIRuntimeInspector(
            resolver: { _ in executableURL },
            versionReader: { _, _ in "codex-cli 0.146.0" }
        )

        #expect(await inspector.inspect(.codex) == .available(
            executableURL: executableURL,
            version: "codex-cli 0.146.0"
        ))
    }

    @Test("CLI 探测区分未安装与版本检测失败")
    func runtimeInspectorSeparatesMissingAndFailedRuntime() async {
        let missing = RAGCLIRuntimeInspector(
            resolver: { provider in
                throw RAGCLIRuntimeError.executableNotFound(provider.executableName)
            },
            versionReader: { _, _ in "unused" }
        )
        #expect(await missing.inspect(.claude) == .notInstalled)

        let failed = RAGCLIRuntimeInspector(
            resolver: { _ in URL(fileURLWithPath: "/broken/claude") },
            versionReader: { _, _ in
                throw RAGCLIRuntimeError.invalidOutput("empty --version output")
            }
        )
        #expect(await failed.inspect(.claude) == .failed(detail: "empty --version output"))
    }

    private func makeRequest(userPrompt: String) -> AIChatRequest {
        AIChatRequest(
            systemPrompt: "Answer from supplied evidence.",
            userPrompt: userPrompt,
            model: "ignored-by-cli",
            parameters: .summaryDefault
        )
    }
}

@MainActor
@Suite("RAG inference backend settings")
struct RAGInferenceBackendSettingsTests {

    @Test("RAG 推理后端默认 API，并可独立持久化 CLI 选择")
    func inferenceBackendPersists() {
        let suiteName = "test.starcat.rag-cli-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        #expect(settings.ragInferenceBackend == .api)

        settings.ragInferenceBackend = .claudeCLI
        let restored = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        #expect(restored.ragInferenceBackend == .claudeCLI)
        #expect(restored.aiChatTask == settings.aiChatTask)
    }
}
