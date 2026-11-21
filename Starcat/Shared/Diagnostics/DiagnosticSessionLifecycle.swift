//
//  DiagnosticSessionLifecycle.swift
//  Starcat
//
//  独立诊断会话的环境与正常退出标记，不访问账号、Keychain 或业务数据库。
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
        DiagnosticLogStore.shared.startSession()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in DiagnosticLogStore.shared.endSession() }
    }
}
