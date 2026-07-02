//
//  RepoNoteRepositoryProtocol.swift
//  Starcat
//
//  仓库私有笔记 + 状态管理协议（W4 Batch A1 引入）。
//
//  `repo_notes` 表同时承载笔记内容（content）、阅读状态（status）与 Starcat 私有
//  知识库状态（library_state）。
//  设计目的：这些都是"一 repo 至多一条用户私有数据"，合并到同张表简化 CRUD。
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

    /// 查询单个 repo 的知识库状态。没有 repo_notes 行时按未入库处理。
    func fetchLibraryState(repoId: Int64) async throws -> LibraryState

    /// 批量查询知识库状态映射；未出现的 repo 由调用方按 `.outsideLibrary` 处理。
    func fetchLibraryStateMap(repoIds: [Int64]) async throws -> [Int64: LibraryState]

    /// 查询所有已写入的知识库状态映射；未写过 repo_notes 的 repo 不在 map 内。
    func fetchAllLibraryStateMap() async throws -> [Int64: LibraryState]

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

    /// 返回有非空笔记内容的 repo id（Smart Collections `requireNote` 过滤用）。
    func fetchRepoIdsWithNonEmptyContent() async throws -> Set<Int64>

    /// 每个状态下的 repo 数量（Sidebar 状态分组渲染用，一次拉全部）。
    /// 注意：从未写过 repo_notes 行的 repo 不算 "unread"（它压根没记录），
    /// 不在本统计内。UI 端如需"未读 = 全部 - 已写笔记 + 笔记 status=unread" 自行计算。
    func statusCounts() async throws -> [RepoStatus: Int]

    /// 每个知识库状态下的 repo_notes 行数量；集合总数会在 RepoRepository 侧按 repo scope 统计。
    func libraryStateCounts() async throws -> [LibraryState: Int]

    // MARK: - 写入

    /// 整记录 upsert（同时落 content + status，调用方负责把 editedAt 设为现在）。
    func upsert(_ note: RepoNote) async throws

    /// 仅更新笔记内容。不存在的 repo_notes 行会被自动创建（status 默认 "unread"）。
    /// editedAt 自动设为 now。
    func updateContent(repoId: Int64, content: String?) async throws

    /// 仅更新状态。不存在的 repo_notes 行会被自动创建（content 为 nil）。
    /// editedAt 自动设为 now。
    /// 关键约束：设置 `.using` 时会同步入库；从 `.using` 改回其他状态不会自动移出知识库。
    func updateStatus(repoId: Int64, status: RepoStatus) async throws

    /// 仅更新 Starcat 私有知识库状态。
    ///
    /// - `.inLibrary`：行不存在时创建 unread 行并写入 `library_updated_at`。
    /// - `.outsideLibrary`：行不存在时 no-op，避免为了默认状态制造空用户数据。
    /// - 只有状态实际变化时才更新 `library_updated_at`。
    func updateLibraryState(repoId: Int64, state: LibraryState) async throws

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
