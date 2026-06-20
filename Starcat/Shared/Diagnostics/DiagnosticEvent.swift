//
//  DiagnosticEvent.swift
//  Starcat
//
//  用户可导出的诊断事件模型。
//
//  模块职责：
//  - 给关键错误与少量生命周期事件提供结构化 JSONL 记录；
//  - 保持字段克制，避免把 OSLog 变成高频业务埋点；
//  - 明确区分「给用户看的友好文案」与「给开发者定位问题的诊断细节」。
//

import Foundation

/// 诊断事件。
///
/// 这些事件会写入用户本机 Application Support 下的 JSONL 文件，并在用户主动导出
/// 调试日志时打包。它不是 analytics，也不会上传；只保存定位问题所需的最小上下文。
struct DiagnosticEvent: Codable, Sendable, Equatable {

    enum Level: String, Codable, Sendable {
        case debug
        case info
        case warning
        case error
        case critical
    }

    /// ISO8601 时间戳，使用 String 而不是 Date，方便用户直接打开 JSONL 阅读。
    var timestamp: String
    var level: Level
    var category: String
    var operation: String
    var message: String
    var service: String?
    var statusCode: Int?
    var errorCode: String?
    var underlying: String?
    var context: [String: String]

    init(
        timestamp: Date = Date(),
        level: Level,
        category: String,
        operation: String,
        message: String,
        service: String? = nil,
        statusCode: Int? = nil,
        errorCode: String? = nil,
        underlying: String? = nil,
        context: [String: String] = [:]
    ) {
        self.timestamp = ISO8601DateFormatter.shared.string(from: timestamp)
        self.level = level
        self.category = category
        self.operation = operation
        self.message = Self.redact(message)
        self.service = service
        self.statusCode = statusCode
        self.errorCode = errorCode
        self.underlying = underlying.map(Self.redact)
        self.context = context.reduce(into: [:]) { partial, pair in
            partial[pair.key] = Self.redact(pair.value)
        }
    }

    /// 最小脱敏：API Key / Bearer token / GitHub token / Authorization 这类常见形态。
    ///
    /// 这里故意不做复杂 NLP 识别，避免误删正常诊断信息；高风险原始 payload 本身就不应
    /// 传入 DiagnosticEvent。调用方必须只传短消息、状态码、服务名、repo fullName 等。
    static func redact(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(
            of: #"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer <redacted>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token)\s*[:=]\s*[A-Za-z0-9._~+/=-]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        return output
    }
}
