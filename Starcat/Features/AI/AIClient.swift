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
    /// 业务归因必须在创建客户端时确定，底层 adapter 不猜调用方属于哪个功能。
    var usageContext: AIUsageContext = .unknown
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
    /// 同一长寿命客户端可服务 RAG 的 planning / answer / title 等阶段，请求级归因优先于
    /// client configuration；普通业务不传时继续使用客户端默认值。
    var usageContext: AIUsageContext? = nil
    /// 关闭推理模型的 thinking / reasoning。GitHub 评论这类短回复不需要思考链。
    ///
    /// `true` 时 Chat 请求带 `reasoning_effort=none`，中间件再补 Qwen / vLLM 的
    /// `enable_thinking=false`。默认 false，避免改掉对话、RAG 里需要思考的路径。
    var disableThinking: Bool = false
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

/// 统一远程 Provider 与 Local MLX 的推理流，避免业务 UI 依赖某一家模型的输出协议。
///
/// 原生 `reasoning_content` 优先；部分兼容服务只把推理包在正文开头的 `<think>` 标签里，
/// Local MLX 的部分模板还会把开始标签预填进 prompt，生成流只返回思考正文与结束标签。
/// 状态机只在流起点和 reasoning/answer 边界处理 framing，并支持标签跨 chunk，正文开始后
/// 完全透传，因此不会误吞回答中用于讲解协议或代码的普通 `<think>` 文本。
struct AIStreamReasoningNormalizer {
    private enum Source: Equatable {
        case probing
        case tagged
        case native
        case content
    }

    private let openingTag: String
    private let closingTag: String
    private var source: Source
    private var probe = ""
    private var taggedTail = ""
    private var shouldProbeLeadingOpeningTag: Bool
    private var shouldStripLeadingClosingTags = false
    private var contentBoundaryProbe = ""
    private var emittedReasoning = false

    init(
        openingTag: String = "<think>",
        closingTag: String = "</think>",
        startsInsideReasoning: Bool = false
    ) {
        self.openingTag = openingTag
        self.closingTag = closingTag
        source = startsInsideReasoning ? .tagged : .probing
        // 部分本地模板已在 prompt 尾部预填 `<think>`，但模型仍可能重复生成它。
        // 只探测 reasoning 流的第一个有效字符，避免误吞思考正文里的普通标签文本。
        shouldProbeLeadingOpeningTag = startsInsideReasoning
    }

