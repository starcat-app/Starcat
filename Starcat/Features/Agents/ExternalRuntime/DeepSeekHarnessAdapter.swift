//
//  DeepSeekHarnessAdapter.swift
//  Starcat
//
//  DeepSeek Harness 0.1.0-rc.8 SDK JSON-RPC adapter。
//
//  rc.8 只有 initialize、session/prompt、shutdown 三个 client request；停止当前 run
//  只能回收“一 run 一 Sidecar”的进程。该限制由 capability 明确表达，不能伪装成
//  已具备 turn cancel 或双向 approval。
//

import Foundation

struct DeepSeekHarnessAdapter: ExternalAgentProtocolAdapter {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessRC8

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
            guard fileManager.fileExists(atPath: path) else {
                throw ExternalAgentRuntimeError.executableNotRunnable(path)
            }
        }
        guard fileManager.fileExists(atPath: cordisConfigURL.path) else {
            throw ExternalAgentRuntimeError.missingConfiguration("DebugDeepSeekHarnessCordisConfigPath")
        }
        self.executableURL = executableURL
        self.provider = provider
        self.modelOverride = modelOverride
        self.cordisConfigURL = cordisConfigURL
        self.environment = environment
        #else
        throw ExternalAgentRuntimeError.unsupportedArchitecture("DeepSeek Harness rc.8 carrier is arm64-only on macOS")
        #endif
    }

    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver {
        let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model?.isEmpty == false ? model! : request.modelName
        guard let resolvedModel, !resolvedModel.isEmpty else {
            throw ExternalAgentRuntimeError.missingConfiguration("DeepSeek model")
        }
        return DeepSeekHarnessDriver(
            request: request,
            executableURL: executableURL,
            provider: provider,
            model: resolvedModel,
            cordisConfigURL: cordisConfigURL,
            environment: environment
        )
    }
}

private final class DeepSeekHarnessDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.deepSeekHarness
    let capabilities = AgentRuntimeCapabilities.deepSeekHarnessRC8
    let processConfiguration: ExternalAgentProcessConfiguration

    private let request: ExternalAgentRunRequest
    private let provider: String
    private let model: String
    private let sessionID: String

    init(
        request: ExternalAgentRunRequest,
        executableURL: URL,
        provider: String,
        model: String,
        cordisConfigURL: URL,
        environment: [String: String]
    ) {
        self.request = request
        self.provider = provider
        self.model = model
        sessionID = request.runID.uuidString.lowercased()
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: executableURL,
            arguments: [],
            environment: ExternalAgentProcessEnvironment.filtered(
                source: environment,
                allowedCredentialKeys: [
                    "DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL"
                ],
                additional: [
                    "DSH_CORDIS_CONFIG": cordisConfigURL.path,
                    "DSH_CWD": request.workingDirectory.path,
                    "DSH_SESSION_ROOT": request.workingDirectory.appendingPathComponent("sessions").path,
                ]
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
            return Self.mapEvent(params[external: "event"])
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    /// rc.8 没有 turn cancel。Host 会按一 run 一进程的边界终止 Sidecar。
    func cancellationFrame() -> AgentJSONValue? { nil }

    func shutdownFrame() -> AgentJSONValue? {
        .jsonRPCRequest(id: 3, method: "shutdown")
    }

    private static func mapEvent(_ value: AgentJSONValue?) -> ExternalAgentProtocolOutput {
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
            let usage = usage(from: data[external: "usage"] ?? message[external: "usage"])
            return ExternalAgentProtocolOutput(events: [.assistantMessage(text, usage: usage)])
        case "tool/call":
            let id = data[external: "callId"]?.stringValue ?? UUID().uuidString
            let name = data[external: "name"]?.stringValue ?? "unknown"
            let rawInput = data[external: "arguments"]?.stringValue
            let input = rawInput.flatMap { try? decodeJSON($0) } ?? .object([:])
            return ExternalAgentProtocolOutput(events: [
                .toolCall(id: id, name: name, input: input, rawInput: rawInput)
            ])
        case "tool/result":
            let message = data[external: "message"] ?? data
            let id = data[external: "callId"]?.stringValue
                ?? message[external: "toolCallId"]?.stringValue
                ?? UUID().uuidString
            let name = data[external: "name"]?.stringValue ?? "unknown"
            return ExternalAgentProtocolOutput(events: [
                .toolResult(id: id, name: name, output: message, isError: data[external: "isError"]?.externalBool == true)
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
}
