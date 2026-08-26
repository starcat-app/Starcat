//
//  GitHubStarListRepositoryProtocol.swift
//  Starcat
//
//  GitHub Stars List 本地缓存协议。
//
//  设计约束：
//  - GitHub 是分组关系的远端真源；完整同步使用快照覆盖。
//  - 用户主动 mutation 成功后才写本地，避免乐观更新导致 UI 与 GitHub 分叉。
//  - `未分组` 是查询语义，不落数据库实体。
//

import Foundation

protocol GitHubStarListRepositoryProtocol: Sendable {

    // MARK: - 同步写入

    /// 用 GitHub 远端完整快照覆盖本地 list 与 membership。
    func replaceRemoteSnapshot(
        lists: [GitHubStarListRemoteRecord],
        memberships: [GitHubStarListRemoteMembership],
        syncedAt: Date
    ) async throws

    /// 保存单个 list。已有 list 的本地颜色默认保留；传入 `colorHex` 时显式覆盖颜色。
    func upsertList(_ remote: GitHubStarListRemoteRecord, colorHex: String?, syncedAt: Date) async throws

    /// 删除一个 list，本地 membership 依赖外键级联清理。
    func deleteList(id: String) async throws

    /// 替换某 repo 的 GitHub List 集合。
    func setListIds(forRepo repoId: Int64, listIds: [String]) async throws

    // MARK: - 查询

    func fetchAllLists() async throws -> [GitHubStarList]

    func findList(id: String) async throws -> GitHubStarList?

    func listIds(forRepo repoId: Int64) async throws -> [String]

    /// 一次性返回所有真实 list 的 starred repo 计数。
    func repoCountsByList() async throws -> [String: Int]

    /// 虚拟「未分组」计数。
    func ungroupedRepoCount() async throws -> Int

    /// 一次性返回所有 starred repo 的 GitHub List 关联。
    func fetchAllListAssignments() async throws -> [Int64: [GitHubStarList]]

    // MARK: - Starcat AI 分组规则

    /// 保存 Starcat 本地规则。该数据不会进入 GitHub List mutation。
    func upsertAIRule(_ rule: GitHubStarListAIRule) async throws

    func findAIRule(listId: String) async throws -> GitHubStarListAIRule?

    func fetchAllAIRules() async throws -> [GitHubStarListAIRule]
}
