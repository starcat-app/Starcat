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
    var occurrenceCount: Int = 0
    var latestOccurrenceCount: Int = 0
    var storageUnavailable: Bool = false
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
    private var expiredEvents = 0
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
        guard event.isSevereFailure, event.hasValidSummaryKey else { return }
        let estimatedBytes = event.estimatedQueuedBytes
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        guard pending.count < queueLimit, pendingBytes + estimatedBytes <= queueByteLimit else {
            dropped += 1
            if dropped == 1 { notify() }
            return
        }
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
                let damaged = text.split(separator: "\n").filter {
                    (try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))) == nil
                }.count
                // 没有新事件的会话仍要导出既有环境，不能把未加载当成空记录。
                var sessions = sessionRecords
                let sessionsURL = directoryURL.appendingPathComponent("sessions.json")
                if sessions == nil, fileManager.fileExists(atPath: sessionsURL.path) {
                    do {
                        sessions = try JSONDecoder().decode([DiagnosticSessionRecord].self,
                            from: Data(contentsOf: sessionsURL))
                    } catch { readFailures += 1 }
                }
                continuation.resume(returning: DiagnosticSnapshot(
                    text: text, cutoffSequence: cutoff,
                    capturedAt: ISO8601DateFormatter.shared.string(from: Date()),
                    health: ["droppedEvents": lost, "writeFailures": writeFailures, "readFailures": readFailures,
                             "rotationFailures": rotationFailures, "damagedLines": damaged, "peakQueue": peak,
                             "expiredEvents": expiredEvents,
                             "peakQueueBytes": peakBytes, "queueBudgetBytes": queueByteLimit,
                             "queueLimit": queueLimit, "diskBudgetBytes": segmentBytes * (segmentCount + 1)],
                    sessions: try? encoder.encode(sessions ?? [])))
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
                } catch { writeFailures += 1; notify() }
                continuation.resume()
            }
        }
    }

    func issueSummary(since cutoff: Date = Date().addingTimeInterval(-86400)) async -> DiagnosticLogSummary {
        let snapshot = await snapshot()
        let acknowledgement: (Date?, Bool) = await withCheckedContinuation { continuation in
            writer.async { [self] in
                guard fileManager.fileExists(atPath: acknowledgedURL.path) else {
                    continuation.resume(returning: (nil, false))
                    return
                }
                do {
                    let value = try String(contentsOf: acknowledgedURL, encoding: .utf8)
                    guard let date = ISO8601DateFormatter.shared.date(from: value) else {
                        readFailures += 1
                        continuation.resume(returning: (nil, true))
                        return
                    }
                    continuation.resume(returning: (date, false))
                } catch {
                    readFailures += 1
                    continuation.resume(returning: (nil, true))
                }
            }
        }
        let events = snapshot.text.split(separator: "\n").compactMap { try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8)) }
            .filter { $0.isSevereFailure
                && $0.date >= cutoff }
        // marker 为可选值，直接用分支避免把“尚未确认”误解为“没有问题”。
        let eligible = events.filter { event in acknowledgement.0.map { event.date > $0 } ?? true }
        let groups = Dictionary(grouping: eligible, by: \.issueFingerprint)
        let latest = eligible.max { $0.date < $1.date }
        return DiagnosticLogSummary(issueCount: groups.count, latestIssue: latest,
            occurrenceCount: eligible.reduce(0) { $0 + max(1, $1.occurrenceCount) },
            latestOccurrenceCount: latest.flatMap { groups[$0.issueFingerprint] }?.reduce(0) {
                $0 + max(1, $1.occurrenceCount)
            } ?? 0,
            storageUnavailable: acknowledgement.1 || snapshot.health.contains { $0.key.hasSuffix("Failures") && $0.value > 0 }
                || (snapshot.health["droppedEvents"] ?? 0) > 0 || (snapshot.health["damagedLines"] ?? 0) > 0)
    }

    private func files() -> [URL] {
        do {
            let present = Set(try fileManager.contentsOfDirectory(atPath: directoryURL.path))
            return (stride(from: segmentCount, through: 1, by: -1).map {
                directoryURL.appendingPathComponent("diagnostic-log.\($0).jsonl")
            } + [fileURL]).filter { present.contains($0.lastPathComponent) }
        } catch {
            let failure = error as NSError
            if failure.domain != NSCocoaErrorDomain || failure.code != NSFileReadNoSuchFileError {
                readFailures += 1
            }
            return []
        }
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
            aggregate.occurrenceCount = (repeats[key]?.occurrenceCount ?? 0) + max(1, event.occurrenceCount)
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
            if event.date < Date().addingTimeInterval(-retention) { expiredEvents += event.occurrenceCount; return }
            if Date().timeIntervalSince(lastCleanup) > 3600 {
                lastCleanup = Date()
                for file in files() {
                    let attributes = try fileManager.attributesOfItem(atPath: file.path)
                    if let modified = attributes[.modificationDate] as? Date,
                       modified < Date().addingTimeInterval(-retention) { try fileManager.removeItem(at: file) }
                    else if let created = attributes[.creationDate] as? Date,
                            created < Date().addingTimeInterval(-retention) {
                        // 低频日志可能始终不轮转，mtime 会一直更新。旧文件逐行收口，
                        // 保留近期记录与损坏行证据，避免整个文件删除时丢掉新故障。
                        let text = try String(contentsOf: file, encoding: .utf8)
                        let lines = text.split(separator: "\n")
                        let kept = lines.filter { line in
                            guard let value = try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(line.utf8)),
                                  value.date != .distantPast else { return true }
                            if value.date < Date().addingTimeInterval(-retention) {
                                expiredEvents += max(1, value.occurrenceCount)
                                return false
                            }
                            return true
                        }
                        if kept.count != lines.count {
                            try (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            var data = try encoder.encode(event)
            data.append(10)
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
        } catch { writeFailures += 1; notify() }
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .diagnosticIssuesDidChange, object: nil) }
    }

    /// 最多保留二十个会话；阶段只来自严重故障，不用会话文件旁路保存成功操作历史。
    private func updateSession(_ event: DiagnosticEvent, ending: Bool = false) throws {
        let url = directoryURL.appendingPathComponent("sessions.json")
        if sessionRecords == nil {
            // 会话元数据损坏不能被空数组覆盖，否则导出会丢失已有环境关联。
            do {
                sessionRecords = fileManager.fileExists(atPath: url.path)
                    ? try JSONDecoder().decode([DiagnosticSessionRecord].self, from: Data(contentsOf: url)) : []
            } catch {
                readFailures += 1
                throw error
            }
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

    /// 启动元数据独立保存，收紧普通事件准入后仍可关联无故障会话的环境。
    func startSession() {
        writer.async { [self] in
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try updateSession(DiagnosticEvent(level: .info, category: "startup", operation: "session",
                                                   message: "Session metadata", phase: "started"))
            } catch { writeFailures += 1; notify() }
        }
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
        summary: DiagnosticIssue? = nil,
        impact: DiagnosticEvent.Impact = .none,
        outcome: DiagnosticEvent.Outcome = .failed,
        service: String? = nil,
        statusCode: Int? = nil,
        errorCode: String? = nil,
        underlying: String? = nil,
        context: [String: String] = [:],
        fields: [String: DiagnosticValue] = [:],
        error: Error? = nil,
        sourceFile: String = #fileID,
        sourceFunction: String = #function,
        sourceLine: Int = #line
    ) {
        guard error.map(DiagnosticFailure.isCancellation) != true else { return }
        let event = DiagnosticEvent(
            level: level,
            visibility: visibility,
            category: category,
            operation: operation,
            message: message,
            summaryKey: summary?.rawValue,
            service: service,
            statusCode: statusCode,
            errorCode: errorCode ?? error.map(DiagnosticFailure.code),
            underlying: underlying ?? error.map(DiagnosticEvent.summarize),
            context: context, phase: "finished", outcome: outcome, impact: impact, fields: fields,
            errorChain: error.map(DiagnosticFailure.causes) ?? [],
            sourceFile: sourceFile, sourceFunction: sourceFunction, sourceLine: sourceLine
        )
        if DiagnosticContext.current?.capture(event) != true { DiagnosticLogStore.shared.enqueue(event) }
    }
}

extension Notification.Name {
    /// 诊断日志新增或状态面板问题被用户确认后发出。
    ///
    /// toolbar 状态按钮用它刷新本地摘要；不携带 payload，避免把诊断内容通过通知广播。
    static let diagnosticIssuesDidChange = Notification.Name("StarcatDiagnosticIssuesDidChange")
}
