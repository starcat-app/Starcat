//
//  SearchHistoryRepositoryProtocol.swift
//  Starcat
//
//  搜索历史 Repository 协议。
//
//  设计约束：
//  - **大小写不敏感去重**：`record("Swift")` 和 `record("swift")` 视作同一条；
//    保留最近一次输入的原始大小写到 `query` 字段（小写归一存 `query_lower`，UNIQUE 索引）。
//  - **首次记录**：useCount = 1，first_seen_at = last_used_at = modified_at = now。
//  - **后续命中**：useCount += 1，last_used_at = modified_at = now，first_seen_at 不变，
//    `query` 字段被刷新为最新一次输入的大小写（用户最近一次怎么写就显示成什么）。
//  - **总数上限 50**：超出后按 `decayedScore` 升序淘汰最低者（沉底的老低频项先走）。
//    限制写在 Repository 层，UI 层不感知。
//  - **删除走物理 DELETE**（W5 接入 CloudKit 之前）；CloudKit 接入后改 tombstone 机制。
//

import Foundation

protocol SearchHistoryRepositoryProtocol: Sendable {

    /// 取全部历史，按 `last_used_at DESC` 数据库预排序后返回。
    /// UI 层再用 `SearchHistory.decayedScore(halfLifeDays:)` 内存里按分数排序。
    ///
    /// 数据库不直接按分数排序的原因：SQLite 不内置 `pow()`，自定义函数注册成本不必要
    /// （表上限 50 条，内存排序耗时远低于 1ms）。
    func fetchAll() async throws -> [SearchHistory]

    /// 记录一次提交。
    /// - 已存在（`query_lower` 命中）→ `useCount += 1`，刷新 `last_used_at` / `modified_at` /
    ///   `query`（保留最新大小写）。
    /// - 不存在 → 新建一条 `useCount = 1`，timestamps 全部 = now，如有需要淘汰最低分项。
    /// 空白 / trim 后为空的 query 直接返回，不持久化。
    func record(_ query: String) async throws

    /// 按 `query_lower` 删除单条。query 大小写不敏感。
    /// 不存在 → no-op。
    func remove(query: String) async throws

    /// 清空整表。
    func clearAll() async throws
}

// 注意：`GRDBSearchHistoryRepository: SearchHistoryRepositoryProtocol` 的 conformance 直接写在
// `SearchHistoryRepository.swift` 的 struct 声明上，避免 retroactive conformance 在 Swift 6
// 语言模式下触发 `'Sendable' must occur in the same source file` 错误（与 RepoNoteRepository 同理）。
