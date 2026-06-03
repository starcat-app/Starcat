//
//  OpenAIClient.swift
//  Starcat
//
//  MacPaw/OpenAI adapter。
//
//  技术选择：
//  - 底层使用 MacPaw/OpenAI 的 `OpenAIProtocol`，原因见
//    `docs/详细设计/12-AI库选型调研.md`：协议化、可 mock、支持 OpenAI-compatible
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
        let trimmedKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AIClientError.missingAPIKey }

        let sdkConfig = try Self.makeSDKConfiguration(from: configuration, apiKey: trimmedKey)
        self.configuration = configuration
        self.client = OpenAI(configuration: sdkConfig)
    }

    /// 生产代码注入真实 MacPaw client；单元测试可用 mock OpenAIProtocol 走这里。
    init(configuration: AIClientConfiguration, client: OpenAIProtocol) {
        self.configuration = configuration
        self.client = client
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        let resolvedModel = model?.nilIfBlank ?? configuration.chatModel
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent(systemPrompt))),
                .user(.init(content: .string(userPrompt)))
            ],
            model: resolvedModel
        )

        let result = try await client.chats(query: query)
        guard let content = result.choices.first?.message.content?.nilIfBlank else {
            throw AIClientError.emptyResponse
        }
        return content
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

    /// 连接测试使用 embeddings 而不是 chat：
    /// - token / Base URL / model 三项都能被验证；
    /// - 输入极短，成本比让模型生成文本更低；
    /// - embedding 是语义搜索的硬依赖，设置页优先验证它更贴近第一版功能闭环。
    func testConnection() async throws {
        _ = try await embedding(input: "starcat connection test", model: configuration.embeddingModel)
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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
