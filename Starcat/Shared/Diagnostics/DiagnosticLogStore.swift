//
//  DiagnosticLogStore.swift
//  Starcat
//
//  有界后台 JSONL 写入者。锁只保护入队与截点，文件操作严格在私有串行队列。
//  不依赖业务数据库；自身失败只累计健康计数，避免递归诊断。
//

import Foundation

/// 提醒统计与证据留存分离，确认提醒不会删除历史事件。
struct DiagnosticLogSummary: Equatable, Sendable {
    var issueCount: Int
    var latestIssue: DiagnosticEvent?
    static let empty = DiagnosticLogSummary(issueCount: 0, latestIssue: nil)
}

/// 快照是值拷贝，导出期间轮转或继续写入不会改变已经取得的证据。
struct DiagnosticSnapshot: Sendable {
    let text: String
    let cutoffSequence: UInt64
    let capturedAt: String
    let health: [String: Int]
    var sessions: Data? = nil
}

/// @unchecked Sendable 的约束：pending/sequence/dropped 只在锁内访问；其余可变状态只在 writer 队列访问。
/// 不能在锁内 await，也不能向 writer.sync，避免 UI 与文件操作互相等待。
final class DiagnosticLogStore: @unchecked Sendable {
    // 测试中的业务链路也会自动取证，统一隔离，避免污染本机 Debug App 的真实诊断目录。
    static let shared = DiagnosticLogStore(directoryURL: TestEnvironment.isRunning
        ? FileManager.default.temporaryDirectory.appendingPathComponent("StarcatTests-diagnostics-\(DiagnosticContext.sessionID)")
        : nil)
    private let writer = DispatchQueue(label: "ink.starcat.diagnostics.writer", qos: .utility)
    private let lock = NSLock()
    private var pending: [DiagnosticEvent] = []
    private var scheduled = false
    private var drainGeneration: UInt64 = 0
    private var sequence: UInt64 = 0
    private var dropped = 0
    private var peakQueue = 0
    private var pendingBytes = 0
    private var peakQueueBytes = 0
    private let queueLimit: Int
    private let queueByteLimit: Int
    private let segmentBytes: Int
    private let segmentCount: Int
    private let retention: TimeInterval
    private let fileManager: FileManager
    let directoryURL: URL
    private var writeFailures = 0
    private var readFailures = 0
    private var rotationFailures = 0
    private var lastCleanup = Date.distantPast
    private var repeats: [String: DiagnosticEvent] = [:]
    private var repeatFlushScheduled = false
    private var fingerprints: [String: Date] = [:]
    private var sessionRecords: [DiagnosticSessionRecord]?
    private var sessionLastSaved = Date.distantPast
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private var fileURL: URL { directoryURL.appendingPathComponent("diagnostic-log.jsonl") }
    private var acknowledgedURL: URL { directoryURL.appendingPathComponent("diagnostic-log-acknowledged-at.txt") }

    init(fileManager: FileManager = .default, directoryURL: URL? = nil,
         queueLimit: Int = 2048, queueByteLimit: Int = 4 * 1024 * 1024, segmentBytes: Int = 2 * 1024 * 1024,
         segmentCount: Int = 20, retention: TimeInterval = 14 * 86400) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.queueLimit = max(1, queueLimit)
        self.queueByteLimit = max(1024, queueByteLimit)
        self.segmentBytes = max(1024, segmentBytes)
        self.segmentCount = max(1, segmentCount)
        self.retention = retention
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// 同步入队分配顺序，不为每条事件创建 Task。队列满时记录丢弃数，绝不无限增长。
    func enqueue(_ event: DiagnosticEvent) {
        guard event.level != .debug || DiagnosticRecording.shared.expiresAt != nil else { return }
        let estimatedBytes = event.estimatedQueuedBytes
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        guard pending.count < queueLimit, pendingBytes + estimatedBytes <= queueByteLimit else { dropped += 1; return }
        var event = event
        event.sequence = sequence
        pending.append(event)
        pendingBytes += estimatedBytes
        peakQueueBytes = max(peakQueueBytes, pendingBytes)
        peakQueue = max(peakQueue, pending.count)
        if !scheduled {
            scheduled = true
            let generation = drainGeneration
            writer.async { [self] in
                lock.lock()
                guard generation == drainGeneration else { lock.unlock(); return }
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                pendingBytes = 0
                scheduled = false
                lock.unlock()
                batch.forEach(write)
            }
        }
    }

    /// 保留原 async 实例入口用于测试和显式等待的调用方；截点 API 才提供落盘屏障。
    func record(_ event: DiagnosticEvent) async { enqueue(event) }

