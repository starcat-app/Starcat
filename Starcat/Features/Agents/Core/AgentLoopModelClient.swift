//
//  AgentLoopModelClient.swift
//  Starcat
//
//  Agent Loop 与 Starcat 现有 AI Provider 配置之间的适配层。
//
//  模块职责：
//  - 把 Prompt Pipeline、AgentMessage 和 AgentToolDefinition 转成 AIChatRequest；
//  - 复用设置页的 provider、model、参数与 Keychain API key；
//  - 将 provider 流式事件归一为 Runtime 可消费的 Agent 事件；
//  - 在进入网络前拦截已知不支持 tool-calling 的模型，并把 provider 的能力错误分类。
//

import Foundation

struct AgentModelRequest: Sendable {
    var prompt: AgentPromptTurnRequest
    var tools: [AgentToolDefinition]
    /// Runtime 在普通回合使用 auto；进入最终提交回合后切为 required，避免模型用纯文本
    /// 消耗最后一次机会而跳过结构化 Artifact 工具。
    var toolChoice: AIChatToolChoice = .auto
    var metadata: [String: String]
}

struct AgentModelToolCall: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// 保留模型原始 JSON 参数；Runtime 解码失败时仍能完整审计 provider 输出。
    var arguments: String
}

struct AgentModelResponse: Equatable, Sendable {
    var text: String
    var reasoning: String?
    var toolCalls: [AgentModelToolCall]
    var usage: AgentUsage? = nil
    var model: String
    var finishReason: String?
}

enum AgentModelStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(AIChatToolCallDelta)
    case usage(AgentUsage)
    case completed(AgentModelResponse)
}

protocol AgentLoopModelClient: Sendable {
    func stream(request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, Error>
}

enum AgentLoopModelError: Error, LocalizedError, Equatable, Sendable {
    case missingProvider
    case missingAPIKey
    case toolCallingUnsupported(model: String)
    case invalidToolName(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String.l10n("agent.model.error.missingProvider")
        case .missingAPIKey:
            return String.l10n("agent.model.error.missingAPIKey")
        case .toolCallingUnsupported(let model):
            return String(format: String.l10n("agent.model.error.toolCallingUnsupportedFormat"), model)
        case .invalidToolName(let name):
            return String(format: String.l10n("agent.model.error.invalidToolNameFormat"), name)
        case .provider(let message):
            return String(format: String.l10n("agent.model.error.providerFormat"), message)
        }
    }
}

struct OpenAIAgentLoopModelClient: AgentLoopModelClient {
    private let client: any AIClientProtocol
    private let model: String
    private let parameters: AIModelParameters

    init(client: any AIClientProtocol, model: String, parameters: AIModelParameters) {
        self.client = client
        self.model = model
        self.parameters = parameters
    }

