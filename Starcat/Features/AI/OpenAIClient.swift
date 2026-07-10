//
//  OpenAIClient.swift
//  Starcat
//
//  MacPaw/OpenAI adapter。
//
//  技术选择：
//  - 底层使用 MacPaw/OpenAI 的 `OpenAIProtocol`，原因见
//    `docs/3-设计/详细设计/12-AI库选型调研.md`：协议化、可 mock、支持 OpenAI-compatible
//    Base URL，并且已覆盖 chat / embeddings。
//  - Starcat 业务层只依赖 `AIClientProtocol`，避免把第三方 SDK 类型扩散到 UI、
//    Repository 或 ViewModel。
//
//  BYOK 约束：
//  - 这是用户本地应用，Key 由用户自带并保存在本机加密文件。
//  - Starcat 不做自建代理，也不把 Key 上传到 Starcat 服务端。
//

import Foundation
import OpenAI

/// MacPaw/OpenAI 的具体适配器。
struct OpenAIClient: AIClientProtocol {

    private let configuration: AIClientConfiguration
    private let client: OpenAIProtocol

    init(configuration: AIClientConfiguration) throws {
        let trimmedKey = Self.effectiveAPIKey(for: configuration)
        guard !trimmedKey.isEmpty else { throw AIClientError.missingAPIKey }

        let sdkConfig = try Self.makeSDKConfiguration(from: configuration, apiKey: trimmedKey)
        self.configuration = configuration
        #if DEBUG
        self.client = OpenAI(
            configuration: sdkConfig,
            session: Self.makeDebuggableSession(timeoutInterval: configuration.timeoutInterval)
        )
        #else
        self.client = OpenAI(configuration: sdkConfig)
        #endif
    }

