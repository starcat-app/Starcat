//
//  CodexAppServerAdapter.swift
//  Starcat
//
//  Codex `app-server --listen stdio://` 的 JSON-RPC adapter。
//
//  POC 使用用户已安装并登录的 Codex，按 initialize → thread/start → turn/start
//  建立一次性 thread。执行目录是 Starcat 创建的空临时目录，并固定 read-only sandbox；
//  仅保留本机 CODEX_HOME 登录态，不把 API Key 交给子进程。固定业务 Agent 只能通过
//  `dynamicTools` 调用 Starcat 明确暴露的只读能力，不能直接访问数据库或文件系统。
//

import Foundation

struct CodexAppServerAdapter: ExternalAgentProtocolAdapter {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC

    private let executableURL: URL
    private let modelOverride: String?
    private let environment: [String: String]

    init(
        executableURL: URL,
        modelOverride: String? = nil,
        environment: [String: String] = ExternalAgentProcessEnvironment.filtered()
    ) {
        self.executableURL = executableURL
        self.modelOverride = modelOverride?.nilIfBlank
        self.environment = environment
    }

    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver {
        CodexAppServerDriver(
            request: request,
            executableURL: executableURL,
            modelOverride: modelOverride,
            environment: environment
        )
    }
}

private final class CodexAppServerDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServerPOC
    let processConfiguration: ExternalAgentProcessConfiguration

    private let request: ExternalAgentRunRequest
    private let modelOverride: String?
    private var threadID: String?
    private var turnID: String?

    init(
        request: ExternalAgentRunRequest,
        executableURL: URL,
        modelOverride: String?,
        environment: [String: String]
    ) {
        self.request = request
        self.modelOverride = modelOverride
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: executableURL,
            arguments: ["app-server", "--listen", "stdio://"],
            environment: environment,
            currentDirectoryURL: request.workingDirectory
        )
    }

    func initialFrames() throws -> [AgentJSONValue] {
        [
            .jsonRPCRequest(
                id: 1,
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("starcat"),
                        "title": .string("Starcat"),
                        "version": .string(
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "development"
                        ),
                    ]),
                    // Codex dynamic tools 通过 App Server 的实验能力协商；宿主仍只暴露
                    // Agent definition allowlist 中的 Starcat 只读工具。
                    "capabilities": .object(["experimentalApi": .bool(true)]),
                ])
            )
        ]
    }

    func receive(_ frame: AgentJSONValue) throws -> ExternalAgentProtocolOutput {
        guard let object = frame.externalObject else { throw ExternalAgentRuntimeError.invalidFrame }
        if let error = object["error"]?.externalObject {
            throw ExternalAgentRuntimeError.protocolError(
                error["message"]?.stringValue ?? "Codex App Server returned an unknown error."
            )
        }

        // JSON-RPC server request 同时带 `id` 与 `method`；必须先按 method 分流，
        // 否则 dynamic tool call 会被误判成客户端请求的 response 并静默丢弃。
        if let method = object["method"]?.stringValue {
            return try receiveNotificationOrRequest(method: method, object: object)
        }
        if let id = object["id"]?.integerValue {
            return try receiveResponse(id: id, result: object["result"])
        }
        return ExternalAgentProtocolOutput()
    }

    func cancellationFrame() -> AgentJSONValue? {
        guard let threadID, let turnID else { return nil }
        return .jsonRPCRequest(
            id: 90,
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    /// App Server 当前没有稳定 shutdown 方法；Host 在 turn 终态后回收专属进程。
    func shutdownFrame() -> AgentJSONValue? { nil }

    func toolResponseFrame(
        for request: ExternalAgentToolRequest,
        result: ExternalAgentToolExecutionResult
    ) -> AgentJSONValue? {
        .object([
            "jsonrpc": .string("2.0"),
            "id": request.requestID,
            "result": .object([
                "success": .bool(!result.isError),
                "contentItems": .array([
                    .object([
                        "type": .string("inputText"),
                        "text": .string(result.modelText),
                    ])
                ]),
            ]),
        ])
    }

    private func receiveResponse(
        id: Int,
        result: AgentJSONValue?
    ) throws -> ExternalAgentProtocolOutput {
        switch id {
        case 1:
            var threadParams: [String: AgentJSONValue] = [
                "cwd": .string(request.workingDirectory.path),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "ephemeral": .bool(true),
                "developerInstructions": .string(
                    "This is a Starcat read-only POC. Do not modify files, run shell commands, spawn subagents, or request elevated permissions. Use only the supplied prompt context and Starcat dynamic tools."
                ),
            ]
            if !request.tools.isEmpty {
                threadParams["dynamicTools"] = .array(try request.tools.map { definition in
                    .object([
                        "type": .string("function"),
                        "name": .string(definition.name),
                        "description": .string(definition.description),
                        "inputSchema": try Self.jsonValue(from: definition.inputSchema),
                    ])
                })
            }
            if let modelOverride { threadParams["model"] = .string(modelOverride) }
            return ExternalAgentProtocolOutput(outboundFrames: [
                .jsonRPCNotification(method: "initialized"),
                .jsonRPCRequest(id: 2, method: "thread/start", params: .object(threadParams)),
            ])
        case 2:
            guard let threadID = result?[external: "thread"]?[external: "id"]?.stringValue else {
                throw ExternalAgentRuntimeError.protocolError("Codex thread/start response has no thread id.")
            }
            self.threadID = threadID
            return ExternalAgentProtocolOutput(outboundFrames: [
                .jsonRPCRequest(
                    id: 3,
                    method: "turn/start",
                    params: .object([
                        "threadId": .string(threadID),
                        "input": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(request.prompt),
                            ])
                        ]),
                    ])
                )
            ])
        case 3:
            turnID = result?[external: "turn"]?[external: "id"]?.stringValue
            return ExternalAgentProtocolOutput()
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    private func receiveNotificationOrRequest(
        method: String,
        object: [String: AgentJSONValue]
    ) throws -> ExternalAgentProtocolOutput {
        let params = object["params"]
        switch method {
        case "turn/started":
            turnID = params?[external: "turn"]?[external: "id"]?.stringValue ?? turnID
            return ExternalAgentProtocolOutput()
        case "item/agentMessage/delta":
            guard let delta = params?[external: "delta"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            return ExternalAgentProtocolOutput(events: [.assistantDelta(delta)])
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = params?[external: "delta"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            return ExternalAgentProtocolOutput(events: [.reasoningDelta(delta)])
        case "thread/tokenUsage/updated":
            guard let usage = Self.usage(from: params) else { return ExternalAgentProtocolOutput() }
            return ExternalAgentProtocolOutput(events: [.usage(usage)])
        case "item/tool/call":
            guard let requestID = object["id"],
                  let callID = params?[external: "callId"]?.stringValue,
                  let tool = params?[external: "tool"]?.stringValue,
                  let arguments = params?[external: "arguments"]
            else {
                throw ExternalAgentRuntimeError.protocolError(
                    "Codex dynamic tool request is missing id, callId, tool, or arguments."
                )
            }
            return ExternalAgentProtocolOutput(toolRequests: [ExternalAgentToolRequest(
                requestID: requestID,
                callID: callID,
                name: tool,
                input: arguments,
                rawInput: try? arguments.jsonString()
            )])
        case "turn/completed":
            let status = params?[external: "turn"]?[external: "status"]?.stringValue
            switch status {
            case "completed":
                return ExternalAgentProtocolOutput(events: [.completed], isTerminal: true)
            case "interrupted":
                return ExternalAgentProtocolOutput(events: [.cancelled], isTerminal: true)
            case "failed":
                let message = params?[external: "turn"]?[external: "error"]?[external: "message"]?.stringValue
                    ?? "Codex turn failed."
                return ExternalAgentProtocolOutput(events: [.failed(message)], isTerminal: true)
            default:
                return ExternalAgentProtocolOutput()
            }
        case "error":
            guard params?[external: "willRetry"]?.externalBool != true else {
                return ExternalAgentProtocolOutput()
            }
            let message = params?[external: "error"]?[external: "message"]?.stringValue
                ?? "Codex App Server reported an error."
            return ExternalAgentProtocolOutput(events: [.failed(message)], isTerminal: true)
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestUserInput":
            // POC 没有把 Codex approval 扩展成 Starcat 写入审批；请求必须明确拒绝。
            guard let id = object["id"] else { return ExternalAgentProtocolOutput() }
            return ExternalAgentProtocolOutput(outboundFrames: [
                .object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "error": .object([
                        "code": .number(-32_000),
                        "message": .string("Starcat External Agent Runtime POC is read-only."),
                    ]),
                ])
            ])
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    private static func usage(from params: AgentJSONValue?) -> AgentUsage? {
        let usage = params?[external: "tokenUsage"] ?? params?[external: "usage"]
        guard let object = usage?.externalObject else { return nil }
        let input = object["inputTokens"]?.integerValue ?? object["input_tokens"]?.integerValue ?? 0
        let output = object["outputTokens"]?.integerValue ?? object["output_tokens"]?.integerValue ?? 0
        let cached = object["cachedInputTokens"]?.integerValue ?? object["cached_input_tokens"]?.integerValue ?? 0
        let reasoning = object["reasoningOutputTokens"]?.integerValue ?? object["reasoning_tokens"]?.integerValue ?? 0
        return AgentUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            reasoningTokens: reasoning
        )
    }

    private static func jsonValue<T: Encodable>(from value: T) throws -> AgentJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AgentJSONValue.self, from: data)
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
