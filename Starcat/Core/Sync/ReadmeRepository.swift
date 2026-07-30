//
//  ReadmeRepository.swift
//  Starcat
//
//  README 缓存 Repository。
//
//  职责：
//  - 对接 `readmes` 表（schema 见 DatabaseMigrationsV1.createReadmes）
//  - 读取已缓存 README（含 etag / last_modified，用于 If-None-Match 增量校验）
//  - upsert 新拉到的 HTML
//  - 按 repo 删除（取消 star 或主动清缓存时调用）
//
//  设计约束：
//  - 与 RepoRepository 同构（同一个 DatabaseManaging 注入），方便 AppDependencies 统一组装
//  - 不直接持有 DatabaseManager 单例
//  - 读写都 async；GRDB 在内部用专属 dispatch queue，避免阻塞主线程
//
//  字段语义：
//  - content：原始 Markdown（当前阶段未使用，留作 P2 翻译/AI 摘要复用）
//  - rendered_html：GitHub 服务端渲染好的 HTML 片段（实际显示用这个）
//  - etag / last_modified：HTTP 缓存校验头
//  - cached_at：本地写入时间（ISO8601，便于按时间清理）
//  - size：byte 长度，未来批量清理大缓存时按它排序
//

import Foundation
import GRDB

/// README Repository。
struct ReadmeRepository {

    private let database: any DatabaseManaging
    private let notificationCenter: NotificationCenter

    init(
        database: any DatabaseManaging,
        notificationCenter: NotificationCenter = .default
    ) {
        self.database = database
        self.notificationCenter = notificationCenter
    }

    // MARK: - 查询

    /// 按 repoId 查找 README 缓存。
    /// - Returns: 缓存命中返回 Readme；未命中返回 nil
    func find(repoId: Int64) async throws -> Readme? {
        try await database.writer.read { db in
            try Readme.fetchOne(db, key: repoId)
        }
    }

    // MARK: - 写入

    /// upsert README 缓存。
    ///
    /// GRDB 的 `MutablePersistableRecord.upsert(_:)` 是 mutating 方法（会回填 rowID），
    /// 因此必须在 closure 内拷贝为 var；外部接口仍可传不可变值。
    func upsert(_ readme: Readme) async throws {
        try await database.writer.write { db in
            var copy = readme
            try copy.upsert(db)
        }
    }

    /// 仅更新 cached_at（命中 304 时刷新本地缓存有效期判定，不写新 HTML）。
    func touchCachedAt(repoId: Int64, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE readmes SET cached_at = ? WHERE repo_id = ?",
                arguments: [iso, repoId]
            )
        }
    }

    /// 删除指定 repo 的 README 缓存。
    func delete(repoId: Int64) async throws {
        try await database.writer.write { db in
            _ = try Readme.deleteOne(db, key: repoId)
        }
    }

    /// 全表清空（设置页"清理缓存"用，已在 W4-4 D4 接入）。
    ///
    /// HOM-201 P2-2:同步清 `readme_contents`(raw markdown 拆表后的独立表),
    /// 让"清理缓存"一次性带走所有 README 相关 cache(html + markdown)。
    func deleteAll() async throws {
        try await database.writer.write { db in
            _ = try Readme.deleteAll(db)
            _ = try ReadmeContent.deleteAll(db)
        }
        // 清空缓存会让所有 README source 失效；不逐 repo 发事件，避免一次清理触发
        // 大量并发 embedding。RAG 索引器收到无 repoId 的事件后统一做一次 source diff。
        notificationCenter.post(name: .readmeContentDidChange, object: nil)
    }

    /// 只清理当前用户库内 Private 仓库的远端 README HTML / Markdown 缓存。
    ///
    /// Repo、项目关系、Star、Tag、Note 等用户数据均不受影响；清理后再次打开详情会
    /// 使用 GitHub App token 重拉。先删 child `readme_contents`，再删 `readmes`，
    /// 不依赖具体 SQLite FK cascade 配置。
    @discardableResult
    func deletePrivateRemoteCaches() async throws -> Int {
        let deletedCount = try await database.writer.write { db -> Int in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM readmes rm
                    JOIN repos r ON r.id = rm.repo_id
                    WHERE r.is_private = 1
                    """
            ) ?? 0
            try db.execute(
                sql: """
                    DELETE FROM readme_contents
                    WHERE repo_id IN (SELECT id FROM repos WHERE is_private = 1)
                    """
            )
            try db.execute(
                sql: """
                    DELETE FROM readmes
                    WHERE repo_id IN (SELECT id FROM repos WHERE is_private = 1)
                    """
            )
            return count
        }
        guard deletedCount > 0 else { return 0 }
        notificationCenter.post(name: .readmeContentDidChange, object: nil)
        return deletedCount
    }

    // MARK: - readme_contents(HOM-201 P2-2)

    /// 查询 raw Markdown 文本(独立表 `readme_contents`,P2-2 拆出去后专门承载)。
    ///
    /// 调用方:仅 AI / 向量索引等"纯文本消费方"显式调,普通 detail 渲染路径不调。
    /// 详见 `ReadmeContent.swift` 文件头与 `createReadmeContents` schema 注释。
    func findContent(repoId: Int64) async throws -> String? {
        try await database.writer.read { db in
            try ReadmeContent.fetchOne(db, key: repoId)?.content
        }
    }

    /// upsert raw Markdown 到 `readme_contents` 表。
    ///
    /// 调用方:`ReadmeAPI.refreshMarkdownIfNeeded(...)` 按需懒补全时使用。
    /// **业务约束**:调用方需先确保 `readmes` 行存在(否则 FK 不阻挡,但语义上是
    /// "孤立 markdown 没 HTML",WebView 兜底会查无 rendered_html 进 .empty 状态)。
    func upsertContent(repoId: Int64, content: String, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        let size = content.utf8.count
        let contentChanged = try await database.writer.write { db -> Bool in
            let previous = try ReadmeContent.fetchOne(db, key: repoId)?.content
            var row = ReadmeContent(
                repoId: repoId,
                content: content,
                cachedAt: iso,
                size: size
            )
            try row.upsert(db)
            return previous != content
        }
        guard contentChanged else { return }
        notificationCenter.post(
            name: .readmeContentDidChange,
            object: nil,
            userInfo: ["repoId": repoId]
        )
    }

    // MARK: - W4-4 D4：缓存统计

    /// readmes 表行数（设置页"清理缓存"显示当前缓存条目数用）。
    func countAll() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM readmes") ?? 0
        }
    }

    /// 所有缓存 README 字节总数（基于 `readmes.size` 列）。
    /// 注：size 是 upsert 时写入的 HTML 字节数，等价于 disk 占用的近似量级。
    func totalBytes() async throws -> Int64 {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM readmes") ?? 0
        }
    }
}

extension Notification.Name {
    /// raw Markdown 已变化。带 `repoId` 表示单 repo 更新；不带表示全量缓存已清空。
    /// 事件由 Repository 在事务成功后发送，确保详情页、后台预取和索引补全走同一入口。
    static let readmeContentDidChange = Notification.Name("StarcatReadmeContentDidChange")
}
