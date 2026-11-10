//
//  DiagnosticBundleExporter.swift
//  Starcat
//
//  调试日志导出器。
//
//  模块职责：
//  - 用户主动触发时，把 Starcat 的诊断 JSONL、App 版本信息和非敏感设置快照打包；
//  - 只导出本机文件，不上传任何数据；
//  - 避免包含 API Key、GitHub Token、AI prompt、README 全文等敏感内容。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// 诊断包导出结果。
enum DiagnosticExportResult: Equatable {
    case exported(URL)
    case cancelled
    case failed(String)
}

/// 诊断包导出器。
///
/// 采用静态方法是为了让 Settings 页和启动失败页都能复用，不需要额外持有状态。
enum DiagnosticBundleExporter {

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// 弹出保存面板并导出诊断 zip。
    @MainActor
    static func exportFromPanel(settings: AppSettings? = nil, options: DiagnosticExportOptions = .init()) async -> DiagnosticExportResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "starcat-diagnostics-\(dateFormatter.string(from: Date())).zip"
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else {
            return .cancelled
        }

        do {
            let url = try await export(to: destination, settings: settings, options: options)
            return .exported(url)
        } catch {
            AppLog.general.error("Diagnostic export failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                category: "diagnostics",
                operation: "export",
                message: "Diagnostic export failed",
                underlying: error.localizedDescription
            )
            return .failed(error.localizedDescription)
        }
    }

    /// 主线程只捕获设置值；采集有预算，压缩与文件替换都在后台。
    @MainActor
    static func export(to destination: URL, settings: AppSettings? = nil,
                       options: DiagnosticExportOptions = .init(),
                       store: DiagnosticLogStore = .shared,
                       localAIStore: LocalAILogStore = .shared,
                       systemStore: DiagnosticSystemDiagnostics = .shared) async throws -> URL {
        let settings = settingsSnapshot(settings)
        let snapshot = await DiagnosticDeadline.capture { await store.snapshot() }
        let local = await DiagnosticDeadline.capture { await localAIStore.snapshot() }
        let system = await DiagnosticDeadline.capture { await systemStore.snapshot() }
        let storageFailed = snapshot?.health.contains { $0.key.hasSuffix("Failures") && $0.value > 0 } ?? false
        let storageTruncated = (snapshot?.health["droppedEvents"] ?? 0) > 0
        var collectors: [DiagnosticCollectorResult] = [
            .init(name: "events", status: snapshot == nil ? .timedOut : storageFailed ? .failed : storageTruncated ? .truncated : .collected,
                  detail: storageFailed ? "Some diagnostic storage operations failed" : storageTruncated ? "Some queued events were dropped" : nil),
            .init(name: "localAI", status: local == nil ? .timedOut : local?.storageError != nil ? .failed : .collected,
                  detail: local?.storageError == nil ? nil : "Local AI storage reported a failure"),
            system?.1 ?? .init(name: "system", status: .timedOut, detail: nil),
            .init(name: "settings", status: settings["hasSettings"] == "true" ? .collected : .notCollected, detail: nil)
        ]
        if let local, local.droppedCount > 0 {
            collectors.append(.init(name: "localAIQueue", status: .truncated, detail: "Local AI events were dropped"))
        }
        if (local?.events.count ?? 0) > 500 {
            collectors.append(.init(name: "localAIWindow", status: .truncated, detail: "Only the last 500 Local AI events were included"))
        }
        let safeLocal = (local?.events ?? []).suffix(500).map { event in
            var safe = DiagnosticEvent(level: event.level == .error ? .error : event.level == .warning ? .warning : .info,
                category: "localAI", operation: "runtime", message: "Local AI stage",
                requestID: event.requestID, phase: event.stage,
                fields: event.fields.reduce(into: [:]) { fields, item in
                    if let count = Int(item.value) { fields[item.key] = .integer(count) }
                    else if let count = Double(item.value), count.isFinite { fields[item.key] = .decimal(count) }
                    else if ["finishReason", "reason", "errorType"].contains(item.key) {
                        fields[item.key] = .string(item.value)
                    }
                })
            safe.timestamp = event.timestamp
            safe.sessionID = nil
            safe.environmentID = nil
            return safe
        }
        let input = DiagnosticArchiveBuilder.Input(
            snapshot: snapshot ?? DiagnosticSnapshot(text: "", cutoffSequence: 0,
                capturedAt: Date().ISO8601Format(), health: ["captureUnavailable": 1]),
            settings: settings, options: options, sessions: snapshot?.sessions,
            localAI: Array(safeLocal), collectors: collectors, system: system?.0)
        let result = try await Task.detached(priority: .utility) {
            try archive(input: input, destination: destination)
        }.value
        DiagnosticLogStore.record(level: .info, category: "diagnostics", operation: "export",
                                  message: "Diagnostic material saved locally")
        // 导出仅生成本地证据，不确认提醒，不代表故障恢复或文件已上传。
        return result
    }

    /// 完整临时 ZIP 生成后才替换目标；失败不删除用户已有文件。
    static func archive(input: DiagnosticArchiveBuilder.Input, destination: URL,
                        compress: (URL, URL) throws -> Void = {
                            try FileManager.default.zipItem(at: $0, to: $1, shouldKeepParent: true)
                        }) throws -> URL {
        let manager = FileManager.default
        let identifier = UUID().uuidString
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".starcat-diagnostics-" + identifier, isDirectory: true)
        let root = temporary.appendingPathComponent("starcat-diagnostics", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        _ = try DiagnosticArchiveBuilder.writePayload(input: input, to: root, exportID: identifier)
        let stagedZIP = temporary.appendingPathComponent("bundle.zip")
        do {
            try compress(root, stagedZIP)
        } catch {
            // 压缩失败仍保留可读报告和其余文件，文件夹名称明确区分 ZIP。
            let fallbackInput = DiagnosticArchiveBuilder.Input(snapshot: input.snapshot, settings: input.settings,
                options: input.options, sessions: input.sessions, localAI: input.localAI,
                collectors: input.collectors + [.init(name: "compression", status: .failed,
                    detail: "ZIP creation failed; exported a directory")], system: input.system)
            _ = try DiagnosticArchiveBuilder.writePayload(input: fallbackInput, to: root, exportID: identifier)
            let fallback = destination.deletingLastPathComponent()
                .appendingPathComponent("starcat-diagnostics-" + identifier, isDirectory: true)
            try manager.moveItem(at: root, to: fallback)
            return fallback
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: stagedZIP)
        } else {
            try manager.moveItem(at: stagedZIP, to: destination)
        }
        return destination
    }

    @MainActor
    private static func settingsSnapshot(_ settings: AppSettings?) -> [String: String] {
        var snapshot: [String: String] = [
            "hasSettings": settings == nil ? "false" : "true"
        ]
        if let settings {
            snapshot["appearanceMode"] = settings.appearanceMode.rawValue
            snapshot["disableAnimations"] = String(settings.disableAnimations)
            snapshot["mcpServiceEnabled"] = String(settings.mcpServiceEnabled)
            snapshot["mcpServicePort"] = String(settings.mcpServicePort)
            snapshot["mcpExposePrivateNotes"] = String(settings.mcpExposePrivateNotes)
            snapshot["mcpAllowLocalWrites"] = String(settings.mcpAllowLocalWrites)
            snapshot["chatHistoryStorageKind"] = settings.chatHistoryStorageKind.rawValue
            snapshot["aiProviderProfileCount"] = String(settings.aiProviderProfiles.count)
        }
        return snapshot
    }

}
