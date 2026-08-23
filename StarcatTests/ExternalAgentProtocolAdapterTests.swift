//
//  ExternalAgentProtocolAdapterTests.swift
//  StarcatTests
//
//  Codex App Server 与 DeepSeek Harness 0.1.1rc1 JSON-RPC fixture 测试。
//
//  常规测试只驱动协议状态机，不依赖用户登录态和网络；显式设置
//  `STARCAT_RUN_CODEX_INTEGRATION=1` / `STARCAT_RUN_DEEPSEEK_INTEGRATION=1`
//  时，额外执行对应本机 Runtime 的真实 turn smoke。
//

import Foundation
import Testing
@testable import Starcat

/// `xcodebuild` 不会把任意 shell 环境变量转发给 test host。保留环境变量入口供
/// Xcode Scheme 使用，同时允许 CI 通过 `-DSTARCAT_RUN_CODEX_INTEGRATION` 显式启用。
private let shouldRunCodexIntegration: Bool = {
#if STARCAT_RUN_CODEX_INTEGRATION
    true
#else
    ProcessInfo.processInfo.environment["STARCAT_RUN_CODEX_INTEGRATION"] == "1"
#endif
}()

private let shouldRunDeepSeekIntegration: Bool = {
#if STARCAT_RUN_DEEPSEEK_INTEGRATION
    true
#else
    ProcessInfo.processInfo.environment["STARCAT_RUN_DEEPSEEK_INTEGRATION"] == "1"
#endif
}()

@Suite("External Agent Protocol Adapters")
struct ExternalAgentProtocolAdapterTests {

    @Test("未知 Runtime 事件仅保留有界脱敏业务数据")
    func externalTracePayloadRedactsSensitiveFields() throws {
        let payload = ExternalAgentTracePayload.sanitized(.object([
            "apiKey": .string("fixture-api-key"),
            "env": .object(["HOME": .string("/private/home")]),
            "token": .string("fixture-token"),
            "tools": .array([.object(["name": .string("private-tool")])]),
            "tokenUsage": .object(["inputTokens": .number(12)]),
            "result": .string("visible result"),
        ]))
        let json = try payload.jsonString()

        #expect(json.contains("visible result"))
        #expect(json.contains("inputTokens"))
        #expect(json.contains("<redacted>"))
        #expect(!json.contains("fixture-api-key"))
        #expect(!json.contains("fixture-token"))
        #expect(!json.contains("private-tool"))
        #expect(!json.contains("/private/home"))
    }

    @Test("Codex adapter 完成 initialize、thread 与 turn 握手")
    func codexHandshakeAndDeltaMapping() throws {
        let request = fixtureRequest()
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: request)

        #expect(try driver.initialFrames().first?[external: "method"]?.stringValue == "initialize")

