//
//  GitHubStarListRepositoryProtocol.swift
//  Starcat
//
//  GitHub Stars List 本地缓存协议。
//
//  设计约束：
//  - GitHub 是分组关系的远端真源；完整同步使用快照覆盖。
//  - 正常写入仍以 mutation 成功为准；只有明确的组织 OAuth 限制才保存本地覆盖。
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

    /// 保存单个 list：nil 保留已有颜色，空字符串清除颜色；新 list 默认无图标
    func upsertList(_ remote: GitHubStarListRemoteRecord, colorHex: String?, syncedAt: Date) async throws

    /// 删除一个 list，本地 membership 依赖外键级联清理。
    func deleteList(id: String) async throws

    /// 替换某 repo 的 GitHub List 集合。
    func setListIds(forRepo repoId: Int64, listIds: [String]) async throws

    /// 保存某 repo 的完整本地期望；Repository 只落与当前远端快照不同的覆盖行。
    func setLocalListIds(
        forRepo repoId: Int64,
        listIds: [String],
        failureReason: String
    ) async throws

    // MARK: - 查询

    func fetchAllLists() async throws -> [GitHubStarList]

    func findList(id: String) async throws -> GitHubStarList?

    func listIds(forRepo repoId: Int64) async throws -> [String]

    /// 只读取 GitHub 已确认的远端关系，不合并本地覆盖。
    func remoteListIds(forRepo repoId: Int64) async throws -> [String]

    /// 当前仓库是否仍有尚未回写 GitHub 的本地 membership 差异。
    func hasLocalListOverrides(forRepo repoId: Int64) async throws -> Bool

    /// 返回所有仍需回写 GitHub 的本地期望；每个仓库只生成一个精确目标集合。
    func fetchPendingLocalMembershipSyncs() async throws -> [GitHubStarListPendingMembershipSync]

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

    // MARK: - Starcat AI 自动忽略

    /// 只返回仍为 starred 且未分组的仓库；其它历史行不应污染下一轮预检统计。
    func fetchAIAutoIgnoredRepos() async throws -> [GitHubStarListAIAutoIgnoredRepo]

    func upsertAIAutoIgnoredRepo(_ record: GitHubStarListAIAutoIgnoredRepo) async throws

    func deleteAIAutoIgnoredRepo(repoId: Int64) async throws
}
