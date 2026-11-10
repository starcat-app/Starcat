//
//  AnthropicClient.swift
//  Starcat
//
//  Anthropic Messages API 的最小 `URLSession` 客户端。
//
//  为什么不复用 `OpenAIClient` / MacPaw SDK：
//  - Completions 与 Messages 是两套协议；把 `/anthropic` 改写成 `/chat/completions` 必失败。
//  - 不新增 SPM，避免把 Anthropic 官方 SDK 的类型泄漏进业务层。
//
//  关键约束：
//  - 同时发 `x-api-key` 与 `Authorization: Bearer`，兼容官方与多数中转。
//  - `listModels` 遇到 401/403 直接失败，禁止回落内置目录。
//  - Messages 404/405 时再试 `/anthropic` 候选，测通后把 Base URL 写回。
//  - embedding 入口必须拒绝，设置页任务门禁漏拦时也不能发出无效请求。
//  - 取消必须落到 URLSession：外层 Task.cancel() 取消 `bytes(for:)` / `data(for:)`。
//

import Foundation

/// Anthropic Messages API adapter。
struct AnthropicClient: AIClientProtocol {
    private let configuration: AIClientConfiguration
    private let endpoint: AnthropicEndpoint
    private let session: URLSession
    private let usageRecorder: any AIUsageRecording
    private let apiKey: String
    private let probeState: ProbeState

    /// 测连接后实际打通的 Base URL；可能比用户输入多了一段 `/anthropic`。
    var probedBaseURL: String { probeState.resolvedBaseURL }

    /// 结构体客户端不能在 async listModels 里 mutating self，用引用记下改写后的 URL。
    private final class ProbeState: @unchecked Sendable {
        var resolvedBaseURL: String
        init(_ resolvedBaseURL: String) {
            self.resolvedBaseURL = resolvedBaseURL
        }
    }

    private enum ProbeResult {
        case ready(models: [AIModelDescriptor])
        case wrongPath(listedModels: [AIModelDescriptor])
    }

    init(
        configuration: AIClientConfiguration,
        session: URLSession? = nil,
        usageRecorder: any AIUsageRecording = AIUsageRecorder.shared
    ) throws {
        let trimmedKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AIClientError.missingAPIKey }

