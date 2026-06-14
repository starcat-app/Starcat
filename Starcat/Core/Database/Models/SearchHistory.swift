//
//  SearchHistory.swift
//  Starcat
//
//  用户搜索历史记录，对应 `search_history` 表。
//
//  设计要点（与 `docs/CloudKit数据同步设计.md` 对齐）：
//
//  - **CloudKit-ready 字段**：`id` 用 UUID（不依赖数据库自增 PK，CloudKit recordID 友好）、
//    所有时间戳走 ISO8601 字符串（`modifiedAt` 用于 LWW 冲突合并）、删除走 tombstone 机制
//    （由未来 CloudKit 同步层处理，本期暂不引入 tombstone 表，因为 UI 单设备情况下直接
//    `DELETE` 即可；接入 CloudKit 时再补 tombstone 表，跟 Tag/RepoNote 一致）。
//  - **冲突合并策略**（W5 CloudKit 接入时）：modifiedAt 较新者整体取优，但
//    `useCount = max(local, remote)` —— 避免 "Mac 搜了 5 次、iPhone 搜了 3 次，
//    同步后只剩 3 次" 的明显计数倒退；这是本表与 Tag/RepoNote 纯 LWW 的唯一差异。
//  - **去重键**：`query_lower`（lowercased）唯一索引；原始大小写保留在 `query` 字段
//    便于 UI 显示。例如 "Swift" 和 "swift" 视为同一条记录，但显示最近一次输入的大小写。
//  - **排序公式**：内存中按 `useCount × 0.5^(daysSinceLastUsed / halfLifeDays)` 降序，
//    UI 层调 `decayedScore(halfLifeDays:)` 一次拿到分数；SQLite 不做 pow 计算（GRDB 不内置）。
//
//  字段对照（`DatabaseMigrationsV1.createSearchHistory`）：
//    id              TEXT PRIMARY KEY      -- UUID 字符串
//    query           TEXT NOT NULL         -- 用户输入原文（保留大小写）
//    query_lower     TEXT NOT NULL UNIQUE  -- 小写归一，去重 + 查询用
//    use_count       INTEGER NOT NULL DEFAULT 1
//    last_used_at    TEXT NOT NULL         -- ISO8601，排序衰减 + UI 显示
//    first_seen_at   TEXT NOT NULL         -- ISO8601，首次记录
//    modified_at     TEXT NOT NULL         -- ISO8601，CloudKit LWW 用
//

import Foundation
import GRDB

struct SearchHistory: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Sendable {

    static let databaseTableName = "search_history"

    /// UUID 字符串。CloudKit 同步时直接做 recordName。
    var id: String

    /// 用户输入的原始关键词，保留输入时的大小写（如 "Swift"）。
    var query: String

    /// `query.lowercased()`，去重 + LIKE 查询用。
    var queryLower: String

    /// 累计使用次数。每次 `record(_:)` 同 query 命中时 +1。
    var useCount: Int

    /// 最近一次使用的 ISO8601 时间戳。排序衰减的 t0 参考点。
    var lastUsedAt: String

    /// 首次记录的 ISO8601 时间戳。仅用于 UI 显示（如 "首次添加于 3 个月前"），
    /// 不参与排序。
    var firstSeenAt: String

    /// 任意字段最近一次变更的 ISO8601 时间戳。CloudKit LWW 用。
    var modifiedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case query
        case queryLower = "query_lower"
        case useCount = "use_count"
        case lastUsedAt = "last_used_at"
        case firstSeenAt = "first_seen_at"
        case modifiedAt = "modified_at"
    }
}

extension SearchHistory {

    /// 半衰期衰减分数：`useCount × 0.5^(daysSinceLastUsed / halfLifeDays)`。
    ///
    /// **效果直观例子**（halfLifeDays = 14 默认）：
    /// - 新关键词（useCount=1，今天）：score = 1.0
    /// - 老关键词（useCount=10，14 天前用过）：score = 5.0 —— 半衰一次仍排在新关键词前
    /// - 老关键词（useCount=10，28 天前用过）：score = 2.5
    /// - 极老关键词（useCount=10，90 天前用过）：score = 0.12 —— 沉底
    ///
    /// **`lastUsedAt` 解析失败时返回 useCount**（不衰减）—— 数据脏的情况下保守地按
    /// 频次排序，不让历史记录因为时间戳格式问题被错误地排到最底；后续 CloudKit
    /// 同步如果偶发收到非标准格式也走这个 fallback。
    func decayedScore(now: Date = Date(), halfLifeDays: Double = 14) -> Double {
        guard let lastUsed = ISO8601DateFormatter.shared.date(from: lastUsedAt) else {
            return Double(useCount)
        }
        let daysSinceLastUsed = now.timeIntervalSince(lastUsed) / 86_400
        // 极端情况：lastUsedAt 比 now 还新（设备时钟漂移），daysSinceLastUsed < 0，
        // 此时 0.5^负数 > 1 会放大分数；clamp 到 0 避免异常。
        let clampedDays = max(0, daysSinceLastUsed)
        let decayFactor = pow(0.5, clampedDays / halfLifeDays)
        return Double(useCount) * decayFactor
    }
}
