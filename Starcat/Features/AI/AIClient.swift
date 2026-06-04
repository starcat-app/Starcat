//
//  AIClient.swift
//  Starcat
//
//  AI 客户端抽象层。
//
//  模块职责：
//  - 把业务层需要的 chat / embeddings 能力抽成 Starcat 自己的协议。
//  - 屏蔽 MacPaw/OpenAI 的具体类型，后续如果切换 swift-ai-sdk、Ollama 原生 SDK
//    或 Apple 本地模型，只需要替换 adapter，不让 ViewModel 跟着改。
//
//  关键约束：
//  - API Key 由调用方从加密存储读取后注入，本层不直接读取 KeychainManager。
//  - Base URL 使用 OpenAI-compatible 约定，必须能拆成 scheme / host / port / basePath。
//  - Embedding 返回 Float，便于直接写入 SQLite BLOB。
//

import Foundation

/// AI 调用配置。
struct AIClientConfiguration: Equatable, Sendable {
    var providerID: String = "legacy-openAICompatible"
    var provider: AIServiceProvider = .openAICompatible
    var apiKey: String
    var baseURL: String
    var chatModel: String
    var embeddingModel: String
    var timeoutInterval: TimeInterval = 300
}

/// Chat 返回格式要求。
enum AIChatResponseFormat: Equatable, Sendable {
    case text
    case jsonObject
}

/// 参数化 Chat 请求。
struct AIChatRequest: Equatable, Sendable {
    var systemPrompt: String
    var userPrompt: String
    var model: String
    var parameters: AIModelParameters
    var responseFormat: AIChatResponseFormat = .text
}

/// 非流式 Chat 响应。
struct AIChatResponse: Equatable, Sendable {
    var content: String
    var model: String
    var finishReason: String?
}

/// 流式 Chat 事件。
enum AIChatStreamEvent: Equatable, Sendable {
    case delta(String)
    case completed(AIChatResponse)
}

/// 业务层依赖的最小 AI 能力集。
protocol AIClientProtocol: Sendable {
    func chat(request: AIChatRequest) async throws -> AIChatResponse
    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error>
    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String
    func embedding(input: String, model: String?) async throws -> [Float]
    func embeddings(inputs: [String], model: String?) async throws -> [[Float]]
    func listModels() async throws -> [AIModelDescriptor]
    func testConnection() async throws
}

/// AI 客户端错误。
enum AIClientError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case emptyResponse
    case responseTruncated
    case modelListRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先填写 API Key。"
        case .invalidBaseURL(let url):
            return "Base URL 无效：\(url)"
        case .emptyResponse:
            return "AI 服务返回了空内容。"
        case .responseTruncated:
            return "AI 服务输出达到最大 token 限制，请调大最大 token 或缩短输入内容。"
        case .modelListRequestFailed(let message):
            return "获取模型列表失败：\(message)"
        }
    }
}
