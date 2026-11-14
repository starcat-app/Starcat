//
//  LocalAILogEvent.swift
//  Starcat
//
//  本地 AI 运行流水的数据契约。日志正文按产品要求固定英文，不进入 String Catalog。
//  只接收阶段、统计和模型身份；禁止传入 prompt、文档、回答、思考原文或凭据。
//

import Foundation

/// 一次请求的稳定身份；TaskLocal 会随结构化子任务传播，不借用可变的设置选择。
struct LocalAILogContext: Sendable {
    @TaskLocal static var current: LocalAILogContext?
    @TaskLocal static var store: LocalAILogStore = .shared

    let requestID: String
    let modelID: String
    let modelName: String
    let revision: String
    let feature: String

    init(
        modelID explicitModelID: String? = nil,
        modelName: String,
        feature: String,
        directory: URL? = nil
    ) {
        let entry = LocalAIModelCatalog.entries.first { $0.displayName == modelName }
        requestID = UUID().uuidString
        // Laya 刻意不进入通用模型目录，因此允许专用 runtime 提供稳定 ID；日志筛选
        // 不能退化为 displayName，否则模型改名后历史记录会与当前入口断开。
        modelID = explicitModelID ?? entry?.id ?? modelName
        self.modelName = modelName
        revision = directory?.lastPathComponent.components(separatedBy: "@").dropFirst().joined(separator: "@") ?? ""
        self.feature = feature
    }

    /// 后台回收也有模型身份，但不得错误继承首次请求的 requestID。
    static func model(directory: URL, feature: String) -> LocalAILogContext {
        let entry = LocalAIModelCatalog.entries.first {
            directory.lastPathComponent.hasPrefix($0.id + "@")
        }
        return LocalAILogContext(modelName: entry?.displayName ?? "Unknown model", feature: feature, directory: directory)
    }
}

/// 可落盘的单行结构化日志；序号由日志队列分配，保证同一时间戳下仍有确定顺序。
struct LocalAILogEvent: Codable, Identifiable, Equatable, Sendable {
    enum Level: String, CaseIterable, Codable, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    var sequence: UInt64 = 0
    let id: UUID
    let timestamp: String
    let level: Level
    let requestID: String?
    let modelID: String?
    let modelName: String?
    let revision: String?
    let feature: String?
    let stage: String
    let message: String
    let fields: [String: String]

    init(
        level: Level = .info, stage: String, message: String,
        context: LocalAILogContext? = nil, fields: [String: String] = [:], date: Date = Date()
    ) {
        id = UUID()
        timestamp = date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        self.level = level
        requestID = context?.requestID
        modelID = context.map { Self.safe($0.modelID) }
        modelName = context.map { Self.safe($0.modelName) }
        revision = context.map { Self.safe($0.revision) }
        feature = context.map { Self.safe($0.feature) }
        self.stage = Self.safe(stage)
        self.message = Self.safe(message, limit: 512)
        // 字段数量及单字段长度均有界；换行转义后不会伪造下一条日志。
        self.fields = fields.sorted { $0.key < $1.key }.prefix(16).reduce(into: [:]) {
            $0[Self.safe($1.key, limit: 64)] = Self.safe($1.value)
        }
    }

    var line: String {
        let identity = [modelName, feature, requestID.map { String($0.prefix(8)) }].compactMap { $0 }.joined(separator: " | ")
        let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(timestamp) [\(level.rawValue)] [\(identity)] \(stage): \(message)\(details.isEmpty ? "" : " " + details)"
    }

    /// 不使用 localizedDescription：系统错误可能带文档内容，而且日志必须始终是英文。
    static func errorFields(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return ["reason": LocalAIGenerationPolicy.finishReason(for: error),
                "errorType": String(reflecting: type(of: error)), "errorCode": String(nsError.code)]
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func safe(_ text: String, limit: Int = 256) -> String {
        String(DiagnosticEvent.redact(text).prefix(limit))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

/// 运行时统一入口：同步提交有界事件，绝不在推理线程等待磁盘或 UI。
enum LocalAILog {
    static func record(
        _ stage: String, _ message: String, level: LocalAILogEvent.Level = .info,
        context: LocalAILogContext? = LocalAILogContext.current, fields: [String: String] = [:]
    ) {
        // 只在当前真实业务操作中关联请求身份与阶段；独立运行日志的内容、采集和清理不变。
        DiagnosticContext.current?.capture(DiagnosticEvent(
            level: .info, category: "localAI", operation: "request", message: "Local AI request stage",
            requestID: context?.requestID, phase: stage,
            fields: fields.reduce(into: [String: DiagnosticValue]()) { result, field in
                if let number = Int(field.value) { result[field.key] = .integer(number) }
            }
        ))
        LocalAILogContext.store.record(.init(level: level, stage: stage, message: message, context: context, fields: fields))
    }
}
