//
//  RepoRepositoryProtocol.swift
//  Starcat
//
//  Repo 持久化协议（D-01 引入）。
//
//  存在意义：把 `GRDBRepoRepository` 抽象为协议，让 `HomeViewModel` / `SyncManager` 等
//  调用方依赖协议而非具体 struct，从而能写"完全脱离数据库"的单元测试
//  （把 Mock 实现塞到测试 target 即可，不需要起 GRDB writer）。
//
//  设计取舍：
//  - 9 个方法纳入协议：covers HomeViewModel + SyncManager 所有依赖路径
//  - **不纳入协议**：
//    - `topStarred(limit:)` — 调试/快速验证用，无生产调用方
//    - static `repoFromDTO(_:starredAt:cachedAt:)` — DTO → Model 静态工厂，
//      与 Repository 实例状态无关，调用方应直接走 `GRDBRepoRepository.repoFromDTO`
//      或 P1-1 完成后改为 DTO extension（D-06）
//  - `Sendable`：struct + value type 自动 Sendable；mock 实现需注意 isolation
//
//  Mock 落地（D-14 配套后续）：测试 target 写 `struct MockRepoRepository: RepoRepositoryProtocol`，
//  每个 method 用闭包 / 静态 fixture 控制返回值。
//
//  文件命名：与 GitHubAPIClientProtocol 同风格独立成文件；
//  具体实现 `GRDBRepoRepository` 保留在 `RepoRepository.swift`（文件名不改，
//  避免大幅触动 .pbxproj；详见 RepoRepository.swift 头注释）。
//

import Foundation

protocol RepoRepositoryProtocol: Sendable {

    // MARK: - Upsert / 取消 Star 标记

    /// 批量 upsert 一组 starred repos。
    func upsertStarred(_ dtos: [StarredRepoDTO], userID: Int64, syncedAt: Date) async throws

    /// 将本地存在但不在远端集合中的 repo 标记为 is_starred = false。
    func markUnstarredExcept(remoteRepoIDs: Set<Int64>, userID: Int64) async throws

    // MARK: - 查询

    /// 当前用户已 star 的 repo 总数。
    func starredCount() async throws -> Int

    /// 全部已 star 的 repo（按 starred_at 倒序）。
    func fetchAllStarred() async throws -> [Repo]

    /// 未打标签的 repo。
    func fetchUntagged() async throws -> [Repo]

    /// 按语言筛选 repo（nil 表示无语言）。
    func fetchByLanguage(_ language: String?) async throws -> [Repo]

    /// 语言聚合统计。
    func languageStats() async throws -> [LanguageStat]

    /// FTS5 全文搜索（空 query 退化为 fetchAllStarred）。
    func searchFTS(query: String) async throws -> [Repo]

    // MARK: - 同步状态

    /// 更新 sync_state 表中当前用户的同步统计。
    func updateSyncState(userID: Int64, starredCount: Int, syncedCount: Int, status: String) async throws
}

// MARK: - Conformance

/// `GRDBRepoRepository` 已实现所有要求的方法，这里空 conformance 即可。
extension GRDBRepoRepository: RepoRepositoryProtocol {}
