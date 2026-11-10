//
//  DiagnosticSystemDiagnostics.swift
//  Starcat
//
//  系统回调只保存白名单技术字段，不落原始 payload、路径、业务正文或进程环境。
//

import Foundation

/// 系统附件使用独立串行队列与 1MB 容量，最多八份；未收到时不伪造诊断。
final class DiagnosticSystemDiagnostics: @unchecked Sendable {
    static let shared = DiagnosticSystemDiagnostics()
    private let queue = DispatchQueue(label: "ink.starcat.diagnostics.system", qos: .utility)
    private let directory: URL
    private var records: [[String: Any]]?
    private var failures = 0
    private var permissionDenied = false
    private var truncated = false

    init(directory: URL = DiagnosticLogStore.defaultDirectoryURL()) { self.directory = directory }

    /// jsonRepresentation 已由系统生成；先限制体积，再按白名单递归提取数值与栈身份。
    func record(_ data: Data, kind: String) {
        guard data.count <= 4 * 1024 * 1024 else {
            queue.async { self.truncated = true }
            DiagnosticLogStore.record(level: .warning, category: "telemetry", operation: "system.truncated",
                                      message: "System payload exceeded capture budget")
            return
        }
        queue.async { [self] in
            do {
                load()
                let object = try JSONSerialization.jsonObject(with: data)
                var remaining = 2048
                let safe = Self.sanitize(object, depth: 0, remaining: &remaining)
                truncated = truncated || remaining == 0
                let record: [String: Any] = [
                    "kind": kind == "diagnostic" ? "diagnostic" : "metric",
                    "receivedAt": Date().ISO8601Format(),
                    "sessionID": DiagnosticContext.sessionID,
                    "environmentVersion": DiagnosticEnvironment.current().version,
                    "build": DiagnosticEnvironment.current().build,
                    "truncated": remaining == 0,
                    "payload": safe ?? [:]
                ]
                records = Array(((records ?? []) + [record]).suffix(8))
                while try JSONSerialization.data(withJSONObject: records ?? []).count > 1024 * 1024 {
                    records?.removeFirst()
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: records ?? [], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("system-summary.json"), options: .atomic)
            } catch {
                failures += 1
                let ns = error as NSError
                permissionDenied = permissionDenied || (ns.domain == NSCocoaErrorDomain &&
                    [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code))
            }
        }
    }

    /// 仅读取已收到的附件；不触发系统采集，不保证系统一定交付崩溃报告。
    func snapshot() async -> (Data?, DiagnosticCollectorResult) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                load()
                let available = !(records ?? []).isEmpty
                let data = available ? try? JSONSerialization.data(withJSONObject: records ?? [], options: [.sortedKeys]) : nil
                continuation.resume(returning: (data, .init(name: "system",
                    status: permissionDenied ? .permissionDenied : failures > 0 ? .failed : truncated ? .truncated : available ? .collected : .notCollected,
                    detail: failures > 0 ? "System attachment processing failed" : available ? nil : "No system payload received")))
            }
        }
    }

    private func load() {
        guard records == nil else { return }
        let url = directory.appendingPathComponent("system-summary.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            records = []
            return
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1024 * 1024 else { records = []; truncated = true; return }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let existing = object as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
            // 本 App 自管文件仍再提取一次，避免人工修改附件扩大导出范围。
            records = existing.suffix(8).compactMap { item in
                var remaining = 2048
                truncated = truncated || (item["truncated"] as? Bool ?? false)
                return Self.sanitize(item, depth: 0, remaining: &remaining) as? [String: Any]
            }
        } catch {
            records = []
            failures += 1
            let ns = error as NSError
            permissionDenied = ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError
        }
    }

    /// 不允许任意 JSON key；栈仅保留 UUID、偏移、地址和层级，不保存源码路径。
    static func sanitize(_ value: Any, depth: Int, remaining: inout Int) -> Any? {
        guard depth < 16, remaining > 0 else { return nil }
        remaining -= 1
        if let dictionary = value as? [String: Any] {
            let allowed: Set<String> = [
                "kind", "receivedAt", "sessionID", "environmentVersion", "build", "truncated", "payload",
                "timeStampBegin", "timeStampEnd", "appVersion", "metaData", "osVersion",
                "diagnosticMetaData", "crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics",
                "diskWriteExceptionDiagnostics", "exceptionType", "exceptionCode", "signal",
                "terminationReason", "virtualMemoryRegionInfo", "callStackTree", "callStacks",
                "callStackRootFrames", "subFrames", "binaryUUID", "offsetIntoBinaryTextSegment",
                "address", "sampleCount", "threadAttributed", "threadId", "callStackPerThread",
                "cpuMetrics", "cumulativeCPUTime", "applicationTimeMetrics", "cumulativeForegroundTime",
                "cumulativeBackgroundTime", "applicationLaunchMetrics", "applicationResumeTime",
                "hangDuration", "totalCPUTime", "totalSampledTime", "writesCaused", "diskIOMetrics"
            ]
            return dictionary.keys.sorted().prefix(64).reduce(into: [String: Any]()) { result, key in
                guard allowed.contains(key), let child = dictionary[key],
                      let safe = sanitize(child, depth: depth + 1, remaining: &remaining) else { return }
                result[key] = safe
            }
        }
        if let array = value as? [Any] {
            return array.prefix(64).compactMap { sanitize($0, depth: depth + 1, remaining: &remaining) }
        }
        if let number = value as? NSNumber { return number }
        if let text = value as? String {
            if UUID(uuidString: text) != nil { return text }
            if ["metric", "diagnostic"].contains(text) { return text }
            if text.range(of: #"^[0-9xXa-fA-F_.:+\-TZ ]{1,128}$"#, options: .regularExpression) != nil,
               text.range(of: #"[0-9]"#, options: .regularExpression) != nil {
                return DiagnosticEvent.redact(text)
            }
        }
        return nil
    }
}
