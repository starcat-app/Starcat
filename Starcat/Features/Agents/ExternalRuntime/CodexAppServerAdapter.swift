//
//  CodexAppServerAdapter.swift
//  Starcat
//
//  Codex `app-server --listen stdio://` 的 JSON-RPC adapter。
//
//  使用用户已安装并登录的 Codex，按 initialize → thread/start → turn/start
//  建立一次性 thread。执行目录是 Starcat 创建的空临时目录，并固定 read-only sandbox；
//  仅保留本机 CODEX_HOME 登录态，不把 API Key 交给子进程。固定业务 Agent 只能通过
//  `dynamicTools` 调用 Starcat 明确暴露的只读能力，不能直接访问数据库或文件系统。
//

import Foundation

struct CodexAppServerAdapter: ExternalAgentProtocolAdapter {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServer

    private let executableURL: URL
    private let environment: [String: String]
    private let providerID: String?

    init(
        executableURL: URL,
        providerID: String? = nil,
        environment: [String: String] = ExternalAgentProcessEnvironment.filtered()
    ) {
        self.executableURL = executableURL
        self.providerID = providerID
        self.environment = environment
    }

    func makeDriver(request: ExternalAgentRunRequest) throws -> any ExternalAgentProtocolDriver {
        CodexAppServerDriver(
            request: request,
            executableURL: executableURL,
            providerID: providerID,
            environment: environment
        )
    }
}

private final class CodexAppServerDriver: ExternalAgentProtocolDriver, @unchecked Sendable {
    let backend = AgentRuntimeBackend.codexAppServer
    let capabilities = AgentRuntimeCapabilities.codexAppServer
    let processConfiguration: ExternalAgentProcessConfiguration

    private let request: ExternalAgentRunRequest
    private var threadID: String?
    private var turnID: String?
    private var inheritedMCPServerConfigs: [String: AgentJSONValue] = [:]
    private var itemStartedAt: [String: Date] = [:]
    /// delta notification 只给 itemId，不重复携带 command/tool/type 等元数据。
    /// 保存 started item 才能让运行中的同一行持续补充可读标题与详情。
    private var startedItems: [String: AgentJSONValue] = [:]
    private var itemOutputTexts: [String: String] = [:]
    private var itemPlanTexts: [String: String] = [:]
    /// App Server 会用 `summaryIndex` 把一次 reasoning 拆成多个可展示摘要段。
    /// 必须按段累计后再拼接，不能直接把所有 delta 连在一起，否则段落边界会丢失。
    private var reasoningSummaries: [String: [Int: String]] = [:]
    /// agent message 的 delta 不携带 phase；必须在 item/started 记住它，才能把用户可见的
    /// commentary 作为过程日志投影，而不是误拼进最终回答。
    private var agentMessagePhases: [String: String] = [:]
    private var agentMessageTexts: [String: String] = [:]
    private var retryCount = 0

    private static let configReadRequestID = 2
    private static let threadStartRequestID = 10_000
    private static let turnStartRequestID = 10_001

