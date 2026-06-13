//
//  RepoNoteRepositoryProtocol.swift
//  Starcat
//
//  仓库私有笔记 + 状态管理协议（W4 Batch A1 引入）。
//
//  `repo_notes` 表同时承载笔记内容（content）与阅读状态（status，对应 RepoStatus enum）。
//  设计目的：两者都是"一 repo 至多一条用户数据"，合并到同张表简化 CRUD。
//  CloudKit 同步时也作为同一条记录的不同字段处理。
//
//  设计约束：
//  - 一个 repo 最多一行（repo_id 是主键）
//  - status 是 NOT NULL，缺省 "unread"
//  - 第一次写入时若调用 `updateContent` / `updateStatus` 且 repo 未 ever 写过，
//    会自动创建一行（content 或 status 之一为 nil，另一边落默认值）
//

import Foundation

protocol RepoNoteRepositoryProtocol: Sendable {

    // MARK: - 查询

    /// 找该 repo 的笔记 + 状态行。未写过返回 nil。
    func find(repoId: Int64) async throws -> RepoNote?

    /// 批量找一组 repo 的状态映射（用于列表角标，避免 N+1）。
    func fetchStatusMap(repoIds: [Int64]) async throws -> [Int64: RepoStatus]

    /// 全表 status 映射（HOM-46 性能优化，2026-06-02）。
    ///
    /// 设计理由：HomeViewModel.reloadItems 之前先 fetch repos，再用 fetched.map(\.id)
    /// 调 `fetchStatusMap(repoIds:)`，串行依赖导致两次 IO 不能并行。
    /// `repo_notes` 表只在「用户主动标过状态 / 写过笔记」时才有行（通常几十到几百条），
    /// 全表查的成本远低于一次 `IN (1810 个参数)` 的解析 + 串行 round-trip。
    ///
    /// 改用本方法后调用方可以 `async let` 与 repo fetch 真正并行。
    /// 多余的 mapping（非 starred 仓库的 status）在 caller 端按 repo.id 查找时天然忽略，无副作用。
    func fetchAllStatusMap() async throws -> [Int64: RepoStatus]

    /// 按状态查询 repo（用于 §3.5 按状态过滤）。
    /// - 仅返回 is_starred=1 的 repo
    /// - 按 starred_at desc 排序
    func fetchRepos(byStatus status: RepoStatus) async throws -> [Repo]

    /// 每个状态下的 repo 数量（Sidebar 状态分组渲染用，一次拉全部）。
    /// 注意：从未写过 repo_notes 行的 repo 不算 "unread"（它压根没记录），
    /// 不在本统计内。UI 端如需"未读 = 全部 - 已写笔记 + 笔记 status=unread" 自行计算。
    func statusCounts() async throws -> [RepoStatus: Int]

    // MARK: - 写入

    /// 整记录 upsert（同时落 content + status，调用方负责把 editedAt 设为现在）。
    func upsert(_ note: RepoNote) async throws

    /// 仅更新笔记内容。不存在的 repo_notes 行会被自动创建（status 默认 "unread"）。
    /// editedAt 自动设为 now。
    func updateContent(repoId: Int64, content: String?) async throws

    /// 仅更新状态。不存在的 repo_notes 行会被自动创建（content 为 nil）。
    /// editedAt 自动设为 now。
    func updateStatus(repoId: Int64, status: RepoStatus) async throws

    /// 自动状态机：把 `unread` 提升为 `read`（README 加载完成后由 UI 层调用）。
    ///
    /// **语义保证（重要约束）**：
    /// - 行不存在 → 插入新行，status = `read`
    /// - 行存在且 status = `unread` → 升级为 `read`
    /// - 行存在且 status = `read` / `using` → **不动**（幂等；避免覆盖用户手动标过的 using）
    ///
    /// 这个方法专为「README 加载完成时静默升级」设计，与 `updateStatus` 的区别是
    /// **绝不下行**（不会从 using 退回 read）。UI 层可以无脑调，不需要先 find 判断当前状态。
    /// editedAt 仅在真正发生变更时更新，避免无意义改动触发 CloudKit 同步。
    func markAsReadIfNeeded(repoId: Int64) async throws
}

// 注意：`GRDBRepoNoteRepository: RepoNoteRepositoryProtocol` 的 conformance 直接写在
// RepoNoteRepository.swift 的 struct 声明上，避免 retroactive conformance 在 Swift 6
// 语言模式下触发 `'Sendable' must occur in the same source file` 错误。
