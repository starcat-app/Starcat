//
//  StarcatMCPAuditLog.swift
//  Starcat
//
//  MCP 写入审计日志。
//
//  P0 使用本地 JSONL 而不是新建 SQLite 表：审计的首要目标是保证每次外部 agent 写入
//  都留下可追溯记录；等设置页需要筛选 / 展示 / 清理策略时，再把 JSONL 提升为正式
//  repository。当前文件采用 actor 串行追加，避免多个 MCP 请求并发写同一文件时互相覆盖。
//

import Foundation

actor StarcatMCPAuditLog {
    struct Entry: Codable, Sendable {
        let id: String
        let timestamp: String
        let tool: String
        let permission: String
        let dryRun: Bool
        let success: Bool
        let repoId: Int64?
        let repoFullName: String?
        let affectedTags: [String]
        let warnings: [String]
        let error: String?
    }

    static let shared = StarcatMCPAuditLog()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = base
            .appendingPathComponent("com.starcat.app", isDirectory: true)
            .appendingPathComponent("mcp-audit", isDirectory: true)
            .appendingPathComponent("writes.jsonl")
    }

    func record(
        tool: String,
        permission: StarcatMCPWritePermission,
        dryRun: Bool,
        success: Bool,
        repo: Repo?,
        affectedTags: [String],
        warnings: [String],
        error: String?
    ) async {
        let entry = Entry(
            id: UUID().uuidString,
            timestamp: ISO8601DateFormatter.shared.string(from: Date()),
            tool: tool,
            permission: permission.rawValue,
            dryRun: dryRun,
            success: success,
            repoId: repo?.id,
            repoFullName: repo?.fullName,
            affectedTags: affectedTags,
            warnings: warnings,
            error: error
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(entry)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            AppLog.network.error("MCP audit write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

