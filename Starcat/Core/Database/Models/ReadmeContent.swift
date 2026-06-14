//
//  ReadmeContent.swift
//  Starcat
//
//  raw Markdown 文本缓存,对应 `readme_contents` 表(HOM-201 P2-2,2026-06-14)。
//
//  ────────────────────────────────────────────────────────────────────────────
//  动机
//  ────────────────────────────────────────────────────────────────────────────
//
//  原 `readmes.content` 字段是 raw Markdown,**只有 AI / 向量索引**少数路径用,
//  详情页 WebView 走 `rendered_html`。原 schema 让详情页每次 `find(repoId:)`
//  都把几百 KB markdown 一起拉回内存,纯浪费 IO 与内存。拆表后:
//   - `Readme.fetchOne(...)` 只回元数据 + 压缩 HTML;
//   - `ReadmeContent.fetchOne(...)` 显式拉 markdown(AI / 向量索引专用)。
//
//  ────────────────────────────────────────────────────────────────────────────
//  压缩
//  ────────────────────────────────────────────────────────────────────────────
//
//  `content` 列为 `.blob`,用 `ReadmeHTMLCodec`(zlib)透明压缩。Markdown 是结构化
//  文本,压缩比 3-5x。`size` 字段同 `Readme.size`,仍是明文 utf-8 字节数。
//

import Foundation
import GRDB

struct ReadmeContent: FetchableRecord, MutablePersistableRecord, Equatable {

    static let databaseTableName = "readme_contents"

    /// PK,与 `readmes.repo_id` / `repos.id` 对齐(FK ON DELETE CASCADE)。
    var repoId: Int64

    /// 原始 Markdown 文本(明文)。
    ///
    /// 持久化层透明压缩(see `ReadmeHTMLCodec`,与 rendered_html 共用同套 codec)。
    var content: String?

    /// 写入时间,ISO8601。
    var cachedAt: String

    /// 明文字节数(`content.utf8.count`)。
    var size: Int

    init(repoId: Int64, content: String?, cachedAt: String, size: Int) {
        self.repoId = repoId
        self.content = content
        self.cachedAt = cachedAt
        self.size = size
    }

    // MARK: - GRDB

    init(row: Row) {
        self.repoId = row["repo_id"]
        let blob: Data? = row["content"]
        self.content = ReadmeHTMLCodec.decode(blob)
        self.cachedAt = row["cached_at"]
        self.size = row["size"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["repo_id"] = repoId
        container["content"] = ReadmeHTMLCodec.encode(content)
        container["cached_at"] = cachedAt
        container["size"] = size
    }
}