    /// 入队和安排截点在同一锁内完成，保证截点前事件先于快照落盘。
    /// 截点之后的事件继续正常写入；序号缺口结合 dropped 解释，不伪装完整。
    func snapshot() async -> DiagnosticSnapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            // 使尚未开始的 drain 失效，后续入队安排在快照之后，避免跨越截点。
            drainGeneration += 1
            scheduled = false
            let cutoff = sequence
            let lost = dropped
            let peak = peakQueue
            let peakBytes = peakQueueBytes
            writer.async { [self] in
                batch.forEach(write)
                flushRepeats()
                let text = files().compactMap { url -> String? in
                    do { return try String(contentsOf: url, encoding: .utf8) }
                    catch { readFailures += 1; return nil }
                }.joined(separator: "\n")
                continuation.resume(returning: DiagnosticSnapshot(
                    text: text, cutoffSequence: cutoff,
                    capturedAt: ISO8601DateFormatter.shared.string(from: Date()),
                    health: ["droppedEvents": lost, "writeFailures": writeFailures, "readFailures": readFailures,
                             "rotationFailures": rotationFailures, "peakQueue": peak,
                             "peakQueueBytes": peakBytes, "queueBudgetBytes": queueByteLimit,
                             "queueLimit": queueLimit, "diskBudgetBytes": segmentBytes * (segmentCount + 1)],
                    sessions: try? encoder.encode(sessionRecords ?? [])))
            }
            lock.unlock()
        }
    }

    func readAllText() async -> String { await snapshot().text }

    /// 旧调用仅获取文件名；导出应使用 snapshot，不复制活动中的文件。
    func exportableFiles() async -> [URL] {
        _ = await snapshot()
        return await withCheckedContinuation { continuation in
            writer.async { continuation.resume(returning: self.files()) }
        }
    }

    func markIssuesAcknowledged(upTo date: Date = Date()) async {
        // 先截断重复批次，确认之后的新故障不能被并回已经忽略的旧摘要。
        _ = await snapshot()
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                do {
                    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    try ISO8601DateFormatter.shared.string(from: date).write(to: acknowledgedURL, atomically: true, encoding: .utf8)
                    notify()
                } catch { writeFailures += 1 }
                continuation.resume()
            }
        }
    }

    func issueSummary(since cutoff: Date = Date().addingTimeInterval(-86400)) async -> DiagnosticLogSummary {
        let text = await readAllText()
        let acknowledged: Date? = await withCheckedContinuation { continuation in
            writer.async { [self] in
                let value = try? String(contentsOf: acknowledgedURL, encoding: .utf8)
                continuation.resume(returning: value.flatMap { ISO8601DateFormatter.shared.date(from: $0) })
            }
        }
        let events = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8)) }
            .filter { $0.visibility == .issue && [.warning, .error, .critical].contains($0.level)
                && $0.date >= cutoff }
        // marker 为可选值，直接用分支避免把“尚未确认”误解为“没有问题”。
        let eligible = events.filter { event in acknowledged.map { event.date > $0 } ?? true }
        return DiagnosticLogSummary(issueCount: eligible.reduce(0) { $0 + $1.occurrenceCount },
                                    latestIssue: eligible.max { $0.date < $1.date })
    }

    private func files() -> [URL] {
        (stride(from: segmentCount, through: 1, by: -1).map {
            directoryURL.appendingPathComponent("diagnostic-log.\($0).jsonl")
        } + [fileURL]).filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// 操作开始/结束及请求结果不合并，确保每次实际尝试仍能独立关联。
    private func write(_ event: DiagnosticEvent) {
        guard event.operationID == nil, event.requestID == nil, event.phase == nil else { append(event); return }
        let key = "\(event.level)|\(event.visibility)|\(event.category)|\(event.operation)|\(event.message)|\(event.underlying ?? "")|\(event.statusCode ?? 0)|\(event.errorCode ?? "")|\(event.context.sorted { $0.key < $1.key })|\(event.fields.sorted { $0.key < $1.key })"
        if let previous = fingerprints[key], event.date.timeIntervalSince(previous) < 300 {
            var aggregate = repeats[key] ?? event
            aggregate.phase = "repeated"
            aggregate.firstSeen = aggregate.firstSeen ?? event.timestamp
            aggregate.lastSeen = event.timestamp
            aggregate.timestamp = event.timestamp
            aggregate.occurrenceCount = (repeats[key]?.occurrenceCount ?? 0) + 1
            aggregate.sequence = event.sequence
            repeats[key] = aggregate
            if !repeatFlushScheduled {
                repeatFlushScheduled = true
                writer.asyncAfter(deadline: .now() + 1) { [self] in
                    repeatFlushScheduled = false
                    flushRepeats()
                }
            }
        } else {
            if let repeated = repeats.removeValue(forKey: key) { append(repeated) }
            fingerprints[key] = event.date
            append(event)
        }
        if fingerprints.count > 1024 { flushRepeats(); fingerprints.removeAll(keepingCapacity: true) }
    }

    private func flushRepeats() {
        repeats.values.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }.forEach(append)
        repeats.removeAll(keepingCapacity: true)
    }

    private func append(_ event: DiagnosticEvent) {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if Date().timeIntervalSince(lastCleanup) > 3600 {
                lastCleanup = Date()
                for file in files() {
                    let attributes = try fileManager.attributesOfItem(atPath: file.path)
                    if let modified = attributes[.modificationDate] as? Date,
                       modified < Date().addingTimeInterval(-retention) { try fileManager.removeItem(at: file) }
                }
            }
            var data = try encoder.encode(event)
            data.append(10)
            if event.level == .debug, !DiagnosticRecording.shared.consume(data.count) { return }
            try updateSession(event)
            let currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            if currentSize + data.count > segmentBytes {
                do {
                    let oldest = directoryURL.appendingPathComponent("diagnostic-log.\(segmentCount).jsonl")
                    if fileManager.fileExists(atPath: oldest.path) { try fileManager.removeItem(at: oldest) }
                    for index in stride(from: segmentCount - 1, through: 1, by: -1) {
                        let source = directoryURL.appendingPathComponent("diagnostic-log.\(index).jsonl")
                        if fileManager.fileExists(atPath: source.path) {
                            try fileManager.moveItem(at: source, to: directoryURL.appendingPathComponent("diagnostic-log.\(index + 1).jsonl"))
                        }
                    }
                    if fileManager.fileExists(atPath: fileURL.path) {
                        try fileManager.moveItem(at: fileURL, to: directoryURL.appendingPathComponent("diagnostic-log.1.jsonl"))
                    }
                } catch { rotationFailures += 1; throw error }
            }
            if !fileManager.fileExists(atPath: fileURL.path) { fileManager.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if event.visibility == .issue { notify() }
        } catch { writeFailures += 1 }
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .diagnosticIssuesDidChange, object: nil) }
    }

    /// 最多保留二十个会话的安全环境与最后阶段。普通事件每秒最多写一次旁路状态文件。
    private func updateSession(_ event: DiagnosticEvent, ending: Bool = false) throws {
        let url = directoryURL.appendingPathComponent("sessions.json")
        if sessionRecords == nil {
            sessionRecords = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode([DiagnosticSessionRecord].self, from: $0)
            } ?? []
            sessionRecords?.append(DiagnosticSessionRecord(
                sessionID: DiagnosticContext.sessionID, startedAt: event.timestamp,
                lastUpdatedAt: event.timestamp, lastCategory: event.category, lastOperation: event.operation,
                lastPhase: event.phase, endedNormally: false, environment: .current()))
            sessionRecords = Array((sessionRecords ?? []).suffix(20))
        }
        guard var record = sessionRecords?.last else { return }
        record.lastUpdatedAt = event.timestamp
        record.lastCategory = event.category
        record.lastOperation = event.operation
        record.lastPhase = event.phase
        record.endedNormally = ending
        if let index = sessionRecords?.indices.last { sessionRecords?[index] = record }
        if ending || sessionLastSaved == .distantPast || event.category == "startup" ||
            Date().timeIntervalSince(sessionLastSaved) >= 1 {
            try encoder.encode(sessionRecords).write(to: url, options: .atomic)
            sessionLastSaved = Date()
        }
    }

    /// 正常退出时给写入者一个短暂完成窗口；超时仍是未知结束，不伪称崩溃。
    func endSession() {
        let completion = DispatchGroup()
        completion.enter()
        // 与 snapshot 使用同一入队屏障，防止尚未开始的 drain 在正常结束之后回写未结束状态。
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        drainGeneration += 1
        scheduled = false
        writer.async { [self] in
            batch.forEach(write)
            flushRepeats()
            try? updateSession(DiagnosticEvent(level: .info, category: "startup", operation: "session",
                                               message: "Normal termination", phase: "ended"), ending: true)
            completion.leave()
        }
        lock.unlock()
        _ = completion.wait(timeout: .now() + .milliseconds(200))
    }
}

