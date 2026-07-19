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
            let query = makeChatQuery(request: request, resolvedModel: resolvedModel, stream: false)

            let result = try await client.chats(query: query)
            #if DEBUG
            if DebugFlags.aiHTTPLogging {
                AIDebugLogger.dumpDecodedChatResult(result, reason: "chat-success")
            }
            #endif
            guard let content = result.choices.first?.message.content?.nilIfBlank else {
                #if DEBUG
                AIDebugLogger.dumpDecodedChatResult(result, reason: "empty-message-content")
                #endif
                throw AIClientError.emptyResponse
            }
            if result.choices.first?.finishReason == ChatResult.Choice.FinishReason.length.rawValue {
                throw AIClientError.responseTruncated
            }
            return AIChatResponse(
                content: content,
                model: result.model,
                finishReason: result.choices.first?.finishReason
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIClientError {
            throw error
        } catch {
            // SDK 的 statusError 会把整段 NSHTTPURLResponse dump 进 localizedDescription；
            // 产品层只应看到归类后的 AIClientError。
            AppLog.ai.error("Chat request failed: \(error.localizedDescription, privacy: .public)")
            throw Self.mapChatFailure(error)
        }
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
                    let query = makeChatQuery(request: request, resolvedModel: resolvedModel, stream: true)
                    var content = ""
                    var finishReason: String?
                    var reasoningNormalizer = AIStreamReasoningNormalizer()
                    for try await chunk in client.chatsStream(query: query) {
                        for choice in chunk.choices {
                            for event in reasoningNormalizer.ingest(
                                content: choice.delta.content,
                                nativeReasoning: choice.delta.reasoning
                            ) {
                                if case .delta(let delta) = event {
                                    content += delta
                                }
                                continuation.yield(event)
                            }
                            if let reason = choice.finishReason {
                                finishReason = reason.rawValue
                            }
                        }
                    }
                    for event in reasoningNormalizer.finish() {
                        if case .delta(let delta) = event {
                            content += delta
                        }
                        continuation.yield(event)
                    }
                    guard let final = content.nilIfBlank else {
                        continuation.finish(throwing: AIClientError.emptyResponse)
                        return
                    }
                    if finishReason == ChatResult.Choice.FinishReason.length.rawValue {
                        continuation.finish(throwing: AIClientError.responseTruncated)
                        return
                    }
                    continuation.yield(.completed(AIChatResponse(
                        content: final,
                        model: resolvedModel,
                        finishReason: finishReason
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as AIClientError {
                    continuation.finish(throwing: error)
                } catch {
                    AppLog.ai.error("Chat stream failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: Self.mapChatFailure(error))
                }
            }
        }
    }

    // MARK: - Chat 错误映射

    /// 把 MacPaw SDK / URLSession 层错误收成 `AIClientError`，供 UI 与批量整理面板展示。
    ///
    /// 保持与 `embeddingError(from:)` 同构：按 HTTP 状态码 / Provider 文案分流，并把
    /// 短诊断塞进 associated `detail`，避免把 `statusError(response: <NSHTTPURLResponse…>)`
    /// 原样甩给用户。
    static func mapChatFailure(_ error: Error) -> AIClientError {
        if let error = error as? AIClientError {
            return error
        }
        if let error = error as? APIErrorResponse {
            return chatAPIError(message: error.error.message)
        }
        if let error = error as? OpenAIError {
            switch error {
            case .emptyData:
                return .emptyResponse
            case .statusError(let response, let statusCode):
                let detail = httpDiagnosticDetail(response: response, statusCode: statusCode)
                return chatHTTPError(statusCode: statusCode, detail: detail)
            }
        }
        if let error = error as? URLError {
            let detail = "URLError \(error.code.rawValue): \(error.localizedDescription)"
            return error.code == .timedOut
                ? .timedOut(detail: detail)
                : .networkUnavailable(detail: detail)
        }
        if error is DecodingError {
            return .requestFailed(detail: "decoding error")
        }
        // 兜底：截断并脱敏，绝不把超长 SDK dump 当作主文案。
        let raw = String(describing: error)
        let clipped = String(raw.prefix(800))
        return .requestFailed(detail: DiagnosticEvent.redact(clipped))
    }

    /// 结构化 HTTP 诊断（多行），供展开详情与复制；不含 Authorization 等敏感头。
    private static func httpDiagnosticDetail(response: HTTPURLResponse, statusCode: Int) -> String {
        var lines: [String] = []
        let phrase = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.isEmpty {
            lines.append("HTTP \(statusCode)")
        } else {
            lines.append("HTTP \(statusCode) \(phrase)")
        }
        if let url = response.url?.absoluteString, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let mime = response.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines), !mime.isEmpty {
            lines.append("Content-Type: \(mime)")
        }
        return lines.joined(separator: "\n")
    }

    private static func chatHTTPError(statusCode: Int, detail: String) -> AIClientError {
        switch statusCode {
        case 401, 403:
            return .authenticationRejected(detail: detail)
        case 402:
            return .paymentRequired(detail: detail)
        case 408, 504:
            return .timedOut(detail: detail)
        case 429:
            return .rateLimited(detail: detail)
        case 400, 404, 405, 422:
            return .requestRejected(statusCode: statusCode, detail: detail)
        case 500...599:
            return .networkUnavailable(detail: detail)
        default:
            return .requestFailed(detail: detail)
        }
    }

    private static func chatAPIError(message: String) -> AIClientError {
        let normalized = message.lowercased()
        let detail = DiagnosticEvent.redact(String(message.prefix(800)))
        if normalized.contains("unauthorized")
            || normalized.contains("authentication")
            || normalized.contains("api key")
            || normalized.contains("invalid api key") {
            return .authenticationRejected(detail: detail)
        }
        if normalized.contains("rate limit") || normalized.contains("too many requests") {
            return .rateLimited(detail: detail)
        }
        if normalized.contains("insufficient")
            || normalized.contains("balance")
            || normalized.contains("quota")
            || normalized.contains("payment")
            || normalized.contains("billing")
            || normalized.contains("402") {
            return .paymentRequired(detail: detail)
        }
        return .requestRejected(statusCode: 400, detail: detail)
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
        guard let first = vectors.first else { throw AIEmbeddingError.emptyResponse }
        return first
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let resolvedModel = model?.nilIfBlank ?? configuration.embeddingModel
        let query = EmbeddingsQuery(input: .stringList(inputs), model: resolvedModel)
        do {
            let result = try await client.embeddings(query: query)
            let vectors = result.data
                .sorted { $0.index < $1.index }
                .map { $0.embedding.map(Float.init) }
            guard vectors.count == inputs.count, vectors.allSatisfy({ !$0.isEmpty }) else {
                throw AIEmbeddingError.emptyResponse
            }
            return vectors
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // SDK 对 OpenAI-compatible Provider 的非标准错误体可能只暴露 DecodingError。
            // 原始错误写入日志用于反馈诊断，产品层统一收到可执行的向量化错误。
            AppLog.ai.error("Embedding request failed: \(error.localizedDescription, privacy: .public)")
            throw Self.embeddingError(from: error)
        }
    }

    private static func embeddingError(from error: Error) -> AIEmbeddingError {
        if let error = error as? AIEmbeddingError {
            return error
        }
        if let error = error as? APIErrorResponse {
            return embeddingAPIError(message: error.error.message)
        }
        if let error = error as? OpenAIError {
            switch error {
            case .emptyData:
                return .emptyResponse
            case .statusError(_, let statusCode):
                return embeddingHTTPError(statusCode: statusCode)
            }
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? .timedOut : .networkUnavailable
        }
        if error is DecodingError {
            return .invalidResponse
        }
        return .requestFailed
    }

    private static func embeddingHTTPError(statusCode: Int) -> AIEmbeddingError {
        switch statusCode {
        case 401, 403: return .authenticationRejected
        case 408, 504: return .timedOut
        case 429: return .rateLimited
        case 400, 404, 405, 422: return .modelRequestRejected
        case 500...599: return .networkUnavailable
        default: return .requestFailed
        }
    }

    private static func embeddingAPIError(message: String) -> AIEmbeddingError {
        let normalized = message.lowercased()
        if normalized.contains("unauthorized")
            || normalized.contains("authentication")
            || normalized.contains("api key") {
            return .authenticationRejected
        }
        if normalized.contains("rate limit") || normalized.contains("too many requests") {
            return .rateLimited
        }
        return .modelRequestRejected
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

    private func makeChatQuery(
        request: AIChatRequest,
        resolvedModel: String,
        stream: Bool
    ) -> ChatQuery {
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
                messages.append(.assistant(.init(content: .textContent(message.content))))
            }
        }
        if request.images.isEmpty {
            messages.append(.user(.init(content: .string(request.userPrompt))))
        } else {
            var parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = [
                .text(.init(text: request.userPrompt))
            ]
            for image in request.images {
                let dataURL = "data:\(image.contentType);base64,\(image.data.base64EncodedString())"
                parts.append(.image(.init(imageUrl: .init(url: dataURL, detail: .auto))))
            }
            messages.append(.user(.init(content: .contentParts(parts))))
        }

        return ChatQuery(
            messages: messages,
            model: resolvedModel,
            maxCompletionTokens: request.parameters.maxCompletionTokens > 0 ? request.parameters.maxCompletionTokens : nil,
            responseFormat: request.responseFormat == .jsonObject ? .jsonObject : nil,
            temperature: request.parameters.temperature,
            topP: request.parameters.topP,
            stream: stream
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
