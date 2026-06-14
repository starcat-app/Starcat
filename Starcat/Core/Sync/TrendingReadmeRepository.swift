//
//  TrendingReadmeRepository.swift
//  Starcat
//
//  Trending README 缓存 Repository。
//
//  职责：
//  - 对接 `trending_readmes` 表（v4 迁移引入，schema 见 DatabaseMigrationsV1.createTrendingReadmes）
//  - 按 `full_name`（owner/repo）读写 README HTML 缓存
//  - 与 manage 路径的 `ReadmeRepository`（PK = repo_id: Int64）刻意保持隔离，互不污染
//
//  设计约束：
//  - 与 `ReadmeRepository` 同构：都依赖 `DatabaseManaging`、读写都 async、字段语义对齐
//    （rendered_html / etag / last_modified / cached_at / size），让 ReadmeAPI 复用同一套 SWR 逻辑
//  - PK 是 String（full_name）：GRDB MutablePersistableRecord.upsert 在 String PK 下完全可用
//  - 不直接持有 DatabaseManager 单例，便于注入 InMemoryDatabaseManager 跑测试
//
//  HOM-201 P1-3（2026-06-14）：LRU 自动淘汰
//  ────────────────────────────────────────────────────────────────────────────
//  Trending 路径 README 切换频繁(用户每天在 trending 列表里浏览的 repo 是 ephemeral
//  的,大多数永远不会被 star),长期使用后 `trending_readmes` 表会无界增长 —— 设置
//  页虽然有"清理缓存"但是用户感知不到容量问题,默认不会主动清。
//
//  方案:每次 upsert 后跑一次 high-water 触发 + low-water 收缩的 LRU:
//   - 阈值:行数 > 500 行 **或** 总 size > 50MB,任一触发就开始淘汰
//   - 淘汰目标:降到 80% low-water(行 → 400 / size → 40MB),避免每次 upsert 都
//     卡在阈值边界反复淘汰
//   - 淘汰顺序:`cached_at ASC`(最早访问的最先删),命中 `idx_trending_readmes_cached`
//     索引,O(n log n) 排序 → O(deleteCount) 删除
//   - 行数与 size 串行处理:先按行数砍,再按 size 累计砍,两步都是单条 SQL
//     不引入额外往返
//
//  阈值取值依据:
//   - 500 行:trending 每天最多展示几十个 repo,用户活跃 1-2 周内浏览过的 unique
//     repo 约 100-300 个,500 行能覆盖 2-3 周浏览历史
//   - 50MB:rewrite 后 HTML 平均 100-300KB(中位数 README;含图片 base64 / mermaid
//     SVG 的可能 500KB+),50MB 大约能存 150-300 条
//   - 触发后只删到 80% 是经典 high/low water 模式:避免上限边界附近频繁 IO,
//     一次淘汰平摊到接下来几十次 upsert
//
//  P1-3 也对 manage 路径(`ReadmeRepository`)适用吗?
//   不:manage 表通过 starred_repos 外键 cascade 受用户 star 行为约束,行数不会
//   无界增长,而本步设计聚焦"用户 ephemeral 浏览"的 trending 路径。用户 star
//   5000 个 repo 是用户的事,不应该被默认淘汰。
//

import Foundation
import GRDB

/// Trending README Repository。
struct TrendingReadmeRepository {

    /// 触发 LRU 淘汰的行数上限。命中后会触发收缩到 `lruLowWaterRows` 行。
    static let lruMaxRows: Int = 500
    /// 收缩目标(行数)。约为 `lruMaxRows * 0.8`,避免阈值边界反复淘汰。
    static let lruLowWaterRows: Int = 400

    /// 触发 LRU 淘汰的字节上限。命中后会触发收缩到 `lruLowWaterBytes`。
    static let lruMaxBytes: Int64 = 50 * 1024 * 1024
    /// 收缩目标(字节)。约为 `lruMaxBytes * 0.8`。
    static let lruLowWaterBytes: Int64 = 40 * 1024 * 1024

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    // MARK: - 查询

    /// 按 fullName 查找 README 缓存。
    /// - Returns: 缓存命中返回 TrendingReadme；未命中返回 nil
    func find(fullName: String) async throws -> TrendingReadme? {
        try await database.writer.read { db in
            try TrendingReadme.fetchOne(db, key: fullName)
        }
    }

    // MARK: - 写入

    /// upsert README 缓存,完成后视情况触发 LRU 淘汰(HOM-201 P1-3)。
    ///
    /// 与 `ReadmeRepository.upsert` 同款：`MutablePersistableRecord.upsert(_:)` 是 mutating，
    /// closure 内拷贝为 var；外部接口仍可传不可变值。
    ///
    /// LRU 与 upsert 在同一 transaction:要么一起成功要么一起回滚,
    /// 不会出现"upsert 成功 / LRU 失败 → 表又超阈值"的中间态。
    func upsert(_ readme: TrendingReadme) async throws {
        try await database.writer.write { db in
            var copy = readme
            try copy.upsert(db)
            try Self.enforceLRULimits(db)
        }
    }