    func stream(request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let chatRequest = try Self.makeChatRequest(
                        request: request,
                        model: model,
                        parameters: parameters
                    )
                    if parameters.streamEnabled {
                        for try await event in client.chatStream(request: chatRequest) {
                            switch event {
                            case .delta(let delta):
                                continuation.yield(.textDelta(delta))
                            case .reasoningDelta(let delta):
                                continuation.yield(.reasoningDelta(delta))
                            case .reasoningCompleted:
                                // Agent 时间线只消费推理增量；终止事件由最终 completed 响应收口。
                                break
                            case .toolCallDelta(let delta):
                                continuation.yield(.toolCallDelta(delta))
                            case .usage(let usage):
                                continuation.yield(.usage(Self.agentUsage(from: usage)))
                            case .completed(let response):
                                continuation.yield(.completed(Self.modelResponse(from: response)))
                            }
                        }
                    } else {
                        let response = try await client.chat(request: chatRequest)
                        continuation.yield(.completed(Self.modelResponse(from: response)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.classify(error, model: model))
                }
            }
            // AsyncThrowingStream 的 producer Task 不会自动继承消费者后续的取消状态。
            // 显式传播终止,确保用户停止 run 后底层 Provider 网络流也立即结束。
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    static func makeChatRequest(
        request: AgentModelRequest,
        model: String,
        parameters: AIModelParameters
    ) throws -> AIChatRequest {
        let tools = try request.tools.map { definition in
            guard AgentToolDefinition.isProviderCompatibleName(definition.name) else {
                throw AgentLoopModelError.invalidToolName(definition.name)
            }
            return AIChatTool(
                name: definition.name,
                description: definition.description,
                inputSchema: definition.inputSchema,
                strict: false
            )
        }
        return AIChatRequest(
            systemPrompt: request.prompt.systemPrompt,
            userPrompt: request.prompt.userPrompt,
            history: try chatMessages(from: request.prompt.messages),
            model: model,
            parameters: parameters,
            responseFormat: .text,
            tools: tools,
            toolChoice: tools.isEmpty ? .none : request.toolChoice,
            parallelToolCalls: false,
            metadata: request.metadata,
            includeUsage: true,
            // 每次模型回合都归因到 Agent，并用 run_id 串起同一 Run 的多次 tool loop。
            usageContext: AIUsageContext(
                feature: .agent,
                phase: "loop",
                correlationID: request.metadata["run_id"]
            )
        )
    }

    private static func chatMessages(from messages: [AgentMessage]) throws -> [AIChatMessage] {
        var result: [AIChatMessage] = []
        for message in messages.sorted(by: { $0.sequence < $1.sequence }) {
            switch message.role {
            case .user:
                result.append(.init(role: .user, content: text(in: message.parts)))
            case .assistant:
                let calls = try message.parts.compactMap { part -> AIChatToolCall? in
                    guard case .toolCall(let call) = part else { return nil }
                    return AIChatToolCall(
                        id: call.id,
                        name: call.name,
                        arguments: try call.rawInput ?? call.input.jsonString()
                    )
                }
                result.append(.init(
                    role: .assistant,
                    content: text(in: message.parts),
                    reasoningContent: reasoning(in: message.parts),
                    toolCalls: calls
                ))
            case .tool:
                for part in message.parts {
                    guard case .toolResult(let toolResult) = part else { continue }
                    result.append(.init(
                        role: .tool,
                        content: try toolResultEnvelope(toolResult).jsonString(),
                        toolCallID: toolResult.toolCallID
                    ))
                }
            }
        }
        return result
    }

    private static func text(in parts: [AgentMessagePart]) -> String {
        parts.compactMap { part in
            guard case .text(let text) = part else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func reasoning(in parts: [AgentMessagePart]) -> String? {
        let value = parts.compactMap { part in
            guard case .reasoning(let text) = part else { return nil }
            return text
        }.joined(separator: "\n")
        return value.isEmpty ? nil : value
    }

    private static func toolResultEnvelope(_ result: AgentToolResultMessage) -> AgentJSONValue {
        .object([
            "status": .string(result.status.rawValue),
            "is_error": .bool(result.isError),
            "elapsed_ms": .number(Double(result.elapsedMilliseconds)),
            "output": result.output,
            "sources": .array(result.sources.map { source in
                .object([
                    "title": .string(source.title),
                    "url": .string(source.url),
                    "provider": source.provider.map(AgentJSONValue.string) ?? .null
                ])
            })
        ])
    }

    private static func modelResponse(from response: AIChatResponse) -> AgentModelResponse {
        AgentModelResponse(
            text: response.content,
            reasoning: response.reasoningContent,
            toolCalls: response.toolCalls.map {
                AgentModelToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            usage: response.usage.map(agentUsage),
            model: response.model,
            finishReason: response.finishReason
        )
    }

    private static func agentUsage(from usage: AIChatUsage) -> AgentUsage {
        AgentUsage(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cachedTokens: usage.cachedTokens,
            reasoningTokens: usage.reasoningTokens,
            totalTokens: usage.totalTokens
        )
    }

    static func classify(_ error: Error, model: String) -> Error {
        if let error = error as? AgentLoopModelError { return error }
        let description = error.localizedDescription
        let lowered = description.lowercased()
        let mentionsTools = lowered.contains("tool") || lowered.contains("function call")
        let unsupported = lowered.contains("not support")
            || lowered.contains("unsupported")
            || lowered.contains("not available")
            || lowered.contains("not allowed")
        if mentionsTools && unsupported {
            return AgentLoopModelError.toolCallingUnsupported(model: model)
        }
        return AgentLoopModelError.provider(description)
    }

}

@MainActor
enum AgentLoopModelClientFactory {
    static func make(
        settings: AppSettings,
        selectedModelID: String? = nil,
        keychain: any KeychainManaging = KeychainManager.shared
    ) throws -> any AgentLoopModelClient {
        let task = settings.aiChatTask
        let selection = selectedModelID.flatMap { selectedID in
            settings.aiProviderProfiles.lazy
                .filter { $0.isEnabled }
                .compactMap { profile in
                    profile.models.first(where: {
                        $0.id == selectedID && $0.isEnabled && $0.capability != .embedding
                    }).map { (profile, $0) }
                }
                .first
        }
        guard let profile = selection?.0
            ?? settings.aiProviderProfiles.first(where: { $0.id == task.providerID && $0.isEnabled }) else {
            throw AgentLoopModelError.missingProvider
        }

        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw AgentLoopModelError.missingAPIKey
        }

        let taskModel = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = selection?.1.name ?? (taskModel.isEmpty ? settings.aiChatModel : taskModel)
        let descriptor = profile.models.first(where: { $0.name == resolvedModel })
        let capability = descriptor?.capability ?? AIModelCapability.inferred(from: resolvedModel)
        guard capability != .embedding else {
            throw AgentLoopModelError.toolCallingUnsupported(model: resolvedModel)
        }

        // 显式选择模型时读取该 descriptor 的参数；没有选择时保持全局 chat task 行为。
        let parameters = selection?.1.parameters
            ?? (selection == nil
                ? settings.effectiveParameters(for: task)
                : AIModelParameters.defaults(for: capability))
        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: resolvedModel,
            embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
            timeoutInterval: parameters.timeoutSeconds
        ))
        return OpenAIAgentLoopModelClient(client: client, model: resolvedModel, parameters: parameters)
    }
}
