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
    var usage: AgentUsage?
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
            Task {
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
        }
    }

    static func makeChatRequest(
        request: AgentModelRequest,
        model: String,
        parameters: AIModelParameters
    ) throws -> AIChatRequest {
        let tools = try request.tools.map { definition in
            guard isProviderCompatibleToolName(definition.name) else {
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
            toolChoice: tools.isEmpty ? .none : .auto,
            parallelToolCalls: false,
            metadata: request.metadata,
            includeUsage: true
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
                    return AIChatToolCall(id: call.id, name: call.name, arguments: try call.input.jsonString())
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

    private static func isProviderCompatibleToolName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

@MainActor
enum AgentLoopModelClientFactory {
    static func make(
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared
    ) throws -> any AgentLoopModelClient {
        let task = settings.aiChatTask
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID && $0.isEnabled }) else {
            throw AgentLoopModelError.missingProvider
        }

        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw AgentLoopModelError.missingAPIKey
        }

        let model = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.isEmpty ? settings.aiChatModel : model
        let descriptor = profile.models.first(where: { $0.name == resolvedModel })
        let capability = descriptor?.capability ?? AIModelCapability.inferred(from: resolvedModel)
        guard capability != .embedding else {
            throw AgentLoopModelError.toolCallingUnsupported(model: resolvedModel)
        }

        let parameters = settings.effectiveParameters(for: task)
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