    /// 仅更新 cached_at（命中 304 时刷新本地缓存有效期判定，不写新 HTML）。
    func touchCachedAt(fullName: String, at date: Date) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: date)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE trending_readmes SET cached_at = ? WHERE full_name = ?",
                arguments: [iso, fullName]
            )
        }
    }

    /// 删除指定 fullName 的 README 缓存。
    func delete(fullName: String) async throws {
        try await database.writer.write { db in
            _ = try TrendingReadme.deleteOne(db, key: fullName)
        }
    }

    /// 全表清空（设置页"清理缓存"用，与 `ReadmeRepository.deleteAll` 平行）。
    func deleteAll() async throws {
        try await database.writer.write { db in
            _ = try TrendingReadme.deleteAll(db)
        }
    }

    // MARK: - 缓存统计

    /// trending_readmes 表行数（设置页"清理缓存"展示用）。
    func countAll() async throws -> Int {
        try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM trending_readmes") ?? 0
        }
    }

    /// 所有缓存 README 字节总数（基于 `trending_readmes.size` 列）。
    func totalBytes() async throws -> Int64 {
        try await database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM trending_readmes") ?? 0
        }
    }

    // MARK: - LRU 淘汰（HOM-201 P1-3）

    /// 视情况执行 LRU 淘汰：行数或字节数过阈时按 `cached_at ASC` 删到 low-water。
    ///
    /// **必须在 GRDB 写事务内调用**——本方法不负责开启 transaction,只跑 SQL。
    /// 由 `upsert(_:)` 在写事务内直接调,与 upsert 同事务保证原子。
    ///
    /// 内部步骤：
    /// 1. 读 totalRows / totalBytes;两者都没超过 `lruMaxRows` / `lruMaxBytes` 直接 return
    /// 2. 行数超 → 按 `cached_at ASC` 删 (totalRows - lowWaterRows) 行(命中
    ///    `idx_trending_readmes_cached` 索引,O(deleteCount log n))
    /// 3. 字节数超 → 用 SQLite 3.25+ 的 window function `SUM() OVER (ORDER BY cached_at ASC)`
    ///    计算每行累计 size,删除累计 size ≤ `bytesToFree` 的最早一批
    ///
    /// 选用 `cached_at ASC` 而非 `last_accessed_at`:目前 schema 没有"最后访问"列,
    /// `cached_at` 在 304 / touch 时也会更新(详见 `touchCachedAt`),近似等同 LRU
    /// 的 "least recently refreshed",对 trending 路径(以网络刷新为主)足够准确。
    /// 不引入新列就避免 schema 迁移。
    ///
    /// 阈值参数对外暴露(`maxRows` / `lowWaterRows` / `maxBytes` / `lowWaterBytes`)
    /// 主要服务于测试 —— 业务路径都走默认值(类静态常量)。
    static func enforceLRULimits(
        _ db: Database,
        maxRows: Int = lruMaxRows,
        lowWaterRows: Int = lruLowWaterRows,
        maxBytes: Int64 = lruMaxBytes,
        lowWaterBytes: Int64 = lruLowWaterBytes
    ) throws {
        let totalRows = try Int.fetchOne(db, sql: "SELECT count(*) FROM trending_readmes") ?? 0
        let totalBytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM trending_readmes") ?? 0

        guard totalRows > maxRows || totalBytes > maxBytes else { return }

        // 行数收缩
        if totalRows > maxRows {
            let deleteCount = totalRows - lowWaterRows
            try db.execute(
                sql: """
                DELETE FROM trending_readmes
                WHERE full_name IN (
                    SELECT full_name FROM trending_readmes
                    ORDER BY cached_at ASC
                    LIMIT ?
                )
                """,
                arguments: [deleteCount]
            )
        }

        // 字节收缩:重新读 totalBytes(可能行数收缩已带走部分字节,要避免过度删除)
        let bytesAfter = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size), 0) FROM trending_readmes") ?? 0
        if bytesAfter > maxBytes {
            let bytesToFree = bytesAfter - lowWaterBytes
            // SQLite 3.25+ window function:对每行计算"按 cached_at 升序累计 size"
            // 删除累计值 ≤ bytesToFree 的最早一批
            try db.execute(
                sql: """
                DELETE FROM trending_readmes
                WHERE full_name IN (
                    SELECT full_name FROM (
                        SELECT full_name,
                               SUM(size) OVER (ORDER BY cached_at ASC ROWS UNBOUNDED PRECEDING) AS running
                        FROM trending_readmes
                    )
                    WHERE running <= ?
                )
                """,
                arguments: [bytesToFree]
            )
        }
    }
}
