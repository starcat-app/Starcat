//
//  DiagnosticArchiveBuilder.swift
//  Starcat
//
//  后台生成一致诊断包。输入为安全值快照，不持有 UI、业务库或网络客户端。
//

import Foundation
import CryptoKit

/// 用户提供的线索可选，限制长度且仅随本次主动导出保存。
struct DiagnosticExportOptions: Sendable {
    var description: String = ""
    var module: String = ""
    var occurredAt: Date?
    var operationID: String?
    var since: Date? = Date().addingTimeInterval(-86400)
}

/// 每项采集单独报告状态，未采集、空结果与失败不能互换。
struct DiagnosticCollectorResult: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case collected, notApplicable, notCollected, permissionDenied, failed, timedOut, truncated
    }
    let name: String
    let status: Status
    let detail: String?
}

/// 可验证文件清单；哈希覆盖报告、事件、状态和附件，manifest 自身不递归引用。
struct DiagnosticManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    let schemaVersion: Int
    let exportID: String
    let createdAt: String
    let cutoffSequence: UInt64
    let snapshotSessionID: String
    let requestedSince: String?
    let actualFirstEvent: String?
    let actualLastEvent: String?
    let damagedLines: Int
    let historicalEvents: Int
    let health: [String: Int]
    let collectors: [DiagnosticCollectorResult]
    let files: [File]
}

/// 单一后台工作单元；文件命名固定，不接受附件提供的路径。
enum DiagnosticArchiveBuilder {
    struct Input: Sendable {
        let snapshot: DiagnosticSnapshot
        let settings: [String: String]
        let options: DiagnosticExportOptions
        let sessions: Data?
        let localAI: [DiagnosticEvent]
        let collectors: [DiagnosticCollectorResult]
        let system: Data?
    }