extension DiagnosticEvent {
    var date: Date { ISO8601DateFormatter.shared.date(from: timestamp) ?? .distantPast }
}

extension DiagnosticLogStore {

    /// Fire-and-forget 便捷入口，适合 catch 分支和 UI action 调用。
    nonisolated static func record(
        level: DiagnosticEvent.Level,
        visibility: DiagnosticEvent.Visibility = .context,
        category: String,
        operation: String,
        message: StaticString,
        service: String? = nil,
        statusCode: Int? = nil,
        errorCode: String? = nil,
        underlying: String? = nil,
        context: [String: String] = [:],
        sourceFile: String = #fileID,
        sourceFunction: String = #function,
        sourceLine: Int = #line
    ) {
        let event = DiagnosticEvent(
            level: level,
            visibility: visibility,
            category: category,
            operation: operation,
            message: message,
            service: service,
            statusCode: statusCode,
            errorCode: errorCode,
            underlying: underlying,
            context: context, sourceFile: sourceFile, sourceFunction: sourceFunction, sourceLine: sourceLine
        )
        DiagnosticLogStore.shared.enqueue(event)
    }
}

extension Notification.Name {
    /// 诊断日志新增或状态面板问题被用户确认后发出。
    ///
    /// toolbar 状态按钮用它刷新本地摘要；不携带 payload，避免把诊断内容通过通知广播。
    static let diagnosticIssuesDidChange = Notification.Name("StarcatDiagnosticIssuesDidChange")
}
