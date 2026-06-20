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
    static func exportFromPanel(settings: AppSettings? = nil) async -> DiagnosticExportResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "starcat-diagnostics-\(dateFormatter.string(from: Date())).zip"
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else {
            return .cancelled
        }

        do {
            let url = try await export(to: destination, settings: settings)
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

    /// 直接导出到指定 URL，供 UI 和单测复用。
    @MainActor
    static func export(to destination: URL, settings: AppSettings? = nil) async throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let payloadRoot = tempRoot.appendingPathComponent("starcat-diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        try await copyDiagnosticLogs(to: payloadRoot)
        try writeAppInfo(to: payloadRoot)
        try writeSettingsSnapshot(settings, to: payloadRoot)
        try writeReadme(to: payloadRoot)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.zipItem(at: payloadRoot, to: destination, shouldKeepParent: true)

        DiagnosticLogStore.record(
            level: .info,
            category: "diagnostics",
            operation: "export",
            message: "Diagnostic bundle exported",
            context: ["path": destination.path]
        )
        return destination
    }

    private static func copyDiagnosticLogs(to root: URL) async throws {
        let files = await DiagnosticLogStore.shared.exportableFiles()
        guard !files.isEmpty else {
            let emptyURL = root.appendingPathComponent("diagnostic-log.jsonl")
            try Data().write(to: emptyURL)
            return
        }

        for file in files {
            let target = root.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    private static func writeAppInfo(to root: URL) throws {
        let info: [String: String] = [
            "bundleIdentifier": AppConstants.bundleIdentifier,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "exportedAt": ISO8601DateFormatter.shared.string(from: Date())
        ]
        try writeJSON(info, to: root.appendingPathComponent("app-info.json"))
    }

    @MainActor
    private static func writeSettingsSnapshot(_ settings: AppSettings?, to root: URL) throws {
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
        try writeJSON(snapshot, to: root.appendingPathComponent("settings-snapshot.json"))
    }

    private static func writeReadme(to root: URL) throws {
        let text = """
        Starcat Diagnostics

        This archive was created locally by Starcat after an explicit user action.
        It contains diagnostic logs and non-sensitive app metadata only.

        It should not contain GitHub tokens, API keys, AI prompts, README bodies, or private notes.
        """
        try text.write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
