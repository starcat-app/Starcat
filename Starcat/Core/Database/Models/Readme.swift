//
//  Readme.swift
//  Starcat
//
//  README 内容缓存，对应 `readmes` 表。
//
//  设计意图：与 repos 元数据分离，避免列表查询带出大字符串字段（README 可达数百 KB）。
//

import Foundation
import GRDB

struct Readme: Codable, FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "readmes"

    var repoId: Int64

    /// 原始 Markdown 文本。
    var content: String?

    /// 渲染后 HTML（可选，目前 WebView 端实时渲染，缓存留作未来扩展）。
    var renderedHtml: String?

    /// GitHub 返回的 ETag，用于 If-None-Match 增量校验。
    var etag: String?

    /// HTTP Last-Modified 头。
    var lastModified: String?

    /// 缓存写入时间，ISO8601。
    var cachedAt: String

    /// 内容字节数，便于按大小清理缓存。
    var size: Int

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case content
        case renderedHtml = "rendered_html"
        case etag
        case lastModified = "last_modified"
        case cachedAt = "cached_at"
        case size
    }
}
