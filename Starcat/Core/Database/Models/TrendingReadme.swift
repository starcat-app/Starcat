//
//  TrendingReadme.swift
//  Starcat
//
//  Trending README 缓存的 GRDB 行模型，对应 v4 迁移的 `trending_readmes` 表。
//
//  设计动机：
//  - manage 路径用 `Readme`（PK = `repo_id: Int64`）持久化 README HTML，但 trending repo
//    没有真实的 GitHub repo id，只有 `owner/name`，无法复用 `readmes` 表的 PK。
//  - 单独建 `trending_readmes`（PK = `full_name: String`）让两条路径完全隔离：
//    a) 取消 star 时 cascade 删 `readmes` 不会牵连 trending 缓存
//    b) 离线兜底时按 owner/repo 路径直接查，与 manage 的 repo_id 路径互不污染
//
//  字段语义与 manage 的 `Readme` 完全对齐（rendered_html / etag / last_modified / cached_at / size），
//  让 `ReadmeAPI` 可以复用同一套 SWR + ETag 304 + 大小统计逻辑。
//
//  关键约束：
//  - PK 是 `full_name`（TEXT）：String 类型在 GRDB 中作主键完全合法，
//    `MutablePersistableRecord.upsert` 也支持。
//  - `cachedAt` 是 NOT NULL，因为有缓存就一定有时间戳；与表层约束对齐。
//  - 不挂任何外键 / FTS：trending 缓存是独立、临时性数据，不与用户数据表关联。
//

import Foundation
import GRDB

/// `trending_readmes` 表行映射。
struct TrendingReadme: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "trending_readmes"

    /// PK：`owner/name`，与 `TrendingRepo.fullName` 对齐
    var fullName: String

    /// GitHub 服务端渲染的 README HTML。可选——404 / 边缘 case 下可能为 nil。
    var renderedHtml: String?

    /// GitHub 返回的 ETag，用于 If-None-Match 增量校验。
    var etag: String?

    /// HTTP Last-Modified 头。
    var lastModified: String?

    /// 缓存写入时间，ISO8601 字符串。仅用于"缓存于 X 时间前"展示。
    var cachedAt: String

    /// HTML 字节数，便于"清理缓存"统计或按大小排序清理。
    var size: Int

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case renderedHtml = "rendered_html"
        case etag
        case lastModified = "last_modified"
        case cachedAt = "cached_at"
        case size
    }
}
