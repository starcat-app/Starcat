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

/// 所有写操作使用同一授权，操作种类由 action 字段区分。
enum StarcatMCPWritePermission: String, Codable, Sendable {
    case write
}

/// GitHub Star 写入结果。
///
/// `star_repo` 允许直接处理尚未进入本地数据库的 GitHub 仓库，因此 dry-run 时不一定
/// 存在 `Repo`。单独保留 `target_full_name`，让 Agent 始终能核对本次远端操作目标。
struct MCPStarWriteResult: Codable, Sendable {
    let ok: Bool
    let dry_run: Bool
    let changed: Bool
    let permission: String
    let action: String
    let target_full_name: String
    let repo: MCPRepoDTO?
    let warnings: [String]

    init(
        dryRun: Bool,
        changed: Bool,
        action: String,
        targetFullName: String,
        repo: Repo? = nil,
        warnings: [String] = []
    ) {
        self.ok = true
        self.dry_run = dryRun
        self.changed = changed
        self.permission = StarcatMCPWritePermission.write.rawValue
        self.action = action
        self.target_full_name = targetFullName
        self.repo = repo.map(MCPRepoDTO.init(repo:))
        self.warnings = warnings
    }
}

/// 批量整理请求中的单个仓库输入。
///
/// `note == nil` 表示不处理笔记，空字符串则表示清空笔记；二者不能合并，否则 Agent
/// 无法在同一批请求中区分“保持不变”和“主动清空”。
struct MCPBatchOrganizeItemInput: Sendable {
    let repoID: Int64?
    let owner: String?
    let name: String?
    let tagNames: [String]
    let note: String?
}

/// 批量整理中一个仓库的执行结果。失败项显式标记是否可能已发生部分写入，避免把
/// 跨 Repository/Capability 的顺序执行误解为数据库事务。
struct MCPBatchOrganizeItemResult: Codable, Sendable {
    let index: Int
    let ok: Bool
    let changed: Bool
    let partial_write_possible: Bool
    let repo: MCPRepoDTO
    let tag_names: [String]
    let note_requested: Bool
    let warnings: [String]
    let error: String?
}

/// 批量标签/笔记写入的汇总结果。
struct MCPBatchOrganizeResult: Codable, Sendable {
    let ok: Bool
    let dry_run: Bool
    let permission: String
    let action: String
    let requested_count: Int
    let succeeded_count: Int
    let failed_count: Int
    let changed_count: Int
    let results: [MCPBatchOrganizeItemResult]

    init(dryRun: Bool, results: [MCPBatchOrganizeItemResult]) {
        self.ok = results.allSatisfy(\.ok)
        self.dry_run = dryRun
        self.permission = StarcatMCPWritePermission.write.rawValue
        self.action = "batch_organize_repos"
        self.requested_count = results.count
        self.succeeded_count = results.filter { $0.ok }.count
        self.failed_count = results.filter { !$0.ok }.count
        self.changed_count = results.filter { $0.changed }.count
        self.results = results
    }
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
