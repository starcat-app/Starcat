//
//  DeepSeekHarnessAdapter.swift
//  Starcat
//
//  DeepSeek Harness 0.1.1rc1 Runtime JSON-RPC adapter。
//
//  当前协议只有 initialize、session/prompt、shutdown 三个 client request；停止当前 run
//  只能回收“一 run 一 Sidecar”的进程。该限制由 capability 明确表达，不能伪装成
//  已具备 turn cancel 或双向 approval。
//

import Foundation

/// Starcat 已验证的 DeepSeek Harness Runtime 契约。
///
/// Runtime 仍由用户通过外部路径安装，常量只用于协议版本说明与模型选择，绝不表示
/// carrier 会进入 App bundle 或 DMG。
enum DeepSeekHarnessRuntime {
    static let packageVersion = "0.1.1rc1"
    static let defaultProvider = "deepseek-official"
    static let supportedModels = ["deepseek-v4-flash", "deepseek-v4-pro"]
    static let defaultModel = supportedModels[0]
}

struct DeepSeekHarnessAdapter: ExternalAgentProtocolAdapter {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessPOC

    private let executableURL: URL
    private let provider: String
    private let modelOverride: String?
    private let cordisConfigURL: URL
    private let environment: [String: String]

    init(
        executableURL: URL,
        provider: String,
        modelOverride: String?,
        cordisConfigURL: URL,
        environment: [String: String]
    ) throws {
        #if arch(arm64)
        let fileManager = FileManager.default
        for path in [executableURL.path, executableURL.path + "-rg", executableURL.path + "-spawn-helper"] {
            guard fileManager.isExecutableFile(atPath: path) else {
                throw ExternalAgentRuntimeError.executableNotRunnable(path)
            }
        }
        guard fileManager.fileExists(atPath: cordisConfigURL.path) else {
            throw ExternalAgentRuntimeError.missingConfiguration("DebugDeepSeekHarnessCordisConfigPath")
        }
        let cordisConfig = try String(contentsOf: cordisConfigURL, encoding: .utf8)
        let forbiddenPlugins = [
            "@deepseek-ai/dsh-bash-local",
            "@deepseek-ai/dsh-subprocess-local",
        ]
        if let forbiddenPlugin = forbiddenPlugins.first(where: cordisConfig.contains) {
            // DeepSeek adapter 还没有 Starcat 的双向工具桥。放行 Harness 自带 Shell
            // 既越过产品权限边界，也会在 wheel 动态解压 pty.node 时触发 Gatekeeper。
            throw ExternalAgentRuntimeError.protocolError(
                "DeepSeek Harness Cordis config enables an unsupported local tool: \(forbiddenPlugin). "
                    + "Run scripts/install-deepseek-harness-runtime.sh and select its Starcat config."
            )
        }
        self.executableURL = executableURL
        self.provider = provider
        self.modelOverride = modelOverride
        self.cordisConfigURL = cordisConfigURL
        self.environment = environment
        #else
        throw ExternalAgentRuntimeError.unsupportedArchitecture(
            "DeepSeek Harness \(DeepSeekHarnessRuntime.packageVersion) Runtime is arm64-only on macOS"
        )
        #endif
    }

    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver {
        let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = (model?.isEmpty == false ? model : nil)
            ?? request.modelName
            ?? DeepSeekHarnessRuntime.defaultModel
        guard !resolvedModel.isEmpty else {
            throw ExternalAgentRuntimeError.missingConfiguration("DeepSeek model")
        }
        let runCordisConfigURL = try DeepSeekHarnessCordisRunConfiguration.prepare(
            baseConfigURL: cordisConfigURL,
            workingDirectory: request.workingDirectory,
            mcpConnection: request.mcpConnection
        )
        return DeepSeekHarnessDriver(
            request: request,
            executableURL: executableURL,
            provider: provider,
            model: resolvedModel,
            cordisConfigURL: runCordisConfigURL,
            mcpConnection: request.mcpConnection,
            environment: environment
        )
    }
}

