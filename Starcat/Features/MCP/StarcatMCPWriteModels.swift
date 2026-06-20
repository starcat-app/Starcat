//
//  StarcatMCPWriteModels.swift
//  Starcat
//
//  MCP 写入工具的对外 DTO。
//
//  这些模型是 agent 写入结果的稳定协议边界：工具不要直接返回内部 GRDB record，
//  而是统一返回 ok / dry_run / changed / warnings，方便外部 agent 判断是否需要重试
//  或把结果展示给用户确认。
//

import Foundation

/// MCP 写入权限等级。
enum StarcatMCPWritePermission: String, Codable, Sendable {
    case localWrite = "local_write"
    case batchWrite = "batch_write"
    case destructiveWrite = "destructive_write"
}

/// MCP 写入工具统一返回格式。
struct MCPWriteResult: Codable, Sendable {
    let ok: Bool
    let dry_run: Bool
    let changed: Bool
    let permission: String
    let action: String
    let repo: MCPRepoDTO?
    let note: MCPRepoNoteDTO?
    let tags: [MCPTagDTO]
    let warnings: [String]

    init(
        ok: Bool = true,
        dryRun: Bool,
        changed: Bool,
        permission: StarcatMCPWritePermission,
        action: String,
        repo: Repo? = nil,
        note: RepoNote? = nil,
        tags: [Tag] = [],
        warnings: [String] = []
    ) {
        self.ok = ok
        self.dry_run = dryRun
        self.changed = changed
        self.permission = permission.rawValue
        self.action = action
        self.repo = repo.map(MCPRepoDTO.init(repo:))
        self.note = note.map(MCPRepoNoteDTO.init(note:))
        self.tags = tags.map(MCPTagDTO.init(tag:))
        self.warnings = warnings
    }
}

