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
        case "assistant/chunk":
            let chunk = data[external: "chunk"]
            guard let deltaType = chunk?[external: "type"]?.stringValue,
                  let text = chunk?[external: "text"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            if deltaType == "text-delta" {
                return ExternalAgentProtocolOutput(events: [.assistantDelta(text)])
            }
            if deltaType == "reasoning-delta" {
                return ExternalAgentProtocolOutput(events: [.reasoningDelta(text)])
            }
            return ExternalAgentProtocolOutput()
        case "assistant/message":
            let message = data[external: "message"] ?? data
            let text = message[external: "content"]?.externalArray?
                .compactMap { block -> String? in
                    guard block[external: "type"]?.stringValue == "text" else { return nil }
                    return block[external: "text"]?.stringValue
                }
                .joined() ?? ""
            let usage = Self.usage(from: data[external: "usage"] ?? message[external: "usage"])
            return ExternalAgentProtocolOutput(events: [.assistantMessage(text, usage: usage)])
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
                    output: message,
                    isError: data[external: "isError"]?.externalBool == true
                        || message[external: "isError"]?.externalBool == true
                )
            ])
        case "turn/end":
            let reason = data[external: "reason"]?[external: "kind"]?.stringValue
            if reason == "cancelled" || reason == "interrupted" {
                return ExternalAgentProtocolOutput(events: [.cancelled], isTerminal: true)
            }
            if let reason, ["error", "failed"].contains(reason) {
                let message = "DeepSeek Harness turn ended: \(reason)."
                return ExternalAgentProtocolOutput(
                    events: [
                        .trace(ExternalAgentTraceEvent(
                            id: data[external: "id"]?.stringValue ?? "turn-error:\(UUID().uuidString)",
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
                        )),
                        .failed(message),
                    ],
                    isTerminal: true
                )
            }
            return ExternalAgentProtocolOutput()
        case "turn/retry", "model/retry":
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
        default:
            // Harness 的事件集合会随版本演进。未知事件不能继续静默吞掉，否则 UI 又会
            // 退回一套固定阶段；只投影类型、状态和 message，不保存整个协议 data。
            let eventID = data[external: "id"]?.stringValue
                ?? data[external: "eventId"]?.stringValue
                ?? "\(type):\(UUID().uuidString)"
            let summary = data[external: "message"]?.stringValue
                ?? data[external: "status"]?.stringValue
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: eventID,
                kind: .unknown,
                status: .completed,
                title: type,
                summary: summary,
                completedAt: Date()
            ))])
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