/// 为单次 Run 追加 Starcat MCP client。基础配置仍由用户选择；临时配置只保存
/// 环境变量引用，不写 Bearer Token，并随 working directory 一起回收。
enum DeepSeekHarnessCordisRunConfiguration {
    static func prepare(
        baseConfigURL: URL,
        workingDirectory: URL,
        mcpConnection: ExternalAgentMCPConnection?
    ) throws -> URL {
        guard mcpConnection != nil else { return baseConfigURL }
        let base = try String(contentsOf: baseConfigURL, encoding: .utf8)
        guard !base.contains("@deepseek-ai/dsh-mcp-client") else {
            throw ExternalAgentRuntimeError.protocolError(
                "DeepSeek Harness base Cordis config must not preconfigure the Starcat MCP client."
            )
        }
        let runConfigURL = workingDirectory.appendingPathComponent("starcat-run.cordis.yml")
        let mcpPlugin = """

        # Starcat 每轮临时 MCP Bridge。URL 与 Token 只从子进程环境读取。
        - id: starcat-mcp
          name: '@deepseek-ai/dsh-mcp-client'
          config:
            serverName: starcat
            transport: streamable-http
            url: !!js process.env.STARCAT_MCP_URL
            headers:
              Authorization: !!js '`Bearer ${process.env.STARCAT_MCP_TOKEN}`'
            toolCallTimeoutMs: 60000
            failOnStartupError: true
        """
        try Data((base + mcpPlugin + "\n").utf8).write(to: runConfigURL, options: .atomic)
        return runConfigURL
    }
}