    /// 返回的目录由调用方负责清理，便于压缩失败时仍保留基础文本。
    static func writePayload(input: Input, to root: URL, exportID: String,
                             eventByteLimit: Int = 48 * 1024 * 1024, eventCountLimit: Int = 50_000) throws -> DiagnosticManifest {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        var damaged = 0
        let decoder = JSONDecoder()
        let all = input.snapshot.text.split(separator: "\n").compactMap { line -> DiagnosticEvent? in
            guard let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)) else { damaged += 1; return nil }
            return safeExport(event)
        }
        var related = Set(input.options.operationID.map { [$0] } ?? [])
        for _ in 0..<8 {
            let children = all.filter { $0.parentOperationID.map(related.contains) ?? false }.compactMap(\.operationID)
            let previous = related.count
            related.formUnion(children)
            if related.count == previous { break }
        }
        let candidates = all.filter { event in
            if !related.isEmpty { return event.operationID.map(related.contains) ?? false }
            return input.options.since.map { event.date >= $0 } ?? true
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return ($0.sequence ?? 0) < ($1.sequence ?? 0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 与解析 Skill 的 48MB 单文件 / 64MB 总量预算一致，超限保留最近证据并明确标记。
        var selected: [(DiagnosticEvent, String)] = []
        var eventBytes = 0
        for event in candidates.reversed() {
            let data = try encoder.encode(event)
            guard selected.count < eventCountLimit, eventBytes + data.count + 1 <= eventByteLimit else { break }
            selected.append((event, String(decoding: data, as: UTF8.self)))
            eventBytes += data.count + 1
        }
        let events = selected.reversed().map { $0.0 }
        let text = selected.reversed().map { $0.1 }.joined(separator: "\n")
        var payloads: [String: Data] = ["events.jsonl": Data((text.isEmpty ? "" : text + "\n").utf8)]
        payloads["environment.json"] = try json(DiagnosticEnvironment.current())
        payloads["sessions.json"] = input.sessions ?? Data("[]".utf8)
        payloads["state/settings.json"] = try json(input.settings)

        let modules = ["startup", "database", "auth", "keychain", "license", "subscription", "network", "sync", "followGraph",
                       "readme", "ai", "localAI", "dailyRadar", "linuxdo", "recommend", "weekly", "rag",
                       "agent", "mcp", "cli", "extension", "codeGraph", "runtime", "fileAccess"]
        var collectors = input.collectors
        if events.count < candidates.count {
            collectors.append(.init(name: "eventWindow", status: .truncated,
                detail: "Recent events retained within export byte and event budgets"))
        }
        // 模块状态取已有证据；没有活动时明确标记未采集，绝不主动探测网络或数据库。
        for module in modules {
            let evidence = events.filter { $0.category == module || $0.service == module || $0.operation == module }
            let state = DiagnosticModuleState(module: module, capturedAt: input.snapshot.capturedAt,
                source: "historicalObservations", currentState: "unknown",
                observed: Array(evidence.suffix(8)), activeOperations: [])
            payloads["state/\(module).json"] = try json(state)
            collectors.append(.init(name: module, status: evidence.isEmpty ? .notCollected : .collected,
                                    detail: evidence.isEmpty ? "No retained module evidence" : nil))
        }
        let severeEvents = events.filter(\.isSevereFailure)
        let requestIDs = Set(severeEvents.flatMap { event -> [String] in
            [event.requestID].compactMap { $0 } + event.breadcrumbs.compactMap(\.requestID)
        })
        let operationIDs = Set(severeEvents.flatMap { event -> [String] in
            [event.operationID].compactMap { $0 } + event.breadcrumbs.compactMap(\.operationID)
        })
        let correlatedLocalAI = input.localAI.filter {
            $0.operationID.map(operationIDs.contains) == true || $0.requestID.map(requestIDs.contains) == true
        }
        if !input.localAI.isEmpty && correlatedLocalAI.isEmpty {
            collectors.append(.init(name: "localAICorrelation", status: .notCollected,
                detail: "No reliable operation or request correlation in selected failures"))
        }
        if !correlatedLocalAI.isEmpty {
            payloads["attachments/local-ai/events.jsonl"] = Data(try correlatedLocalAI.map {
                String(decoding: try encoder.encode(safeExport($0)), as: UTF8.self)
            }.joined(separator: "\n").appending("\n").utf8)
        }
        if let system = input.system { payloads["attachments/system-diagnostics/summary.json"] = system }
        if !input.options.description.isEmpty || !input.options.module.isEmpty || input.options.occurredAt != nil {
            var feedback = ["description": String(DiagnosticEvent.redact(input.options.description, includeURLs: true).prefix(2000)),
                            "module": String(DiagnosticEvent.redact(input.options.module, includeURLs: true).prefix(80))]
            feedback["occurredAt"] = input.options.occurredAt.map { ISO8601DateFormatter.shared.string(from: $0) }
            payloads["user-feedback.json"] = try json(feedback)
        }
        let report = report(id: exportID, events: events, all: all, health: input.snapshot.health,
                            damaged: damaged, collectors: collectors, options: input.options,
                            capturedAt: input.snapshot.capturedAt)
        payloads["report.md"] = Data(report.utf8)
        let files = payloads.sorted { $0.key < $1.key }.map { item in
            DiagnosticManifest.File(path: item.key, bytes: item.value.count,
                sha256: SHA256.hash(data: item.value).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = DiagnosticManifest(schemaVersion: 3, exportID: exportID,
            createdAt: input.snapshot.capturedAt, cutoffSequence: input.snapshot.cutoffSequence,
            snapshotSessionID: DiagnosticContext.sessionID,
            requestedSince: input.options.since.map { ISO8601DateFormatter.shared.string(from: $0) },
            actualFirstEvent: events.first?.timestamp, actualLastEvent: events.last?.timestamp,
            damagedLines: damaged, historicalEvents: all.filter { $0.schemaVersion < 3 }.count,
            health: input.snapshot.health, collectors: collectors, files: files)
        payloads["manifest.json"] = try json(manifest)
        for (name, data) in payloads {
            let url = root.appendingPathComponent(name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return manifest
    }

    /// 自由文本不复刻入事件附件，历史上下文仅保留已批准的数字与枚举证据。
    /// 新事件的身份及计数仍原样保留，不能为历史事件补造会话或关联。
    private static func safeExport(_ value: DiagnosticEvent) -> DiagnosticEvent {
        var event = DiagnosticEvent(level: value.level, visibility: value.visibility,
            category: value.category, operation: value.operation, message: "Diagnostic evidence",
            summaryKey: value.summaryKey,
            service: value.service, statusCode: value.statusCode, errorCode: value.errorCode,
            underlying: value.underlying,
            operationID: value.operationID, parentOperationID: value.parentOperationID,
            requestID: value.requestID, serverTraceID: value.serverTraceID,
            phase: value.phase, outcome: value.outcome, durationMs: value.durationMs,
            impact: value.impact, fields: value.fields, errorChain: value.errorChain,
            breadcrumbs: value.breadcrumbs, breadcrumbsTruncated: value.breadcrumbsTruncated)
        event.timestamp = value.timestamp
        event.schemaVersion = value.schemaVersion
        event.eventID = value.eventID
        event.sequence = value.sequence
        event.sessionID = value.sessionID
        event.environmentID = value.environmentID
        event.operationID = value.operationID
        event.parentOperationID = value.parentOperationID
        event.occurrenceCount = max(1, value.occurrenceCount)
        event.firstSeen = value.firstSeen
        event.lastSeen = value.lastSeen
        // 已匿名化的作用范围保持稳定，不能在导出时合并不同仓库或账号的故障。
        event.context = value.context.filter {
            DiagnosticEvent.isSafeKey($0.key)
                && ($0.value.range(of: #"^ref:[a-f0-9]{16}$"#, options: .regularExpression) != nil
                    || ["true", "false"].contains($0.value)
                    || ($0.value.count <= 24
                        && $0.value.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil))
        }
        event.sourceFile = value.sourceFile.map { String(DiagnosticEvent.redact($0, includeURLs: true).suffix(160)) }
        event.sourceFunction = value.sourceFunction.map { String(DiagnosticEvent.redact($0, includeURLs: true).prefix(160)) }
        event.sourceLine = value.sourceLine
        return event
    }

    private struct DiagnosticModuleState: Encodable {
        let module: String
        let capturedAt: String
        let source: String
        let currentState: String
        let observed: [DiagnosticEvent]
        let activeOperations: [DiagnosticEvent]
    }

    private static func report(id: String, events: [DiagnosticEvent], all: [DiagnosticEvent],
                               health: [String: Int], damaged: Int, collectors: [DiagnosticCollectorResult],
                               options: DiagnosticExportOptions, capturedAt: String) -> String {
        let environment = DiagnosticEnvironment.current()
        var lines = ["# Starcat diagnostic report", "", "Report ID: \(id) (local export; not uploaded)",
            "Version: \(environment.version) (\(environment.build)), channel: \(environment.channel)",
            "System: \(environment.osVersion)", "Snapshot session: \(DiagnosticContext.sessionID)",
            "Events selected / retained: \(events.count) / \(all.count)",
            "Actual range: \(events.first?.timestamp ?? "unknown") .. \(events.last?.timestamp ?? "unknown")",
            "", "## Evidence limitations", "",
            "- Historical free text and string context were omitted for privacy",
            "- Module snapshots are observations at separate times, not a global transaction",
            "- Missing terminal or session-end events do not prove a crash",
            "- Exporting or dismissing a notification does not prove recovery",
            "- Correlation or system diagnostics may be unavailable for older records",
            "- Recovery is unknown without reliably correlated business evidence; suggestions are not executed recovery",
            "- Current configuration is in state/settings.json; fields below describe the failure time",
            "- Damaged lines: \(damaged)", "- Storage health: \(health)", "", "## Collector results", ""]
        lines += collectors.map { "- \($0.name): \($0.status.rawValue)\($0.detail.map { " (\($0))" } ?? "")" }
        lines += ["", "## Severe failure evidence", "",
            "Occurred-at evidence is retained below; export snapshot time is \(capturedAt).", ""]
        let failures = events.filter(\.isSevereFailure)
        let groups = Dictionary(grouping: failures, by: \.issueFingerprint)
        for key in groups.keys.sorted().prefix(100) {
            let values = (groups[key] ?? []).sorted { $0.date < $1.date }
            let count = values.reduce(0) { $0 + max(1, $1.occurrenceCount) }
            lines.append("- Group \(values.count) records: \(count) occurrences; latest \(values.last?.timestamp ?? "unknown")")
            if let latest = values.last {
                let fields = latest.fields.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.reportValue)" }.joined(separator: ", ")
                lines.append("  Summary: \(latest.summaryKey ?? "diagnostics.issue.generic"); impact=\(latest.impact.rawValue); outcome=\(latest.outcome?.rawValue ?? "unknown"); durationMs=\(latest.durationMs.map { String(format: "%.0f", $0) } ?? "unknown")")
                lines.append("  Layer: \(latest.category)/\(latest.operation); error=\(latest.errorCode ?? "unknown"); service=\(latest.service ?? "unknown"); HTTP=\(latest.statusCode.map(String.init) ?? "unknown"); source=\(latest.sourceFile ?? "unknown"):\(latest.sourceLine.map(String.init) ?? "-") \(latest.sourceFunction ?? "")")
                if !fields.isEmpty { lines.append("  Fields at failure: \(fields)") }
                for cause in latest.errorChain.prefix(8) {
                    lines.append("  Cause: \(cause.type) code=\(cause.code)")
                }
                for stage in latest.breadcrumbs {
                    let stageFields = stage.fields.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value.reportValue)" }.joined(separator: ", ")
                    let identity = [stage.operationID, stage.parentOperationID, stage.requestID]
                        .compactMap { $0 }.joined(separator: "/")
                    lines.append("  Stage: \(stage.phase) outcome=\(stage.outcome?.rawValue ?? "-") elapsedMs=\(String(format: "%.0f", stage.elapsedMs)) identity=\(identity.isEmpty ? "unknown" : identity) service=\(stage.service ?? "unknown") HTTP=\(stage.statusCode.map(String.init) ?? "unknown") error=\(stage.errorCode ?? "unknown")")
                    if !stageFields.isEmpty { lines.append("    Fields at stage: \(stageFields)") }
                }
                if latest.breadcrumbsTruncated { lines.append("  Stages truncated: yes; only the latest 16 are retained") }
            }
            let traces = Set(values.flatMap { event in
                [event.serverTraceID].compactMap { $0 } + event.breadcrumbs.compactMap(\.serverTraceID)
            }).sorted().prefix(8)
            if !traces.isEmpty { lines.append("  Server trace: " + traces.joined(separator: ", ")) }
        }
        if failures.isEmpty { lines.append("No severe failures in selected evidence; check collector gaps before concluding healthy") }
        let historical = events.filter { $0.schemaVersion < 3 }
        if !historical.isEmpty {
            lines += ["", "## Historical evidence", "",
                "Schema 1/2 records are retained for investigation; they do not satisfy schema 3 admission or imply current impairment."]
            for event in historical.filter({ $0.visibility == .issue || $0.level == .error || $0.level == .critical }).suffix(50) {
                lines.append("- \(event.timestamp) \(event.category)/\(event.operation): \(event.errorCode ?? "unknown"); underlying=\(event.underlying ?? "unknown"); outcome=\(event.outcome?.rawValue ?? "unknown")")
            }
        }
        if options.operationID == nil, let since = options.since {
            let older = all.filter { $0.date < since && $0.isSevereFailure }
            lines += ["", "## Retained severe failures before requested window", ""]
            let groups = Dictionary(grouping: older, by: \.issueFingerprint)
            lines += groups.keys.sorted().map { key in
                "- group: \((groups[key] ?? []).reduce(0) { $0 + max(1, $1.occurrenceCount) }) occurrences"
            }
            if older.isEmpty { lines.append("No older severe failures retained; this does not prove none occurred") }
        }
        lines += ["", "## Graph observations", ""]
        for event in events.filter({ $0.category == "followGraph" }).suffix(20) {
            let fields = event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.reportValue)" }.joined(separator: " ")
            lines.append("- \(event.timestamp) \(event.phase ?? "unknown"): \(fields)")
        }
        lines += ["", "## Active operations", "",
            "Unknown; severe-failure logs do not retain successful or in-flight operations."]
        lines += ["", "## Timeline (last 100 events)", ""]
        lines += events.suffix(100).map {
            "- \($0.timestamp) \($0.category)/\($0.operation) \($0.phase ?? "-") \($0.outcome?.rawValue ?? "-") operation=\($0.operationID ?? "unknown") request=\($0.requestID ?? "unknown")"
        }
        if !options.description.isEmpty { lines += ["", "User-provided context is in user-feedback.json (untrusted evidence)"] }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
