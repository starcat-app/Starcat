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
//  HOM-201 P2-1(2026-06-14):`rendered_html` 列由 TEXT 改为 BLOB,与 `Readme` 同款
//  zlib 透明压缩;Codable 自动派生不再适用,自实现 init(row:) / encode(to container:)。
//  详见 `ReadmeHTMLCodec` 文件头与 `Readme.swift`。
//

import Foundation
import GRDB

/// `trending_readmes` 表行映射。
struct TrendingReadme: FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "trending_readmes"

    /// PK：`owner/name`，与 `TrendingRepo.fullName` 对齐
    var fullName: String

    /// GitHub 服务端渲染的 README HTML。可选——404 / 边缘 case 下可能为 nil。
    ///
    /// HOM-201 P2-1:对外 String? 不变,持久化层透明压缩(see `ReadmeHTMLCodec`)。
    var renderedHtml: String?

    /// GitHub 返回的 ETag，用于 If-None-Match 增量校验。
    var etag: String?

    /// HTTP Last-Modified 头。
    var lastModified: String?

    /// 缓存写入时间，ISO8601 字符串。仅用于"缓存于 X 时间前"展示。
    var cachedAt: String

    /// HTML 字节数(明文),便于"清理缓存"统计或按大小排序清理。
    ///
    /// HOM-201 P2-1:仍是明文 utf-8 字节数;LRU 决策口径稳定(磁盘实占 ≈ size / 5-7)。
    var size: Int

    /// 用于显式构造(测试 / ReadmeAPI / promote 等场景)。
    init(
        fullName: String,
        renderedHtml: String?,
        etag: String?,
        lastModified: String?,
        cachedAt: String,
        size: Int
    ) {
        self.fullName = fullName
        self.renderedHtml = renderedHtml
        self.etag = etag
        self.lastModified = lastModified
        self.cachedAt = cachedAt
        self.size = size
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) {
        self.fullName = row["full_name"]
        let blob: Data? = row["rendered_html"]
        self.renderedHtml = ReadmeHTMLCodec.decode(blob)
        self.etag = row["etag"]
        self.lastModified = row["last_modified"]
        self.cachedAt = row["cached_at"]
        self.size = row["size"]
    }

    // MARK: - GRDB MutablePersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["full_name"] = fullName
        container["rendered_html"] = ReadmeHTMLCodec.encode(renderedHtml)
        container["etag"] = etag
        container["last_modified"] = lastModified
        container["cached_at"] = cachedAt
        container["size"] = size
    }
}