private final class DeepSeekHarnessDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessPOC
    let processConfiguration: ExternalAgentProcessConfiguration

    private let request: ExternalAgentRunRequest
    private let provider: String
    private let model: String
    private let sessionID: String
    /// Harness 的 `tool/result` 不重复工具名，只通过 `message.source.callId` 关联。
    /// 保留同一 session 的 call 映射，避免用 `unknown` 或随机 UUID 掩盖协议字段。
    private var toolNamesByCallID: [String: String] = [:]
    /// request/header 与 request/context 本身不重复 turn/step；记录当前执行括号后才能把
    /// 请求配置、消息与工具事件挂回真实 Step，而不是在 UI 中生成无关联的平铺日志。
    private var currentTurn: Int?
    private var currentStep: Int?
    private var activeCompactionID: String?
    /// request/header 与 request/context、compaction 的 start/summary/end 都会更新同一
    /// 生命周期行。缓存已公开的详情，避免后一个事件 upsert 时把前一个阶段覆盖掉。
    private var requestDetailsByID: [String: [AgentTraceDetail]] = [:]
    private var compactionDetailsByID: [String: [AgentTraceDetail]] = [:]

    init(
        request: ExternalAgentRunRequest,
        executableURL: URL,
        provider: String,
        model: String,
        cordisConfigURL: URL,
        mcpConnection: ExternalAgentMCPConnection?,
        environment: [String: String]
    ) {
        self.request = request
        self.provider = provider
        self.model = model
        sessionID = request.runID.uuidString.lowercased()
        var additionalEnvironment = [
            "DSH_CORDIS_CONFIG": cordisConfigURL.path,
            "DSH_CWD": request.workingDirectory.path,
            "DSH_SESSION_ROOT": request.workingDirectory.appendingPathComponent("sessions").path,
        ]
        if let mcpConnection {
            additionalEnvironment["STARCAT_MCP_URL"] = mcpConnection.endpointURL.absoluteString
            additionalEnvironment["STARCAT_MCP_TOKEN"] = mcpConnection.bearerToken
        }
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: executableURL,
            arguments: [],
            environment: ExternalAgentProcessEnvironment.filtered(
                source: environment,
                allowedCredentialKeys: [
                    "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL"
                ],
                additional: additionalEnvironment
            ),
            currentDirectoryURL: request.workingDirectory
        )
    }

    func initialFrames() throws -> [AgentJSONValue] {
        [
            .jsonRPCRequest(
                id: 1,
                method: "initialize",
                params: .object([
                    "cwd": .string(request.workingDirectory.path),
                    "provider": .string(provider),
                    "model": .string(model),
                    "maxTokens": .number(16_384),
                ])
            )
        ]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard let object = frame.externalObject else { throw ExternalAgentRuntimeError.invalidFrame }
        if let error = object["error"]?.externalObject {
            throw ExternalAgentRuntimeError.protocolError(
                error["message"]?.stringValue ?? "DeepSeek Harness returned an unknown error."
            )
        }
        if let id = object["id"]?.integerValue {
            switch id {
            case 1:
                return ExternalAgentProtocolOutput(outboundFrames: [
                    .jsonRPCRequest(
                        id: 2,
                        method: "session/prompt",
                        params: .object([
                            "sessionId": .string(sessionID),
                            "contentBlocks": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string(request.prompt),
                                ])
                            ]),
                        ])
                    )
                ])
            default:
                return ExternalAgentProtocolOutput()
            }
        }

        guard let method = object["method"]?.stringValue,
              let params = object["params"],
              params[external: "sessionId"]?.stringValue == sessionID
        else {
            // 子 Agent 通知首期禁用；不同 session 的事件绝不能投影进当前 Run。
            return ExternalAgentProtocolOutput()
        }
        switch method {
        case "session.status":
            guard params[external: "status"]?.stringValue == "idle" else {
                return ExternalAgentProtocolOutput()
            }
            return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
        case "session.event":
            return mapEvent(params[external: "event"])
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    /// 当前 Runtime 没有 turn cancel。Host 会按一 run 一进程的边界终止 Sidecar。
    func cancellationFrame() -> AgentJSONValue? { nil }

    func shutdownFrame() -> AgentJSONValue? {
        .jsonRPCRequest(id: 3, method: "shutdown")
    }

    private func mapEvent(_ value: AgentJSONValue?) -> ExternalAgentProtocolOutput {
        guard let type = value?[external: "type"]?.stringValue,
              let data = value?[external: "data"]
        else { return ExternalAgentProtocolOutput() }

        switch type {
        case "turn/start":
            let turn = data[external: "turn"]?.integerValue ?? currentTurn ?? 0
            currentTurn = turn
            currentStep = nil
            let detail = ExternalAgentTracePayload.detail(
                label: String.l10n("agent.workspace.trace.eventData"),
                value: data
            )
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: turnTraceID(turn),
                kind: .lifecycle,
                status: .running,
                title: "\(String.l10n("agent.workspace.trace.kind.turn")) \(turn + 1)",
                details: detail.map { [$0] } ?? [],
                startedAt: eventDate(value)
            ))])
        case "step/start":
            let turn = data[external: "turn"]?.integerValue ?? currentTurn ?? 0
            let step = data[external: "step"]?.integerValue ?? 0
            currentTurn = turn
            currentStep = step
            let detail = ExternalAgentTracePayload.detail(
                label: String.l10n("agent.workspace.trace.eventData"),
                value: data
            )
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: stepTraceID(turn: turn, step: step),
                parentID: turnTraceID(turn),
                kind: .lifecycle,
                status: .running,
                title: "\(String.l10n("agent.workspace.trace.kind.step")) \(step + 1)",
                details: detail.map { [$0] } ?? [],
                startedAt: eventDate(value)
            ))])
        case "step/end":
            let turn = data[external: "turn"]?.integerValue ?? currentTurn ?? 0
            let step = data[external: "step"]?.integerValue ?? currentStep ?? 0
            currentTurn = turn
            currentStep = step
            let detail = ExternalAgentTracePayload.detail(
                label: String.l10n("agent.workspace.trace.eventData"),
                value: data
            )
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: stepTraceID(turn: turn, step: step),
                parentID: turnTraceID(turn),
                kind: .lifecycle,
                status: .completed,
                title: "\(String.l10n("agent.workspace.trace.kind.step")) \(step + 1)",
                details: detail.map { [$0] } ?? [],
                completedAt: eventDate(value)
            ))])
        case "assistant/chunk":
            let chunk = data[external: "chunk"]
            guard let deltaType = chunk?[external: "type"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            switch deltaType {
            case "text-delta":
                guard let text = chunk?[external: "text"]?.stringValue else {
                    return ExternalAgentProtocolOutput()
                }
                return ExternalAgentProtocolOutput(events: [.assistantDelta(text)])
            case "reasoning-delta":
                guard let text = chunk?[external: "text"]?.stringValue else {
                    return ExternalAgentProtocolOutput()
                }
                return ExternalAgentProtocolOutput(events: [.reasoningDelta(text)])
            case "usage":
                guard let usage = Self.usage(from: chunk?[external: "usage"] ?? chunk) else {
                    return ExternalAgentProtocolOutput()
                }
                return ExternalAgentProtocolOutput(events: [.usage(usage)])
            case "block-start", "block-end", "tool-call-delta", "finish":
                // 这些是 assistant/message、tool/call 与终态的原始组装帧。逐帧生成 UI 行
                // 会制造噪声和数百个空 disclosure；最终装配事件才是可恢复的产品事实。
                return ExternalAgentProtocolOutput()
            default:
                return genericTrace(type: "assistant/chunk/\(deltaType)", data: chunk ?? data, value: value)
            }
        case "assistant/message":
            let message = data[external: "message"] ?? data
            let text = contentText(in: message, matching: "text")
            let reasoning = contentText(in: message, matching: "reasoning")
            let usage = Self.usage(from: data[external: "usage"] ?? message[external: "usage"])
            var events: [ExternalAgentProtocolEvent] = [.assistantMessage(text, usage: usage)]
            if let reasoning = Self.nonBlank(reasoning) {
                let messageID = Self.nonBlank(message[external: "id"]?.stringValue)
                    ?? stepCorrelationID(prefix: "assistant")
                events.append(.trace(ExternalAgentTraceEvent(
                    id: "reasoning:\(messageID)",
                    parentID: currentStepTraceID,
                    kind: .reasoningSummary,
                    status: data[external: "interrupted"]?.externalBool == true ? .cancelled : .completed,
                    title: String.l10n("agent.workspace.trace.kind.thinking"),
                    summary: reasoning,
                    details: [.init(
                        label: String.l10n("agent.workspace.timeline.reasoning"),
                        value: reasoning,
                        format: .markdown
                    )],
                    completedAt: eventDate(value)
                )))
            }
            return ExternalAgentProtocolOutput(events: events)
        case "user/message", "steering/message":
            let message = data[external: "message"] ?? data
            let text = contentText(in: message)
            let messageID = Self.nonBlank(message[external: "id"]?.stringValue)
                ?? eventIdentifier(type: type, data: data, value: value)
            var details: [AgentTraceDetail] = []
            if let text = Self.nonBlank(text) {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.message"),
                    value: text,
                    format: .markdown
                ))
            }
            if let source = message[external: "source"],
               let detail = ExternalAgentTracePayload.detail(
                   label: String.l10n("agent.workspace.trace.eventData"),
                   value: source
               ) {
                details.append(detail)
            }
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "message:\(messageID)",
                parentID: currentStepTraceID,
                kind: .message,
                status: .completed,
                title: String.l10n("agent.workspace.trace.kind.message"),
                summary: Self.summary(from: text),
                details: details,
                completedAt: eventDate(value)
            ))])
        case "tool/call":
            guard let id = Self.nonBlank(data[external: "callId"]?.stringValue),
                  let name = Self.nonBlank(data[external: "name"]?.stringValue)
            else {
                return Self.malformedToolTrace(type: type, value: value)
            }
            toolNamesByCallID[id] = name
            let rawInput = data[external: "arguments"]?.stringValue
            let input = rawInput.flatMap { try? Self.decodeJSON($0) } ?? .object([:])
            return ExternalAgentProtocolOutput(events: [
                .toolCall(id: id, name: name, input: input, rawInput: rawInput)
            ])
        case "tool/result":
            let message = data[external: "message"] ?? data
            guard let id = Self.nonBlank(data[external: "callId"]?.stringValue)
                ?? Self.nonBlank(message[external: "source"]?[external: "callId"]?.stringValue)
                ?? Self.nonBlank(message[external: "toolCallId"]?.stringValue)
            else {
                return Self.malformedToolTrace(type: type, value: value)
            }
            guard let name = Self.nonBlank(data[external: "name"]?.stringValue)
                ?? toolNamesByCallID.removeValue(forKey: id)
            else {
                return Self.malformedToolTrace(type: type, value: value)
            }
            return ExternalAgentProtocolOutput(events: [
                .toolResult(
                    id: id,
                    name: name,
                    // error 与 meta 位于 message 外层，必须一起投影，否则重放时看不到失败
                    // 类型或工具自带的结构化展示数据。
                    output: data,
                    isError: data[external: "isError"]?.externalBool == true
                        || message[external: "isError"]?.externalBool == true
                        || data[external: "error"] != nil
                )
            ])
        case "request/header":
            let header = data[external: "header"] ?? .object([:])
            let config = header[external: "config"] ?? .object([:])
            var requestData: [String: AgentJSONValue] = ["config": config]
            if let defaults = header[external: "adapterDefaults"] {
                requestData["adapterDefaults"] = defaults
            }
            if let reason = data[external: "reason"] { requestData["reason"] = reason }
            return requestTrace(
                idPrefix: "request",
                detailLabel: String.l10n("agent.workspace.trace.requestConfig"),
                payload: .object(requestData),
                summary: config[external: "model"]?.stringValue,
                value: value
            )
        case "request/context":
            return requestTrace(
                idPrefix: "request",
                detailLabel: String.l10n("agent.workspace.trace.requestContext"),
                payload: data,
                summary: data[external: "model"]?.stringValue,
                value: value
            )
        case "todo/write":
            let todos = data[external: "todos"] ?? .array([])
            let items = todos.externalArray ?? []
            let completed = items.filter {
                $0[external: "status"]?.stringValue == "completed"
            }.count
            let status: AgentTraceStatus = items.contains {
                $0[external: "status"]?.stringValue == "in_progress"
            } ? .running : .completed
            let detail = ExternalAgentTracePayload.detail(
                label: String.l10n("agent.workspace.trace.todos"),
                value: todos
            )
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "todo",
                parentID: currentStepTraceID,
                kind: .todo,
                status: status,
                title: String.l10n("agent.workspace.trace.kind.todo"),
                summary: "\(completed.formatted()) / \(items.count.formatted())",
                details: detail.map { [$0] } ?? [],
                completedAt: status == .completed ? eventDate(value) : nil
            ))])
        case "turn/end":
            let turn = data[external: "turn"]?.integerValue ?? currentTurn ?? 0
            let reasonData = data[external: "reason"] ?? .object(["kind": .string("completed")])
            let reason = reasonData[external: "kind"]?.stringValue
                ?? reasonData.stringValue
                ?? "completed"
            currentStep = nil
            if ["aborted", "cancelled", "canceled"].contains(reason) {
                return ExternalAgentProtocolOutput(events: [
                    .trace(turnEndTrace(
                        turn: turn,
                        summary: String.l10n("agent.workspace.status.cancelled"),
                        status: .cancelled,
                        reasonData: reasonData,
                        value: value
                    )),
                    .cancelled,
                ], isTerminal: true)
            }
            if ["error", "failed", "interrupted"].contains(reason) {
                let message = reasonData[external: "error"]?[external: "message"]?.stringValue
                    ?? (reason == "interrupted"
                        ? String.l10n("agent.workspace.trace.deepSeekInterrupted")
                        : String.l10n("agent.workspace.status.failed"))
                return ExternalAgentProtocolOutput(
                    events: [
                        .trace(turnEndTrace(
                            turn: turn,
                            summary: message,
                            status: .failed,
                            reasonData: reasonData,
                            value: value
                        )),
                        .failed(message),
                    ],
                    isTerminal: true
                )
            }
            if reason == "blocked" {
                return ExternalAgentProtocolOutput(events: [.trace(turnEndTrace(
                    turn: turn,
                    summary: String.l10n("agent.workspace.trace.deepSeekBlocked"),
                    status: .waiting,
                    reasonData: reasonData,
                    value: value
                ))])
            }
            if reason == "max-tokens" {
                return ExternalAgentProtocolOutput(events: [.trace(turnEndTrace(
                    turn: turn,
                    summary: String.l10n("agent.workspace.trace.deepSeekMaxTokens"),
                    status: .completed,
                    reasonData: reasonData,
                    value: value,
                    kind: .warning
                ))])
            }
            return ExternalAgentProtocolOutput(events: [.trace(turnEndTrace(
                turn: turn,
                summary: reason == "completed"
                    ? String.l10n("agent.workspace.status.completed")
                    : reason,
                status: .completed,
                reasonData: reasonData,
                value: value
            ))])
        case "turn/retry", "model/retry", "llm/retry":
            let message = data[external: "message"]?.stringValue
                ?? data[external: "error"]?[external: "message"]?.stringValue
                ?? type
            let attempt = data[external: "attempt"]?.integerValue
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: data[external: "id"]?.stringValue ?? "retry:\(UUID().uuidString)",
                kind: .retry,
                status: .running,
                title: String.l10n("action.retry"),
                summary: message,
                details: [.init(label: String.l10n("error.loadFailed"), value: message, format: .error)],
                attempt: attempt
            ))])
        case "compaction/start":
            let id = Self.nonBlank(data[external: "compactionId"]?.stringValue)
                ?? eventIdentifier(type: type, data: data, value: value)
            activeCompactionID = id
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "compaction:\(id)",
                parentID: currentTurn.map(turnTraceID),
                kind: .compaction,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.contextCompaction"),
                startedAt: eventDate(value)
            ))])
        case "compaction/summary":
            let id = Self.nonBlank(data[external: "compactionId"]?.stringValue)
                ?? activeCompactionID
                ?? eventIdentifier(type: type, data: data, value: value)
            activeCompactionID = id
            let summary = contentText(in: data[external: "summary"] ?? .array([]))
            var details: [AgentTraceDetail] = []
            if let summary = Self.nonBlank(summary) {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.summary"),
                    value: summary,
                    format: .markdown
                ))
            }
            let metadata = data.removingExternalKeys(["summary", "rawOutput", "system", "tools"])
            if let detail = ExternalAgentTracePayload.detail(
                label: String.l10n("agent.workspace.trace.eventData"),
                value: metadata
            ) {
                details.append(detail)
            }
            compactionDetailsByID[id] = details
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "compaction:\(id)",
                parentID: currentTurn.map(turnTraceID),
                kind: .compaction,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.contextCompaction"),
                summary: Self.summary(from: summary),
                details: details
            ))])
        case "compaction/end":
            let id = Self.nonBlank(data[external: "compactionId"]?.stringValue)
                ?? activeCompactionID
                ?? eventIdentifier(type: type, data: data, value: value)
            activeCompactionID = nil
            let error = data[external: "error"]?[external: "message"]?.stringValue
                ?? data[external: "error"]?.stringValue
            var details = compactionDetailsByID.removeValue(forKey: id) ?? []
            if let error {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.error"),
                    value: error,
                    format: .error
                ))
            }
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "compaction:\(id)",
                parentID: currentTurn.map(turnTraceID),
                kind: .compaction,
                status: error == nil ? .completed : .failed,
                title: String.l10n("agent.workspace.trace.kind.contextCompaction"),
                summary: error,
                details: details,
                completedAt: eventDate(value)
            ))])
        case "session/title":
            let title = data[external: "title"]?.stringValue
                ?? data[external: "message"]?.stringValue
                ?? type
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: eventIdentifier(type: type, data: data, value: value),
                kind: .lifecycle,
                status: .completed,
                title: title,
                completedAt: eventDate(value)
            ))])
        case "agent/inbox/spliced", "session/end-seed":
            return genericTrace(type: type, data: data, value: value, kind: .lifecycle)
        case let hookType where hookType.hasPrefix("hook/"):
            return genericTrace(type: type, data: data, value: value, kind: .lifecycle)
        default:
            // SessionEventMap 允许插件 declaration merging。未知类型是合法扩展，必须保留
            // 有界、脱敏后的业务 data，不能继续生成一个无法展开的空标题行。
            return genericTrace(type: type, data: data, value: value)
        }
    }

    private var currentStepTraceID: String? {
        guard let currentTurn, let currentStep else { return nil }
        return stepTraceID(turn: currentTurn, step: currentStep)
    }

    private func turnTraceID(_ turn: Int) -> String { "turn:\(turn)" }

    private func stepTraceID(turn: Int, step: Int) -> String { "turn:\(turn):step:\(step)" }

    private func stepCorrelationID(prefix: String) -> String {
        if let currentTurn, let currentStep { return "\(prefix):\(currentTurn):\(currentStep)" }
        return "\(prefix):unknown"
    }

    private func requestTrace(
        idPrefix: String,
        detailLabel: String,
        payload: AgentJSONValue,
        summary: String?,
        value: AgentJSONValue?
    ) -> ExternalAgentProtocolOutput {
        let id = stepCorrelationID(prefix: idPrefix)
        let detail = ExternalAgentTracePayload.detail(label: detailLabel, value: payload)
        var details = requestDetailsByID[id] ?? []
        if let detail {
            details.removeAll { $0.label == detail.label }
            details.append(detail)
            requestDetailsByID[id] = details
        }
        return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
            id: id,
            parentID: currentStepTraceID,
            kind: .request,
            status: .completed,
            title: String.l10n("agent.workspace.trace.kind.request"),
            summary: summary,
            details: details,
            completedAt: eventDate(value)
        ))])
    }

    private func turnEndTrace(
        turn: Int,
        summary: String,
        status: AgentTraceStatus,
        reasonData: AgentJSONValue,
        value: AgentJSONValue?,
        kind: AgentTraceKind? = nil
    ) -> ExternalAgentTraceEvent {
        var details = [AgentTraceDetail(
            label: String.l10n("agent.workspace.trace.reason"),
            value: summary,
            format: status == .failed ? .error : .text
        )]
        if let detail = ExternalAgentTracePayload.detail(
            label: String.l10n("agent.workspace.trace.eventData"),
            value: reasonData
        ) {
            details.append(detail)
        }
        return ExternalAgentTraceEvent(
            id: turnTraceID(turn),
            kind: kind ?? (status == .failed ? .error : .lifecycle),
            status: status,
            title: "\(String.l10n("agent.workspace.trace.kind.turn")) \(turn + 1)",
            summary: summary,
            details: details,
            completedAt: eventDate(value)
        )
    }

    private func genericTrace(
        type: String,
        data: AgentJSONValue,
        value: AgentJSONValue?,
        kind: AgentTraceKind = .unknown
    ) -> ExternalAgentProtocolOutput {
        let detail = ExternalAgentTracePayload.detail(
            label: String.l10n("agent.workspace.trace.eventData"),
            value: data
        )
        let summary = data[external: "message"]?.stringValue
            ?? data[external: "status"]?.stringValue
        let status = Self.traceStatus(from: data[external: "status"]?.stringValue)
        return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
            id: eventIdentifier(type: type, data: data, value: value),
            parentID: currentStepTraceID,
            kind: kind,
            status: status,
            title: type,
            summary: summary,
            details: detail.map { [$0] } ?? [],
            completedAt: [.pending, .running, .waiting].contains(status) ? nil : eventDate(value)
        ))])
    }

    private func eventIdentifier(
        type: String,
        data: AgentJSONValue,
        value: AgentJSONValue?
    ) -> String {
        Self.nonBlank(data[external: "id"]?.stringValue)
            ?? Self.nonBlank(data[external: "eventId"]?.stringValue)
            ?? value?[external: "seq"]?.integerValue.map { "\(type):\($0)" }
            ?? stepCorrelationID(prefix: type)
    }

    private func eventDate(_ value: AgentJSONValue?) -> Date {
        guard let milliseconds = value?[external: "time"]?.externalNumber else { return Date() }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func contentText(in value: AgentJSONValue, matching type: String? = nil) -> String {
        if let text = value.stringValue { return text }
        let blocks = value[external: "content"]?.externalArray ?? value.externalArray ?? []
        return blocks.compactMap { block -> String? in
            if let type, block[external: "type"]?.stringValue != type { return nil }
            return block[external: "text"]?.stringValue
                ?? block[external: "content"]?.stringValue
        }.joined(separator: "\n\n")
    }

    private static func summary(from value: String?) -> String? {
        guard let value = nonBlank(value) else { return nil }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return String(firstLine.prefix(240))
    }

    private static func traceStatus(from value: String?) -> AgentTraceStatus {
        switch value?.lowercased() {
        case "pending": return .pending
        case "running", "working", "in_progress": return .running
        case "waiting": return .waiting
        case "failed", "error": return .failed
        case "cancelled", "canceled", "interrupted": return .cancelled
        case "skipped": return .skipped
        default: return .completed
        }
    }

    private static func usage(from value: AgentJSONValue?) -> AgentUsage? {
        guard let value, let object = value.externalObject else { return nil }
        let input = object["inputTokens"]?.integerValue ?? 0
        let output = object["outputTokens"]?.integerValue ?? 0
        return AgentUsage(inputTokens: input, outputTokens: output)
    }

    private static func decodeJSON(_ string: String) throws -> AgentJSONValue {
        guard let data = string.data(using: .utf8) else { throw ExternalAgentRuntimeError.invalidFrame }
        return try JSONDecoder().decode(AgentJSONValue.self, from: data)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// 关联字段缺失属于 Harness 协议错误，不能生成随机 ID 后继续写入历史；随机 ID 会让
    /// `tool/result` 永远找不到对应的 `tool/call`，正是 UI “未知调用 ID” 的根因。
    private static func malformedToolTrace(
        type: String,
        value: AgentJSONValue?
    ) -> ExternalAgentProtocolOutput {
        let eventID = value?[external: "seq"]?.integerValue.map { "\(type):\($0)" }
            ?? "\(type):malformed"
        let message = "DeepSeek Harness emitted \(type) without a correlatable call ID and tool name."
        return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
            id: eventID,
            kind: .error,
            status: .failed,
            title: String.l10n("error.loadFailed"),
            summary: message,
            details: [.init(
                label: String.l10n("error.loadFailed"),
                value: message,
                format: .error
            )],
            completedAt: Date()
        ))])
    }
}
