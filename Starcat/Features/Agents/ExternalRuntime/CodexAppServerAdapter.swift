//
//  CodexAppServerAdapter.swift
//  Starcat
//
//  Codex `app-server --listen stdio://` 的 JSON-RPC adapter。
//
//  POC 使用用户已安装并登录的 Codex，按 initialize → thread/start → turn/start
//  建立一次性 thread。执行目录是 Starcat 创建的空临时目录，并固定 read-only sandbox；
//  仅保留本机 CODEX_HOME 登录态，不把 API Key 交给子进程，也不让固定业务 Agent
//  自动迁移到该后端。
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
                    // 首期只消费稳定 v2 通知，不开启 dynamic tools 等实验 API。
                    "capabilities": .object(["experimentalApi": .bool(false)]),
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

        if let id = object["id"]?.integerValue {
            return try receiveResponse(id: id, result: object["result"])
        }
        if let method = object["method"]?.stringValue {
            return receiveNotificationOrRequest(method: method, object: object)
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
                    "This is a Starcat read-only POC. Do not modify files, run shell commands, spawn subagents, or request elevated permissions. Answer only from the supplied prompt context."
                ),
            ]
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
    ) -> ExternalAgentProtocolOutput {
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
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
