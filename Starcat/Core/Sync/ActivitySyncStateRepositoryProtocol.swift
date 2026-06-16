//
//  ActivitySyncStateRepositoryProtocol.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：Activity 数据接入单行 meta 表 Repository 协议。
//
//  关注点（详见 ActivitySyncStateRecord 注释）：
//  - 单行表（PK 固定 `"singleton"`），与 `weekly_bulk_meta` 同款风格
//  - PR-2/PR-3 用本协议保存 / 读取每个数据源的 ETag + lastFetchedAt + lastCleanupAt
//

import Foundation

protocol ActivitySyncStateRepositoryProtocol: Sendable {

    /// 读单行 meta。从未写入返回 nil（调用方按各自语义处理：ETag 当作 nil，
    /// lastFetchedAt 当作 distantPast，lastCleanupAt 当作"需要立即清理"等）。
    func current() async throws -> ActivitySyncStateRecord?

    /// 写入 events 数据源相关字段（成功拉到 events 后调用）。
    ///
    /// **partial update 语义**：传 nil 不动该字段（保留库里旧值）；非 nil 则覆盖。
    /// 实现走单条 UPSERT SQL，避免 read-modify-write 竞态。
    func updateEvents(etag: String?, lastFetchedAt: Date) async throws

    /// 写入 blog rss 数据源相关字段（成功拉到 blog rss 后调用）。
    func updateBlogRss(etag: String?, lastFetchedAt: Date) async throws

    /// 写入 security advisory 数据源相关字段（成功扫完一批 starred repo 后调用）。
    /// security 没有集中 etag（per-repo 端点），所以这里只写时间。
    func updateSecurity(lastFetchedAt: Date) async throws

    /// 更新 lastCleanupAt（30 天清理任务跑完后调用）。
    func updateLastCleanupAt(_ date: Date) async throws

    /// 清空 sync state（设置页"清除全部缓存"路径走这里）。
    func clear() async throws
}
