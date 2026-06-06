//
//  RepoTagRepositoryProtocol.swift
//  Starcat
//
//  Repo ↔ Tag 多对多关联协议（W4 Batch A1 引入）。
//
//  与 `TagRepositoryProtocol` 拆开两个文件的理由：
//  - 职责清晰：Tag CRUD（前者）vs 关系维护 + join 查询（本者）
//  - 单测更聚焦：tag 命名冲突 / 合并测试和 repo 打标签测试可分别独立
//
//  设计约束：
//  - `addTag` / `batchAddTag` 用 INSERT OR IGNORE，多次 add 同一对是 no-op（不抛错）
//  - `setTags(repoId:tagIds:)` 是替换式（delete + batch insert），便于 picker"一次提交"
//  - `fetchRepos(forTag:)` 返回 [Repo]，按 starred_at desc，对接 Sidebar 按标签筛选
//

import Foundation

protocol RepoTagRepositoryProtocol: Sendable {

    // MARK: - 单 repo 操作

    /// 给单个 repo 打一个标签。已存在该关联时 no-op（INSERT OR IGNORE）。
    func addTag(repoId: Int64, tagId: String) async throws

    /// 移除单个 repo 的某个标签。不存在时 no-op。
    func removeTag(repoId: Int64, tagId: String) async throws

    /// 替换式更新：先删该 repo 的所有标签，再批量添加新集合。
    /// 适合"打标签 picker 一次性提交"语义。事务内完成。
    func setTags(repoId: Int64, tagIds: [String]) async throws

    // MARK: - 批量

    /// 批量给一组 repo 加同一个标签。事务 + INSERT OR IGNORE。
    /// 适合"列表多选 → 批量打标签"用例。
    func batchAddTag(repoIds: [Int64], tagId: String) async throws

    // MARK: - 查询

    /// 某 repo 的标签 ID 列表。
    func fetchTagIds(forRepo repoId: Int64) async throws -> [String]

    /// 某 repo 的完整标签（join tags，按 sort_order/name 排序）。
    func fetchTags(forRepo repoId: Int64) async throws -> [Tag]

    /// 某标签下的所有 repo（join repos，按 starred_at desc，仅 is_starred=1）。
    func fetchRepos(forTag tagId: String) async throws -> [Repo]

    /// 某标签下的 repo 数量（用于 Sidebar Tags 行显示计数）。
    func repoCount(forTag tagId: String) async throws -> Int

    /// 一次性返回所有标签的 repo 计数（Sidebar Tags 渲染一次拉全部）。
    /// 返回 dict：tagId → count。
    func repoCountsByTag() async throws -> [String: Int]

    /// 一次性返回所有 starred repo 的标签关联，按 (repo_id, tag.sort_order, tag.name) 排序。
    ///
    /// 给"导出 Starred 列表为 HTML"这类一次性把全部 repo 的标签都取走的场景用，
    /// 避免 N+1（N 个 repo 各调一次 `fetchTags(forRepo:)`）。返回 dict：repoId → [Tag]。
    /// 无标签的 repo 不在 dict 中（调用方需自行兜底空数组语义）。
    func fetchAllTagAssignments() async throws -> [Int64: [Tag]]
}

// 注意：`GRDBRepoTagRepository: RepoTagRepositoryProtocol` 的 conformance 直接写在
// RepoTagRepository.swift 的 struct 声明上，避免 retroactive conformance 在 Swift 6
// 语言模式下触发 `'Sendable' must occur in the same source file` 错误。
