//
//  AIDebugLogger.swift
//  Starcat
//
//  AI 调试日志格式化器。
//
//  模块职责：
//  - 在 DEBUG 构建中把 OpenAI-compatible provider 的 HTTP 原始响应打印到 Xcode Console；
//  - 把 MacPaw/OpenAI SDK 已解码的 `ChatResult` 重新编码为 JSON，便于对比
//    “服务商返回格式”和“SDK 解码后字段”；
//  - 对输出做分块，避免 Xcode Console / OSLog 单行过长时被截断。
//
//  关键约束：
//  - 本文件只在 DEBUG 下输出完整 payload；Release 构建不会打印 AI 响应正文；
//  - 日志可能包含 repo README 相关生成结果，只用于本机排查，不写入数据库；
//  - API Key 不会被打印：这里仅处理 response，不打印 Authorization header。
//

import Foundation
import OpenAI

/// AI 调试日志门面。
///
/// 为什么同时使用 `print` 和 `AppLog.ai`：
/// - `print` 能在 Xcode Debug Console 里直接看到完整分块正文，适合排查 LM Studio
///   返回 JSON 这种临时问题；
/// - `AppLog.ai` 只记录短摘要，便于 Console.app 按 subsystem/category 过滤。
enum AIDebugLogger {

    private static let chunkSize = 3_000

    /// 打印 chat completion HTTP 原始响应。
    ///
    /// 这里打印的是 MacPaw/OpenAI SDK 解码前的 body，是确认 LM Studio 实际返回格式的
    /// 第一手证据。只由 `AIHTTPDiagnosticURLProtocol` 在 DEBUG + 主动开启开关时调用。
    static func dumpRawChatHTTPResponse(
        id: String,
        url: URL?,
        statusCode: Int?,
        headers: [AnyHashable: Any],
        body: Data
    ) {
        #if DEBUG
        let bodyText = String(data: body, encoding: .utf8) ?? body.base64EncodedString()
        let headerText = headers
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
        let title = "Starcat AI HTTP Response [\(id)]"
        let metadata = """
        url: \(url?.absoluteString ?? "<nil>")
        status: \(statusCode.map(String.init) ?? "<nil>")
        headers:
        \(headerText)
        bodyBytes: \(body.count)
        """

        AppLog.ai.notice("AI HTTP response received id=\(id, privacy: .public) status=\(statusCode ?? -1, privacy: .public) bytes=\(body.count, privacy: .public)")
        dumpBlock(title: title, metadata: metadata, body: bodyText)
        #endif
    }

    /// 打印 SDK 解码后的 `ChatResult`。
    ///
    /// 当 Starcat 报“AI 服务返回了空内容”时，本方法能显示 MacPaw/OpenAI 已经把哪些
    /// 字段解出来：`content` 是否真为空、`reasoning/refusal/tool_calls/finish_reason`
    /// 是否有值，以及 `usage` 是否正常。
    static func dumpDecodedChatResult(_ result: ChatResult, reason: String) {
        #if DEBUG
        let body = prettyJSON(result) ?? String(describing: result)
        let metadata = chatSummary(result, reason: reason)
        AppLog.ai.notice("AI chat decoded result reason=\(reason, privacy: .public) choices=\(result.choices.count, privacy: .public) model=\(result.model, privacy: .public)")
        dumpBlock(title: "Starcat AI SDK Decoded ChatResult", metadata: metadata, body: body)
        #endif
    }

    /// 打印 chat 请求摘要，不包含完整 prompt。
    ///
    /// Prompt 里包含 README 内容，通常很长；排查“空内容”时只需要模型、Base URL 和
    /// prompt 长度即可确认调用的是哪一路配置。
    static func logChatRequest(baseURL: String, model: String, systemPromptLength: Int, userPromptLength: Int) {
        #if DEBUG
        AppLog.ai.notice("AI chat request baseURL=\(baseURL, privacy: .public) model=\(model, privacy: .public) systemChars=\(systemPromptLength, privacy: .public) userChars=\(userPromptLength, privacy: .public)")
        #endif
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func chatSummary(_ result: ChatResult, reason: String) -> String {
        let choiceLines: String = result.choices.map { choice -> String in
            let message = choice.message
            return """
            choice[\(choice.index)] role=\(message.role) finishReason=\(choice.finishReason) contentChars=\(message.content?.count ?? 0) refusalChars=\(message.refusal?.count ?? 0) reasoningChars=\(message.reasoning?.count ?? 0) toolCalls=\(message.toolCalls?.count ?? 0)
            """
        }.joined(separator: "\n")

        let usage = result.usage.map {
            "usage: prompt=\($0.promptTokens) completion=\($0.completionTokens) total=\($0.totalTokens)"
        } ?? "usage: <nil>"

        return """
        reason: \(reason)
        id: \(result.id)
        model: \(result.model)
        object: \(result.object)
        choices: \(result.choices.count)
        \(usage)
        \(choiceLines)
        """
    }

    private static func dumpBlock(title: String, metadata: String, body: String) {
        print("===== \(title) BEGIN =====")
        print(metadata)
        print("----- body begin -----")

        if body.isEmpty {
            print("<empty body>")
        } else {
            var index = body.startIndex
            var chunkIndex = 1
            while index < body.endIndex {
                let end = body.index(index, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
                print("----- chunk \(chunkIndex) -----")
                print(String(body[index..<end]))
                index = end
                chunkIndex += 1
            }
        }

        print("----- body end -----")
        print("===== \(title) END =====")
    }
}
