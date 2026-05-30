//
//  TagRepositoryProtocol.swift
//  Starcat
//
//  标签 CRUD 协议（W4 Batch A1 引入）。
//
//  存在意义：把 `GRDBTagRepository` 抽象为协议，让标签管理 UI / Tags 视图 / 批量打标签
//  等调用方依赖协议而非具体 struct，便于未来注入 Mock 做单测。
//  风格与 D-01 `RepoRepositoryProtocol` 一致。
//
//  设计约束：
//  - Tag.id 由调用方生成 UUID 字符串（业务层职责，便于测试控制）
//  - Tag.name 是 SQL 层 UNIQUE 约束；调用方建议先 `findByName(_:)` 检查再 `create(_:)`
//    防止抛 GRDB.DatabaseError（友好错误提示）
//  - `delete(id:)` 通过 ON DELETE CASCADE 自动清掉 repo_tags 中所有关联行
//  - `merge(source:into:)` 是 P0 必须功能（合并重复语义标签），事务内完成
//

import Foundation

protocol TagRepositoryProtocol: Sendable {

    // MARK: - 写入

    /// 创建标签。
    /// - Throws: name 冲突会抛 GRDB.DatabaseError（UNIQUE constraint failed）
    func create(_ tag: Tag) async throws

    /// 更新标签全字段（调用方负责把 updatedAt 设为现在）。
    /// 不存在 → no-op（GRDB save 在主键存在时走 update，主键不存在走 insert；
    /// 为避免误创建，本方法明确要求"已存在"语义，调用方应先 find）。
    func update(_ tag: Tag) async throws

    /// 删除标签（ON DELETE CASCADE 会自动清掉 repo_tags / tag_stats_cache 关联行）。
    func delete(id: String) async throws

    /// 把 source 标签合并到 target：
    /// - source 下所有 repo 关联全部转到 target（冲突时跳过，不重复关联）
    /// - source 标签本身被删除
    /// 事务内完成，要么全成要么全回滚。
    func merge(source: String, into target: String) async throws

    // MARK: - 查询

    func find(id: String) async throws -> Tag?

    /// 按 name 精确查找（用于 UI 创建前去重检查）。
    func findByName(_ name: String) async throws -> Tag?

    /// 全部标签，按 sort_order asc → name asc 排序。
    func fetchAll() async throws -> [Tag]
}

// 注意：`GRDBTagRepository: TagRepositoryProtocol` 的 conformance 直接写在
// TagRepository.swift 的 struct 声明上，避免 retroactive conformance 在 Swift 6
// 语言模式下触发 `'Sendable' must occur in the same source file` 错误。
