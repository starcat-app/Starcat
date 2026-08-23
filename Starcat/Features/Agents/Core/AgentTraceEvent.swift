//
//  AgentTraceEvent.swift
//  Starcat
//
//  Agent Runtime 原生执行过程的可持久化产品投影。
//
//  这里保留不同 Runtime 的事件类型、顺序和父子关系，但不保存 JSON-RPC 原始帧、
//  环境变量或隐藏思维链。Adapter 只应写入用户可见的 reasoning summary 与经过裁剪的
//  输入输出，避免调试协议数据变成新的隐私存储面。
//

import Foundation

enum AgentTraceKind: String, Codable, Hashable, Sendable {
    case lifecycle
    case message
    case plan
    case todo
    case request
    case reasoningSummary
    case commentary
    case tool
    case command
    case fileChange
    case webSearch
    case mcpTool
    case approval
    case warning
    case retry
    case error
    case compaction
    case unknown
}

enum AgentTraceStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case cancelled
    case skipped
}

enum AgentTraceDetailFormat: String, Codable, Hashable, Sendable {
    case text
    case markdown
    case code
    case json
    case error
}

/// 展开区使用带语义的字段，而不是把所有 Provider 输出拼成一段不可读日志。
struct AgentTraceDetail: Codable, Hashable, Sendable {
    let label: String
    let value: String
    let format: AgentTraceDetailFormat

    init(label: String, value: String, format: AgentTraceDetailFormat = .text) {
        self.label = label
        self.value = AgentTraceText.sanitized(value)
        self.format = format
    }
}

/// Runtime-native 事件的公共无损投影。`id` 在同一生命周期内保持稳定，started/delta/
/// completed 通过 upsert 更新同一行；`sequence` 只决定首次出现位置，防止流式更新让列表跳动。
struct AgentTraceEvent: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let runID: UUID
    let backend: AgentRuntimeBackend
    let providerEventID: String?
    let parentID: String?
    let sequence: Int
    let kind: AgentTraceKind
    let status: AgentTraceStatus
    let title: String
    let summary: String?
    let details: [AgentTraceDetail]
    let attempt: Int?
    let durationMilliseconds: Int?
    /// 单步 usage 只在 Provider 能与该事件可靠关联时写入；nil 不是 0，而是未提供。
    let usage: AgentUsage?
    let startedAt: Date
    let completedAt: Date?

    init(
        id: String,
        runID: UUID,
        backend: AgentRuntimeBackend,
        providerEventID: String? = nil,
        parentID: String? = nil,
        sequence: Int,
        kind: AgentTraceKind,
        status: AgentTraceStatus,
        title: String,
        summary: String? = nil,
        details: [AgentTraceDetail] = [],
        attempt: Int? = nil,
        durationMilliseconds: Int? = nil,
        usage: AgentUsage? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.backend = backend
        self.providerEventID = providerEventID
        self.parentID = parentID
        self.sequence = sequence
        self.kind = kind
        self.status = status
        self.title = AgentTraceText.sanitized(title, limit: 500)
        self.summary = summary.map { AgentTraceText.sanitized($0, limit: 2_000) }
        self.details = details
        self.attempt = attempt
        self.durationMilliseconds = durationMilliseconds
        self.usage = usage
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    var hasDetails: Bool {
        // duration 已固定显示在主行右侧，不能单独触发 disclosure；否则展开区没有新增信息。
        !details.isEmpty || attempt != nil
    }
}

enum AgentTraceText {
    /// Trace 是可恢复的产品数据，不是无限增长的调试日志。保留首尾能同时看到请求上下文
    /// 与终态错误，NUL 则必须移除，否则会破坏日志、复制和后续序列化工具。
    static func sanitized(_ value: String, limit: Int = 12_000) -> String {
        let cleaned = value.replacingOccurrences(of: "\0", with: "")
        guard cleaned.count > limit else { return cleaned }
        let headCount = max(1, limit * 2 / 3)
        let tailCount = max(1, limit - headCount)
        return String(cleaned.prefix(headCount))
            + "\n\n… output truncated by Starcat …\n\n"
            + String(cleaned.suffix(tailCount))
    }
}
