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

/// 多轮对话用的单条消息。
///
/// assistant tool-call 与对应 tool-result 必须保持独立 role 和 call id，provider 才能在
/// 下一轮继续推理；把它们拼进文本会破坏 OpenAI-compatible 的消息关联协议。
struct AIChatMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String = ""
    var reasoningContent: String?
    var toolCalls: [AIChatToolCall] = []
    var toolCallID: String?
}

/// OpenAI-compatible function tool 的模型可见声明。
struct AIChatTool: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: AgentJSONSchema
    var strict: Bool = false
}

/// 模型生成的一次 function tool-call。
///
/// `arguments` 保留 provider 返回的原始 JSON 字符串。模型输出不可信，必须由 Agent
/// Runtime 解码并按工具 schema 校验，AI adapter 不能提前丢失无效输入的审计证据。
struct AIChatToolCall: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}

/// 流式响应中一段尚未组装完成的 tool-call。
struct AIChatToolCallDelta: Equatable, Sendable {
    var choiceIndex: Int = 0
    var index: Int
    var id: String?
    var name: String?
    var argumentsFragment: String?
}

enum AIChatToolChoice: Equatable, Sendable {
    case none
    case auto
    case required
    case tool(String)
}

/// 单次模型调用的 token 使用量。
struct AIChatUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
}

/// 当前轮用户消息附带的图片。仅保存在请求内，不进入历史、日志或数据库。
struct AIChatImageInput: Equatable, Sendable {
    var data: Data
    var contentType: String
}

/// 参数化 Chat 请求。
struct AIChatRequest: Equatable, Sendable {
    var systemPrompt: String
    var userPrompt: String
    /// 历史轮次（按时间顺序排列，最后一条早于 `userPrompt`）。
    ///
    /// 为什么单独拆出来而不是把整段历史拼进 `userPrompt`：
    /// - 走原生 messages 数组让模型识别 role，质量明显优于"all-in-one user 字符串"；
    /// - 流式响应和非流式响应都能复用同一份历史，不需要在两条路径上重复字符串拼接；
    /// - 摘要、标签等单轮功能传空数组，Agent Runtime 则传完整 tool 消息链。
    var history: [AIChatMessage] = []
    /// OpenAI-compatible vision content parts。非视觉模型由服务端返回明确能力错误。
    var images: [AIChatImageInput] = []
    var model: String
    var parameters: AIModelParameters
    var responseFormat: AIChatResponseFormat = .text
    var tools: [AIChatTool] = []
    var toolChoice: AIChatToolChoice = .auto
    var parallelToolCalls: Bool = false
    var metadata: [String: String] = [:]
    var includeUsage: Bool = false
}

/// 非流式 Chat 响应。
struct AIChatResponse: Equatable, Sendable {
    var content: String
    var reasoningContent: String? = nil
    var toolCalls: [AIChatToolCall] = []
    var usage: AIChatUsage? = nil
    var model: String
    var finishReason: String?
}

/// 流式 Chat 事件。
enum AIChatStreamEvent: Equatable, Sendable {
    /// Provider 明确拆出的推理 token；来自 `reasoning_content` / `reasoning`，或正文起始的 `<think>` 块。
    case reasoningDelta(String)
    case reasoningCompleted
    case delta(String)
    case toolCallDelta(AIChatToolCallDelta)
    case usage(AIChatUsage)
    case completed(AIChatResponse)
}

/// 统一 OpenAI-compatible 推理流，避免业务 UI 依赖某一家 provider 的字段名称。
///
/// 原生 `reasoning_content` 优先；部分兼容服务只把推理包在正文开头的 `<think>` 标签里，
/// 因此只识别开头标签，并正确处理标签被拆到多个 SSE chunk 的情况。这样不会误吞回答
/// 中用于讲解协议或代码的普通 `<think>` 文本。
struct AIStreamReasoningNormalizer {
    private enum Source: Equatable {
        case probing
        case tagged
        case native
        case content
    }