        let initialized = try driver.receive(response(id: 1, result: .object([:])))
        #expect(initialized.outboundFrames.map { $0[external: "method"]?.stringValue } == [
            "initialized", "config/read"
        ])
        let configRead = try driver.receive(response(id: 2, result: .object([
            "layers": .array([
                .object(["config": .object(["mcp_servers": .object([
                    "user-mcp": .object([
                        "command": .string("fixture-mcp"),
                        "args": .array([.string("serve")]),
                    ]),
                ])])]),
                .object(["config": .object(["mcp_servers": .object([
                    "plugin-mcp": .object(["url": .string("https://example.com/mcp")]),
                    "user-mcp": .object(["startup_timeout_sec": .number(5)]),
                ])])]),
            ]),
        ])))
        let threadStart = try #require(configRead.outboundFrames.first)
        #expect(threadStart[external: "method"]?.stringValue == "thread/start")
        #expect(threadStart[external: "params"]?[external: "model"] == nil)
        let dynamicTool = threadStart[external: "params"]?[external: "dynamicTools"]?.externalArray?.first
        #expect(dynamicTool?[external: "name"]?.stringValue == "fixture_lookup")
        let config = threadStart[external: "params"]?[external: "config"]
        #expect(config?[external: "features"]?[external: "plugins"]?.externalBool == false)
        #expect(config?[external: "features"]?[external: "hooks"]?.externalBool == false)
        #expect(config?[external: "features"]?[external: "apps"]?.externalBool == false)
        #expect(config?[external: "features"]?[external: "enable_mcp_apps"]?.externalBool == false)
        #expect(config?[external: "mcp_servers"]?[external: "user-mcp"]?[external: "enabled"]?.externalBool == false)
        #expect(config?[external: "mcp_servers"]?[external: "user-mcp"]?[external: "command"]?.stringValue == "fixture-mcp")
        #expect(config?[external: "mcp_servers"]?[external: "user-mcp"]?[external: "startup_timeout_sec"]?.externalNumber == 5)
        #expect(config?[external: "mcp_servers"]?[external: "plugin-mcp"]?[external: "enabled"]?.externalBool == false)

        let threadStarted = try driver.receive(response(
            id: 10_000,
            result: .object(["thread": .object(["id": .string("thread-1")])])
        ))
        let turnStart = try #require(threadStarted.outboundFrames.first)
        #expect(turnStart[external: "method"]?.stringValue == "turn/start")
        #expect(turnStart[external: "params"]?[external: "model"]?.stringValue == "test-model")
        #expect(turnStart[external: "params"]?[external: "effort"]?.stringValue == "high")
        #expect(turnStart[external: "params"]?[external: "summary"]?.stringValue == "detailed")

        let delta = try driver.receive(notification(
            method: "item/agentMessage/delta",
            params: .object(["delta": .string("hello")])
        ))
        #expect(delta.events == [.assistantDelta("hello")])

        let completedItem = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("agentMessage"),
                "text": .string("hello"),
            ])])
        ))
        #expect(completedItem.events == [.assistantMessage("hello", usage: nil)])

        let usage = try driver.receive(notification(
            method: "thread/tokenUsage/updated",
            params: .object(["tokenUsage": .object([
                "total": .object([
                    "inputTokens": .number(12),
                    "outputTokens": .number(3),
                    "cachedInputTokens": .number(4),
                    "cacheWriteInputTokens": .number(1),
                    "reasoningOutputTokens": .number(2),
                    "totalTokens": .number(15),
                ]),
                "last": .object(["totalTokens": .number(7)]),
                "modelContextWindow": .number(128_000),
            ])])
        ))
        #expect(usage.events.contains { event in
            guard case .usage(let value) = event else { return false }
            return value.inputTokens == 12
                && value.outputTokens == 3
                && value.cachedTokens == 4
                && value.cacheWriteTokens == 1
                && value.reasoningTokens == 2
                && value.totalTokens == 15
                && value.contextWindowUsedTokens == 7
                && value.contextWindowLimitTokens == 128_000
        })
        #expect(usage.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "usage:current"
                && trace.kind == .request
                && trace.usage?.contextWindowLimitTokens == 128_000
        })

        let completed = try driver.receive(notification(
            method: "turn/completed",
            params: .object(["turn": .object(["status": .string("completed")])])
        ))
        #expect(completed.events == [.completed])
        #expect(completed.isTerminal)
    }

    @Test("Codex commentary 投影为过程日志且不覆盖最终回答")
    func codexCommentaryUsesTracePhase() throws {
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: fixtureRequest())

        let started = try driver.receive(notification(
            method: "item/started",
            params: .object(["item": .object([
                "id": .string("commentary-1"),
                "type": .string("agentMessage"),
                "phase": .string("commentary"),
                "text": .string(""),
            ])])
        ))
        #expect(started.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "commentary-1" && trace.kind == .commentary && trace.status == .running
        })

        let delta = try driver.receive(notification(
            method: "item/agentMessage/delta",
            params: .object([
                "itemId": .string("commentary-1"),
                "delta": .string("**准备检索仓库**"),
            ])
        ))
        #expect(delta.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.summary == "**准备检索仓库**"
                && trace.details.first?.format == .markdown
        })
        #expect(!delta.events.contains { event in
            if case .assistantDelta = event { return true }
            return false
        })

        let completed = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("commentary-1"),
                "type": .string("agentMessage"),
                "phase": .string("commentary"),
                "text": .string("**准备检索仓库**"),
            ])])
        ))
        #expect(completed.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .commentary && trace.status == .completed
        })
        #expect(!completed.events.contains { event in
            if case .assistantMessage = event { return true }
            return false
        })
    }

    @Test("External prompt 注入 App 语言与用户可见 preamble 约束")
    func externalPromptCarriesLanguageAndPreambleRules() {
        let prompt = ExternalAgentPromptBuilder.build(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周报",
            context: AgentRunContext(sourceDescription: "Unit Snapshot"),
            localeIdentifier: "zh-Hans_CN",
            preferredLanguage: "Simplified Chinese"
        )

        #expect(prompt.contains("App locale: zh-Hans_CN"))
        #expect(prompt.contains("Preferred output language: Simplified Chinese"))
        #expect(prompt.contains("Before each tool call"))
        #expect(prompt.contains("Do not expose hidden chain-of-thought"))
    }

    @Test("Codex model/list 解析目录并按服务端默认值修复失效选择")
    func codexModelCatalogSelectionUsesServerDefaults() throws {
        let page = try CodexModelCatalog.parsePage(from: .object([
            "data": .array([
                .object([
                    "id": .string("model-default"),
                    "model": .string("provider-model-default"),
                    "displayName": .string("Default Model"),
                    "isDefault": .bool(true),
                    "defaultReasoningEffort": .string("medium"),
                    "supportedReasoningEfforts": .array([
                        .object(["reasoningEffort": .string("low")]),
                        .object(["reasoningEffort": .string("medium")]),
                        .object(["reasoningEffort": .string("high")]),
                    ]),
                ]),
                .object([
                    "id": .string("model-fast"),
                    "model": .string("provider-model-fast"),
                    "displayName": .string("Fast Model"),
                    "isDefault": .bool(false),
                    "defaultReasoningEffort": .string("low"),
                    "supportedReasoningEfforts": .array([
                        .object(["reasoningEffort": .string("low")]),
                    ]),
                ]),
            ]),
            "nextCursor": .string("cursor-2"),
        ]))

        #expect(page.nextCursor == "cursor-2")
        #expect(page.models.map(\.id) == ["model-default", "model-fast"])
        let catalog = CodexModelCatalog(models: page.models)
        let selection = try #require(catalog.resolvedSelection(
            preferredModelID: "removed-model",
            preferredReasoningEffort: "unsupported"
        ))
        #expect(selection.modelID == "model-default")
        #expect(selection.modelName == "provider-model-default")
        #expect(selection.reasoningEffort == "medium")
    }

    @Test("Codex 模型目录 Driver 完成 initialize 与 model/list 握手")
    func codexModelCatalogDriverHandshake() throws {
        let resultBox = CodexModelCatalogResultBox()
        let driver = CodexModelCatalogDriver(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: [:],
            resultBox: resultBox
        )

        #expect(try driver.initialFrames().first?[external: "method"]?.stringValue == "initialize")
        let initialized = try driver.receive(response(id: 1, result: .object([:])))
        #expect(initialized.outboundFrames.map { $0[external: "method"]?.stringValue } == [
            "initialized", "model/list",
        ])

        let completed = try driver.receive(response(id: 2, result: .object([
            "data": .array([
                .object([
                    "id": .string("gpt-fixture"),
                    "model": .string("gpt-fixture"),
                    "displayName": .string("GPT Fixture"),
                    "isDefault": .bool(true),
                    "supportedReasoningEfforts": .array([]),
                ]),
            ]),
        ])))

        #expect(completed.events == [.completed])
        #expect(completed.isTerminal)
        #expect(try resultBox.requiredCatalog().models.map(\.id) == ["gpt-fixture"])
    }

    @Test(
        "本机 Codex App Server 完成模型目录与真实 turn",
        .enabled(if: shouldRunCodexIntegration)
    )
    func installedCodexCompletesModelCatalogAndRealTurn() async throws {
        let executablePath = ProcessInfo.processInfo.environment["STARCAT_CODEX_EXECUTABLE"]
            ?? "/opt/homebrew/bin/codex"
        let executableURL = URL(fileURLWithPath: executablePath)
        #expect(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let environment = ExternalAgentProcessEnvironment.filtered()
        let catalog = try await CodexModelCatalogClient(
            executableURL: executableURL,
            environment: environment,
            firstOutputTimeout: .seconds(60)
        ).load()
        let selection = try #require(catalog.resolvedSelection(
            preferredModelID: nil,
            preferredReasoningEffort: nil
        ))

        let request = ExternalAgentRunRequest(
            runID: UUID(),
            prompt: "Call fixture_lookup once with query starcat. After the tool result, reply with exactly STARCAT_CODEX_SMOKE_OK and nothing else.",
            modelName: selection.modelName,
            reasoningEffort: selection.reasoningEffort,
            workingDirectory: FileManager.default.temporaryDirectory,
            tools: [AgentToolDefinition(
                name: "fixture_lookup",
                description: "Returns the Starcat integration fixture.",
                inputSchema: AgentJSONSchema(
                    type: .object,
                    properties: ["query": AgentJSONSchema(type: .string)],
                    required: ["query"]
                )
            )]
        )
        let driver = try CodexAppServerAdapter(
            executableURL: executableURL,
            environment: environment
        ).makeDriver(request: request)
        let collector = CodexIntegrationEventCollector()

        try await ExternalAgentRuntimeHost(firstOutputTimeout: .seconds(180)).execute(
            runID: request.runID,
            driver: driver,
            toolCallHandler: { _ in
                ExternalAgentToolExecutionResult(
                    output: .object(["summary": .string("fixture-result")]),
                    modelText: "fixture-result",
                    isError: false,
                    artifactMarkdown: nil
                )
            }
        ) { event in
            await collector.append(event)
        }

        let events = await collector.events
        let assistantText = events.reduce(into: "") { text, event in
            switch event {
            case .assistantDelta(let delta), .assistantMessage(let delta, _):
                text += delta
            default:
                break
            }
        }
        #expect(assistantText.contains("STARCAT_CODEX_SMOKE_OK"))
        #expect(events.contains { event in
            guard case .toolCall(_, let name, _, _) = event else { return false }
            return name == "fixture_lookup"
        })
        #expect(events.contains { event in
            guard case .toolResult(_, let name, _, let isError) = event else { return false }
            return name == "fixture_lookup" && !isError
        })
        #expect(events.contains(.completed))
    }

    @Test(
        "本机 DeepSeek Harness 0.1.1rc1 通过 MCP 读取 Starcat 数据",
        .enabled(if: shouldRunDeepSeekIntegration)
    )
    @MainActor
    func installedDeepSeekHarnessCompletesRealTurn() async throws {
        #if arch(arm64)
        let environment = ProcessInfo.processInfo.environment
        let executablePath = try #require(environment["STARCAT_DEEPSEEK_RUNTIME_PATH"])
        let configPath = try #require(environment["STARCAT_DEEPSEEK_CORDIS_PATH"])
        let apiKey = try #require(environment["DEEPSEEK_API_KEY"])
        #expect(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-deepseek-mcp-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let mcpRuntime = try await StarcatMCPRuntimeTests.makeRuntime(
            allowedToolNames: ["starcat.search_repos"],
            exposesResources: false
        )
        let port = try StarcatMCPPortAvailability.availableDynamicPort()
        let token = UUID().uuidString
        let mcpServer = StarcatMCPLoopbackHTTPServer(
            port: port,
            runtime: mcpRuntime,
            requestValidator: { request in
                guard request.path == "/mcp" else { return .notFound }
                guard request.header("Authorization") == "Bearer \(token)" else {
                    return .unauthorized
                }
                return nil
            }
        )
        defer {
            mcpServer.stop()
            Task { @MainActor in await mcpRuntime.shutdown() }
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        let boundPort = try await mcpServer.startAndWaitUntilReady()

        let request = ExternalAgentRunRequest(
            runID: UUID(),
            prompt: "Use the Starcat repository search tool with limit 1. Reply with STARCAT_MCP_SMOKE_OK and the returned repository full_name.",
            modelName: environment["STARCAT_DEEPSEEK_MODEL"] ?? DeepSeekHarnessRuntime.defaultModel,
            reasoningEffort: nil,
            workingDirectory: workingDirectory,
            tools: [],
            mcpConnection: ExternalAgentMCPConnection(
                endpointURL: URL(string: "http://127.0.0.1:\(boundPort)/mcp")!,
                bearerToken: token
            )
        )
        let adapter = try DeepSeekHarnessAdapter(
            executableURL: URL(fileURLWithPath: executablePath),
            provider: DeepSeekHarnessRuntime.defaultProvider,
            modelOverride: request.modelName,
            cordisConfigURL: URL(fileURLWithPath: configPath),
            environment: ExternalAgentProcessEnvironment.filtered(
                source: environment,
                allowedCredentialKeys: ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL"]
            )
        )
        let collector = CodexIntegrationEventCollector()

        try await ExternalAgentRuntimeHost(firstOutputTimeout: .seconds(180)).execute(
            runID: request.runID,
            driver: try adapter.makeDriver(request: request),
            toolCallHandler: { request in
                ExternalAgentToolExecutionResult(
                    output: .object(["error": .string("Unexpected tool: \(request.name)")]),
                    modelText: "Unexpected tool: \(request.name)",
                    isError: true,
                    artifactMarkdown: nil
                )
            }
        ) { event in
            await collector.append(event)
        }

        let events = await collector.events
        let assistantText = events.reduce(into: "") { text, event in
            switch event {
            case .assistantDelta(let delta), .assistantMessage(let delta, _):
                text += delta
            default:
                break
            }
        }
        #expect(assistantText.contains("STARCAT_MCP_SMOKE_OK"))
        #expect(assistantText.contains("apple/swift"))
        #expect(events.contains { event in
            guard case .toolCall(_, let name, _, _) = event else { return false }
            return name.contains("starcat_search_repos")
        })
        #expect(events.contains { event in
            guard case .toolResult(_, let name, _, let isError) = event else { return false }
            return name.contains("starcat_search_repos") && !isError
        })
        #expect(events.contains(.completed))
        #expect(!events.contains { event in
            guard case .failed = event else { return false }
            return true
        })
        #else
        #expect(Bool(false), "DeepSeek Harness Runtime wheel only supports macOS arm64")
        #endif
    }

    @Test("Codex adapter 映射 dynamic tool 请求并回写结果")
    func codexDynamicToolRoundTrip() throws {
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: fixtureRequest())

        let output = try driver.receive(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(42),
            "method": .string("item/tool/call"),
            "params": .object([
                "callId": .string("call-1"),
                "tool": .string("fixture_lookup"),
                "arguments": .object(["query": .string("starcat")]),
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
            ]),
        ]))

        let request = try #require(output.toolRequests.first)
        #expect(request.requestID == .number(42))
        #expect(request.callID == "call-1")
        #expect(request.name == "fixture_lookup")
        #expect(request.input == .object(["query": .string("starcat")]))

        let response = try #require(driver.toolResponseFrame(
            for: request,
            result: ExternalAgentToolExecutionResult(
                output: .object(["summary": .string("ok")]),
                modelText: "{\"summary\":\"ok\"}",
                isError: false,
                artifactMarkdown: nil
            )
        ))
        #expect(response[external: "id"] == .number(42))
        #expect(response[external: "result"]?[external: "success"]?.externalBool == true)
        let contentItem = response[external: "result"]?[external: "contentItems"]?.externalArray?.first
        #expect(contentItem?[external: "text"]?.stringValue == "{\"summary\":\"ok\"}")
    }

    @Test("Codex adapter 保留 reasoning、plan、web search 与 retry 原生事件")
    func codexRuntimeTraceMapping() throws {
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: fixtureRequest())

        _ = try driver.receive(notification(
            method: "item/reasoning/summaryPartAdded",
            params: .object(["itemId": .string("reason-1"), "summaryIndex": .number(0)])
        ))
        let reasoning = try driver.receive(notification(
            method: "item/reasoning/summaryTextDelta",
            params: .object([
                "itemId": .string("reason-1"),
                "summaryIndex": .number(0),
                "delta": .string("检查仓库范围"),
            ])
        ))
        #expect(reasoning.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "reason-1" && trace.kind == .reasoningSummary
        })
        _ = try driver.receive(notification(
            method: "item/reasoning/summaryPartAdded",
            params: .object(["itemId": .string("reason-1"), "summaryIndex": .number(1)])
        ))
        _ = try driver.receive(notification(
            method: "item/reasoning/summaryTextDelta",
            params: .object([
                "itemId": .string("reason-1"),
                "summaryIndex": .number(1),
                "delta": .string("准备调用检索工具"),
            ])
        ))
        let completedReasoning = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("reason-1"),
                "type": .string("reasoning"),
                "status": .string("completed"),
            ])])
        ))
        #expect(completedReasoning.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "reason-1"
                && trace.status == .completed
                && trace.summary == "检查仓库范围\n\n准备调用检索工具"
        })

        let completedOnlyReasoning = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("reason-2"),
                "type": .string("reasoning"),
                "summary": .array([
                    .object(["type": .string("summary_text"), "text": .string("核对证据来源")]),
                    .object(["type": .string("summary_text"), "text": .string("组织最终回答")]),
                ]),
                "status": .string("completed"),
            ])])
        ))
        #expect(completedOnlyReasoning.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "reason-2"
                && trace.summary == "核对证据来源\n\n组织最终回答"
                && trace.details.first?.value == trace.summary
        })

        let rawReasoning = try driver.receive(notification(
            method: "item/reasoning/textDelta",
            params: .object(["itemId": .string("reason-raw"), "delta": .string("hidden chain")])
        ))
        #expect(rawReasoning.events == [.reasoningDelta("hidden chain")])
        let completedRawReasoning = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("reason-raw"),
                "type": .string("reasoning"),
                "text": .string("hidden chain"),
                "status": .string("completed"),
            ])])
        ))
        #expect(completedRawReasoning.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "reason-raw" && trace.summary == nil && trace.details.isEmpty
        })

        let plan = try driver.receive(notification(
            method: "turn/plan/updated",
            params: .object(["plan": .array([
                .object(["step": .string("检索候选仓库"), "status": .string("inProgress")]),
                .object(["step": .string("生成周刊"), "status": .string("pending")]),
            ])])
        ))
        #expect(plan.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .plan && trace.details.count == 2
        })

        let search = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("search-1"),
                "type": .string("webSearch"),
                "query": .string("GitHub trending Swift"),
                "status": .string("completed"),
            ])])
        ))
        #expect(search.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "search-1" && trace.kind == .webSearch && trace.status == .completed
        })

        let retry = try driver.receive(notification(
            method: "error",
            params: .object([
                "willRetry": .bool(true),
                "error": .object(["message": .string("temporary unavailable")]),
            ])
        ))
        #expect(!retry.isTerminal)
        #expect(retry.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .retry && trace.attempt == 1
        })

        let failed = try driver.receive(notification(
            method: "turn/completed",
            params: .object(["turn": .object([
                "status": .string("failed"),
                "error": .object(["message": .string("fixture failure")]),
            ])])
        ))
        #expect(failed.isTerminal)
        #expect(failed.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .error && trace.status == .failed
        })
        #expect(failed.events.contains(.failed("fixture failure")))

        let approval = try driver.receive(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(44),
            "method": .string("item/commandExecution/requestApproval"),
            "params": .object([:]),
        ]))
        #expect(approval.outboundFrames.first?[external: "id"] == .number(44))
        #expect(approval.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .approval && trace.status == .skipped
        })
    }

    @Test("Codex adapter 聚合执行增量、Hook 与未知执行事件")
    func codexRuntimeProgressEventMapping() throws {
        let adapter = CodexAppServerAdapter(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        let driver = try adapter.makeDriver(request: fixtureRequest())

        _ = try driver.receive(notification(
            method: "item/started",
            params: .object(["item": .object([
                "id": .string("command-1"),
                "type": .string("commandExecution"),
                "command": .string("git status --short"),
                "status": .string("inProgress"),
            ])])
        ))
        _ = try driver.receive(notification(
            method: "item/commandExecution/outputDelta",
            params: .object(["itemId": .string("command-1"), "delta": .string("M file\n")])
        ))
        let command = try driver.receive(notification(
            method: "item/commandExecution/outputDelta",
            params: .object(["itemId": .string("command-1"), "delta": .string("?? new\n")])
        ))
        #expect(command.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "command-1"
                && trace.kind == .command
                && trace.status == .running
                && trace.details.first?.value == "M file\n?? new\n"
        })
        let completedCommand = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("command-1"),
                "type": .string("commandExecution"),
                "command": .string("git status --short"),
                "status": .string("completed"),
            ])])
        ))
        #expect(completedCommand.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "command-1"
                && trace.status == .completed
                && trace.details.first?.value == "M file\n?? new\n"
        })

        let hook = try driver.receive(notification(
            method: "hook/completed",
            params: .object(["run": .object([
                "id": .string("hook-1"),
                "eventName": .string("afterToolUse"),
                "status": .string("completed"),
                "sourcePath": .string("/private/config/hooks.json"),
                "entries": .array([.object(["text": .string("formatted")])]),
            ])])
        ))
        #expect(hook.events.contains { event in
            guard case .trace(let trace) = event,
                  let payload = trace.details.first?.value
            else { return false }
            return trace.id == "hook:hook-1"
                && trace.status == .completed
                && payload.contains("formatted")
                && !payload.contains("/private/config/hooks.json")
        })

        let unknown = try driver.receive(notification(
            method: "item/providerExtension/progress",
            params: .object([
                "itemId": .string("extension-1"),
                "result": .string("visible progress"),
                "apiKey": .string("fixture-secret"),
            ])
        ))
        #expect(unknown.events.contains { event in
            guard case .trace(let trace) = event,
                  let payload = trace.details.first?.value
            else { return false }
            return trace.kind == .unknown
                && payload.contains("visible progress")
                && payload.contains("<redacted>")
                && !payload.contains("fixture-secret")
        })

        let imageGeneration = try driver.receive(notification(
            method: "item/completed",
            params: .object(["item": .object([
                "id": .string("image-1"),
                "type": .string("imageGeneration"),
                "status": .string("completed"),
                "result": .string("generated-image"),
                "savedPath": .string("/tmp/generated.png"),
            ])])
        ))
        #expect(imageGeneration.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .tool
                && trace.title == String.l10n("agent.workspace.trace.kind.imageGeneration")
                && trace.details.first?.value.contains("generated-image") == true
        })
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

        let toolCall = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": .object([
                    "type": .string("tool/call"),
                    "data": .object([
                        "callId": .string("call-starcat-1"),
                        "name": .string("mcp__starcat__starcat_search_repos_123456789abc"),
                        "arguments": .string(#"{"limit":5}"#),
                    ]),
                ]),
            ])
        ))
        #expect(toolCall.events.contains { event in
            guard case .toolCall(let id, let name, _, _) = event else { return false }
            return id == "call-starcat-1"
                && name == "mcp__starcat__starcat_search_repos_123456789abc"
        })

        let toolResult = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": .object([
                    "type": .string("tool/result"),
                    "data": .object([
                        "message": .object([
                            "source": .object(["callId": .string("call-starcat-1")]),
                            "content": .array([.object([
                                "type": .string("text"),
                                "text": .string(#"{"total":1}"#),
                            ])]),
                            "isError": .bool(false),
                        ]),
                    ]),
                ]),
            ])
        ))
        #expect(toolResult.events.contains { event in
            guard case .toolResult(let id, let name, _, let isError) = event else { return false }
            return id == "call-starcat-1"
                && name == "mcp__starcat__starcat_search_repos_123456789abc"
                && !isError
        })

        let unknown = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": .object([
                    "type": .string("harness/custom-progress"),
                    "data": .object([
                        "id": .string("custom-1"),
                        "status": .string("working"),
                    ]),
                ]),
            ])
        ))
        #expect(unknown.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "custom-1"
                && trace.kind == .unknown
                && trace.title == "harness/custom-progress"
        })

        let failure = try driver.receive(notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": .object([
                    "type": .string("turn/end"),
                    "data": .object(["reason": .object(["kind": .string("failed")])]),
                ]),
            ])
        ))
        #expect(failure.isTerminal)
        #expect(failure.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .error && trace.status == .failed
        })

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
        // 官方 0.1.1rc1 Runtime wheel 没有 Intel 产物；universal 构建仍需明确验证该 slice 拒绝运行。
        #expect(throws: ExternalAgentRuntimeError.unsupportedArchitecture(
            "DeepSeek Harness 0.1.1rc1 Runtime is arm64-only on macOS"
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

    @Test("DeepSeek adapter 保留步骤、请求、任务与可见 reasoning 内容")
    func deepSeekProjectsDurableSessionEvents() throws {
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
        _ = try driver.receive(response(
            id: 1,
            result: .object(["serverInfo": .object(["name": .string("deepseek-harness-sdk-runtime")])])
        ))
        let sessionID = request.runID.uuidString.lowercased()

        let turn = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "turn/start",
            seq: 1,
            data: .object(["turn": .number(0)])
        ))
        #expect(turn.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "turn:0" && trace.status == .running
        })

        let step = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "step/start",
            seq: 2,
            data: .object(["turn": .number(0), "step": .number(0)])
        ))
        #expect(step.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "turn:0:step:0"
                && trace.parentID == "turn:0"
                && !trace.details.isEmpty
        })

        let requestContext = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "request/context",
            seq: 3,
            data: .object([
                "provider": .string("deepseek-official"),
                "model": .string("deepseek-v4-flash"),
                "contextWindow": .number(131_072),
            ])
        ))
        #expect(requestContext.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "request:0:0" && trace.details.count == 1
        })

        let usage = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "assistant/chunk",
            seq: 4,
            data: .object([
                "turn": .number(0),
                "step": .number(0),
                "chunk": .object([
                    "type": .string("usage"),
                    "usage": .object([
                        "inputTokens": .number(20),
                        "outputTokens": .number(5),
                        "cacheReadTokens": .number(8),
                        "cacheWriteTokens": .number(2),
                        "reasoningTokens": .number(3),
                    ]),
                ]),
            ])
        ))
        #expect(usage.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "turn:0:step:0"
                && trace.usage?.cachedTokens == 8
                && trace.usage?.cacheWriteTokens == 2
                && trace.usage?.reasoningTokens == 3
                && trace.usage?.contextWindowUsedTokens == 33
                && trace.usage?.contextWindowLimitTokens == 131_072
        })

        let requestHeader = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "request/header",
            seq: 5,
            data: .object([
                "reason": .string("initial"),
                "header": .object([
                    "config": .object([
                        "provider": .string("deepseek-official"),
                        "model": .string("deepseek-v4-flash"),
                        "reasoningEffort": .string("high"),
                    ]),
                    "system": .string("private system prompt"),
                    "tools": .array([.object(["apiKey": .string("fixture-secret")])]),
                ]),
            ])
        ))
        #expect(requestHeader.events.contains { event in
            guard case .trace(let trace) = event,
                  trace.kind == .request,
                  let payload = trace.details.first?.value
            else { return false }
            return trace.id == "request:0:0"
                && payload.contains("deepseek-v4-flash")
                && !payload.contains("private system prompt")
                && !payload.contains("fixture-secret")
        })

        let assistant = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "assistant/message",
            seq: 6,
            data: .object([
                "turn": .number(0),
                "step": .number(0),
                "message": .object([
                    "id": .string("assistant-1"),
                    "content": .array([
                        .object(["type": .string("reasoning"), "text": .string("先核对仓库范围")]),
                        .object(["type": .string("text"), "text": .string("已完成")]),
                    ]),
                ]),
            ])
        ))
        #expect(assistant.events.contains(.assistantMessage("已完成", usage: nil)))
        #expect(assistant.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "reasoning:assistant-1"
                && trace.kind == .reasoningSummary
                && trace.summary == "先核对仓库范围"
                && trace.details.first?.format == .markdown
        })

        let todos = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "todo/write",
            seq: 6,
            data: .object(["todos": .array([
                .object(["content": .string("读取仓库"), "status": .string("completed")]),
                .object(["content": .string("生成总结"), "status": .string("in_progress")]),
            ])])
        ))
        #expect(todos.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "todo" && trace.kind == .todo && trace.status == .running
        })

        let unknown = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "plugin/custom",
            seq: 7,
            data: .object([
                "status": .string("working"),
                "apiKey": .string("fixture-secret"),
                "result": .string("visible result"),
            ])
        ))
        #expect(unknown.events.contains { event in
            guard case .trace(let trace) = event,
                  let payload = trace.details.first?.value
            else { return false }
            return trace.kind == .unknown
                && trace.status == .running
                && payload.contains("visible result")
                && payload.contains("<redacted>")
                && !payload.contains("fixture-secret")
        })

        _ = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "compaction/start",
            seq: 8,
            data: .object(["compactionId": .string("compact-1")])
        ))
        _ = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "compaction/summary",
            seq: 9,
            data: .object([
                "compactionId": .string("compact-1"),
                "summary": .array([.object([
                    "type": .string("text"),
                    "text": .string("保留仓库范围与工具结果"),
                ])]),
                "rawOutput": .string("private compaction transcript"),
            ])
        ))
        let compactionEnd = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "compaction/end",
            seq: 10,
            data: .object(["compactionId": .string("compact-1")])
        ))
        #expect(compactionEnd.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.id == "compaction:compact-1"
                && trace.status == .completed
                && trace.details.contains { $0.value.contains("保留仓库范围与工具结果") }
                && !trace.details.contains { $0.value.contains("private compaction transcript") }
        })

        let blocked = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "turn/end",
            seq: 11,
            data: .object([
                "turn": .number(0),
                "reason": .object(["kind": .string("blocked")]),
            ])
        ))
        #expect(!blocked.isTerminal)
        #expect(blocked.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.status == .waiting
                && trace.summary == String.l10n("agent.workspace.trace.deepSeekBlocked")
        })

        let maxTokens = try driver.receive(deepSeekEvent(
            sessionID: sessionID,
            type: "turn/end",
            seq: 12,
            data: .object([
                "turn": .number(0),
                "reason": .object(["kind": .string("max-tokens")]),
            ])
        ))
        #expect(maxTokens.events.contains { event in
            guard case .trace(let trace) = event else { return false }
            return trace.kind == .warning
                && trace.summary == String.l10n("agent.workspace.trace.deepSeekMaxTokens")
        })
        #else
        #expect(Bool(true))
        #endif
    }

    @Test("DeepSeek 每轮 Cordis 配置通过环境变量接入临时 Starcat MCP")
    func deepSeekRunCordisInjectsTransientMCPWithoutPersistingToken() throws {
        #if arch(arm64)
        let fixture = try DeepSeekCarrierFixture()
        defer { fixture.cleanup() }
        let connection = ExternalAgentMCPConnection(
            endpointURL: URL(string: "http://127.0.0.1:54321/mcp")!,
            bearerToken: "fixture-secret-token"
        )
        let request = ExternalAgentRunRequest(
            runID: UUID(),
            prompt: "读取 Starcat",
            modelName: "deepseek-test",
            reasoningEffort: nil,
            workingDirectory: fixture.directoryURL,
            tools: [],
            mcpConnection: connection
        )
        let adapter = try DeepSeekHarnessAdapter(
            executableURL: fixture.executableURL,
            provider: DeepSeekHarnessRuntime.defaultProvider,
            modelOverride: request.modelName,
            cordisConfigURL: fixture.configURL,
            environment: [:]
        )
        let driver = try adapter.makeDriver(request: request)
        let runConfigPath = try #require(driver.processConfiguration.environment["DSH_CORDIS_CONFIG"])
        let runConfig = try String(contentsOfFile: runConfigPath, encoding: .utf8)

        #expect(runConfig.contains("@deepseek-ai/dsh-mcp-client"))
        #expect(runConfig.contains("process.env.STARCAT_MCP_URL"))
        #expect(runConfig.contains("process.env.STARCAT_MCP_TOKEN"))
        #expect(!runConfig.contains(connection.bearerToken))
        #expect(driver.processConfiguration.environment["STARCAT_MCP_URL"] == connection.endpointURL.absoluteString)
        #expect(driver.processConfiguration.environment["STARCAT_MCP_TOKEN"] == connection.bearerToken)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test("DeepSeek adapter 拒绝未授权的本地 Shell Cordis 插件")
    func deepSeekRejectsLocalShellCordisConfig() throws {
        #if arch(arm64)
        let fixture = try DeepSeekCarrierFixture()
        defer { fixture.cleanup() }
        try Data("- id: bash\n  name: '@deepseek-ai/dsh-bash-local'\n".utf8)
            .write(to: fixture.configURL)

        #expect(throws: ExternalAgentRuntimeError.protocolError(
            "DeepSeek Harness Cordis config enables an unsupported local tool: "
                + "@deepseek-ai/dsh-bash-local. Run scripts/install-deepseek-harness-runtime.sh "
                + "and select its Starcat config."
        )) {
            _ = try DeepSeekHarnessAdapter(
                executableURL: fixture.executableURL,
                provider: DeepSeekHarnessRuntime.defaultProvider,
                modelOverride: DeepSeekHarnessRuntime.defaultModel,
                cordisConfigURL: fixture.configURL,
                environment: [:]
            )
        }
        #endif
    }

    @Test("DeepSeek Runtime 从 Starcat Provider 配置读取加密凭据")
    @MainActor
    func deepSeekRuntimeUsesConfiguredProviderCredential() throws {
        let suiteName = "ExternalAgentProtocolAdapterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let profile = AIProviderProfile(
            id: "deepseek-runtime-test",
            provider: .deepSeek,
            baseURL: "https://runtime.deepseek.example"
        )
        settings.aiProviderProfiles = [profile]
        try keychain.storeAIKey("fixture-secret", forProvider: profile.id)

        let environment = ExternalAgentRuntimePOCPreferences.deepSeekEnvironment(
            source: ["PATH": "/usr/bin"],
            settings: settings,
            keychain: keychain
        )

        #expect(environment["DEEPSEEK_API_KEY"] == "fixture-secret")
        #expect(environment["DEEPSEEK_BASE_URL"] == "https://runtime.deepseek.example")
        #expect(environment["PATH"] == "/usr/bin")
    }

    private func fixtureRequest() -> ExternalAgentRunRequest {
        ExternalAgentRunRequest(
            runID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            prompt: "hello",
            modelName: "test-model",
            reasoningEffort: "high",
            workingDirectory: FileManager.default.temporaryDirectory,
            tools: [AgentToolDefinition(
                name: "fixture_lookup",
                description: "Looks up a fixture.",
                inputSchema: AgentJSONSchema(
                    type: .object,
                    properties: ["query": AgentJSONSchema(type: .string)],
                    required: ["query"]
                )
            )]
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

    private func deepSeekEvent(
        sessionID: String,
        type: String,
        seq: Int,
        data: AgentJSONValue
    ) -> AgentJSONValue {
        notification(
            method: "session.event",
            params: .object([
                "sessionId": .string(sessionID),
                "event": .object([
                    "type": .string(type),
                    "seq": .number(Double(seq)),
                    "time": .number(1_777_000_000_000 + Double(seq)),
                    "data": data,
                ]),
            ])
        )
    }
}

private actor CodexIntegrationEventCollector {
    private(set) var events: [ExternalAgentProtocolEvent] = []

    func append(_ event: ExternalAgentProtocolEvent) {
        events.append(event)
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
