//
//  LocalAIGenerationPolicy.swift
//  Starcat
//
//  本地生成的参数与生命周期约束。与 MLX 张量无关，便于用无模型测试验证超时和取消。
//  不修改用户参数；硬内存预算仍由 LocalAIMemoryPolicy 和 runtime 负责。
//

import Foundation

/// 生成默认值按模型区分，不能用远程 API 的通用 128K 输出预算。
enum LocalAIGenerationPolicy {
    /// 仓库聊天独立于摘要、RAG 等既有任务预算。输入必须给回答留下固定 4K 空间。
    static let chatContextTokens = 32_768
    static let chatOutputTokens = 4_096
    static let chatInputTokens = chatContextTokens - chatOutputTokens

    /// 在请求快照上应用，不覆盖用户持久化的模型参数或其它本地任务。
    static func repositoryChatParameters(_ parameters: AIModelParameters) -> AIModelParameters {
        var result = parameters
        result.contextWindowTokens = chatContextTokens
        result.maxCompletionTokens = min(max(parameters.maxCompletionTokens, 1), chatOutputTokens)
        return result
    }

    /// 长度上限是截断，不是完整回答。统一在客户端拦截，所有业务入口都能收到失败。
    static func validateCompletion(_ response: AIChatResponse) throws {
        if response.finishReason == "length" { throw AIClientError.responseTruncated }
        if response.finishReason == "cancelled" { throw CancellationError() }
        guard response.finishReason == "stop" else { throw AIClientError.emptyResponse }
    }

    /// 日志中的稳定终止类别，不记录 SDK 错误可能携带的路径或输入内容。
    static func finishReason(for error: Error) -> String {
        switch error {
        case LocalAIError.repetitiveOutput: return "repetition"
        case AIClientError.timedOut: return "timeout"
        case AIClientError.responseTruncated: return "length"
        case is CancellationError: return "cancelled"
        default: return "error"
        }
    }

    static func defaultParameters(model: String, capability: AIModelCapability) -> AIModelParameters {
        guard capability == .chat else { return .defaults(for: capability) }
        let isMiniCPM = model == LocalAIModelCatalog.llmMiniCPM5.displayName
        let isQwen3Instruct = model == LocalAIModelCatalog.llmQwen3_4B.displayName
        let isQwen35 = model.hasPrefix("Qwen3.5 ")
        let outputTokens = 4_096
        // 上游建议：MiniCPM5 1.0 / 0.95 / min_p=0；Qwen3 thinking 0.6 / 0.95 / top_k=20。
        // https://huggingface.co/openbmb/MiniCPM5-2B-MLX#quickstart
        // https://huggingface.co/Qwen/Qwen3-1.7B#best-practices
        // Qwen3 Instruct 2507 用 0.7 / 0.8；Qwen3.5 通用 thinking 用 1.0 / 0.95。
        // https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507#best-practices
        // https://huggingface.co/Qwen/Qwen3.5-4B#best-practices
        return AIModelParameters(
            temperature: isMiniCPM || isQwen35 ? 1.0 : (isQwen3Instruct ? 0.7 : 0.6),
            topP: isQwen3Instruct ? 0.8 : 0.95,
            topK: isMiniCPM ? 0 : 20,
            maxCompletionTokens: outputTokens,
            // RAG 用窗口减输出预算分配输入；不能宣称可用 12K 输入、运行时却只接受 8K。
            contextWindowTokens: LocalAIMemoryPolicy.inputTokens + outputTokens,
            timeoutSeconds: 300,
            streamEnabled: true)
    }

    /// 超时覆盖排队、加载和生成。结构化任务组保证取消后等待 GPU 工作退出，
    /// 不以“提前返回”绕过 runtime 的准入/内存锁；父任务取消同样向两条子任务传播。
    static func withTimeout<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = seconds.isFinite ? max(seconds, 0.001) : 300
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AIClientError.timedOut(detail: "Local AI generation exceeded \(timeout) seconds")
            }
            defer { group.cancelAll() }
            // 上面始终加入两个子任务；首个完成后取消另一条，并等待取消清理结束。
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }
}
