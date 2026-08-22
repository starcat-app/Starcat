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
                    "reasoningOutputTokens": .number(2),
                ])
            ])])
        ))
        #expect(usage.events == [.usage(AgentUsage(
            inputTokens: 12,
            outputTokens: 3,
            cachedTokens: 4,
            reasoningTokens: 2
        ))])

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
        "本机 DeepSeek Harness 0.1.1rc1 完成真实 turn",
        .enabled(if: shouldRunDeepSeekIntegration)
    )
    func installedDeepSeekHarnessCompletesRealTurn() async throws {
        #if arch(arm64)
        let environment = ProcessInfo.processInfo.environment
        let executablePath = try #require(environment["STARCAT_DEEPSEEK_RUNTIME_PATH"])
        let configPath = try #require(environment["STARCAT_DEEPSEEK_CORDIS_PATH"])
        let apiKey = try #require(environment["DEEPSEEK_API_KEY"])
        #expect(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let request = ExternalAgentRunRequest(
            runID: UUID(),
            prompt: "Reply with exactly STARCAT_DEEPSEEK_SMOKE_OK and nothing else.",
            modelName: environment["STARCAT_DEEPSEEK_MODEL"] ?? DeepSeekHarnessRuntime.defaultModel,
            reasoningEffort: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            tools: []
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
        #expect(assistantText.contains("STARCAT_DEEPSEEK_SMOKE_OK"))
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