    private static let openingTag = "<think>"
    private static let closingTag = "</think>"

    private var source: Source = .probing
    private var probe = ""
    private var taggedTail = ""
    private var emittedReasoning = false

    mutating func ingest(content: String?, nativeReasoning: String?) -> [AIChatStreamEvent] {
        var events: [AIChatStreamEvent] = []

        if let nativeReasoning, !nativeReasoning.isEmpty, source != .tagged {
            source = .native
            emittedReasoning = true
            events.append(.reasoningDelta(nativeReasoning))
        }
        guard let content, !content.isEmpty else { return events }

        switch source {
        case .native, .content:
            events.append(.delta(content))
        case .probing:
            probe += content
            let leadingWhitespace = probe.prefix { $0.isWhitespace }
            let candidate = String(probe.dropFirst(leadingWhitespace.count))
            if candidate.count < Self.openingTag.count {
                // 开始标签被拆开时先保留，不要把 `<thi` 误当成正文输出。
                guard Self.openingTag.hasPrefix(candidate) else {
                    source = .content
                    events.append(.delta(probe))
                    probe = ""
                    return events
                }
                return events
            }
            if candidate.hasPrefix(Self.openingTag) {
                source = .tagged
                probe = ""
                events.append(contentsOf: ingestTagged(String(candidate.dropFirst(Self.openingTag.count))))
            } else {
                source = .content
                events.append(.delta(probe))
                probe = ""
            }
        case .tagged:
            events.append(contentsOf: ingestTagged(content))
        }

        return events
    }

    mutating func finish() -> [AIChatStreamEvent] {
        var events: [AIChatStreamEvent] = []
        if source == .probing, !probe.isEmpty {
            events.append(.delta(probe))
        } else if source == .tagged, !taggedTail.isEmpty {
            emittedReasoning = true
            events.append(.reasoningDelta(taggedTail))
        }
        if emittedReasoning {
            events.append(.reasoningCompleted)
        }
        return events
    }

    private mutating func ingestTagged(_ text: String) -> [AIChatStreamEvent] {
        let buffered = taggedTail + text
        if let closingRange = buffered.range(of: Self.closingTag) {
            let reasoning = String(buffered[..<closingRange.lowerBound])
            let answer = String(buffered[closingRange.upperBound...])
            taggedTail = ""
            source = .content
            var events: [AIChatStreamEvent] = []
            if !reasoning.isEmpty {
                emittedReasoning = true
                events.append(.reasoningDelta(reasoning))
            }
            if !answer.isEmpty {
                events.append(.delta(answer))
            }
            return events
        }

        let heldSuffix = Self.longestClosingTagPrefix(in: buffered)
        let emittedCount = buffered.count - heldSuffix.count
        let reasoning = String(buffered.prefix(emittedCount))
        taggedTail = heldSuffix
        guard !reasoning.isEmpty else { return [] }
        emittedReasoning = true
        return [.reasoningDelta(reasoning)]
    }

    private static func longestClosingTagPrefix(in text: String) -> String {
        for length in stride(from: min(closingTag.count - 1, text.count), through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if closingTag.hasPrefix(suffix) { return suffix }
        }
        return ""
    }
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
    case invalidChatHistory(String)
    case emptyResponse
    case responseTruncated
    case modelListRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String.l10n("ai.client.error.missingAPIKey")
        case .invalidBaseURL(let url):
            return String(format: String.l10n("ai.client.error.invalidBaseURLFormat"), url)
        case .invalidChatHistory(let message):
            return String(format: String.l10n("ai.client.error.invalidChatHistoryFormat"), message)
        case .emptyResponse:
            return String.l10n("ai.client.error.emptyResponse")
        case .responseTruncated:
            return String.l10n("ai.client.error.responseTruncated")
        case .modelListRequestFailed(let message):
            return String(format: String.l10n("ai.client.error.modelListRequestFailedFormat"), message)
        }
    }
}