    mutating func ingest(content: String?, nativeReasoning: String?) -> [AIChatStreamEvent] {
        var events: [AIChatStreamEvent] = []

        if let nativeReasoning, !nativeReasoning.isEmpty, source != .tagged {
            source = .native
            emittedReasoning = true
            events.append(.reasoningDelta(nativeReasoning))
        }
        guard let content, !content.isEmpty else { return events }

        switch source {
        case .native:
            events.append(.delta(content))
        case .content:
            if let answer = ingestContentBoundary(content), !answer.isEmpty {
                events.append(.delta(answer))
            }
        case .probing:
            probe += content
            let leadingWhitespace = probe.prefix { $0.isWhitespace }
            let candidate = String(probe.dropFirst(leadingWhitespace.count))
            if candidate.count < openingTag.count {
                // 开始标签被拆开时先保留，不要把 `<thi` 误当成正文输出。
                guard openingTag.hasPrefix(candidate) else {
                    source = .content
                    events.append(.delta(probe))
                    probe = ""
                    return events
                }
                return events
            }
            if candidate.hasPrefix(openingTag) {
                source = .tagged
                probe = ""
                events.append(contentsOf: ingestTagged(String(candidate.dropFirst(openingTag.count))))
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
            let candidate = taggedTail.trimmingCharacters(in: .whitespacesAndNewlines)
            // 生成恰好截断在 framing 中间时不把 `<thi` 当 reasoning 展示。
            if !candidate.isEmpty
                && !(shouldProbeLeadingOpeningTag && openingTag.hasPrefix(candidate))
            {
                emittedReasoning = true
                events.append(.reasoningDelta(taggedTail))
            }
        } else if source == .content, let answer = finishContentBoundaryProbe() {
            events.append(.delta(answer))
        }
        if emittedReasoning {
            events.append(.reasoningCompleted)
        }
        return events
    }

    private mutating func ingestTagged(_ text: String) -> [AIChatStreamEvent] {
        var buffered = taggedTail + text
        taggedTail = ""

        if shouldProbeLeadingOpeningTag {
            let leadingWhitespace = buffered.prefix { $0.isWhitespace }
            let candidate = String(buffered.dropFirst(leadingWhitespace.count))
            if candidate.isEmpty
                || (candidate.count < openingTag.count && openingTag.hasPrefix(candidate))
            {
                taggedTail = buffered
                return []
            }
            shouldProbeLeadingOpeningTag = false
            if candidate.hasPrefix(openingTag) {
                buffered = String(candidate.dropFirst(openingTag.count))
            }
        }

        if let closingRange = buffered.range(of: closingTag) {
            let reasoning = String(buffered[..<closingRange.lowerBound])
            let answer = String(buffered[closingRange.upperBound...])
            source = .content
            shouldStripLeadingClosingTags = true
            var events: [AIChatStreamEvent] = []
            if !reasoning.isEmpty {
                emittedReasoning = true
                events.append(.reasoningDelta(reasoning))
            }
            if let answer = ingestContentBoundary(answer), !answer.isEmpty {
                events.append(.delta(answer))
            }
            return events
        }

        let heldSuffix = longestClosingTagPrefix(in: buffered)
        let emittedCount = buffered.count - heldSuffix.count
        let reasoning = String(buffered.prefix(emittedCount))
        taggedTail = heldSuffix
        guard !reasoning.isEmpty else { return [] }
        emittedReasoning = true
        return [.reasoningDelta(reasoning)]
    }

    /// reasoning 结束后只在正文边界吞掉重复 `</think>`；正文一旦开始即完全透传。
    private mutating func ingestContentBoundary(_ text: String) -> String? {
        guard shouldStripLeadingClosingTags else { return text }
        contentBoundaryProbe += text

        while true {
            let leadingWhitespace = contentBoundaryProbe.prefix { $0.isWhitespace }
            let candidate = String(contentBoundaryProbe.dropFirst(leadingWhitespace.count))
            guard !candidate.isEmpty else { return nil }
            if candidate.count < closingTag.count, closingTag.hasPrefix(candidate) {
                return nil
            }
            if candidate.hasPrefix(closingTag) {
                contentBoundaryProbe = String(
                    candidate.dropFirst(closingTag.count).drop(while: { $0.isWhitespace }))
                continue
            }

            shouldStripLeadingClosingTags = false
            let answer = contentBoundaryProbe
            contentBoundaryProbe = ""
            return answer
        }
    }

    private mutating func finishContentBoundaryProbe() -> String? {
        guard !contentBoundaryProbe.isEmpty else { return nil }
        let candidate = contentBoundaryProbe.trimmingCharacters(in: .whitespacesAndNewlines)
        contentBoundaryProbe = ""
        if candidate.isEmpty || closingTag.hasPrefix(candidate) { return nil }
        return candidate
    }

    private func longestClosingTagPrefix(in text: String) -> String {
        for length in stride(from: min(closingTag.count - 1, text.count), through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if closingTag.hasPrefix(suffix) { return suffix }
        }
        return ""
    }
}

/// 只需要文本生成的业务契约。
///
/// RAG 的 Planner / Generator 不应被迫依赖 Embedding、模型列表和连接测试。把这两项
/// chat 能力单独抽出来后，本机 CLI 可以只在 RAG 装配边界接入，不会自动变成 README
/// 翻译、笔记或其它普通 AI 功能的全局 Provider。
protocol AITextGenerating: Sendable {
    func chat(request: AIChatRequest) async throws -> AIChatResponse
    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error>
}

/// API Provider 客户端的完整能力集。
protocol AIClientProtocol: AITextGenerating {
    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String
    func embedding(input: String, model: String?) async throws -> [Float]
    func embeddings(inputs: [String], model: String?) async throws -> [[Float]]
    func listModels() async throws -> [AIModelDescriptor]
    func testConnection() async throws
}

/// Starcat 统一 AI 客户端工厂。
///
/// `.localAI` 走进程内 MLX（`LocalMLXClient`，无 Key / 无网络），`.anthropic` 走
/// Messages API（`AnthropicClient`），其余 provider 走 OpenAI-compatible HTTP
///（`OpenAIClient`）。各业务的 makeClient 工厂只应调用本函数，不要再按 provider
/// 自行分支；本地模型未安装时由 `LocalMLXClient` 在解析阶段抛
/// `LocalAIError.modelNotInstalled`。
enum AIClientFactory {
    static func make(configuration: AIClientConfiguration) throws -> any AIClientProtocol {
        if configuration.provider == .localAI {
            return LocalMLXClient.makeClient(configuration: configuration)
        }
        if configuration.provider == .anthropic {
            return try AnthropicClient(configuration: configuration)
        }
        return try OpenAIClient(configuration: configuration)
    }
}

/// AI 客户端错误。
///
/// chat / completions 路径会把 MacPaw SDK 的 `OpenAIError.statusError` 等原始 dump
/// 收成这里的枚举，避免 UI 直接展示 `NSHTTPURLResponse` 调试字符串。
/// 带 `detail` 的 case 把结构化诊断留给日志与「可展开详情」；`errorDescription` 始终是
/// 按 HTTP 状态码区分的用户可读短文案。
enum AIClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidBaseURL(String)
    case invalidChatHistory(String)
    case emptyResponse
    case responseTruncated
    case modelListRequestFailed(String)
    /// Provider 拒绝凭据（HTTP 401 / 403 或等价鉴权文案）。
    case authenticationRejected(detail: String)
    /// Provider 限流（HTTP 429）。
    case rateLimited(detail: String)
    /// 需要付费 / 余额不足（HTTP 402）。
    case paymentRequired(detail: String)
    /// Provider 拒绝本次请求（HTTP 400 / 404 / 422 等）；`detail` 供展开诊断。
    case requestRejected(statusCode: Int, detail: String)
    /// 网络不可达或 5xx。
    case networkUnavailable(detail: String)
    /// 请求超时。
    case timedOut(detail: String)
    /// 其它已归类失败；`detail` 供展开诊断。
    case requestFailed(detail: String)

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
        case .authenticationRejected:
            return String.l10n("ai.client.error.authenticationRejected.modelsSettings")
        case .rateLimited:
            return String.l10n("ai.client.error.rateLimited")
        case .paymentRequired:
            return String.l10n("ai.client.error.paymentRequired")
        case .requestRejected(let statusCode, _):
            switch statusCode {
            case 400:
                return String.l10n("ai.client.error.badRequest")
            case 404, 405:
                return String.l10n("ai.client.error.notFound")
            case 422:
                return String.l10n("ai.client.error.unprocessable")
            default:
                return String(format: String.l10n("ai.client.error.requestRejectedFormat"), statusCode)
            }
        case .networkUnavailable:
            return String.l10n("ai.client.error.networkUnavailable")
        case .timedOut:
            return String.l10n("ai.client.error.timedOut")
        case .requestFailed:
            return String.l10n("ai.client.error.requestFailed")
        }
    }

    /// 可展开详情 / 诊断日志用的结构化细节；配置类错误通常为 nil。
    var diagnosticDetail: String? {
        switch self {
        case .invalidChatHistory(let message):
            return Self.nonEmpty(message)
        case .modelListRequestFailed(let message):
            return Self.nonEmpty(message)
        case .authenticationRejected(let detail),
             .rateLimited(let detail),
             .paymentRequired(let detail),
             .networkUnavailable(let detail),
             .timedOut(let detail),
             .requestFailed(let detail):
            return Self.nonEmpty(detail)
        case .requestRejected(_, let detail):
            return Self.nonEmpty(detail)
        case .missingAPIKey, .invalidBaseURL, .emptyResponse, .responseTruncated:
            return nil
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 向量化配置与请求错误。
///
/// 配置类错误可在调用 Provider 前确定，便于设置页和 RAG 工作台直接引导用户修正；
/// 请求类错误只能由真实 embedding 请求确认，不能误报成笔记内容或数据格式问题。
enum AIEmbeddingError: Error, LocalizedError, Equatable, Sendable {
    case missingProvider
    case providerUnavailable
    case missingAPIKey
    case missingModel
    case incompatibleModel(String)
    case authenticationRejected
    case rateLimited
    case modelRequestRejected
    case networkUnavailable
    case timedOut
    case invalidResponse
    case emptyResponse
    case requestFailed

    var isConfigurationIssue: Bool {
        switch self {
        case .missingProvider, .providerUnavailable, .missingAPIKey, .missingModel, .incompatibleModel:
            return true
        case .authenticationRejected, .rateLimited, .modelRequestRejected, .networkUnavailable,
             .timedOut, .invalidResponse, .emptyResponse, .requestFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String.l10n("ai.embedding.error.missingProvider.modelsSettings")
        case .providerUnavailable:
            return String.l10n("ai.embedding.error.providerUnavailable.modelsSettings")
        case .missingAPIKey:
            return String.l10n("ai.embedding.error.missingAPIKey.modelsSettings")
        case .missingModel:
            return String.l10n("ai.embedding.error.missingModel.modelsSettings")
        case .incompatibleModel(let model):
            return String(format: String.l10n("ai.embedding.error.incompatibleModelFormat.modelsSettings"), model)
        case .authenticationRejected:
            return String.l10n("ai.embedding.error.authenticationRejected.modelsSettings")
        case .rateLimited:
            return String.l10n("ai.embedding.error.rateLimited")
        case .modelRequestRejected:
            return String.l10n("ai.embedding.error.modelRequestRejected")
        case .networkUnavailable:
            return String.l10n("ai.embedding.error.networkUnavailable")
        case .timedOut:
            return String.l10n("ai.embedding.error.timedOut")
        case .invalidResponse:
            return String.l10n("ai.embedding.error.invalidResponse")
        case .emptyResponse:
            return String.l10n("ai.embedding.error.emptyResponse")
        case .requestFailed:
            return String.l10n("ai.embedding.error.requestFailed")
        }
    }
}
