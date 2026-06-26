//
//  DiagnosticLogStore.swift
//  Starcat
//
//  用户可导出的本机诊断日志存储。
//
//  设计目标：
//  - 用 app-owned JSONL 保存关键 warning/error，用户主动导出时可直接打包；
//  - 不替代 OSLog，OSLog 继续承担开发期 Console.app 调试；
//  - 写入失败只记 OSLog，不影响主流程，避免诊断系统反过来拖垮 App。
//

import Foundation

/// 诊断日志给 UI 展示用的轻量摘要。
///
/// 只统计 warning 及以上级别，避免 debug/info 健康检查日志让 toolbar 状态看起来像故障。
struct DiagnosticLogSummary: Equatable, Sendable {
    var issueCount: Int
    var latestIssue: DiagnosticEvent?

    static let empty = DiagnosticLogSummary(issueCount: 0, latestIssue: nil)
}

/// 轻量 JSONL 诊断日志。
///
/// actor 串行化文件写入，避免多个 async 任务同时 append 导致行交错。日志按文件大小
/// 滚动，保留当前文件和一个 `.1` 备份，足够覆盖最近问题，同时不会无限增长。
actor DiagnosticLogStore {

    static let shared = DiagnosticLogStore()

    private static let directoryName = "diagnostics"
    private static let fileName = "diagnostic-log.jsonl"
    private static let rotatedFileName = "diagnostic-log.1.jsonl"
    private static let acknowledgedFileName = "diagnostic-log-acknowledged-at.txt"
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let duplicateSuppressionWindow: TimeInterval = 5 * 60

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let directoryURL: URL
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let acknowledgedFileURL: URL
    private var lastRecordedAtByFingerprint: [DiagnosticEventFingerprint: Date] = [:]

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]

        let baseURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.directoryURL = baseURL
        self.fileURL = baseURL.appendingPathComponent(Self.fileName)
        self.rotatedFileURL = baseURL.appendingPathComponent(Self.rotatedFileName)
        self.acknowledgedFileURL = baseURL.appendingPathComponent(Self.acknowledgedFileName)
    }

    /// 追加一条诊断事件。
    func record(_ event: DiagnosticEvent) async {
        do {
            guard !shouldSuppress(event) else { return }
            try ensureDirectory()
            try rotateIfNeeded()
            let data = try encoder.encode(event)
            try append(data)
            markRecorded(event)
            NotificationCenter.default.post(name: .diagnosticIssuesDidChange, object: nil)
        } catch {
            AppLog.general.error("Diagnostic log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 返回当前可导出的日志文件，旧文件排前，方便人工按时间阅读。
    func exportableFiles() async -> [URL] {
        [rotatedFileURL, fileURL].filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// 测试和导出器使用：读取所有 JSONL 文本。
    func readAllText() async -> String {
        let files = await exportableFiles()
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "")
    }

    /// 把当前及更早的诊断问题标记为“用户已处理”。
    ///
    /// 这里只写一个 marker，而不删除 JSONL 本体：用户导出的诊断包仍然保留完整证据；
    /// toolbar 状态面板则从 marker 之后重新开始统计，避免旧 warning 一直压着状态栏。
    func markIssuesAcknowledged(upTo date: Date = Date()) async {
        do {
            try ensureDirectory()
            let text = ISO8601DateFormatter.shared.string(from: date)
            try text.write(to: acknowledgedFileURL, atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: .diagnosticIssuesDidChange, object: nil)
        } catch {
            AppLog.general.error("Diagnostic issue acknowledgement failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 读取最近诊断问题摘要。
    ///
    /// 这是 toolbar 状态面板的只读入口：它不新增日志、不触发外部请求，只解析本机 JSONL。
    /// 失败行会被跳过，避免半行写入或旧格式日志让状态面板不可用。
    func issueSummary(since cutoff: Date = Date().addingTimeInterval(-24 * 60 * 60)) async -> DiagnosticLogSummary {
        let files = await exportableFiles()
        let decoder = JSONDecoder()
        let acknowledgedAt = acknowledgedAt()
        var issues: [DiagnosticEvent] = []

        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(DiagnosticEvent.self, from: data),
                      event.isUserVisibleIssue,
                      event.date >= cutoff,
                      acknowledgedAt.map({ event.date > $0 }) ?? true else {
                    continue
                }
                issues.append(event)
            }
        }

        let latest = issues.max { $0.date < $1.date }
        return DiagnosticLogSummary(issueCount: issues.count, latestIssue: latest)
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let size = attributes[.size] as? UInt64 ?? 0
        guard size >= Self.maxBytes else { return }

        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try fileManager.removeItem(at: rotatedFileURL)
        }
        try fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }

    private func append(_ data: Data) throws {
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private func acknowledgedAt() -> Date? {
        guard let text = try? String(contentsOf: acknowledgedFileURL, encoding: .utf8) else {
            return nil
        }
        return ISO8601DateFormatter.shared.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func shouldSuppress(_ event: DiagnosticEvent) -> Bool {
        let fingerprint = DiagnosticEventFingerprint(event)
        let eventDate = event.date
        pruneDuplicateFingerprints(before: eventDate)

        if let lastRecordedAt = lastRecordedAtByFingerprint[fingerprint],
           eventDate.timeIntervalSince(lastRecordedAt) < Self.duplicateSuppressionWindow {
            return true
        }

        return false
    }

    private func markRecorded(_ event: DiagnosticEvent) {
        lastRecordedAtByFingerprint[DiagnosticEventFingerprint(event)] = event.date
    }

    private func pruneDuplicateFingerprints(before date: Date) {
        let cutoff = date.addingTimeInterval(-Self.duplicateSuppressionWindow)
        lastRecordedAtByFingerprint = lastRecordedAtByFingerprint.filter { $0.value >= cutoff }
    }
}

private extension DiagnosticEvent {
    var date: Date {
        ISO8601DateFormatter.shared.date(from: timestamp) ?? .distantPast
    }

    var isUserVisibleIssue: Bool {
        switch level {
        case .warning, .error, .critical:
            return true
        case .debug, .info:
            return false
        }
    }
}

private struct DiagnosticEventFingerprint: Hashable {
    let level: String
    let category: String
    let operation: String
    let message: String
    let service: String?
    let statusCode: Int?
    let errorCode: String?
    let underlying: String?
    let context: [ContextPair]

    init(_ event: DiagnosticEvent) {
        self.level = event.level.rawValue
        self.category = event.category
        self.operation = event.operation
        self.message = event.message
        self.service = event.service
        self.statusCode = event.statusCode
        self.errorCode = event.errorCode
        self.underlying = event.underlying
        // `Dictionary` 的枚举顺序不稳定；排序后再做 key，避免相同 context 因顺序不同绕过去重。
        self.context = event.context
            .map { ContextPair(key: $0.key, value: $0.value) }
            .sorted()
    }

    struct ContextPair: Hashable, Comparable {
        let key: String
        let value: String

        static func < (lhs: ContextPair, rhs: ContextPair) -> Bool {
            if lhs.key == rhs.key {
                return lhs.value < rhs.value
            }
            return lhs.key < rhs.key
        }
    }
}

extension DiagnosticLogStore {

    /// Fire-and-forget 便捷入口，适合 catch 分支和 UI action 调用。
    nonisolated static func record(
        level: DiagnosticEvent.Level,
        category: String,
        operation: String,
        message: String,
        service: String? = nil,
        statusCode: Int? = nil,
        errorCode: String? = nil,
        underlying: String? = nil,
        context: [String: String] = [:]
    ) {
        let event = DiagnosticEvent(
            level: level,
            category: category,
            operation: operation,
            message: message,
            service: service,
            statusCode: statusCode,
            errorCode: errorCode,
            underlying: underlying,
            context: context
        )
        Task {
            await DiagnosticLogStore.shared.record(event)
        }
    }
}

extension Notification.Name {
    /// 诊断日志新增或状态面板问题被用户确认后发出。
    ///
    /// toolbar 状态按钮用它刷新本地摘要；不携带 payload，避免把诊断内容通过通知广播。
    static let diagnosticIssuesDidChange = Notification.Name("StarcatDiagnosticIssuesDidChange")
}
