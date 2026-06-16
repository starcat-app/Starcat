//
//  ActivityEventRepositoryProtocol.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：following 事件流 Repository 协议。
//
//  关注点：
//  - 本地缓存 GitHub Events feed（不感知「何时再次拉取」——那是 PR-2 ViewModel 的责任）
//  - 提供 CRUD + 30 天清理边界
//  - 已读 / 未读由 `markRead(_:isRead:)` 显式翻转，device-local，不挂 CloudKit
//

import Foundation

protocol ActivityEventRepositoryProtocol: Sendable {

    // MARK: - 查询

    /// 取本地缓存的全部 following 事件，按 createdAt desc 排序，limit 截断。
    ///
    /// PR-2 在 `ActivityViewModel.reload` 拉到事件后展示用——纯本地读，不打网络。
    /// 空缓存返回空数组（不抛错）。
    func fetchAll(limit: Int) async throws -> [ActivityEventRecord]

    /// 当前未读事件总数（用于 Sidebar Badge / following 分类未读计数）。
    func unreadCount() async throws -> Int

    // MARK: - 写入

    /// 批量入库（INSERT OR REPLACE 形式）。
    ///
    /// **保留 is_read 语义**：与 `ReleaseRepository.upsertMany` 同款——同 event_id 已存在时
    /// 刷新 actor / payload / fetched_at，但**保留 is_read**（用户已读状态不能被网络刷新覆盖）。
    ///
    /// **网络层 过滤 ReleaseEvent**：调用方（PR-2 `GitHubEventsAPI` → `ActivityViewModel`）
    /// 在写入前已经把 `event_type == "ReleaseEvent"` 的行丢弃（决策 Q1），
    /// 本方法不做二次过滤——schema 不强约束 event_type 取值，依赖调用方契约。
    func upsertMany(_ records: [ActivityEventRecord]) async throws

    /// 标记单个事件为已读 / 未读。
    func markRead(eventId: String, isRead: Bool) async throws

    /// 标记所有事件为已读（"全部已读"按钮）。
    func markAllRead() async throws

    /// 删除 createdAt 早于 `days` 天前的事件。
    ///
    /// 由 `ActivityViewModel.cleanupIfNeeded()` 后台调度（≥ 24h 触发一次，决策 P6），
    /// 不在主刷新路径里跑，避免阻塞 UI loading。
    /// 返回实际删除行数（debug 日志用）。
    @discardableResult
    func deleteOlderThan(days: Int) async throws -> Int

    /// 清空全表（设置页"清除全部缓存"路径走这里）。
    func clearAll() async throws
}
