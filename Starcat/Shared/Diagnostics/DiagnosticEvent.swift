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

    /// 事件在诊断体系中的用途。
    ///
    /// `context` 只作为导出包上下文，不点亮全局故障；`issue` 仅用于用户无法通过
    /// 设置、重试、重新登录等方式自行恢复的程序或本地数据故障。
    enum Visibility: String, Codable, Sendable {
        case context
        case issue
    }

    /// ISO8601 时间戳，使用 String 而不是 Date，方便用户直接打开 JSONL 阅读。
    var timestamp: String
    var level: Level
    var visibility: Visibility
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
        visibility: Visibility = .context,
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
        self.visibility = visibility
        self.category = category
        self.operation = operation
        self.message = Self.sanitize(message, maxLength: 1_024)
        self.service = service
        self.statusCode = statusCode
        self.errorCode = errorCode
        self.underlying = underlying.map { Self.sanitize($0, maxLength: 4_096) }
        self.context = context.reduce(into: [:]) { partial, pair in
            partial[pair.key] = Self.sanitize(pair.value, maxLength: 512)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case level
        case visibility
        case category
        case operation
        case message
        case service
        case statusCode
        case errorCode
        case underlying
        case context
    }

    /// 老版本 JSONL 没有 `visibility`。升级后默认把这些历史记录当作上下文，
    /// 避免旧的网络、配置与取消事件继续点亮状态面板；原始事件仍保留在导出包中。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        level = try container.decode(Level.self, forKey: .level)
        visibility = try container.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .context
        category = try container.decode(String.self, forKey: .category)
        operation = try container.decode(String.self, forKey: .operation)
        message = try container.decode(String.self, forKey: .message)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        underlying = try container.decodeIfPresent(String.self, forKey: .underlying)
        context = try container.decodeIfPresent([String: String].self, forKey: .context) ?? [:]
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
        output = output.replacingOccurrences(
            of: #"(?i)(api\s*key)\s+[A-Za-z0-9._~+/=-]{6,}"#,
            with: "$1 <redacted>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|sk-(?:proj-)?[A-Za-z0-9_-]{8,})\b"#,
            with: "<redacted-secret>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?:file://)?/Users/[^/\s]+"#,
            with: "/Users/<redacted>",
            options: .regularExpression
        )
        return output
    }

    /// 把任意错误收敛成可导出的最小摘要。GRDB 错误可能在描述中附带 SQL 参数，
    /// 因此只保留类型、domain 与 code；其它错误统一脱敏并截断。
    static func summarize(_ error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        if typeName.contains("GRDB.DatabaseError") {
            let nsError = error as NSError
            return "\(typeName) domain=\(nsError.domain) code=\(nsError.code)"
        }
        return sanitize("\(typeName): \(error.localizedDescription)", maxLength: 4_096)
    }

    private static func sanitize(_ value: String, maxLength: Int) -> String {
        let redacted = redact(value)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength)) + "…<truncated>"
    }
}
