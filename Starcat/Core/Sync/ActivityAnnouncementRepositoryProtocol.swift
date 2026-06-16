//
//  ActivityAnnouncementRepositoryProtocol.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：announcement 双源公告聚合 Repository 协议。
//
//  关注点：
//  - 本地缓存双源公告（blog / security），由 PR-2 / PR-3 在各自数据源拉到后写入
//  - 提供 CRUD + 按 source 过滤 + 30 天清理
//  - 已读 / 未读由 `markRead(_:isRead:)` 显式翻转，device-local，不挂 CloudKit
//

import Foundation

protocol ActivityAnnouncementRepositoryProtocol: Sendable {

    // MARK: - 查询

    /// 取本地缓存的全部公告，按 createdAt desc 排序，limit 截断。
    func fetchAll(limit: Int) async throws -> [ActivityAnnouncementRecord]

    /// 取指定来源的公告（按 createdAt desc）。便于 UI 按 source 分组渲染。
    func fetch(source: AnnouncementSource, limit: Int) async throws -> [ActivityAnnouncementRecord]

    /// 当前未读公告总数。
    func unreadCount() async throws -> Int

    // MARK: - 写入

    /// 批量入库。重复 id（如 RSS 同一 guid 二次拉到）刷新 title / body / fetched_at 等，
    /// **保留 is_read**（与 ActivityEventRepository.upsertMany 同款约束）。
    func upsertMany(_ records: [ActivityAnnouncementRecord]) async throws

    /// 标记单条公告为已读 / 未读。
    func markRead(announcementId: String, isRead: Bool) async throws

    /// 标记所有公告为已读。
    func markAllRead() async throws

    /// 删除 createdAt 早于 `days` 天前的公告。返回删除行数。
    @discardableResult
    func deleteOlderThan(days: Int) async throws -> Int

    /// 清空全表。
    func clearAll() async throws
}
