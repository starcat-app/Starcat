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
import CryptoKit

/// 诊断安全字段只接受标量，不允许把响应、设置或业务对象整体序列化。
enum DiagnosticValue: Codable, Sendable, Equatable {
    case string(String), integer(Int), decimal(Double), boolean(Bool)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .boolean(bool) }
        else if let int = try? value.decode(Int.self) { self = .integer(int) }
        else if let double = try? value.decode(Double.self) { self = .decimal(double) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .integer(let int): try value.encode(int)
        case .decimal(let double): try value.encode(double.isFinite ? double : 0)
        case .boolean(let bool): try value.encode(bool)
        }
    }
}

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
    /// `context` 保留可恢复故障和取消证据，不点亮全局故障；
    /// `issue` 仅表达需要开发者协助的提醒，与证据采集范围独立。
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
    var schemaVersion: Int = 2
    var eventID: String = UUID().uuidString
    var sequence: UInt64?
    var sessionID: String? = DiagnosticContext.sessionID
    var environmentID: String? = DiagnosticContext.sessionID
    var operationID: String?
    var parentOperationID: String?
    var requestID: String?
    var serverTraceID: String?
    var phase: String?
    var outcome: Outcome?
    var durationMs: Double?
    var impact: Impact = .none
    /// 聚合行表示本条新增次数，不能把累计次数再次相加。
    var occurrenceCount: Int = 1
    var firstSeen: String?
    var lastSeen: String?
    var fields: [String: DiagnosticValue] = [:]

    enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled, partial, skipped
    }

    enum Impact: String, Codable, Sendable {
        case none, degraded, blocked, dataRisk
    }

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
        context: [String: String] = [:],
        operationID: String? = nil,
        parentOperationID: String? = nil,
        requestID: String? = nil,
        serverTraceID: String? = nil,
        phase: String? = nil,
        outcome: Outcome? = nil,
        durationMs: Double? = nil,
        impact: Impact = .none,
        fields: [String: DiagnosticValue] = [:]
    ) {
        self.timestamp = ISO8601DateFormatter.shared.string(from: timestamp)
        self.level = level
        self.visibility = visibility
        self.category = Self.sanitize(category, maxLength: 80)
        self.operation = Self.sanitize(operation, maxLength: 160)
        self.message = Self.sanitize(message, maxLength: 1_024)
        self.service = service.map { Self.sanitize($0, maxLength: 80) }
        self.statusCode = statusCode
        self.errorCode = errorCode.map { Self.sanitize($0, maxLength: 128) }
        self.underlying = underlying.map { Self.sanitize($0, maxLength: 4_096) }
        self.context = context.sorted { $0.key < $1.key }.prefix(32).reduce(into: [:]) { partial, pair in
            guard Self.isSafeKey(pair.key) else { return }
            let sensitive = ["repo", "login", "user", "path", "url", "endpoint", "account"]
                .contains { pair.key.localizedCaseInsensitiveContains($0) }
            partial[String(pair.key.prefix(80))] = sensitive
                ? Self.anonymousReference(pair.value) : Self.sanitize(pair.value, maxLength: 256)
        }
        self.operationID = operationID ?? DiagnosticContext.current?.id
        self.parentOperationID = parentOperationID ?? DiagnosticContext.current?.parentID
        self.requestID = requestID
        self.serverTraceID = serverTraceID.flatMap(Self.safeTrace)
        self.phase = phase
        self.outcome = outcome
        self.durationMs = durationMs
        self.impact = impact
        self.fields = fields.sorted { $0.key < $1.key }.prefix(48).reduce(into: [:]) { result, item in
            guard Self.isSafeKey(item.key) else { return }
            if case .string(let text) = item.value {
                // 只接收代码控制的短枚举值；正文、路径和 URL 不属于安全字段。
                guard text.range(of: #"^[A-Za-z0-9_.:<>\-]{0,128}$"#, options: .regularExpression) != nil else { return }
                result[item.key] = .string(Self.redact(text))
            } else {
                result[item.key] = item.value
            }
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
        case schemaVersion, eventID, sequence, sessionID, environmentID
        case operationID, parentOperationID, requestID, serverTraceID
        case phase, outcome, durationMs, impact, occurrenceCount, firstSeen, lastSeen, fields
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
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID) ?? ""
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
        parentOperationID = try container.decodeIfPresent(String.self, forKey: .parentOperationID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        serverTraceID = try container.decodeIfPresent(String.self, forKey: .serverTraceID)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        outcome = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        impact = try container.decodeIfPresent(Impact.self, forKey: .impact) ?? .none
        occurrenceCount = try container.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1
        firstSeen = try container.decodeIfPresent(String.self, forKey: .firstSeen)
        lastSeen = try container.decodeIfPresent(String.self, forKey: .lastSeen)
        fields = try container.decodeIfPresent([String: DiagnosticValue].self, forKey: .fields) ?? [:]
    }

    /// 同一会话内可关联，不输出身份，也不提供跨用户稳定跟踪标识。
    static func anonymousReference(_ text: String) -> String {
        let digest = SHA256.hash(data: Data((DiagnosticContext.sessionID + text).utf8))
        return "ref:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func safeTrace(_ text: String) -> String? {
        text.range(of: #"^[A-Za-z0-9_.:\-]{1,128}$"#, options: .regularExpression) != nil ? text : nil
    }

    private static func isSafeKey(_ key: String) -> Bool {
        guard key.count <= 80 else { return false }
        return !["token", "secret", "password", "cookie", "authorization", "prompt", "content",
                 "body", "response", "apikey", "api_key", "licensekey", "note", "query"]
            .contains { key.localizedCaseInsensitiveContains($0) }
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
            of: #"(?i)(api[_-]?key|token|license[_-]?key|cookie|password)\s*[:=]\s*[^\s,;]+"#,
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
            of: #"(?:file://)?/Users/[^\n\"<>]+"#,
            with: "/Users/<redacted>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: #"https?://[^\s<>"]+"#, with: "<url>", options: .regularExpression)
        output = output.replacingOccurrences(of: #"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        return output
    }

    /// 把任意错误收敛成可导出的最小摘要。GRDB 错误可能在描述中附带 SQL 参数，
    /// 因此只保留类型、domain 与 code；其它错误统一脱敏并截断。
    ///
    /// `DecodingError` 的 `localizedDescription` 在中文系统上会收成「未能读取数据，
    /// 因为它的格式不正确」，丢掉 codingPath。诊断必须留下 path + debugDescription，
    /// 才能区分「未知 provider」和真正的坏 JSON。
    static func summarize(_ error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        if typeName.contains("GRDB.DatabaseError") {
            let nsError = error as NSError
            return "\(typeName) domain=\(nsError.domain) code=\(nsError.code)"
        }
        if let decoding = error as? DecodingError {
            return sanitize(summarizeDecodingError(decoding), maxLength: 4_096)
        }
        let nsError = error as NSError
        return sanitize("\(typeName) domain=\(nsError.domain) code=\(nsError.code)", maxLength: 512)
    }

    private static func summarizeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Swift.DecodingError.typeMismatch(\(type), path=\(codingPath(context)) \(context.debugDescription))"
        case .valueNotFound(let type, let context):
            return "Swift.DecodingError.valueNotFound(\(type), path=\(codingPath(context)) \(context.debugDescription))"
        case .keyNotFound(let key, let context):
            return "Swift.DecodingError.keyNotFound(\(key.stringValue), path=\(codingPath(context)) \(context.debugDescription))"
        case .dataCorrupted(let context):
            return "Swift.DecodingError.dataCorrupted(path=\(codingPath(context)) \(context.debugDescription))"
        @unknown default:
            return "Swift.DecodingError: \(error)"
        }
    }

    private static func codingPath(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map { key -> String in
            if let index = key.intValue {
                return "[\(index)]"
            }
            return key.stringValue
        }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }

    private static func sanitize(_ value: String, maxLength: Int) -> String {
        let redacted = redact(value)
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(maxLength)) + "…<truncated>"
    }
}
