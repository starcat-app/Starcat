//
//  Readme.swift
//  Starcat
//
//  README 内容缓存，对应 `readmes` 表。
//
//  设计意图：与 repos 元数据分离，避免列表查询带出大字符串字段（README 可达数百 KB）。
//
//  HOM-201 P2-1(2026-06-14):`rendered_html` 列由 TEXT 改为 BLOB,应用层用 zlib 透明
//  压缩。Model 对外仍持 `renderedHtml: String?`(UI 层 / ReadmeAPI 无感),由
//  `ReadmeHTMLCodec` 在 `init(row:)` / `encode(to container:)` 边界做编解码;
//  Codable 自动派生不再适用(String? ↔ BLOB 映射需手写)。
//
//  HOM-201 P2-2(2026-06-14):原 `content` 字段(raw Markdown)拆到独立表 / 独立 Model
//  `ReadmeContent`(对应 `readme_contents` 表),让默认 `find(repoId:)` 不再带出
//  几百 KB markdown body。AI / 向量索引等"纯文本消费方"显式调
//  `ReadmeRepository.findContent(repoId:)` 拉 markdown。
//

import Foundation
import GRDB

struct Readme: FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "readmes"

    var repoId: Int64

    /// 渲染后 HTML(GitHub 服务端渲染,WebView 显示用)。
    ///
    /// HOM-201 P2-1:对外 String? 不变,持久化层透明压缩(see `ReadmeHTMLCodec`)。
    var renderedHtml: String?

    /// GitHub 返回的 ETag，用于 If-None-Match 增量校验。
    var etag: String?

    /// HTTP Last-Modified 头。
    var lastModified: String?

    /// 缓存写入时间，ISO8601。
    var cachedAt: String

    /// 内容字节数(明文),便于按大小清理缓存与 LRU 决策。
    ///
    /// HOM-201 P2-1:仍是明文 utf-8 字节数;磁盘实际占用 ≈ size / 5-7(zlib 压缩比)。
    /// LRU 决策口径(明文 size)不变,与压缩前体验对齐。
    var size: Int

    /// 用于显式构造(测试 / ReadmeAPI / promote 等场景)。
    init(
        repoId: Int64,
        renderedHtml: String?,
        etag: String?,
        lastModified: String?,
        cachedAt: String,
        size: Int
    ) {
        self.repoId = repoId
        self.renderedHtml = renderedHtml
        self.etag = etag
        self.lastModified = lastModified
        self.cachedAt = cachedAt
        self.size = size
    }

    // MARK: - GRDB FetchableRecord

    /// 从数据库行解码。`rendered_html` 列是 zlib BLOB,经 `ReadmeHTMLCodec.decode`
    /// 还原为明文 String;解压失败兜底 nil,行本身仍可 fetch 出来。
    init(row: Row) {
        self.repoId = row["repo_id"]
        let blob: Data? = row["rendered_html"]
        self.renderedHtml = ReadmeHTMLCodec.decode(blob)
        self.etag = row["etag"]
        self.lastModified = row["last_modified"]
        self.cachedAt = row["cached_at"]
        self.size = row["size"]
    }

    // MARK: - GRDB MutablePersistableRecord

    /// 写入数据库行。`renderedHtml` String 经 `ReadmeHTMLCodec.encode` 压缩为 zlib BLOB
    /// 落到 `rendered_html` 列。`size` 仍是明文字节数(LRU 口径稳定)。
    func encode(to container: inout PersistenceContainer) {
        container["repo_id"] = repoId
        container["rendered_html"] = ReadmeHTMLCodec.encode(renderedHtml)
        container["etag"] = etag
        container["last_modified"] = lastModified
        container["cached_at"] = cachedAt
        container["size"] = size
    }
}