    init(
        request: ExternalAgentRunRequest,
        executableURL: URL,
        providerID: String?,
        environment: [String: String]
    ) {
        self.request = request
        processConfiguration = ExternalAgentProcessConfiguration(
            executableURL: executableURL,
            arguments: CodexRuntimeProcessArguments.appServer(
                executableURL: executableURL,
                providerID: providerID
            ),
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
            return ExternalAgentProtocolOutput(outboundFrames: [
                .jsonRPCNotification(method: "initialized"),
                .jsonRPCRequest(
                    id: Self.configReadRequestID,
                    method: "config/read",
                    params: .object([
                        "cwd": .string(request.workingDirectory.path),
                        "includeLayers": .bool(true),
                    ])
                ),
            ])
        case Self.configReadRequestID:
            inheritedMCPServerConfigs = Self.mergedMCPServerConfigs(from: result)
            return ExternalAgentProtocolOutput(outboundFrames: [try makeThreadStartFrame()])
        case Self.threadStartRequestID:
            guard let threadID = result?[external: "thread"]?[external: "id"]?.stringValue else {
                throw ExternalAgentRuntimeError.protocolError("Codex thread/start response has no thread id.")
            }
            self.threadID = threadID
            var turnParams: [String: AgentJSONValue] = [
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(request.prompt),
                    ])
                ]),
                // Starcat 的执行时间线需要 Provider 明确授权的 reasoning summary。
                // `detailed` 仍然只返回可展示摘要，不会暴露 raw chain-of-thought。
                "summary": .string("detailed"),
            ]
            // Codex 模型与推理强度属于 turn 级覆盖项。不能写进 thread/start，
            // 更不能沿用 Starcat BYOK 模型，否则 UI 选择与实际执行模型会错位。
            if let modelName = request.modelName?.nilIfBlank {
                turnParams["model"] = .string(modelName)
            }
            if let reasoningEffort = request.reasoningEffort?.nilIfBlank {
                turnParams["effort"] = .string(reasoningEffort)
            }
            return ExternalAgentProtocolOutput(outboundFrames: [
                .jsonRPCRequest(
                    id: Self.turnStartRequestID,
                    method: "turn/start",
                    params: .object(turnParams)
                )
            ])
        case Self.turnStartRequestID:
            turnID = result?[external: "turn"]?[external: "id"]?.stringValue
            return ExternalAgentProtocolOutput()
        default:
            return ExternalAgentProtocolOutput()
        }
    }

    private func makeThreadStartFrame() throws -> AgentJSONValue {
        var threadParams: [String: AgentJSONValue] = [
            "cwd": .string(request.workingDirectory.path),
            "approvalPolicy": .string("never"),
            "sandbox": .string("read-only"),
            "ephemeral": .bool(true),
            "developerInstructions": .string(
                "This is a Starcat read-only Agent Runtime. Do not modify files, run shell commands, spawn subagents, or request elevated permissions. Use only the supplied prompt context and Starcat dynamic tools."
            ),
            // App Server 会继承用户级 MCP、plugins 与 hooks。Starcat 必须在 session
            // layer 显式关闭它们，避免无关 MCP 启动超时，也确保能力面只来自 dynamicTools。
            "config": .object([
                "features": .object([
                    "plugins": .bool(false),
                    "hooks": .bool(false),
                    "plugin_hooks": .bool(false),
                    "apps": .bool(false),
                    "enable_mcp_apps": .bool(false),
                ]),
                "mcp_servers": .object(Self.disabling(inheritedMCPServerConfigs)),
            ]),
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
        return .jsonRPCRequest(
            id: Self.threadStartRequestID,
            method: "thread/start",
            params: .object(threadParams)
        )
    }

    private static func mergedMCPServerConfigs(
        from result: AgentJSONValue?
    ) -> [String: AgentJSONValue] {
        var merged: [String: AgentJSONValue] = [:]
        for layer in result?[external: "layers"]?.externalArray ?? [] {
            guard let servers = layer[external: "config"]?[external: "mcp_servers"]?.externalObject else {
                continue
            }
            for (name, value) in servers {
                guard let next = value.externalObject else { continue }
                var server = merged[name]?.externalObject ?? [:]
                server.merge(next) { _, latest in latest }
                merged[name] = .object(server)
            }
        }
        return merged
    }

    private static func disabling(
        _ configs: [String: AgentJSONValue]
    ) -> [String: AgentJSONValue] {
        configs.reduce(into: [:]) { result, entry in
            guard var config = entry.value.externalObject else { return }
            // SessionFlags 会按 server 整体校验；必须保留 command/url 等结构字段再关闭。
            // 原配置只在同一 Codex 子进程内往返，Host 从不记录或展示其中的 env 值。
            config["enabled"] = .bool(false)
            result[entry.key] = .object(config)
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
            if let itemID = params?[external: "itemId"]?.stringValue,
               agentMessagePhases[itemID] == "commentary" {
                agentMessageTexts[itemID, default: ""] += delta
                return ExternalAgentProtocolOutput(events: [
                    .trace(commentaryTrace(
                        id: itemID,
                        text: agentMessageTexts[itemID] ?? delta,
                        status: .running
                    )),
                ])
            }
            return ExternalAgentProtocolOutput(events: [.assistantDelta(delta)])
        case "item/started":
            guard let item = params?[external: "item"],
                  let itemID = item[external: "id"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            let startedAt = Date()
            itemStartedAt[itemID] = startedAt
            startedItems[itemID] = item
            if item[external: "type"]?.stringValue == "agentMessage" {
                let phase = item[external: "phase"]?.stringValue
                if let phase { agentMessagePhases[itemID] = phase }
                guard phase == "commentary" else { return ExternalAgentProtocolOutput() }
                return ExternalAgentProtocolOutput(events: [
                    .trace(commentaryTrace(id: itemID, text: nil, status: .running)),
                ])
            }
            guard let trace = Self.traceEvent(from: item, status: .running, startedAt: startedAt)
            else { return ExternalAgentProtocolOutput() }
            return ExternalAgentProtocolOutput(events: [.trace(trace)])
        case "item/completed":
            guard let item = params?[external: "item"] else { return ExternalAgentProtocolOutput() }
            var events: [ExternalAgentProtocolEvent] = []
            if item[external: "type"]?.stringValue == "agentMessage",
               let text = item[external: "text"]?.stringValue,
               !text.isEmpty {
                let itemID = item[external: "id"]?.stringValue
                let phase = item[external: "phase"]?.stringValue
                    ?? itemID.flatMap { agentMessagePhases[$0] }
                if phase == "commentary", let itemID {
                    // commentary 是模型主动给用户的过程说明，不是隐藏思维链；持久化为
                    // Markdown trace，最终回答仍只接收 final_answer 或旧版本的未知 phase。
                    events.append(.trace(commentaryTrace(
                        id: itemID,
                        text: text,
                        status: .completed,
                        completedAt: Date()
                    )))
                } else {
                    // 某些 App Server / model 组合可能只给 completed item，不保证逐 token delta。
                    // 用完整消息兜底，projector 会覆盖已收集的增量而不会重复落库。
                    events.append(.assistantMessage(text, usage: nil))
                }
                if let itemID {
                    agentMessagePhases[itemID] = nil
                    agentMessageTexts[itemID] = nil
                }
            }
            let itemID = item[external: "id"]?.stringValue
            let completedAt = Date()
            if item[external: "type"]?.stringValue == "reasoning",
               let itemID,
               let summary = Self.completedReasoningSummary(from: item)
                    ?? accumulatedReasoningSummary(for: itemID) {
                // summary delta 是用户可见的安全摘要；completed item 在部分 Codex 版本里
                // 不再重复 summary；另一些版本只在 completed item 返回 summary 数组。
                // 两条路径必须合并兜底，否则 upsert 会把已显示内容覆盖为空。
                events.append(.trace(ExternalAgentTraceEvent(
                    id: itemID,
                    kind: .reasoningSummary,
                    status: .completed,
                    title: String.l10n("agent.workspace.trace.kind.thinking"),
                    summary: summary,
                    details: [.init(
                        label: String.l10n("agent.workspace.timeline.reasoning"),
                        value: summary,
                        format: .markdown
                    )],
                    startedAt: itemStartedAt[itemID],
                    completedAt: completedAt
                )))
            } else if let trace = Self.traceEvent(
                from: item,
                status: Self.traceStatus(from: item) ?? .completed,
                startedAt: itemID.flatMap { itemStartedAt[$0] },
                completedAt: completedAt,
                progressText: itemID.flatMap { itemOutputTexts[$0] ?? itemPlanTexts[$0] }
            ) {
                events.append(.trace(trace))
            }
            if let itemID {
                startedItems[itemID] = nil
                itemOutputTexts[itemID] = nil
                itemPlanTexts[itemID] = nil
                itemStartedAt[itemID] = nil
                reasoningSummaries[itemID] = nil
            }
            return ExternalAgentProtocolOutput(events: events)
        case "item/commandExecution/outputDelta":
            guard let itemID = params?[external: "itemId"]?.stringValue,
                  let delta = params?[external: "delta"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            itemOutputTexts[itemID, default: ""] += delta
            let item = startedItems[itemID]
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: itemID,
                kind: .command,
                status: .running,
                title: item?[external: "command"]?.stringValue
                    ?? String.l10n("agent.workspace.trace.kind.command"),
                summary: item?[external: "status"]?.stringValue,
                details: [.init(
                    label: String.l10n("agent.workspace.trace.output"),
                    value: itemOutputTexts[itemID] ?? delta,
                    format: .code
                )],
                startedAt: itemStartedAt[itemID]
            ))])
        case "item/fileChange/outputDelta":
            guard let itemID = params?[external: "itemId"]?.stringValue,
                  let delta = params?[external: "delta"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            itemOutputTexts[itemID, default: ""] += delta
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: itemID,
                kind: .fileChange,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.fileChanges"),
                details: [.init(
                    label: String.l10n("agent.workspace.trace.output"),
                    value: itemOutputTexts[itemID] ?? delta,
                    format: .code
                )],
                startedAt: itemStartedAt[itemID]
            ))])
        case "item/fileChange/patchUpdated":
            guard let itemID = params?[external: "itemId"]?.stringValue,
                  let changes = params?[external: "changes"]
            else { return ExternalAgentProtocolOutput() }
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: itemID,
                kind: .fileChange,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.fileChanges"),
                details: ExternalAgentTracePayload.detail(
                    label: String.l10n("agent.workspace.trace.changes"),
                    value: changes
                ).map { [$0] } ?? [],
                startedAt: itemStartedAt[itemID]
            ))])
        case "item/mcpToolCall/progress":
            guard let itemID = params?[external: "itemId"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            let item = startedItems[itemID]
            let server = item?[external: "server"]?.stringValue ?? "MCP"
            let tool = item?[external: "tool"]?.stringValue ?? "tool"
            let message = params?[external: "message"]?.stringValue
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: itemID,
                kind: .mcpTool,
                status: .running,
                title: "\(server).\(tool)",
                summary: message,
                details: message.map {
                    [.init(label: String.l10n("agent.workspace.trace.progressUpdate"), value: $0)]
                } ?? [],
                startedAt: itemStartedAt[itemID]
            ))])
        case "item/plan/delta":
            guard let itemID = params?[external: "itemId"]?.stringValue,
                  let delta = params?[external: "delta"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            itemPlanTexts[itemID, default: ""] += delta
            let plan = itemPlanTexts[itemID] ?? delta
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: itemID,
                kind: .plan,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.plan"),
                summary: plan,
                details: [.init(
                    label: String.l10n("agent.workspace.trace.kind.plan"),
                    value: plan,
                    format: .markdown
                )],
                startedAt: itemStartedAt[itemID]
            ))])
        case "item/reasoning/summaryPartAdded":
            guard let itemID = params?[external: "itemId"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            let summaryIndex = params?[external: "summaryIndex"]?.integerValue ?? 0
            if reasoningSummaries[itemID]?[summaryIndex] == nil {
                reasoningSummaries[itemID, default: [:]][summaryIndex] = ""
            }
            return ExternalAgentProtocolOutput()
        case "item/reasoning/summaryTextDelta":
            guard let delta = params?[external: "delta"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            let itemID = params?[external: "itemId"]?.stringValue ?? "reasoning"
            let summaryIndex = params?[external: "summaryIndex"]?.integerValue ?? 0
            reasoningSummaries[itemID, default: [:]][summaryIndex, default: ""] += delta
            guard let summary = accumulatedReasoningSummary(for: itemID) else {
                return ExternalAgentProtocolOutput(events: [.reasoningDelta(delta)])
            }
            return ExternalAgentProtocolOutput(events: [
                .reasoningDelta(delta),
                .trace(ExternalAgentTraceEvent(
                    id: itemID,
                    kind: .reasoningSummary,
                    status: .running,
                    title: String.l10n("agent.workspace.trace.kind.thinking"),
                    summary: summary,
                    details: [.init(
                        label: String.l10n("agent.workspace.timeline.reasoning"),
                        value: summary,
                        format: .markdown
                    )],
                    startedAt: itemStartedAt[itemID] ?? Date()
                )),
            ])
        case "item/reasoning/textDelta":
            // raw reasoning 只用于既有的瞬时流式占位，不进入可持久化 trace；产品历史只保存
            // App Server 明确标记为 summary 的内容，避免暴露隐藏思维链。
            guard let delta = params?[external: "delta"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            return ExternalAgentProtocolOutput(events: [.reasoningDelta(delta)])
        case "turn/plan/updated":
            let plan = params?[external: "plan"]?.externalArray ?? []
            let details = plan.enumerated().compactMap { index, value -> AgentTraceDetail? in
                let step = value[external: "step"]?.stringValue
                    ?? value[external: "text"]?.stringValue
                    ?? value[external: "title"]?.stringValue
                guard let step, !step.isEmpty else { return nil }
                let status = value[external: "status"]?.stringValue ?? "pending"
                return AgentTraceDetail(label: "\(index + 1). \(status)", value: step)
            }
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "plan:\(turnID ?? "current")",
                kind: .plan,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.plan"),
                summary: details.isEmpty
                    ? nil
                    : String.localizedStringWithFormat(
                        String.l10n("agent.workspace.trace.stepCountFormat"),
                        details.count
                    ),
                details: details
            ))])
        case "hook/started", "hook/completed":
            guard let run = params?[external: "run"],
                  let id = run[external: "id"]?.stringValue
            else { return ExternalAgentProtocolOutput() }
            let completed = method == "hook/completed"
            let title = run[external: "eventName"]?.stringValue
                ?? run[external: "handlerType"]?.stringValue
                ?? String.l10n("agent.workspace.trace.kind.lifecycle")
            let summary = run[external: "status"]?.stringValue
                ?? run[external: "executionMode"]?.stringValue
            let visibleRun = run.removingExternalKeys(["sourcePath"])
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "hook:\(id)",
                kind: .lifecycle,
                status: completed ? (Self.traceStatus(from: run) ?? .completed) : .running,
                title: title,
                summary: summary,
                details: ExternalAgentTracePayload.detail(
                    label: String.l10n("agent.workspace.trace.eventData"),
                    value: visibleRun
                ).map { [$0] } ?? [],
                durationMilliseconds: run[external: "durationMs"]?.integerValue,
                completedAt: completed ? Date() : nil
            ))])
        case "thread/compacted":
            let id = params?[external: "turnId"]?.stringValue ?? turnID ?? "current"
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "compaction:\(id)",
                kind: .compaction,
                status: .completed,
                title: String.l10n("agent.workspace.trace.kind.contextCompaction"),
                completedAt: Date()
            ))])
        case "turn/diff/updated":
            guard let diff = params?[external: "diff"]?.stringValue else {
                return ExternalAgentProtocolOutput()
            }
            let id = params?[external: "turnId"]?.stringValue ?? turnID ?? "current"
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "diff:\(id)",
                kind: .fileChange,
                status: .running,
                title: String.l10n("agent.workspace.trace.kind.fileChanges"),
                details: [.init(
                    label: String.l10n("agent.workspace.trace.changes"),
                    value: diff,
                    format: .code
                )]
            ))])
        case "warning", "configWarning":
            let message = params?[external: "message"]?.stringValue
                ?? params?[external: "warning"]?.stringValue
                ?? String.l10n("agent.workspace.trace.warningFallback")
            return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                id: "warning:\(UUID().uuidString)",
                kind: .warning,
                status: .completed,
                title: String.l10n("agent.workspace.trace.kind.warning"),
                summary: message,
                details: [.init(label: String.l10n("agent.workspace.trace.message"), value: message)],
                completedAt: Date()
            ))])
        case "thread/tokenUsage/updated":
            guard let usage = Self.usage(from: params) else { return ExternalAgentProtocolOutput() }
            return ExternalAgentProtocolOutput(events: [
                .usage(usage),
                .trace(ExternalAgentTraceEvent(
                    id: "usage:\(turnID ?? "current")",
                    kind: .request,
                    status: .completed,
                    title: String.l10n("agent.workspace.trace.kind.tokenUsage"),
                    summary: String.localizedStringWithFormat(
                        String.l10n("agent.workspace.trace.tokenUsage.summaryFormat"),
                        usage.totalTokens
                    ),
                    usage: usage,
                    completedAt: Date()
                )),
            ])
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
                return Self.failedOutput(message, id: "turn-error:\(turnID ?? UUID().uuidString)")
            default:
                return ExternalAgentProtocolOutput()
            }
        case "error":
            let message = params?[external: "error"]?[external: "message"]?.stringValue
                ?? "Codex App Server reported an error."
            if params?[external: "willRetry"]?.externalBool == true {
                retryCount += 1
                return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                    id: "retry:\(turnID ?? "current"):\(retryCount)",
                    kind: .retry,
                    status: .running,
                    title: String.l10n("action.retry"),
                    summary: message,
                    details: [.init(
                        label: String.l10n("agent.workspace.trace.previousError"),
                        value: message,
                        format: .error
                    )],
                    attempt: retryCount
                ))])
            }
            return Self.failedOutput(message, id: "error:\(turnID ?? UUID().uuidString)")
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestUserInput":
            // 当前没有把 Codex approval 扩展成 Starcat 写入审批；请求必须明确拒绝。
            guard let id = object["id"] else { return ExternalAgentProtocolOutput() }
            let approvalID = (try? id.jsonString()) ?? UUID().uuidString
            let message = "Starcat External Agent Runtime is read-only."
            return ExternalAgentProtocolOutput(
                outboundFrames: [.object([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "error": .object([
                        "code": .number(-32_000),
                        "message": .string(message),
                    ]),
                ])],
                events: [.trace(ExternalAgentTraceEvent(
                    id: "approval:\(approvalID)",
                    kind: .approval,
                    status: .skipped,
                    title: String.l10n("agent.workspace.timeline.approval"),
                    summary: message,
                    details: [.init(label: method, value: message)],
                    completedAt: Date()
                ))]
            )
        default:
            // App Server 小版本会增加执行期通知。不能静默丢弃，也不能把整帧（含 RPC
            // 元数据和潜在 secret）直接展示；仅对执行域事件保留脱敏后的 params。
            if method.hasPrefix("item/")
                || method.hasPrefix("turn/")
                || method.hasPrefix("hook/")
                || method.hasPrefix("thread/compact") {
                let id = params?[external: "itemId"]?.stringValue
                    ?? params?[external: "turnId"]?.stringValue
                    ?? "\(method):\(UUID().uuidString)"
                let safeParams = ExternalAgentTracePayload.sanitized(params ?? .object([:]))
                return ExternalAgentProtocolOutput(events: [.trace(ExternalAgentTraceEvent(
                    id: "event:\(id):\(method)",
                    kind: .unknown,
                    status: .completed,
                    title: method,
                    details: ExternalAgentTracePayload.detail(
                        label: String.l10n("agent.workspace.trace.eventData"),
                        value: safeParams
                    ).map { [$0] } ?? [],
                    completedAt: Date()
                ))])
            }
            return ExternalAgentProtocolOutput()
        }
    }

    /// 把 App Server 的 user-visible commentary 保持为独立 Trace。这里不使用
    /// `assistantMessage`，否则中间 preamble 会覆盖真正的 final_answer。
    private func commentaryTrace(
        id: String,
        text: String?,
        status: AgentTraceStatus,
        completedAt: Date? = nil
    ) -> ExternalAgentTraceEvent {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed?.isEmpty == false ? trimmed : nil
        return ExternalAgentTraceEvent(
            id: id,
            kind: .commentary,
            status: status,
            title: String.l10n("agent.workspace.trace.kind.commentary"),
            summary: summary,
            details: summary.map { value in
                [.init(
                    label: String.l10n("agent.workspace.trace.progressUpdate"),
                    value: value,
                    format: .markdown
                )]
            } ?? [],
            startedAt: itemStartedAt[id],
            completedAt: completedAt
        )
    }

    private static func traceEvent(
        from item: AgentJSONValue,
        status: AgentTraceStatus,
        startedAt: Date?,
        completedAt: Date? = nil,
        progressText: String? = nil
    ) -> ExternalAgentTraceEvent? {
        guard let type = item[external: "type"]?.stringValue,
              let id = item[external: "id"]?.stringValue,
              !["userMessage", "agentMessage"].contains(type)
        else { return nil }

        let kind: AgentTraceKind
        let title: String
        var summary: String?
        var details: [AgentTraceDetail] = []
        var includesEventData = false
        switch type {
        case "plan":
            kind = .plan
            title = String.l10n("agent.workspace.trace.kind.plan")
            summary = item[external: "text"]?.stringValue ?? progressText
            if let summary {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.kind.plan"),
                    value: summary,
                    format: .markdown
                ))
            }
        case "reasoning":
            kind = .reasoningSummary
            title = String.l10n("agent.workspace.trace.kind.thinking")
            // completed item 里的 `text` 可能是 raw reasoning；只有 Provider 明确标记的
            // summary 才允许进入可恢复 Trace，避免把隐藏思维链持久化。
            summary = completedReasoningSummary(from: item)
            if let summary {
                details.append(.init(
                    label: String.l10n("agent.workspace.timeline.reasoning"),
                    value: summary,
                    format: .markdown
                ))
            }
        case "commandExecution":
            kind = .command
            title = item[external: "command"]?.stringValue
                ?? String.l10n("agent.workspace.trace.kind.command")
            summary = item[external: "status"]?.stringValue
            if let output = item[external: "aggregatedOutput"]?.stringValue
                ?? item[external: "output"]?.stringValue
                ?? progressText {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.output"),
                    value: output,
                    format: .code
                ))
            }
        case "fileChange":
            kind = .fileChange
            title = String.l10n("agent.workspace.trace.kind.fileChanges")
            summary = item[external: "status"]?.stringValue
            if let changes = item[external: "changes"] {
                if let detail = ExternalAgentTracePayload.detail(
                    label: String.l10n("agent.workspace.trace.changes"),
                    value: changes
                ) {
                    details.append(detail)
                }
            }
            if let progressText {
                details.append(.init(
                    label: String.l10n("agent.workspace.trace.output"),
                    value: progressText,
                    format: .code
                ))
            }
        case "mcpToolCall":
            kind = .mcpTool
            let server = item[external: "server"]?.stringValue ?? "MCP"
            let tool = item[external: "tool"]?.stringValue ?? "tool"
            title = "\(server).\(tool)"
            summary = item[external: "status"]?.stringValue
            if let arguments = item[external: "arguments"] {
                if let detail = ExternalAgentTracePayload.detail(
                    label: String.l10n("agent.workspace.trace.input"),
                    value: arguments
                ) {
                    details.append(detail)
                }
            }
            if let result = item[external: "result"] {
                if let detail = ExternalAgentTracePayload.detail(
                    label: String.l10n("agent.workspace.trace.output"),
                    value: result
                ) {
                    details.append(detail)
                }
            }
        case "webSearch":
            kind = .webSearch
            title = String.l10n("agent.workspace.trace.kind.webSearch")
            summary = item[external: "query"]?.stringValue
            if let query = item[external: "query"]?.stringValue {
                details.append(.init(label: String.l10n("agent.workspace.trace.query"), value: query))
            }
        case "contextCompaction":
            kind = .compaction
            title = String.l10n("agent.workspace.trace.kind.contextCompaction")
            summary = item[external: "status"]?.stringValue
        case "hookPrompt":
            kind = .message
            title = String.l10n("agent.workspace.trace.kind.hookPrompt")
            let count = item[external: "fragments"]?.externalArray?.count ?? 0
            summary = String.localizedStringWithFormat(
                String.l10n("agent.workspace.trace.fragmentCountFormat"),
                count
            )
            // Hook prompt 属于模型上下文，普通过程 UI 只显示片段数量，不能展开原文。
            details.append(.init(
                label: String.l10n("agent.workspace.trace.eventData"),
                value: summary ?? count.formatted()
            ))
        case "collabAgentToolCall":
            kind = .tool
            title = item[external: "tool"]?.stringValue
                ?? String.l10n("agent.workspace.trace.kind.collaboration")
            summary = item[external: "status"]?.stringValue
            includesEventData = true
        case "subAgentActivity":
            kind = .lifecycle
            title = String.l10n("agent.workspace.trace.kind.subAgentActivity")
            summary = item[external: "kind"]?.stringValue
            includesEventData = true
        case "imageView":
            kind = .tool
            title = String.l10n("agent.workspace.trace.kind.imageView")
            summary = item[external: "path"]?.stringValue
            includesEventData = true
        case "imageGeneration":
            kind = .tool
            title = String.l10n("agent.workspace.trace.kind.imageGeneration")
            summary = item[external: "status"]?.stringValue
            includesEventData = true
        case "sleep":
            kind = .lifecycle
            title = String.l10n("agent.workspace.trace.kind.waiting")
            if let duration = item[external: "durationMs"]?.integerValue {
                summary = "\(duration.formatted()) ms"
            }
            includesEventData = true
        case "enteredReviewMode", "exitedReviewMode":
            kind = .lifecycle
            title = String.l10n(
                type == "enteredReviewMode"
                    ? "agent.workspace.trace.kind.enteredReview"
                    : "agent.workspace.trace.kind.exitedReview"
            )
            summary = item[external: "review"]?.stringValue
            includesEventData = true
        case "dynamicToolCall":
            // Host 会在真实执行边界发出带输入与结果的 tool trace，避免同一次调用出现两行。
            return nil
        default:
            kind = .unknown
            title = type
            summary = item[external: "status"]?.stringValue
            includesEventData = true
        }
        if includesEventData,
           let detail = ExternalAgentTracePayload.detail(
               label: String.l10n("agent.workspace.trace.eventData"),
               value: item
           ) {
            details.append(detail)
        }
        if let error = item[external: "error"]?[external: "message"]?.stringValue
            ?? item[external: "error"]?.stringValue {
            details.append(.init(
                label: String.l10n("agent.workspace.trace.error"),
                value: error,
                format: .error
            ))
        }
        return ExternalAgentTraceEvent(
            id: id,
            parentID: item[external: "parentId"]?.stringValue,
            kind: kind,
            status: status,
            title: title,
            summary: summary,
            details: details,
            durationMilliseconds: item[external: "durationMs"]?.integerValue,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    /// completed reasoning 的 `summary` 是 `[{ type: "summary_text", text: "..." }]`，
    /// 不是字符串。只接受 Provider 明确标记的 summary_text，raw content 永不进入 Trace。
    private static func completedReasoningSummary(from item: AgentJSONValue) -> String? {
        let parts = item[external: "summary"]?.externalArray?.compactMap { part -> String? in
            guard part[external: "type"]?.stringValue == "summary_text" else { return nil }
            return part[external: "text"]?.stringValue?.nilIfBlank
        } ?? []
        return parts.joined(separator: "\n\n").nilIfBlank
    }

    private func accumulatedReasoningSummary(for itemID: String) -> String? {
        reasoningSummaries[itemID]?
            .sorted { $0.key < $1.key }
            .compactMap { $0.value.nilIfBlank }
            .joined(separator: "\n\n")
            .nilIfBlank
    }

    private static func traceStatus(from item: AgentJSONValue) -> AgentTraceStatus? {
        switch item[external: "status"]?.stringValue {
        case "inProgress", "running": return .running
        case "completed", "success": return .completed
        case "failed", "error": return .failed
        case "declined", "skipped": return .skipped
        case "cancelled", "interrupted": return .cancelled
        default: return nil
        }
    }

    private static func usage(from params: AgentJSONValue?) -> AgentUsage? {
        let usage = params?[external: "tokenUsage"] ?? params?[external: "usage"]
        let totals = usage?[external: "total"] ?? usage
        guard let object = totals?.externalObject else { return nil }
        let input = object["inputTokens"]?.integerValue ?? object["input_tokens"]?.integerValue ?? 0
        let output = object["outputTokens"]?.integerValue ?? object["output_tokens"]?.integerValue ?? 0
        let cached = object["cachedInputTokens"]?.integerValue ?? object["cached_input_tokens"]?.integerValue ?? 0
        let cacheWrite = object["cacheWriteInputTokens"]?.integerValue
            ?? object["cache_write_input_tokens"]?.integerValue
        let reasoning = object["reasoningOutputTokens"]?.integerValue ?? object["reasoning_tokens"]?.integerValue ?? 0
        let total = object["totalTokens"]?.integerValue ?? object["total_tokens"]?.integerValue
        let last = usage?[external: "last"]
        let contextUsed = last?[external: "totalTokens"]?.integerValue
            ?? last?[external: "total_tokens"]?.integerValue
        let contextLimit = usage?[external: "modelContextWindow"]?.integerValue
            ?? usage?[external: "model_context_window"]?.integerValue
        return AgentUsage(
            inputTokens: input,
            outputTokens: output,
            cachedTokens: cached,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            totalTokens: total,
            contextWindowUsedTokens: contextUsed,
            contextWindowLimitTokens: contextLimit
        )
    }

    /// Provider 的终态失败同时投影为可展开 Trace 与 Run 终态。仅发 `.failed` 会让用户
    /// 看到红色横幅，却无法在过程列表里定位是哪个 turn/error 事件结束了执行。
    private static func failedOutput(_ message: String, id: String) -> ExternalAgentProtocolOutput {
        ExternalAgentProtocolOutput(
            events: [
                .trace(ExternalAgentTraceEvent(
                    id: id,
                    kind: .error,
                    status: .failed,
                    title: String.l10n("error.loadFailed"),
                    summary: message,
                    details: [.init(label: String.l10n("error.loadFailed"), value: message, format: .error)],
                    completedAt: Date()
                )),
                .failed(message),
            ],
            isTerminal: true
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