        self.configuration = configuration
        self.endpoint = try AnthropicEndpoint.normalize(baseURL: configuration.baseURL)
        self.session = session ?? Self.makeSession(timeoutInterval: configuration.timeoutInterval)
        self.usageRecorder = usageRecorder
        self.apiKey = trimmedKey
        self.probeState = ProbeState(self.endpoint.normalizedBaseURL)
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        let startedAt = Date().timeIntervalSince1970
        let resolved = resolvedRequest(request)
        do {
            let urlRequest = try makeMessagesRequest(resolved, stream: false)
            let (data, http) = try await send(urlRequest)
            try throwIfHTTPError(http, data: data)
            let response = try AnthropicMessagesCodec.decodeMessageResponse(data, fallbackModel: resolved.model)
            await recordChatUsage(
                startedAt: startedAt,
                model: response.model,
                context: request.usageContext,
                usage: response.usage,
                status: .succeeded
            )
            return response
        } catch is CancellationError {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .cancelled,
                error: CancellationError()
            )
            throw CancellationError()
        } catch let error as URLError where Self.isCancellation(error) {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .cancelled,
                error: CancellationError()
            )
            throw CancellationError()
        } catch let error as AIClientError {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .failed,
                error: error
            )
            throw error
        } catch {
            let mapped = mapTransportError(error)
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .failed,
                error: mapped
            )
            throw mapped
        }
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await runStream(request: request, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        let resolvedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? configuration.chatModel
        let response = try await chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: resolvedModel,
            parameters: .summaryDefault
        ))
        return response.content
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        _ = (input, model)
        throw AIClientError.requestRejected(
            statusCode: 400,
            detail: "Anthropic does not provide embeddings"
        )
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        _ = (inputs, model)
        throw AIClientError.requestRejected(
            statusCode: 400,
            detail: "Anthropic does not provide embeddings"
        )
    }

    func listModels() async throws -> [AIModelDescriptor] {
        switch try await probe(endpoint) {
        case .ready(let models):
            probeState.resolvedBaseURL = endpoint.normalizedBaseURL
            return models
        case .wrongPath(let listed):
            guard let alt = try endpoint.anthropicPathCandidate() else {
                throw AIClientError.requestRejected(
                    statusCode: 404,
                    detail: "Anthropic messages endpoint not found"
                )
            }
            switch try await probe(alt) {
            case .ready(let models):
                probeState.resolvedBaseURL = alt.normalizedBaseURL
                return listed.isEmpty ? models : listed
            case .wrongPath:
                throw AIClientError.requestRejected(
                    statusCode: 404,
                    detail: "Anthropic messages endpoint not found"
                )
            }
        }
    }

    func testConnection() async throws {
        _ = try await listModels()
    }

    // MARK: - Stream

    private func runStream(
        request: AIChatRequest,
        continuation: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
    ) async {
        let startedAt = Date().timeIntervalSince1970
        let resolved = resolvedRequest(request)
        do {
            try Task.checkCancellation()
            let urlRequest = try makeMessagesRequest(resolved, stream: true)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw AIClientError.requestFailed(detail: "missing HTTP response")
            }
            if !(200..<300).contains(http.statusCode) {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                }
                throw mapHTTPError(statusCode: http.statusCode, data: body)
            }

            var parser = AnthropicSSEStreamParser(fallbackModel: resolved.model)
            var lastUsage: AIChatUsage?
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let events = try parser.ingest(line: line)
                for event in events {
                    if case .usage(let usage) = event {
                        lastUsage = usage
                    }
                    continuation.yield(event)
                }
            }
            let finished = try parser.finish()
            for event in finished.events {
                if case .completed = event { continue }
                continuation.yield(event)
            }
            await recordChatUsage(
                startedAt: startedAt,
                model: finished.response.model,
                context: request.usageContext,
                usage: finished.response.usage ?? lastUsage,
                status: .succeeded
            )
            continuation.yield(.completed(finished.response))
            continuation.finish()
        } catch is CancellationError {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .cancelled,
                error: CancellationError()
            )
            continuation.finish(throwing: CancellationError())
        } catch let error as URLError where Self.isCancellation(error) {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .cancelled,
                error: CancellationError()
            )
            continuation.finish(throwing: CancellationError())
        } catch let error as AIClientError {
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .failed,
                error: error
            )
            continuation.finish(throwing: error)
        } catch {
            let mapped = mapTransportError(error)
            await recordChatUsage(
                startedAt: startedAt,
                model: resolved.model,
                context: request.usageContext,
                status: .failed,
                error: mapped
            )
            continuation.finish(throwing: mapped)
        }
    }

    // MARK: - HTTP

    private func makeMessagesRequest(
        _ request: AIChatRequest,
        stream: Bool,
        endpoint: AnthropicEndpoint? = nil
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: (endpoint ?? self.endpoint).messagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try AnthropicMessagesCodec.requestJSONData(request, stream: stream)
        applyHeaders(&urlRequest)
        return urlRequest
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.timeoutInterval = configuration.timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AnthropicMessagesCodec.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await DiagnosticHTTP.data(for: request, using: session, service: "anthropic")
            guard let http = response as? HTTPURLResponse else {
                throw AIClientError.requestFailed(detail: "missing HTTP response")
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where Self.isCancellation(error) {
            throw CancellationError()
        } catch {
            throw mapTransportError(error)
        }
    }

    private func throwIfHTTPError(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> AIClientError {
        let detail = AnthropicMessagesCodec.errorMessage(from: data)
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

    private func mapTransportError(_ error: Error) -> AIClientError {
        if let error = error as? AIClientError {
            return error
        }
        if let error = error as? URLError {
            let detail = DiagnosticEvent.redact("URLError \(error.code.rawValue): \(error.localizedDescription)")
            return error.code == .timedOut ? .timedOut(detail: detail) : .networkUnavailable(detail: detail)
        }
        return .requestFailed(detail: DiagnosticEvent.redact(String(describing: error)))
    }

    private func decodeModels(_ data: Data) throws -> [AIModelDescriptor] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else {
            throw AIClientError.modelListRequestFailed("Anthropic models response missing data")
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return AIModelDescriptor(
                providerID: configuration.providerID,
                name: id,
                ownedBy: row["owned_by"] as? String,
                capability: AIModelCapability.inferred(from: id),
                isEnabled: true,
                isCustom: false
            )
        }
    }

    /// 中转没有可用 `/models` 时，用最小 messages 验 Key。失败则测试失败。
    ///
    /// 不走 `chat()` / 完整 decode：正式 chat 会把 `max_tokens` 当截断、把空 text
    /// 当 emptyResponse。DeepSeek thinking 模型常把 8 tokens 全花在 thinking 上，
    /// HTTP 200 且不是 error envelope 就已经证明 Key 和 Messages 端点可用。
    private func probe(_ endpoint: AnthropicEndpoint) async throws -> ProbeResult {
        var request = URLRequest(url: endpoint.modelsURL)
        request.httpMethod = "GET"
        applyHeaders(&request)

        let (data, http) = try await send(request)
        switch http.statusCode {
        case 200..<300:
            let listed = (try? decodeModels(data)) ?? []
            do {
                try await ping(endpoint)
                return .ready(models: listed.isEmpty
                    ? AnthropicModelCatalog.bundledDescriptors(providerID: configuration.providerID)
                    : listed)
            } catch {
                if Self.isMissingMessagesPath(error) {
                    return .wrongPath(listedModels: listed)
                }
                throw error
            }
        case 401, 403:
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        case 404, 405:
            do {
                try await ping(endpoint)
                return .ready(models: AnthropicModelCatalog.bundledDescriptors(providerID: configuration.providerID))
            } catch {
                if Self.isMissingMessagesPath(error) {
                    return .wrongPath(listedModels: [])
                }
                throw error
            }
        default:
            throw mapHTTPError(statusCode: http.statusCode, data: data)
        }
    }

    private func ping(_ endpoint: AnthropicEndpoint) async throws {
        let pingRequest = resolvedRequest(AIChatRequest(
            systemPrompt: "",
            userPrompt: "ping",
            model: configuration.chatModel,
            parameters: AIModelParameters(
                temperature: 0,
                topP: 1,
                topK: 0,
                maxCompletionTokens: 8,
                timeoutSeconds: configuration.timeoutInterval,
                streamEnabled: false
            )
        ))
        let urlRequest = try makeMessagesRequest(pingRequest, stream: false, endpoint: endpoint)
        let (data, http) = try await send(urlRequest)
        try throwIfHTTPError(http, data: data)
        try AnthropicMessagesCodec.throwIfErrorEnvelope(data)
    }

    private static func isMissingMessagesPath(_ error: Error) -> Bool {
        guard let error = error as? AIClientError else { return false }
        if case .requestRejected(let statusCode, _) = error, statusCode == 404 || statusCode == 405 {
            return true
        }
        return false
    }

    private func resolvedRequest(_ request: AIChatRequest) -> AIChatRequest {
        var copy = request
        if copy.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.model = configuration.chatModel
        }
        return copy
    }

    private func recordChatUsage(
        startedAt: Double,
        model: String,
        context: AIUsageContext?,
        usage: AIChatUsage? = nil,
        status: AIUsageStatus,
        error: Error? = nil
    ) async {
        await usageRecorder.record(AIUsageEventFactory.make(
            startedAt: startedAt,
            configuration: configuration,
            usageContext: context,
            model: model,
            operation: .chat,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            totalTokens: usage?.totalTokens,
            cachedInputTokens: usage?.cachedTokens,
            reasoningOutputTokens: usage?.reasoningTokens,
            itemCount: 1,
            status: status,
            error: error
        ))
    }

    private static func makeSession(timeoutInterval: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        return URLSession(configuration: configuration)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
