//
//  DiagnosticSessionLifecycle.swift
//  Starcat
//
//  独立会话与增强复现控制，不访问账号、Keychain 或业务数据库。
//

import AppKit
import Foundation

/// 环境只包含固定白名单；历史环境由会话记录保存，不用导出时版本补造历史事实。
struct DiagnosticEnvironment: Codable, Sendable {
    let sessionID: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let osVersion: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let sandboxed: Bool
    let channel: String

    static func current() -> Self {
        Self(sessionID: DiagnosticContext.sessionID,
             version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
             bundleIdentifier: Bundle.main.bundleIdentifier ?? AppConstants.bundleIdentifier,
             osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
             processorCount: ProcessInfo.processInfo.processorCount,
             physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
             sandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
             channel: DistributionChannel.current.rawValue)
    }
}

/// 会话缺失结束记录只表示未知，不推断崩溃。文件由诊断写入者独占访问。
struct DiagnosticSessionRecord: Codable, Sendable {
    var sessionID: String
    var startedAt: String
    var lastUpdatedAt: String
    var lastCategory: String
    var lastOperation: String
    var lastPhase: String?
    var endedNormally: Bool
    var environment: DiagnosticEnvironment
}

/// 生命周期仅安装本 App 的正常退出观察；测试期不安装系统观察器。
enum DiagnosticSessionLifecycle {
    @MainActor private static var terminationObserver: NSObjectProtocol?

    @MainActor
    static func start() {
        guard !TestEnvironment.isRunning, terminationObserver == nil else { return }
        DiagnosticLogStore.record(level: .info, category: "startup", operation: "session",
                                  message: "Session started")
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in DiagnosticLogStore.shared.endSession() }
    }
}

/// 增强模式只允许额外安全 debug 阶段，自动到期或达到 20MB 后停止。
/// 锁内只处理值，通知和日志在解锁后发送，避免递归入队死锁。
final class DiagnosticRecording: @unchecked Sendable {
    static let shared = DiagnosticRecording()
    private let lock = NSLock()
    private var deadline: Date?
    private var generation = UUID()
    private var bytes = 0
    private let byteLimit: Int
    private let lifecycleEvents: Bool

    /// 小预算和静默生命周期只用于隔离测试；生产上限始终不超过 20MB。
    init(byteLimit: Int = 20 * 1024 * 1024, lifecycleEvents: Bool = true) {
        self.byteLimit = min(20 * 1024 * 1024, max(1, byteLimit))
        self.lifecycleEvents = lifecycleEvents
    }

    var expiresAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return deadline.flatMap { $0 > Date() ? $0 : nil }
    }

    @discardableResult
    func start(duration: TimeInterval = 900) -> Date {
        let duration = min(900, max(1, duration))
        let end = Date().addingTimeInterval(duration)
        let token = UUID()
        lock.lock()
        deadline = end
        generation = token
        bytes = 0
        lock.unlock()
        if lifecycleEvents {
            DiagnosticLogStore.record(level: .info, category: "diagnostics", operation: "reproduction.start",
                                      message: "Enhanced safe recording started")
            notify()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration) { [self] in
            stop(ifGeneration: token)
        }
        return end
    }

    func stop() { stop(ifGeneration: nil) }

    private func stop(ifGeneration token: UUID?) {
        lock.lock()
        guard deadline != nil, token == nil || token == generation else { lock.unlock(); return }
        deadline = nil
        lock.unlock()
        if lifecycleEvents {
            DiagnosticLogStore.record(level: .info, category: "diagnostics", operation: "reproduction.end",
                                      message: "Enhanced safe recording ended")
            notify()
        }
    }

    /// 在写入者编码后计量，达到预算立即关闭，不改变业务日志原有留存策略。
    func consume(_ count: Int) -> Bool {
        lock.lock()
        let active = deadline.map { $0 > Date() } ?? false
        if active { bytes += count }
        let allowed = active && bytes <= byteLimit
        let exceeded = active && !allowed
        lock.unlock()
        if exceeded { stop() }
        return allowed
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .diagnosticRecordingDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let diagnosticRecordingDidChange = Notification.Name("StarcatDiagnosticRecordingDidChange")
}