    /// 生产代码注入真实 MacPaw client；单元测试可用 mock OpenAIProtocol 走这里。
    init(configuration: AIClientConfiguration, client: OpenAIProtocol) {
        self.configuration = configuration
        self.client = client
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        let resolvedModel = request.model.nilIfBlank ?? configuration.chatModel
        #if DEBUG
        AIDebugLogger.logChatRequest(
            baseURL: configuration.baseURL,
            model: resolvedModel,
            systemPromptLength: request.systemPrompt.count,
            userPromptLength: request.userPrompt.count
        )
        #endif
        let query = try Self.makeChatQuery(request: request, resolvedModel: resolvedModel, stream: false)

        let result = try await client.chats(query: query)
        #if DEBUG
        if DebugFlags.aiHTTPLogging {
            AIDebugLogger.dumpDecodedChatResult(result, reason: "chat-success")
        }
        #endif
        guard let choice = result.choices.first else {
            throw AIClientError.emptyResponse
        }
        let toolCalls = Self.toolCalls(from: choice.message.toolCalls)
        let content = choice.message.content ?? ""
        guard content.nilIfBlank != nil || !toolCalls.isEmpty else {
            #if DEBUG
            AIDebugLogger.dumpDecodedChatResult(result, reason: "empty-message-content")
            #endif
            throw AIClientError.emptyResponse
        }
        if choice.finishReason == ChatResult.Choice.FinishReason.length.rawValue {
            throw AIClientError.responseTruncated
        }
        return AIChatResponse(
            content: content,
            reasoningContent: choice.message.reasoning,
            toolCalls: toolCalls,
            usage: Self.usage(from: result.usage),
            model: result.model,
            finishReason: choice.finishReason
        )
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let resolvedModel = request.model.nilIfBlank ?? configuration.chatModel
                    #if DEBUG
                    AIDebugLogger.logChatRequest(
                        baseURL: configuration.baseURL,
                        model: resolvedModel,
                        systemPromptLength: request.systemPrompt.count,
                        userPromptLength: request.userPrompt.count
                    )
                    #endif
                    let query = try Self.makeChatQuery(request: request, resolvedModel: resolvedModel, stream: true)
                    var content = ""
                    var reasoningContent = ""
                    var finishReason: String?
                    var toolCallAccumulator = AIChatToolCallAccumulator()
                    var finalUsage: AIChatUsage?
                    var responseModel = resolvedModel
                    for try await chunk in client.chatsStream(query: query) {
                        responseModel = chunk.model
                        if let usage = Self.usage(from: chunk.usage) {
                            finalUsage = usage
                            continuation.yield(.usage(usage))
                        }
                        for choice in chunk.choices {
                            if let delta = choice.delta.content, !delta.isEmpty {
                                content += delta
                                continuation.yield(.delta(delta))
                            }
                            if let delta = choice.delta.reasoning, !delta.isEmpty {
                                reasoningContent += delta
                                continuation.yield(.reasoningDelta(delta))
                            }
                            for call in choice.delta.toolCalls ?? [] {
                                let delta = AIChatToolCallDelta(
                                    index: call.index,
                                    id: call.id,
                                    name: call.function?.name,
                                    argumentsFragment: call.function?.arguments
                                )
                                toolCallAccumulator.append(delta)
                                continuation.yield(.toolCallDelta(delta))
                            }
                            if let reason = choice.finishReason {
                                finishReason = reason.rawValue
                            }
                        }
                    }
                    let toolCalls = toolCallAccumulator.completedCalls()
                    guard content.nilIfBlank != nil || !toolCalls.isEmpty else {
                        continuation.finish(throwing: AIClientError.emptyResponse)
                        return
                    }
                    if finishReason == ChatResult.Choice.FinishReason.length.rawValue {
                        continuation.finish(throwing: AIClientError.responseTruncated)
                        return
                    }
                    continuation.yield(.completed(AIChatResponse(
                        content: content,
                        reasoningContent: reasoningContent.nilIfBlank,
                        toolCalls: toolCalls,
                        usage: finalUsage,
                        model: responseModel,
                        finishReason: finishReason
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        let response = try await chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model?.nilIfBlank ?? configuration.chatModel,
            parameters: .summaryDefault
        ))
        return response.content
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        let vectors = try await embeddings(inputs: [input], model: model)
        guard let first = vectors.first else { throw AIClientError.emptyResponse }
        return first
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let resolvedModel = model?.nilIfBlank ?? configuration.embeddingModel
        let query = EmbeddingsQuery(input: .stringList(inputs), model: resolvedModel)
        let result = try await client.embeddings(query: query)
        let vectors = result.data
            .sorted { $0.index < $1.index }
            .map { $0.embedding.map(Float.init) }
        guard vectors.count == inputs.count, vectors.allSatisfy({ !$0.isEmpty }) else {
            throw AIClientError.emptyResponse
        }
        return vectors
    }

    func listModels() async throws -> [AIModelDescriptor] {
        let url = try Self.modelsURL(baseURL: configuration.baseURL, provider: configuration.provider)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeoutInterval
        let key = Self.effectiveAPIKey(for: configuration)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.modelListRequestFailed(String.l10n("ai.client.modelList.noHTTPResponse"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIClientError.modelListRequestFailed("HTTP \(http.statusCode) \(body.prefix(240))")
        }
        do {
            let decoded = try JSONDecoder().decode(ProviderModelsResponse.self, from: data)
            return decoded.data.map {
                AIModelDescriptor(
                    providerID: configuration.providerID,
                    name: $0.id,
                    ownedBy: $0.ownedBy,
                    capability: AIModelCapability.inferred(from: "\($0.id) \($0.name ?? "")"),
                    isEnabled: true,
                    isCustom: false
                )
            }
        } catch {
            throw AIClientError.modelListRequestFailed(error.localizedDescription)
        }
    }

    /// 连接测试使用 embeddings 而不是 chat：
    /// - token / Base URL / model 三项都能被验证；
    /// - 输入极短，成本比让模型生成文本更低；
    /// - embedding 是语义搜索的硬依赖，设置页优先验证它更贴近第一版功能闭环。
    func testConnection() async throws {
        _ = try await listModels()
    }

    static func makeChatQuery(
        request: AIChatRequest,
        resolvedModel: String,
        stream: Bool
    ) throws -> ChatQuery {
        // 顺序：system → [history...] → user。
        //
        // 历史里的 .user / .assistant 各自映射到 MacPaw 的对应 case。
        // 这里**不**把 history 的 system 角色透传给 SDK：
        // 多 system 消息在不少 OpenAI-compatible 服务端会被合并或报错，
        // Starcat 自己也只在数组开头放一条 systemPrompt 表达"全局指令"，
        // 历史只用来承载真实对话轮次（HOM-150）。
        var messages: [ChatQuery.ChatCompletionMessageParam] = [
            .system(.init(content: .textContent(request.systemPrompt)))
        ]
        for message in request.history {
            switch message.role {
            case .user:
                messages.append(.user(.init(content: .string(message.content))))
            case .assistant:
                let toolCalls = message.toolCalls.map { call in
                    ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam(
                        id: call.id,
                        function: .init(arguments: call.arguments, name: call.name)
                    )
                }
                messages.append(.assistant(.init(
                    content: message.content.isEmpty ? nil : .textContent(message.content),
                    reasoningContent: message.reasoningContent,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls
                )))
            case .tool:
                guard let toolCallID = message.toolCallID?.nilIfBlank else {
                    throw AIClientError.invalidChatHistory("tool message is missing tool_call_id")
                }
                messages.append(.tool(.init(
                    content: .textContent(message.content),
                    toolCallId: toolCallID
                )))
            }
        }
        if let userPrompt = request.userPrompt.nilIfBlank {
            messages.append(.user(.init(content: .string(userPrompt))))
        }

        let tools = try request.tools.map { tool in
            ChatQuery.ChatCompletionToolParam(function: .init(
                name: tool.name,
                description: tool.description,
                parameters: try sdkSchema(from: tool.inputSchema),
                strict: tool.strict
            ))
        }

        return ChatQuery(
            messages: messages,
            model: resolvedModel,
            maxCompletionTokens: request.parameters.maxCompletionTokens > 0 ? request.parameters.maxCompletionTokens : nil,
            metadata: request.metadata.isEmpty ? nil : request.metadata,
            parallelToolCalls: tools.isEmpty ? nil : request.parallelToolCalls,
            responseFormat: request.responseFormat == .jsonObject ? .jsonObject : nil,
            temperature: request.parameters.temperature,
            toolChoice: tools.isEmpty ? nil : sdkToolChoice(request.toolChoice),
            tools: tools.isEmpty ? nil : tools,
            topP: request.parameters.topP,
            stream: stream,
            streamOptions: stream && request.includeUsage ? .init(includeUsage: true) : nil
        )
    }

    private static func sdkSchema(from schema: AgentJSONSchema) throws -> JSONSchema {
        let data = try JSONEncoder().encode(schema)
        return try JSONDecoder().decode(JSONSchema.self, from: data)
    }

    private static func sdkToolChoice(_ choice: AIChatToolChoice) -> ChatQuery.ChatCompletionFunctionCallOptionParam {
        switch choice {
        case .none:
            return .none
        case .auto:
            return .auto
        case .required:
            return .required
        case .tool(let name):
            return .function(name)
        }
    }

    private static func toolCalls(
        from calls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam]?
    ) -> [AIChatToolCall] {
        (calls ?? []).map { call in
            AIChatToolCall(
                id: call.id.nilIfBlank ?? UUID().uuidString,
                name: call.function.name,
                arguments: call.function.arguments.nilIfBlank ?? "{}"
            )
        }
    }

    private static func usage(from usage: ChatResult.CompletionUsage?) -> AIChatUsage? {
        guard let usage else { return nil }
        return AIChatUsage(
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            cachedTokens: usage.promptTokensDetails?.cachedTokens ?? 0,
            reasoningTokens: usage.completionTokensDetails?.reasoningTokens ?? 0,
            totalTokens: usage.totalTokens
        )
    }

    /// 将用户输入的 OpenAI-compatible Base URL 拆给 MacPaw/OpenAI。
    ///
    /// MacPaw 的 Configuration 接收 host / basePath，而设置页让用户输入完整 URL。
    /// 这里保留 path 是为了兼容 `/v1`、`/openai/v1`、代理前缀等部署方式。
    private static func makeSDKConfiguration(
        from config: AIClientConfiguration,
        apiKey: String
    ) throws -> OpenAI.Configuration {
        guard let url = URL(string: config.baseURL),
              let scheme = url.scheme,
              let host = url.host
        else {
            throw AIClientError.invalidBaseURL(config.baseURL)
        }

        let basePath = url.path.isEmpty ? "/v1" : url.path
        let port = url.port ?? (scheme == "http" ? 80 : 443)

        return OpenAI.Configuration(
            token: apiKey,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: config.timeoutInterval,
            parsingOptions: [.relaxed]
        )
    }

    private static func effectiveAPIKey(for configuration: AIClientConfiguration) -> String {
        let trimmed = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return configuration.provider.fallbackAPIKey
    }

    private static func modelsURL(baseURL: String, provider: AIServiceProvider) throws -> URL {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host
        else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port

        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch provider {
        case .deepSeek:
            components.path = "/models"
        default:
            components.path = trimmedPath.isEmpty ? "/v1/models" : "/\(trimmedPath)/models"
        }

        guard let finalURL = components.url else {
            throw AIClientError.invalidBaseURL(baseURL)
        }
        return finalURL
    }

    #if DEBUG
    /// 构造 Debug 期可插拔的 URLSession。
    ///
    /// MacPaw/OpenAI 允许注入 `URLSession`。这里仅在 `DebugAIHTTPLogging` 打开时
    /// 插入 `AIHTTPDebugURLProtocol`，这样能看到 LM Studio 原始 JSON，同时不影响
    /// 默认开发体验；Release 构建完全走普通 SDK 初始化路径。
    private static func makeDebuggableSession(timeoutInterval: TimeInterval) -> URLSession {
        guard DebugFlags.aiHTTPLogging else { return .shared }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        configuration.protocolClasses = [AIHTTPDebugURLProtocol.self] + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration)
    }
    #endif
}

private struct ProviderModelsResponse: Decodable {
    var data: [ProviderModel]
}

private struct ProviderModel: Decodable {
    var id: String
    var name: String?
    var ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownedBy = "owned_by"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
